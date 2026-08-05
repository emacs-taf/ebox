;;; ebox-tree.el --- Element tree model for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns runtime identity, display accessors, child traversal, parent paths, and
;; flex participation metadata.  It does not own layout measurement or buffer
;; editing.

;;; Code:

(require 'cl-lib)

(require 'subr-x)
(require 'ebox-style)

(defconst ebox--default-display '(block flow)
  "Default CSS-like display for a plain Ebox box.")

(defvar ebox--node-region-ids-cache nil
  "Dynamic snapshot-detail-local node -> region ids cache.
This is an optimization for snapshot capture, not buffer runtime state.")

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

(defun ebox-tree--metadata-string (value)
  "Return VALUE normalized to a selector metadata string."
  (cond
   ((null value) nil)
   ((symbolp value) (symbol-name value))
   ((stringp value) value)
   (t (format "%s" value))))

(defun ebox-tree-node-id (node)
  "Return NODE's selector id string from `:id', or nil."
  (and (listp node)
       (ebox-tree--metadata-string (plist-get node :id))))

(defun ebox-tree-node-classes (node)
  "Return NODE's selector class strings from `:class'."
  (when (listp node)
    (let ((class (plist-get node :class)))
      (cond
       ((null class) nil)
       ((listp class)
        (delq nil (mapcar #'ebox-tree--metadata-string class)))
       (t (list (ebox-tree--metadata-string class)))))))

(defun ebox-tree-node-key (node)
  "Return NODE's selector key string from `:key', or nil."
  (and (listp node)
       (ebox-tree--metadata-string (plist-get node :key))))

(defun ebox-tree--children-raw (node)
  "Return NODE's direct child nodes without assigning runtime ids."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box
     (delq nil (list (plist-get node :ebox-content-node))))
    ('concat
     (ebox-tree-layout-children node))
    ('stack
     (ebox-tree-layout-children node))
    ('flex
     (append (when-let ((box (plist-get node :box)))
               (list box))
             (plist-get node :children)))
    ('grid
     (append (when-let ((box (plist-get node :box)))
               (list box))
             (plist-get node :children)))
    ('flex-item
     (delq nil (list (plist-get node :node))))
    (_ nil)))

(defun ebox-tree-node-children (node)
  "Return NODE's direct declarative children without mutating them.
The returned nodes remain owned by their tree.  Callers may inspect them but
must not modify a published runtime tree through this accessor."
  (ebox-tree--children-raw node))

(defun ebox-tree-layout-children (node)
  "Return layout container children for NODE in render order.
New row/column containers store flat `:children'.  Legacy `ebox-concat' and
`ebox-stack' nodes may still carry `:left'/`:right' or `:top'/`:bottom'."
  (or (plist-get node :children)
      (pcase (and (listp node) (plist-get node :ebox-type))
        ('concat
         (delq nil (list (plist-get node :left)
                         (plist-get node :right))))
        ('stack
         (delq nil (list (plist-get node :top)
                         (plist-get node :bottom))))
        (_ nil))))

(defun ebox-tree--replace-direct-child (child replacements)
  "Return CHILD's identity replacement from REPLACEMENTS, when present.
REPLACEMENTS is an alist whose keys are compared with `eq'.  Nil is not a
child and is therefore never used as a replacement key."
  (if-let ((replacement (and child (assq child replacements))))
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
    (when (and (memq type '(concat stack flex grid))
               (plist-member copy :children))
      (let* ((children (plist-get copy :children))
             (replaced
              (ebox-tree--replace-direct-child-list children replacements)))
        (unless (eq replaced children)
          (setq copy (plist-put copy :children replaced)))))
    copy))

(defun ebox-tree-copy-node-structure (root)
  "Copy every Ebox node below ROOT while preserving opaque leaf values.
The returned tree owns distinct node plists and child lists.  Values such as
keymaps, callbacks, Host references, and surface-property payloads retain their
original object identity."
  (cl-labels
      ((copy-node
        (node)
        (if (or (not (listp node)) (stringp node))
            node
          (ebox-tree-copy-with-direct-child-replacements
           node
           (mapcar (lambda (child)
                     (cons child (copy-node child)))
                   (ebox-tree--children-raw node))))))
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
       (when-let ((child (plist-get node :ebox-content-node)))
         (plist-put shell :ebox-content-node
                    (ebox-tree--runtime-identity-skeleton
                     child node-id-set region-id-set))))
      ((or 'concat 'stack)
       (plist-put shell :children
                  (mapcar
                   (lambda (child)
                     (ebox-tree--runtime-identity-skeleton
                      child node-id-set region-id-set))
                   (ebox-tree-layout-children node))))
      ((or 'flex 'grid)
       (when-let ((box (plist-get node :box)))
         (plist-put shell :box
                    (ebox-tree--runtime-identity-skeleton
                     box node-id-set region-id-set)))
       (plist-put shell :children
                  (mapcar
                   (lambda (child)
                     (ebox-tree--runtime-identity-skeleton
                      child node-id-set region-id-set))
                   (plist-get node :children))))
      ('flex-item
       (when-let ((child (plist-get node :node)))
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
               (when-let ((host-ref (plist-get node :host-ref)))
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
                   (visit child))
                 (remhash node active))))))
      (visit root))
    root))

(defun ebox-tree-validate-declarative-root (root)
  "Validate ROOT for one declarative runtime commit.

The runtime tree must be a proper tree: a node object cannot appear in two
locations, cycles are rejected, explicit sibling keys must be unique, and
non-nil host references must be unique across the root.  Keys are sibling-local
and all explicit identities are compared with `equal'.  Return ROOT on success."
  (ebox-tree-validate-host-refs root)
  (let ((seen (make-hash-table :test 'eq))
        (active (make-hash-table :test 'eq)))
    (cl-labels
        ((visit (node)
           (when (and (listp node) (not (stringp node)))
             (when (gethash node active)
               (error "Ebox declarative tree contains a cycle"))
             (when (gethash node seen)
               (error "Ebox declarative tree reuses one node object"))
             (puthash node t seen)
             (puthash node t active)
             (let ((keys (make-hash-table :test 'equal)))
               (dolist (child (ebox-tree--children-raw node))
                 (when-let ((key (and (listp child)
                                      (not (stringp child))
                                      (plist-get child :key))))
                     (when (gethash key keys)
                       (error "Ebox declarative siblings use duplicate key %S"
                              key))
                     (puthash key t keys))
                 (visit child)))
             (remhash node active))))
      (visit root))
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
           (dolist (child (ebox-tree--children-raw node))
             (visit child)))))
    (visit root))
  root)

(defconst ebox-tree--runtime-source-keys
  '(:node-id :region-id :render-cache)
  "Runtime-owned plist keys excluded from declarative source signatures.")

(defconst ebox-tree--child-source-keys
  '(:children :left :right :top :bottom :node :box :ebox-content-node)
  "Child references excluded from node-local declarative signatures.")

(defconst ebox-tree--excluded-source-keys
  (append ebox-tree--runtime-source-keys ebox-tree--child-source-keys)
  "Runtime and child keys excluded from node-local source comparison.")

(defconst ebox-tree-metadata-source-keys
  '(:key :id :class :host-ref)
  "Declarative metadata keys that do not directly change rendered text.")

(defun ebox-tree--plist-keys (plist)
  "Return keys from PLIST in source order."
  (cl-loop for (key _value) on plist by #'cddr collect key))

(defun ebox-tree-node-local-source-signature (node)
  "Return NODE's non-recursive declarative source signature.

Runtime identities, caches, and child pointers are excluded.  Child order is
compared independently through stable runtime ids, so a leaf change does not
mark every ancestor dirty."
  (let ((plist node)
        signature)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (unless (memq key ebox-tree--excluded-source-keys)
          (push key signature)
          (push value signature))))
    (nreverse signature)))

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
  (unless (ebox-tree--local-source-sequence-equal-p old new)
    (let (seen changed)
      (dolist (source (list old new))
        (let ((plist source))
          (while plist
            (let ((key (pop plist)))
              (pop plist)
              (unless (or (memq key ebox-tree--excluded-source-keys)
                          (memq key seen))
                (push key seen)
                (let ((old-entry (plist-member old key))
                      (new-entry (plist-member new key)))
                  (unless (and (eq (not (null old-entry))
                                   (not (null new-entry)))
                               (equal-including-properties
                                (cadr old-entry) (cadr new-entry)))
                    (push key changed))))))))
      (nreverse changed))))

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
            (when-let ((key (node-key child)))
              (puthash key child table)))))
       (match-child
        (old-children old-keyed new-child index)
        (if-let ((key (node-key new-child)))
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
                  (cons (ebox--ensure-region-id node)
                        (ebox-tree-node-all-region-ids
                         (plist-get node :ebox-content-node))))
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
                   (when-let ((box (plist-get node :box)))
                     (list (ebox--ensure-region-id box)))
                   (apply #'append
                          (mapcar #'ebox-tree-node-all-region-ids
                                  (plist-get node :children)))))
                 ('grid
                  (append
                   (when-let ((box (plist-get node :box)))
                     (list (ebox--ensure-region-id box)))
                   (apply #'append
                          (mapcar #'ebox-tree-node-all-region-ids
                                  (plist-get node :children)))))
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
           (ebox-tree-node-paint-conflict-p
            (plist-get node :ebox-content-node) paint-key t)))
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
                (when-let ((box (plist-get node :box)))
                  (and (plist-get box paint-key) t)))
           (cl-some (lambda (child)
                      (ebox-tree-node-paint-conflict-p child paint-key t))
                    (plist-get node :children))))
      ('grid
       (or (and inherited
                (when-let ((box (plist-get node :box)))
                  (and (plist-get box paint-key) t)))
           (cl-some (lambda (child)
                      (ebox-tree-node-paint-conflict-p child paint-key t))
                    (plist-get node :children))))
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
           (when-let ((path (ebox-tree-node-path-to-region
                             (plist-get node :ebox-content-node)
                             region-id)))
             (append path (list node)))))
      ('concat
       (catch 'found
         (dolist (child (ebox-tree-layout-children node))
           (when-let ((path (ebox-tree-node-path-to-region child region-id)))
             (throw 'found (append path (list node)))))
         nil))
      ('stack
       (catch 'found
         (dolist (child (ebox-tree-layout-children node))
           (when-let ((path (ebox-tree-node-path-to-region child region-id)))
             (throw 'found (append path (list node)))))
         nil))
      ('flex
       (cond
        ((and (plist-get node :box)
              (equal (ebox-get (plist-get node :box) :region-id) region-id))
         (list node))
        (t
         (catch 'found
           (dolist (child (plist-get node :children))
             (when-let ((path (ebox-tree-node-path-to-region child region-id)))
               (throw 'found (append path (list node)))))
           nil))))
      ('grid
       (cond
        ((and (plist-get node :box)
              (equal (ebox-get (plist-get node :box) :region-id) region-id))
         (list node))
        (t
         (catch 'found
           (dolist (child (plist-get node :children))
             (when-let ((path (ebox-tree-node-path-to-region child region-id)))
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
           (ebox-tree-node-visible-overflow-p
            (plist-get node :ebox-content-node))))
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
                    (plist-get node :children))))
      ('grid
       (or (and (plist-get node :box)
                (ebox--box-visible-overflow-p (plist-get node :box)))
           (cl-some #'ebox-tree-node-visible-overflow-p
                    (plist-get node :children))))
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
