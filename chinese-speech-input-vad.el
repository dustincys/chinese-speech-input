;;; chinese-speech-input-vad.el --- Silero 语音活动检测  -*- lexical-binding: t; -*-

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

;; 使用 Silero VAD 检测语音开始/结束，从而录制“一句话”音频。
;; Silero VAD 与语种无关，中英文都适用。

;;; Code:

(declare-function chinese-speech-input-start-recording "chinese-speech-input")
(declare-function chinese-speech-input-stop-recording "chinese-speech-input")

(defvar chinese-speech-input-vad-events-process nil)
(defvar chinese-speech-input-vad-events-dir
  (file-name-directory (or load-file-name (buffer-file-name))))
(defvar chinese-speech-input-vad-events-command
  `(,(expand-file-name ".venv/bin/python" chinese-speech-input-vad-events-dir)
    ,(expand-file-name "vad-events.py" chinese-speech-input-vad-events-dir)))

(defvar chinese-speech-input-vad-on-end-functions nil)
(defvar chinese-speech-input-vad-on-start-functions nil)
(defvar chinese-speech-input-vad-on-ready-functions nil)
(defvar chinese-speech-input-vad-debug nil
  "非 nil 时在语音开始/结束打印提示。")

(defvar chinese-speech-input-vad-ready nil
  "非 nil 表示 VAD 进程已加载模型并开始监听（收到 READY）。")

(defvar chinese-speech-input-vad-pending-callback nil
  "当前一轮录音的转写回调。")
(defvar chinese-speech-input-vad-pending-filename nil
  "当前一轮录音的指定文件名（可为 nil，自动生成）。")

(defvar chinese-speech-input-vad-filter-buffer ""
  "进程输出缓冲，用于拼接被切分的行。")

(defun chinese-speech-input-vad-toggle-debug ()
  "切换 `chinese-speech-input-vad-debug'。"
  (interactive)
  (setq chinese-speech-input-vad-debug (not chinese-speech-input-vad-debug))
  (message (if chinese-speech-input-vad-debug
               "已开启 VAD 调试。"
             "已关闭 VAD 调试。")))

(defun chinese-speech-input-vad-handle-line (line)
  "处理 VAD 进程输出的一整行 LINE。"
  (cond
   ((string-prefix-p "READY" line)
    (setq chinese-speech-input-vad-ready t)
    (message "VAD 已就绪，可以开始说话。")
    (run-hooks 'chinese-speech-input-vad-on-ready-functions))
   ((string-prefix-p "START" line)
    (when chinese-speech-input-vad-debug (message "语音开始"))
    (run-hooks 'chinese-speech-input-vad-on-start-functions))
   ((string-prefix-p "END" line)
    (when chinese-speech-input-vad-debug (message "语音结束"))
    (run-hooks 'chinese-speech-input-vad-on-end-functions))))

(defun chinese-speech-input-vad-events-filter (_proc string)
  "按行处理 VAD 进程输出（自动拼接被切分的行）。"
  (setq chinese-speech-input-vad-filter-buffer
        (concat chinese-speech-input-vad-filter-buffer string))
  (while (string-match "\n" chinese-speech-input-vad-filter-buffer)
    (let ((line (substring chinese-speech-input-vad-filter-buffer
                           0 (match-beginning 0))))
      (setq chinese-speech-input-vad-filter-buffer
            (substring chinese-speech-input-vad-filter-buffer
                       (match-end 0)))
      (chinese-speech-input-vad-handle-line line))))

;;;###autoload
(defun chinese-speech-input-vad-start ()
  "如果尚未运行则启动 VAD 进程。"
  (interactive)
  (unless (process-live-p chinese-speech-input-vad-events-process)
    (setq chinese-speech-input-vad-ready nil)
    (setq chinese-speech-input-vad-filter-buffer "")
    (let ((process-environment
           (cons
            (format
             "PULSE_PROP=node.description='%s' media.name='%s' node.name='%s'"
             "vad" "vad" "vad")
            process-environment)))
      (setq chinese-speech-input-vad-events-process
            (make-process
             :name "vad-events"
             :command chinese-speech-input-vad-events-command
             :buffer (get-buffer-create "*vad-events*")
             :stderr (get-buffer-create "*vad-events-err*")
             :filter #'chinese-speech-input-vad-events-filter)))))

(defun chinese-speech-input-vad-stop ()
  "停止 VAD 进程。"
  (interactive)
  (when (process-live-p chinese-speech-input-vad-events-process)
    (stop-process chinese-speech-input-vad-events-process)))

(defun chinese-speech-input-vad-stop-recording-once ()
  (remove-hook 'chinese-speech-input-vad-on-end-functions
               'chinese-speech-input-vad-stop-recording-once)
  (chinese-speech-input-stop-recording))

(defun chinese-speech-input-vad-start-recording-once ()
  "VAD 就绪后启动录音（只执行一次）。"
  (remove-hook 'chinese-speech-input-vad-on-ready-functions
               'chinese-speech-input-vad-start-recording-once)
  (chinese-speech-input-start-recording
   chinese-speech-input-vad-pending-callback
   chinese-speech-input-vad-pending-filename))

;;;###autoload
(defun chinese-speech-input-vad-record-one-turn (callback &optional filename)
  "录制一句话：VAD 就绪后开始录音，语音结束后用文件名调用 CALLBACK。"
  (setq chinese-speech-input-vad-pending-callback callback)
  (setq chinese-speech-input-vad-pending-filename filename)
  (chinese-speech-input-vad-start)
  (add-hook 'chinese-speech-input-vad-on-end-functions
            'chinese-speech-input-vad-stop-recording-once)
  (if chinese-speech-input-vad-ready
      ;; 已经就绪：立刻开始录音（用户直接说话即可，能录到完整一句话）
      (chinese-speech-input-start-recording callback filename)
    ;; 尚未就绪：等 READY 后再开始录音，避免把模型加载期录进去
    (message "正在启动 VAD，首次约需几秒，请稍候…")
    (add-hook 'chinese-speech-input-vad-on-ready-functions
              'chinese-speech-input-vad-start-recording-once)))

(provide 'chinese-speech-input-vad)
;;; chinese-speech-input-vad.el ends here
