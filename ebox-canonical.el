;;; ebox-canonical.el --- Typed canonical Ebox nodes -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns the typed programmatic boundary between normalized author input and
;; Ebox's current runtime representation.  Canonical kind, layout, source, and
;; child facts remain explicit even when the runtime reuses an existing box
;; encoding for rendering.  This module does not parse the `.ebox' DSL or
;; perform measurement, layout, paint, or buffer publication.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-style)
(require 'ebox-node-factory)

(cl-defstruct
    (ebox-layout-config
     (:constructor ebox-layout-config--create))
  "Canonical typed layout selection for one BoxNode."
  kind
  props)

(defun ebox-canonical--validate-plist (plist context)
  "Validate PLIST shape for error CONTEXT and return PLIST."
  (unless (proper-list-p plist)
    (error "%s properties must be a proper plist: %S" context plist))
  (unless (zerop (% (length plist) 2))
    (error "%s property is missing a value: %S" context (car (last plist))))
  (cl-loop for key in plist by #'cddr
           unless (keywordp key)
           do (error "%s property name must be a keyword: %S" context key))
  plist)

(defun ebox-canonical--without-keys (plist keys)
  "Return PLIST without entries whose keys occur in KEYS."
  (cl-loop for (key value) on plist by #'cddr
           unless (memq key keys)
           append (list key value)))

(defun ebox-canonical--field-values (plist field)
  "Return every FIELD value from PLIST in source order."
  (cl-loop for (key value) on plist by #'cddr
           when (eq key field)
           collect value))

(defun ebox-canonical--required-field (plist field context)
  "Return exactly one required FIELD from PLIST for error CONTEXT."
  (let ((values (ebox-canonical--field-values plist field)))
    (unless (= (length values) 1)
      (error "%s requires %S exactly once" context field))
    (car values)))

(defun ebox-canonical--optional-field (plist field context)
  "Return `(PRESENT . VALUE)' for optional FIELD in PLIST and CONTEXT."
  (let ((values (ebox-canonical--field-values plist field)))
    (when (> (length values) 1)
      (error "%s accepts %S at most once" context field))
    (and values (cons t (car values)))))

(defun ebox-canonical--compiled-property-definitions (plist context)
  "Return canonical property definitions compiled from PLIST for CONTEXT."
  (condition-case err
      (cl-loop for (property _value)
               on (ebox-style-compile-declarations plist t) by #'cddr
               collect (or (ebox-style-property property)
                           (error "Missing canonical Ebox property: %S"
                                  property)))
    (error
     (error "%s rejected properties: %s" context (error-message-string err)))))

(defun ebox-canonical--text-measurement-property-p (property)
  "Return non-nil when PROPERTY belongs to canonical Text measurement."
  (eq (plist-get property :group) 'typography))

(defun ebox-canonical--box-frame-property-p (property)
  "Return non-nil when PROPERTY belongs to Box geometry or participation."
  (let ((contexts (plist-get property :contexts))
        (group (plist-get property :group))
        (name (plist-get property :name)))
    (or (memq 'item contexts)
        (and (memq 'box contexts)
             (not (memq group '(paint typography)))
             (not (eq name :wrap-mode))))))

(defun ebox-canonical--assert-property-role (plist predicate context)
  "Require every compiled PLIST property to satisfy PREDICATE for CONTEXT."
  (dolist (property
           (ebox-canonical--compiled-property-definitions plist context))
    (unless (funcall predicate property)
      (error "%s does not accept %S"
             context (plist-get property :name)))))

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

(defun ebox-node-kind (node)
  "Return canonical NODE kind, or nil for a legacy runtime node."
  (and (listp node) (plist-get node :ebox-kind)))

(defun ebox-text-node-p (node)
  "Return non-nil when NODE is a canonical TextNode."
  (eq (ebox-node-kind node) 'text))

(defun ebox-box-node-p (node)
  "Return non-nil when NODE is a canonical BoxNode."
  (eq (ebox-node-kind node) 'box))

(defun ebox-node-source-handle (node)
  "Return canonical NODE's opaque source handle."
  (and (listp node) (plist-get node :ebox-source-handle)))

(defun ebox-text-node-value (node)
  "Return canonical TextNode NODE's string payload."
  (unless (ebox-text-node-p node)
    (error "Expected canonical TextNode, got %S" node))
  (plist-get node :ebox-text-value))

(defun ebox-box-node-layout (node)
  "Return canonical BoxNode NODE's typed layout config."
  (unless (ebox-box-node-p node)
    (error "Expected canonical BoxNode, got %S" node))
  (plist-get node :ebox-layout-config))

(defun ebox-box-node-children (node)
  "Return canonical BoxNode NODE's retained canonical children."
  (unless (ebox-box-node-p node)
    (error "Expected canonical BoxNode, got %S" node))
  (plist-get node :children))

;;;###autoload
(defun ebox-text-create (&rest plist)
  "Create a canonical TextNode from evaluated PLIST.

`:value' is required and must be one string.  `:source-handle' is optional.
  Only text measurement properties are accepted; paint is projected separately."
  (ebox-canonical--validate-plist plist "ebox-text-create")
  (let* ((value (ebox-canonical--required-field
                 plist :value "Ebox Text"))
         (source-field (ebox-canonical--optional-field
                        plist :source-handle "Ebox Text"))
         (source-handle (cdr source-field))
         (props (ebox-canonical--without-keys
                 plist '(:value :source-handle))))
    (unless (stringp value)
      (error "Ebox Text :value must be a string: %S" value))
    (ebox-canonical--assert-property-role
     props #'ebox-canonical--text-measurement-property-p "Ebox Text")
    (let ((node (apply #'ebox-create (append props (list :content value)))))
      (plist-put node :ebox-kind 'text)
      (plist-put node :ebox-text-value value)
      (plist-put node :ebox-source-handle source-handle)
      node)))

;;;###autoload
(defun ebox-box-create (&rest plist)
  "Create a canonical BoxNode from evaluated PLIST.

`:layout' must occur exactly once as an `ebox-layout-config'.
`:children' is a list of canonical nodes.  Normal layout accepts zero or one
child.  Row and Column layouts accept any number of children."
  (ebox-canonical--validate-plist plist "ebox-box-create")
  (let* ((layout (ebox-canonical--required-field
                  plist :layout "Ebox Box"))
         (children-field (ebox-canonical--optional-field
                          plist :children "Ebox Box"))
         (outer-field (ebox-canonical--optional-field
                       plist :outer "Ebox Box"))
         (source-field (ebox-canonical--optional-field
                        plist :source-handle "Ebox Box"))
         (children (if children-field (cdr children-field) nil))
         (outer (if outer-field (cdr outer-field) 'block))
         (source-handle (cdr source-field))
         (props (ebox-canonical--without-keys
                 plist '(:layout :children :outer :source-handle))))
    (unless (ebox-layout-config-p layout)
      (error "Ebox Box :layout must be a typed layout config: %S"
             layout))
    (unless (memq outer '(inline block))
      (error "Ebox Box :outer must be inline or block: %S" outer))
    (unless (proper-list-p children)
      (error "Ebox Box :children must be a proper list: %S" children))
    (unless (cl-every (lambda (child)
                        (or (ebox-text-node-p child)
                            (ebox-box-node-p child)))
                      children)
      (error "Ebox Box children must be canonical Text/Box nodes: %S"
             children))
    (unless (memq (ebox-layout-config-kind layout) '(normal row column))
      (error "Ebox Box Layout is not implemented: %S"
             (ebox-layout-config-kind layout)))
    (unless (null (ebox-layout-config-props layout))
      (error "Ebox Box Layout properties are not implemented: %S"
             (ebox-layout-config-props layout)))
    (when (and (eq (ebox-layout-config-kind layout) 'normal)
               (> (length children) 1))
      (error "Ebox Box Normal layout currently accepts at most one child"))
    (ebox-canonical--assert-property-role
     props #'ebox-canonical--box-frame-property-p "Ebox Box")
    (let ((node (apply #'ebox-create props)))
      (plist-put node :ebox-kind 'box)
      (plist-put node :ebox-layout-config layout)
      (plist-put node :children children)
      (plist-put node :ebox-source-handle source-handle)
      ;; Children own their text formatting.  The Box frame consumes their
      ;; already-laid-out output and must not wrap or justify it a second time.
      (plist-put node :wrap-mode nil)
      (plist-put node :display
                 (list outer
                       (pcase (ebox-layout-config-kind layout)
                         ('normal 'flow)
                         (kind kind))))
      node)))

(provide 'ebox-canonical)

;;; ebox-canonical.el ends here
