;;; chinese-speech-input.el --- 中文语音输入                 -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: SPI 中文语音输入
;; Keywords: multimedia, chinese

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; 参照 Sacha Chua 的 speech-input.el 实现的中文语音输入方案：
;;
;;   1. 使用 Silero VAD 检测语音起止（chinese-speech-input-vad.el + vad-events.py）；
;;   2. 用 ffmpeg 录制一句话；
;;   3. 交给阿里云 Qwen-ASR 或腾讯云一句话识别转写成中文
;;      （chinese-speech-input-transcribe.el）；
;;   4. 插入文本，或用模糊匹配选中候选命令。
;;
;; 快速开始：
;;   (require 'chinese-speech-input)
;;   M-x chinese-speech-input-insert-once   ; 说话并插入中文
;;   M-x chinese-speech-input-vad-start     ; 或先启动 VAD

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chinese-speech-input-transcribe)
(require 'chinese-speech-input-vad)

;;; ---- 录音 ----

(defvar chinese-speech-input-recording-process nil)

(defvar chinese-speech-input-recording-command
  '("ffmpeg" "-y" "-f" "pulse" "-i" "default"
    "-f" "wav" "-ar" "16000" "-ac" "1")
  "用 ffmpeg 录制的命令。默认从 PulseAudio 的 default 源录制 16kHz 单声道 wav。
中文 ASR 建议 16kHz；若麦克风源不是 default 请自行调整。")

(defvar chinese-speech-input-recording-filename nil)

(defun chinese-speech-input-stop-recording ()
  "停止当前录音。"
  (interactive)
  (when (process-live-p chinese-speech-input-recording-process)
    (interrupt-process chinese-speech-input-recording-process)))

(defun chinese-speech-input-start-recording (callback &optional filename)
  "开始录音；录音结束后用文件名调用 CALLBACK。"
  (interactive)
  (when (process-live-p chinese-speech-input-recording-process)
    (interrupt-process chinese-speech-input-recording-process))
  (let* ((temp-file (or filename (make-temp-file "chinese-speech-input" nil ".wav"))))
    (setq chinese-speech-input-recording-filename temp-file)
    (setq chinese-speech-input-recording-process
          (make-process
           :name "record"
           :buffer "*record*"
           :command (append chinese-speech-input-recording-command (list temp-file))))
    (set-process-sentinel chinese-speech-input-recording-process
                          (lambda (_proc status)
                            (when (and (string-match "finished\\|exited\\|killed" status)
                                       callback)
                              (funcall callback temp-file))))))

(defun chinese-speech-input-cancel-recording ()
  "丢弃当前录音。"
  (interactive)
  (when (process-live-p chinese-speech-input-recording-process)
    (set-process-sentinel chinese-speech-input-recording-process nil))
  (chinese-speech-input-stop-recording)
  (remove-hook 'chinese-speech-input-vad-on-end-functions
               'chinese-speech-input-vad-stop-recording-once)
  (when (and chinese-speech-input-recording-filename
             (file-exists-p chinese-speech-input-recording-filename))
    (delete-file chinese-speech-input-recording-filename)))

;;; ---- 直接插入 ----

;;;###autoload
(defun chinese-speech-input-insert-once ()
  "录制并转写一句话中文，插入到当前缓冲区。"
  (interactive)
  (chinese-speech-input-vad-record-one-turn
   (lambda (filename)
     (unwind-protect
         (condition-case err
             (let ((text (chinese-speech-input-transcribe-sync filename)))
               (when (and text (not (string-empty-p text)))
                 (insert text)))
           (error (message "中文语音转写失败：%s" (error-message-string err))))
       (when (file-exists-p filename)
         (delete-file filename))))))

;;; ---- 模糊匹配 ----

(defcustom chinese-speech-input-string-distance-threshold 0.3
  "字符串距离阈值（相对长度）。0 表示必须完全匹配，nil 表示总是匹配。"
  :type '(choice (const nil) number)
  :group 'chinese-speech-input)

(defun chinese-speech-input-normalize-string (s)
  "简化 S 以便比较：只保留汉字、字母、数字，其余删除并转小写。"
  (downcase
   (replace-regexp-in-string
    "[^a-z0-9\u4e00-\u9fff\u3400-\u4dbf]+" "" s)))

(defun chinese-speech-input--reshape-collection (collection)
  "把 COLLECTION 统一成 ((结果 候选1 候选2 ...) ...) 的形式。"
  (mapcar (lambda (o)
            (cond
             ((stringp o) (list o o))
             ((stringp (cdr o)) (list (car o) (cdr o)))
             (t o)))
          collection))

(defun chinese-speech-input-string-approx (text other-text)
  "返回非 nil 表示 TEXT 与 OTHER-TEXT 大致相同。
TEXT 也可以是之前算好的字符串距离（数字）。"
  (when (stringp text)
    (setq text (chinese-speech-input-normalize-string text))
    (setq other-text (chinese-speech-input-normalize-string other-text)))
  (or (null chinese-speech-input-string-distance-threshold)
      (<=
       (/ (if (numberp text)
              text
            (string-distance text other-text))
          (* 1.0
             (if (numberp text)
                 (length other-text)
               (max (length text) (length other-text)))))
       chinese-speech-input-string-distance-threshold)))

(defun chinese-speech-input-get-list-distances (text collection)
  "找出 COLLECTION 中与 TEXT 最接近的项。
返回 (距离 候选 结果) 的列表，按距离升序。"
  (let* ((collection (chinese-speech-input--reshape-collection collection))
         (normalized (chinese-speech-input-normalize-string text)))
    (sort
     (apply #'append
            (mapcar
             (lambda (o)
               (mapcar
                (lambda (cand)
                  (list
                   (string-distance
                    normalized
                    (chinese-speech-input-normalize-string cand))
                   cand
                   (car o)))
                (cdr o)))
             collection))
     :key 'car)))

(defun chinese-speech-input-match-in-list (text collection)
  "返回 COLLECTION 中与 TEXT 最接近的候选的结果值。"
  (let ((by-distance (chinese-speech-input-get-list-distances text collection)))
    (if (and by-distance
             (chinese-speech-input-string-approx
              (elt (car by-distance) 0)
              (elt (car by-distance) 1)))
        (elt (car by-distance) 2)
      text)))

(defun chinese-speech-input-match-first-part (text collection)
  "尝试把 COLLECTION 中的候选匹配到 TEXT 开头（按字符）。
返回 (候选结果 . 剩余文本)。"
  (let* ((collection (chinese-speech-input--reshape-collection collection))
         (norm (chinese-speech-input-normalize-string text))
         (norm-len (length norm))
         (best nil))                     ; (距离 候选结果 消费长度)
    (dolist (group collection)
      (dolist (cand (cdr group))
        (let* ((norm-cand (chinese-speech-input-normalize-string cand))
               (cand-len (length norm-cand)))
          (when (> cand-len 0)
            (cl-loop for len from (max 1 (1- cand-len))
                     to (min norm-len (1+ cand-len))
                     do (let ((dist (string-distance
                                     norm-cand
                                     (substring norm 0 len))))
                          (when (and (chinese-speech-input-string-approx dist norm-cand)
                                     (or (null best)
                                         (< dist (car best))
                                         ;; 距离相同优先更长的候选（更具体）
                                         (and (= dist (car best))
                                              (> len (nth 2 best)))))
                            (setq best (list dist (car group) len)))))))))
    (if best
        (cons (nth 1 best) (substring norm (nth 2 best)))
      (cons nil norm))))

(defun chinese-speech-input-match-all (text collection)
  "尝试把 COLLECTION 依次匹配到 TEXT 上，返回匹配到的结果列表。"
  (let ((remaining (chinese-speech-input-normalize-string text))
        results)
    (while (not (string-empty-p remaining))
      (let ((m (chinese-speech-input-match-first-part remaining collection)))
        (if (car m)
            (progn
              (push (car m) results)
              (setq remaining (cdr m)))
          (setq remaining (substring remaining 1)))))
    (nreverse results)))

(defun chinese-speech-input--collection-context (collection)
  "把 COLLECTION 中的候选串展开为提示词列表。"
  (apply #'append
         (mapcar #'cdr (chinese-speech-input--reshape-collection collection))))

;;; ---- 命令选择 ----

;;;###autoload
(defun chinese-speech-input-from-list (prompt collection callback)
  "语音选择 COLLECTION 中与所说内容最接近的一项。
COLLECTION 可为字符串列表、(结果 . 候选) 列表或 (结果 候选1 候选2 ...) 列表。
识别完成后用 (结果 实际文本) 调用 CALLBACK。"
  (when prompt (message "%s" prompt))
  (chinese-speech-input-vad-record-one-turn
   (lambda (filename)
     (unwind-protect
         (condition-case err
             (let* ((collection (chinese-speech-input--reshape-collection collection))
                    (context (chinese-speech-input--collection-context collection))
                    (text (chinese-speech-input-transcribe-sync filename context)))
               (funcall callback
                        (chinese-speech-input-match-in-list text collection)
                        text))
           (error (message "中文语音转写失败：%s" (error-message-string err))))
       (when (file-exists-p filename)
         (delete-file filename))))))

;;;###autoload
(defun chinese-speech-input-multiple-from-list (prompt collection each-callback after-all-callback)
  "语音选择 COLLECTION 中的多个项。
对每个识别出的项用 (结果 上一个返回值) 调用 EACH-CALLBACK，
全部完成后用 (结果列表 实际文本) 调用 AFTER-ALL-CALLBACK。"
  (when prompt (message "%s" prompt))
  (chinese-speech-input-vad-record-one-turn
   (lambda (filename)
     (unwind-protect
         (condition-case err
             (let* ((collection (chinese-speech-input--reshape-collection collection))
                    (context (chinese-speech-input--collection-context collection))
                    (text (chinese-speech-input-transcribe-sync filename context))
                    (commands (chinese-speech-input-match-all text collection)))
               (when each-callback
                 (seq-reduce (lambda (prev value)
                               (funcall each-callback value prev))
                             commands nil))
               (when after-all-callback
                 (funcall after-all-callback commands text)))
           (error (message "中文语音转写失败：%s" (error-message-string err))))
       (when (file-exists-p filename)
         (delete-file filename))))))

(provide 'chinese-speech-input)
;;; chinese-speech-input.el ends here
