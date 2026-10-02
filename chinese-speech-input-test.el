;;; chinese-speech-input-test.el --- 测试                     -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: SPI 中文语音输入
;; Keywords:

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

;;

;;; Code:

(require 'ert)
(require 'chinese-speech-input)

(ert-deftest chinese-speech-input-normalize-string ()
  "测试中文归一化。"
  (should (equal (chinese-speech-input-normalize-string "你好，世界！")
                 "你好世界"))
  (should (equal (chinese-speech-input-normalize-string "Hello 世界123")
                 "hello世界123"))
  (should (equal (chinese-speech-input-normalize-string "打开文件。")
                 "打开文件"))
  (should (equal (chinese-speech-input-normalize-string "ＡＢＣ，测试")
                 "测试")))

(ert-deftest chinese-speech-input-match-in-list ()
  "测试单候选模糊匹配。"
  (let ((chinese-speech-input-string-distance-threshold 0.3))
    (should (equal (chinese-speech-input-match-in-list "打开文件"
                                                       '("打开文件" "关闭文件" "保存文件"))
                   "打开文件"))
    ;; 一字之差（4 字中错 1 字），应仍能匹配
    (should (equal (chinese-speech-input-match-in-list "打开文见"
                                                       '("打开文件" "关闭文件"))
                   "打开文件"))
    ;; 完全不匹配时原样返回
    (should (equal (chinese-speech-input-match-in-list "随便说说"
                                                       '("打开文件" "关闭文件"))
                   "随便说说"))
    ;; 候选别名
    (should (equal (chinese-speech-input-match-in-list "开启"
                                                       '(("打开" "打开" "开启" "启动")))
                   "打开"))))

(ert-deftest chinese-speech-input-match-first-part ()
  "测试开头匹配（按字符）。"
  (let ((chinese-speech-input-string-distance-threshold 0.3))
    (should (equal (chinese-speech-input-match-first-part
                    "打开文件保存文件"
                    '("打开文件" "保存文件" "关闭文件"))
                   '("打开文件" . "保存文件")))
    ;; 别名匹配，且优先更长的候选
    (should (equal (chinese-speech-input-match-first-part
                    "打开文件"
                    '("打开" "打开文件"))
                   '("打开文件" . "")))))

(ert-deftest chinese-speech-input-match-all ()
  "测试多候选匹配。"
  (let ((chinese-speech-input-string-distance-threshold 0.3))
    (should (equal (chinese-speech-input-match-all
                    "打开文件保存文件"
                    '("打开文件" "保存文件" "关闭文件"))
                   '("打开文件" "保存文件")))
    (should (equal (chinese-speech-input-match-all
                    "启动程序然后保存"
                    '(("打开" "打开" "启动" "开启")
                      ("保存" "保存" "存储")))
                   '("打开" "保存")))))

(ert-deftest chinese-speech-input--reshape-collection ()
  "测试集合形状归一化。"
  (should (equal (chinese-speech-input--reshape-collection
                  '("甲" ("乙" "乙一" "乙二") ("丙" . "丙一")))
                 '(("甲" "甲") ("乙" "乙一" "乙二") ("丙" "丙一")))))

(provide 'chinese-speech-input-test)
;;; chinese-speech-input-test.el ends here
