;;; chinese-speech-input-transcribe.el --- 中文语音转写（阿里云 Qwen-ASR）  -*- lexical-binding: t; -*-

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

;; 把一段录音转写成中文文本，使用阿里云百炼 Qwen-ASR
;; （模型 qwen3-asr-flash，OpenAI 兼容模式）：
;;
;;   https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference
;;
;; 需要 `DASHSCOPE_API_KEY'（或设置 `chinese-speech-input-aliyun-api-key'）。

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup chinese-speech-input nil
  "中文语音输入。"
  :group 'multimedia)

(defcustom chinese-speech-input-language "zh"
  "识别语种。阿里云取值见 Qwen-ASR 文档（zh 普通话 / yue 粤语 等）。"
  :type 'string)

;;;###autoload
(defcustom chinese-speech-input-aliyun-api-key (getenv "DASHSCOPE_API_KEY")
  "阿里云百炼 API Key。"
  :type 'string)

(defcustom chinese-speech-input-aliyun-url
  "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
  "Qwen-ASR OpenAI 兼容模式调用地址（chat/completions）。
如需使用业务空间专属域名，改为
https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
  :type 'string)

(defcustom chinese-speech-input-aliyun-model "qwen3-asr-flash"
  "Qwen-ASR 模型名。"
  :type 'string)

(defcustom chinese-speech-input-aliyun-enable-itn nil
  "是否开启 ITN（逆文本标准化），把中文数字转为阿拉伯数字。"
  :type 'boolean)

(defcustom chinese-speech-input-curl-timeout "60"
  "curl 请求超时时间（秒），作为 --max-time 传入。"
  :type 'string)

;;; ---- 基础工具 ----

(defun chinese-speech-input--base64-file (filename)
  "返回 FILENAME 内容的 base64 编码（不带换行）。"
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally filename)
    (base64-encode-string (buffer-string) t)))

(defun chinese-speech-input--curl-json-post (url headers body &optional callback)
  "向 URL 发送 JSON BODY（字符串），HEADERS 为字符串列表。
同步：返回解析后的 JSON（alist）。
异步：若给 CALLBACK，则返回进程并在完成时用 JSON（alist）调用 CALLBACK。"
  (let* ((tmp (make-temp-file "cn-speech-asr-" nil ".json"))
         (body-bytes (encode-coding-string body 'utf-8))
         (command `("curl" "-s" "-S" "-X" "POST"
                    "--max-time" ,chinese-speech-input-curl-timeout
                    ,url
                    ,@(mapcan (lambda (h) (list "-H" h)) headers)
                    "--data-binary" ,(concat "@" tmp))))
    (let ((coding-system-for-write 'no-conversion))
      (write-region body-bytes nil tmp nil nil))
    (if (functionp callback)
        (make-process
         :name "chinese-speech-input-asr"
         :command command
         :coding 'utf-8
         :sentinel
         (lambda (process _event)
           (unwind-protect
               (let ((buf (process-buffer process)))
                 (funcall callback
                          (if (buffer-live-p buf)
                              (with-current-buffer buf
                                (goto-char (point-min))
                                (condition-case nil
                                    (json-parse-buffer :object-type 'alist
                                                       :array-type 'list)
                                  (error nil)))
                            nil)))
             (delete-file tmp))))
      (unwind-protect
          (with-temp-buffer
            (let ((coding-system-for-read 'utf-8)
                  (exit-code
                   (apply #'call-process (car command) nil (current-buffer) nil
                          (cdr command))))
              (goto-char (point-min))
              (cond
               ((and (numberp exit-code) (not (zerop exit-code)))
                (error "ASR 请求失败（curl 退出码 %s）：%s"
                       exit-code
                       (or (string-trim (buffer-string)) "(无输出)")))
               (t
                (condition-case nil
                    (json-parse-buffer :object-type 'alist :array-type 'list)
                  (error
                   (error "ASR 响应不是有效 JSON：%s"
                          (or (string-trim (buffer-string)) "(空响应)"))))))))
        (delete-file tmp)))))

;;; ---- 阿里云 Qwen-ASR ----

(defun chinese-speech-input--aliyun-body (data-url context)
  "构造阿里云 Qwen-ASR（OpenAI 兼容模式）请求体。CONTEXT 为提示词字符串列表（可为 nil）。"
  (let* ((user-content
          (vector `(("type" . "input_audio")
                    ("input_audio" . (("data" . ,data-url))))))
         (user-msg `(("role" . "user") ("content" . ,user-content)))
         (system-msg (when (and context (consp context) (> (length context) 0))
                       `(("role" . "system")
                         ("content" . [ (("text" . ,(string-join (delq nil context) "，")))]))))
         (messages (apply #'vector (delq nil (list system-msg user-msg)))))
    (json-encode
     `(("model" . ,chinese-speech-input-aliyun-model)
       ("messages" . ,messages)
       ("stream" . :json-false)
       ("asr_options"
        . (("enable_itn" . ,(if chinese-speech-input-aliyun-enable-itn t :json-false))
           ("language" . ,chinese-speech-input-language)))))))

(defun chinese-speech-input--aliyun-headers ()
  "阿里云请求头。"
  (list (concat "Authorization: Bearer " chinese-speech-input-aliyun-api-key)
        "Content-Type: application/json"))

(defun chinese-speech-input--aliyun-text (result)
  "从阿里云（OpenAI 兼容）返回 RESULT 中提取文本；出错时返回 nil。"
  (let* ((choices (alist-get 'choices result))
         (message (alist-get 'message (car choices)))
         (content (alist-get 'content message)))
    (cond
     ((stringp content) content)
     ((consp content) (alist-get 'text (car content)))
     (t nil))))

(defun chinese-speech-input--aliyun-error (result)
  "若 RESULT 为阿里云错误响应，返回错误描述，否则 nil。"
  (or (alist-get 'message result)
      (alist-get 'message (alist-get 'error result))))

(defun chinese-speech-input--aliyun-request (filename context callback)
  "把 FILENAME 发给阿里云 Qwen-ASR。CONTEXT 为提示词列表。
同步（CALLBACK 为 nil）返回解析后的 JSON；否则异步调用 CALLBACK。"
  (unless chinese-speech-input-aliyun-api-key
    (error "未设置 DASHSCOPE_API_KEY"))
  (let* ((audio (chinese-speech-input--base64-file filename))
         (data-url (concat "data:audio/wav;base64," audio))
         (body (chinese-speech-input--aliyun-body data-url context))
         (headers (chinese-speech-input--aliyun-headers)))
    (chinese-speech-input--curl-json-post chinese-speech-input-aliyun-url
                                          headers body callback)))

(defun chinese-speech-input--aliyun-result-text (result)
  "从阿里云 RESULT 提取文本；失败时抛出错误。"
  (let ((text (chinese-speech-input--aliyun-text result)))
    (if (null text)
        (error "阿里云 Qwen-ASR 识别失败：%s"
               (or (chinese-speech-input--aliyun-error result)
                   (format "%S" result)))
      text)))

;;;###autoload
(defun chinese-speech-input-transcribe-sync (filename &optional context)
  "同步转写 FILENAME 为中文文本。
CONTEXT 为提示词字符串列表（如候选命令），用于提升识别准确率。"
  (chinese-speech-input--aliyun-result-text
   (chinese-speech-input--aliyun-request filename context nil)))

;;;###autoload
(defun chinese-speech-input-transcribe (filename callback &optional context)
  "异步转写 FILENAME，完成后用识别文本调用 CALLBACK。
CONTEXT 为提示词字符串列表。"
  (chinese-speech-input--aliyun-request
   filename context
   (lambda (result)
     (funcall callback
              (condition-case nil
                  (chinese-speech-input--aliyun-result-text result)
                (error nil))))))

(provide 'chinese-speech-input-transcribe)
;;; chinese-speech-input-transcribe.el ends here
