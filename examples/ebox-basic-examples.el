;;; ebox-basic-examples.el --- Basic Ebox examples -*- lexical-binding: t; -*-

;;; Commentary:

;; Load this file after adding the repository root to `load-path', then run
;; `M-x ebox-basic-examples-open'.  The example intentionally uses `:wrap-mode
;; kp' to exercise the optional ekp-backed wrapping path while still loading
;; cleanly when ekp is unavailable.

;;; Code:

(require 'ebox)

(defconst ebox-basic-examples-long-text
  "作为可嵌入 Emacs buffer 的文本 UI 组件，Ebox 负责把普通字符串渲染成稳定的像素宽度盒子。这个示例混合中文、English words 和标点，用来验证 CJK 换行、kp wrap、padding、margin 与 border 在同一个盒子里的组合效果。")

(defun ebox-basic-examples-build ()
  "Return the basic example layout node."
  (ebox-build
   `(box :content ,ebox-basic-examples-long-text
         :margin 2
         :margin-top 1
         :padding (0 2)
         :width (410)
         :border "gray"
         :wrap-mode kp)))

(defun ebox-basic-examples-render ()
  "Render the basic example to a propertized string."
  (ebox-render (ebox-basic-examples-build)))

;;;###autoload
(defun ebox-basic-examples-open ()
  "Open the basic Ebox example buffer."
  (interactive)
  (ebox-display-buffer "*ebox-basic-examples*"
    (ebox-basic-examples-build)))

(provide 'ebox-basic-examples)
;;; ebox-basic-examples.el ends here
