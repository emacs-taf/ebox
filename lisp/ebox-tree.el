;;; ebox-tree.el --- Element tree model for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns runtime identity, display accessors, child traversal, parent paths, and
;; parent participation metadata.  It does not own layout measurement or buffer
;; editing.

;;; Code:

(require 'cl-lib)

(require 'subr-x)
(require 'ecss)
(require 'ebox-source)
(require 'ebox-selector-view)
(require 'ebox-style)
(require 'ebox-node-factory)
(require 'ebox-child-range)
(require 'ebox-runtime-index)

(defvar ebox-tree--incoming-source-indexes nil
  "Transaction-local handle to incoming source-index map for one delta.")
(require 'ebox-layout-config)

(declare-function ebox-get "ebox" (box property))
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--next-runtime-node-id "ebox" ())
(declare-function ebox--string-region-ids "ebox" (string))
(declare-function ebox--box-visible-overflow-p "ebox" (box))
(declare-function ebox--flex-validate-item-bases "ebox-flex" (props children))

(defconst ebox--default-display '(block flow)
  "Default CSS-like display for a plain Ebox box.")

(defvar ebox--node-region-ids-cache nil
  "Dynamic snapshot-detail-local node -> region ids cache.
This is an optimization for snapshot capture, not buffer runtime state.")
(defvar ebox--flex-item-prop-keys)

(defun ebox-tree-layout-kind (node)
  "Return NODE's child-layout kind through the tree boundary.
Typed Box nodes own this fact in their LayoutConfig.  Private legacy nodes are
translated only here so tree consumers do not infer layout from storage tags."
  (let ((canonical-kind (and (listp node) (plist-get node :ebox-kind))))
    (pcase canonical-kind
      ('text nil)
      ('box
       (when-let* ((config (plist-get node :ebox-layout-config)))
         (ebox-layout-config-kind config)))
      (_
       (pcase (and (listp node) (plist-get node :ebox-type))
         ('box 'normal)
         ('concat 'row)
         ('stack 'column)
         ('flex 'flex)
         ('grid 'grid)
         (_ nil))))))

(defun ebox-tree-computed-display (node)
  "Return NODE's canonical CSS-like display pair."
  (or (and (listp node) (plist-get node :display))
      (when-let* ((kind (ebox-tree-layout-kind node)))
        (list 'block (if (eq kind 'normal) 'flow kind)))
      ebox--default-display))

(defun ebox-tree-display-outer (node)
  "Return NODE's outer display."
  (car (ebox-tree-computed-display node)))

(defun ebox-tree-display-inner (node)
  "Return NODE's inner display."
  (cadr (ebox-tree-computed-display node)))

(defun ebox-tree-formatting-context-p (node)
  "Return non-nil when NODE establishes a child layout context."
  (memq (ebox-tree-display-inner node) '(row column flex grid)))

(defun ebox-tree-layout-props (node)
  "Return NODE's canonical child-layout properties.
Typed Box nodes read their LayoutConfig; legacy runtime adapters fall back to
their private props encoding.  Callers receive a detached value."
  (if-let* ((config (and (listp node)
                         (plist-get node :ebox-layout-config))))
      (copy-tree (ebox-layout-config-props config))
    (copy-tree (or (and (listp node) (plist-get node :raw-props))
                   (and (listp node) (plist-get node :props))))))

(defun ebox-tree-node-selector-type (node)
  "Return NODE's CSS-like selector type symbol."
  (if (eq (and (listp node) (plist-get node :ebox-kind)) 'text)
      'text
    (when-let* ((kind (ebox-tree-layout-kind node)))
      (if (eq kind 'normal) 'box kind))))

(defun ebox-tree-metadata-string (value)
  "Return VALUE normalized to a selector metadata string."
  (cond
   ((null value) nil)
   ((symbolp value) (symbol-name value))
   ((stringp value) value)
   (t (format "%s" value))))

(defun ebox-tree-node-source-handle (node)
  "Return canonical NODE's opaque source handle, or nil."
  (and (listp node) (plist-get node :ebox-source-handle)))

(defun ebox-tree-node-source-identity (node)
  "Return canonical NODE's opaque source identity, or nil."
  (when-let* ((handle (ebox-tree-node-source-handle node)))
    (ebox-source--handle-id-view handle)))

(defun ebox-tree-node-id (source-index node)
  "Return NODE's selector id string from SOURCE-INDEX, or nil."
  (when-let* ((handle (ebox-tree-node-source-handle node)))
    (ebox-source--index-id-view source-index handle)))

(defun ebox-tree-node-source-declarations (source-index node)
  "Return NODE's canonical declarations from SOURCE-INDEX, or nil."
  (when-let* ((handle (ebox-tree-node-source-handle node)))
    (ebox-source--index-declarations-view source-index handle)))

(defun ebox-tree--metadata-tokens (value)
  "Return VALUE as a list of normalized selector metadata tokens."
  (cond
   ((null value) nil)
   ((listp value)
    (delq nil (mapcar #'ebox-tree-metadata-string value)))
   (t (list (ebox-tree-metadata-string value)))))

(defun ebox-tree-node-classes (source-index node)
  "Return NODE's selector class strings from SOURCE-INDEX."
  (when-let* ((handle (ebox-tree-node-source-handle node)))
    (ebox-source--index-classes-view source-index handle)))

(defun ebox-tree-node-state (source-index node)
  "Return NODE's selector state tokens from SOURCE-INDEX."
  (when-let* ((handle (ebox-tree-node-source-handle node)))
    (ebox-source--index-states-view source-index handle)))

(defun ebox-tree-node-author-key (source-index node)
  "Return NODE's raw author key from SOURCE-INDEX."
  (when-let* ((handle (ebox-tree-node-source-handle node)))
    (ebox-source--index-key-view source-index handle)))

(defun ebox-tree-node-key (source-index node)
  "Return NODE's selector key string from SOURCE-INDEX, or nil."
  (ebox-tree-metadata-string
   (ebox-tree-node-author-key source-index node)))

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

(defun ebox-tree-node-attributes (source-index node)
  "Return NODE's selector attributes from SOURCE-INDEX plus id and key."
  (when (listp node)
    (let ((attributes
           (delq nil
                 (list (when-let* ((id (ebox-tree-node-id source-index node)))
                         (cons :id id))
                       (when-let* ((key (ebox-tree-node-key source-index node)))
                         (cons :key key))))))
      (dolist (attribute
               (when-let* ((handle (ebox-tree-node-source-handle node)))
                 (ebox-source--index-attributes-view source-index handle)))
        (push (cons (ebox-tree--selector-attribute-key (car attribute))
                    (ebox-tree--selector-attribute-value (cdr attribute)))
              attributes))
      (nreverse attributes))))

(defun ebox-tree--children-raw (node)
  "Return NODE's direct child nodes without assigning runtime ids."
  (let ((type (and (listp node) (plist-get node :ebox-type))))
    (cond
     ;; Flex and Grid own a visual wrapper as well as their layout children.
     ;; Runtime traversals must see both through this single child contract;
     ;; otherwise rendered wrapper regions have no node or surface identity.
     ((memq type '(flex grid))
      (append (when-let* ((box (plist-get node :box))) (list box))
              (ebox-tree-layout-children node)))
     ((and (listp node) (plist-member node :children))
      (plist-get node :children))
     ((and (listp node) (plist-get node :ebox-child-sequence))
      (ebox-child-range--flatten (plist-get node :ebox-child-sequence)))
     (t
      (pcase type
    ('box
     (if (plist-member node :children)
         (plist-get node :children)
       (delq nil (list (plist-get node :ebox-content-node)))))
    ('concat
     (ebox-tree-layout-children node))
    ('stack
     (ebox-tree-layout-children node))
        (_ nil))))))

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
               (if (ebox-child-range--descriptor-p child)
                   (dolist (item (ebox-child-range--descriptor-items child))
                     (funcall function item))
                 (funcall function child)))
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
           (if (ebox-child-range--descriptor-p child)
               (dolist (item (ebox-child-range--descriptor-items child))
                 (funcall function item))
             (funcall function child))))
        (_ nil))))
  node)

(defun ebox-tree-map-direct-children (node function)
  "Return FUNCTION results for NODE's children without an intermediate list."
  (let (results)
    (ebox-tree-for-each-direct-child
     node (lambda (child) (push (funcall function child) results)))
    (nreverse results)))

(defun ebox-tree-author-style-count (node)
  "Return NODE's retained count of style-projecting canonical descendants."
  (let ((count (and (listp node)
                    (plist-get node :ebox-author-style-count))))
    (if (and (integerp count) (>= count 0))
        count
      (if (and (listp node)
               (plist-get node :ebox-author-style-required-p))
          1
        0))))

(defun ebox-tree--set-author-style-count (node count)
  "Set NODE's exact nonnegative author style COUNT and return NODE."
  (unless (and (integerp count) (>= count 0))
    (error "Ebox author style count must be nonnegative: %S" count))
  (plist-put node :ebox-author-style-count count)
  (if (> count 0)
      (plist-put node :ebox-author-style-required-p t)
    (cl-remf node :ebox-author-style-required-p))
  node)

(defun ebox-tree-clear-author-style-pending (node)
  "Clear projected author style facts in NODE's pending subtree."
  (when (> (ebox-tree-author-style-count node) 0)
    (ebox-tree-for-each-direct-child
     node
     (lambda (child)
       (when (> (ebox-tree-author-style-count child) 0)
         (ebox-tree-clear-author-style-pending child))))
    (ebox-tree--set-author-style-count node 0))
  node)

(cl-defun ebox-tree--put-child-sequence
    (node sequence &optional (children nil children-p))
  "Set NODE's authoritative child SEQUENCE and retained material CHILDREN.
When CHILDREN is omitted, invalidate the retained material list without
flattening; the next layout consumer may materialize it exactly once."
  (plist-put node :ebox-child-sequence sequence)
  (if children-p
      (plist-put node :children children)
    (cl-remf node :children))
  node)

(defun ebox-tree-layout-children (node)
  "Return layout container children for NODE in render order.
New row/column containers store flat `:children'.  Legacy `ebox-concat' and
`ebox-stack' nodes may still carry `:left'/`:right' or `:top'/`:bottom'."
  (if (plist-member node :children)
      (plist-get node :children)
    (if (plist-member node :ebox-child-sequence)
        (let ((children
               (ebox-child-range--flatten
                (plist-get node :ebox-child-sequence))))
          (plist-put node :children children)
          children)
      (or (plist-get node :children)
        (pcase (and (listp node) (plist-get node :ebox-type))
          ('concat
           (delq nil (list (plist-get node :left)
                           (plist-get node :right))))
          ('stack
           (delq nil (list (plist-get node :top)
                           (plist-get node :bottom))))
          (_ nil))))))

(defun ebox-tree--replace-direct-child (child replacements)
  "Return CHILD's identity replacement from REPLACEMENTS, when present.
REPLACEMENTS is an alist whose keys are compared with `eq'.  Nil is not a
child and is therefore never used as a replacement key."
  (if-let* ((replacement (and child (assq child replacements))))
      (cdr replacement)
    child))

(defun ebox-tree--replace-direct-child-list-result (children replacements)
  "Return `(CHILDREN . STYLE-DELTA)' after identity REPLACEMENTS."
  (if (null replacements)
      (cons children 0)
    (let ((style-delta 0) changed replaced)
      (dolist (child children)
        (let ((replacement
               (ebox-tree--replace-direct-child child replacements)))
          (unless (eq replacement child)
            (setq changed t)
            (cl-incf style-delta
                     (- (ebox-tree-author-style-count replacement)
                        (ebox-tree-author-style-count child))))
          (when replacement
            (push replacement replaced))))
      (cons (if changed (nreverse replaced) children)
            style-delta))))

(defun ebox-tree--replace-direct-child-list (children replacements)
  "Replace CHILDREN found by identity in REPLACEMENTS."
  (car (ebox-tree--replace-direct-child-list-result children replacements)))

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

(defun ebox-tree-copy-with-direct-child-replacements
    (node replacements &optional key-function)
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
         (sequence (plist-get copy :ebox-child-sequence))
         (style-delta 0)
         (scalar-properties
          (pcase type
            ('box '(:ebox-content-node))
            ('concat '(:left :right))
            ('stack '(:top :bottom))
            ('flex '(:box))
            ('grid '(:box)))))
    (dolist (property scalar-properties)
      (setq copy
            (ebox-tree--replace-direct-child-property
             copy property replacements)))
    (when (and (or (memq type '(concat stack flex grid))
                   (and (eq type 'box) (plist-member copy :children)))
               (plist-member copy :children))
      (let* ((children (plist-get copy :children))
             (result
              (ebox-tree--replace-direct-child-list-result
               children replacements))
             (replaced (car result)))
        (unless (eq replaced children)
          (setq copy (plist-put copy :children replaced)))
        (unless sequence
          (setq style-delta (cdr result)))))
    (when sequence
      (let ((updated sequence) changed fallback identity-locations)
        (dolist (replacement replacements)
          (let* ((old (car replacement)) (new (cdr replacement))
                 (location (and old (plist-get old :ebox-sequence-location)))
                 old-key)
            (unless location
              (unless identity-locations
                (setq identity-locations (make-hash-table :test #'eq))
                (dotimes (segment-index
                          (ebox-child-range--sequence-count sequence))
                  (let ((payload
                         (ebox-child-range--segment-payload
                          (ebox-child-range--segment-at
                           sequence segment-index))))
                    (dotimes (offset (length payload))
                      (puthash
                       (aref payload offset)
                       (list :parent-node-id (plist-get node :node-id)
                             :segment-index segment-index :offset offset)
                       identity-locations)))))
              (setq location (gethash old identity-locations)))
            (when (and location
                       (equal (plist-get location :parent-node-id)
                              (plist-get node :node-id)))
              (let* ((segment
                      (ebox-child-range--segment-at
                       updated (plist-get location :segment-index)))
                     (keys (ebox-child-range--segment-keys segment)))
                (setq old-key (aref keys (plist-get location :offset))))
              (cl-incf style-delta
                       (- (ebox-tree-author-style-count new)
                          (ebox-tree-author-style-count old)))
              (if new
                  (setq updated
                        (ebox-child-range--replace-item-at
                         updated (plist-get location :segment-index)
                         (plist-get location :offset) old new
                         (if key-function
                             (funcall key-function new)
                           (if (or (null old-key)
                                   (equal
                                    (ebox-tree-node-source-identity old)
                                    (ebox-tree-node-source-identity new)))
                               old-key
                             (error
                              "Ebox Range replacement requires source key facts"))))
                        changed t)
                (setq fallback t)))))
        (when fallback
          (error "Ebox Range item removal requires a Range transaction"))
        (when changed
          (setq copy
                (if (plist-member copy :children)
                    (ebox-tree--put-child-sequence
                     copy updated (plist-get copy :children))
                  (ebox-tree--put-child-sequence copy updated))))))
    (when (eq (plist-get node :ebox-kind) 'box)
      (setq copy
            (ebox-tree--set-author-style-count
             copy (+ (ebox-tree-author-style-count node) style-delta))))
    copy))

(defun ebox-tree-copy-node-structure (root)
  "Copy every Ebox node below ROOT while preserving opaque leaf values.
The returned tree owns distinct node plists and child lists.  Values such as
keymaps, callbacks, Host references, and surface-property payloads retain their
original object identity."
  (let ((seen (make-hash-table :test #'eq))
        (active (make-hash-table :test #'eq)))
    (cl-labels
      ((without (plist key)
         (cl-loop for (property value) on plist by #'cddr
                  unless (eq property key) append (list property value)))
       (copy-node
        (node)
        (if (or (not (listp node)) (stringp node))
            node
          (when (gethash node active)
            (error "Ebox declarative tree contains a cycle"))
          (when (gethash node seen)
            (error "Ebox declarative tree reuses one node object"))
          (puthash node t seen)
          (puthash node t active)
          (prog1
          (let* ((type (plist-get node :ebox-type))
                 (material-p (or (memq type '(concat stack flex grid))
                                 (plist-get node :ebox-child-sequence)))
                 (raw (and material-p (plist-get node :children)))
                 (sequence (and material-p
                                (plist-get node :ebox-child-sequence)))
                 (has-range (cl-some #'ebox-child-range--descriptor-p raw)))
            (if (or has-range sequence)
                (let ((copy (copy-sequence node)) segments segment-keys)
                  (when has-range
                    (error "Ebox declarative Range must be normalized before copy"))
                  (if sequence
                      (dotimes (index
                                (ebox-child-range--sequence-count sequence))
                        (let ((segment
                               (ebox-child-range--segment-at sequence index)))
                          (push (ebox-child-range--segment-keys segment)
                                segment-keys)
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
                  (setq segments (nreverse segments)
                        segment-keys (nreverse segment-keys))
                  (pcase type
                    ((or 'flex 'grid)
                     (when-let* ((box (plist-get node :box)))
                       (setq copy (plist-put copy :box (copy-node box)))))
                    ('concat
                     (setq copy (without (without copy :left) :right)))
                    ('stack
                     (setq copy (without (without copy :top) :bottom))))
                  (ebox-tree--put-child-sequence
                   copy
                   (ebox-child-range--build
                    segments nil nil t segment-keys)
                   (cl-mapcan (lambda (segment)
                                (copy-sequence (cdr segment)))
                              segments)))
              (let ((copy
                     (ebox-tree-copy-with-direct-child-replacements
                      node
                      (mapcar (lambda (child)
                                (cons child (copy-node child)))
                              (ebox-tree--children-raw node)))))
                copy)))
            (remhash node active)))))
      (copy-node root))))

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
    (when-let* ((handle (ebox-tree-node-source-handle node)))
      (setq shell (plist-put shell :ebox-source-handle handle)))
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
       (if (or (plist-member node :children)
               (plist-get node :ebox-child-sequence))
           (plist-put shell :children
                      (ebox-tree-map-direct-children
                       node
                       (lambda (child)
                         (ebox-tree--runtime-identity-skeleton
                          child node-id-set region-id-set))))
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
                   (ebox-tree-layout-children node)))))
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

(defun ebox-tree-validate-host-refs (root &optional source-index)
  "Validate ROOT's unique opaque source identities and return ROOT.
SOURCE-INDEX owns Host lookup identity.  Building it rejects duplicate source
handles, reused node objects, and cycles without consulting node metadata."
  (or source-index (ebox-tree-source-index root))
  root)

(defconst ebox-tree--common-participation-keys
  '(:order :align-self)
  "Participation properties shared by Flex and Grid children.")

(defconst ebox-tree--flex-participation-keys
  '(:flex :flex-grow :flex-shrink :flex-basis)
  "Properties accepted only on a direct Flex child Box.")

(defconst ebox-tree--grid-participation-keys
  '(:grid-column :grid-row :justify-self)
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

(defun ebox-tree--declarations-specify-participation-p
    (source-index node key)
  "Return non-nil when NODE in SOURCE-INDEX specifies participation KEY."
  (and (listp node)
       (plist-member (ebox-style-node-declarations source-index node)
                     (ebox-style-schema-id key))))

(defun ebox-tree--author-specifies-participation-p
    (source-index node key)
  "Return non-nil when NODE's SOURCE-INDEX specifies participation KEY."
  (or (ebox-tree--declarations-specify-participation-p
       source-index node key)
      (and (null (plist-get node :ebox-computed-style))
           (plist-member node key))))

(defun ebox-tree--node-participation-keys (source-index node source)
  "Return NODE participation keys from SOURCE-INDEX or COMPUTED SOURCE."
  (let ((style (plist-get node :ebox-computed-style))
        keys)
    (dolist (key ebox-tree--participation-keys)
      (when
          (pcase source
            ('author
             (ebox-tree--author-specifies-participation-p
              source-index node key))
            ('computed
             (and (plist-member node key)
                  (ebox-tree--style-specifies-participation-p style key)))
            (_ (error "Unknown Ebox participation source: %S" source)))
        (push key keys)))
    (nreverse keys)))

(defun ebox-tree--child-layout-kind (node parent-kind)
  "Return the layout kind governing NODE's direct children."
  (ignore parent-kind)
  (or (ebox-tree-layout-kind node)
      (pcase (ebox-tree-display-inner node)
        ('flow 'normal)
        (kind kind))))

(defun ebox-tree--validate-node-parent-participation
    (node parent-kind source &optional source-index)
  "Validate NODE participation under PARENT-KIND from AUTHOR or COMPUTED SOURCE."
  (let ((keys
         (ebox-tree--node-participation-keys
          source-index node source)))
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
                  keys)))))
  (when (and (or (eq source 'computed) (not (ebox-style-cascade-active-p)))
             (eq (ebox-tree-layout-kind node) 'flex))
    (ebox--flex-validate-item-bases
     (ebox-tree-layout-props node) (ebox-tree-layout-children node)))
  node)

(defun ebox-tree--indexed-parent-context
    (node-id node-table parent-table)
  "Return the direct parent layout kind for NODE-ID in indexed tree."
  (let* ((parent-id (ebox-runtime-index-get node-id parent-table))
         (parent (and parent-id (ebox-runtime-index-get parent-id node-table))))
    (and parent (ebox-tree--child-layout-kind parent nil))))

(defun ebox-tree-validate-indexed-participation
    (node-table parent-table node-ids &optional source source-index)
  "Validate NODE-IDS in indexed final tree using AUTHOR or COMPUTED SOURCE."
  (setq source (or source 'author))
  (dolist (node-id
           (delete-dups
            (append (copy-sequence node-ids)
                    (when (or (eq source 'computed)
                              (not (ebox-style-cascade-active-p)))
                      (delq nil (mapcar
                                 (lambda (id)
                                   (ebox-runtime-index-get id parent-table))
                                 node-ids))))))
    (when-let* ((node (ebox-runtime-index-get node-id node-table)))
      (ebox-tree--validate-node-parent-participation
       node
       (ebox-tree--indexed-parent-context node-id node-table parent-table)
       source source-index)))
  node-table)

(defun ebox-tree-validate-declarative-root
    (root &optional validate-participation-p root-parent-kind source-index)
  "Validate ROOT for one declarative runtime commit.

The runtime tree must be a proper tree: a node object cannot appear in two
locations, cycles are rejected, explicit sibling keys must be unique, and
non-nil host references must be unique across the root.  Keys are sibling-local
and all explicit identities are compared with `equal'.  Return ROOT on success."
  (ebox-tree-source-index
   root validate-participation-p root-parent-kind source-index)
  root)

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
           (ebox-tree-for-each-direct-child node #'visit))))
    (visit root))
  root)

(defconst ebox-tree--runtime-source-keys
  '(:node-id :region-id :surface-object :render-cache :ebox-sequence-location
    :ebox-content-width-exact-p :ebox-content-layout-complete-p)
  "Runtime-owned plist keys excluded from declarative source signatures.")

(defconst ebox-tree--child-source-keys
  '(:children :ebox-child-sequence :left :right :top :bottom :node :box
    :ebox-content-node)
  "Child references excluded from node-local declarative signatures.")

(defconst ebox-tree--excluded-source-keys
  (append ebox-tree--runtime-source-keys
          ebox-tree--child-source-keys
          ebox-node-factory--style-projection-keys
          '(:ebox-style-overrides
            :ebox-source-handle
            :ebox-grid-config
            :ebox-computed-style :ebox-style-wrapper
            :ebox-font-fact
            :ebox-style-generated-wrapper
            :ebox-author-style-count :ebox-author-style-required-p
            :ebox-text-value :ebox-candidate-computed-style-p))
  "Derived keys excluded from node-local source comparison.
Canonical declarations remain source facts and therefore participate in diff;
their property-level delta is normalized by the incremental candidate boundary.
Computed styles, projection counters, duplicate Text storage, and legacy wrapper
overrides are derived side state.")

(defconst ebox-tree-metadata-source-keys
  '(:key :id :class :selector-attributes :selector-state)
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
           (raw (ebox-style--expand-engine-plist raw))
           (table (make-hash-table :test #'eq)))
      (cl-loop for (key value) on raw by #'cddr
               unless (memq key '(:color :background-color :bgcolor :host-ref
                                  :surface-properties))
               do (puthash key value table))
      (when (plist-member raw :gap)
        (let* ((gap (plist-get raw :gap))
               (row (if (consp gap) (car gap) gap))
               (column (if (and (consp gap) (cdr gap)) (cadr gap) row)))
          (puthash :row-gap row table)
          (puthash :column-gap column table)
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
                 (funcall (if (eq (car old) :surface-properties)
                              #'ebox-interaction-surface-equal-p
                            #'equal-including-properties)
                          (cadr old) (cadr new))))
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
                             (funcall (if (eq key :surface-properties)
                                          #'ebox-interaction-surface-equal-p
                                        #'equal-including-properties)
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
        ;; Sequence coordinates belong to the containing tree, not the
        ;; retained identity.  A keyed child may have moved in its new parent.
        (when (plist-member new :ebox-sequence-location)
          (plist-put new :ebox-sequence-location nil))
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

(defun ebox-tree-reconcile-runtime
    (old old-source-index new new-source-index)
  "Transfer runtime identity from OLD to NEW using their source indexes."
  (cl-labels
      ((node-key
        (source-index node)
        (and node
             (ebox-tree-node-author-key source-index node)))
       (same-type-p
        (old-node new-node)
        (and (listp old-node)
             (listp new-node)
             (eq (plist-get old-node :ebox-type)
                 (plist-get new-node :ebox-type))))
       (keyed-children
        (source-index children)
        (let ((table (make-hash-table :test 'equal)))
          (dolist (child children table)
            (when-let* ((key (node-key source-index child)))
              (puthash key child table)))))
       (match-child
        (old-children old-keyed old-identities new-identities new-child index)
        (if-let* ((key (node-key new-source-index new-child)))
            (let ((old-child (gethash key old-keyed)))
              (and (same-type-p old-child new-child) old-child))
          (or (let* ((identity (ebox-tree-node-source-identity new-child))
                     (old-child (and identity (gethash identity old-identities))))
                (and (not (node-key old-source-index old-child))
                     (same-type-p old-child new-child) old-child))
              (let ((old-child (nth index old-children)))
                (and (not (node-key old-source-index old-child))
                     ;; An inserted sibling cannot take the identity of a
                     ;; retained sibling that appears later in the new tree.
                     (not (gethash (ebox-tree-node-source-identity old-child)
                                   new-identities))
                     (same-type-p old-child new-child)
                     old-child)))))
       (reconcile
        (old-node new-node)
        (when (and (listp new-node) (not (stringp new-node)))
          (ebox-tree-transfer-runtime-identity old-node new-node)
          (let* ((old-children
                  (and old-node (ebox-tree--children-raw old-node)))
                 (new-children (ebox-tree--children-raw new-node))
                 (old-identities (make-hash-table :test #'equal))
                 (new-identities (make-hash-table :test #'equal))
                 (old-keyed
                  (keyed-children old-source-index old-children)))
            (dolist (child old-children)
              (when-let* ((identity (ebox-tree-node-source-identity child)))
                (puthash identity child old-identities)))
            (dolist (child new-children)
              (when-let* ((identity (ebox-tree-node-source-identity child)))
                (puthash identity t new-identities)))
            (cl-loop for new-child in new-children
                     for index from 0
                     do (reconcile
                         (match-child
                          old-children old-keyed old-identities new-identities
                          new-child index)
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

(defun ebox-tree--semantic-layout-leaves (node)
  "Return semantic leaves below internal layout adapter NODE."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ((or 'concat 'stack)
     (apply #'append
            (mapcar #'ebox-tree--semantic-layout-leaves
                    (ebox-tree-layout-children node))))
    (_ (and (listp node) (list node)))))

(defun ebox-tree-semantic-children (node)
  "Return NODE's logical children without internal layout adapters."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box
     (if (plist-get node :ebox-child-sequence)
         (ebox-tree-layout-children node)
       (if (plist-member node :children)
           (plist-get node :children)
       (when-let* ((content-node (plist-get node :ebox-content-node)))
           (ebox-tree--semantic-layout-leaves content-node)))))
    ((or 'concat 'stack)
     (ebox-tree--semantic-layout-leaves node))
    ('flex (ebox-tree-layout-children node))
    ('grid (ebox-tree-layout-children node))
    (_ (ebox-tree-children node))))

(defun ebox-tree--subject-from-record (node record &optional token)
  "Return one ECSS selector subject for NODE and source RECORD."
  (ebox-selector-subject-create
   :token (or token (make-symbol "ebox-selector-node"))
   :type (ebox-tree-metadata-string (ebox-tree-node-selector-type node))
   :id (ebox-source-record-id record)
   :classes (ebox-source-record-classes record)
   :attributes
   (mapcar (lambda (attribute)
             (cons (substring (symbol-name (car attribute)) 1)
                   (cdr attribute)))
           (let ((attributes
                  (delq
                   nil
                   (list
                    (when-let* ((id (ebox-source-record-id record)))
                      (cons :id id))
                    (when-let* ((key
                                 (ebox-tree-metadata-string
                                  (ebox-source-record-key record))))
                      (cons :key key))))))
             (dolist (attribute (ebox-source-record-attributes record))
               (push (cons
                      (ebox-tree--selector-attribute-key (car attribute))
                      (ebox-tree--selector-attribute-value (cdr attribute)))
                     attributes))
             (nreverse attributes)))
   :states (ebox-source--record-selector-states record)))

(defun ebox-tree-node-subject (source-index node)
  "Return SOURCE-INDEX's retained ECSS selector subject for NODE."
  (or (ebox-source--index-node-subject source-index node)
      (error "Ebox selector node is absent from its source index")))

(defun ebox-tree-source-builder-snapshot (builder roots)
  "Return a sealed source-index slice for canonical ROOTS in open BUILDER."
  (unless (proper-list-p roots)
    (signal 'wrong-type-argument (list 'proper-list-p roots)))
  (let ((slice (ebox-source-builder-create))
        (seen (make-hash-table :test #'eq)))
    (cl-labels
        ((visit (node)
           (when (and (listp node) (not (stringp node)))
             (when-let* ((handle (ebox-tree-node-source-handle node)))
               (unless (gethash handle seen)
                 (puthash handle t seen)
                 (ebox-source--builder-add-record
                  slice handle
                  (or (ebox-source--builder-record builder handle)
                      (error "Ebox source builder does not own canonical node")))))
             (ebox-tree-for-each-direct-child node #'visit))))
      (dolist (root roots) (visit root)))
    (ebox-source-builder-finish slice)))

(defun ebox-tree-source-index
    (root &optional validate-participation-p root-parent-kind base-source-index
          allow-unreferenced-sources-p)
  "Build one immutable source and selector index for canonical ROOT.
When VALIDATE-PARTICIPATION-P is non-nil, validate ROOT-PARENT-KIND during the
same traversal.  Topology, Range addresses, source identities, and sibling
keys are always validated.  BASE-SOURCE-INDEX, when non-nil, is the fact-only
index transported with the canonical input; records are never recovered from
opaque handles on that path."
  (when (ebox-child-range--descriptor-p root)
    (error "Ebox child Range descriptor cannot be the root"))
  (let ((view (make-hash-table :test #'eq))
        (subjects (make-hash-table :test #'equal))
        (node-subjects (make-hash-table :test #'eq))
        (id-table (make-hash-table :test #'equal))
        (class-table (make-hash-table :test #'equal))
        (type-table (make-hash-table :test #'eq))
        (seen (make-hash-table :test #'eq))
        (active (make-hash-table :test #'eq))
        (range-refs (make-hash-table :test #'equal))
        (used-handles (make-hash-table :test #'eq))
        entries)
    (cl-labels
        ((prepend (table key entry)
           (puthash key (cons entry (gethash key table)) table))
         (record-for (node)
           (when-let* ((handle (ebox-tree-node-source-handle node)))
             (or (and base-source-index
                      (ebox-source--index-record base-source-index handle))
                 (error "Ebox canonical source is absent from its input index"))))
         (record-key (node)
           (when-let* ((record (record-for node)))
             (ebox-source-record-key record)))
         (record-participation-keys (node record)
           (let ((declarations (ebox-source-record-declarations record)) keys)
             (dolist (key ebox-tree--participation-keys)
               (when (or (plist-member declarations (ebox-style-schema-id key))
                         (and (null (plist-get node :ebox-computed-style))
                              (plist-member node key)))
                 (push key keys)))
             (nreverse keys)))
         (validate-participation (node record parent-kind)
           (when validate-participation-p
             (let ((keys (record-participation-keys node record)))
               (when keys
                 (when (eq (plist-get node :ebox-kind) 'text)
                   (error "Ebox Text cannot carry participation properties: %S"
                          keys))
                 (pcase parent-kind
                   ('flex
                    (when (cl-intersection
                           keys ebox-tree--grid-participation-keys :test #'eq)
                      (error
                       "Grid participation requires a direct Grid parent: %S"
                       keys)))
                   ('grid
                    (when (cl-intersection
                           keys ebox-tree--flex-participation-keys :test #'eq)
                      (error
                       "Flex participation requires a direct Flex parent: %S"
                       keys)))
                   (_
                    (error
                     "Ebox participation requires a Flex or Grid parent: %S"
                     keys)))))))
         (material-children (node)
           (let* ((type (plist-get node :ebox-type))
                  (raw (and (memq type '(box concat stack flex grid))
                            (plist-get node :children)))
                  children)
             (when (and raw (not (proper-list-p raw)))
               (error "Ebox material children must be a proper list"))
             (if-let* ((sequence (plist-get node :ebox-child-sequence)))
                 (progn
                   (dotimes (index (ebox-child-range--sequence-count sequence))
                     (when-let* ((ref
                                  (ebox-child-range--segment-ref
                                   (ebox-child-range--segment-at
                                    sequence index))))
                       (when (gethash ref range-refs)
                         (error "Ebox child Range ref is not unique: %S" ref))
                       (puthash ref t range-refs)))
                   (ebox-tree-for-each-direct-child
                    node (lambda (child) (push child children))))
               (dolist (entry (ebox-tree--children-raw node))
                 (if (ebox-child-range--descriptor-p entry)
                     (progn
                       (unless (and (proper-list-p raw) (memq entry raw))
                         (error
                          "Ebox child Range descriptor is invalid in a scalar slot"))
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
                   (push entry children))))
             (nreverse children)))
         (visit-children (node path parent-kind)
           (let ((keys (make-hash-table :test #'equal)) result)
             (dolist (child (material-children node))
               (when (and (eq (plist-get node :ebox-kind) 'box)
                          (not (memq (plist-get child :ebox-kind) '(text box))))
                 (error "Canonical Ebox Box child must be Text or Box: %S"
                        child))
               (when-let* ((key (record-key child)))
                 (when (gethash key keys)
                   (error "Ebox declarative siblings use duplicate key %S" key))
                 (puthash key t keys))
               (setq result
                     (nconc
                      result
                      (visit child path
                             (ebox-tree--child-layout-kind node parent-kind)))))
             result))
         (visit (node path parent-kind)
           (when (and (listp node) (not (stringp node)))
             (when (gethash node active)
               (error "Ebox declarative tree contains a cycle"))
             (when (gethash node seen)
               (error "Ebox declarative tree reuses one node object"))
             (puthash node t seen)
             (puthash node t active)
             (let* ((handle (plist-get node :ebox-source-handle))
                    (current-path (append path (list node))))
               (if (null handle)
                   (prog1
                       (visit-children node current-path parent-kind)
                     (remhash node active))
                 (let* ((record (record-for node))
                        (identity (ebox-source--handle-id-view handle))
                        (subject
                         (ebox-tree--subject-from-record node record))
                        (entry (cons node current-path)))
                   (puthash handle t used-handles)
                   (validate-participation node record parent-kind)
                   (when (gethash identity subjects)
                     (error "Ebox source identity is not unique: %S" identity))
                   (puthash (ebox-selector-subject-token subject) subject view)
                   (puthash identity subject subjects)
                   (puthash handle subject node-subjects)
                   (push (list :node node :path current-path :subject subject
                               :source-handle handle)
                         entries)
                   (when-let* ((id (ebox-source-record-id record)))
                     (prepend id-table id entry))
                   (dolist (class (ebox-source-record-classes record))
                     (prepend class-table class entry))
                   (when-let* ((type (ebox-tree-node-selector-type node)))
                     (prepend type-table type entry))
                   (let ((children (visit-children node current-path parent-kind)))
                     (setf (ebox-selector-subject-children subject)
                           (mapcar #'ebox-selector-subject-token children))
                     (dolist (child children)
                       (setf (ebox-selector-subject-parent child)
                             (ebox-selector-subject-token subject))))
                   (remhash node active)
                   (list subject)))))))
      (let* ((root-subjects (visit root nil root-parent-kind))
             (root-subject (car root-subjects)))
        (dolist (table (list id-table class-table type-table))
          (maphash (lambda (key values)
                     (puthash key (nreverse values) table))
                   table))
        (when (and base-source-index
                   (not allow-unreferenced-sources-p)
                   (/= (hash-table-count used-handles)
                       (ebox-source-table-count
                        (ebox-source--index-handle-records
                         base-source-index))))
          (error "Ebox canonical input contains unreferenced source facts"))
        (ebox-source--with-derived
         (or base-source-index
             (ebox-source-builder-finish (ebox-source-builder-create)))
         :subjects subjects :node-subjects node-subjects :selector-view view
         :selector-topology (make-symbol "ebox-selector-topology")
         :entries (nreverse entries)
         :root-subject root-subject
         :selector-id-table id-table
         :selector-class-table class-table
         :selector-type-table type-table)))))

(defun ebox-tree-source-handle-order (root)
  "Return canonical source handles below ROOT in document preorder."
  (let (handles)
    (cl-labels
        ((visit
          (node)
          (when-let* ((handle (ebox-tree-node-source-handle node)))
            (push handle handles))
          (ebox-tree-for-each-direct-child node #'visit)))
      (visit root))
    (nreverse handles)))

(defun ebox-tree-source-fact-index-delta
    (old-index touched removed incoming-source-indexes &optional final-order)
  "Return fact-only OLD-INDEX after local TOUCHED and REMOVED changes."
  (let ((removed-handles nil)
        (added-handles nil)
        (replacement-pairs nil)
        (removed-seen (make-hash-table :test #'eq))
        (added-seen (make-hash-table :test #'eq)))
    (cl-labels
        ((remove-handle
          (node)
          (when-let* ((handle (ebox-tree-node-source-handle node)))
            (unless (gethash handle removed-seen)
              (puthash handle t removed-seen)
              (push handle removed-handles))))
         (add-handle
          (node)
          (when-let* ((handle (ebox-tree-node-source-handle node)))
            (unless (gethash handle added-seen)
              (puthash handle t added-seen)
              (push handle added-handles)))))
      (dolist (node removed) (remove-handle node))
      (dolist (entry touched)
        (let* ((old (car entry))
               (new (nth 1 entry))
               (old-handle (and old (ebox-tree-node-source-handle old)))
               (new-handle (ebox-tree-node-source-handle new)))
          (unless (eq old-handle new-handle)
            (when old (remove-handle old))
            (add-handle new)
            (when (and old-handle new-handle)
              (push (cons old-handle new-handle) replacement-pairs)))))
      (ebox-source--index-replace-handles
       old-index (nreverse removed-handles)
       (nreverse added-handles) incoming-source-indexes
       (nreverse replacement-pairs) final-order))))

(defun ebox-tree-source-index-delta
    (old-index touched removed node-table parent-table root)
  "Return a candidate source index from OLD-INDEX and local tree changes.
TOUCHED entries are `(OLD NEW PARENT-ID CHILDREN-CHANGED)'.  REMOVED contains
retired nodes.  NODE-TABLE and PARENT-TABLE describe the final candidate.
Records and selector relationships update through persistent deltas.
Query entries and document-order lookup views remain stale until queried."
  (let* ((structural-p
          (or removed
              (cl-some (lambda (entry)
                         (or (null (car entry)) (nth 3 entry)))
                       touched)))
         (final-order
          (and structural-p (ebox-tree-source-handle-order root)))
         (index
          (ebox-tree-source-fact-index-delta
           old-index touched removed ebox-tree--incoming-source-indexes
           final-order))
         (base-view (ebox-source--index-selector-view old-index))
         (removed-tokens (make-hash-table :test #'eq))
         (added-view (make-hash-table :test #'eq))
         (base-subjects
          (or (ebox-source--index-subjects old-index)
              (ebox-source--flat-table
               (make-hash-table :test #'equal) #'equal)))
         (base-node-subjects
          (or (ebox-source--index-node-subjects old-index)
              (ebox-source--flat-table
               (make-hash-table :test #'eq) #'eq)))
         (removed-identities (make-hash-table :test #'equal))
         (removed-handles (make-hash-table :test #'eq))
         (added-subjects (make-hash-table :test #'equal))
         (added-node-subjects (make-hash-table :test #'eq)))
    (if (null base-view)
        ;; Fact-only generations cannot seed a coherent relationship delta.
        (ebox-tree-source-index root t nil index)
      (cl-labels
          ((remove-node
             (node)
             (when-let* ((handle (ebox-tree-node-source-handle node)))
               (when-let* ((subject (ebox-source--index-node-subject old-index node)))
                 (puthash (ebox-selector-subject-token subject) t removed-tokens))
               (puthash handle t removed-handles)
               (puthash (ebox-source--handle-id-view handle) t
                        removed-identities)))
           (node-subject
             (handle)
             (or (gethash handle added-node-subjects)
                 (and (not (gethash handle removed-handles))
                      (ebox-source--table-value
                       base-node-subjects handle)))))
        (dolist (node removed) (remove-node node))
        (dolist (entry touched)
          (when-let* ((old (car entry))) (remove-node old)))
        ;; TOUCHED is preorder, so a copied parent subject is installed before
        ;; its child and local inheritance can bind without a tree scan.
        (dolist (entry touched)
          (let* ((node (nth 1 entry))
                 (handle (ebox-tree-node-source-handle node)))
            (when handle
              (let* ((record (or (ebox-source--index-record index handle)
                                 (error "Ebox candidate source is absent")))
                     (old-subject (and (car entry)
                                       (ebox-source--index-node-subject old-index (car entry))))
                     (subject (ebox-tree--subject-from-record
                               node record (and old-subject (ebox-selector-subject-token old-subject))))
                     (parent-id (nth 2 entry))
                     parent-subject)
                (while (and parent-id (null parent-subject))
                  (when-let* ((parent (ebox-runtime-index-get parent-id node-table)))
                    (when-let* ((parent-handle
                                 (ebox-tree-node-source-handle parent)))
                      (setq parent-subject (node-subject parent-handle))))
                  (unless parent-subject
                    (setq parent-id (ebox-runtime-index-get parent-id parent-table))))
                (setf (ebox-selector-subject-parent subject)
                      (and parent-subject (ebox-selector-subject-token parent-subject)))
                (puthash (ebox-selector-subject-token subject) subject added-view)
                (puthash (ebox-source--handle-id-view handle)
                         subject added-subjects)
                (puthash handle subject added-node-subjects)))))
        (cl-labels ((semantic-children (node)
                      (let (result)
                        (ebox-tree-for-each-direct-child
                         node
                         (lambda (child)
                           (if-let* ((handle (ebox-tree-node-source-handle child))
                                     (subject (node-subject handle)))
                               (push (ebox-selector-subject-token subject) result)
                             (setq result (nconc (reverse (semantic-children child)) result)))))
                        (nreverse result))))
          (dolist (entry touched)
            (let* ((node (nth 1 entry))
                   (subject (node-subject (ebox-tree-node-source-handle node))))
              (when subject
                (setf (ebox-selector-subject-children subject) (semantic-children node))))))
        (let* ((view (ebox-source--table-overlay
                      base-view added-view removed-tokens
                      (+ (- (ebox-source--table-size base-view) (hash-table-count removed-tokens))
                         (hash-table-count added-view))))
               (subjects
                (ebox-source--table-overlay
                 base-subjects added-subjects removed-identities
                 (+ (- (ebox-source--table-size base-subjects)
                       (hash-table-count removed-identities))
                    (hash-table-count added-subjects))))
               (node-subjects
                (ebox-source--table-overlay
                 base-node-subjects added-node-subjects removed-handles
                 (+ (- (ebox-source--table-size base-node-subjects)
                       (hash-table-count removed-handles))
                    (hash-table-count added-node-subjects)))))
          (ebox-source--with-derived
           index
           :subjects subjects :node-subjects node-subjects :selector-view view
           :selector-topology
           (if (ebox-selector-view-topology-stable-p base-view added-view removed-tokens)
               (ebox-source--index-selector-topology old-index)
             (make-symbol "ebox-selector-topology"))
           :entries (ebox-source--index-entries old-index)
           :root-subject
           (when-let* ((root-handle (ebox-tree-node-source-handle root)))
             (ebox-source--table-value node-subjects root-handle))
           :selector-id-table (ebox-source--index-selector-id-table old-index)
           :selector-class-table
           (ebox-source--index-selector-class-table old-index)
           :selector-type-table
           (ebox-source--index-selector-type-table old-index)
           :derived-stale-p t))))))

(defun ebox-tree-selector-index (root)
  "Return derived selector views over ROOT's unique source index."
  (let ((index (ebox-tree-source-index root)))
    (list :source-index index
          :selector-id-table
          (ebox-source--index-selector-table index 'id)
          :selector-class-table
          (ebox-source--index-selector-table index 'class)
          :selector-type-table
          (ebox-source--index-selector-table index 'type))))

(defun ebox-tree-selector-match-p (source-index selector subject)
  "Match SELECTOR against SUBJECT using SOURCE-INDEX's immutable view."
  (let ((ebox-selector-view--current (ebox-source--index-selector-view source-index)))
    (ecss-selector-match-p selector subject ebox-selector-view-adapter)))

(defun ebox-tree-style-source-index (root source-index &optional parent-kind)
  "Return SOURCE-INDEX when its selector relationships are already coherent.
Lazy query entries may remain stale; they do not invalidate the style view."
  (if (and source-index (ebox-source--index-selector-view source-index))
      source-index
    (ebox-tree-source-index root t parent-kind source-index)))

(defun ebox-tree-subject-index (root &optional source-index)
  "Return ECSS subject views over ROOT's SOURCE-INDEX.
Build a temporary index only for an unmounted tree query."
  (let ((index (or source-index (ebox-tree-source-index root))))
    (list :source-index index
          :root-subject (ebox-source--index-root-subject-view index)
          :entries (ebox-source--index-entries-view index)
          :node-subject-table
          (ebox-source--index-node-subject-table-view index))))

(defun ebox-tree-subject-for-path (source-index path)
  "Return SOURCE-INDEX's retained subject for the final node on PATH."
  (when-let* ((node (car (last path))))
    (ebox-tree-node-subject source-index node)))

(defun ebox-tree-flex-participation-props (node)
  "Return raw flex item participation props attached to NODE."
  (and (listp node)
       (ebox-tree-flex-direct-participation-props node)))

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
      (_ nil)))))

(defun ebox-tree-node-visible-overflow-p (node)
  "Return non-nil when NODE contains visible overflow that cannot be span patched."
  (cond
   ((or (stringp node) (not (listp node))) nil)
   ;; Canonical Text temporarily shares the legacy `ebox-type' storage tag so
   ;; the old renderer can paint it.  It is nevertheless a leaf, not a Box
   ;; formatting context, and therefore cannot own geometric overflow.
   ((eq (plist-get node :ebox-kind) 'text) nil)
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
      (_ nil)))))

(defalias 'ebox--computed-display #'ebox-tree-computed-display)
(defalias 'ebox--display-outer #'ebox-tree-display-outer)
(defalias 'ebox--display-inner #'ebox-tree-display-inner)
(defalias 'ebox--formatting-context-p #'ebox-tree-formatting-context-p)
(defalias 'ebox--layout-props #'ebox-tree-layout-props)
(defalias 'ebox--node-selector-type #'ebox-tree-node-selector-type)
(defalias 'ebox--layout-children #'ebox-tree-layout-children)
(defalias 'ebox--node-children #'ebox-tree-children)
(defalias 'ebox--flex-direct-participation-props
  #'ebox-tree-flex-direct-participation-props)
(defalias 'ebox--flex-participation-props
  #'ebox-tree-flex-participation-props)
(defalias 'ebox--node-all-region-ids #'ebox-tree-node-all-region-ids)
(defalias 'ebox--node-paint-conflict-p #'ebox-tree-node-paint-conflict-p)
(defalias 'ebox--node-path-to-region #'ebox-tree-node-path-to-region)
(defalias 'ebox--node-visible-overflow-p #'ebox-tree-node-visible-overflow-p)

(provide 'ebox-tree)

;;; ebox-tree.el ends here
