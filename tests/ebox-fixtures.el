;;; ebox-fixtures.el --- Typed Ebox test fixtures -*- lexical-binding: t; -*-

;;; Commentary:
;; Test-only construction helpers.  They keep retained layout, publication,
;; and rollback tests on the canonical Text/Box/LayoutConfig model without
;; reintroducing removed public constructors.

;;; Code:

(require 'cl-lib)
(require 'ebox)

(defconst ebox-test--source-fields
  '(:source-identity :key :class :id
    :selector-state :selector-attributes)
  "Author source fields owned by opaque fixture source handles.")

(defconst ebox-test--direct-fields
  '(:region-id :surface-properties :scroll-offset
    :ebox-scroll-offset-controlled-p)
  "Private runtime fields used only by focused backend tests.")

(defconst ebox-test--non-style-fields
  (append ebox-test--source-fields
          '(:outer :item-gap :cross-align)
          ebox-test--direct-fields)
  "Fixture fields that do not enter the canonical Ebox style schema.")

(defun ebox-test-root (input)
  "Return the single canonical root owned by fixture INPUT."
  (ebox-canonical-input--single-root input "Ebox test fixture"))

(defun ebox-test-forest (input)
  "Return fixture INPUT's ordered canonical forest."
  (unless (ebox-canonical-input-p input)
    (signal 'wrong-type-argument (list 'ebox-canonical-input-p input)))
  (copy-sequence (ebox-canonical-input--nodes input)))

(defun ebox-test-source-index (input)
  "Return the immutable source generation owned by fixture INPUT."
  (unless (ebox-canonical-input-p input)
    (signal 'wrong-type-argument (list 'ebox-canonical-input-p input)))
  (ebox-canonical-input--source-index input))

(defun ebox-test-child-range (range-ref &rest inputs)
  "Return a test Range descriptor over canonical INPUTS.
The descriptor is consumed only by a fixture parent, which imports every input
source generation before lowering the descriptor to raw canonical nodes."
  (unless range-ref
    (error "Ebox test Range ref must be non-nil"))
  (dolist (input inputs)
    (unless (ebox-canonical-input-p input)
      (signal 'wrong-type-argument (list 'ebox-canonical-input-p input))))
  (ebox-child-range--descriptor-create range-ref inputs))

(defun ebox-test-forest-input (&rest inputs)
  "Combine canonical INPUTS into one ordered forest input."
  (let ((builder (ebox-source-builder-create))
        nodes)
    (dolist (input inputs)
      (unless (ebox-canonical-input-p input)
        (signal 'wrong-type-argument (list 'ebox-canonical-input-p input)))
      (ebox-source-builder-import builder (ebox-test-source-index input))
      (setq nodes (nconc nodes (ebox-test-forest input))))
    (ebox-canonical-input-create nodes (ebox-source-builder-finish builder))))

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

(defun ebox-test--source-handle (builder props declarations)
  "Return one opaque fixture source for PROPS and DECLARATIONS.
The optional `:source-identity' fixture property explicitly names its stable
author identity; opaque source handles remain internal to SourceBuilder."
  (let* ((identity (plist-get props :source-identity))
         (arguments
          (list :key (plist-get props :key)
                :id (plist-get props :id)
                :class (plist-get props :class)
                :selector-state (plist-get props :selector-state)
                :selector-attributes (plist-get props :selector-attributes)
                :declarations declarations
                :provenance '(:adapter ebox-test))))
    (apply #'ebox-source-builder-bind
           builder
           (append
            (and identity (list :identity identity))
            arguments))))

(defun ebox-test--declarations (tag props)
  "Return canonical TAG declarations from evaluated fixture PROPS."
  (ebox-style-compile-form
   tag (ebox-test--without (ebox-test--explicit-sizes tag props)
                          ebox-test--non-style-fields)))

(defun ebox-test--explicit-length (value axis &optional track)
  "Express fixture VALUE in explicit units for AXIS.
Fixture numbers are historical cell measurements; singleton lists are pixel
measurements, except for vertical Grid TRACK values, which are line counts.
This adapter belongs only to old backend characterization fixtures.  Public
DSL and style tests call the production API directly and reject these forms."
  (cond
   ((numberp value) (list axis value))
   ((memq value '(viewport viewport-height))
    (list (if (eq value 'viewport) 'vw 'vh) 100))
   ((and (consp value) (null (cdr value)))
    (if (numberp (car value))
        (list (if (and track (eq axis 'lh)) 'lh 'px) (car value))
      (if (memq (car value) '(viewport viewport-height))
          (ebox-test--explicit-length (car value) axis)
        value)))
   ((and track (consp value) (memq (car value) '(minmax repeat)))
    (cons (car value)
          (cl-loop for part in (cdr value) for index from 0
                   collect (if (and (eq (car value) 'repeat) (= index 0))
                               part
                             (ebox-test--explicit-length part axis t)))))
   (t value)))

(defun ebox-test--explicit-sizes (tag props)
  "Convert old backend fixture PROPS to explicit sizes for TAG."
  (cl-loop
   for (property value) on props by #'cddr
   for name = (symbol-name property)
   append
   (list
    property
    (cond
     ((memq property '(:padding :margin :gap :padding-inline :padding-block
                       :margin-inline :margin-block :border-width))
      (if (ebox-size-value-p value t) value
        (let* ((axes (cond ((eq property :border-width) '(px px px px))
                           ((string-suffix-p "-inline" name) '(ch ch))
                           ((string-suffix-p "-block" name) '(lh lh))
                           ((eq property :gap) '(lh ch))
                           (t '(lh ch lh ch))))
               (parts (if (listp value) value (list value))))
          (when (and (= (length parts) 1)
                     (not (eq (car axes) (cadr axes))))
            (setq parts (list (car parts) (car parts))))
          (cl-loop for part in parts for axis in axes
                   collect (ebox-test--explicit-length part axis)))))
     ((memq property '(:border :border-top :border-right :border-bottom
                       :border-left))
      (if (and (listp value) (> (length value) 1)
               (numberp (car value)))
          (cons (list 'px (car value)) (cdr value))
        (ebox-test--explicit-length value 'px)))
     ((memq property '(:grid-template-columns :grid-template-rows
                       :grid-auto-columns :grid-auto-rows))
      (let ((axis (if (string-suffix-p "rows" name) 'lh 'ch)))
        (if (and (listp value)
                 (not (memq (car value)
                            '(px % vw vh ch lh calc min max clamp fr minmax repeat))))
            (mapcar (lambda (part) (ebox-test--explicit-length part axis t)) value)
          (ebox-test--explicit-length value axis t))))
     ((eq property :flex)
      (if (and (listp value) (= (length value) 3))
          (list (car value) (cadr value)
                (ebox-test--explicit-length (nth 2 value) 'ch))
        value))
     ((or (memq property '(:width :height :min-width :min-height :max-width
                           :max-height :flex-basis :row-gap :column-gap :item-gap))
          (string-match-p "\\`:\\(?:padding\\|margin\\)-" name)
          (string-match-p "\\`:\\(?:border-.*-width\\)\\'" name))
      (ebox-test--explicit-length
       value (cond ((string-prefix-p ":border-" name) 'px)
                   ((eq property :item-gap) (if (eq tag 'column) 'lh 'px))
                   ((string-match-p "height\\|top\\|bottom\\|block\\|row-gap" name) 'lh)
                   (t 'ch))
       (eq property :row-gap)))
     (t value)))))

(defun ebox-test--layout (tag props declarations)
  "Return TAG LayoutConfig from PROPS and DECLARATIONS."
  (ebox-layout-config-for-form
   tag
   (if (memq tag '(row column))
       (ebox-test--keep (ebox-test--explicit-sizes tag props)
                        '(:item-gap :cross-align))
     (ebox-style-declaration-properties
      declarations
      (lambda (property)
        (memq (plist-get property :name)
              (ebox-layout-config-property-names tag)))))))

(defun ebox-test-text (value &rest props)
  "Return one canonical Text input for VALUE and author PROPS."
  (let* ((builder (ebox-source-builder-create))
         (declarations (ebox-test--declarations 'text props))
         (node
          (ebox-text-create
           :value value
           :owned-facts
           (ebox-canonical-facts-from-declarations 'text declarations)
           :source-handle
           (ebox-test--source-handle builder props declarations)))
         (index (ebox-source-builder-finish builder)))
    (ebox-canonical-input-create (list node) index)))

(defun ebox-test--normalize-child (builder child)
  "Import fixture CHILD into BUILDER and return its canonical node value."
  (cond
   ((ebox-canonical-input-p child)
    (ebox-source-builder-import builder (ebox-test-source-index child))
    (ebox-test-root child))
   ((ebox-child-range--descriptor-p child)
    (ebox-child-range--descriptor-create
     (ebox-child-range--descriptor-ref child)
     (mapcar (lambda (item)
               (ebox-test--normalize-child builder item))
             (ebox-child-range--descriptor-items child))))
   (t
    (error "Fixture child must be a canonical input or Range: %S" child))))

(defun ebox-test--box-node (tag props children)
  "Return canonical Box input TAG from PROPS and CHILDREN."
  (let* ((builder (ebox-source-builder-create))
         (declarations (ebox-test--declarations tag props))
         (nodes (mapcar (lambda (child)
                          (ebox-test--normalize-child builder child))
                        children))
         (node
          (ebox-box-create
             :source-builder builder
             :layout (ebox-test--layout tag props declarations)
             :outer (or (plist-get props :outer) 'block)
             :children nodes
             :owned-facts
             (ebox-canonical-facts-from-declarations tag declarations)
             :source-handle
             (ebox-test--source-handle builder props declarations)))
         (index (ebox-source-builder-finish builder)))
    (dolist (key ebox-test--direct-fields)
      (when (plist-member props key)
        (plist-put node key (copy-tree (plist-get props key)))))
    (ebox-canonical-input-create (list node) index)))

(defun ebox-test-box (&rest items)
  "Return one typed Normal Box fixture from evaluated ITEMS."
  (pcase-let ((`(,props . ,children) (ebox-test--split-items items)))
    (ebox-test--box-node 'box props children)))

(defun ebox-test-row (&rest items)
  "Return one typed Row fixture from evaluated ITEMS."
  (pcase-let ((`(,props . ,children) (ebox-test--split-items items)))
    (ebox-test--box-node 'row props (delq nil children))))

(defun ebox-test-column (&rest items)
  "Return one typed Column fixture from evaluated ITEMS."
  (pcase-let ((`(,props . ,children) (ebox-test--split-items items)))
    (ebox-test--box-node 'column props (delq nil children))))

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
  "Return INPUT with direct Flex participation and Box properties from PROPS."
  (unless (ebox-canonical-input-p node)
    (signal 'wrong-type-argument (list 'ebox-canonical-input-p node)))
  (unless (ebox-box-node-p (ebox-test-root node))
    (setq node (ebox-test--box-node 'box nil (list node))))
  (let* ((source-index (ebox-test-source-index node))
         (node (ebox-test-root node))
         (source (or (ebox-node-source-handle node)
                     (error "Fixture Box lacks an opaque source handle: %S"
                            node)))
         (layout (ebox-box-node-layout node))
         (children (ebox-box-node-children node))
         (base (ebox-style-node-declarations source-index node))
         (extra (ebox-test--declarations 'box props))
         (declarations (ebox-style-merge-declarations base extra))
         (binding
          (ebox-source-index-rebind
           source-index source :declarations declarations))
         (copy
          (ebox-box-create
           :layout layout
           :children children
           :outer (ebox-tree-display-outer node)
           :owned-facts
           (ebox-canonical-facts-from-declarations
            'box declarations)
           :source-handle (cdr binding))))
    (ebox-canonical-input-create (list copy) (car binding))))

(provide 'ebox-fixtures)

;;; ebox-fixtures.el ends here
