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
(require 'ebox-layout-config)
(require 'ebox-style)
(require 'ebox-node-factory)
(require 'ebox-child-range)

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

(defconst ebox-canonical--source-metadata-fields
  '(:source-handle :key :class :id)
  "Source facts accepted by both canonical Text and Box constructors.")

(defvar ebox-canonical--declaration-fact-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Declaration-identity keyed validated canonical node facts.")

(defun ebox-canonical--source-metadata (plist context)
  "Return detached source metadata from PLIST for CONTEXT.
Every metadata field is optional but may occur at most once."
  (let (metadata)
    (dolist (field ebox-canonical--source-metadata-fields)
      (when-let* ((entry (ebox-canonical--optional-field
                          plist field context)))
        (setq metadata
              (append metadata (list field (cdr entry))))))
    metadata))

(defun ebox-canonical--apply-source-metadata (node metadata)
  "Attach canonical source METADATA to runtime NODE and return NODE."
  (while metadata
    (let ((field (pop metadata))
          (value (pop metadata)))
      (plist-put node
                 (pcase field
                   (:source-handle :ebox-source-handle)
                   (_ field))
                 value)
      ;; `:host-ref' is the private retained-geometry projection of the
      ;; source-owned handle.  It is not a second public identity field.
      (when (and (eq field :source-handle) value)
        (plist-put node :host-ref value))))
  node)

(defun ebox-canonical--text-measurement-property-p (property)
  "Return non-nil when PROPERTY belongs to canonical Text measurement."
  (eq (plist-get property :group) 'typography))

(defun ebox-canonical--box-frame-property-p (property)
  "Return non-nil when PROPERTY belongs to Box geometry or participation."
  (let ((contexts (plist-get property :contexts))
        (group (plist-get property :group)))
    (or (memq 'item contexts)
        (and (memq 'box contexts)
             (not (memq group '(paint typography)))))))

(defun ebox-canonical--node-properties
    (props declarations-field predicate context tag)
  "Return declarations, engine props, and projection need for one node.
PROPS are direct typed inputs.  DECLARATIONS-FIELD is an optional normalized
author fact set.  PREDICATE selects canonical node-owned values for CONTEXT
and author TAG."
  (if declarations-field
      (progn
        (when props
          (error "%s cannot mix normalized declarations with direct properties"
                 context))
        (let* ((declarations (cdr declarations-field))
               (by-tag
                (or (gethash declarations
                             ebox-canonical--declaration-fact-cache)
                    (let ((table (make-hash-table :test #'eq)))
                      (puthash declarations table
                               ebox-canonical--declaration-fact-cache)
                      table)))
               (missing (make-symbol "ebox-canonical-facts-missing"))
               (cached (gethash tag by-tag missing)))
          (if (not (eq cached missing))
              cached
            (ebox-style-validate-form-declarations tag declarations)
            (let ((facts
                   (list declarations
                         (ebox-style-declaration-properties
                          declarations
                          (lambda (property)
                            (or (funcall predicate property)
                                (memq (plist-get property :group)
                                      '(paint typography)))))
                         (ebox-style-declarations-require-projection-p
                          declarations
                          (lambda (property)
                            (or (funcall predicate property)
                                (memq (plist-get property :group)
                                      '(paint typography))
                                (and (memq tag '(flex grid))
                                     (memq tag
                                           (plist-get property
                                                      :contexts)))))))))
              (setf (nth 1 facts)
                    (ebox-style-expand-ebox-plist (nth 1 facts)))
              (puthash tag facts by-tag)
              facts))))
    (let ((declarations
           (if (null props)
               nil
             (condition-case err
                 (ebox-style-compile-declarations props t)
               (error
                (error "%s rejected properties: %s"
                       context (error-message-string err)))))))
      (cl-loop for (id _value) on declarations by #'cddr
               for property = (or (ebox-style--property id)
                                  (error "Missing canonical Ebox property: %S"
                                         id))
               unless (funcall predicate property)
               do (error "%s does not accept %S"
                         context (plist-get property :name)))
      (list declarations
            (ebox-style-expand-ebox-plist
             (ebox-style-declaration-properties
              declarations
              (lambda (property)
                (or (funcall predicate property)
                    (memq (plist-get property :group)
                          '(paint typography))))))
            nil))))

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
  (ebox-layout-config--copy (plist-get node :ebox-layout-config)))

(defun ebox-box-node-children (node)
  "Return canonical BoxNode NODE's material Text/Box children."
  (unless (ebox-box-node-p node)
    (error "Expected canonical BoxNode, got %S" node))
  (if (plist-member node :children)
      (plist-get node :children)
    (when-let* ((sequence (plist-get node :ebox-child-sequence)))
      (ebox-child-range--flatten sequence))))

(defun ebox-box-node-range-anchors (node)
  "Return transparent Range anchors retained by canonical BoxNode NODE."
  (unless (ebox-box-node-p node)
    (error "Expected canonical BoxNode, got %S" node))
  (let ((sequence (plist-get node :ebox-child-sequence))
        (offset 0)
        anchors)
    (when sequence
      (dotimes (index (ebox-child-range--sequence-count sequence))
        (let* ((segment (ebox-child-range--segment-at sequence index))
               (payload (ebox-child-range--segment-payload segment))
               (after (+ offset (length payload))))
          (when-let* ((ref (ebox-child-range--segment-ref segment)))
            (push (list :ref ref :before offset :after after) anchors))
          (setq offset after))))
    (nreverse anchors)))

(defun ebox-canonical--normalize-children (children)
  "Return material children and optional Range sequence for CHILDREN."
  (let (material segments range-p)
    (dolist (entry children)
      (if (ebox-child-range--descriptor-p entry)
          (let ((items (ebox-child-range--descriptor-items entry)))
            (unless (cl-every (lambda (item)
                                (or (ebox-text-node-p item)
                                    (ebox-box-node-p item)))
                              items)
              (error "Ebox Box Range items must be canonical Text/Box nodes: %S"
                     items))
            (setq range-p t)
            (push (cons (ebox-child-range--descriptor-ref entry) items)
                  segments)
            (dolist (item items)
              (push item material)))
        (unless (or (ebox-text-node-p entry) (ebox-box-node-p entry))
          (error "Ebox Box children must be canonical Text/Box nodes or Ranges: %S"
                 children))
        (push (cons nil (list entry)) segments)
        (push entry material)))
    (list (nreverse material)
          (and range-p
               (ebox-child-range--build (nreverse segments) nil t)))))

;;;###autoload
(defun ebox-text-create (&rest plist)
  "Create a canonical TextNode from evaluated PLIST.

`:value' is required and must be one string.  `:source-handle', `:key',
`:class', and `:id' are optional source facts.  Direct properties are limited
to text measurement.  `:declarations' may carry one already-normalized Text
author fact set so paint is projected without reparsing."
  (ebox-canonical--validate-plist plist "ebox-text-create")
  (let* ((value (ebox-canonical--required-field
                 plist :value "Ebox Text"))
         (declarations-field (ebox-canonical--optional-field
                              plist :declarations "Ebox Text"))
         (source-metadata (ebox-canonical--source-metadata plist "Ebox Text"))
         (props (ebox-canonical--without-keys
                 plist (append '(:value :declarations)
                               ebox-canonical--source-metadata-fields))))
    (unless (stringp value)
      (error "Ebox Text :value must be a string: %S" value))
    (pcase-let* ((`(,declarations ,engine-props ,style-required-p)
                   (ebox-canonical--node-properties
                    props declarations-field
                    #'ebox-canonical--text-measurement-property-p
                    "Ebox Text" 'text))
                  (node
                   (ebox-node-factory--create-text-expanded
                    (append engine-props (list :content value))
                    declarations)))
      (plist-put node :ebox-kind 'text)
      (plist-put node :ebox-text-value value)
      (ebox-canonical--apply-source-metadata node source-metadata)
      (plist-put node :display '(inline flow))
      (plist-put node :ebox-author-style-count
                 (if style-required-p 1 0))
      (when style-required-p
        (plist-put node :ebox-author-style-required-p t))
      node)))

;;;###autoload
(defun ebox-box-create (&rest plist)
  "Create a canonical BoxNode from evaluated PLIST.

`:layout' must occur exactly once as an `ebox-layout-config'.
`:children' is a list of canonical nodes.  Every Layout accepts zero or more
children according to its own formatting algorithm.  `:declarations' may
carry one already-normalized Box author fact set."
  (ebox-canonical--validate-plist plist "ebox-box-create")
  (let* ((layout (ebox-canonical--required-field
                  plist :layout "Ebox Box"))
         (children-field (ebox-canonical--optional-field
                          plist :children "Ebox Box"))
         (declarations-field (ebox-canonical--optional-field
                              plist :declarations "Ebox Box"))
         (outer-field (ebox-canonical--optional-field
                       plist :outer "Ebox Box"))
         (source-metadata (ebox-canonical--source-metadata plist "Ebox Box"))
         (children (if children-field (cdr children-field) nil))
         child-sequence
         (outer (if outer-field (cdr outer-field) 'block))
         (props (ebox-canonical--without-keys
                 plist (append '(:layout :children :outer :declarations)
                               ebox-canonical--source-metadata-fields))))
    (unless (ebox-layout-config-p layout)
      (error "Ebox Box :layout must be a typed layout config: %S"
             layout))
    (setq layout (ebox-layout-config--copy layout))
    (unless (memq outer '(inline block))
      (error "Ebox Box :outer must be inline or block: %S" outer))
    (unless (proper-list-p children)
      (error "Ebox Box :children must be a proper list: %S" children))
    (pcase-let ((`(,material-children ,normalized-sequence)
                 (ebox-canonical--normalize-children children)))
      (setq children material-children)
      (setq child-sequence normalized-sequence))
    (unless (memq (ebox-layout-config-kind layout)
                  '(normal row column flex grid))
      (error "Ebox Box Layout is not implemented: %S"
             (ebox-layout-config-kind layout)))
    (pcase-let* ((tag (if (eq (ebox-layout-config-kind layout) 'normal)
                           'box
                         (ebox-layout-config-kind layout)))
                  (`(,declarations ,engine-props ,style-required-p)
                   (ebox-canonical--node-properties
                    props declarations-field
                    #'ebox-canonical--box-frame-property-p
                    "Ebox Box" tag))
                  (node (ebox-node-factory--create-expanded
                         engine-props declarations)))
      (plist-put node :ebox-kind 'box)
      (plist-put node :ebox-layout-config layout)
      (plist-put node :children children)
      (when child-sequence
        (plist-put node :ebox-child-sequence child-sequence))
      (ebox-canonical--apply-source-metadata node source-metadata)
      (plist-put node :display
                 (list outer
                       (pcase (ebox-layout-config-kind layout)
                         ('normal 'flow)
                         (kind kind))))
      (let ((style-count
             (+ (if style-required-p 1 0)
                (cl-loop for child in children
                         sum (or (plist-get child
                                            :ebox-author-style-count)
                                 (if (plist-get
                                      child :ebox-author-style-required-p)
                                     1
                                   0))))))
        (plist-put node :ebox-author-style-count style-count)
        (when (> style-count 0)
          (plist-put node :ebox-author-style-required-p t)))
      node)))

(provide 'ebox-canonical)

;;; ebox-canonical.el ends here
