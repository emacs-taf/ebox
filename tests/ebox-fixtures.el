;;; ebox-fixtures.el --- Typed Ebox test fixtures -*- lexical-binding: t; -*-

;;; Commentary:
;; Test-only construction helpers.  They keep retained layout, publication,
;; and rollback tests on the canonical Text/Box/LayoutConfig model without
;; reintroducing removed public constructors.

;;; Code:

(require 'cl-lib)
(require 'ebox)

(defconst ebox-test--source-fields
  '(:source-handle :key :class :id)
  "Canonical source fields accepted by typed fixture nodes.")

(defconst ebox-test--direct-fields
  '(:region-id :selector-state :selector-attributes :surface-properties
    :scroll-offset :ebox-scroll-offset-controlled-p)
  "Private runtime fields used only by focused backend tests.")

(defconst ebox-test--non-style-fields
  (append '(:source-handle :host-ref :key :class :id
            :outer :content :ebox-content-node
            :item-gap :cross-align)
          ebox-test--direct-fields)
  "Fixture fields that do not enter the canonical Ebox style schema.")

(defun ebox-test--keep (plist keys)
  "Return PLIST entries whose keys occur in KEYS."
  (cl-loop for (key value) on plist by #'cddr
           when (memq key keys) append (list key value)))

(defun ebox-test--split-items (items)
  "Return `(PROPERTIES . CHILDREN)' from evaluated fixture ITEMS."
  (let (properties children)
    (while items
      (let ((item (pop items)))
        (if (keywordp item)
            (progn
              (unless items (error "Missing fixture value for %S" item))
              (setq properties
                    (append properties (list item (pop items)))))
          (push item children))))
    (cons properties (nreverse children))))

(defun ebox-test--without (plist keys)
  "Return PLIST without entries whose keys occur in KEYS."
  (cl-loop for (key value) on plist by #'cddr
           unless (memq key keys) append (list key value)))

(defun ebox-test--unquote (value)
  "Return VALUE without one inert source-level quote wrapper."
  (if (and (consp value)
           (eq (car value) 'quote)
           (null (cddr value)))
      (cadr value)
    value))

(defun ebox-test--normalize-properties (props)
  "Return fixture PROPS with source literals normalized.
The typed author boundary spells explicit no-wrap as `none'; old backend
fixtures used nil for the same engine condition."
  (cl-loop for (key value) on props by #'cddr
           append (list key
                        (if (and (eq key :wrap-mode) (null value))
                            'none
                          (ebox-test--unquote value)))))

(defun ebox-test--source-properties (props)
  "Return typed source metadata projected from fixture PROPS."
  (let ((source (ebox-test--keep props '(:key :class :id))))
    (when-let* ((handle (or (plist-get props :source-handle)
                            (plist-get props :host-ref))))
      (setq source (append source (list :source-handle handle))))
    source))

(defun ebox-test--declarations (tag props)
  "Return canonical TAG declarations from evaluated fixture PROPS."
  (ebox-style-compile-form
   tag (ebox-test--without props ebox-test--non-style-fields)))

(defun ebox-test--layout (tag props declarations)
  "Return TAG LayoutConfig from PROPS and DECLARATIONS."
  (ebox-layout-config-for-form
   tag
   (if (memq tag '(row column))
       (ebox-test--keep props '(:item-gap :cross-align))
     (ebox-style-declaration-properties
      declarations
      (lambda (property)
        (memq (plist-get property :name)
              (ebox-layout-config-property-names tag)))))))

(defun ebox-test--text (value &optional props)
  "Return one canonical Text fixture for VALUE and author PROPS."
  (let ((declarations (ebox-test--declarations 'text props)))
    (apply #'ebox-text-create
           (append (list :value value :declarations declarations)
                   (ebox-test--source-properties props)))))

(defun ebox-test--box-node (tag props children)
  "Return canonical Box form TAG from PROPS and CHILDREN."
  (let* ((props (ebox-test--normalize-properties props))
         (declarations (ebox-test--declarations tag props))
         (node
          (apply #'ebox-box-create
                 (append
                  (list :layout (ebox-test--layout tag props declarations)
                        :outer (or (plist-get props :outer) 'block)
                        :children children
                        :declarations declarations)
                  (ebox-test--source-properties props)))))
    (dolist (key ebox-test--direct-fields)
      (when (plist-member props key)
        (plist-put node key (copy-tree (plist-get props key)))))
    node))

(defun ebox-test-box (&rest props)
  "Return one typed Normal Box fixture from evaluated PROPS."
  (let* ((content-present-p (plist-member props :content))
         (content (plist-get props :content))
         (child (plist-get props :ebox-content-node))
         (children
          (cond
           (child (list child))
           (content-present-p
            (if (stringp content)
                (list (ebox-test--text content))
              (error "Fixture :content must be a string: %S" content)))
           (t nil))))
    (ebox-test--box-node 'box props children)))

(defun ebox-test-row (&rest items)
  "Return one typed Row fixture from evaluated ITEMS."
  (pcase-let ((`(,props . ,children) (ebox-test--split-items items)))
    (ebox-test--box-node 'row props (delq nil children))))

(defun ebox-test-column (&rest items)
  "Return one typed Column fixture from evaluated ITEMS."
  (pcase-let ((`(,props . ,children) (ebox-test--split-items items)))
    (ebox-test--box-node 'column props (delq nil children))))

(defun ebox-test-concat (left right)
  "Return a two-child typed Row fixture."
  (ebox-test-row left right))

(defun ebox-test-stack (top bottom)
  "Return a two-child typed Column fixture."
  (ebox-test-column top bottom))

(defun ebox-test-spacer (&rest props)
  "Return an empty typed Normal Box fixture."
  (apply #'ebox-test-box props))

(defun ebox-test-flex (&rest items)
  "Return one typed Flex fixture from evaluated ITEMS."
  (pcase-let ((`(,props . ,children) (ebox-test--split-items items)))
    (ebox-test--box-node 'flex props (delq nil children))))

(defun ebox-test-grid (&rest items)
  "Return one typed Grid fixture from evaluated ITEMS."
  (pcase-let ((`(,props . ,children) (ebox-test--split-items items)))
    (ebox-test--box-node 'grid props (delq nil children))))

(defun ebox-test-grid-fr (factor)
  "Return one fractional Grid track fixture."
  (list 'fr factor))

(defun ebox-test-flex-item (node &rest props)
  "Return NODE with direct Flex participation and Box properties from PROPS."
  (setq props (ebox-test--normalize-properties props))
  (unless (ebox-box-node-p node)
    (setq node (ebox-test--box-node 'box nil (list node))))
  (let* ((layout (ebox-box-node-layout node))
         (children (ebox-box-node-children node))
         (base (ebox-style-node-declarations node))
         (extra (ebox-test--declarations 'box props))
         (copy
          (apply #'ebox-box-create
                 (append
                  (list :layout layout :children children
                        :outer (ebox-tree-display-outer node)
                        :declarations
                        (ebox-style-merge-declarations base extra))
                  (ebox-test--source-properties node)))))
    copy))

(defun ebox-test--build-item (items)
  "Return one typed direct-child Box from old backend fixture ITEMS.
`item' never reaches production input; this test helper only projects its
participation properties onto the material child being exercised."
  (pcase-let* ((`(,props . ,children) (ebox-test--split-items items))
               (props (ebox-test--normalize-properties props)))
    (unless (= (length children) 1)
      (error "Ebox test item requires exactly one child: %S" items))
    (apply #'ebox-test-flex-item
           (ebox-test-build (car children)) props)))

(defun ebox-test--build-box-form (tag items)
  "Return one typed TAG Box fixture from old backend fixture ITEMS."
  (pcase-let* ((`(,props . ,child-forms) (ebox-test--split-items items))
               (props (ebox-test--normalize-properties props))
               (content-present-p (plist-member props :content))
               (content (plist-get props :content))
               (content-node (plist-get props :ebox-content-node))
               (props (ebox-test--without
                       props '(:content :ebox-content-node)))
               (children (mapcar #'ebox-test-build child-forms)))
    (when content-node
      (setq children (append children (list content-node))))
    (when content-present-p
      (unless (stringp content)
        (error "Ebox test :content must be a string: %S" content))
      (setq children (append children (list (ebox-test--text content)))))
    (ebox-test--box-node tag props children)))

(defun ebox-test-build (form)
  "Build canonical typed nodes from one backend test FORM.

This is deliberately not an author DSL.  It isolates retained-layout and
publication tests from source parsing while their compact historical fixture
data is migrated.  Production `ebox-build' remains strict and never accepts
`:content', `item', `concat', `stack', or `spacer'."
  (cond
   ((or (ebox-text-node-p form) (ebox-box-node-p form)) form)
   ((stringp form) (ebox-test--text form))
   ((not (and (consp form) (symbolp (car form))))
    (error "Invalid Ebox typed test form: %S" form))
   ((eq (car form) 'text)
    (pcase-let* ((`(,props . ,payloads)
                   (ebox-test--split-items (cdr form)))
                 (props (ebox-test--normalize-properties props)))
      (unless (and (= (length payloads) 1)
                   (stringp (car payloads)))
        (error "Ebox test text requires exactly one string payload: %S" form))
      (ebox-test--text (car payloads) props)))
   ((memq (car form) '(box row column flex grid))
    (ebox-test--build-box-form (car form) (cdr form)))
   ((eq (car form) 'item)
    (ebox-test--build-item (cdr form)))
   ((eq (car form) 'concat)
    (ebox-test--build-box-form 'row (cdr form)))
   ((eq (car form) 'stack)
    (ebox-test--build-box-form 'column (cdr form)))
   ((eq (car form) 'spacer)
    (ebox-test--build-box-form 'box (cdr form)))
   (t
    (error "Unknown Ebox typed test form: %S" (car form)))))

(provide 'ebox-fixtures)

;;; ebox-fixtures.el ends here
