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
(require 'ebox-source)
(require 'ebox-style)
(require 'ebox-node-factory)
(require 'ebox-child-range)
(require 'ebox-tree)

(declare-function ebox--flex-validate-item-bases "ebox-flex" (props children))

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

(defconst ebox-canonical--source-fields
  '(:source-handle)
  "Opaque source input accepted by canonical Text and Box constructors.")

(defvar ebox-canonical--declaration-fact-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Declaration-identity keyed validated canonical node facts.")

(cl-defstruct (ebox-canonical-facts
               (:constructor ebox-canonical--make-facts))
  "Already computed node-owned projection of one source declaration set."
  engine-properties style-required-p specified-property-ids)

(cl-defstruct (ebox-canonical-input
               (:constructor ebox-canonical--make-input)
               (:conc-name ebox-canonical-input--))
  "Atomic transport of a canonical forest and its source generation."
  nodes source-index range-anchors)

(defun ebox-canonical--validate-input-source-ownership (nodes source-index)
  "Validate that NODES reference exactly SOURCE-INDEX's source generation."
  (let ((seen-nodes (make-hash-table :test #'eq))
        (seen-handles (make-hash-table :test #'eq))
        preorder-handles)
    (cl-labels
        ((visit
          (node)
          (unless (or (ebox-text-node-p node) (ebox-box-node-p node))
            (error "Ebox canonical input contains a noncanonical node: %S" node))
          (when (gethash node seen-nodes)
            (error "Ebox canonical input reuses one node object"))
          (puthash node t seen-nodes)
          (let ((handle (ebox-node-source-handle node)))
            (unless (and (ebox-source-handle-p handle)
                         (ebox-source-index-handle-member-p
                          source-index handle))
              (error
               "Ebox canonical source is absent from its input generation"))
            (when (gethash handle seen-handles)
              (error "Ebox canonical input reuses one source handle"))
            (puthash handle t seen-handles)
            (push handle preorder-handles))
          (when (ebox-box-node-p node)
            (mapc #'visit (ebox-box-node-children node)))))
      (mapc #'visit nodes))
    (setq preorder-handles (nreverse preorder-handles))
    (unless (= (hash-table-count seen-handles)
               (ebox-source--table-size
                (ebox-source--index-handle-records source-index)))
      (error "Ebox canonical input contains unreferenced source facts"))
    (ebox-source--with-order source-index preorder-handles)))

(defun ebox-canonical-input-create (nodes source-index &optional range-anchors)
  "Return one opaque canonical input for ordered forest NODES.
SOURCE-INDEX owns every source fact referenced by NODES.  RANGE-ANCHORS are
nonvisual structural addresses transported with the same generation."
  (unless (and (proper-list-p nodes)
               (cl-every (lambda (node)
                           (and (listp node) (not (stringp node))))
                         nodes))
    (error "Ebox canonical input nodes must be a proper node forest: %S"
           nodes))
  (unless (ebox-source-index-p source-index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p source-index)))
  (setq source-index
        (ebox-canonical--validate-input-source-ownership nodes source-index))
  (ebox-canonical--make-input
   :nodes (copy-sequence nodes)
   :source-index source-index
   :range-anchors (copy-tree range-anchors)))

(defun ebox-canonical-input-roots (input)
  "Return a shallow copy of canonical INPUT's ordered forest roots.
This is a read-only structural view; it does not adopt INPUT's source facts
into another candidate."
  (unless (ebox-canonical-input-p input)
    (signal 'wrong-type-argument (list 'ebox-canonical-input-p input)))
  (copy-sequence (ebox-canonical-input--nodes input)))

(defun ebox-canonical-input-import-roots (input roots builder)
  "Import INPUT facts owned by selected top-level ROOTS into BUILDER.
Each ROOT must be an exact, unique member of INPUT's forest.  The selected
subtrees retain their existing nodes, handles, and immutable records without
adopting facts from unselected roots.  Return a shallow copy of ROOTS."
  (unless (ebox-canonical-input-p input)
    (signal 'wrong-type-argument (list 'ebox-canonical-input-p input)))
  (ebox-source--builder-assert-open builder)
  (unless (proper-list-p roots)
    (error "Ebox canonical selected roots must be a proper list: %S" roots))
  (let ((available (make-hash-table :test #'eq))
        (selected (make-hash-table :test #'eq))
        (source-index (ebox-canonical-input--source-index input)))
    (dolist (root (ebox-canonical-input--nodes input))
      (puthash root t available))
    (cl-labels
        ((import-node
          (node)
          (let* ((handle (ebox-node-source-handle node))
                 (record (ebox-source--index-record source-index handle)))
            (unless record
              (error "Ebox canonical selected root has no source facts"))
            (ebox-source--builder-add-record builder handle record))
          (when (ebox-box-node-p node)
            (mapc #'import-node (ebox-box-node-children node)))))
      (dolist (root roots)
        (unless (gethash root available)
          (error "Ebox canonical selected root is outside its input"))
        (when (gethash root selected)
          (error "Ebox canonical selected root occurs more than once"))
        (puthash root t selected)
        (import-node root))))
  (copy-sequence roots))

(defun ebox-canonical-input--single-root (input context)
  "Return INPUT's only root node, or signal for error CONTEXT."
  (unless (ebox-canonical-input-p input)
    (signal 'wrong-type-argument (list 'ebox-canonical-input-p input)))
  (let ((nodes (ebox-canonical-input--nodes input)))
    (unless (= (length nodes) 1)
      (error "%s requires exactly one canonical root" context))
    (car nodes)))

(defun ebox-canonical-input-root-host-ref (input)
  "Return INPUT's detached single-root publication reference.
This framework-integration port keeps `ebox-source-handle' opaque: Ebox first
validates that the canonical root's exact handle belongs to INPUT's immutable
source generation, then returns only the author-owned publication reference."
  (let* ((root (ebox-canonical-input--single-root
                input "ebox-canonical-input-root-host-ref"))
         (handle (plist-get root :ebox-source-handle))
         (source-index (ebox-canonical-input--source-index input)))
    (unless (and (ebox-source-handle-p handle)
                 (ebox-source-index-handle-member-p source-index handle))
      (error "Ebox canonical root source is absent from its input generation"))
    (ebox-source-handle-id handle)))

(defun ebox-canonical-input-equal-p (left right)
  "Return non-nil when canonical inputs LEFT and RIGHT are exactly equivalent.
The comparison includes the ordered forest, transparent Range anchors, source
identity order, and every immutable author fact.  Derived selector/runtime
indexes are deliberately excluded because they are projections of these
canonical inputs, not additional source authority."
  (and (ebox-canonical-input-p left)
       (ebox-canonical-input-p right)
       (equal-including-properties
        (ebox-canonical-input--nodes left)
        (ebox-canonical-input--nodes right))
       (equal-including-properties
        (ebox-canonical-input--range-anchors left)
        (ebox-canonical-input--range-anchors right))
       (let ((left-handles
              (ebox-source-index-handles
               (ebox-canonical-input--source-index left)))
             (right-handles
              (ebox-source-index-handles
               (ebox-canonical-input--source-index right)))
             (left-index (ebox-canonical-input--source-index left))
             (right-index (ebox-canonical-input--source-index right)))
         (and (= (length left-handles) (length right-handles))
              (cl-every
               (lambda (left-handle right-handle)
                 (and
                  (equal-including-properties
                   (ebox-source--handle-id-view left-handle)
                   (ebox-source--handle-id-view right-handle))
                  (equal-including-properties
                   (ebox-source--index-record left-index left-handle)
                   (ebox-source--index-record right-index right-handle))))
               left-handles right-handles)))))

(defun ebox-canonical-input-equal-outside-ranges-p
    (left right range-refs &optional host-refs)
  "Compare canonical LEFT and RIGHT outside child ranges in RANGE-REFS.
Only the contents of matching Box child anchors may differ.  Anchor order,
unmasked nodes and their immutable source facts must remain equal including
text properties.  Offsets may shift only by the sizes of masked contents.
HOST-REFS optionally masks entire single-root outputs addressed by source
identity instead of a child anchor.  Their identity, kind and position must
still match.  Root anchors are compared exactly.  Inputs are never modified.
Callers must publish every masked change in the same atomic candidate."
  (if (not (or range-refs host-refs))
      (ebox-canonical-input-equal-p left right)
    (and
     (ebox-canonical-input-p left)
     (ebox-canonical-input-p right)
     (equal-including-properties
      (ebox-canonical-input--range-anchors left)
      (ebox-canonical-input--range-anchors right))
     (let ((masked (make-hash-table :test #'equal))
           (hosts (make-hash-table :test #'equal))
           (left-index (ebox-canonical-input--source-index left))
           (right-index (ebox-canonical-input--source-index right)))
       (dolist (ref range-refs) (puthash ref t masked))
       (dolist (ref host-refs) (puthash ref t hosts))
       (cl-labels
           ((node-equal
             (a b)
             (let ((a-handle (ebox-node-source-handle a))
                   (b-handle (ebox-node-source-handle b)))
               (and
                (equal-including-properties
                 (ebox-source--handle-id-view a-handle)
                 (ebox-source--handle-id-view b-handle))
                (if (gethash (ebox-source--handle-id-view a-handle) hosts)
                    (eq (ebox-node-kind a) (ebox-node-kind b))
                  (and
                   (equal-including-properties
                    (ebox-source--index-record left-index a-handle)
                   (ebox-source--index-record right-index b-handle))
                   (if (and (ebox-box-node-p a) (ebox-box-node-p b))
                       (and
                        (equal-including-properties
                         (ebox-canonical--without-keys
                          a '(:children :ebox-child-sequence))
                         (ebox-canonical--without-keys
                          b '(:children :ebox-child-sequence)))
                        (forest-equal
                         (ebox-box-node-children a) (ebox-box-node-children b)
                         (ebox-box-node-range-anchors a)
                         (ebox-box-node-range-anchors b)))
                     (equal-including-properties a b)))))))
            (forest-equal
             (a b a-anchors b-anchors)
             (let ((a-length (length a)) (b-length (length b))
                   (a-offset 0) (b-offset 0))
               (and
                (= (length a-anchors) (length b-anchors))
                (cl-every
                 (lambda (a-anchor b-anchor)
                   (let ((a-before (plist-get a-anchor :before))
                         (a-after (plist-get a-anchor :after))
                         (b-before (plist-get b-anchor :before))
                         (b-after (plist-get b-anchor :after)))
                     (and
                      (integerp a-before) (integerp a-after)
                      (integerp b-before) (integerp b-after)
                      (<= a-offset a-before a-after a-length)
                      (<= b-offset b-before b-after b-length)
                      (= (- a-before a-offset) (- b-before b-offset))
                      (equal-including-properties
                       (ebox-canonical--without-keys a-anchor '(:before :after))
                       (ebox-canonical--without-keys b-anchor '(:before :after)))
                      (cl-loop repeat (- a-before a-offset)
                               always (node-equal (pop a) (pop b)))
                      (if (gethash (plist-get a-anchor :ref) masked)
                          (progn
                            (setq a (nthcdr (- a-after a-before) a)
                                  b (nthcdr (- b-after b-before) b))
                            t)
                        (and (= (- a-after a-before) (- b-after b-before))
                             (cl-loop repeat (- a-after a-before)
                                      always (node-equal (pop a) (pop b)))))
                      (setq a-offset a-after b-offset b-after))))
                 a-anchors b-anchors)
                (= (length a) (length b))
                (cl-every #'node-equal a b)))))
         ;; Canonical construction orders source handles by forest preorder,
         ;; so comparing each retained node also proves source identity order.
         (forest-equal (ebox-canonical-input--nodes left)
                       (ebox-canonical-input--nodes right) nil nil))))))

(defun ebox-canonical--source-handle (plist context)
  "Return the one opaque source handle from PLIST for CONTEXT."
  (let ((handle (ebox-canonical--required-field
                 plist :source-handle context)))
    (unless (ebox-source-handle-p handle)
      (error "%s :source-handle must be opaque Ebox source: %S"
             context handle))
    handle))

(defun ebox-canonical--apply-source-handle (node handle)
  "Attach opaque source HANDLE to runtime NODE and return NODE."
  (plist-put node :ebox-source-handle handle)
  node)

(defun ebox-canonical--text-engine-property-p (_property)
  "Return non-nil for a Text fact materializable without a Surface.
Canonical Text style currently consists of paint facts and host-resolved font
facts.  Neither is a constructor-owned measurement field."
  nil)

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
                          (ebox-style--concrete-declarations declarations)
                          (lambda (property)
                            (or (funcall predicate property)
                                (eq (plist-get property :group) 'paint))))
                         (or (ebox-style--deferred-declarations-p declarations)
                             (ebox-style-declarations-require-projection-p
                              declarations
                              (lambda (property)
                                (or (funcall predicate property)
                                    (eq (plist-get property :group) 'paint)
                                    (and (memq tag '(flex grid))
                                         (memq tag
                                               (plist-get property
                                                          :contexts))))))))))
              (setf (nth 1 facts)
                    (ebox-style--expand-engine-plist (nth 1 facts)))
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
            (ebox-style--expand-engine-plist
             (ebox-style-declaration-properties
              declarations
              (lambda (property)
                (or (funcall predicate property)
                    (eq (plist-get property :group) 'paint)))))
            nil))))

(defvar ebox-canonical--box-configuration-cache (make-hash-table :test #'equal)
  "Bounded immutable layout configurations keyed by concrete layout input.")

(defun ebox-canonical-box-configuration (tag declarations)
  "Return provisional `:layout' and `:outer' inputs for Box TAG.
DECLARATIONS are canonical source declarations, validated for TAG.  Keep the
complete declarations in the source binding and derive owned facts from them.
Only concrete values enter this configuration; ECSS resolves tagged values
before rendering.  The returned plist is detached; its LayoutConfig is opaque."
  (let* ((names (ebox-layout-config-property-names tag))
         (concrete (ebox-style--concrete-declarations
                    (ebox-style-validate-form-declarations tag declarations)))
         (properties
          (ebox-style-declaration-properties
           concrete (lambda (property) (memq (plist-get property :name) names))))
         (outer (or (plist-get concrete 'ebox/outer) 'block))
         (key (list tag properties outer))
         (cached (gethash key ebox-canonical--box-configuration-cache)))
    (unless cached
      (setq cached (list :layout (ebox-layout-config-for-form tag properties)
                         :outer outer))
      (when (>= (hash-table-count ebox-canonical--box-configuration-cache) 128)
        (clrhash ebox-canonical--box-configuration-cache))
      (puthash (copy-tree key) cached ebox-canonical--box-configuration-cache))
    (copy-sequence cached)))

(defun ebox-canonical-facts-from-declarations (tag declarations &optional interactions)
  "Return immutable node-owned facts for TAG from DECLARATIONS.
Source declarations stay behind the source handle; the returned value contains
provisional concrete node properties.  Tagged values require ECSS computation.
INTERACTIONS is a plist of fixed node capabilities, separate from CSS."
  (let ((predicate
         (if (eq tag 'text)
             #'ebox-canonical--text-engine-property-p
           #'ebox-canonical--box-frame-property-p)))
    (pcase-let ((`(,canonical ,engine ,style-required-p)
                 (ebox-canonical--node-properties
                  nil (and declarations (cons t declarations))
                  predicate
                  (if (eq tag 'text) "Ebox Text" "Ebox Box") tag)))
      (ebox-canonical--make-facts
       :engine-properties
       (append engine
               (when interactions
                 (list :surface-properties
                       (ebox-interaction-surface-properties
                        (ebox-interaction-normalize interactions)))))
       :style-required-p style-required-p
       :specified-property-ids
       (cl-loop for (id _value) on canonical by #'cddr collect id)))))

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

(defun ebox-canonical--normalize-children (children source-builder)
  "Normalize CHILDREN, using explicit SOURCE-BUILDER for Range ownership."
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
    (setq material (nreverse material)
          segments (nreverse segments))
    (when source-builder
      (ebox-source--builder-assert-open source-builder)
      (dolist (child material)
        (unless (ebox-source--builder-record
                 source-builder (ebox-node-source-handle child))
          (error "Ebox child is not owned by :source-builder"))))
    (when range-p
      (unless (ebox-source-builder-p source-builder)
        (error "Ebox Range children require an explicit :source-builder"))
      (ebox-source--builder-assert-open source-builder))
    (let ((source-builder (and range-p source-builder)))
      (list material
            (and range-p
                 (ebox-child-range--build
                  segments
                  (lambda (node)
                    (let ((record
                           (ebox-source--builder-record
                            source-builder (ebox-node-source-handle node))))
                      (unless record
                        (error "Ebox Range child is not owned by :source-builder"))
                      (ebox-source-record-key record)))
                  nil t))))))

;;;###autoload
(defun ebox-text-create (&rest plist)
  "Create a canonical TextNode from evaluated PLIST.

`:value' is required and must be one string.  `:source-handle' is required and
is the only author source input.  Direct properties are limited to already
computed Text measurement facts."
  (ebox-canonical--validate-plist plist "ebox-text-create")
  (let* ((value (ebox-canonical--required-field
                 plist :value "Ebox Text"))
         (source-handle (ebox-canonical--source-handle plist "Ebox Text"))
         (facts (ebox-canonical--required-field
                 plist :owned-facts "Ebox Text"))
         (props (ebox-canonical--without-keys
                 plist
                 (append '(:value :owned-facts)
                         ebox-canonical--source-fields))))
    (unless (stringp value)
      (error "Ebox Text :value must be a string: %S" value))
    (when props
      (error "Ebox Text accepts only normalized owned facts"))
    (when (not (ebox-canonical-facts-p facts))
      (error "Ebox Text :owned-facts must be canonical facts: %S" facts))
    (pcase-let* ((engine-props
                  (ebox-canonical-facts-engine-properties facts))
                 (style-required-p
                  (ebox-canonical-facts-style-required-p facts))
                 (node
                  (ebox-node-factory--create-text-expanded
                   (append engine-props (list :content value)))))
      (plist-put node :ebox-kind 'text)
      (plist-put node :ebox-text-value value)
      (ebox-canonical--apply-source-handle node source-handle)
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
`:children' is a list of canonical nodes or transparent Range descriptors.
Range children require an open `:source-builder' owning their source handles.
Every Layout accepts zero or more children according to its own formatting
algorithm.  `:source-handle' remains the node's only author source input."
  (ebox-canonical--validate-plist plist "ebox-box-create")
  (let* ((layout (ebox-canonical--required-field
                  plist :layout "Ebox Box"))
         (children-field (ebox-canonical--optional-field
                          plist :children "Ebox Box"))
         (builder-field (ebox-canonical--optional-field
                         plist :source-builder "Ebox Box"))
         (outer-field (ebox-canonical--optional-field
                       plist :outer "Ebox Box"))
         (source-handle (ebox-canonical--source-handle plist "Ebox Box"))
         (facts (ebox-canonical--required-field
                 plist :owned-facts "Ebox Box"))
         (children (if children-field (cdr children-field) nil))
         child-sequence
         (outer (if outer-field (cdr outer-field) 'block))
         (props (ebox-canonical--without-keys
                 plist (append '(:layout :children :outer :owned-facts :source-builder)
                               ebox-canonical--source-fields))))
    (unless (ebox-layout-config-p layout)
      (error "Ebox Box :layout must be a typed layout config: %S"
             layout))
    (setq layout (ebox-layout-config--copy layout))
    (unless (memq outer '(inline block))
      (error "Ebox Box :outer must be inline or block: %S" outer))
    (unless (proper-list-p children)
      (error "Ebox Box :children must be a proper list: %S" children))
    (when builder-field
      (unless (ebox-source--builder-record (cdr builder-field) source-handle)
        (error "Ebox Box is not owned by :source-builder")))
    (pcase-let ((`(,material-children ,normalized-sequence)
                 (ebox-canonical--normalize-children children (cdr builder-field))))
      (setq children material-children)
      (setq child-sequence normalized-sequence))
    (unless (memq (ebox-layout-config-kind layout)
                  '(normal row column flex grid))
      (error "Ebox Box Layout is not implemented: %S"
             (ebox-layout-config-kind layout)))
    (when (eq (ebox-layout-config-kind layout) 'flex)
      (ebox--flex-validate-item-bases (ebox-layout-config-props layout) children))
    (when props
      (error "Ebox Box accepts only normalized owned facts"))
    (when (not (ebox-canonical-facts-p facts))
      (error "Ebox Box :owned-facts must be canonical facts: %S" facts))
    (pcase-let* ((`(,canonical-declarations ,engine-props ,style-required-p)
                   (list
                    (ebox-canonical-facts-specified-property-ids facts)
                    (ebox-canonical-facts-engine-properties facts)
                    (ebox-canonical-facts-style-required-p facts)))
                  (node (ebox-node-factory--create-expanded engine-props)))
      (plist-put node :ebox-kind 'box)
      (plist-put node :ebox-layout-config layout)
      (plist-put node :children children)
      (when (plist-member canonical-declarations
                          (ebox-style-schema-id :min-width))
        (plist-put node :ebox-explicit-min-width-p t))
      (when (plist-member canonical-declarations
                          (ebox-style-schema-id :min-height))
        (plist-put node :ebox-explicit-min-height-p t))
      (when child-sequence
        (plist-put node :ebox-child-sequence child-sequence))
      (ebox-canonical--apply-source-handle node source-handle)
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
