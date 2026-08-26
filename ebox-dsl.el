;;; ebox-dsl.el --- DSL compiler facade for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns `.ebox` DSL compilation and compatibility sugar over the Ebox element
;; and style models.  It does not own core render or buffer patch execution.

;;; Code:

(require 'cl-lib)
(require 'ebox-style)
(require 'ebox-tree)
(require 'ebox-flex)
(require 'ebox-grid)

(declare-function ebox-create "ebox" (&rest plist))

(defconst ebox-dsl--outer-values '(inline block)
  "Valid outer participation values for the canonical Box DSL.")

(defconst ebox-dsl--layout-values '(normal row column flex grid)
  "Valid child layout values for the canonical Box DSL.")

(defun ebox--dsl-unquote-value (value)
  "Unquote one static DSL property VALUE when it is quoted data."
  (if (and (consp value)
           (eq (car value) 'quote)
           (null (cddr value)))
      (cadr value)
    value))

(defun ebox--dsl-unquote-properties (items)
  "Unquote static property values in top-level DSL ITEMS.
Structural child forms remain untouched; only values immediately following
keyword properties are normalized."
  (let (result)
    (while items
      (let ((item (pop items)))
        (if (keywordp item)
            (progn
              (unless items
                (error "ebox-build: missing value for %S" item))
              (push item result)
              (push (ebox--dsl-unquote-value (pop items)) result))
          (push item result))))
    (nreverse result)))

(defun ebox-dsl--axis-value (props property default allowed)
  "Return PROPS PROPERTY or DEFAULT after validating it against ALLOWED."
  (let ((value (if (plist-member props property)
                   (plist-get props property)
                 default)))
    (unless (memq value allowed)
      (error "ebox-build: invalid %S value %S" property value))
    value))

(defun ebox-dsl--with-display (node outer layout)
  "Return a shallow copy of NODE with canonical OUTER and LAYOUT display."
  (let ((copy (copy-sequence node)))
    (plist-put copy :display
               (list outer (if (eq layout 'normal) 'flow layout)))
    copy))

(defun ebox--build-children-layout (children)
  "Build a vertical default layout from CHILDREN."
  (setq children (delq nil children))
  (cond
   ((null children) nil)
   ((null (cdr children)) (ebox-dsl-build (car children)))
   (t (apply #'ebox-column (mapcar #'ebox-dsl-build children)))))

(defun ebox--build-box-content (children &optional _props)
  "Return content or child layout represented by DSL CHILDREN.
The first value is string content.  The second value is a lazy child node."
  (setq children (delq nil children))
  (cond
   ((null children)
    (cl-values nil nil))
   ((cl-every #'stringp children)
    (cl-values (string-join children "\n") nil))
   (t
    (cl-values nil (ebox--build-children-layout children)))))

(defun ebox--build-box (items)
  "Build a box node from DSL ITEMS."
  (let* ((split (ebox--build-split-attrs items))
         (props (car split))
         (children (cdr split)))
    (cl-multiple-value-bind (content child-node)
        (ebox--build-box-content children props)
      (when (and (or content child-node) (plist-member props :content))
        (error "ebox-build: box cannot combine :content with child nodes"))
      (apply #'ebox-create
             (append (if child-node
                         (ebox--preformatted-box-props props)
                       props)
                     (when content (list :content content))
                     (when child-node
                       (list :ebox-content-node child-node)))))))

(defun ebox--build-wrap-layout (tag props layout)
  "Wrap LAYOUT with box PROPS for DSL TAG, or return LAYOUT unchanged."
  (if (null props)
      layout
    (when (plist-member props :content)
      (error "ebox-build: %S cannot combine :content with child nodes" tag))
    (apply #'ebox-create
           (append (ebox--preformatted-box-props props)
                   (list :display '(block flow)
                         :ebox-content-node layout)))))

(defun ebox--build-layout (tag constructor items)
  "Build a row/column layout TAG with CONSTRUCTOR from DSL ITEMS."
  (let* ((split (ebox--build-split-attrs items))
         (props (car split))
         (children (cdr split))
         (layout
          (apply constructor
                 (mapcar (lambda (child)
                           (if (ebox-child-range--descriptor-p child)
                               child
                             (ebox-dsl-build child)))
                         (delq nil children)))))
    (ebox--build-wrap-layout tag props layout)))

(defun ebox--build-flex (items)
  "Build a flex node from DSL ITEMS."
  (let* ((split (ebox--build-split-attrs items))
         (props (car split))
         (children (mapcar #'ebox-dsl-build (delq nil (cdr split)))))
    (apply #'ebox-flex (append props children))))

(defun ebox--build-flex-item (items)
  "Build a flex item wrapper from DSL ITEMS."
  (let* ((split (ebox--build-split-attrs items))
         (props (car split))
         (children (cdr split))
         (item-props (ebox--plist-keep-keys props ebox--flex-item-prop-keys))
         (box-props (ebox--plist-remove-keys props ebox--flex-item-prop-keys)))
    (unless children
      (error "ebox-build: item requires a child node"))
    (let ((child (ebox--flex-wrap-node-with-box-props
                  'item (ebox--build-children-layout children) box-props)))
      (dolist (key ebox--flex-item-prop-keys)
        (when (plist-member item-props key)
          (plist-put child key (plist-get item-props key))))
      (apply #'ebox-flex-item child item-props))))

(defun ebox--build-grid-item (items)
  "Build a grid-item node from DSL ITEMS."
  (let* ((split (ebox-grid--split-attrs items))
         (props (car split))
         (children (delq nil (cdr split))))
    (unless (= (length children) 1)
      (error "ebox-build: grid-item requires exactly one child node"))
    (apply #'ebox-grid-item
           (ebox-dsl-build (car children))
           props)))

(defun ebox--build-grid (items)
  "Build a grid node from DSL ITEMS."
  (let* ((split (ebox-grid--split-attrs items))
         (props (car split))
         (children (mapcar #'ebox-dsl-build (delq nil (cdr split)))))
    (apply #'ebox-grid (append props children))))

(defun ebox--build-spacer (items)
  "Build a spacer node from DSL ITEMS."
  (let* ((split (ebox--build-split-attrs items))
         (props (car split))
         (children (cdr split)))
    (when children
      (error "ebox-build: spacer cannot have child nodes"))
    (when (plist-member props :content)
      (error "ebox-build: spacer cannot set :content"))
    (apply #'ebox-spacer props)))

(defun ebox--build-canonical-box (items)
  "Build canonical Box ITEMS with orthogonal outer and layout axes."
  (let* ((split (ebox--build-split-attrs items))
         (props (car split))
         (children (cdr split))
         (outer (ebox-dsl--axis-value
                 props :outer 'block ebox-dsl--outer-values))
         (layout (ebox-dsl--axis-value
                  props :layout 'normal ebox-dsl--layout-values))
         (box-props (ebox--plist-remove-keys props '(:outer :layout)))
         node)
    (setq node
          (pcase layout
            ('normal
             (ebox--build-box (append box-props children)))
            ('row
             (ebox--build-layout
              'box #'ebox-row (append box-props children)))
            ('column
             (ebox--build-layout
              'box #'ebox-column (append box-props children)))
            ('flex
             (ebox--build-flex (append box-props children)))
            ('grid
             (ebox--build-grid (append box-props children)))))
    (ebox-dsl--with-display node outer layout)))

(defun ebox-dsl-build (dsl)
  "Build an Ebox node from an ETML-style list DSL.

Supported forms:
  (box :content \"Hello\" :width (160))
  (box :content \"Fits preview\" :width (viewport))
  (box :width (240) (row (box \"A\") (box \"B\")))
  (row (box :content \"Left\") (spacer :width (16)) (box :content \"Right\"))
  (column (box :content \"Top\") (box :content \"Bottom\"))
  (grid :grid-template-columns ((80) (80))
        (grid-item :grid-column (1 :span 2) (box \"Header\")))
  (flex :width (320) :gap (1 (12)) (item :flex 1 (box \"A\")))

`box' and `ebox' create `ebox-create' nodes.  `row', `column',
`flex', and `spacer' compile to existing Ebox layout helpers.  `row'
and `column' may also receive box properties; those properties wrap
the child layout in a box using the rendered child layout as content."
  (cond
   ((ebox--node-p dsl) dsl)
   ((stringp dsl) (ebox-create :content dsl))
   ((not (and (consp dsl) (symbolp (car dsl))))
    (error "ebox-build: invalid DSL node %S" dsl))
   (t
    (let ((tag (car dsl))
          (items (ebox--dsl-unquote-properties (cdr dsl))))
      (pcase tag
        ('box (ebox--build-canonical-box items))
        ('ebox (ebox--build-box items))
        ('row (ebox--build-layout tag #'ebox-row items))
        ('column (ebox--build-layout tag #'ebox-column items))
        ('flex (ebox--build-flex items))
        ('item (ebox--build-flex-item items))
        ('grid-item (ebox--build-grid-item items))
        ('spacer (ebox--build-spacer items))
        ('grid (ebox--build-grid items))
        (_ (error "ebox-build: unknown DSL tag %S" tag)))))))

(provide 'ebox-dsl)

;;; ebox-dsl.el ends here
