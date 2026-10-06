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
(defvar chinese-speech-input-vad-debug nil
  "非 nil 时在语音开始/结束打印提示。")

(defvar chinese-speech-input-vad-ready nil
  "非 nil 表示 VAD 进程已加载模型并开始监听（收到 READY）。")

(defvar chinese-speech-input-vad-pending-callback nil
  "当前一轮录音的转写回调。")
(defvar chinese-speech-input-vad-pending-filename nil
  "当前一轮录音的指定文件名（可为 nil，自动生成）。")

(defun chinese-speech-input-vad-toggle-debug ()
  "切换 `chinese-speech-input-vad-debug'。"
  (interactive)
  (setq chinese-speech-input-vad-debug (not chinese-speech-input-vad-debug))
  (message (if chinese-speech-input-vad-debug
               "已开启 VAD 调试。"
             "已关闭 VAD 调试。")))

(defun chinese-speech-input-vad-events-filter (_proc string)
  (cond
   ((string-match "^READY" string)
    (setq chinese-speech-input-vad-ready t)
    (message "VAD 已就绪，可以开始说话。"))
   ((string-match "^START" string)
    (when chinese-speech-input-vad-debug (message "语音开始"))
    (run-hooks 'chinese-speech-input-vad-on-start-functions))
   ((string-match "^END" string)
    (when chinese-speech-input-vad-debug (message "语音结束"))
    (run-hooks 'chinese-speech-input-vad-on-end-functions))))

;;;###autoload
(defun chinese-speech-input-vad-start ()
  "如果尚未运行则启动 VAD 进程。"
  (interactive)
  (unless (process-live-p chinese-speech-input-vad-events-process)
    (setq chinese-speech-input-vad-ready nil)
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
  "语音开始时启动录音（只执行一次）。"
  (remove-hook 'chinese-speech-input-vad-on-start-functions
               'chinese-speech-input-vad-start-recording-once)
  (chinese-speech-input-start-recording
   chinese-speech-input-vad-pending-callback
   chinese-speech-input-vad-pending-filename))

;;;###autoload
(defun chinese-speech-input-vad-record-one-turn (callback &optional filename)
  "录制一句话：VAD 检测到语音开始后开始录音，语音结束后用文件名调用 CALLBACK。"
  (setq chinese-speech-input-vad-pending-callback callback)
  (setq chinese-speech-input-vad-pending-filename filename)
  (chinese-speech-input-vad-start)
  (unless chinese-speech-input-vad-ready
    (message "正在启动 VAD，首次约需几秒，请稍候…"))
  (add-hook 'chinese-speech-input-vad-on-start-functions
            'chinese-speech-input-vad-start-recording-once)
  (add-hook 'chinese-speech-input-vad-on-end-functions
            'chinese-speech-input-vad-stop-recording-once))

(provide 'chinese-speech-input-vad)
;;; chinese-speech-input-vad.el ends here
