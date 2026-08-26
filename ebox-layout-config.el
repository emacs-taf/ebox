;;; ebox-layout-config.el --- Typed Box layout selection -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the small backend-neutral value that selects one Box child-layout
;; algorithm.  Layout modules construct validated variants; the value itself
;; carries no runtime identity, children, measurement, or publication state.

;;; Code:

(require 'cl-lib)

(declare-function ebox-flex-layout-config-props-p
                  "ebox-flex" (props))
(declare-function ebox-grid-layout-config-props-p
                  "ebox-grid" (props))

(cl-defstruct
    (ebox-layout-config
     (:constructor ebox-layout-config--create))
  "Canonical typed layout selection for one BoxNode."
  kind
  props)

(defun ebox-layout-config-validate (config)
  "Return CONFIG after revalidating its variant-owned properties."
  (unless (ebox-layout-config-p config)
    (error "Expected an Ebox LayoutConfig: %S" config))
  (let* ((kind (ebox-layout-config-kind config))
         (props (ebox-layout-config-props config))
         (valid-p
          (pcase kind
            ((or 'normal 'row 'column) (null props))
            ('flex
             (and (fboundp 'ebox-flex-layout-config-props-p)
                  (ebox-flex-layout-config-props-p props)))
            ('grid
             (and (fboundp 'ebox-grid-layout-config-props-p)
                  (ebox-grid-layout-config-props-p props)))
            (_ nil))))
    (unless valid-p
      (error "Invalid %S LayoutConfig properties: %S"
             kind props)))
  config)

(defun ebox-layout-config--copy (config)
  "Return a detached copy of validated CONFIG."
  (ebox-layout-config-validate config)
  (ebox-layout-config--create
   :kind (ebox-layout-config-kind config)
   :props (copy-tree (ebox-layout-config-props config))))

;;;###autoload
(defun ebox-normal-layout-create ()
  "Return the canonical Normal layout config."
  (ebox-layout-config--create :kind 'normal :props nil))

;;;###autoload
(defun ebox-row-layout-create ()
  "Return the canonical Row layout config."
  (ebox-layout-config--create :kind 'row :props nil))

;;;###autoload
(defun ebox-column-layout-create ()
  "Return the canonical Column layout config."
  (ebox-layout-config--create :kind 'column :props nil))

(provide 'ebox-layout-config)

;;; ebox-layout-config.el ends here
