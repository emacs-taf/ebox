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

(defun ebox-node-factory--create-expanded (expanded declarations)
  "Create one runtime box from EXPANDED engine facts and DECLARATIONS."
  (let ((controlled-scroll-offset-p
         (plist-member expanded :scroll-offset)))
    (let ((box (copy-sequence ebox-node-factory--box-longhand)))
      (cl-loop for (property value) on expanded by #'cddr
               do (plist-put box property value))
      (plist-put box :ebox-type 'box)
      (plist-put box :display '(block flow))
      (plist-put box :ebox-style-declarations (copy-sequence declarations))
      (when controlled-scroll-offset-p
        (plist-put box :ebox-scroll-offset-controlled-p t))
      box)))

(defun ebox-node-factory--create-text-expanded (expanded declarations)
  "Create canonical Text storage from EXPANDED facts and DECLARATIONS."
  (let ((node (copy-sequence ebox-node-factory--text-longhand)))
    (cl-loop for (property value) on expanded by #'cddr
             do (plist-put node property value))
    (plist-put node :ebox-type 'box)
    (plist-put node :display '(inline flow))
    (plist-put node :ebox-style-declarations (copy-sequence declarations))
    node))

(defun ebox-node-factory--create (plist declarations)
  "Create one runtime box from normalized PLIST and DECLARATIONS.
PLIST contains already-validated public engine inputs; DECLARATIONS are the
single canonical author fact set retained for style projection."
  (ebox-node-factory--create-expanded
   (ebox-style-expand-ebox-plist plist) declarations))

(defun ebox-node-factory--create-from-properties (&rest plist)
  "Create one private runtime box from evaluated engine PLIST."
  (ebox-node-factory--create
   plist (ebox-style-compile-declarations plist)))

(provide 'ebox-node-factory)

;;; ebox-node-factory.el ends here
