;;; ebox-node-factory.el --- Runtime box node factory -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the legacy runtime box encoding used by render/layout modules during
;; the typed canonical migration.  Higher programmatic constructors may lower
;; through this factory, but author DSL parsing and buffer publication do not
;; belong here.

;;; Code:

(require 'ebox-style)

(defconst ebox--longhand
  '(:content ""
    :box-sizing border-box
    :width nil :min-width 0 :max-width nil
    :height nil :min-height 0 :max-height nil
    :padding-left-pixel 0 :padding-right-pixel 0
    :padding-top-height 0 :padding-bottom-height 0
    :margin-left-pixel 0 :margin-right-pixel 0
    :margin-top-height 0 :margin-bottom-height 0
    :border-left-pixel 0 :border-left-color nil
    :border-right-pixel 0 :border-right-color nil
    :border-top-p nil :border-top-color nil
    :border-bottom-p nil :border-bottom-color nil
    :color nil :bgcolor nil
    :font nil :font-family nil :font-height nil
    :font-weight nil :font-slant nil
    :text-align left :vertical-align top
    :overflow scroll :visibility visible
    :wrap-mode word :scroll-offset 0)
  "Default longhand fields for the current runtime box encoding.")

(defun ebox--longhand-create (&optional plist)
  "Return a runtime box field plist overridden by PLIST."
  (let ((box (copy-sequence ebox--longhand)))
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (plist-put box key value)))
    box))

;;;###autoload
(defun ebox-create (&rest plist)
  "Create one legacy runtime box from PLIST.

New framework integrations should use `ebox-text-create' and
`ebox-box-create'.  This factory remains public during source-tree migration."
  (let ((declarations (ebox-style-compile-declarations plist))
        (expanded (ebox-style-expand-ebox-plist plist))
        (controlled-scroll-offset-p (plist-member plist :scroll-offset)))
    (let ((box (ebox--longhand-create expanded)))
      (plist-put box :ebox-type 'box)
      (plist-put box :display '(block flow))
      (plist-put box :ebox-style-declarations declarations)
      (when controlled-scroll-offset-p
        (plist-put box :ebox-scroll-offset-controlled-p t))
      box)))

(provide 'ebox-node-factory)

;;; ebox-node-factory.el ends here
