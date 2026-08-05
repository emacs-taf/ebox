;;; ebox-surface.el --- Retained projection and publication -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Owns the boundary from an Ebox candidate runtime to a generic TP surface
;; plan, and the atomic publication participant that mirrors the committed TP
;; generation into Ebox's buffer-local runtime indexes.

;;; Code:

(require 'cl-lib)
(require 'ebox-tree)
(require 'ebox-layout)
(require 'ebox-incremental)
(require 'tp-surface)

(defvar ebox-region-types)
(defvar ebox--region-box-table)
(defvar ebox--scroll-global-state)
(defvar ebox--scroll-idle-prefetch-timers)
(defvar ebox--smooth-scroll-state-table)
(defvar ebox--box-extents)
(defvar ebox--box-extent-template)
(defvar ebox--buffer-render-state-table)
(defvar ebox--viewport-dependent-node-ids-cache)
(defvar ebox--viewport-dependent-subtree-cache)
(defvar ebox--viewport-height-dependent-subtree-cache)
(defvar ebox--render-runtime-revision)
(defvar ebox--render-cache-table)
(defvar ebox--render-cache-signature-cache)
(defvar ebox--flex-content-min-width-table)

(declare-function ebox--render-layout "ebox-layout" (node))
(declare-function ebox-buffer--build-region-role-span-template
                  "ebox-buffer-backend" (string))
(declare-function ebox-buffer-materialize-region-role-spans
                  "ebox-buffer-backend" (buffer))
(declare-function ebox--build-box-extent-template "ebox" (rendered))
(declare-function ebox--build-scroll-content-span-template "ebox" (string))
(declare-function ebox--set-box-extents "ebox" (region-id start end))
(declare-function ebox--clear-buffer-extents
                  "ebox" (&optional buffer preserve-template))
(declare-function ebox--clear-box-extents-for-region-ids
                  "ebox" (region-ids))
(declare-function ebox--install-box-extent-template
                  "ebox" (buffer template start))
(declare-function ebox--install-buffer-scroll-content-span-template
                  "ebox" (buffer template start &optional defer-window-region-set))
(declare-function ebox-incremental--hash-snapshot
                  "ebox-incremental" (table keys))
(declare-function ebox-incremental--restore-hash-snapshot
                  "ebox-incremental" (table entries))
(declare-function ebox-incremental--replace-hash-entries
                  "ebox-incremental" (target keys source))
(declare-function ebox-incremental--detach-scroll-state-table-markers
                  "ebox-incremental" (table))
(declare-function ebox--runtime-region-id-conflict
                  "ebox-incremental" (region-id-set target-buffer))
(declare-function ebox--viewport-dependent-node-id-axes
                  "ebox-incremental" (node))
(declare-function ebox-incremental--detach-region-role-span-table
                  "ebox-incremental" (table))
(declare-function ebox-incremental--finalize-declarative-scroll-publication
                  "ebox-incremental" (scroll-keys))
(declare-function ebox--scroll-schedule-idle-prefetch
                  "ebox" (region-id &optional delay))
(declare-function ebox--scroll-clear-state "ebox" (region-id))
(declare-function ebox--smooth-scroll-stop "ebox" (region-id))

(defvar-local ebox-surface--buffer-surface nil
  "Live TP content surface mounted for the current Ebox buffer.")

(defun ebox-surface--live-buffer-surface (buffer)
  "Return BUFFER's live Ebox TP surface, or nil."
  (when (buffer-live-p buffer)
    (let ((surface
           (with-current-buffer buffer ebox-surface--buffer-surface)))
      (and (tp-surface-live-p surface) surface))))

(defun ebox-surface--buffer-extent-snapshot (buffer)
  "Return numeric live box extents owned by BUFFER."
  (let (snapshot)
    (maphash
     (lambda (region-id extents)
       (when (eq (marker-buffer (car extents)) buffer)
         (push (list region-id
                     (marker-position (car extents))
                     (marker-position (cdr extents)))
               snapshot)))
     ebox--box-extents)
    snapshot))

(defun ebox-surface--restore-buffer-extents (buffer snapshot template)
  "Restore BUFFER box extents from SNAPSHOT and numeric TEMPLATE."
  (ebox--clear-buffer-extents buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local ebox--box-extent-template template)
      (dolist (entry snapshot)
        (ebox--set-box-extents (nth 0 entry) (nth 1 entry) (nth 2 entry))))))

(defun ebox-surface--runtime-keys (state key)
  "Return hash keys stored under KEY in runtime STATE."
  (when-let ((table (plist-get state key)))
    (ebox-surface--hash-keys table)))

(defun ebox-surface--commit-report (surface state report-base)
  "Return Ebox's compact report for SURFACE, STATE, and REPORT-BASE."
  (let* ((tp-report (tp-surface-report surface))
         (text-operations (or (plist-get tp-report :text-operations) 0))
         (property-operations
          (or (plist-get tp-report :property-operations) 0))
         (patch-count (+ text-operations property-operations))
         (report (copy-sequence report-base))
         (planned-publication-scope (plist-get report :publication-scope)))
    (dolist (entry
             `((:runtime-published . t)
               (:runtime-revision . ,(plist-get state :runtime-revision))
               (:surface-revision . ,(tp-surface-revision surface))
               (:publication-scope . tp-surface)
               (:planned-publication-scope . ,planned-publication-scope)
               (:tp-render-scope . surface-plan)
               (:tp-operation-count . ,patch-count)
               (:tp-transaction-id . ,(plist-get tp-report :transaction-id))
               (:tp-text-operations . ,text-operations)
               (:tp-property-operations . ,property-operations)
               (:reconciled-objects
                . ,(plist-get tp-report :reconciled-objects))
               (:created-objects . ,(plist-get tp-report :created-objects))
               (:removed-objects . ,(plist-get tp-report :removed-objects))
               (:moved-objects . ,(plist-get tp-report :moved-objects))))
      (setq report (plist-put report (car entry) (cdr entry))))
    (unless (plist-member report :strategy)
      (setq report
            (plist-put report :strategy
                       (if (zerop patch-count) 'no-op 'surface-commit))))
    (unless (plist-member report :constraint-source)
      (setq report (plist-put report :constraint-source 'declarative)))
    (unless (plist-member report :constraint-root-node-id)
      (setq report
            (plist-put report :constraint-root-node-id
                       (plist-get (plist-get state :root-node) :node-id))))
    (unless (plist-member report :dirty-count)
      (setq report
            (plist-put report :dirty-count
                       (if (zerop patch-count) 0 1))))
    (unless (plist-member report :patch-count)
      (setq report (plist-put report :patch-count patch-count)))
    (unless (plist-member report :patch-ops)
      (setq report
            (plist-put report :patch-ops
                       (and (> patch-count 0) '(tp-surface)))))
    report))

(defun ebox-surface--publish-runtime-state
    (buffer surface old-state report-base after-publication)
  "Register BUFFER runtime publication for SURFACE after OLD-STATE.
REPORT-BASE requests an Ebox commit report.  AFTER-PUBLICATION, when non-nil,
runs after TP and Ebox point at the same candidate generation."
  (let (new-state region-snapshot scroll-snapshot extent-snapshot
        old-template old-surface old-mirror region-keys scroll-keys)
    (tp-transaction-participate
     (list 'ebox/runtime buffer)
     (lambda ()
       (setq new-state (tp-surface-client-state surface)
             old-surface
             (with-current-buffer buffer ebox-surface--buffer-surface)
             old-mirror (gethash buffer ebox--buffer-render-state-table)
             old-template (with-current-buffer buffer ebox--box-extent-template)
             extent-snapshot (ebox-surface--buffer-extent-snapshot buffer)
             region-keys
             (delete-dups
              (append (ebox-surface--runtime-keys old-state :region-id-set)
                      (ebox-surface--runtime-keys new-state :region-id-set)))
             scroll-keys
             (delete-dups
              (append (copy-sequence (plist-get old-state :scroll-region-ids))
                      (copy-sequence (plist-get new-state :scroll-region-ids)))))
       (setq region-snapshot
             (ebox-incremental--hash-snapshot
              ebox--region-box-table region-keys)
             scroll-snapshot
             (ebox-incremental--hash-snapshot
              ebox--scroll-global-state scroll-keys))
       (when new-state
         (plist-put new-state :surface surface)
         (plist-put new-state :runtime-revision
                    (1- (tp-surface-revision surface)))
         (when report-base
           (plist-put new-state :last-update-report
                      (ebox-surface--commit-report
                       surface new-state report-base))))
       (with-current-buffer buffer
         (setq-local ebox-surface--buffer-surface surface))
       (if new-state
           (puthash buffer new-state ebox--buffer-render-state-table)
         (remhash buffer ebox--buffer-render-state-table))
       (ebox-incremental--replace-hash-entries
        ebox--region-box-table region-keys
        (plist-get new-state :region-box-table))
       (ebox-incremental--replace-hash-entries
        ebox--scroll-global-state scroll-keys
        (plist-get new-state :scroll-state-table))
       (ebox--clear-buffer-extents buffer)
       (when new-state
         (ebox--install-box-extent-template
          buffer (plist-get new-state :box-extent-template) 1)
         (ebox--install-buffer-scroll-content-span-template
          buffer (plist-get new-state :scroll-content-span-template) 1)
         (ebox-buffer-materialize-region-role-spans buffer))
       (when after-publication
         (funcall after-publication
                  (plist-get new-state :last-update-report)))
       (unless (buffer-live-p buffer)
         (error "Ebox declarative target died during publication")))
     (lambda ()
       (when-let ((table (plist-get new-state :scroll-state-table)))
         (ebox-incremental--detach-scroll-state-table-markers table))
       (if (buffer-live-p buffer)
           (progn
             (when region-snapshot
               (ebox-incremental--restore-hash-snapshot
                ebox--region-box-table region-snapshot))
             (when scroll-snapshot
               (ebox-incremental--restore-hash-snapshot
                ebox--scroll-global-state scroll-snapshot))
             (with-current-buffer buffer
               (setq-local ebox-surface--buffer-surface old-surface))
             (ebox-surface--restore-buffer-extents
              buffer extent-snapshot old-template)
             (if old-mirror
                 (puthash buffer old-mirror ebox--buffer-render-state-table)
               (remhash buffer ebox--buffer-render-state-table)))
         (remhash buffer ebox--buffer-render-state-table)
         (dolist (region-id region-keys)
           (remhash region-id ebox--region-box-table))
         (dolist (region-id scroll-keys)
           (ebox--scroll-clear-state region-id)
           (ebox--smooth-scroll-stop region-id))
         (ebox--clear-box-extents-for-region-ids region-keys))))))

(defun ebox-surface--retire-state (old-state new-state)
  "Retire marker and timer resources in OLD-STATE after NEW-STATE commits."
  (when old-state
    (let ((old-role-table (plist-get old-state :region-role-span-table))
          (new-role-table (plist-get new-state :region-role-span-table)))
      (unless (eq old-role-table new-role-table)
        (ebox-incremental--detach-region-role-span-table old-role-table)))
    (let ((old-scroll-table (plist-get old-state :scroll-state-table))
          (new-scroll-table (plist-get new-state :scroll-state-table)))
      (unless (eq old-scroll-table new-scroll-table)
        (ebox-incremental--detach-scroll-state-table-markers old-scroll-table)))))

(defun ebox-surface-mount-buffer
    (buffer source &optional report-base after-publication
            preserve-identities-p state-overrides)
  "Mount or atomically update BUFFER from Ebox SOURCE and return its surface.
REPORT-BASE requests a committed Ebox report.  AFTER-PUBLICATION runs inside
the rollback-capable transaction.  PRESERVE-IDENTITIES-P retains identities
already present in a logical candidate.  STATE-OVERRIDES augments its runtime."
  (let* ((surface (ebox-surface--live-buffer-surface buffer))
         (old-state (and surface (tp-surface-client-state surface)))
         (preserve-identities-p
          (or preserve-identities-p
              (and (null old-state)
                   (ebox-surface--source-identities-available-p
                    source buffer))))
         (producer
          (ebox-surface-producer
           source old-state preserve-identities-p state-overrides)))
    (tp-with-transaction
      (if surface
          (tp-surface-update surface producer)
        (setq surface
              (tp-surface-mount
               buffer producer
               '(:capability content :inhibit-read-only t))))
      (ebox-surface--publish-runtime-state
       buffer surface old-state report-base after-publication))
    (let* ((new-state (tp-surface-client-state surface))
           (scroll-keys
            (delete-dups
             (append (copy-sequence (plist-get old-state :scroll-region-ids))
                     (copy-sequence (plist-get new-state :scroll-region-ids))))))
      (ebox-surface--retire-state old-state new-state)
      (ebox-incremental--finalize-declarative-scroll-publication scroll-keys))
    surface))

(defconst ebox-surface--root-key 'ebox/surface
  "Stable TP key for an Ebox surface projection root.")

(defconst ebox-surface--nodes-key 'ebox/nodes
  "Stable TP key for the retained logical Ebox node tree.")

(defconst ebox-surface--fragments-key 'ebox/fragments
  "Stable TP key for linear rendered fragments.")

(defun ebox-surface--clear-runtime-attachments (root)
  "Clear TP handles and render-cache attachments below ROOT."
  (cl-labels
      ((visit (node)
         (when (and (listp node) (not (stringp node)))
           (when (plist-member node :surface-object)
             (plist-put node :surface-object nil))
           (when (plist-member node :render-cache)
             (plist-put node :render-cache nil))
           (dolist (child (ebox-tree--children-raw node))
             (visit child)))))
    (visit root))
  root)

(defun ebox-surface--candidate-root
    (source previous-state preserve-identities-p)
  "Return an isolated runtime copy of SOURCE for PREVIOUS-STATE.
When PRESERVE-IDENTITIES-P is non-nil, retain existing Ebox node and region
identities while always discarding TP handles and render-cache attachments."
  (unless (and (listp source) (not (stringp source)))
    (error "Ebox surface source must be an Ebox node"))
  (ebox-tree-validate-declarative-root source)
  (let ((candidate (ebox-tree-copy-node-structure source)))
    (if preserve-identities-p
        (ebox-surface--clear-runtime-attachments candidate)
      (ebox-tree-clear-runtime-identities candidate))
    (when-let ((previous-root (plist-get previous-state :root-node)))
      (ebox-tree-reconcile-runtime previous-root candidate))
    candidate))

(defun ebox-surface--source-region-id-set (source)
  "Return region ids already present in Ebox SOURCE without mutating it."
  (let ((ids (make-hash-table :test 'equal)))
    (cl-labels
        ((visit (node)
           (when (and (listp node) (not (stringp node)))
             (when-let ((region-id (plist-get node :region-id)))
               (puthash region-id t ids))
             (dolist (child (ebox-tree--children-raw node))
               (visit child)))))
      (visit source))
    ids))

(defun ebox-surface--source-identities-available-p (source buffer)
  "Return non-nil when SOURCE's migration ids are available for BUFFER."
  (or (stringp source)
      (not (ebox--runtime-region-id-conflict
            (ebox-surface--source-region-id-set source) buffer))))

(defun ebox-surface--node-key (node)
  "Return NODE's namespaced sibling key, or nil for positional identity."
  (when-let ((key (plist-get node :key)))
    (list 'ebox/key key)))

(defun ebox-surface--node-kind (node)
  "Return the TP kind discriminator for Ebox NODE."
  (list 'ebox/node (plist-get node :ebox-type)))

(defun ebox-surface--ensure-node-tree (context parent node table)
  "Ensure NODE and descendants below PARENT in CONTEXT and fill TABLE."
  (let ((object
         (tp-object-ensure context parent
                           (ebox-surface--node-key node)
                           (ebox-surface--node-kind node))))
    (tp-object-retain context object)
    (plist-put node :surface-object object)
    (puthash node object table)
    (dolist (child (ebox-tree--children-raw node))
      (ebox-surface--ensure-node-tree context object child table))
    object))

(defun ebox-surface--node-object-table (objects-by-node)
  "Return a node-id keyed table from OBJECTS-BY-NODE."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (node object)
       (let ((node-id (plist-get node :node-id)))
         (unless node-id
           (error "Ebox rendered node has no runtime identity"))
         (puthash node-id object table)))
     objects-by-node)
    table))

(defun ebox-surface--region-object-table (state node-objects)
  "Return region-to-object table from candidate STATE and NODE-OBJECTS."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (region-id node-id)
       (let ((object (gethash node-id node-objects)))
         (unless object
           (error "Ebox region %S has no candidate surface object" region-id))
         (puthash region-id object table)))
     (plist-get state :region-node-table))
    table))

(defun ebox-surface--object-region-table (region-objects)
  "Return an object-to-region table from REGION-OBJECTS."
  (let ((table (make-hash-table :test 'eq)))
    (maphash (lambda (region-id object)
               (puthash object region-id table))
             region-objects)
    table))

(defun ebox-surface--node-editable-region-id (node)
  "Return NODE's editable Ebox region id, or nil."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box (plist-get node :region-id))
    ((or 'flex 'grid)
     (plist-get (plist-get node :box) :region-id))
    ('flex-item
     (ebox-surface--node-editable-region-id (plist-get node :node)))
    (_ nil)))

(defun ebox-surface--logical-id-region-table (state region-objects)
  "Return root-scoped logical-id entries for STATE and REGION-OBJECTS."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (logical-id entries)
       (dolist (entry entries)
         (when-let* ((region-id
                      (ebox-surface--node-editable-region-id (car entry)))
                     (object (gethash region-id region-objects)))
           (push (cons object region-id) (gethash logical-id table)))))
     (plist-get state :selector-id-table))
    (maphash (lambda (logical-id matches)
               (puthash logical-id (nreverse matches) table))
             table)
    table))

(defun ebox-surface--hash-keys (table)
  "Return TABLE keys in unspecified order."
  (let (keys)
    (maphash (lambda (key _value) (push key keys)) table)
    keys))

(defun ebox-surface--render-candidate (state)
  "Render candidate STATE in isolated Ebox side tables."
  (let ((scroll-table (make-hash-table :test 'equal))
        (timer-table (make-hash-table :test 'equal))
        (smooth-table (make-hash-table :test 'equal)))
    (let ((ebox--region-box-table (plist-get state :region-box-table))
          (ebox--scroll-global-state scroll-table)
          (ebox--scroll-idle-prefetch-timers timer-table)
          (ebox--smooth-scroll-state-table smooth-table)
          (ebox--render-runtime-revision
           (plist-get state :runtime-revision))
          (ebox--render-cache-table (plist-get state :render-cache))
          (ebox--render-cache-signature-cache
           (plist-get state :render-signature-cache))
          (ebox--viewport-dependent-node-ids-cache
           (make-hash-table :test 'eq))
          (ebox--viewport-dependent-subtree-cache
           (make-hash-table :test 'eq))
          (ebox--viewport-height-dependent-subtree-cache
           (plist-get state :viewport-height-dependent-subtree-cache))
          (ebox--flex-content-min-width-table
           (plist-get state :flex-content-min-widths)))
      (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                 (lambda (&rest _) nil)))
        (prog1 (let ((ebox--surface-materialization-active t))
                 (ebox--render-layout (plist-get state :root-node)))
          (plist-put state :scroll-state-table scroll-table)
          (plist-put state :scroll-region-ids
                     (ebox-surface--hash-keys scroll-table)))))))

(defun ebox-surface--finish-runtime-state (state)
  "Install post-layout runtime indexes into candidate STATE."
  (setq state
        (ebox--render-state-install-index
         state (ebox--runtime-index (plist-get state :root-node) t)))
  (let* ((root (plist-get state :root-node))
         (ebox--viewport-dependent-node-ids-cache
          (make-hash-table :test 'eq))
         (ebox--viewport-height-dependent-subtree-cache
          (plist-get state :viewport-height-dependent-subtree-cache))
         (axes (ebox--viewport-dependent-node-id-axes root)))
    (plist-put state :viewport-dependent-node-id-axes axes)
    (plist-put state :viewport-dependent-node-ids
               (and axes
                    (delete-dups
                     (copy-sequence (append (car axes) (cdr axes))))))
    (plist-put state :viewport-dependent-node-ids-ready t))
  state)

(defun ebox-surface--role-ids-at (rendered position)
  "Return namespaced Ebox role/id pairs at POSITION in RENDERED."
  (let (roles)
    (dolist (region-id
             (get-text-property position 'ebox-content-owners rendered))
      (cl-pushnew (cons 'content-owner region-id) roles :test #'equal))
    (dolist (entry ebox-region-types)
      (when-let ((region-id
                  (get-text-property position (cdr entry) rendered)))
        (cl-pushnew (cons (car entry) region-id) roles :test #'equal)))
    (nreverse roles)))

(defun ebox-surface--region-role-tags (region-id role-ids)
  "Return projection tags for REGION-ID from ROLE-IDS."
  (list :ebox/region-id region-id
        :ebox/roles
        (cl-loop for (role . owner) in role-ids
                 when (equal owner region-id) collect role)))

(defun ebox-surface--attach-fragment
    (context fragment role-ids region-objects)
  "Attach FRAGMENT to ROLE-IDS owners through REGION-OBJECTS in CONTEXT."
  (dolist (region-id (delete-dups (mapcar #'cdr role-ids)))
    (let ((object (gethash region-id region-objects)))
      (unless object
        (error "Ebox output references unknown region %S" region-id))
      (tp-object-attach-fragment
       context object fragment
       (ebox-surface--region-role-tags region-id role-ids)))))

(defun ebox-surface--fragment-plan
    (context parent rendered start end index region-objects)
  "Return one plan below PARENT for RENDERED START..END at INDEX in CONTEXT."
  (let* ((key (cons 'ebox/fragment index))
         (object (tp-object-ensure context parent key 'ebox/fragment))
         (role-ids (ebox-surface--role-ids-at rendered start))
         (tags (list :ebox/fragment index :ebox/role-ids role-ids)))
    (ebox-surface--attach-fragment
     context object role-ids region-objects)
    (tp-surface-plan-create
     :key key :kind 'ebox/fragment
     :text (substring rendered start end) :tags tags
     :capability 'content)))

(defun ebox-surface--fragment-plans
    (context parent rendered region-objects)
  "Return property-interval plans in CONTEXT for RENDERED below PARENT."
  (let ((position 0)
        (limit (length rendered))
        (index 0)
        plans)
    (while (< position limit)
      (let ((next (or (next-property-change position rendered limit) limit)))
        (push (ebox-surface--fragment-plan
               context parent rendered position next index region-objects)
              plans)
        (setq position (max next (1+ position))
              index (1+ index))))
    (nreverse plans)))

(defun ebox-surface--surface-plan
    (context surface-root rendered region-objects)
  "Return CONTEXT's plan below SURFACE-ROOT for RENDERED and REGION-OBJECTS."
  (let* ((fragment-root
          (tp-object-ensure context surface-root
                            ebox-surface--fragments-key 'ebox/fragments))
         (fragments
          (ebox-surface--fragment-plans
           context fragment-root rendered region-objects)))
    (tp-surface-plan-create
     :key ebox-surface--root-key :kind 'ebox/surface
     :children
     (list (tp-surface-plan-create
            :key ebox-surface--fragments-key :kind 'ebox/fragments
            :children fragments :capability 'content))
     :capability 'content)))

(defun ebox-surface--apply-state-overrides (state overrides)
  "Apply plist OVERRIDES to candidate runtime STATE and return STATE."
  (while overrides
    (setq state (plist-put state (pop overrides) (pop overrides))))
  state)

(defun ebox-surface--project
    (context source previous-state preserve-identities-p state-overrides)
  "Project SOURCE in CONTEXT using PREVIOUS-STATE and identity policy.
PRESERVE-IDENTITIES-P retains existing Ebox node and region identities."
  (if (stringp source)
      (let ((object
             (tp-object-ensure context nil ebox-surface--root-key
                               'ebox/string)))
        (ignore object)
        (tp-surface-result-create
         (tp-surface-plan-create
          :key ebox-surface--root-key :kind 'ebox/string
          :text source :capability 'content)))
    (let* ((root (ebox-surface--candidate-root
                  source previous-state preserve-identities-p))
           (state
            (ebox-surface--apply-state-overrides
             (ebox--new-buffer-render-state root)
             (copy-sequence state-overrides)))
         (surface-root
          (tp-object-ensure context nil ebox-surface--root-key 'ebox/surface))
         (node-root
          (tp-object-ensure context surface-root
                            ebox-surface--nodes-key 'ebox/nodes))
         (objects-by-node (make-hash-table :test 'eq)))
    (tp-object-retain context node-root)
    (ebox-surface--ensure-node-tree context node-root root objects-by-node)
    (plist-put state :region-box-table (make-hash-table :test 'equal))
    (let ((rendered (ebox-surface--render-candidate state)))
      (setq state (ebox-surface--finish-runtime-state state))
      (plist-put state :region-role-span-table
                 (ebox-buffer--build-region-role-span-template rendered))
      (plist-put state :box-extent-template
                 (ebox--build-box-extent-template rendered))
      (plist-put state :scroll-content-span-template
                 (let ((ebox--scroll-global-state
                        (plist-get state :scroll-state-table)))
                   (ebox--build-scroll-content-span-template rendered)))
      (let* ((node-objects (ebox-surface--node-object-table objects-by-node))
             (region-objects
              (ebox-surface--region-object-table state node-objects)))
        (plist-put state :surface-node-object-table node-objects)
        (plist-put state :region-surface-object-table region-objects)
        (plist-put state :surface-object-region-table
                   (ebox-surface--object-region-table region-objects))
        (plist-put state :logical-id-region-table
                   (ebox-surface--logical-id-region-table
                    state region-objects))
        (tp-surface-result-create
         (ebox-surface--surface-plan
          context surface-root rendered region-objects)
         state))))))

(defun ebox-surface-producer
    (source &optional previous-state preserve-identities-p state-overrides)
  "Return a TP producer for Ebox SOURCE and optional PREVIOUS-STATE.
PRESERVE-IDENTITIES-P retains existing Ebox node and region identities.
STATE-OVERRIDES augments the candidate Ebox runtime state."
  (lambda (context)
    (ebox-surface--project
     context source previous-state preserve-identities-p state-overrides)))

(provide 'ebox-surface)

;;; ebox-surface.el ends here
