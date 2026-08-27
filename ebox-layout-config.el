;;; ebox-layout-config.el --- Typed Box layout selection -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the small backend-neutral value that selects one Box child-layout
;; algorithm.  Layout modules construct validated variants; the value itself
;; carries no runtime identity, children, measurement, or publication state.

;;; Code:

(require 'cl-lib)
(require 'seq)

(declare-function ebox-flex-layout-config-props-p
                  "ebox-flex" (props))
(declare-function ebox-grid-layout-config-props-p
                  "ebox-grid" (props))
(declare-function ebox-flex-layout-create "ebox-flex" (&rest plist))
(declare-function ebox-grid-layout-create "ebox-grid" (&rest plist))

(cl-defstruct
    (ebox-layout-config
     (:constructor ebox-layout-config--create))
  "Canonical typed layout selection for one BoxNode."
  kind
  props)

(defconst ebox-layout-config--simple-cross-align-values
  '(start center end stretch)
  "Canonical Row/Column cross-axis alignment values.")

(defun ebox-layout-config--simple-axis-props-p (props)
  "Return non-nil when PROPS is canonical Row/Column config data."
  (and (equal (mapcar #'car (seq-partition props 2))
              '(:item-gap :cross-align))
       (let ((gap (plist-get props :item-gap))
             (align (plist-get props :cross-align)))
         (and (integerp gap) (>= gap 0)
              (memq align ebox-layout-config--simple-cross-align-values)))))

(defun ebox-layout-config--simple-axis-create (kind plist)
  "Return validated simple-axis KIND LayoutConfig from PLIST."
  (unless (and (proper-list-p plist) (zerop (% (length plist) 2)))
    (error "Ebox %S LayoutConfig requires an even plist: %S" kind plist))
  (let ((seen (make-hash-table :test #'eq)))
    (cl-loop for (key _value) on plist by #'cddr
             unless (memq key '(:item-gap :cross-align))
             do (error "Ebox %S LayoutConfig does not accept %S" kind key)
             do (when (gethash key seen)
                  (error "Duplicate Ebox %S LayoutConfig property: %S" kind key))
             do (puthash key t seen)))
  (let ((props
         (list :item-gap (if (plist-member plist :item-gap)
                             (plist-get plist :item-gap)
                           0)
               :cross-align (if (plist-member plist :cross-align)
                                (plist-get plist :cross-align)
                              'stretch))))
    (unless (ebox-layout-config--simple-axis-props-p props)
      (error "Invalid Ebox %S LayoutConfig properties: %S" kind props))
    (ebox-layout-config--create :kind kind :props props)))

(defun ebox-layout-config-validate (config)
  "Return CONFIG after revalidating its variant-owned properties."
  (unless (ebox-layout-config-p config)
    (error "Expected an Ebox LayoutConfig: %S" config))
  (let* ((kind (ebox-layout-config-kind config))
         (props (ebox-layout-config-props config))
         (valid-p
          (pcase kind
            ('normal (null props))
            ((or 'row 'column)
             (ebox-layout-config--simple-axis-props-p props))
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
(defun ebox-row-layout-create (&rest plist)
  "Return canonical RowConfig from evaluated PLIST."
  (ebox-layout-config--simple-axis-create 'row plist))

;;;###autoload
(defun ebox-column-layout-create (&rest plist)
  "Return canonical ColumnConfig from evaluated PLIST."
  (ebox-layout-config--simple-axis-create 'column plist))

(defun ebox-layout-config-property-names (tag)
  "Return canonical property names owned by TAG's LayoutConfig."
  (pcase tag
    ('flex
     '(:flex-direction :flex-wrap :justify-content
       :align-items :align-content :row-gap :column-gap))
    ('grid
     '(:grid-template-columns :grid-template-rows
       :grid-auto-columns :grid-auto-rows :grid-auto-flow
       :row-gap :column-gap
       :justify-items :align-items :justify-content :align-content))
    ((or 'box 'row 'column) nil)
    (_ (error "Unknown Ebox Box author form: %S" tag))))

(defun ebox-layout-config-for-form (tag properties)
  "Return TAG's typed LayoutConfig from evaluated layout PROPERTIES."
  (pcase tag
    ('box
     (when properties
       (error "Ebox Normal layout does not accept config properties: %S"
              properties))
     (ebox-normal-layout-create))
    ('row (apply #'ebox-row-layout-create properties))
    ('column (apply #'ebox-column-layout-create properties))
    ('flex (apply #'ebox-flex-layout-create properties))
    ('grid (apply #'ebox-grid-layout-create properties))
    (_ (error "Unknown Ebox Box author form: %S" tag))))

(provide 'ebox-layout-config)

;;; ebox-layout-config.el ends here
