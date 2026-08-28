;;; ebox-node-factory.el --- Runtime box node factory -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns private runtime box storage used by render/layout modules.  Higher
;; programmatic constructors may lower through this factory, but author source
;; facts, DSL parsing, and buffer publication do not belong here.

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

(defconst ebox-node-factory--text-longhand
  '(:content ""
    :overflow visible
    :wrap-mode word)
  "Minimal runtime fields owned by canonical Text.")

(defconst ebox-node-factory--box-longhand
  '(:content ""
    :box-sizing border-box
    :min-width 0 :min-height 0
    :padding-left-pixel 0 :padding-right-pixel 0
    :padding-top-height 0 :padding-bottom-height 0
    :margin-left-pixel 0 :margin-right-pixel 0
    :margin-top-height 0 :margin-bottom-height 0
    :border-left-pixel 0 :border-right-pixel 0
    :text-align left :vertical-align top
    :overflow scroll :visibility visible
    :wrap-mode word :scroll-offset 0)
  "Runtime-required defaults owned by canonical Box.
Nil paint and optional sizing fields remain sparse.  Numeric frame insets are
materialized because every layout algorithm consumes them as definite values;
leaving them absent would make the canonical node violate the Box contract.")

(defun ebox--longhand-create (&optional plist)
  "Return a runtime box field plist overridden by PLIST."
  (let ((box (copy-sequence ebox--longhand)))
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (plist-put box key value)))
    box))

(defun ebox-node-factory--create-expanded (expanded)
  "Create one runtime box from EXPANDED engine facts."
  (let ((controlled-scroll-offset-p
         (plist-member expanded :scroll-offset)))
    (let ((box (copy-sequence ebox-node-factory--box-longhand)))
      (cl-loop for (property value) on expanded by #'cddr
               do (plist-put box property value))
      (plist-put box :ebox-type 'box)
      (plist-put box :display '(block flow))
      (when controlled-scroll-offset-p
        (plist-put box :ebox-scroll-offset-controlled-p t))
      box)))

(defun ebox-node-factory--create-text-expanded (expanded)
  "Create canonical Text storage from EXPANDED facts."
  (let ((node (copy-sequence ebox-node-factory--text-longhand)))
    (cl-loop for (property value) on expanded by #'cddr
             do (plist-put node property value))
    (plist-put node :ebox-type 'box)
    (plist-put node :display '(inline flow))
    node))

(defun ebox-node-factory--create-from-properties (&rest plist)
  "Create one private runtime box from evaluated engine PLIST."
  (ebox-node-factory--create-expanded
   (ebox-style-expand-ebox-plist plist)))

(provide 'ebox-node-factory)

;;; ebox-node-factory.el ends here
