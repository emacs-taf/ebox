;;; ebox-dsl.el --- Canonical author DSL for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the complete inert `.ebox' author boundary: form parsing, form-local
;; property validation, and desugaring into canonical TextNode/BoxNode plus
;; typed LayoutConfig values.  It does not own layout, paint materialization,
;; buffer publication, or framework runtime identity.

;;; Code:

(require 'cl-lib)
(require 'ebox-style)
(require 'ebox-canonical)
(require 'ebox-flex)
(require 'ebox-grid)

(cl-defstruct
    (ebox-dsl--properties
     (:constructor ebox-dsl--make-properties))
  "Normalized properties for one canonical Text or Box author source."
  tag
  source-metadata
  outer
  layout
  declarations)

(defconst ebox-dsl--box-tags
  '(box row column flex grid)
  "Author tags that construct one canonical BoxNode.")

(defconst ebox-dsl--source-fields
  '(:key :class :id)
  "Shared source metadata accepted by Ebox author surfaces.")

(defun ebox-dsl--source-handle ()
  "Return one opaque identity for a normalized author node."
  (make-symbol "ebox-source"))

(defun ebox-dsl--validate-plist (plist context)
  "Validate PLIST shape for CONTEXT and return PLIST."
  (unless (and (proper-list-p plist) (zerop (% (length plist) 2)))
    (error "%s properties must be an even plist: %S" context plist))
  (cl-loop for key in plist by #'cddr
           unless (keywordp key)
           do (error "%s property name must be a keyword: %S" context key))
  plist)

(defun ebox-dsl--field-values (plist field)
  "Return every FIELD value from PLIST in source order."
  (cl-loop for (key value) on plist by #'cddr
           when (eq key field)
           collect value))

(defun ebox-dsl--optional-field (plist field context)
  "Return optional FIELD from PLIST, rejecting duplicates for CONTEXT."
  (let ((values (ebox-dsl--field-values plist field)))
    (when (> (length values) 1)
      (error "%s accepts %S at most once" context field))
    (and values (cons t (car values)))))

(defun ebox-dsl--without-keys (plist keys)
  "Return PLIST without entries whose keys occur in KEYS."
  (cl-loop for (key value) on plist by #'cddr
           unless (memq key keys)
           append (list key value)))

(defun ebox-dsl--keep-keys (plist keys)
  "Return PLIST entries whose keys occur in KEYS."
  (cl-loop for (key value) on plist by #'cddr
           when (memq key keys)
           append (list key value)))

(defun ebox-dsl--source-metadata
    (properties source-handle context)
  "Return source metadata from PROPERTIES and SOURCE-HANDLE for CONTEXT."
  (let ((metadata (list :source-handle source-handle)))
    (dolist (field ebox-dsl--source-fields)
      (when-let* ((entry (ebox-dsl--optional-field
                          properties field context)))
        (setq metadata
              (append metadata (list field (cdr entry))))))
    metadata))

(defun ebox-dsl--compile-style (tag properties context)
  "Compile and validate TAG author PROPERTIES for CONTEXT."
  (condition-case err
      (if properties
          (ebox-style-compile-form tag properties)
        nil)
    (error
     (error "%s rejected properties: %s"
            context (error-message-string err)))))

(defun ebox-dsl--layout-config
    (tag declarations extensions context)
  "Construct TAG LayoutConfig from DECLARATIONS and EXTENSIONS for CONTEXT."
  (if (eq tag 'text)
      nil
    (condition-case err
        (ebox-layout-config-for-form
         tag
         (if (memq tag '(row column))
             extensions
           (let ((names (ebox-layout-config-property-names tag)))
             (ebox-style-declaration-properties
              declarations
              (lambda (property)
                (memq (plist-get property :name) names))))))
      (error
       (error "%s rejected layout config: %s"
              context (error-message-string err))))))

(defun ebox-dsl--normalize-properties (tag properties source-handle)
  "Project evaluated TAG PROPERTIES for opaque SOURCE-HANDLE.

TAG is `text', `box', `row', `column', `flex', or `grid'.  The returned
`ebox-dsl--properties' contains typed constructor inputs, source metadata,
and canonical declarations.  Child forms and text payloads are outside this
function."
  (unless (memq tag (cons 'text ebox-dsl--box-tags))
    (error "Ebox author properties has unknown author tag: %S" tag))
  (let* ((context (format "Ebox %S" tag))
         (properties
          (ebox-dsl--validate-plist properties context)))
    (dolist (field '(:content :layout :display :ebox-type :ebox-content-node))
      (when (plist-member properties field)
        (error "%s does not accept private author property %S"
               context field)))
    (let* ((outer-field
            (and (not (eq tag 'text))
                 (ebox-dsl--optional-field
                  properties :outer context)))
           (outer (and (not (eq tag 'text))
                       (if outer-field (cdr outer-field) 'block)))
           (extension-keys (and (memq tag '(row column))
                                '(:item-gap :cross-align)))
           (extensions
            (ebox-dsl--keep-keys
             properties extension-keys))
           (style-properties
            (ebox-dsl--without-keys
             properties
             (append (unless (eq tag 'text) '(:outer))
                     extension-keys
                     ebox-dsl--source-fields)))
           (declarations
            (ebox-dsl--compile-style
             tag style-properties context)))
      (ebox-dsl--make-properties
       :tag tag
       :source-metadata
       (ebox-dsl--source-metadata
        properties source-handle context)
       :outer outer
       :layout
       (ebox-dsl--layout-config
        tag declarations extensions context)
       :declarations declarations))))

(defconst ebox-dsl--tags '(text box row column flex grid)
  "The complete Ebox author tag set.")

(defun ebox-dsl--unquote-value (value)
  "Unquote one static DSL property VALUE when it is quoted data."
  (if (and (consp value)
           (eq (car value) 'quote)
           (null (cddr value)))
      (cadr value)
    value))

(defun ebox-dsl--unquote-properties (items)
  "Unquote static property values in top-level DSL ITEMS."
  (let (result)
    (while items
      (let ((item (pop items)))
        (if (keywordp item)
            (progn
              (unless items
                (error "Ebox build: missing value for %S" item))
              (push item result)
              (push (ebox-dsl--unquote-value (pop items)) result))
          (push item result))))
    (nreverse result)))

(defun ebox-dsl--split (items)
  "Return `(PROPERTIES . CHILDREN)' parsed from author ITEMS."
  (let (properties children)
    (while items
      (let ((item (pop items)))
        (if (keywordp item)
            (progn
              (unless items
                (error "Ebox build: missing value for %S" item))
              (setq properties
                    (append properties (list item (pop items)))))
          (setq children (append children (list item))))))
    (cons properties children)))

(defun ebox-dsl--build-text (_source items)
  "Build one canonical TextNode from author ITEMS."
  (let* ((split (ebox-dsl--split items))
         (properties (car split))
         (payloads (cdr split)))
    (unless (= (length payloads) 1)
      (error "Ebox text requires exactly one string payload"))
    (unless (stringp (car payloads))
      (error "Ebox text payload must be a string: %S" (car payloads)))
    (let* ((plan (ebox-dsl--normalize-properties
                  'text properties (ebox-dsl--source-handle)))
           (node
            (apply #'ebox-text-create
                   (append (list :value (car payloads))
                           (ebox-dsl--properties-source-metadata plan)
                           (list :declarations
                                 (ebox-dsl--properties-declarations plan))))))
      node)))

(defun ebox-dsl--build-box (tag _source items)
  "Build canonical BoxNode TAG from author ITEMS."
  (let* ((split (ebox-dsl--split items))
         (properties (car split))
         (child-forms (cdr split))
         (plan (ebox-dsl--normalize-properties
                tag properties (ebox-dsl--source-handle)))
         (children (mapcar #'ebox-dsl-build child-forms))
         (node
          (apply #'ebox-box-create
                 (append
                  (list :layout (ebox-dsl--properties-layout plan)
                        :outer (ebox-dsl--properties-outer plan)
                        :children children
                        :declarations
                        (ebox-dsl--properties-declarations plan))
                  (ebox-dsl--properties-source-metadata plan)))))
    node))

(defun ebox-dsl-build (dsl)
  "Build one canonical Ebox node from inert author DSL.

The complete grammar is String plus `text', `box', `row', `column', `flex',
and `grid'.  Strings normalize to Text.  The five Box forms select a typed
LayoutConfig; no form accepts `:content', `:layout', or a raw runtime node."
  (cond
   ((stringp dsl)
    (ebox-dsl--build-text dsl (list dsl)))
   ((not (and (consp dsl) (symbolp (car dsl))))
    (error "Ebox build: invalid author node %S" dsl))
   ((not (memq (car dsl) ebox-dsl--tags))
    (error "Ebox build: unknown author tag %S" (car dsl)))
   ((eq (car dsl) 'text)
    (ebox-dsl--build-text
     dsl (ebox-dsl--unquote-properties (cdr dsl))))
   (t
    (ebox-dsl--build-box
     (car dsl) dsl (ebox-dsl--unquote-properties (cdr dsl))))))

(provide 'ebox-dsl)

;;; ebox-dsl.el ends here
