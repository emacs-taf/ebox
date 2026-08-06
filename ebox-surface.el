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
(require 'tp-reactive)
(require 'tp-surface)

(defvar ebox-region-types)
(defvar ebox--region-box-table)
(defvar ebox--scroll-global-state)
(defvar ebox--scroll-idle-prefetch-timers)
(defvar ebox--smooth-scroll-state-table)
(defvar ebox--buffer-render-state-table)
(defvar ebox--viewport-dependent-node-ids-cache)
(defvar ebox--viewport-dependent-subtree-cache)
(defvar ebox--viewport-height-dependent-subtree-cache)
(defvar ebox--render-runtime-revision)
(defvar ebox--render-cache-table)
(defvar ebox--render-cache-signature-cache)
(defvar ebox--flex-content-min-width-table)
(defvar ebox--scroll-window-initial-lookahead-lines-override)
(defvar ebox-viewport-width)
(defvar ebox-viewport-height)

(declare-function ebox--render-layout "ebox-layout" (node))
(declare-function ebox-incremental--hash-snapshot
                  "ebox-incremental" (table keys))
(declare-function ebox-incremental--restore-hash-snapshot
                  "ebox-incremental" (table entries))
(declare-function ebox-incremental--replace-hash-entries
                  "ebox-incremental" (target keys source))
(declare-function ebox--runtime-region-id-conflict
                  "ebox-incremental" (region-id-set target-buffer))
(declare-function ebox--viewport-dependent-node-id-axes
                  "ebox-incremental" (node))
(declare-function ebox--update-report
                  "ebox-incremental" (region-id strategy &rest props))
(declare-function ebox-incremental--finalize-declarative-scroll-publication
                  "ebox-incremental" (scroll-keys &optional prefetch-delay))
(declare-function ebox--scroll-schedule-idle-prefetch
                  "ebox" (region-id &optional delay))
(declare-function ebox--scroll-clear-state "ebox" (region-id))
(declare-function ebox--smooth-scroll-stop "ebox" (region-id))

(defvar-local ebox-surface--buffer-surface nil
  "Live TP content surface mounted for the current Ebox buffer.")

(cl-defstruct (ebox-surface--signals
               (:constructor ebox-surface--make-signals))
  "TP signals carrying one mounted Ebox surface's host context."
  buffer viewport-width viewport-height display scroll)

(defvar-local ebox-surface--context-signals nil
  "Buffer-scoped TP signals consumed by the mounted Ebox producer.")

(defun ebox-surface--signals-live-p (signals)
  "Return non-nil when every signal in SIGNALS is live."
  (and (ebox-surface--signals-p signals)
       (buffer-live-p (ebox-surface--signals-buffer signals))
       (cl-every
        #'tp-signal-live-p
        (list (ebox-surface--signals-viewport-width signals)
              (ebox-surface--signals-viewport-height signals)
              (ebox-surface--signals-display signals)
              (ebox-surface--signals-scroll signals)))))

(defun ebox-surface--dispose-signals (signals)
  "Dispose live TP SIGNALS owned by an abandoned Ebox mount."
  (when (ebox-surface--signals-p signals)
    (dolist (signal
             (list (ebox-surface--signals-viewport-width signals)
                   (ebox-surface--signals-viewport-height signals)
                   (ebox-surface--signals-display signals)
                   (ebox-surface--signals-scroll signals)))
      (when (tp-signal-live-p signal)
        (tp-signal-dispose signal)))
    (when-let ((buffer (ebox-surface--signals-buffer signals)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (eq ebox-surface--context-signals signals)
            (setq-local ebox-surface--context-signals nil)))))))

(defun ebox-surface--scroll-offsets (table)
  "Return immutable sorted scroll offsets copied from TABLE."
  (let (offsets)
    (when (hash-table-p table)
      (maphash
       (lambda (region-id state)
         (push (cons region-id (or (plist-get state :scroll-offset) 0))
               offsets))
       table))
    (sort offsets (lambda (left right) (< (car left) (car right))))))

(defun ebox-surface--context-values
    (buffer old-state state-overrides)
  "Return BUFFER context values after OLD-STATE and STATE-OVERRIDES."
  (cl-labels
      ((value (key fallback)
         (if (plist-member state-overrides key)
             (plist-get state-overrides key)
           (if (plist-member old-state key)
               (plist-get old-state key)
             fallback))))
    (let ((scroll-table
           (value :scroll-state-table
                  (plist-get old-state :scroll-state-table))))
      (list :viewport-width
            (value :viewport-width ebox-viewport-width)
            :viewport-height
            (value :viewport-height ebox-viewport-height)
            :display-signature
            (value :display-signature
                   (with-current-buffer buffer
                     (ebox--current-display-signature)))
            :scroll-offsets
            (ebox-surface--scroll-offsets scroll-table)))))

(defun ebox-surface--ensure-signals (buffer values)
  "Return BUFFER's context signals for VALUES and whether they were created."
  (let ((signals
         (with-current-buffer buffer ebox-surface--context-signals)))
    (if (ebox-surface--signals-live-p signals)
        (cons signals nil)
      (when signals (ebox-surface--dispose-signals signals))
      (setq signals
            (ebox-surface--make-signals
             :buffer buffer
             :viewport-width
             (tp-signal-create (plist-get values :viewport-width)
                               :scope buffer)
             :viewport-height
             (tp-signal-create (plist-get values :viewport-height)
                               :scope buffer)
             :display
             (tp-signal-create (plist-get values :display-signature)
                               :scope buffer)
             :scroll
             (tp-signal-create (plist-get values :scroll-offsets)
                               :scope buffer)))
      (with-current-buffer buffer
        (setq-local ebox-surface--context-signals signals))
      (cons signals t))))

(defun ebox-surface--stage-signal-values (signals values)
  "Stage VALUES into TP context SIGNALS in the active transaction."
  (tp-signal-set (ebox-surface--signals-viewport-width signals)
                 (plist-get values :viewport-width))
  (tp-signal-set (ebox-surface--signals-viewport-height signals)
                 (plist-get values :viewport-height))
  (tp-signal-set (ebox-surface--signals-display signals)
                 (plist-get values :display-signature))
  (tp-signal-set (ebox-surface--signals-scroll signals)
                 (plist-get values :scroll-offsets)))

(defun ebox-surface--live-buffer-surface (buffer)
  "Return BUFFER's live Ebox TP surface, or nil."
  (when (buffer-live-p buffer)
    (let ((surface
           (with-current-buffer buffer ebox-surface--buffer-surface)))
      (and (tp-surface-live-p surface) surface))))

(defun ebox-surface-buffer-mounted-p (buffer)
  "Return non-nil when BUFFER has a live Ebox TP surface."
  (not (null (ebox-surface--live-buffer-surface buffer))))

(defun ebox-surface-region-mounts (buffer region-id &optional roles)
  "Return REGION-ID's TP-owned output mounts in BUFFER.
When ROLES is non-nil, keep only direct mounts owning a listed Ebox role.
Without ROLES, include descendant output attached to the region's object.
The returned ranges are numeric snapshots; TP retains marker ownership."
  (when-let* ((surface (ebox-surface--live-buffer-surface buffer))
              (state (tp-surface-client-state surface))
              (table (plist-get state :region-surface-object-table))
              (object (gethash region-id table)))
    (cl-remove-if-not
     (lambda (mount)
       (let ((tags (plist-get mount :tags)))
         (if roles
             (and (equal (plist-get tags :ebox/region-id) region-id)
                  (cl-intersection roles (plist-get tags :ebox/roles)))
           (or (equal (plist-get tags :ebox/region-id) region-id)
               (plist-get tags :ebox/descendant-output)))))
     (tp-object-mounts object))))

(defun ebox-surface-region-bounds (buffer region-id &optional roles)
  "Return numeric bounds for REGION-ID's TP mounts in BUFFER.
ROLES has the same filtering meaning as in `ebox-surface-region-mounts'."
  (when-let ((mounts (ebox-surface-region-mounts buffer region-id roles)))
    (cons (apply #'min (mapcar (lambda (mount) (plist-get mount :start)) mounts))
          (apply #'max (mapcar (lambda (mount) (plist-get mount :end)) mounts)))))

(defun ebox-surface--runtime-keys (state key)
  "Return hash keys stored under KEY in runtime STATE."
  (when-let ((table (plist-get state key)))
    (ebox-surface--hash-keys table)))

(defun ebox-surface--bind-scroll-states-to-buffer (state buffer)
  "Bind every semantic scroll state in STATE to its owning BUFFER."
  (when-let ((table (plist-get state :scroll-state-table)))
    (maphash
     (lambda (region-id scroll-state)
       (puthash region-id (plist-put scroll-state :buffer buffer) table))
     table)))

(defun ebox-surface--commit-report (surface state report-base)
  "Return Ebox's compact report for SURFACE, STATE, and REPORT-BASE."
  (let* ((tp-report (tp-surface-report surface))
         (text-operations (or (plist-get tp-report :text-operations) 0))
         (property-operations
          (or (plist-get tp-report :property-operations) 0))
         (patch-count (+ text-operations property-operations))
         (report (copy-sequence report-base))
         (scoped-p (and (not (plist-get tp-report :full-root))
                        (> (or (plist-get tp-report :scope-count) 0) 0)))
         (planned-publication-scope (plist-get report :publication-scope)))
    (dolist (entry
             `((:runtime-published . t)
               (:runtime-revision . ,(plist-get state :runtime-revision))
               (:surface-revision . ,(tp-surface-revision surface))
               (:publication-scope . tp-surface)
               (:planned-publication-scope . ,planned-publication-scope)
               (:tp-render-scope . ,(if scoped-p 'objects 'surface-plan))
               (:tp-full-root . ,(plist-get tp-report :full-root))
               (:tp-scope-count . ,(plist-get tp-report :scope-count))
               (:tp-scope-range-count
                . ,(plist-get tp-report :scope-range-count))
               (:tp-scope-fallback . ,(plist-get tp-report :scope-fallback))
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
  (let (new-state region-snapshot scroll-snapshot
        old-surface old-mirror region-keys scroll-keys)
    (tp-transaction-participate
     (list 'ebox/runtime buffer)
     (lambda ()
       (setq new-state (tp-surface-client-state surface)
             old-surface
             (with-current-buffer buffer ebox-surface--buffer-surface)
             old-mirror (gethash buffer ebox--buffer-render-state-table)
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
         (ebox-surface--bind-scroll-states-to-buffer new-state buffer)
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
       (when after-publication
         (funcall after-publication
                  (plist-get new-state :last-update-report)))
       (unless (buffer-live-p buffer)
         (error "Ebox declarative target died during publication")))
     (lambda ()
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
             (if old-mirror
                 (puthash buffer old-mirror ebox--buffer-render-state-table)
               (remhash buffer ebox--buffer-render-state-table)))
         (remhash buffer ebox--buffer-render-state-table)
         (dolist (region-id region-keys)
           (remhash region-id ebox--region-box-table))
         (dolist (region-id scroll-keys)
           (ebox--scroll-clear-state region-id)
           (ebox--smooth-scroll-stop region-id)))))))

(defun ebox-surface-mount-buffer
    (buffer source &optional report-base after-publication
            preserve-identities-p state-overrides)
  "Mount or atomically update BUFFER from Ebox SOURCE and return its surface.
REPORT-BASE requests a committed Ebox report.  AFTER-PUBLICATION runs inside
the rollback-capable transaction.  PRESERVE-IDENTITIES-P retains identities
already present in a logical candidate.  STATE-OVERRIDES augments its runtime."
  (let* ((surface (ebox-surface--live-buffer-surface buffer))
         (old-state (and surface (tp-surface-client-state surface)))
         (context-values
          (ebox-surface--context-values buffer old-state state-overrides))
         (signals-result
          (ebox-surface--ensure-signals buffer context-values))
         (signals (car signals-result))
         (signals-created-p (cdr signals-result))
         (preserve-identities-p
          (or preserve-identities-p
              (and (null old-state)
                   (ebox-surface--source-identities-available-p
                    source buffer))))
         (producer
          (ebox-surface-producer
           source old-state preserve-identities-p state-overrides signals))
         success)
    (unwind-protect
        (progn
          (tp-with-transaction
            (ebox-surface--stage-signal-values signals context-values)
            (if surface
                (tp-surface-update surface producer)
              (setq surface
                    (tp-surface-mount
                     buffer producer
                     '(:capability content :inhibit-read-only t))))
            (ebox-surface--publish-runtime-state
             buffer surface old-state report-base after-publication))
          (setq success t)
          (let* ((new-state (tp-surface-client-state surface))
                 (scroll-keys
                  (delete-dups
                   (append
                    (copy-sequence (plist-get old-state :scroll-region-ids))
                    (copy-sequence
                     (plist-get new-state :scroll-region-ids))))))
            (ebox-incremental--finalize-declarative-scroll-publication
             scroll-keys))
          surface)
      (when (and signals-created-p (not success))
        (ebox-surface--dispose-signals signals)))))

(defun ebox-surface--viewport-report (state width height axes strategy)
  "Return a viewport report for STATE, WIDTH, HEIGHT, AXES, and STRATEGY."
  (let ((root (plist-get state :root-node)))
    (ebox--update-report
     nil strategy
     :constraint-source 'viewport
     :constraint-owner-id 'viewport
     :constraint-owner-type 'viewport
     :constraint-root-node-id (plist-get root :node-id)
     :viewport-axes axes
     :target-viewport-width width
     :target-viewport-height height
     :dirty-kinds (unless (eq axes 'none) '(geometry))
     :dirty-count (if (eq axes 'none) 0 1)
     :patch-count (if (eq axes 'none) 0 1)
     :patch-ops (unless (eq axes 'none) '(root-rerender))
     :owner-ids (unless (eq axes 'none)
                  (list (plist-get root :node-id)))
     :root-rerender (not (eq axes 'none)))))

(defun ebox-surface--publish-context-no-op
    (buffer surface state values state-overrides report)
  "Commit VALUES and no-op STATE-OVERRIDES into STATE for BUFFER and SURFACE."
  (let ((signals
         (with-current-buffer buffer ebox-surface--context-signals))
        (old-width (plist-get state :viewport-width))
        (old-height (plist-get state :viewport-height))
        (old-display (plist-get state :display-signature))
        (old-report (plist-get state :last-update-report)))
    (unless (ebox-surface--signals-live-p signals)
      (error "Ebox mounted surface has no live context signals"))
    (tp-with-transaction
      (ebox-surface--stage-signal-values signals values)
      (tp-transaction-participate
       (list 'ebox/context-no-op buffer)
       (lambda ()
         (unless (eq state (tp-surface-client-state surface))
           (error "Ebox no-op context unexpectedly published a surface"))
         (plist-put state :viewport-width
                    (plist-get state-overrides :viewport-width))
         (plist-put state :viewport-height
                    (plist-get state-overrides :viewport-height))
         (plist-put state :display-signature
                    (plist-get state-overrides :display-signature))
         (plist-put state :last-update-report report))
       (lambda ()
         (plist-put state :viewport-width old-width)
         (plist-put state :viewport-height old-height)
         (plist-put state :display-signature old-display)
         (plist-put state :last-update-report old-report))))
    report))

(defun ebox-surface-update-buffer-viewport (buffer width &optional height)
  "Publish BUFFER for viewport WIDTH and optional HEIGHT through TP."
  (let* ((surface (ebox-surface--live-buffer-surface buffer))
         (state (and surface (tp-surface-client-state surface))))
    (unless state
      (error "Ebox viewport update requires a mounted TP surface"))
    (let* ((old-width (plist-get state :viewport-width))
           (old-height (plist-get state :viewport-height))
           (target-height (or height old-height))
           (display-signature
            (with-current-buffer buffer
              (ebox--current-display-signature)))
           (display-changed
            (not (equal display-signature
                        (plist-get state :display-signature))))
           (width-changed (not (equal width old-width)))
           (height-changed (not (equal target-height old-height)))
           (axes (cond ((and width-changed height-changed) 'both)
                       (width-changed 'width)
                       (height-changed 'height)
                       (t 'none))))
      (if (and (eq axes 'none) (not display-changed))
          (let ((report
                 (ebox-surface--viewport-report
                  state width target-height axes 'no-op)))
            (plist-put state :last-update-report report)
            report)
        (ebox-incremental--notify-before-runtime-mutation buffer 'viewport)
        (unless (eq state (tp-surface-client-state surface))
          (error "Ebox runtime changed during viewport update notification"))
        (let ((commit-input
               (ebox-incremental-prepare-viewport-commit
                buffer width target-height axes display-signature)))
          (if (plist-get commit-input :no-op)
              (let* ((state-overrides
                      (plist-get commit-input :state-overrides))
                     (values
                      (ebox-surface--context-values
                       buffer state state-overrides)))
                (ebox-surface--publish-context-no-op
                 buffer surface state values state-overrides
                 (plist-get commit-input :report-base)))
            (ebox-surface-update-buffer-scoped
             buffer
             (plist-get commit-input :root)
             (plist-get commit-input :scope-node-ids)
             (plist-get commit-input :report-base)
             (plist-get commit-input :state-overrides)
             nil nil 0)
            (plist-get (tp-surface-client-state surface)
                       :last-update-report)))))))

(defun ebox-surface--projection-start (context root)
  "Create retained TP identities for ROOT in CONTEXT."
  (let* ((surface-root
          (tp-object-ensure context nil ebox-surface--root-key 'ebox/surface))
         (node-root
          (tp-object-ensure context surface-root
                            ebox-surface--nodes-key 'ebox/nodes))
         (objects-by-node (make-hash-table :test 'eq)))
    (tp-object-retain context node-root)
    (ebox-surface--ensure-node-tree context node-root root objects-by-node)
    (cons surface-root objects-by-node)))

(defun ebox-surface--projection-result
    (context projection state rendered)
  "Complete CONTEXT PROJECTION for STATE from RENDERED output."
  (let* ((surface-root (car projection))
         (objects-by-node (cdr projection))
         (node-objects (ebox-surface--node-object-table objects-by-node))
         (region-objects
          (ebox-surface--region-object-table state node-objects)))
    (plist-put state :surface-node-object-table node-objects)
    (plist-put state :region-surface-object-table region-objects)
    (plist-put state :surface-object-region-table
               (ebox-surface--object-region-table region-objects))
    (plist-put state :logical-id-region-table
               (ebox-surface--logical-id-region-table state region-objects))
    (tp-surface-result-create
     (ebox-surface--surface-plan
      context surface-root rendered state node-objects region-objects)
     state)))

(defun ebox-surface--mounted-object-for-node (state node-id)
  "Return NODE-ID's nearest live retained object with mounts in STATE."
  (let ((objects (plist-get state :surface-node-object-table))
        (parents (plist-get state :parent-table))
        object)
    (while (and node-id
                (progn
                  (setq object (and objects (gethash node-id objects)))
                  (or (not object) (null (tp-object-mounts object)))))
      (setq node-id (and parents (gethash node-id parents))))
    (unless (and object (tp-object-live-p object)
                 (tp-object-mounts object))
      (error "Ebox scoped owner has no mounted TP object"))
    object))

(defun ebox-surface--objects-for-node-ids (state node-ids)
  "Return mounted retained objects in STATE for Ebox NODE-IDS."
  (delete-dups
   (mapcar (lambda (node-id)
             (ebox-surface--mounted-object-for-node state node-id))
           node-ids)))

(defun ebox-surface-update-buffer-scoped
    (buffer source scope-node-ids report-base state-overrides
            &optional after-publication on-mismatch scroll-prefetch-delay)
  "Publish BUFFER SOURCE within SCOPE-NODE-IDS through TP.
STATE-OVERRIDES augments the isolated candidate runtime.  REPORT-BASE and
AFTER-PUBLICATION have the same meaning as in `ebox-surface-mount-buffer'.
ON-MISMATCH is forwarded to TP's scoped publication policy.
SCROLL-PREFETCH-DELAY controls post-publication lazy scroll warming."
  (let* ((surface (ebox-surface--live-buffer-surface buffer))
         (old-state (and surface (tp-surface-client-state surface))))
    (unless surface
      (error "Ebox scoped update requires a mounted TP surface"))
    (let ((objects
           (ebox-surface--objects-for-node-ids old-state scope-node-ids)))
      (unless objects
        (error "Ebox scoped update requires at least one retained owner"))
      (let* ((context-values
              (ebox-surface--context-values buffer old-state state-overrides))
             (signals-result
              (ebox-surface--ensure-signals buffer context-values))
             (signals (car signals-result))
             (signals-created-p (cdr signals-result))
             (producer
              (ebox-surface-producer
               source old-state t state-overrides signals))
             success)
        (unwind-protect
            (progn
              (tp-with-transaction
                (ebox-surface--stage-signal-values signals context-values)
                (tp-surface-update-scoped
                 surface objects producer
                 (and on-mismatch (list :on-mismatch on-mismatch)))
                (ebox-surface--publish-runtime-state
                 buffer surface old-state report-base after-publication))
              (setq success t)
              (let* ((new-state (tp-surface-client-state surface))
                     (scroll-keys
                      (delete-dups
                       (append
                        (copy-sequence
                         (plist-get old-state :scroll-region-ids))
                        (copy-sequence
                         (plist-get new-state :scroll-region-ids))))))
                (ebox-incremental--finalize-declarative-scroll-publication
                 scroll-keys scroll-prefetch-delay))
              surface)
          (when (and signals-created-p (not success))
            (ebox-surface--dispose-signals signals)))))))

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

(defun ebox-surface--retained-scroll-lookahead (state)
  "Return lookahead needed to retain STATE's prepared lazy prefixes."
  (when-let ((table (plist-get state :scroll-state-table)))
    (let ((maximum 0))
      (maphash
       (lambda (_region-id scroll-state)
         (let ((retained (length (plist-get scroll-state :content-lines)))
               (offset (or (plist-get scroll-state :scroll-offset) 0))
               (height (or (plist-get scroll-state :content-height) 0)))
           (setq maximum
                 (max maximum (- retained offset height 1)))))
       table)
      (max 0 maximum))))

(defun ebox-surface--scroll-metadata-snapshot (table producer-region-ids)
  "Return reusable lazy-scroll metadata copied from TABLE.
PRODUCER-REGION-IDS names scroll-only updates whose producer closures remain
valid because their declarative layout and viewport did not change."
  (let ((snapshot (make-hash-table :test 'equal)))
    (maphash
     (lambda (region-id state)
       (let ((preserve-producer-p
              (member region-id producer-region-ids))
             (producer-keys
              '(:content-lines :rendered-content-lines
                :content-lines-complete-p :render-content-prefix
                :materialize-content-lines :region-line-bounds-index
                :region-line-span-index :region-line-span-index-deferred
                :rendered-region-line-span-index
                :rendered-region-line-span-index-deferred
                :region-line-span-hints :cache-miss-prefetch-target-lines
                :native-reflow-target-prefix-p
                :native-reflow-prefix-reset-p :native-reflow-visible-offset
                :native-reflow-visible-lines))
             metadata)
         (dolist (key (append
                       '(:content-region-id-set :lazy-scroll-prefix-dirty
                         :lazy-scroll-window-refresh-required)
                       (and preserve-producer-p producer-keys)))
           (when (if (memq key producer-keys)
                     (plist-member state key)
                   (plist-get state key))
             (setq metadata
                   (plist-put metadata key (plist-get state key)))))
         (when metadata
           (puthash region-id metadata snapshot))))
     table)
    snapshot))

(defun ebox-surface--restore-scroll-metadata (table snapshot)
  "Restore reusable lazy-scroll SNAPSHOT fields into TABLE."
  (maphash
   (lambda (region-id metadata)
     (when-let ((state (gethash region-id table)))
       (while metadata
         (setq state
               (plist-put state (pop metadata) (pop metadata))))
       (puthash region-id state table)))
   snapshot))

(defun ebox-surface--render-candidate (state)
  "Render candidate STATE in isolated Ebox side tables."
  (let ((scroll-table
         (or (plist-get state :scroll-state-table)
             (make-hash-table :test 'equal)))
        (scroll-metadata
         (ebox-surface--scroll-metadata-snapshot
          (or (plist-get state :scroll-state-table)
              (make-hash-table :test 'equal))
          (plist-get state :preserve-scroll-producer-region-ids)))
        (timer-table (make-hash-table :test 'equal))
        (smooth-table (make-hash-table :test 'equal)))
    (cl-remf state :preserve-scroll-producer-region-ids)
    (let ((ebox-viewport-width (plist-get state :viewport-width))
          (ebox-viewport-height (plist-get state :viewport-height))
          (ebox--region-box-table (plist-get state :region-box-table))
          (ebox--scroll-global-state scroll-table)
          (ebox--scroll-idle-prefetch-timers timer-table)
          (ebox--smooth-scroll-state-table smooth-table)
          (ebox--render-runtime-revision
           (plist-get state :runtime-revision))
          (ebox--render-cache-table (plist-get state :render-cache))
          (ebox--render-cache-signature-cache
           (plist-get state :render-signature-cache))
          (ebox--scroll-window-initial-lookahead-lines-override
           (ebox-surface--retained-scroll-lookahead state))
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
          (ebox-surface--restore-scroll-metadata
           scroll-table scroll-metadata)
          (plist-put state :scroll-state-table scroll-table)
          (plist-put state :scroll-region-ids
                     (ebox-surface--hash-keys scroll-table)))))))

(defun ebox-surface--finish-runtime-state (state)
  "Install post-layout runtime indexes into candidate STATE."
  (ebox--render-state-install-index
   state (ebox--runtime-index (plist-get state :root-node) t)))

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

(defun ebox-surface--attach-fragment-ancestors
    (context fragment node-id state node-objects attached)
  "Attach FRAGMENT in CONTEXT to NODE-ID ancestors from STATE.
NODE-OBJECTS resolves retained objects; ATTACHED prevents duplicate mounts."
  (let ((parent-table (plist-get state :parent-table))
        (current (gethash node-id (plist-get state :parent-table))))
    (while current
      (let ((object (gethash current node-objects)))
        (unless object
          (error "Ebox output ancestor has no TP object: %S" current))
        (unless (gethash object attached)
          (tp-object-attach-fragment
           context object fragment '(:ebox/descendant-output t))
          (puthash object t attached)))
      (setq current (gethash current parent-table)))))

(defun ebox-surface--attach-fragment
    (context fragment role-ids state node-objects region-objects)
  "Attach FRAGMENT to direct and ancestor Ebox owners in CONTEXT.
ROLE-IDS identifies direct rendered regions.  STATE and NODE-OBJECTS extend
that ownership through the Ebox layout tree so a planned ancestor owner may
authorize every descendant output interval without exposing ranges to TP."
  (let ((attached (make-hash-table :test 'eq))
        (region-node-table (plist-get state :region-node-table)))
    (dolist (region-id (delete-dups (mapcar #'cdr role-ids)))
      (let ((object (gethash region-id region-objects))
            (node-id (gethash region-id region-node-table)))
        (unless (and object node-id)
          (error "Ebox output references unknown region %S" region-id))
        (unless (gethash object attached)
          (tp-object-attach-fragment
           context object fragment
           (ebox-surface--region-role-tags region-id role-ids))
          (puthash object t attached))
        (ebox-surface--attach-fragment-ancestors
         context fragment node-id state node-objects attached)))))

(defun ebox-surface--fragment-plan
    (context parent rendered start end index role-ids
             state node-objects region-objects)
  "Return one plan below PARENT for RENDERED START..END at INDEX.
ROLE-IDS names the Ebox owners attached through REGION-OBJECTS in CONTEXT."
  (let* ((key (cons 'ebox/fragment index))
         (object (tp-object-ensure context parent key 'ebox/fragment))
         (tags (list :ebox/fragment index :ebox/role-ids role-ids)))
    (ebox-surface--attach-fragment
     context object role-ids state node-objects region-objects)
    (tp-surface-plan-create
     :key key :kind 'ebox/fragment
     :text (substring rendered start end) :tags tags
     :capability 'content)))

(defun ebox-surface--fragment-plans
    (context parent rendered state node-objects region-objects)
  "Return property-interval plans in CONTEXT for RENDERED below PARENT."
  (let ((position 0)
        (limit (length rendered))
        intervals previous-role-ids next-role-ids)
    (while (< position limit)
      (let ((next (or (next-property-change position rendered limit) limit)))
        (push (list :start position :end next
                    :role-ids
                    (ebox-surface--role-ids-at rendered position))
              intervals)
        (setq position (max next (1+ position)))))
    (setq intervals (nreverse intervals))
    (dolist (interval intervals)
      (if-let ((roles (plist-get interval :role-ids)))
          (setq previous-role-ids roles)
        (plist-put interval :previous-role-ids previous-role-ids)))
    (dolist (interval (reverse (copy-sequence intervals)))
      (if-let ((roles (plist-get interval :role-ids)))
          (setq next-role-ids roles)
        (plist-put interval :role-ids
                   (delete-dups
                    (append (plist-get interval :previous-role-ids)
                            next-role-ids)))))
    (cl-loop for interval in intervals
             for fragment-index from 0
             collect
             (ebox-surface--fragment-plan
              context parent rendered
              (plist-get interval :start) (plist-get interval :end)
              fragment-index (plist-get interval :role-ids)
              state node-objects region-objects))))

(defun ebox-surface--surface-plan
    (context surface-root rendered state node-objects region-objects)
  "Return CONTEXT's plan below SURFACE-ROOT for RENDERED and STATE.
NODE-OBJECTS and REGION-OBJECTS supply retained ownership for its fragments."
  (let* ((fragment-root
          (tp-object-ensure context surface-root
                            ebox-surface--fragments-key 'ebox/fragments))
         (fragments
          (ebox-surface--fragment-plans
           context fragment-root rendered state node-objects region-objects)))
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

(defun ebox-surface--apply-scroll-offsets (root offsets)
  "Apply surface-scoped scroll OFFSETS to matching boxes below ROOT."
  (cl-labels
      ((visit (node)
         (when (and (listp node) (not (stringp node)))
           (when (eq (plist-get node :ebox-type) 'box)
             (when-let* ((region-id (plist-get node :region-id))
                         (entry (assq region-id offsets)))
               (ebox-put node :scroll-offset (cdr entry))))
           (dolist (child (ebox-tree--children-raw node))
             (visit child)))))
    (visit root))
  root)

(defun ebox-surface--context-axes (root)
  "Return ROOT's exact viewport dependency axes without shared caches."
  (let ((ebox--viewport-dependent-node-ids-cache
         (make-hash-table :test 'eq))
        (ebox--viewport-dependent-subtree-cache
         (make-hash-table :test 'eq))
        (ebox--viewport-height-dependent-subtree-cache
         (make-hash-table :test 'eq)))
    (ebox--viewport-dependent-node-id-axes root)))

(defun ebox-surface--project
    (context source previous-state preserve-identities-p state-overrides
             signals)
  "Project SOURCE in CONTEXT using PREVIOUS-STATE and identity policy.
PRESERVE-IDENTITIES-P retains existing Ebox node and region identities.
SIGNALS, when non-nil, supplies the mounted surface's host context."
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
           (axes (and signals (ebox-surface--context-axes root)))
           (viewport-width
            (and signals
                 (funcall
                  (if (car axes) #'tp-signal-read #'tp-signal-peek)
                  (ebox-surface--signals-viewport-width signals))))
           (viewport-height
            (and signals
                 (funcall
                  (if (cdr axes) #'tp-signal-read #'tp-signal-peek)
                  (ebox-surface--signals-viewport-height signals))))
           (display-signature
            (and signals
                 (tp-signal-read
                  (ebox-surface--signals-display signals))))
           (scroll-offsets
            (and signals
                 (tp-signal-peek
                  (ebox-surface--signals-scroll signals))))
           (state
            (ebox-surface--apply-state-overrides
             (ebox--new-buffer-render-state root)
             (copy-sequence state-overrides))))
      (when signals
        (plist-put state :viewport-width viewport-width)
        (plist-put state :viewport-height viewport-height)
        (plist-put state :display-signature display-signature)
        (plist-put state :viewport-dependent-node-id-axes axes)
        (plist-put state :viewport-dependent-node-ids
                   (delete-dups
                    (copy-sequence (append (car axes) (cdr axes)))))
        (plist-put state :viewport-dependent-node-ids-ready t)
        (ebox-surface--apply-scroll-offsets root scroll-offsets))
      (let ((projection (ebox-surface--projection-start context root)))
        (plist-put state :region-box-table (make-hash-table :test 'equal))
        (let ((rendered (ebox-surface--render-candidate state)))
          (when (and signals
                     (hash-table-p (plist-get state :scroll-state-table))
                     (> (hash-table-count
                         (plist-get state :scroll-state-table))
                        0))
            (tp-signal-read (ebox-surface--signals-scroll signals)))
          (setq state (ebox-surface--finish-runtime-state state))
          (ebox-surface--projection-result
           context projection state rendered))))))

(defun ebox-surface-producer
    (source &optional previous-state preserve-identities-p state-overrides
            signals)
  "Return a TP producer for Ebox SOURCE and optional PREVIOUS-STATE.
PRESERVE-IDENTITIES-P retains existing Ebox node and region identities.
STATE-OVERRIDES augments the candidate Ebox runtime state.  SIGNALS carries
the mounted surface context; one-shot string materialization omits it."
  (lambda (context)
    (ebox-surface--project
     context source previous-state preserve-identities-p state-overrides
     signals)))

(provide 'ebox-surface)

;;; ebox-surface.el ends here
