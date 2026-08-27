;;; ebox-native-commit.el --- Thin native frame commit for Ebox -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Converts one pure native frame into candidate-local Ebox state.  Rust owns
;; layout, paint-property composition, and the fragment effect tape; this file
;; only validates the side-effect boundary and installs already computed facts.

;;; Code:

(require 'cl-lib)

(declare-function ebox-native-reflow-layout-ready-p "ebox-native-reflow" ())
(declare-function ebox-native-reflow-execute-sync
                  "ebox-native-reflow" (node frame &optional layout-package))
(declare-function ebox-native-reflow-execute-session-sync
                  "ebox-native-reflow"
                  (session node frame &optional layout-package state))
(declare-function ebox-native-reflow-create-session
                  "ebox-native-reflow" (&rest arguments))
(declare-function ebox-native-reflow-fork-session
                  "ebox-native-reflow" (session &rest options))
(declare-function ebox-native-reflow-confirm-native-frame
                  "ebox-native-reflow"
                  (session generation key confirmed-revision))
(declare-function ebox-native-reflow-session-generation
                  "ebox-native-reflow" (session))
(declare-function ebox-native-reflow-frame-fragments
                  "ebox-native-reflow" (frame))
(declare-function ebox--literal-root-pixel-width "ebox" (box))
(declare-function ebox-get "ebox" (box key))
(declare-function ebox-style-cascade-active-p "ebox-style" ())
(declare-function ebox-tree-node-key "ebox-tree" (node))
(declare-function ebox-tree--children-raw "ebox-tree" (node))
(declare-function ebox--node-direct-viewport-width-dependent-p
                  "ebox-incremental" (node))
(declare-function ebox--node-direct-viewport-height-dependent-p
                  "ebox-incremental" (node))
(declare-function ebox--render-cache-contained-viewport-node-p
                  "ebox-incremental" (node))

(defun ebox-native-commit-topology-stable-p
    (old-state candidate-state prepared)
  "Return non-nil when PREPARED preserves OLD-STATE's object topology."
  (let ((old-nodes (plist-get old-state :node-table))
        (new-nodes (plist-get candidate-state :node-table))
        (old-parents (plist-get old-state :parent-table))
        (new-parents (plist-get candidate-state :parent-table))
        (old-regions (plist-get old-state :region-node-table))
        (new-regions (plist-get candidate-state :region-node-table))
        (old-objects (plist-get old-state :surface-node-object-table))
        (stable t)
        (missing (make-symbol "native-topology-missing")))
    (setq stable
          (and (null (plist-get prepared :removed-node-ids))
               (not (cl-some
                     (lambda (entry)
                       (eq (plist-get entry :dirty-kind) 'structure))
                     (plist-get prepared :dirty-set)))
               (hash-table-p old-nodes) (hash-table-p new-nodes)
               (hash-table-p old-parents) (hash-table-p new-parents)
               (hash-table-p old-regions) (hash-table-p new-regions)
               (hash-table-p old-objects)
               (= (hash-table-count old-nodes)
                  (hash-table-count new-nodes))
               (= (hash-table-count old-regions)
                  (hash-table-count new-regions))))
    (when stable
      (maphash
       (lambda (node-id node)
         (let ((old-node (gethash node-id old-nodes missing)))
           (unless (and (not (eq old-node missing))
                        (gethash node-id old-objects)
                        (equal (gethash node-id old-parents missing)
                               (gethash node-id new-parents missing))
                        (eq (plist-get old-node :ebox-type)
                            (plist-get node :ebox-type))
                        (equal (ebox-tree-node-key old-node)
                               (ebox-tree-node-key node)))
             (setq stable nil))))
       new-nodes))
    (when stable
      (maphash
       (lambda (region-id node-id)
         (unless (equal (gethash region-id old-regions missing) node-id)
           (setq stable nil)))
       new-regions))
    stable))

(defun ebox-native-commit-layout-touched-node-ids (candidate-state prepared)
  "Return PREPARED's exact dirty-to-root closure in CANDIDATE-STATE."
  (let ((parents (plist-get candidate-state :parent-table))
        (seen (make-hash-table :test 'equal))
        result)
    (dolist (entry (plist-get prepared :dirty-set))
      (let ((node-id (plist-get entry :node-id)))
        (while (and node-id (not (gethash node-id seen)))
          (puthash node-id t seen)
          (push node-id result)
          (setq node-id (and parents (gethash node-id parents))))))
    (nreverse result)))

(defun ebox-native-commit--node-position-table (state)
  "Return NODE-ID to `(PARENT-ID . POSITION)' table for STATE."
  (let ((nodes (plist-get state :node-table))
        (table (make-hash-table :test 'equal)))
    (when (hash-table-p nodes)
      (maphash
       (lambda (parent-id node)
         (cl-loop for child in (ebox-tree--children-raw node)
                  for position from 0
                  do (puthash (plist-get child :node-id)
                              (cons parent-id position) table)))
       nodes)
      (when-let* ((root (plist-get state :root-node)))
        (puthash (plist-get root :node-id) (cons nil 0) table)))
    table))

(defun ebox-native-commit-object-delta-node-ids
    (old-state candidate-state prepared)
  "Return the exact preorder TP object delta, or nil.
Compare OLD-STATE with CANDIDATE-STATE under PREPARED's local index proof.
Every old node absent from CANDIDATE-STATE must be named by PREPARED's removed
set.  Every new, replaced, moved, reparented, or explicitly touched node enters
the result.  Untouched nodes are authorized only when their old TP object,
type, key, parent, and sibling position are identical."
  (let* ((old-root (plist-get old-state :root-node))
         (new-root (plist-get candidate-state :root-node))
         (old-nodes (plist-get old-state :node-table))
         (new-nodes (plist-get candidate-state :node-table))
         (old-objects (plist-get old-state :surface-node-object-table))
         (old-positions (ebox-native-commit--node-position-table old-state))
         (new-positions
          (ebox-native-commit--node-position-table candidate-state))
         (requested (make-hash-table :test 'equal))
         (removed (make-hash-table :test 'equal))
         (replaced (make-hash-table :test 'equal))
         (missing (make-symbol "native-object-delta-missing"))
         (valid
          (and old-root new-root
               (equal (plist-get old-root :node-id)
                      (plist-get new-root :node-id))
               (eq (plist-get old-root :ebox-type)
                   (plist-get new-root :ebox-type))
               (equal (ebox-tree-node-key old-root)
                      (ebox-tree-node-key new-root))
               (hash-table-p old-nodes) (hash-table-p new-nodes)
               (hash-table-p old-objects)))
         result)
    (dolist (node-id (plist-get prepared :touched-node-ids))
      (if (gethash node-id new-nodes)
          (puthash node-id t requested)
        (setq valid nil)))
    (dolist (node-id (plist-get prepared :removed-node-ids))
      (if (and (gethash node-id old-nodes)
               (not (gethash node-id new-nodes)))
          (puthash node-id t removed)
        (setq valid nil)))
    (when valid
      (maphash
       (lambda (node-id _node)
         (when (and (not (gethash node-id new-nodes))
                    (not (gethash node-id removed)))
           (setq valid nil)))
       old-nodes))
    (when valid
      (cl-labels
          ((visit (node)
             (let* ((node-id (plist-get node :node-id))
                    (old-node (gethash node-id old-nodes missing))
                    (old-object (gethash node-id old-objects))
                    (position (gethash node-id new-positions))
                    (parent-id (car-safe position))
                    (replacement-p
                     (or (eq old-node missing)
                         (null old-object)
                         (not (eq (plist-get old-node :ebox-type)
                                  (plist-get node :ebox-type)))
                         (not (equal (ebox-tree-node-key old-node)
                                     (ebox-tree-node-key node)))))
                    (touched-p
                     (or replacement-p
                         (gethash node-id requested)
                         (gethash parent-id replaced)
                         (not (equal (gethash node-id old-positions missing)
                                     position)))))
               (unless (and node-id position)
                 (setq valid nil))
               (when replacement-p (puthash node-id t replaced))
               (when touched-p (push node-id result))
               (dolist (child (ebox-tree--children-raw node))
                 (visit child)))))
        (visit new-root)))
    (and valid result (nreverse result))))

(defun ebox-native-commit-context-axes-stable-p
    (old-state candidate-state prepared)
  "Return non-nil when PREPARED preserves viewport-axis membership."
  (let ((old-nodes (plist-get old-state :node-table))
        (new-nodes (plist-get candidate-state :node-table))
        stable)
    (setq stable
          (and (plist-get old-state :viewport-dependent-node-ids-ready)
               (plist-member old-state :viewport-dependent-node-id-axes)
               (hash-table-p old-nodes)
               (hash-table-p new-nodes)))
    (dolist (entry (plist-get prepared :dirty-set) stable)
      (let* ((node-id (plist-get entry :node-id))
             (old (and stable (gethash node-id old-nodes)))
             (new (and stable (gethash node-id new-nodes))))
        (unless (and old new
                     (eq (ebox--node-direct-viewport-width-dependent-p old)
                         (ebox--node-direct-viewport-width-dependent-p new))
                     (eq (ebox--node-direct-viewport-height-dependent-p old)
                         (ebox--node-direct-viewport-height-dependent-p new))
                     (eq (ebox--render-cache-contained-viewport-node-p old)
                         (ebox--render-cache-contained-viewport-node-p new)))
          (setq stable nil))))))

(defun ebox-native-commit-projection-eligible-p
    (previous-state state-overrides stylesheet-active-p)
  "Return non-nil when a candidate may use changed-only TP projection."
  (let ((state (append state-overrides nil)))
    (and previous-state
         (not stylesheet-active-p)
         (require 'ebox-native-reflow nil t)
         (ebox-native-reflow-layout-ready-p)
         (hash-table-p (plist-get previous-state
                                  :surface-node-object-table))
         (or (plist-get state :native-topology-stable-p)
             (consp (plist-get state :native-touched-node-ids)))
         (ebox-native-commit--runtime-types-supported-p state)
         (ebox-native-commit--region-index-safe-p state))))

(defun ebox-native-commit-viewport-continuity-eligible-p
    (previous-state candidate-state)
  "Return non-nil when CANDIDATE-STATE can extend the retained native frame.
The viewport planner owns the unchanged-topology proof.  This predicate owns
the native continuation contract: a live session, a confirmable prior frame,
the committed text/fragment bases, compiler postorder, and projection support."
  (and (eq (plist-get previous-state :projection-kind) 'native-frame)
       (plist-get previous-state :native-sync-session)
       (or (plist-get previous-state :native-sync-pending)
           (plist-get previous-state :native-sync-confirmed-p))
       (stringp (plist-get previous-state :native-committed-rendered))
       (vectorp
        (plist-get previous-state :native-committed-fragment-template))
       (plist-member previous-state :native-committed-owned-ranges)
       (let ((postorder (plist-get previous-state :native-node-postorder)))
         (and (vectorp postorder) (> (length postorder) 0)))
       (let ((state (copy-sequence candidate-state)))
         (plist-put state :native-topology-stable-p t)
         ;; Viewport context changed, but no declarative source node did.
         ;; Presence of this empty set is an explicit compiler certificate.
         (plist-put state :native-touched-node-ids nil)
         (plist-put state :native-removed-node-ids nil)
         (ebox-native-commit-projection-eligible-p
          previous-state state nil))))

(defun ebox-native-commit--isolate-session
    (previous-state candidate-state)
  "Give CANDIDATE-STATE a private child of PREVIOUS-STATE's native session."
  (when-let* ((session (plist-get previous-state :native-sync-session))
              (fork
               (condition-case nil
                   (ebox-native-reflow-fork-session session)
                 (error nil))))
    (plist-put candidate-state :native-sync-session fork)
    ;; A pending/confirmed frame is local to the previous Rust handle.  The
    ;; fork retains compiler facts but begins its own publication sequence.
    (plist-put candidate-state :native-sync-pending nil)
    (plist-put candidate-state :native-sync-confirmed-p nil)
    t))

(defun ebox-native-commit-prepare-viewport-continuity
    (previous-state candidate-state)
  "Prepare a private native viewport continuation in CANDIDATE-STATE."
  (and (ebox-native-commit-viewport-continuity-eligible-p
        previous-state candidate-state)
       (ebox-native-commit--isolate-session
        previous-state candidate-state)
       (progn
         (plist-put candidate-state :native-topology-stable-p t)
         (plist-put candidate-state :native-touched-node-ids nil)
         (plist-put candidate-state :native-removed-node-ids nil)
         t)))

(defun ebox-native-commit-plan-eligible-p
    (old-state candidate-state prepared)
  "Return non-nil when PREPARED can bypass superseded local layout proofs."
  (let* ((stable
          (ebox-native-commit-topology-stable-p
           old-state candidate-state prepared))
         (context-axes-stable
          (and stable
               (ebox-native-commit-context-axes-stable-p
                old-state candidate-state prepared)))
         (layout-touched
          (if stable
              (ebox-native-commit-layout-touched-node-ids
               candidate-state prepared)
            (ebox-native-commit-object-delta-node-ids
             old-state candidate-state prepared)))
         (state (copy-sequence candidate-state)))
    (plist-put state :native-touched-node-ids layout-touched)
    (plist-put state :native-topology-stable-p stable)
    (when (and (or stable layout-touched)
               (not (ebox-style-cascade-active-p))
               (ebox-native-commit-projection-eligible-p
                old-state state nil)
               (ebox-native-commit--isolate-session
                old-state candidate-state))
      (plist-put candidate-state :native-topology-stable-p stable)
      (plist-put candidate-state :native-touched-node-ids layout-touched)
      (when context-axes-stable
        (plist-put candidate-state :viewport-dependent-node-ids-ready t)
        (plist-put candidate-state :viewport-dependent-node-ids
                   (plist-get old-state :viewport-dependent-node-ids))
        (plist-put candidate-state :viewport-dependent-node-id-axes
                   (plist-get old-state :viewport-dependent-node-id-axes)))
      (unless stable
        (cl-remf candidate-state :native-fragment-owner-cache))
      t)))

(defun ebox-native-commit--root-box (node)
  "Return NODE's outer box, or nil."
  (pcase (plist-get node :ebox-type)
    ('box node)
    ('flex (plist-get node :box))))

(defun ebox-native-commit--region-box (state region-id)
  "Resolve REGION-ID's candidate box directly from STATE indexes."
  (when-let* ((node-id (gethash region-id
                                (plist-get state :region-node-table)))
              (node (gethash node-id (plist-get state :node-table))))
    (pcase (plist-get node :ebox-type)
      ('box node)
      ('flex (plist-get node :box)))))

(defun ebox-native-commit--region-index-safe-p (state)
  "Return non-nil when STATE has an unambiguous, non-scrolling region index."
  (let ((counts (plist-get state :region-box-count-table))
        (scroll (plist-get state :scroll-state-table))
        safe)
    (setq safe
          (and (hash-table-p counts)
               (or (null scroll)
                   (and (hash-table-p scroll)
                        (zerop (hash-table-count scroll))))))
    (when safe
      (maphash
       (lambda (region-id count)
         (let ((box (ebox-native-commit--region-box state region-id)))
           (unless (and (= count 1) box
                        (zerop (or (ebox-get box :scroll-offset) 0)))
             (setq safe nil))))
       counts))
    safe))

(defun ebox-native-commit--runtime-types-supported-p (state)
  "Return non-nil when STATE contains only executable native node types."
  (let ((nodes (plist-get state :node-table))
        (supported t))
    (when (hash-table-p nodes)
      (maphash
       (lambda (_node-id node)
         (unless (memq (plist-get node :ebox-type)
                       '(box concat stack flex))
           (setq supported nil)))
       nodes))
    supported))

(defun ebox-native-commit--install-region-boxes (state)
  "Install STATE's already indexed region boxes without walking its tree."
  (let ((table (plist-get state :region-box-table)))
    (unless (hash-table-p table)
      (setq table (make-hash-table :test 'equal))
      (plist-put state :region-box-table table))
    (when (zerop (hash-table-count table))
      (maphash
       (lambda (region-id _count)
         (puthash region-id
                  (ebox-native-commit--region-box state region-id)
                  table))
       (plist-get state :region-box-count-table)))
    table))

(defun ebox-native-commit--frame-spec (state node)
  "Return the exact native execution frame for STATE and NODE."
  (let* ((viewport-width (plist-get state :viewport-width))
         (viewport-height (plist-get state :viewport-height))
         (root-box (ebox-native-commit--root-box node))
         (root-width
          (or (and root-box (ebox--literal-root-pixel-width root-box))
              viewport-width)))
    (when (and (integerp viewport-width) (> viewport-width 0)
               (integerp viewport-height) (> viewport-height 0)
               (integerp root-width) (> root-width 0))
      (append
       (list :key 1
             :viewport-width viewport-width
             :viewport-height viewport-height
             :root-width root-width
             :runtime-revision
             (or (plist-get state :runtime-revision) 0)
             :context-hash
             (sxhash-equal
              (list viewport-width viewport-height root-width
                    (plist-get state :display-signature)))
             :complete t
             :root-metadata nil)
       (when (plist-get state :native-sync-confirmed-p)
         (list :base-viewport-width viewport-width
               :base-viewport-height viewport-height
               :base-root-width root-width))))))

(defun ebox-native-commit--apply-patches (source patches)
  "Return SOURCE with ordered native PATCHES applied."
  (let ((cursor 0) pieces)
    (dolist (patch patches)
      (let ((start (plist-get patch :old-start))
            (end (plist-get patch :old-end))
            (replacement (plist-get patch :replacement)))
        (unless (and (integerp start) (integerp end)
                     (<= cursor start end (length source))
                     (stringp replacement))
          (error "Native retained frame has an invalid patch"))
        (push (substring source cursor start) pieces)
        (push replacement pieces)
        (setq cursor end)))
    (push (substring source cursor) pieces)
    (apply #'concat (nreverse pieces))))

(defun ebox-native-commit--apply-fragment-style-delta (template delta)
  "Return TEMPLATE with Rust-computed fragment style DELTA applied."
  (unless (vectorp template)
    (error "Native fragment style delta has no retained template"))
  (let ((target (copy-sequence template)))
    (dolist (entry delta)
      (let ((index (car entry)))
        (unless (and (integerp index) (<= 0 index) (< index (length target)))
          (error "Native fragment style delta index is out of bounds"))
        (let ((record (copy-sequence (aref target index))))
          (aset record 7 (copy-sequence (cdr entry)))
          (aset target index record))))
    target))

(defun ebox-native-commit--promote-pending-frame (state session)
  "Promote STATE's previously published pending frame in SESSION."
  (when-let* ((pending (plist-get state :native-sync-pending)))
    (ebox-native-reflow-confirm-native-frame
     session (plist-get pending :generation) (plist-get pending :key)
     (plist-get pending :confirmed-revision))
    (plist-put state :native-sync-confirmed-p t)
    (cl-remf state :native-sync-pending)))

(defun ebox-native-commit--retained-frame (state node frame-spec)
  "Return NODE's full or patch-derived retained native frame for STATE."
  (let ((session
         (or (plist-get state :native-sync-session)
             (let ((created
                    (ebox-native-reflow-create-session
                     :workers 1 :max-jobs 4 :max-results 4)))
               (plist-put state :native-sync-session created)
               created))))
    (ebox-native-commit--promote-pending-frame state session)
    (let* ((result
            (ebox-native-reflow-execute-session-sync
             session node frame-spec nil state))
           (generation (ebox-native-reflow-session-generation session))
           (frame
            (if (plist-get result :native-patch)
                (let* ((source (plist-get state :native-committed-rendered))
                       (metadata (plist-get result :root-render-metadata))
                       (reuse-fragments
                        (plist-get result :reuse-fragment-template))
                       (fragment-style-delta
                        (plist-get result :fragment-style-delta))
                       (rendered nil))
                  (unless (stringp source)
                    (error "Native retained patch has no committed base"))
                  (when (or reuse-fragments fragment-style-delta)
                    (let ((template
                           (plist-get state
                                      :native-committed-fragment-template)))
                      (unless (vectorp template)
                        (error "Native retained patch has no fragment base"))
                      (when fragment-style-delta
                        (setq template
                              (ebox-native-commit--apply-fragment-style-delta
                               template fragment-style-delta)))
                      (setq metadata
                            (plist-put metadata :fragment-span-template
                                       template))))
                  (when (and (plist-get result :reuse-ownership-template)
                             (plist-get state :native-topology-stable-p))
                    (plist-put state :native-reuse-ownership-p t))
                  (when (and (plist-get result :reuse-mount-projection)
                             (plist-get state :native-topology-stable-p))
                    (plist-put state :native-reuse-mount-projection-p t))
                  (setq rendered
                        (ebox-native-commit--apply-patches
                         source (plist-get result :patches)))
                  (plist-put state :native-coordinate-patches
                             (plist-get result :coordinate-patches))
                  (list :native-frame t :rendered rendered
                        :root-render-metadata metadata
                        :effect-tape metadata
                        :line-widths []
                        :patches (plist-get result :patches)
                        :coordinate-patches
                        (plist-get result :coordinate-patches)
                        :base-character-count
                        (plist-get result :base-character-count)
                        :target-character-count
                        (plist-get result :target-character-count)
                        :styles (plist-get result :styles)
                        :property-templates
                        (plist-get result :property-templates)
                        :native-patch t
                        :reuse-fragment-template reuse-fragments
                        :reuse-ownership-template
                        (plist-get result :reuse-ownership-template)
                        :reuse-mount-projection
                        (plist-get result :reuse-mount-projection)
                        :fragment-style-delta fragment-style-delta))
              result)))
      (plist-put state :native-sync-pending
                 (list :generation generation :key 1
                       :confirmed-revision
                       (1+ (or (plist-get state :runtime-revision) 0))))
      (plist-put state :native-frame-kind
                 (if (plist-get frame :native-patch) 'patch 'full))
      frame)))

(defun ebox-native-commit-render (state node)
  "Return NODE's native rendered string after committing effects into STATE.
Return nil without mutating STATE when the native capability proof is absent."
  (when (and (require 'ebox-native-reflow nil t)
             (ebox-native-reflow-layout-ready-p)
             (eq (plist-get state :projection-kind) 'native-frame)
             (ebox-native-commit--runtime-types-supported-p state)
             (ebox-native-commit--region-index-safe-p state))
    (when-let* ((frame-spec (ebox-native-commit--frame-spec state node)))
      (condition-case err
          (let* ((frame (ebox-native-commit--retained-frame
                         state node frame-spec))
                 (effects (plist-get frame :effect-tape))
                 (rendered (plist-get frame :rendered))
                 (fragment-template
                  (and (not (plist-get effects :scroll-window-p))
                       (plist-get effects :fragment-span-template))))
            (when (and (stringp rendered) (vectorp fragment-template))
              (ebox-native-commit--install-region-boxes state)
              (plist-put state :render-owned-text-values
                         (make-hash-table :test #'eq))
              (plist-put state :native-render-output rendered)
              (plist-put state :native-render-frame frame)
              (plist-put state :native-render-fragment-template
                         fragment-template)
              (plist-put state :native-render-p t)
              rendered))
        (error
         (plist-put state :native-render-fallback
                    (error-message-string err))
         nil)))))

(provide 'ebox-native-commit)
;;; ebox-native-commit.el ends here
