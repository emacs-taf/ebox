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
    :width nil :min-width auto :max-width nil
    :height nil :min-height auto :max-height nil
    :padding-left-pixel 0 :padding-right-pixel 0
    :padding-top-height 0 :padding-bottom-height 0
    :margin-left-pixel 0 :margin-right-pixel 0
    :margin-top-height 0 :margin-bottom-height 0
    :border-left-pixel 0 :border-left-style none :border-left-color nil
    :border-right-pixel 0 :border-right-style none :border-right-color nil
    :border-top-pixel 0 :border-top-style none :border-top-color nil
    :border-bottom-pixel 0 :border-bottom-style none :border-bottom-color nil
    :color nil :bgcolor nil
    :text-decoration-line none :text-decoration-color currentColor
    :text-decoration-style solid
    :text-align left :vertical-align top
    :overflow scroll :visibility visible
    :wrap-mode word :scroll-offset 0)
  "Default longhand fields for the current runtime box encoding.")

(defconst ebox-node-factory--style-projection-keys
  (let ((fields ebox--longhand)
        keys)
    (while fields
      (let ((key (pop fields)))
        (pop fields)
        (unless (memq key '(:content :scroll-offset))
          (push key keys))))
    (nreverse keys))
  "Private runtime fields materialized from canonical style facts.
These fields are projections, never declarative source authority.  Content and
scroll offset remain outside this set because their lifecycle is not owned by
style projection.")

(defconst ebox-node-factory--text-longhand
  '(:content ""
    :overflow visible
    :wrap-mode word)
  "Minimal runtime fields owned by canonical Text.")

(defconst ebox-node-factory--box-longhand
  '(:content ""
    :box-sizing border-box
    :min-width auto :min-height auto
    :padding-left-pixel 0 :padding-right-pixel 0
    :padding-top-height 0 :padding-bottom-height 0
    :margin-left-pixel 0 :margin-right-pixel 0
    :margin-top-height 0 :margin-bottom-height 0
    :border-left-pixel 0 :border-left-style none
    :border-right-pixel 0 :border-right-style none
    :border-top-pixel 0 :border-top-style none
    :border-bottom-pixel 0 :border-bottom-style none
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
   (ebox-style--expand-engine-plist plist)))

(provide 'ebox-node-factory)

;;; ebox-node-factory.el ends here
