;;; chinese-speech-input-transcribe.el --- 中文语音转写（阿里云 / 腾讯云）  -*- lexical-binding: t; -*-

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

;; 把一段录音转写成中文文本。支持两个后端：
;;
;;   1. 阿里云百炼 Qwen-ASR（模型 qwen3-asr-flash，OpenAI 兼容模式）
;;      https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference
;;      需要 `DASHSCOPE_API_KEY'。
;;
;;   2. 腾讯云一句话识别（SentenceRecognition）
;;      https://cloud.tencent.com/document/product/1093/35646
;;      需要 `TENCENT_SECRET_ID' / `TENCENT_SECRET_KEY'（TC3-HMAC-SHA256 签名）。
;;
;; 通过 `chinese-speech-input-asr-backend' 选择后端。

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup chinese-speech-input nil
  "中文语音输入。"
  :group 'multimedia)

;;;###autoload
(defcustom chinese-speech-input-asr-backend 'aliyun
  "ASR 后端：`aliyun'（阿里云 Qwen-ASR）或 `tencent'（腾讯云一句话识别）。"
  :type '(choice (const aliyun) (const tencent)))

(defcustom chinese-speech-input-language "zh"
  "识别语种，传给后端。阿里云取值见 Qwen-ASR 文档（如 zh / yue）。"
  :type 'string)

;;; ---- 阿里云 ----

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

;;; ---- 腾讯云 ----

(defcustom chinese-speech-input-tencent-secret-id
  (or (getenv "TENCENT_SECRET_ID") (getenv "TENCENTCLOUD_SECRET_ID"))
  "腾讯云 SecretId。"
  :type 'string)

(defcustom chinese-speech-input-tencent-secret-key
  (or (getenv "TENCENT_SECRET_KEY") (getenv "TENCENTCLOUD_SECRET_KEY"))
  "腾讯云 SecretKey。"
  :type 'string)

(defcustom chinese-speech-input-tencent-host "asr.tencentcloudapi.com"
  "腾讯云 ASR 接口域名。"
  :type 'string)

(defcustom chinese-speech-input-tencent-engine "16k_zh"
  "腾讯云一句话识别引擎类型（EngSerViceType），如 16k_zh / 16k_zh-PY / 16k_yue。"
  :type 'string)

(defcustom chinese-speech-input-tencent-region "ap-guangzhou"
  "腾讯云地域（X-TC-Region）。"
  :type 'string)

(defcustom chinese-speech-input-tencent-convert-num-mode 0
  "腾讯云阿拉伯数字智能转换：0 输出中文数字，1 智能转为阿拉伯数字。"
  :type '(choice (const 0) (const 1)))

(defcustom chinese-speech-input-tencent-filter-punc 0
  "腾讯云标点过滤：0 不过滤，1 过滤句末标点，2 过滤所有标点。"
  :type '(choice (const 0) (const 1) (const 2)))

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

(defun chinese-speech-input--sha256-hex (string)
  "返回 STRING 的 SHA-256 十六进制摘要（小写）。"
  (secure-hash 'sha256 string))

(defun chinese-speech-input--sha256-bytes (string)
  "返回 STRING 的 SHA-256 摘要（原始字节，unibyte string）。"
  (secure-hash 'sha256 string nil nil t))

(defun chinese-speech-input--hmac-sha256 (key message)
  "返回以 KEY 对 MESSAGE 做 HMAC-SHA256 的原始字节。"
  (let* ((block-size 64)
         (key (if (> (length key) block-size)
                  (chinese-speech-input--sha256-bytes key)
                key))
         (key (concat key (make-string (- block-size (length key)) 0)))
         (ipad (apply #'unibyte-string
                      (mapcar (lambda (b) (logxor b #x36))
                              (string-to-list key))))
         (opad (apply #'unibyte-string
                      (mapcar (lambda (b) (logxor b #x5c))
                              (string-to-list key)))))
    (chinese-speech-input--sha256-bytes
     (concat opad
             (chinese-speech-input--sha256-bytes (concat ipad message))))))

(defun chinese-speech-input--hex-encode (bytes)
  "把原始字节 BYTES 编码为小写十六进制字符串。"
  (apply #'concat
         (mapcar (lambda (b) (format "%02x" b)) (string-to-list bytes))))

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
    ;; 以原始字节写入请求体（与签名计算完全一致）
    (let ((coding-system-for-write 'no-conversion))
      (write-region body-bytes nil tmp nil 'silent))
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
            (let ((coding-system-for-read 'utf-8))
              (apply #'call-process (car command) nil (current-buffer) nil
                     (cdr command)))
            (goto-char (point-min))
            (json-parse-buffer :object-type 'alist :array-type 'list))
        (delete-file tmp)))))

;;; ---- 阿里云 ----

(defun chinese-speech-input--aliyun-body (data-url context)
  "构造阿里云 Qwen-ASR（OpenAI 兼容模式）请求体。CONTEXT 为提示词字符串列表（可为 nil）。"
  (let* ((user-content
          (vector `(("type" . "input_audio")
                    ("input_audio" . (("data" . ,data-url))))))
         (user-msg `(("role" . "user") ("content" . ,user-content)))
         (system-msg (when (and context (consp context) (> (length context) 0))
                       `(("role" . "system")
                         ("content" . ,(string-join (delq nil context) "，")))))
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

;;; ---- 腾讯云 ----

(defun chinese-speech-input--tencent-body (audio data-len context)
  "构造腾讯云一句话识别请求体。"
  (json-encode
   `(("ProjectId" . 0)
     ("SubServiceType" . 2)
     ("EngSerViceType" . ,chinese-speech-input-tencent-engine)
     ("SourceType" . 1)
     ("VoiceFormat" . "wav")
     ("UsrAudioKey" . "emacs-cn-speech-input")
     ("Data" . ,audio)
     ("DataLen" . ,data-len)
     ("ConvertNumMode" . ,chinese-speech-input-tencent-convert-num-mode)
     ("FilterPunc" . ,chinese-speech-input-tencent-filter-punc)
     ,@(when (and context (consp context) (> (length context) 0))
         (list
          (cons "HotwordList"
                (mapconcat (lambda (w) (concat w "|10"))
                           (delq nil context) ",")))))))

(defun chinese-speech-input--tencent-sign (body)
  "对 BODY 做 TC3-HMAC-SHA256 签名，返回请求头列表。"
  (let* ((host chinese-speech-input-tencent-host)
         (service "asr")
         (now (current-time))
         (timestamp (format-time-string "%s" now))
         (date (format-time-string "%Y-%m-%d" now t))
         (payload (encode-coding-string body 'utf-8))
         (hashed-payload (secure-hash 'sha256 payload))
         (canonical-request
          (concat "POST\n"
                  "/\n"
                  "\n"
                  "content-type:application/json; charset=utf-8\n"
                  (concat "host:" host "\n")
                  "\n"
                  "content-type;host\n"
                  hashed-payload))
         (string-to-sign
          (concat "TC3-HMAC-SHA256\n"
                  timestamp "\n"
                  date "/" service "/tc3_request\n"
                  (secure-hash 'sha256 canonical-request)))
         (secret-date (chinese-speech-input--hmac-sha256
                       (concat "TC3" chinese-speech-input-tencent-secret-key) date))
         (secret-service (chinese-speech-input--hmac-sha256 secret-date service))
         (secret-signing (chinese-speech-input--hmac-sha256 secret-service "tc3_request"))
         (signature (chinese-speech-input--hex-encode
                     (chinese-speech-input--hmac-sha256 secret-signing string-to-sign)))
         (authorization
          (concat "TC3-HMAC-SHA256 Credential="
                  chinese-speech-input-tencent-secret-id "/" date "/" service "/tc3_request"
                  ", SignedHeaders=content-type;host, Signature=" signature)))
    (list (concat "Authorization: " authorization)
          "Content-Type: application/json; charset=utf-8"
          (concat "Host: " host)
          "X-TC-Action: SentenceRecognition"
          "X-TC-Version: 2019-06-14"
          (concat "X-TC-Region: " chinese-speech-input-tencent-region)
          (concat "X-TC-Timestamp: " timestamp))))

(defun chinese-speech-input--tencent-text (result)
  "从腾讯云返回 RESULT 中提取文本；出错时返回 nil。"
  (let* ((response (alist-get 'Response result))
         (err (alist-get 'Error response)))
    (if err nil
      (alist-get 'Result response))))

(defun chinese-speech-input--tencent-error (result)
  "若 RESULT 为腾讯云错误响应，返回错误描述，否则 nil。"
  (let* ((response (alist-get 'Response result))
         (err (alist-get 'Error response)))
    (when err
      (format "腾讯云 ASR 错误 [%s]: %s"
              (alist-get 'Code err)
              (alist-get 'Message err)))))

;;; ---- 统一入口 ----

(defun chinese-speech-input--backend-request (filename context callback)
  "把 FILENAME 交给当前后端。CONTEXT 为提示词列表。
同步（CALLBACK 为 nil）返回解析后的 JSON；否则异步调用 CALLBACK。"
  (pcase chinese-speech-input-asr-backend
    ('aliyun
     (unless chinese-speech-input-aliyun-api-key
       (error "未设置 DASHSCOPE_API_KEY"))
     (let* ((audio (chinese-speech-input--base64-file filename))
            (data-url (concat "data:audio/wav;base64," audio))
            (body (chinese-speech-input--aliyun-body data-url context))
            (headers (chinese-speech-input--aliyun-headers)))
       (chinese-speech-input--curl-json-post chinese-speech-input-aliyun-url
                                             headers body callback)))
    ('tencent
     (unless (and chinese-speech-input-tencent-secret-id
                  chinese-speech-input-tencent-secret-key)
       (error "未设置 TENCENT_SECRET_ID / TENCENT_SECRET_KEY"))
     (let* ((audio (chinese-speech-input--base64-file filename))
            (data-len (file-attribute-size (file-attributes filename)))
            (body (chinese-speech-input--tencent-body audio data-len context))
            (headers (chinese-speech-input--tencent-sign body)))
       (chinese-speech-input--curl-json-post
        (concat "https://" chinese-speech-input-tencent-host "/")
        headers body callback)))
    (_ (error "未知后端：%S" chinese-speech-input-asr-backend))))

(defun chinese-speech-input--result-text (result)
  "从原始 ASR 响应 RESULT 提取文本；失败时抛出错误。"
  (let ((tencent-err (chinese-speech-input--tencent-error result)))
    (cond
     (tencent-err (error "%s" tencent-err))
     ((eq chinese-speech-input-asr-backend 'tencent)
      (or (chinese-speech-input--tencent-text result) ""))
     (t
      (let ((text (chinese-speech-input--aliyun-text result)))
        (if (null text)
            (error "阿里云 Qwen-ASR 识别失败：%s"
                   (or (chinese-speech-input--aliyun-error result)
                       (format "%S" result)))
          text))))))

;;;###autoload
(defun chinese-speech-input-transcribe-sync (filename &optional context)
  "同步转写 FILENAME 为中文文本。
CONTEXT 为提示词字符串列表（如候选命令），用于提升识别准确率。"
  (chinese-speech-input--result-text
   (chinese-speech-input--backend-request filename context nil)))

;;;###autoload
(defun chinese-speech-input-transcribe (filename callback &optional context)
  "异步转写 FILENAME，完成后用识别文本调用 CALLBACK。
CONTEXT 为提示词字符串列表。"
  (chinese-speech-input--backend-request
   filename context
   (lambda (result)
     (funcall callback
              (condition-case nil
                  (chinese-speech-input--result-text result)
                (error nil))))))

(provide 'chinese-speech-input-transcribe)
;;; chinese-speech-input-transcribe.el ends here
