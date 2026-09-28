;;; ebox-fragment.el --- Layout fragments and snapshots for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns derived layout fragment and snapshot data used for diffing and
;; patchability checks.  It does not own source identity or buffer edits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-tree)
(require 'ebox-measure)

(declare-function ebox--current-display-signature "ebox-measure" ())
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox-style--declaration-value-equal-p
                  "ebox-style" (left right))
(declare-function ebox--complete-layout-snapshot
                  "ebox-incremental"
                  (buffer node snapshot &optional copy))

(defvar ebox--layout-fragments-table nil
  "Dynamic published-generation layout fragment retention table.")

(defvar ebox--layout-fragments-reuse-p nil
  "Non-nil when the current candidate may reuse retained layout fragments.")

(defconst ebox-fragment-flex-retention-max-entries 512
  "Maximum number of retained final-sized Flex fragments per generation.")

(defvar ebox-fragment-flex-retention-hit-count 0
  "Diagnostic count of retained final-sized Flex child fragment hits.")

(defvar ebox-fragment-flex-retention-rerender-count 0
  "Diagnostic count of final-sized Flex child fragment rerenders.")

(defvar ebox-fragment-flex-retention-store-count 0
  "Diagnostic count of retained final-sized Flex child fragment stores.")

(defun ebox-fragment-flex-allocation-key
    (source axis main cross align viewport &optional render-context)
  "Return exact retained-fragment key for SOURCE in Flex allocation context.
RENDER-CONTEXT contains layout-mode inputs that affect the rendered child but
are not part of its final allocated geometry."
  (when (and (hash-table-p ebox--layout-fragments-table)
             (listp source)
             (not (stringp source))
             (numberp viewport))
    (let ((height-key
           (if (and (plist-member render-context
                                  :viewport-height-dependent)
                    (null (plist-get render-context
                                     :viewport-height-dependent)))
               :viewport-height-independent
             (and (boundp 'ebox-viewport-height) ebox-viewport-height))))
      (list (ebox--ensure-node-id source)
            (copy-sequence (ebox--node-all-region-ids source))
            'flex-final-sized
            axis main cross align viewport
            height-key
            render-context
            (and (fboundp 'ebox--current-display-signature)
                 (ebox--current-display-signature))))))

(defun ebox-fragment-flex-retained-side-effects-reusable-p (metadata)
  "Return non-nil when retained fragment METADATA has no scroll effects.
Even a clear action is generation-sensitive: replaying or skipping it can
leave a stale scroll state after an A-to-B-to-A candidate sequence."
  (and (listp metadata)
       (not (plist-get metadata :stateful-p))
       (plist-member metadata :scroll-actions)
       (null (plist-get metadata :scroll-actions))))

(defun ebox-fragment-flex-retention-lookup (key)
  "Return retained Flex fragment entry for KEY, or nil."
  (when (and key (hash-table-p ebox--layout-fragments-table))
    (let ((entry (gethash key ebox--layout-fragments-table)))
      (when (and entry
                 ebox--layout-fragments-reuse-p
                 (ebox-fragment-flex-retained-side-effects-reusable-p
                  (plist-get entry :side-effects)))
        (cl-incf ebox-fragment-flex-retention-hit-count)
        (plist-get entry :entry)))))

(defun ebox-fragment-flex-retention-store (key entry side-effects)
  "Store retained Flex fragment ENTRY under KEY with SIDE-EFFECTS."
  (when (and key entry
             (ebox-fragment-flex-retained-side-effects-reusable-p
              side-effects)
             (hash-table-p ebox--layout-fragments-table))
    (when (and (not (gethash key ebox--layout-fragments-table))
               (>= (hash-table-count ebox--layout-fragments-table)
                   ebox-fragment-flex-retention-max-entries))
      (let (old-key)
        (maphash
         (lambda (candidate-key _old-entry)
           (setq old-key candidate-key))
         ebox--layout-fragments-table)
        (when old-key
          (remhash old-key ebox--layout-fragments-table))))
    (puthash key
             (list :entry entry :side-effects side-effects)
             ebox--layout-fragments-table)
    (cl-incf ebox-fragment-flex-retention-store-count))
  entry)

(cl-defstruct (ebox-fragment
               (:constructor ebox-fragment-create))
  node-id type display region-ids child-ids style-signature size
  line-signature span-footprint-signature external-footprint-signature
  parent-slot-signature role-topology-signature overflow-signature
  buffer-span buffer-spans)

(defun ebox-fragment-layout-signature (fragment)
  "Return layout-significant fields from FRAGMENT.
Backend marker and buffer span data are intentionally excluded."
  (let (signature)
    (dolist (field '(:node-id :type :display :region-ids :child-ids
                     :style-signature :size :line-signature))
      (let* ((name (intern (substring (symbol-name field) 1)))
             (accessor (intern (format "ebox-fragment-%s" name)))
             (value (and (fboundp accessor) (funcall accessor fragment))))
        (when value
          (setq signature (plist-put signature field value)))))
    signature))

(defun ebox-fragment--registry-signature-keys (signature)
  "Return computed engine keys owned by registry SIGNATURE classification.
Typography is represented separately by its resolved font fact, and
shorthands have already expanded before a computed node is inspected."
  (delete-dups
   (cl-loop for property in ebox-style--property-definitions
            when (and (eq (plist-get property :signature) signature)
                      (not (plist-get property :shorthand))
                      (not (eq (plist-get property :group) 'typography)))
            append (ebox-style--definition-engine-targets property))))

(defconst ebox--paint-style-signature-keys
  (ebox-fragment--registry-signature-keys 'paint)
  "Box properties that affect paint without changing layout geometry.")

(defconst ebox--typography-style-signature-keys
  '(:ebox-font-fact)
  "Typography properties whose resolved metrics may change geometry.")

(defconst ebox--geometry-style-signature-keys
  (delete-dups
   (append
    (ebox-fragment--registry-signature-keys 'layout)
    ebox--typography-style-signature-keys
    '(:vertical-align :flex-props :flex-participation)))
  "Computed engine fields that require layout or owner rerender work.
The style registry owns the property-to-engine mapping.  Typography compares
its resolved font fact rather than declarations; container and item fields
are collected from their computed runtime owners by the node signature.")

(defconst ebox--structure-style-signature-keys
  '(:display)
  "Style signature keys that change tree or formatting-context structure.")

(defconst ebox--style-signature-keys
  (append ebox--paint-style-signature-keys
          ebox--geometry-style-signature-keys)
  "Box properties included in layout snapshot style signatures.")

(defun ebox-fragment-style-source-node (node)
  "Return the box-like node carrying visual style for NODE."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box node)
    ('flex (plist-get node :box))
    ('grid (plist-get node :box))
    (_ nil)))

(defun ebox-fragment-node-style-signature (node)
  "Return NODE's display, layout, flex, and paint style signature."
  (when (listp node)
    (let* ((signature (list :display (ebox--computed-display node)))
           (style-node (ebox-fragment-style-source-node node))
           (config (plist-get node :ebox-layout-config))
           ;; Typed containers own computed child-layout properties in
           ;; LayoutConfig; legacy containers carry them in :props.  Read
           ;; these effective values, not declarations, alongside frame and
           ;; item fields so cascade-only changes have complete render effects.
           (layout-props (if config (ebox-layout-config-props config)
                           (plist-get node :props))))
      (dolist (key ebox--style-signature-keys)
        (when-let* ((entry (or (plist-member node key)
                              (and (not (eq node style-node))
                                   (plist-member style-node key))
                              (plist-member layout-props key))))
          ;; Pure Text and previously untouched Boxes can omit optional
          ;; placement defaults.  Materializing an identical schema default
          ;; during style preparation must not invent a geometry change.
          (let ((default (plist-member ebox-style--box-runtime-defaults key)))
            (unless (and default (equal (cadr entry) (cadr default)))
              (setq signature (plist-put signature key (cadr entry)))))))
      (when style-node
        (when-let* ((participation (ebox--flex-participation-props style-node)))
          (setq signature
                (plist-put signature :flex-participation participation))))
      (when (eq (ebox--display-inner node) 'flex)
        (setq signature
              (plist-put signature :flex-props
                         (plist-get node :props))))
      (when-let* ((participation (ebox--flex-participation-props node)))
        (setq signature
              (plist-put signature :flex-participation participation)))
      signature)))

(defun ebox-fragment-plist-keys (plist)
  "Return the keyword keys present in PLIST."
  (let (keys)
    (while plist
      (push (pop plist) keys)
      (pop plist))
    (nreverse keys)))

(defun ebox-fragment-plist-changed-keys (old new)
  "Return keys whose plist values differ between OLD and NEW."
  (let (changed keys)
    (dolist (key (append (ebox-fragment-plist-keys old)
                         (ebox-fragment-plist-keys new)))
      (cl-pushnew key keys))
    (dolist (key keys)
      (unless (ebox-style--declaration-value-equal-p
               (plist-get old key) (plist-get new key))
        (push key changed)))
    changed))

(defun ebox-fragment-style-signature-dirty-kind (old new)
  "Return dirty kind implied by OLD and NEW style signatures."
  (let ((changed (ebox-fragment-plist-changed-keys old new)))
    (cond
     ((null changed) nil)
     ((cl-some (lambda (key)
                 (memq key ebox--structure-style-signature-keys))
               changed)
      'structure)
     ((cl-some (lambda (key)
                 (memq key ebox--geometry-style-signature-keys))
               changed)
      'geometry)
     (t 'paint))))

(defun ebox-fragment-layout-snapshot-detailed-p (snapshot)
  "Return non-nil when SNAPSHOT already has expensive detail fields."
  (and (plist-member snapshot :buffer-spans)
       (plist-member snapshot :line-signature)
       (plist-member snapshot :span-footprint-signature)
       (plist-member snapshot :external-footprint-signature)
       (plist-member snapshot :parent-slot-signature)
       (plist-member snapshot :role-topology-signature)
       (plist-member snapshot :overflow-signature)))

(defun ebox-fragment-layout-snapshot-spans-p (snapshot)
  "Return non-nil when SNAPSHOT already has buffer span details."
  (plist-member snapshot :buffer-spans))

(defun ebox-fragment-node-layout-snapshot (buffer node &optional details)
  "Return a derived layout snapshot for NODE in BUFFER.
The default snapshot is intentionally lightweight; when DETAILS is non-nil,
include buffer spans and line signatures."
  (let* ((node-id (ebox--ensure-node-id node))
         (region-ids (ebox--node-all-region-ids node))
         (snapshot
          (list :node-id node-id
                :type (plist-get node :ebox-type)
                :display (ebox--computed-display node)
                :region-ids region-ids
                :style-signature (ebox--node-style-signature node)
                :child-ids
                (mapcar #'ebox--ensure-node-id
                        (ebox--node-children node)))))
    (if details
        (ebox--complete-layout-snapshot buffer node snapshot)
      snapshot)))

(defun ebox-fragment-layout-snapshot-dirty-kind (old new)
  "Return the dirty kind between OLD and NEW layout snapshots."
  (cond
   ((or (null old) (null new)) 'structure)
   ((not (eq (plist-get old :type)
             (plist-get new :type)))
    'structure)
   ((not (equal (plist-get old :display)
                (plist-get new :display)))
    'structure)
   ((not (equal (plist-get old :child-ids)
                (plist-get new :child-ids)))
    'structure)
   ((not (equal (plist-get old :line-signature)
                (plist-get new :line-signature)))
    'geometry)
   ((not (equal (plist-get old :buffer-spans)
                (plist-get new :buffer-spans)))
    'placement)
   ((not (equal (plist-get old :style-signature)
                (plist-get new :style-signature)))
    (ebox-fragment-style-signature-dirty-kind
     (plist-get old :style-signature)
     (plist-get new :style-signature)))))

(defalias 'ebox--style-source-node #'ebox-fragment-style-source-node)
(defalias 'ebox--node-style-signature #'ebox-fragment-node-style-signature)
(defalias 'ebox--plist-keys #'ebox-fragment-plist-keys)
(defalias 'ebox--plist-changed-keys #'ebox-fragment-plist-changed-keys)
(defalias 'ebox--style-signature-dirty-kind
  #'ebox-fragment-style-signature-dirty-kind)
(defalias 'ebox--layout-snapshot-detailed-p
  #'ebox-fragment-layout-snapshot-detailed-p)
(defalias 'ebox--layout-snapshot-spans-p
  #'ebox-fragment-layout-snapshot-spans-p)
(defalias 'ebox--node-layout-snapshot
  #'ebox-fragment-node-layout-snapshot)
(defalias 'ebox--layout-snapshot-dirty-kind
  #'ebox-fragment-layout-snapshot-dirty-kind)
(defalias 'ebox--flex-fragment-allocation-key
  #'ebox-fragment-flex-allocation-key)
(defalias 'ebox--flex-fragment-retention-lookup
  #'ebox-fragment-flex-retention-lookup)
(defalias 'ebox--flex-fragment-retention-store
  #'ebox-fragment-flex-retention-store)

(provide 'ebox-fragment)

;;; ebox-fragment.el ends here
