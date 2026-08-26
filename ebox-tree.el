;;; ebox-tree.el --- Element tree model for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns runtime identity, display accessors, child traversal, parent paths, and
;; parent participation metadata.  It does not own layout measurement or buffer
;; editing.

;;; Code:

(require 'cl-lib)

(require 'subr-x)
(require 'ecss-selector)
(require 'ebox-style)
(require 'ebox-child-range)
(require 'ebox-layout-config)

(declare-function ebox-get "ebox" (box property))
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--next-runtime-node-id "ebox" ())
(declare-function ebox--string-region-ids "ebox" (string))
(declare-function ebox--box-visible-overflow-p "ebox" (box))

(defconst ebox--default-display '(block flow)
  "Default CSS-like display for a plain Ebox box.")

(defvar ebox--node-region-ids-cache nil
  "Dynamic snapshot-detail-local node -> region ids cache.
This is an optimization for snapshot capture, not buffer runtime state.")
(defvar ebox--flex-item-prop-keys)
(defvar ebox--flex-item-direct-adapter-token)
(defvar ebox--flex-item-wrapper-adapter-token)
(defvar ebox-tree--legacy-flex-item-adapter-proofs
  (make-hash-table :test #'eq :weakness 'key)
  "Weak adapter -> construction-shape proofs for legacy Flex items.")

(defun ebox-tree-computed-display (node)
  "Return NODE's canonical CSS-like display pair."
  (or (and (listp node) (plist-get node :display))
      (pcase (and (listp node) (plist-get node :ebox-type))
        ('box '(block flow))
        ('concat '(block row))
        ('stack '(block column))
        ('flex '(block flex))
        ('grid '(block grid))
        ('flex-item '(block flow))
        (_ ebox--default-display))))

(defun ebox-tree-display-outer (node)
  "Return NODE's outer display."
  (car (ebox-tree-computed-display node)))

(defun ebox-tree-display-inner (node)
  "Return NODE's inner display."
  (cadr (ebox-tree-computed-display node)))

(defun ebox-tree-formatting-context-p (node)
  "Return non-nil when NODE establishes a child layout context."
  (memq (ebox-tree-display-inner node) '(row column flex grid)))

(defun ebox-tree-node-selector-type (node)
  "Return NODE's CSS-like selector type symbol."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box 'box)
    ('concat 'row)
    ('stack 'column)
    ('flex 'flex)
    ('grid 'grid)
    ('flex-item 'item)
    (_ nil)))

(defun ebox-tree-metadata-string (value)
  "Return VALUE normalized to a selector metadata string."
  (cond
   ((null value) nil)
   ((symbolp value) (symbol-name value))
   ((stringp value) value)
   (t (format "%s" value))))

(defun ebox-tree-node-id (node)
  "Return NODE's selector id string from `:id', or nil."
  (and (listp node)
       (ebox-tree-metadata-string (plist-get node :id))))

(defun ebox-tree--metadata-tokens (value)
  "Return VALUE as a list of normalized selector metadata tokens."
  (cond
   ((null value) nil)
   ((listp value)
    (delq nil (mapcar #'ebox-tree-metadata-string value)))
   (t (list (ebox-tree-metadata-string value)))))

(defun ebox-tree-node-classes (node)
  "Return NODE's selector class strings from `:class'."
  (and (listp node)
       (ebox-tree--metadata-tokens (plist-get node :class))))

(defun ebox-tree-node-state (node)
  "Return NODE's selector state tokens from `:selector-state'."
  (and (listp node)
       (ebox-tree--metadata-tokens (plist-get node :selector-state))))

(defun ebox-tree-node-key (node)
  "Return NODE's selector key string from `:key', or nil."
  (and (listp node)
       (ebox-tree-metadata-string (plist-get node :key))))

(defun ebox-tree--selector-attribute-key (key)
  "Return canonical keyword selector attribute KEY."
  (cond
   ((keywordp key) key)
   ((symbolp key) (intern (concat ":" (symbol-name key))))
   ((stringp key) (intern (if (string-prefix-p ":" key)
                              key
                            (concat ":" key))))
   (t (error "Ebox selector attribute name is invalid: %S" key))))

(defun ebox-tree--selector-attribute-value (value)
  "Return canonical selector attribute VALUE."
  (cond
   ((symbolp value) (symbol-name value))
   ((numberp value) (number-to-string value))
   (t (copy-tree value))))

(defun ebox-tree-node-attributes (node)
  "Return NODE's explicit selector attributes plus built-in id and key."
  (when (listp node)
    (let ((attributes
           (delq nil
                 (list (when-let* ((id (ebox-tree-node-id node)))
                         (cons :id id))
                       (when-let* ((key (ebox-tree-node-key node)))
                         (cons :key key))))))
      (dolist (attribute (plist-get node :selector-attributes))
        (unless (consp attribute)
          (error "Ebox selector attributes must be an alist: %S"
                 (plist-get node :selector-attributes)))
        (push (cons (ebox-tree--selector-attribute-key (car attribute))
                    (ebox-tree--selector-attribute-value (cdr attribute)))
              attributes))
      (nreverse attributes))))

(defun ebox-tree--children-raw (node)
  "Return NODE's direct child nodes without assigning runtime ids."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box
     (if (plist-member node :children)
         (plist-get node :children)
       (delq nil (list (plist-get node :ebox-content-node)))))
    ('concat
     (ebox-tree-layout-children node))
    ('stack
     (ebox-tree-layout-children node))
    ('flex
     (append (when-let* ((box (plist-get node :box)))
               (list box))
             (ebox-tree-layout-children node)))
    ('grid
     (append (when-let* ((box (plist-get node :box)))
               (list box))
             (ebox-tree-layout-children node)))
    ('flex-item
     (delq nil (list (plist-get node :node))))
    (_ nil)))

(defun ebox-tree-node-children (node)
  "Return NODE's direct declarative children without mutating them.
The returned nodes remain owned by their tree.  Callers may inspect them but
must not modify a published runtime tree through this accessor."
  (ebox-tree--children-raw node))

(defun ebox-tree-for-each-direct-child (node function)
  "Call FUNCTION for each direct child of NODE without materializing Ranges."
  (let ((type (and (listp node) (plist-get node :ebox-type)))
        (sequence (and (listp node)
                       (plist-get node :ebox-child-sequence))))
    (when (memq type '(flex grid))
      (when-let* ((box (plist-get node :box)))
        (funcall function box)))
    (if sequence
        (ebox-child-range--fold
         sequence
         (lambda (ignored child)
           (funcall function child)
           ignored)
         nil)
      (pcase type
        ('box
         (if (plist-member node :children)
             (dolist (child (plist-get node :children))
               (funcall function child))
           (when-let* ((child (plist-get node :ebox-content-node)))
             (funcall function child))))
        ((or 'concat 'stack 'flex 'grid)
         (dolist (child
                  (or (plist-get node :children)
                      (pcase type
                        ('concat
                         (delq nil (list (plist-get node :left)
                                         (plist-get node :right))))
                        ('stack
                         (delq nil (list (plist-get node :top)
                                         (plist-get node :bottom)))))))
           (funcall function child)))
        ('flex-item
         (when-let* ((child (plist-get node :node)))
           (funcall function child))))))
  node)

(defun ebox-tree-layout-children (node)
  "Return layout container children for NODE in render order.
New row/column containers store flat `:children'.  Legacy `ebox-concat' and
`ebox-stack' nodes may still carry `:left'/`:right' or `:top'/`:bottom'."
  (if (plist-member node :ebox-child-sequence)
      (ebox-child-range--flatten (plist-get node :ebox-child-sequence))
    (or (plist-get node :children)
        (pcase (and (listp node) (plist-get node :ebox-type))
          ('concat
           (delq nil (list (plist-get node :left)
                           (plist-get node :right))))
          ('stack
           (delq nil (list (plist-get node :top)
                           (plist-get node :bottom))))
          (_ nil)))))

(defun ebox-tree--replace-direct-child (child replacements)
  "Return CHILD's identity replacement from REPLACEMENTS, when present.
REPLACEMENTS is an alist whose keys are compared with `eq'.  Nil is not a
child and is therefore never used as a replacement key."
  (if-let* ((replacement (and child (assq child replacements))))
      (cdr replacement)
    child))

(defun ebox-tree--replace-direct-child-list (children replacements)
  "Replace CHILDREN found by identity in REPLACEMENTS.
Return CHILDREN itself when no child changes.  Otherwise return one new list
whose untouched child objects remain shared.  A nil replacement removes the
matched child from the returned sequence."
  (if (null replacements)
      children
    (let (changed replaced)
      (dolist (child children)
        (let ((replacement
               (ebox-tree--replace-direct-child child replacements)))
          (unless (eq replacement child)
            (setq changed t))
          (when replacement
            (push replacement replaced))))
      (if changed
          (nreverse replaced)
        children))))

(defun ebox-tree--replace-direct-child-property
    (node property replacements)
  "Replace NODE's direct child PROPERTY from REPLACEMENTS.
NODE must already be a shallow copy.  Return the possibly updated plist."
  (if (plist-member node property)
      (let* ((child (plist-get node property))
             (replacement
              (ebox-tree--replace-direct-child child replacements)))
        (if (eq replacement child)
            node
          (plist-put node property replacement)))
    node))

(defun ebox-tree-copy-with-direct-child-replacements (node replacements)
  "Return a shallow copy of NODE with direct child REPLACEMENTS applied.

REPLACEMENTS is an alist of (OLD-CHILD . NEW-CHILD) pairs.  OLD-CHILD is
matched by object identity, not structural equality.  Every supported child
slot is updated, including the legacy aliases retained by binary concat and
stack nodes.  Multiple replacements for one parent are applied to the same
single parent copy.  Untouched child objects remain `eq' to their originals.

A nil NEW-CHILD removes a matched child from a flat `:children' list and sets
a matched scalar child slot to nil.  With no replacements, the node plist is
still copied while every nested value remains shared."
  (unless (and (listp node) (not (stringp node)))
    (error "Ebox can only path-copy a node plist, got %S" node))
  (let* ((type (plist-get node :ebox-type))
         (copy (copy-sequence node))
         (scalar-properties
          (pcase type
            ('box '(:ebox-content-node))
            ('concat '(:left :right))
            ('stack '(:top :bottom))
            ('flex '(:box))
            ('grid '(:box))
            ('flex-item '(:node)))))
    (dolist (property scalar-properties)
      (setq copy
            (ebox-tree--replace-direct-child-property
             copy property replacements)))
    (when (and (or (memq type '(concat stack flex grid))
                   (and (eq type 'box) (plist-member copy :children)))
               (plist-member copy :children))
      (let* ((children (plist-get copy :children))
             (replaced
              (ebox-tree--replace-direct-child-list children replacements)))
        (unless (eq replaced children)
          (setq copy (plist-put copy :children replaced)))))
    (when-let* ((sequence (and (memq type '(concat stack flex grid))
                              (plist-get copy :ebox-child-sequence))))
      (let ((updated sequence) changed fallback)
        (dolist (replacement replacements)
          (let* ((old (car replacement)) (new (cdr replacement))
                 (location (and old (plist-get old :ebox-sequence-location)))
                 (key (and old (plist-get old :key)))
                 (key-location
                  (and (null location) key
                       (ebox-child-range--hash-lookup
                        (ebox-child-range--sequence-key-root updated) key
                        (funcall
                         (ebox-child-range--sequence-hash-function updated)
                         key)))))
            (when key-location
              (let* ((segment (ebox-child-range--segment-at
                               updated (car key-location)))
                     (candidate (aref
                                 (ebox-child-range--segment-payload segment)
                                 (cdr key-location))))
                (when (eq candidate old)
                  (setq location
                        (list :parent-node-id (plist-get node :node-id)
                              :segment-index (car key-location)
                              :offset (cdr key-location))))))
            (when (and location
                       (equal (plist-get location :parent-node-id)
                              (plist-get node :node-id)))
              (if new
                  (setq updated
                        (ebox-child-range--replace-item-at
                         updated (plist-get location :segment-index)
                         (plist-get location :offset) old new)
                        changed t)
                (setq fallback t)))))
        (when fallback
          (let (segments)
            (dotimes (index (ebox-child-range--sequence-count sequence))
              (let* ((segment (ebox-child-range--segment-at sequence index))
                     (items (append
                             (ebox-child-range--segment-payload segment) nil)))
                (push (cons (ebox-child-range--segment-ref segment)
                            (ebox-tree--replace-direct-child-list
                             items replacements))
                      segments)))
            (setq updated (ebox-child-range--build (nreverse segments))
                  changed t)))
        (when changed
          (setq copy (plist-put copy :ebox-child-sequence updated)))))
    copy))

(defun ebox-tree-copy-node-structure (root)
  "Copy every Ebox node below ROOT while preserving opaque leaf values.
The returned tree owns distinct node plists and child lists.  Values such as
keymaps, callbacks, Host references, and surface-property payloads retain their
original object identity."
  (cl-labels
      ((without (plist key)
         (cl-loop for (property value) on plist by #'cddr
                  unless (eq property key) append (list property value)))
       (copy-node
        (node)
        (if (or (not (listp node)) (stringp node))
            node
          (let* ((type (plist-get node :ebox-type))
                 (material-p (memq type '(concat stack flex grid)))
                 (raw (and material-p (plist-get node :children)))
                 (sequence (and material-p
                                (plist-get node :ebox-child-sequence)))
                 (has-range (cl-some #'ebox-child-range--descriptor-p raw)))
            (if (or has-range sequence)
                (let ((copy (copy-sequence node)) segments)
                  (if sequence
                      (dotimes (index
                                (ebox-child-range--sequence-count sequence))
                        (let ((segment
                               (ebox-child-range--segment-at sequence index)))
                          (push
                           (cons (ebox-child-range--segment-ref segment)
                                 (mapcar #'copy-node
                                         (append
                                          (ebox-child-range--segment-payload
                                           segment)
                                          nil)))
                           segments)))
                    (dolist (entry raw)
                      (if (ebox-child-range--descriptor-p entry)
                          (push (cons (ebox-child-range--descriptor-ref entry)
                                      (mapcar
                                       #'copy-node
                                       (ebox-child-range--descriptor-items entry)))
                                segments)
                        (push (cons nil (list (copy-node entry))) segments))))
                  (setq copy (without copy :children))
                  (pcase type
                    ((or 'flex 'grid)
                     (when-let* ((box (plist-get node :box)))
                       (setq copy (plist-put copy :box (copy-node box)))))
                    ('concat
                     (setq copy (without (without copy :left) :right)))
                    ('stack
                     (setq copy (without (without copy :top) :bottom))))
                  (plist-put copy :ebox-child-sequence
                             (ebox-child-range--build (nreverse segments))))
              (let ((copy
                     (ebox-tree-copy-with-direct-child-replacements
                      node
                      (mapcar (lambda (child)
                                (cons child (copy-node child)))
                              (ebox-tree--children-raw node)))))
                ;; Only this exact deep-copy traversal has proven every copied
                ;; child derives from the authentic source tree.  Generic
                ;; path-copy replacements must not launder adapter provenance.
                (ebox-tree--remint-legacy-flex-item-adapter-proof
                 node copy)))))))
    (copy-node root)))

(defun ebox-tree--runtime-identity-node-shell
    (node node-id-set region-id-set)
  "Return NODE's identity-only shell.
Record its identities in NODE-ID-SET and REGION-ID-SET."
  (let ((node-id (plist-get node :node-id))
        (type (plist-get node :ebox-type))
        shell)
    (unless node-id
      (error "Ebox runtime identity snapshot found a node without identity"))
    (puthash node-id t node-id-set)
    (setq shell (list :ebox-type type :node-id node-id))
    (when (plist-member node :key)
      (setq shell (plist-put shell :key (plist-get node :key))))
    (when (eq type 'box)
      (let ((region-id (plist-get node :region-id)))
        (unless region-id
          (error "Ebox runtime identity snapshot found a box without region"))
        (puthash region-id t region-id-set)
        (setq shell (plist-put shell :region-id region-id))))
    shell))

(defun ebox-tree--runtime-identity-skeleton
    (node node-id-set region-id-set)
  "Return identity-only NODE shape.
Record its identities in NODE-ID-SET and REGION-ID-SET."
  (let ((shell
         (ebox-tree--runtime-identity-node-shell
          node node-id-set region-id-set)))
    (pcase (plist-get node :ebox-type)
      ('box
       (if (plist-member node :children)
           (plist-put shell :children
                      (mapcar
                       (lambda (child)
                         (ebox-tree--runtime-identity-skeleton
                          child node-id-set region-id-set))
                       (plist-get node :children)))
         (when-let* ((child (plist-get node :ebox-content-node)))
           (plist-put shell :ebox-content-node
                      (ebox-tree--runtime-identity-skeleton
                       child node-id-set region-id-set)))))
      ((or 'concat 'stack)
       (plist-put shell :children
                  (mapcar
                   (lambda (child)
                     (ebox-tree--runtime-identity-skeleton
                      child node-id-set region-id-set))
                   (ebox-tree-layout-children node))))
      ((or 'flex 'grid)
       (when-let* ((box (plist-get node :box)))
         (plist-put shell :box
                    (ebox-tree--runtime-identity-skeleton
                     box node-id-set region-id-set)))
       (plist-put shell :children
                  (mapcar
                   (lambda (child)
                     (ebox-tree--runtime-identity-skeleton
                      child node-id-set region-id-set))
                   (ebox-tree-layout-children node))))
      ('flex-item
       (when-let* ((child (plist-get node :node)))
         (plist-put shell :node
                    (ebox-tree--runtime-identity-skeleton
                     child node-id-set region-id-set)))))
    shell))

(defun ebox-tree-runtime-identity-snapshot (root)
  "Return ROOT's payload-free runtime identity snapshot.
The result owns only Ebox type, key, child shape, node identity, and box
region identity.  It never retains content, callbacks, Host references,
surface payloads, render caches, or scroll state."
  (let ((node-id-set (make-hash-table :test 'equal))
        (region-id-set (make-hash-table :test 'equal)))
    (let ((skeleton
           (ebox-tree--runtime-identity-skeleton
            root node-id-set region-id-set)))
      (list :root skeleton
            :node-id-set node-id-set
            :region-id-set region-id-set
            :node-count (hash-table-count node-id-set)))))

(defun ebox-tree-children (node)
  "Return NODE's runtime child nodes.
Renderable child nodes are assigned stable runtime ids before returning."
  (let ((children (ebox-tree--children-raw node)))
    (dolist (child children)
      (when (and (listp child) (not (stringp child)))
        (ebox--ensure-node-id child)))
    children))

(defun ebox-tree-validate-host-refs (root)
  "Reject duplicate non-nil `:host-ref' values below ROOT and return ROOT.
Host references are root-global opaque metadata and are compared with `equal'."
  (let ((host-refs (make-hash-table :test 'equal))
        (seen (make-hash-table :test 'eq))
        (active (make-hash-table :test 'eq)))
    (cl-labels
        ((visit (node)
           (when (and (listp node) (not (stringp node)))
             ;; Let the complete declarative validator report cycles.  This
             ;; focused preflight is also used by initial buffer mounting,
             ;; where it must remain finite for malformed graphs.
             (unless (gethash node active)
               (when-let* ((host-ref (plist-get node :host-ref)))
                 (let ((count (hash-table-count host-refs)))
                   (puthash host-ref t host-refs)
                   (when (= count (hash-table-count host-refs))
                     (error
                      "Ebox declarative tree uses duplicate host ref %S"
                      host-ref))))
               (unless (gethash node seen)
                 (puthash node t seen)
                 (puthash node t active)
                 (dolist (child (ebox-tree--children-raw node))
                   (if (ebox-child-range--descriptor-p child)
                       (dolist (item (ebox-child-range--descriptor-items child))
                         (visit item))
                     (visit child)))
                 (remhash node active))))))
      (visit root))
    root))

(defconst ebox-tree--common-participation-keys
  '(:order :align-self)
  "Participation properties shared by Flex and Grid children.")

(defconst ebox-tree--flex-participation-keys
  '(:flex :flex-grow :flex-shrink :flex-basis)
  "Properties accepted only on a direct Flex child Box.")

(defconst ebox-tree--grid-participation-keys
  '(:grid-column :grid-row :grid-column-span :grid-row-span :justify-self)
  "Properties accepted only on a direct Grid child Box.")

(defconst ebox-tree--participation-keys
  (append ebox-tree--common-participation-keys
          ebox-tree--flex-participation-keys
          ebox-tree--grid-participation-keys)
  "Complete canonical parent-participation property domain.")

(defun ebox-tree--style-specifies-participation-p (style key)
  "Return non-nil when computed STYLE has a declaration winner for KEY."
  (and style
       (ebox-style--specified-property-p style (ebox-style-schema-id key))))

(defun ebox-tree--declarations-specify-participation-p (node key)
  "Return non-nil when NODE author declarations specify participation KEY."
  (and (listp node)
       (plist-member (ebox-style-node-declarations node)
                     (ebox-style-schema-id key))))

(defun ebox-tree--author-specifies-participation-p (node key)
  "Return non-nil when NODE's author source specifies participation KEY."
  (if (eq (plist-get node :ebox-type) 'flex-item)
      (let* ((adapter-source (plist-get node :node))
             (content (and (listp adapter-source)
                           (plist-get adapter-source :ebox-content-node)))
             (projected-p
              (or (and (listp adapter-source)
                       (plist-get adapter-source :ebox-computed-style))
                  (and (listp content)
                       (plist-get content :ebox-computed-style)))))
        (or (ebox-tree--declarations-specify-participation-p
             adapter-source key)
            (ebox-tree--declarations-specify-participation-p content key)
            (and (not projected-p)
                 (plist-member (plist-get node :props) key))))
    (or (ebox-tree--declarations-specify-participation-p node key)
        (and (null (plist-get node :ebox-computed-style))
             (plist-member node key)))))

(defun ebox-tree--node-participation-keys (node source)
  "Return NODE participation keys from AUTHOR or COMPUTED SOURCE."
  (let ((flex-item-p (eq (plist-get node :ebox-type) 'flex-item))
        (style (plist-get node :ebox-computed-style))
        keys)
    (dolist (key ebox-tree--participation-keys)
      (when
          (pcase source
            ('author
             (ebox-tree--author-specifies-participation-p node key))
            ('computed
             (if flex-item-p
                 (let* ((adapter-source (plist-get node :node))
                        (adapter-style
                         (and (listp adapter-source)
                              (plist-get adapter-source
                                         :ebox-computed-style)))
                        (content (and (listp adapter-source)
                                      (plist-get adapter-source
                                                 :ebox-content-node)))
                        (content-style
                         (and (listp content)
                              (plist-get content :ebox-computed-style))))
                   (and (plist-member (plist-get node :props) key)
                        (or (ebox-tree--style-specifies-participation-p
                             adapter-style key)
                            (ebox-tree--style-specifies-participation-p
                             content-style key))))
               (and (plist-member node key)
                    (ebox-tree--style-specifies-participation-p style key))))
            (_ (error "Unknown Ebox participation source: %S" source)))
        (push key keys)))
    (nreverse keys)))

(defun ebox-tree--child-layout-kind (node parent-kind)
  "Return layout kind governing NODE children, preserving transparent adapters."
  (pcase (plist-get node :ebox-type)
    ('flex-item parent-kind)
    ('flex 'flex)
    ('grid 'grid)
    (_ (pcase (if (and (eq (plist-get node :ebox-kind) 'box)
                       (plist-get node :ebox-layout-config))
                  (ebox-layout-config-kind
                   (plist-get node :ebox-layout-config))
                (ebox-tree-display-inner node))
         ('flow 'normal)
         (kind kind)))))

(defun ebox-tree--legacy-flex-item-adapter-p (node token)
  "Return non-nil when NODE has the exact legacy Flex adapter TOKEN shape."
  (let ((proof (gethash node ebox-tree--legacy-flex-item-adapter-proofs))
        (source (plist-get node :node)))
    (and token
         (eq (plist-get node :ebox-type) 'flex-item)
         (vectorp proof)
         (= (length proof) 3)
         (eq (aref proof 0) token)
         (eq (aref proof 1) source)
         (listp source)
         (not (stringp source))
         (let ((children (ebox-tree--children-raw node)))
           (and (eq (car children) source)
                (null (cdr children))))
         (if (eq token ebox--flex-item-wrapper-adapter-token)
             (let ((content (plist-get source :ebox-content-node)))
               (and (eq (plist-get source :ebox-type) 'box)
                    (listp content)
                    (not (stringp content))
                    (eq (aref proof 2) content)))
           (null (aref proof 2))))))

(defun ebox-tree--register-legacy-flex-item-adapter
    (adapter token source content)
  "Register ADAPTER's exact TOKEN, SOURCE, and optional CONTENT identities."
  (puthash adapter (vector token source content)
           ebox-tree--legacy-flex-item-adapter-proofs)
  adapter)

(defun ebox-tree--remint-legacy-flex-item-adapter-proof (old new)
  "Bind NEW adapter provenance to copied children when OLD is authentic."
  (cond
   ((ebox-tree--legacy-flex-item-adapter-p
     old ebox--flex-item-direct-adapter-token)
    (ebox-tree--register-legacy-flex-item-adapter
     new ebox--flex-item-direct-adapter-token (plist-get new :node) nil))
   ((ebox-tree--legacy-flex-item-adapter-p
     old ebox--flex-item-wrapper-adapter-token)
    (let ((wrapper (plist-get new :node)))
      (ebox-tree--register-legacy-flex-item-adapter
       new ebox--flex-item-wrapper-adapter-token
       wrapper (plist-get wrapper :ebox-content-node))))
   (t
    (remhash new ebox-tree--legacy-flex-item-adapter-proofs)
    new)))

(defun ebox-tree--legacy-flex-item-duplicate-p (node parent grandparent)
  "Return non-nil when NODE is an exact duplicate inside a legacy adapter."
  (or
   (and (ebox-tree--legacy-flex-item-adapter-p
         parent ebox--flex-item-direct-adapter-token)
        (eq node (plist-get parent :node)))
   (and (ebox-tree--legacy-flex-item-adapter-p
         parent ebox--flex-item-wrapper-adapter-token)
        (let ((wrapper (plist-get parent :node)))
          (and (eq node wrapper)
               (eq (plist-get wrapper :ebox-type) 'box)
               (listp (plist-get wrapper :ebox-content-node)))))
   (and (ebox-tree--legacy-flex-item-adapter-p
         grandparent ebox--flex-item-wrapper-adapter-token)
        (let ((wrapper (plist-get grandparent :node)))
          (and (eq parent wrapper)
               (eq (plist-get wrapper :ebox-type) 'box)
               (eq node (plist-get wrapper :ebox-content-node)))))))

(defun ebox-tree--validate-node-parent-participation
    (node parent-kind parent grandparent source)
  "Validate NODE participation under PARENT-KIND from AUTHOR or COMPUTED SOURCE."
  (unless (ebox-tree--legacy-flex-item-duplicate-p node parent grandparent)
    (let ((keys (ebox-tree--node-participation-keys node source)))
      (when keys
        (when (eq (plist-get node :ebox-kind) 'text)
          (error "Ebox Text cannot carry participation properties: %S" keys))
        (pcase parent-kind
          ('flex
           (when (cl-intersection
                  keys ebox-tree--grid-participation-keys :test #'eq)
             (error "Grid participation requires a direct Grid parent: %S"
                    keys)))
          ('grid
           (when (cl-intersection
                  keys ebox-tree--flex-participation-keys :test #'eq)
             (error "Flex participation requires a direct Flex parent: %S"
                    keys)))
          (_ (error "Ebox participation requires a Flex or Grid parent: %S"
                    keys))))))
  node)

(defun ebox-tree--indexed-parent-context
    (node-id node-table parent-table)
  "Return (PARENT-KIND PARENT GRANDPARENT) for NODE-ID in indexed tree."
  (let* ((parent-id (gethash node-id parent-table))
         (parent (and parent-id (gethash parent-id node-table)))
         (grandparent-id (and parent-id (gethash parent-id parent-table)))
         (grandparent (and grandparent-id
                           (gethash grandparent-id node-table)))
         (layout-owner parent))
    (while (and layout-owner
                (eq (plist-get layout-owner :ebox-type) 'flex-item))
      (let ((owner-id (plist-get layout-owner :node-id)))
        (setq owner-id (and owner-id (gethash owner-id parent-table))
              layout-owner (and owner-id (gethash owner-id node-table)))))
    (list (and layout-owner
               (ebox-tree--child-layout-kind layout-owner nil))
          parent grandparent)))

(defun ebox-tree-validate-indexed-participation
    (node-table parent-table node-ids &optional source)
  "Validate NODE-IDS in indexed final tree using AUTHOR or COMPUTED SOURCE."
  (setq source (or source 'author))
  (dolist (node-id (delete-dups (copy-sequence node-ids)))
    (when-let* ((node (gethash node-id node-table)))
      (pcase-let ((`(,parent-kind ,parent ,grandparent)
                   (ebox-tree--indexed-parent-context
                    node-id node-table parent-table)))
        (ebox-tree--validate-node-parent-participation
         node parent-kind parent grandparent source))))
  node-table)

(defun ebox-tree-validate-declarative-root
    (root &optional validate-participation-p root-parent-kind)
  "Validate ROOT for one declarative runtime commit.

The runtime tree must be a proper tree: a node object cannot appear in two
locations, cycles are rejected, explicit sibling keys must be unique, and
non-nil host references must be unique across the root.  Keys are sibling-local
and all explicit identities are compared with `equal'.  Return ROOT on success."
  (when (ebox-child-range--descriptor-p root)
    (error "Ebox child Range descriptor cannot be the root"))
  (ebox-tree-validate-host-refs root)
  (let ((seen (make-hash-table :test 'eq))
        (active (make-hash-table :test 'eq))
        (range-refs (make-hash-table :test 'equal)))
    (cl-labels
        ((visit (node parent-kind parent grandparent)
           (when (and (listp node) (not (stringp node)))
             (when (gethash node active)
               (error "Ebox declarative tree contains a cycle"))
             (when (gethash node seen)
               (error "Ebox declarative tree reuses one node object"))
             (puthash node t seen)
             (puthash node t active)
             (when validate-participation-p
               (ebox-tree--validate-node-parent-participation
                node parent-kind parent grandparent 'author))
             (let* ((keys (make-hash-table :test 'equal))
                    (type (plist-get node :ebox-type))
                    (raw (and (memq type '(concat stack flex grid))
                              (plist-get node :children)))
                    children)
               (when (and raw (not (proper-list-p raw)))
                 (error "Ebox material children must be a proper list"))
               (dolist (entry (ebox-tree--children-raw node))
                 (if (ebox-child-range--descriptor-p entry)
                     (progn
                       (unless (and (proper-list-p raw) (memq entry raw))
                         (error "Ebox child Range descriptor is invalid in a scalar slot"))
                       (let ((ref (ebox-child-range--descriptor-ref entry))
                             (items (ebox-child-range--descriptor-items entry)))
                         (unless (and ref (proper-list-p items))
                           (error "Ebox child Range descriptor is invalid"))
                         (when (gethash ref range-refs)
                           (error "Ebox child Range ref is not unique: %S" ref))
                         (puthash ref t range-refs)
                         (dolist (item items)
                           (when (ebox-child-range--descriptor-p item)
                             (error "Nested child Range descriptors are reserved"))
                           (unless (and (listp item) (not (stringp item)))
                             (error "Ebox child Range item must be a node"))
                           (push item children))))
                   (progn
                     (when (ebox-child-range--descriptor-p entry)
                       (error "Ebox child Range descriptor is invalid here"))
                     (push entry children))))
               (dolist (child (nreverse children))
                 (when-let* ((key (and (listp child)
                                      (not (stringp child))
                                      (plist-get child :key))))
                     (when (gethash key keys)
                       (error "Ebox declarative siblings use duplicate key %S"
                              key))
                     (puthash key t keys))
                 (visit child
                        (ebox-tree--child-layout-kind node parent-kind)
                        node parent)))
             (remhash node active))))
      (visit root root-parent-kind nil nil))
    root))

(defun ebox-tree-clear-runtime-identities (root)
  "Clear Ebox-owned runtime identity fields below ROOT and return ROOT."
  (cl-labels
      ((visit (node)
         (when (and (listp node) (not (stringp node)))
           (when (plist-member node :node-id)
             (plist-put node :node-id nil))
           (when (eq (plist-get node :ebox-type) 'box)
             (when (plist-member node :region-id)
               (plist-put node :region-id nil)))
           (when (plist-member node :surface-object)
             (plist-put node :surface-object nil))
           (when (plist-member node :ebox-sequence-location)
             (plist-put node :ebox-sequence-location nil))
           (dolist (child (ebox-tree--children-raw node))
             (visit child)))))
    (visit root))
  root)

(defconst ebox-tree--runtime-source-keys
  '(:node-id :region-id :surface-object :render-cache :ebox-sequence-location
    :ebox-content-width-exact-p)
  "Runtime-owned plist keys excluded from declarative source signatures.")

(defconst ebox-tree--child-source-keys
  '(:children :ebox-child-sequence :left :right :top :bottom :node :box
    :ebox-content-node)
  "Child references excluded from node-local declarative signatures.")

(defconst ebox-tree--excluded-source-keys
  (append ebox-tree--runtime-source-keys
          ebox-tree--child-source-keys
          '(:ebox-style-declarations :ebox-style-overrides
            :ebox-grid-config
            :ebox-computed-style :ebox-style-wrapper
            :ebox-style-generated-wrapper))
  "Non-rendering keys excluded from node-local source comparison.
Cascade declarations and computed-style records are side state; their
projected Ebox longhands carry the actual paint and layout consequences.")

(defconst ebox-tree-metadata-source-keys
  '(:key :id :class :host-ref)
  "Declarative metadata keys that do not directly change rendered text.")

(defun ebox-tree--plist-keys (plist)
  "Return keys from PLIST in source order."
  (cl-loop for (key _value) on plist by #'cddr collect key))

(defun ebox-tree--layout-props-source-signature (node)
  "Return canonical layout-only props for a Grid/Flex NODE.
Raw layout props also carry derived paint aliases, host references, duplicate
width entries, and shorthand gap forms.  Those fields are already represented
by style declarations or runtime identity and must not make a Theme repaint
look like a geometry mutation."
  (when (memq (plist-get node :ebox-type) '(grid flex))
    (let* ((raw (or (plist-get node :raw-props)
                    (plist-get node :props)))
           ;; Compare the same engine vocabulary used by Ebox rendering.  A
           ;; retained node may arrive once from an already-expanded style
           ;; snapshot and later from fresh shorthand declarations; comparing
           ;; those source spellings directly creates fake geometry dirtiness.
           (raw (ebox-style-expand-ebox-plist raw))
           (table (make-hash-table :test #'eq)))
      (cl-loop for (key value) on raw by #'cddr
               unless (memq key '(:color :background-color :bgcolor :host-ref
                                  :surface-properties))
               do (puthash key value table))
      (when (plist-member raw :gap)
        (let* ((gap (plist-get raw :gap))
               (row (if (consp gap) (car gap) gap))
               (column (if (and (consp gap) (cdr gap)) (cadr gap) row))
               ;; Flex and Grid deliberately have separate canonical
               ;; property vocabularies.  Using Grid aliases for a Flex node
               ;; makes an unchanged `gap' look like geometry dirtiness on
               ;; the next retained generation.
               (row-key (if (eq (plist-get node :ebox-type) 'grid)
                            :grid-row-gap
                          :row-gap))
               (column-key (if (eq (plist-get node :ebox-type) 'grid)
                               :grid-column-gap
                             :column-gap)))
          (puthash row-key row table)
          (puthash column-key column table)
          (remhash :gap table)))
      (let (keys)
        (maphash (lambda (key _value) (push key keys)) table)
        (setq keys
              (sort keys
                    (lambda (left right)
                      (string< (symbol-name left)
                               (symbol-name right)))))
        (cl-loop for key in keys
                 append (list key (gethash key table)))))))

(defun ebox-tree--local-source-signature (node)
  "Return NODE's filtered local declarative source signature."
  (let ((plist node)
        signature)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (unless (or (memq key ebox-tree--excluded-source-keys)
                    (and (memq key '(:props :raw-props))
                         (memq (plist-get node :ebox-type) '(grid flex))))
          (push key signature)
          (push value signature))))
    (when-let* ((layout (ebox-tree--layout-props-source-signature node)))
      (push :ebox-layout-props signature)
      (push layout signature))
    (nreverse signature)))

(defun ebox-tree-node-local-source-signature (node)
  "Return NODE's non-recursive declarative source signature.

Runtime identities, caches, and child pointers are excluded.  Child order is
compared independently through stable runtime ids, so a leaf change does not
mark every ancestor dirty."
  (ebox-tree--local-source-signature node))

(defun ebox-tree--next-local-source-entry (plist)
  "Return PLIST's next node-local source entry, skipping excluded keys."
  (while (and plist
              (memq (car plist) ebox-tree--excluded-source-keys))
    (setq plist (cddr plist)))
  plist)

(defun ebox-tree--local-source-sequence-equal-p (old new)
  "Return non-nil when filtered OLD and NEW source sequences are equal."
  (let ((old (ebox-tree--next-local-source-entry old))
        (new (ebox-tree--next-local-source-entry new))
        equal-p)
    (setq equal-p t)
    (while (and equal-p old new)
      (setq equal-p
            (and (eq (car old) (car new))
                 (equal-including-properties (cadr old) (cadr new))))
      (setq old (ebox-tree--next-local-source-entry (cddr old))
            new (ebox-tree--next-local-source-entry (cddr new))))
    (and equal-p (null old) (null new))))

(defun ebox-tree-node-local-changed-keys (old new)
  "Return ordered declarative keys whose node-local values differ.
OLD and NEW are source nodes with the same retained runtime identity."
  (let ((old-signature (ebox-tree--local-source-signature old))
        (new-signature (ebox-tree--local-source-signature new))
        seen changed)
    (dolist (source (list old-signature new-signature))
      (let ((plist source))
        (while plist
          (let ((key (pop plist)))
            (pop plist)
            (unless (memq key seen)
              (push key seen)
              (let ((old-entry (plist-member old-signature key))
                    (new-entry (plist-member new-signature key)))
                (unless (and (eq (not (null old-entry))
                                 (not (null new-entry)))
                             (equal-including-properties
                              (cadr old-entry) (cadr new-entry)))
                  (push (if (eq key :ebox-layout-props) :props key)
                        changed))))))))
    (nreverse changed)))

(defun ebox-tree-transfer-runtime-identity (old new)
  "Transfer retained runtime identity from matching OLD to NEW.

Callers are responsible for deciding whether OLD and NEW are the same keyed
or positional node.  A retained box keeps its node id, public region id, and
host-owned scroll position so buffer properties, interaction state, and the
candidate runtime index agree."
  (if (and old
           (listp old)
           (listp new)
           (eq (plist-get old :ebox-type)
               (plist-get new :ebox-type)))
      (progn
        (plist-put new :node-id (ebox--ensure-node-id old))
        (when (plist-member old :ebox-sequence-location)
          (plist-put new :ebox-sequence-location
                     (copy-sequence (plist-get old :ebox-sequence-location))))
        (when (eq (plist-get new :ebox-type) 'box)
          (plist-put new :region-id (ebox--ensure-region-id old))
          ;; Omitted scroll state is uncontrolled host state.  `ebox-create'
          ;; records explicit :scroll-offset input, which gives declarative
          ;; callers a controlled reset/jump without a second region-update
          ;; transaction.
          (when (and (not (plist-get new
                                     :ebox-scroll-offset-controlled-p))
                     (plist-member old :scroll-offset))
            (plist-put new :scroll-offset (plist-get old :scroll-offset)))))
    (plist-put new :node-id (ebox--next-runtime-node-id)))
  new)

(defun ebox-tree-reconcile-runtime (old new)
  "Transfer stable keyed and positional runtime identity from OLD to NEW."
  (cl-labels
      ((node-key
        (node)
        (when (and (listp node) (plist-member node :key))
          (plist-get node :key)))
       (same-type-p
        (old-node new-node)
        (and (listp old-node)
             (listp new-node)
             (eq (plist-get old-node :ebox-type)
                 (plist-get new-node :ebox-type))))
       (keyed-children
        (children)
        (let ((table (make-hash-table :test 'equal)))
          (dolist (child children table)
            (when-let* ((key (node-key child)))
              (puthash key child table)))))
       (match-child
        (old-children old-keyed new-child index)
        (if-let* ((key (node-key new-child)))
            (let ((old-child (gethash key old-keyed)))
              (and (same-type-p old-child new-child) old-child))
          (let ((old-child (nth index old-children)))
            (and (not (node-key old-child))
                 (same-type-p old-child new-child)
                 old-child))))
       (reconcile
        (old-node new-node)
        (when (and (listp new-node) (not (stringp new-node)))
          (ebox-tree-transfer-runtime-identity old-node new-node)
          (let* ((old-children
                  (and old-node (ebox-tree--children-raw old-node)))
                 (new-children (ebox-tree--children-raw new-node))
                 (old-keyed (keyed-children old-children)))
            (cl-loop for new-child in new-children
                     for index from 0
                     do (reconcile
                         (match-child
                          old-children old-keyed new-child index)
                         new-child))))))
    (reconcile old new))
  new)

(defun ebox-tree-flex-direct-participation-props (node)
  "Return raw flex participation properties stored directly on NODE."
  (let (props)
    (when (listp node)
      (dolist (key ebox--flex-item-prop-keys)
        (when (plist-member node key)
          (setq props (append props (list key (plist-get node key)))))))
    props))

(defun ebox-tree-flex-item-source-node (node)
  "Return the renderable source node for a flex item candidate."
  (if (and (listp node) (eq (plist-get node :ebox-type) 'flex-item))
      (plist-get node :node)
    node))

(defun ebox-tree--semantic-layout-leaves (node)
  "Return semantic leaves below internal layout adapter NODE."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ((or 'concat 'stack)
     (apply #'append
            (mapcar #'ebox-tree--semantic-layout-leaves
                    (ebox-tree-layout-children node))))
    ('flex-item
     (ebox-tree--semantic-layout-leaves (plist-get node :node)))
    (_ (and (listp node) (list node)))))

(defun ebox-tree-semantic-children (node)
  "Return NODE's logical children without internal layout adapters."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box
     (if (plist-member node :children)
         (plist-get node :children)
       (when-let* ((content-node (plist-get node :ebox-content-node)))
         (ebox-tree--semantic-layout-leaves content-node))))
    ((or 'concat 'stack)
     (ebox-tree--semantic-layout-leaves node))
    ('flex
     (mapcar #'ebox-tree-flex-item-source-node (ebox-tree-layout-children node)))
    ('grid (ebox-tree-layout-children node))
    ('flex-item (delq nil (list (plist-get node :node))))
    (_ (ebox-tree-children node))))

(defun ebox-tree-selector-index (root)
  "Return id, class, and type indexes over ROOT's logical selector tree."
  (let ((id-table (make-hash-table :test #'equal))
        (class-table (make-hash-table :test #'equal))
        (type-table (make-hash-table :test #'eq)))
    (cl-labels
        ((prepend (table key entry)
           (puthash key (cons entry (gethash key table)) table))
         (visit (node path)
           (when (and (listp node) (not (stringp node)))
             (let* ((current-path (append path (list node)))
                    (entry (cons node current-path)))
               (when-let* ((id (ebox-tree-node-id node)))
                 (prepend id-table id entry))
               (dolist (class (ebox-tree-node-classes node))
                 (prepend class-table class entry))
               (when-let* ((type (ebox-tree-node-selector-type node)))
                 (prepend type-table type entry))
               (dolist (child (ebox-tree-semantic-children node))
                 (visit child current-path))))))
      (visit root nil))
    (dolist (table (list id-table class-table type-table))
      (maphash (lambda (key entries)
                 (puthash key (nreverse entries) table))
               table))
    (list :selector-id-table id-table
          :selector-class-table class-table
          :selector-type-table type-table)))

(defun ebox-tree-node-subject (node)
  "Return a detached ECSS selector subject representing NODE."
  (ecss-subject-create
   :type (ebox-tree-metadata-string (ebox-tree-node-selector-type node))
   :id (ebox-tree-node-id node)
   :classes (ebox-tree-node-classes node)
   :attributes
   (mapcar (lambda (attribute)
             (cons (substring (symbol-name (car attribute)) 1)
                   (cdr attribute)))
           (ebox-tree-node-attributes node))
   :states (ebox-tree-node-state node)))

(defun ebox-tree-subject-index (root)
  "Return ECSS subjects and semantic node paths below ROOT in document order."
  (let ((node-subject-table (make-hash-table :test #'eq))
        entries)
    (cl-labels
        ((visit (node path)
           (when (and (listp node) (not (stringp node)))
             (let* ((subject (ebox-tree-node-subject node))
                    (current-path (append path (list node))))
               (puthash node subject node-subject-table)
               (push (list :node node :path current-path :subject subject)
                     entries)
               (ecss-subject-set-children
                subject
                (delq nil
                      (mapcar (lambda (child) (visit child current-path))
                              (ebox-tree-semantic-children node))))
               subject))))
      (let ((root-subject (visit root nil)))
        (list :root-subject root-subject
              :entries (nreverse entries)
              :node-subject-table node-subject-table)))))

(defun ebox-tree-subject-for-path (path)
  "Return an ECSS subject chain for the root-to-node Ebox PATH."
  (let (parent subject)
    (dolist (node path)
      (when (and (listp node) (not (stringp node)))
        (setq subject (ebox-tree-node-subject node))
        (when parent
          (ecss-subject-set-children parent (list subject)))
        (setq parent subject)))
    subject))

(defun ebox-tree-flex-participation-props (node)
  "Return raw flex item participation props attached to NODE."
  (cond
   ((and (listp node) (eq (plist-get node :ebox-type) 'flex-item))
    (append (plist-get node :props)
            (ebox-tree-flex-direct-participation-props
             (plist-get node :node))))
   ((listp node)
    (ebox-tree-flex-direct-participation-props node))
   (t nil)))

(defun ebox-tree-node-all-region-ids (node)
  "Return every box region id contained by NODE.
Unlike `ebox-region-ids', this internal helper includes flex wrapper boxes
and their children because incremental replacement owns the rendered subtree,
not only the public update ids."
  (cond
   ((stringp node) (ebox--string-region-ids node))
   ((not (listp node)) nil)
   (t
    (let* ((missing (make-symbol "missing"))
           (cached (and ebox--node-region-ids-cache
                        (gethash node ebox--node-region-ids-cache missing))))
      (if (and ebox--node-region-ids-cache
               (not (eq cached missing)))
          cached
        (let ((region-ids
               (pcase (plist-get node :ebox-type)
                 ('box
                  (cons
                   (ebox--ensure-region-id node)
                   (apply #'append
                          (mapcar #'ebox-tree-node-all-region-ids
                                  (ebox-tree-node-children node)))))
                 ('concat
                  (apply #'append
                         (mapcar #'ebox-tree-node-all-region-ids
                                 (ebox-tree-layout-children node))))
                 ('stack
                  (apply #'append
                         (mapcar #'ebox-tree-node-all-region-ids
                                 (ebox-tree-layout-children node))))
                 ('flex
                  (append
                   (when-let* ((box (plist-get node :box)))
                     (list (ebox--ensure-region-id box)))
                   (apply #'append
                          (mapcar #'ebox-tree-node-all-region-ids
                                  (ebox-tree-layout-children node)))))
                 ('grid
                  (append
                   (when-let* ((box (plist-get node :box)))
                     (list (ebox--ensure-region-id box)))
                   (apply #'append
                          (mapcar #'ebox-tree-node-all-region-ids
                                  (ebox-tree-layout-children node)))))
                 ('flex-item
                  (ebox-tree-node-all-region-ids (plist-get node :node)))
                 (_ nil))))
          (when ebox--node-region-ids-cache
            (puthash node region-ids ebox--node-region-ids-cache))
          region-ids))))))

(defun ebox-tree-node-paint-conflict-p (node paint-key &optional inherited)
  "Return non-nil when a box below NODE declares PAINT-KEY itself.
Such a descendant is the nearest paint source for its own subtree, so
a cheap ancestor face patch over NODE's spans would clobber it.
INHERITED is non-nil while walking below the owning node; the owner's
own declaration is never a conflict.  Pre-rendered string content
cannot be inspected and reports no conflict."
  (cond
   ((not (listp node)) nil)
   (t
    (pcase (plist-get node :ebox-type)
      ('box
       (or (and inherited (plist-get node paint-key) t)
           (cl-some
            (lambda (child)
              (ebox-tree-node-paint-conflict-p child paint-key t))
            (ebox-tree-node-children node))))
      ('concat
       (cl-some (lambda (child)
                  (ebox-tree-node-paint-conflict-p child paint-key t))
                (ebox-tree-layout-children node)))
      ('stack
       (cl-some (lambda (child)
                  (ebox-tree-node-paint-conflict-p child paint-key t))
                (ebox-tree-layout-children node)))
      ('flex
       (or (and inherited
                (when-let* ((box (plist-get node :box)))
                  (and (plist-get box paint-key) t)))
           (cl-some (lambda (child)
                      (ebox-tree-node-paint-conflict-p child paint-key t))
                    (ebox-tree-layout-children node))))
      ('grid
       (or (and inherited
                (when-let* ((box (plist-get node :box)))
                  (and (plist-get box paint-key) t)))
           (cl-some (lambda (child)
                      (ebox-tree-node-paint-conflict-p child paint-key t))
                    (ebox-tree-layout-children node))))
      ('flex-item
       (ebox-tree-node-paint-conflict-p
        (plist-get node :node) paint-key inherited))
      (_ nil)))))

(defun ebox-tree-node-path-to-region (node region-id)
  "Return renderable dirty path from REGION-ID's node up to NODE.
The returned list is ordered from the smallest renderable owner to the root
candidate.  Flex wrapper boxes are represented by their flex node because the
wrapper's visible content is produced by the flex renderer."
  (cond
   ((or (stringp node) (not (listp node))) nil)
   (t
    (pcase (plist-get node :ebox-type)
      ('box
       (or (when (equal (ebox-get node :region-id) region-id)
             (list node))
           (catch 'found
             (dolist (child (ebox-tree-node-children node))
               (when-let* ((path
                            (ebox-tree-node-path-to-region child region-id)))
                 (throw 'found (append path (list node)))))
             nil)))
      ('concat
       (catch 'found
         (dolist (child (ebox-tree-layout-children node))
           (when-let* ((path (ebox-tree-node-path-to-region child region-id)))
             (throw 'found (append path (list node)))))
         nil))
      ('stack
       (catch 'found
         (dolist (child (ebox-tree-layout-children node))
           (when-let* ((path (ebox-tree-node-path-to-region child region-id)))
             (throw 'found (append path (list node)))))
         nil))
      ('flex
       (cond
        ((and (plist-get node :box)
              (equal (ebox-get (plist-get node :box) :region-id) region-id))
         (list node))
        (t
         (catch 'found
           (dolist (child (ebox-tree-layout-children node))
             (when-let* ((path (ebox-tree-node-path-to-region child region-id)))
               (throw 'found (append path (list node)))))
           nil))))
      ('grid
       (cond
        ((and (plist-get node :box)
              (equal (ebox-get (plist-get node :box) :region-id) region-id))
         (list node))
        (t
         (catch 'found
           (dolist (child (ebox-tree-layout-children node))
             (when-let* ((path (ebox-tree-node-path-to-region child region-id)))
               (throw 'found (append path (list node)))))
           nil))))
      ('flex-item
       (ebox-tree-node-path-to-region (plist-get node :node) region-id))
      (_ nil)))))

(defun ebox-tree-node-visible-overflow-p (node)
  "Return non-nil when NODE contains visible overflow that cannot be span patched."
  (cond
   ((or (stringp node) (not (listp node))) nil)
   (t
    (pcase (plist-get node :ebox-type)
      ('box
       (or (ebox--box-visible-overflow-p node)
           (cl-some #'ebox-tree-node-visible-overflow-p
                    (ebox-tree-node-children node))))
      ('concat
       (cl-some #'ebox-tree-node-visible-overflow-p
                (ebox-tree-layout-children node)))
      ('stack
       (cl-some #'ebox-tree-node-visible-overflow-p
                (ebox-tree-layout-children node)))
      ('flex
       (or (and (plist-get node :box)
                (ebox--box-visible-overflow-p (plist-get node :box)))
           (cl-some #'ebox-tree-node-visible-overflow-p
                    (ebox-tree-layout-children node))))
      ('grid
       (or (and (plist-get node :box)
                (ebox--box-visible-overflow-p (plist-get node :box)))
           (cl-some #'ebox-tree-node-visible-overflow-p
                    (ebox-tree-layout-children node))))
      ('flex-item
       (ebox-tree-node-visible-overflow-p (plist-get node :node)))
      (_ nil)))))

(defalias 'ebox--computed-display #'ebox-tree-computed-display)
(defalias 'ebox--display-outer #'ebox-tree-display-outer)
(defalias 'ebox--display-inner #'ebox-tree-display-inner)
(defalias 'ebox--formatting-context-p #'ebox-tree-formatting-context-p)
(defalias 'ebox--node-selector-type #'ebox-tree-node-selector-type)
(defalias 'ebox--layout-children #'ebox-tree-layout-children)
(defalias 'ebox--node-children #'ebox-tree-children)
(defalias 'ebox--flex-direct-participation-props
  #'ebox-tree-flex-direct-participation-props)
(defalias 'ebox--flex-item-source-node #'ebox-tree-flex-item-source-node)
(defalias 'ebox--flex-participation-props
  #'ebox-tree-flex-participation-props)
(defalias 'ebox--node-all-region-ids #'ebox-tree-node-all-region-ids)
(defalias 'ebox--node-paint-conflict-p #'ebox-tree-node-paint-conflict-p)
(defalias 'ebox--node-path-to-region #'ebox-tree-node-path-to-region)
(defalias 'ebox--node-visible-overflow-p #'ebox-tree-node-visible-overflow-p)

(provide 'ebox-tree)

;;; ebox-tree.el ends here
