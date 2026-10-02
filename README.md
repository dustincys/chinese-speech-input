# chinese-speech-input —— Emacs 中文语音输入

参照 [Sacha Chua 的 `speech-input`](https://sachachua.com/topic/speech-recognition/)
（本仓库 `../speech-input/`）的实现思路，做了一套**中文语音输入**方案：

1. 用 [Silero VAD](https://github.com/snakers4/silero-vad) 检测语音起止；
2. 用 `ffmpeg` 录制一句话（16 kHz 单声道 wav）；
3. 交给云端 ASR 转写成中文：
   - **阿里云百炼 Qwen-ASR**（`qwen3-asr-flash`），见
     [Qwen-ASR API 参考](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference)；
   - **腾讯云一句话识别**（`SentenceRecognition`），见
     [一句话识别](https://cloud.tencent.com/document/product/1093/35646)；
4. 把文本插入缓冲区，或用模糊匹配选中候选命令。

## 目录结构

| 文件 | 作用 |
| --- | --- |
| `chinese-speech-input.el` | 主文件：录音、插入文本、中文模糊匹配、命令选择 |
| `chinese-speech-input-transcribe.el` | ASR 后端：阿里云 Qwen-ASR / 腾讯云一句话识别 |
| `chinese-speech-input-vad.el` | Silero VAD 封装 |
| `vad-events.py` | VAD 事件脚本（输出 `START` / `END`） |
| `chinese-speech-input-test.el` | `ert` 单元测试（模糊匹配） |

## 依赖

- GNU Emacs（24.4+，需内置 `json.el` / `base64` / `secure-hash`；已在 Emacs 31 测试）
- `ffmpeg`（录音）
- `curl`（调 API）
- Python 3 虚拟环境（仅 VAD 用，不依赖云端识别）：
  ```bash
  cd chinese-speech-input
  python3 -m venv .venv
  .venv/bin/pip install sounddevice numpy torch
  ```
  首次运行 `vad-events.py` 时会自动下载 Silero VAD 模型（需联网）。

## 云端凭证

任选一个后端，通过 `chinese-speech-input-asr-backend` 选择：

```elisp
;; 阿里云（默认）
(setq chinese-speech-input-asr-backend 'aliyun)
(setq chinese-speech-input-aliyun-api-key "sk-xxxx")   ; 或设置环境变量 DASHSCOPE_API_KEY

;; 腾讯云
(setq chinese-speech-input-asr-backend 'tencent)
(setq chinese-speech-input-tencent-secret-id  "AKIDxxxx")
(setq chinese-speech-input-tencent-secret-key "xxxx")
;; 也支持环境变量 TENCENT_SECRET_ID / TENCENT_SECRET_KEY（或 TENCENTCLOUD_*）
```

> 阿里云百炼 API Key 申请：https://help.aliyun.com/zh/model-studio/get-api-key
> 腾讯云密钥申请：https://console.cloud.tencent.com/cam/capi

## 安装

```elisp
(add-to-list 'load-path "~/github/spi/chinese-speech-input")
(require 'chinese-speech-input)
```

## 使用

| 命令 | 作用 |
| --- | --- |
| `M-x chinese-speech-input-insert-once` | 说一句话，把识别出的中文插入当前缓冲区 |
| `M-x chinese-speech-input-vad-start` | 启动 VAD（`insert-once` 会自动启动） |
| `M-x chinese-speech-input-vad-toggle-debug` | 开关语音起止调试提示 |
| `M-x chinese-speech-input-cancel-recording` | 丢弃当前录音 |

命令选择（把语音匹配到候选列表）：

```elisp
;; 是/否
(chinese-speech-input-from-list
 "是或否？"
 '(("是" "是" "对" "好" "可以") ("否" "否" "不" "不用" "不要"))
 (lambda (result text) (message "你选了：%s（原文：%s）" result text)))

;; 常用命令
(chinese-speech-input-from-list
 "说一个命令"
 '(("打开文件" "打开文件" "开启文件")
   ("保存文件" "保存文件" "存储")
   ("退出" "退出" "关闭"))
 (lambda (result _text) (message "执行：%s" result)))

;; 一句话选多个标签
(chinese-speech-input-multiple-from-list
 "说标签"
 '(("编程" "编程" "代码") ("写作" "写作") ("阅读" "阅读"))
 (lambda (value _prev) (message "选中：%s" value))
 (lambda (values _text) (message "全部：%S" values)))
```

`collection` 支持三种写法：字符串列表、`(结果 . 候选)`、`(结果 候选1 候选2 ...)`。

## 关键配置

```elisp
;; 后端与语种
(setq chinese-speech-input-asr-backend 'aliyun)
(setq chinese-speech-input-language "zh")   ; zh 普通话 / yue 粤语

;; 阿里云
(setq chinese-speech-input-aliyun-model "qwen3-asr-flash")
(setq chinese-speech-input-aliyun-enable-itn nil) ; t 则中文数字转阿拉伯数字

;; 腾讯云
(setq chinese-speech-input-tencent-engine "16k_zh")   ; 16k_zh / 16k_zh-PY / 16k_yue
(setq chinese-speech-input-tencent-region "ap-guangzhou")
(setq chinese-speech-input-tencent-convert-num-mode 0) ; 0 中文数字，1 阿拉伯数字
(setq chinese-speech-input-tencent-filter-punc 0)      ; 0 保留标点，2 去掉全部标点

;; 模糊匹配阈值：0 完全匹配；0.3 允许约 30% 字符差异
(setq chinese-speech-input-string-distance-threshold 0.3)

;; 录音源（若麦克风不是 PulseAudio 的 default，请修改）
(setq chinese-speech-input-recording-command
      '("ffmpeg" "-y" "-f" "pulse" "-i" "default" "-f" "wav" "-ar" "16000" "-ac" "1"))
```

## 实现说明

- **转写**：`chinese-speech-input-transcribe-sync` 把 wav 文件 base64 后：
  - 阿里云走 **OpenAI 兼容模式**
    `POST /compatible-mode/v1/chat/completions`，模型 `qwen3-asr-flash`，
    音频用 `input_audio` 内容块（`data:audio/wav;base64,...`），
    并可用 `system` 消息传入候选词作上下文；
  - 腾讯云走 `SentenceRecognition`（`SourceType=1` 上传语音数据），
    用 **TC3-HMAC-SHA256** 签名（`content-type;host` 参与签名）。
- **模糊匹配**：`chinese-speech-input-normalize-string` 只保留汉字/字母/数字，
  用字符级 `string-distance`（Levenshtein）比较，适合中文无空格分词的场景；
  `match-first-part` / `match-all` 按“字符前缀”而非“单词”切分。
- **VAD**：与语种无关，直接复用 Silero VAD（`vad-events.py` 与上游一致）。

## 测试

```bash
cd chinese-speech-input
emacs --batch -L . -l chinese-speech-input-test.el --eval '(ert-run-tests-batch-and-exit)'
```

## 限制

- 阿里云 `qwen3-asr-flash` 单次最长约 5 分钟；腾讯云一句话识别音频 ≤ 60 秒、≤ 3 MB。
  本方案按“一句话”录制，通常远小于该限制。
- 阿里云本地文件上传接口有 100 QPS 限制，个人使用足够。
- 暂未做简繁转换；同音字纠错主要靠云端模型与候选热词。
