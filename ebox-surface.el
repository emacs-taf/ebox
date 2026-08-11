;;; ebox-surface.el --- Retained projection and publication -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Owns the boundary from an Ebox candidate runtime to a generic TP surface
;; plan, and the atomic publication participant that mirrors the committed TP
;; generation into Ebox's buffer-local runtime indexes.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ebox-buffer-backend)
(require 'ebox-style)
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
(defvar ebox--layout-fragments-table)
(defvar ebox--layout-fragments-reuse-p)
(defvar ebox--flex-content-min-width-table)
(defvar ebox--scroll-window-initial-lookahead-lines-override)
(defvar ebox-viewport-width)
(defvar ebox-viewport-height)
(defvar ebox--render-display-signature)

(declare-function ebox--render-layout "ebox-layout" (node))
(declare-function ebox--record-render-output-provenance
                  "ebox-render-context" (rendered))
(declare-function ebox--render-owned-text-value-p
                  "ebox-render-context" (property value &optional registry))
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
(declare-function ebox-put "ebox" (box property value))
(declare-function ebox-string-lines "ebox" (string))
(declare-function tp-object-mounted-p "tp-surface" (object))
(declare-function tp-object-attach-content-ranges-owned
                  "tp-surface" (context leaf ranges))
(declare-function tp-text-snapshot
                  "tp-core" (text &optional reuse-property-p))
(declare-function tp-surface-plan-create-owned
                  "tp-surface" (&rest arguments))
(declare-function tp-surface-result-create-owned
                  "tp-surface" (context plan &optional client-state))
(declare-function tp-surface-report-summary "tp-surface" (surface))

(defvar-local ebox-surface--buffer-surface nil
  "Live TP content surface mounted for the current Ebox buffer.")

(cl-defstruct (ebox-surface--signals
               (:constructor ebox-surface--make-signals))
  "TP signals carrying one mounted Ebox surface's host context."
  buffer viewport-width viewport-height display scroll)

(defvar-local ebox-surface--context-signals nil
  "Buffer-scoped TP signals consumed by the mounted Ebox producer.")

(defconst ebox-surface--root-key 'ebox/surface
  "Stable TP key for an Ebox surface projection root.")

(defconst ebox-surface--nodes-key 'ebox/nodes
  "Stable TP key for the retained logical Ebox node tree.")

(defconst ebox-surface--fragments-key 'ebox/fragments
  "Stable TP key for linear rendered fragments.")

(defconst ebox-surface--text-key 'ebox/text
  "Stable TP key for the shared rendered text leaf.")

(defconst ebox-surface--inherited-style-properties
  '(ebox/color ebox/font ebox/font-family ebox/font-height
    ebox/font-weight ebox/font-slant)
  "ECSS properties whose inline values can flow to descendants.")

(defun ebox-surface--inline-inheritance-required-p (root)
  "Return non-nil when inline styles in ROOT require an ECSS cascade.
An empty stylesheet still needs a cascade when an inherited declaration can
reach a descendant that does not declare the same property.  Other inline
declarations are already projected into the candidate engine fields at node
construction time and can use the static projection path."
  (let ((pending (list (cons root nil)))
        required)
    (while (and pending (not required))
      (let* ((entry (pop pending))
             (node (car entry))
             (inherited (cdr entry))
             (declarations (ebox-style-node-declarations node)))
        (when (cl-some (lambda (property)
                         (and (memq property inherited)
                              (not (plist-member declarations property))))
                       ebox-surface--inherited-style-properties)
          (setq required t))
        (unless required
          (let ((next (copy-sequence inherited)))
            (dolist (property ebox-surface--inherited-style-properties)
              (when (plist-member declarations property)
                (cl-pushnew property next)))
            (dolist (child (ebox-tree-node-children node))
              (push (cons child next) pending))))))
    required))

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
  (let* ((tp-report (tp-surface-report-summary surface))
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
                     '(:capability content :inhibit-read-only t
                       :coordinate-mounts t))))
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
             nil nil 0
             (plist-get commit-input :projection-kind)
             ;; The incremental viewport candidate aliases the published root
             ;; while it proves the reflow shape.  Let the surface create its
             ;; own copy before layout can attach caches or TP handles.
             nil)
            (plist-get (tp-surface-client-state surface)
                       :last-update-report)))))))

(defun ebox-surface--projection-start
    (context root &optional style-required-p projection-kind previous-state)
  "Create retained TP identities and optional computed styles for ROOT.
STYLE-REQUIRED-P is non-nil when the candidate must refresh cascade results.
When it is nil, inline declarations already projected by node construction
are sufficient for the static layout pass.  PROJECTION-KIND may request a
strict span patch or retained viewport reflow, both of which reuse
PREVIOUS-STATE's node-object table."
  (let* ((surface-root
          (tp-object-ensure context nil ebox-surface--root-key 'ebox/surface))
         (node-root
          (tp-object-ensure context surface-root
                            ebox-surface--nodes-key 'ebox/nodes))
         (objects-by-node
          (if (memq projection-kind
                    '(span-patch viewport-reflow viewport-reflow-mixed-scroll))
              (or (plist-get previous-state :surface-node-object-table)
                  (error "Ebox span projection has no retained node table"))
            (make-hash-table :test 'eq)))
         (bindings-by-subject (make-hash-table :test 'eq))
         (subjects (when style-required-p
                     (ebox-tree-subject-index root))))
    (if (memq projection-kind
              '(span-patch viewport-reflow viewport-reflow-mixed-scroll))
        (tp-object-reuse-subtree context node-root)
      (progn
        (tp-object-retain context node-root)
        (ebox-surface--ensure-node-tree
         context node-root root objects-by-node
         (and subjects (plist-get subjects :node-subject-table))
         bindings-by-subject)))
    (list :surface-root surface-root
          :node-root node-root
          :objects-by-node objects-by-node)))

(defun ebox-surface--complete-projection
    (context root style-required-p projection)
  "Complete a retained PROJECTION for ROOT after a local proof miss.
The initial span attempt already owns the surface and node-root identities in
CONTEXT, so full fallback must populate those same objects instead of creating
the projection roots a second time."
  (let* ((node-root (plist-get projection :node-root))
         (objects-by-node (plist-get projection :objects-by-node))
         (bindings-by-subject (make-hash-table :test 'eq))
         (subjects (when style-required-p
                     (ebox-tree-subject-index root))))
    (tp-object-retain context node-root)
    (ebox-surface--ensure-node-tree
     context node-root root objects-by-node
     (and subjects (plist-get subjects :node-subject-table))
     bindings-by-subject)
    projection))

(defun ebox-surface--projection-result
    (context projection state output)
  "Complete CONTEXT PROJECTION for STATE from rendered OUTPUT."
  (let* ((surface-root (plist-get projection :surface-root))
         (objects-by-node (plist-get projection :objects-by-node))
         (node-objects (ebox-surface--node-object-table objects-by-node))
         (region-objects
          (ebox-surface--region-object-table state node-objects)))
    (plist-put state :surface-node-object-table node-objects)
    (plist-put state :region-surface-object-table region-objects)
    (plist-put state :surface-object-region-table
               (ebox-surface--object-region-table region-objects))
    (plist-put state :logical-id-region-table
               (ebox-surface--logical-id-region-table state region-objects))
    (let* ((prepared
            (ebox-surface--surface-plan
             context surface-root output state node-objects region-objects))
           (plan (car prepared)))
      (tp-surface-result-create-owned context plan state))))

(defun ebox-surface--mounted-object-for-node (state node-id)
  "Return NODE-ID's nearest live retained object with mounts in STATE."
  (let ((objects (plist-get state :surface-node-object-table))
        (parents (plist-get state :parent-table))
        object)
    (while (and node-id
                (progn
                  (setq object (and objects (gethash node-id objects)))
                  (or (not object) (not (tp-object-mounted-p object)))))
      (setq node-id (and parents (gethash node-id parents))))
    (unless (and object (tp-object-live-p object)
                 (tp-object-mounted-p object))
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
            &optional after-publication on-mismatch scroll-prefetch-delay
            projection-kind source-isolated-p)
  "Publish BUFFER SOURCE within SCOPE-NODE-IDS through TP.
STATE-OVERRIDES augments the isolated candidate runtime.  REPORT-BASE and
AFTER-PUBLICATION have the same meaning as in `ebox-surface-mount-buffer'.
ON-MISMATCH is forwarded to TP's scoped publication policy.
SCROLL-PREFETCH-DELAY controls post-publication lazy scroll warming.
PROJECTION-KIND may request a proven non-spatial candidate projection.
SOURCE-ISOLATED-P means SOURCE is an internally copied runtime candidate and
may be adopted without another structural copy or identity reconciliation.
When SOURCE-PATH-COPIED-P is non-nil, SOURCE shares untouched published nodes;
the surface must preserve those shared nodes while consuming the candidate."
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
               source old-state t state-overrides signals projection-kind
               source-isolated-p
               (plist-get state-overrides :source-path-copied-p)))
             success)
        (unwind-protect
            (progn
              (tp-with-transaction
                (ebox-surface--stage-signal-values signals context-values)
                (tp-surface-update-scoped
                 surface objects producer
                 (list :on-mismatch on-mismatch :return-report nil))
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

(defun ebox-surface--candidate-root (source preserve-identities-p)
  "Return an isolated runtime copy of SOURCE.
When PRESERVE-IDENTITIES-P is non-nil, retain existing Ebox node and region
identities while always discarding TP handles and render-cache attachments."
  (unless (and (listp source) (not (stringp source)))
    (error "Ebox surface source must be an Ebox node"))
  (ebox-tree-validate-declarative-root source)
  (let ((candidate (ebox-tree-copy-node-structure source)))
    (if preserve-identities-p
        (ebox-surface--clear-runtime-attachments candidate)
      (ebox-tree-clear-runtime-identities candidate))
    candidate))

(defun ebox-surface--isolated-viewport-overrides (overrides)
  "Copy mutable viewport caches in OVERRIDES for a private reflow candidate.
The retained viewport projection may reuse the TP object topology, but its
layout pass still writes Ebox-side caches.  Keep those writes out of the
published generation so a failed transaction has no cache state to restore."
  (let ((copy (copy-sequence overrides)))
    (dolist (key '(:render-cache :layout-fragments :render-signature-cache
                   :flex-content-min-widths
                   :viewport-height-dependent-subtree-cache))
      (when (plist-member copy key)
        (let ((value (plist-get copy key)))
          (when (hash-table-p value)
            (setq copy (plist-put copy key (copy-hash-table value)))))))
    copy))

(defun ebox-surface--reconcile-candidate (root previous-state)
  "Reconcile styled ROOT with PREVIOUS-STATE runtime identities."
  (when-let ((previous-root (plist-get previous-state :root-node)))
    (ebox-tree-reconcile-runtime previous-root root))
  root)

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

(defun ebox-surface--node-style-binding
    (object node subject bindings-by-subject)
  "Install and return NODE style binding on OBJECT for SUBJECT."
  (let* ((parent (ecss-subject-parent subject))
         (parent-binding (and parent (gethash parent bindings-by-subject)))
         (declarations (ebox-style-node-declarations node))
         (binding
          (tp-bind
           object 'ebox/computed-style
           (lambda ()
             (ebox-style-compute-subject
              subject declarations
              (and parent-binding (tp-binding-read parent-binding)))))))
    (puthash subject binding bindings-by-subject)
    binding))

(defun ebox-surface--apply-node-style
    (object node subject-table bindings-by-subject)
  "Compute and apply NODE style using retained OBJECT and SUBJECT-TABLE."
  (when-let ((subject (gethash node subject-table)))
    (ebox-style-apply-computed
     node
     (tp-binding-read
      (ebox-surface--node-style-binding
       object node subject bindings-by-subject)))))

(defun ebox-surface--ensure-node-tree
    (context parent node table subject-table bindings-by-subject)
  "Ensure styled NODE descendants below PARENT in CONTEXT and fill TABLE."
  (let ((object
         (tp-object-ensure context parent
                           (ebox-surface--node-key node)
                           (ebox-surface--node-kind node))))
    (tp-object-retain context object)
    (plist-put node :surface-object object)
    (puthash node object table)
    (when subject-table
      (ebox-surface--apply-node-style
       object node subject-table bindings-by-subject))
    (dolist (child (ebox-tree--children-raw node))
      (ebox-surface--ensure-node-tree
       context object child table subject-table bindings-by-subject))
    (when subject-table
      (ebox-style-sync-flex-item node))
    object))

(defun ebox-surface--node-object-table (objects-by-node)
  "Return a node-id keyed table from OBJECTS-BY-NODE."
  (let ((table (make-hash-table :test 'equal)))
    (maphash
     (lambda (node object)
       (let ((node-id (if (listp node)
                          (plist-get node :node-id)
                        node)))
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
  "Render candidate STATE or optional NODE in isolated side tables."
  (ebox-surface--render-candidate-node state (plist-get state :root-node)))

(defun ebox-surface--render-candidate-node (state node)
  "Render NODE from candidate STATE in isolated Ebox side tables."
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
              (ebox--render-display-signature
               (plist-get state :display-signature))
              (ebox--region-box-table (plist-get state :region-box-table))
          (ebox--scroll-global-state scroll-table)
          (ebox--scroll-idle-prefetch-timers timer-table)
          (ebox--smooth-scroll-state-table smooth-table)
          (ebox--render-runtime-revision
           (plist-get state :runtime-revision))
          (ebox--render-cache-table (plist-get state :render-cache))
          (ebox--layout-fragments-table
           (plist-get state :layout-fragments))
          (ebox--layout-fragments-reuse-p
           (plist-get state :layout-fragments-reuse-p))
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
           (plist-get state :flex-content-min-widths))
          (ebox--render-owned-text-values
           (make-hash-table :test #'eq)))
      (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                 (lambda (&rest _) nil)))
        (let ((rendered
               (let ((ebox--surface-materialization-active t))
                 (ebox--render-layout node))))
          (ebox--record-render-output-provenance rendered)
          (ebox-surface--restore-scroll-metadata
           scroll-table scroll-metadata)
          (plist-put state :scroll-state-table scroll-table)
          (plist-put state :scroll-region-ids
                     (ebox-surface--hash-keys scroll-table))
          (plist-put state :render-owned-text-values
                     ebox--render-owned-text-values)
          rendered)))))

(defun ebox-surface--attach-retained-node-objects (state)
  "Attach retained TP objects to candidate nodes in STATE."
  (let ((nodes (plist-get state :node-table))
        (objects (plist-get state :surface-node-object-table)))
    (when (and (hash-table-p nodes) (hash-table-p objects))
      (maphash
       (lambda (node-id object)
         (when-let ((node (gethash node-id nodes)))
           (plist-put node :surface-object object)))
       objects))
    state))

(defun ebox-surface--rendered-role-topology-signature
    (rendered region-ids)
  "Return rendered Ebox role topology for REGION-IDS in RENDERED."
  (let ((wanted (make-hash-table :test 'equal))
        (roles-table (make-hash-table :test 'eq))
        (position 0)
        (limit (length rendered)))
    (dolist (region-id region-ids)
      (puthash region-id t wanted))
    (while (< position limit)
      (dolist (entry (ebox-surface--role-ids-at rendered position))
        (when (gethash (cdr entry) wanted)
          (puthash (car entry) t roles-table)))
      (setq position
            (max (or (next-property-change position rendered limit) limit)
                 (1+ position))))
    (let (roles)
      (maphash (lambda (role _value) (push role roles)) roles-table)
      (list :roles
            (sort roles
                  (lambda (left right)
                    (string< (symbol-name left)
                             (symbol-name right))))))))

(defun ebox-surface--span-patch-lines (buffer spans rendered)
  "Return RENDERED shaped for BUFFER SPANS, or nil when unsafe."
  (with-current-buffer buffer
    (if (ebox-buffer--partial-line-slots-p spans)
        (ebox-buffer--rendered-in-existing-slots spans rendered nil t)
      (and (= (length spans) (length (ebox-string-lines rendered)))
           rendered))))

(defun ebox-surface--projected-span-positions (spans lines)
  "Return BUFFER span positions after replacing SPANS with LINES."
  (when (= (length spans) (length lines))
    (let ((delta 0) result)
      (cl-loop for span in spans
               for line in lines
               do (let* ((start (+ (car span) delta))
                         (end (+ start (length line))))
                    (push (cons start end) result)
                    (setq delta
                          (+ delta (- (length line)
                                      (- (cdr span) (car span)))))))
      (nreverse result))))

(defun ebox-surface--replace-buffer-spans
    (source origin spans lines)
  "Return SOURCE with buffer SPANS replaced by propertized LINES."
  (catch 'invalid
    (let ((cursor origin) pieces)
      (cl-loop for span in spans
               for line in lines
               do (let ((start (car span)) (end (cdr span)))
                    (when (or (< start cursor) (< end start))
                      (throw 'invalid nil))
                    (push (substring source (- cursor origin) (- start origin))
                          pieces)
                    (push line pieces)
                    (setq cursor end)))
      (push (substring source (- cursor origin)) pieces)
      (apply #'concat (nreverse pieces)))))

(defun ebox-surface--span-patch-details
    (_buffer snapshot node spans rendered)
  "Return validated replacement details for SNAPSHOT and RENDERED."
  (let* ((lines (ebox-string-lines rendered))
         (new-spans (ebox-surface--projected-span-positions spans lines))
         (old-footprint (plist-get snapshot :span-footprint-signature))
         (new-footprint
          (and new-spans (ebox--rendered-span-footprint-signature rendered)))
         (new-external
          (and new-footprint
               (ebox--external-footprint-signature-from-span-footprint
                new-footprint)))
         (new-parent
          (and new-footprint
               (ebox--project-parent-slot-signature
                (plist-get snapshot :parent-slot-signature)
                new-footprint)))
         (new-roles
          (and new-spans
               (ebox-surface--rendered-role-topology-signature
                rendered (plist-get snapshot :region-ids))))
         (new-overflow (ebox--overflow-signature node)))
    (when (and old-footprint new-footprint
               (ebox--span-footprint-compatible-p
                old-footprint new-footprint)
               (ebox--external-footprint-compatible-p
                (plist-get snapshot :external-footprint-signature)
                new-external)
               (ebox--parent-slot-compatible-p
                (plist-get snapshot :parent-slot-signature) new-parent)
               (equal (plist-get snapshot :role-topology-signature)
                      new-roles)
               (equal (plist-get snapshot :overflow-signature)
                      new-overflow))
      (list :lines lines :spans new-spans :footprint new-footprint
            :external new-external :parent new-parent :roles new-roles
            :overflow new-overflow))))

(defun ebox-surface--install-span-patch-snapshot
    (state owner-id snapshot details)
  "Install DETAILS for OWNER-ID into candidate STATE snapshots."
  (let* ((generation (1+ (or (plist-get state
                                       :layout-snapshot-detail-generation)
                             0)))
         (updated (copy-sequence snapshot))
         (spans (plist-get details :spans))
         (footprint (plist-get details :footprint)))
    (dolist (entry `((:buffer-span . ,(car spans))
                     (:buffer-spans . ,spans)
                     (:line-signature . ,(plist-get footprint
                                                    :line-pixel-widths))
                     (:span-footprint-signature . ,footprint)
                     (:external-footprint-signature
                      . ,(plist-get details :external))
                     (:parent-slot-signature . ,(plist-get details :parent))
                     (:role-topology-signature . ,(plist-get details :roles))
                     (:overflow-signature . ,(plist-get details :overflow))
                     (:detail-generation . ,generation)))
      (setq updated (plist-put updated (car entry) (cdr entry))))
    (puthash owner-id updated (plist-get state :layout-snapshots))
    (plist-put state :layout-snapshot-detail-generation generation)
    (plist-put state :layout-snapshots-complete-p nil)
    state))

(defun ebox-surface--span-patch-output
    (buffer state)
  "Return a proven full output for OWNER-ID's local span patch, or nil."
  (let* ((owner-id (plist-get state :span-patch-owner-id))
         (old-snapshot
          (and owner-id (ebox--ensure-layout-snapshot-details buffer owner-id)))
         (spans (and old-snapshot (plist-get old-snapshot :buffer-spans)))
         (node (and owner-id (gethash owner-id (plist-get state :node-table)))))
    (when (and old-snapshot spans node)
      (with-current-buffer buffer
        (save-restriction
          (widen)
          (let* ((origin (point-min))
                 (source (buffer-substring (point-min) (point-max)))
                 (rendered (ebox-surface--render-candidate-node state node))
                 (replacement
                  (ebox-surface--span-patch-lines buffer spans rendered))
                 (details
                  (and replacement
                       (ebox-surface--span-patch-details
                        buffer old-snapshot node spans replacement)))
                 (lines (and details (plist-get details :lines)))
                 (output (and lines
                              (ebox-surface--replace-buffer-spans
                               source origin spans lines))))
            (when output
              (ebox-surface--install-span-patch-snapshot
               state owner-id old-snapshot details)
              output)))))))

(defun ebox-surface--runtime-index-ready-p (state)
  "Return non-nil when STATE carries a complete prepared runtime index."
  (let* ((root (plist-get state :root-node))
         (root-id (and root (plist-get root :node-id)))
         (nodes (plist-get state :node-table)))
    (and (plist-get state :runtime-index-prepared-p)
         root-id
         (hash-table-p nodes)
         (eq root (gethash root-id nodes))
         (hash-table-p (plist-get state :parent-table))
         (hash-table-p (plist-get state :region-id-set))
         (hash-table-p (plist-get state :region-node-table))
         (hash-table-p (plist-get state :region-box-count-table))
         (hash-table-p (plist-get state :region-box-table))
         (hash-table-p (plist-get state :host-ref-table))
         (vectorp (plist-get state :native-node-postorder)))))

(defun ebox-surface--finish-runtime-state (state)
  "Install or retain the prepared runtime indexes in candidate STATE."
  (unless (ebox-surface--runtime-index-ready-p state)
    (ebox--render-state-install-index
     state (ebox--runtime-index (plist-get state :root-node) t)))
  state)

(defun ebox-surface--role-ids-from-properties (properties)
  "Return namespaced Ebox role/id pairs from PROPERTIES."
  (let (roles)
    (when-let ((region-id
                (plist-get properties 'ebox-overflow-foreground-source)))
      (push (cons 'overflow-foreground region-id) roles))
    (dolist (region-id (plist-get properties 'ebox-content-owners))
      (cl-pushnew (cons 'content-owner region-id) roles :test #'equal))
    (dolist (entry ebox-region-types)
      (when-let ((region-id (plist-get properties (cdr entry))))
            (cl-pushnew (cons (car entry) region-id) roles :test #'equal)))
    (nreverse roles)))

(defun ebox-surface--role-ids-at (rendered position &optional cache)
  "Return namespaced Ebox role/id pairs at POSITION in RENDERED.
CACHE, when non-nil, reuses role extraction for equal property plists during
one output projection."
  (let* ((properties (text-properties-at position rendered))
         (missing (make-symbol "ebox-role-cache-missing"))
         (cached (and cache (gethash properties cache missing))))
    (if (and cache (not (eq cached missing)))
        cached
      (let ((roles (ebox-surface--role-ids-from-properties properties)))
        (when cache
          (puthash properties roles cache))
        roles))))

(defun ebox-surface--candidate-plan-text (rendered owned-values)
  "Return a private snapshot of RENDERED for an owned TP plan.
OWNED-VALUES is the candidate-local provenance registry created by Ebox's
render helpers.  TP transfers only mutable values present in this registry;
all other values remain defensively copied."
  (tp-text-snapshot
   rendered
   (and (hash-table-p owned-values)
        (lambda (property value)
          (and (ebox--render-owned-text-value-p
                property value owned-values)
               (not (memq property '(face font-lock-face mouse-face))))))))

(defun ebox-surface--region-role-tags (region-id role-ids)
  "Return projection tags for REGION-ID from ROLE-IDS."
  (list :ebox/region-id region-id
        :ebox/roles
        (cl-loop for (role . owner) in role-ids
                 when (equal owner region-id) collect role)))

(defun ebox-surface--fragment-owners
    (role-ids state node-objects region-objects)
  "Return ordered Ebox owner and tag pairs for ROLE-IDS.
Each owner appears at most once for one rendered fragment."
  (let ((attached (make-hash-table :test #'eq))
        (region-node-table (plist-get state :region-node-table))
        (parent-table (plist-get state :parent-table))
        owners)
    (dolist (region-id (delete-dups (mapcar #'cdr role-ids)))
      (let ((object (gethash region-id region-objects))
            (node-id (gethash region-id region-node-table)))
        (unless (and object node-id)
          (error "Ebox output references unknown region %S" region-id))
        (unless (gethash object attached)
          (push (list object
                      (ebox-surface--region-role-tags region-id role-ids))
                owners)
          (puthash object t attached))
        (setq node-id (gethash node-id parent-table))
        (while node-id
          (let ((ancestor (gethash node-id node-objects)))
            (unless ancestor
              (error "Ebox output ancestor has no TP object: %S" node-id))
            (unless (gethash ancestor attached)
              (push (list ancestor (list :ebox/descendant-output t)) owners)
              (puthash ancestor t attached)))
          (setq node-id (gethash node-id parent-table)))))
    (nreverse owners)))

(defun ebox-surface--rendered-fragments (rendered)
  "Return an offset index of Ebox-owned property runs in RENDERED.
The complete propertized string remains the sole text storage.  Runs keep
START and END offsets into that string instead of allocating one substring
per property interval; paint projection materializes its private copies only
when it needs to mutate them."
  (let ((position 0)
        (limit (length rendered))
        (line 0)
        (role-cache (make-hash-table :test #'equal))
        fragments previous-role-ids next-role-ids)
    (while (< position limit)
      (let ((next (or (next-property-change position rendered limit) limit)))
        (let ((roles (ebox-surface--role-ids-at rendered position role-cache)))
          (push (list :text rendered :text-source-p t
                      :start position :end next
                      :line line :paint-role-ids roles
                      :role-ids roles)
                fragments))
        (cl-incf line (cl-count ?\n rendered :start position :end next))
        (setq position (max next (1+ position)))))
    (setq fragments (nreverse fragments))
    (dolist (fragment fragments)
      (if-let ((roles (plist-get fragment :role-ids)))
          (setq previous-role-ids roles)
        (plist-put fragment :previous-role-ids previous-role-ids)))
    (dolist (fragment (reverse (copy-sequence fragments)))
      (if-let ((roles (plist-get fragment :role-ids)))
          (setq next-role-ids roles)
        (plist-put fragment :role-ids
                   (delete-dups
                    (append (copy-sequence
                             (plist-get fragment :previous-role-ids))
                            (copy-sequence next-role-ids))))))
    (cl-loop for fragment in fragments for index from 0
             do (plist-put fragment :key (cons 'ebox/fragment index))
             do (cl-remf fragment :previous-role-ids)
             collect fragment)))

(defun ebox-surface--fragment-metadata (fragments)
  "Return FRAGMENTS as offsets into the TP-owned rendered text.
The mutable propertized text is intentionally not retained in Ebox client
state; paint projection reads a defensive snapshot from the published
buffer only when it needs the old text."
  (let ((offset 0)
        metadata)
    (dolist (fragment fragments (nreverse metadata))
      (let* ((source-p (plist-get fragment :text-source-p))
             (text (plist-get fragment :text))
             (length (if source-p
                         (- (plist-get fragment :end)
                            (plist-get fragment :start))
                       (length text)))
             (copy
              (cl-loop for (key value) on fragment by #'cddr
                       unless (eq key :text)
                       append (list key value))))
        (unless source-p
          (plist-put copy :start offset)
          (plist-put copy :end (+ offset length)))
        (plist-put copy :text-source-p t)
        (push copy metadata)
        (setq offset (+ offset length))))))

(defun ebox-surface--owned-ranges
    (context leaf fragments state node-objects region-objects)
  "Attach merged owner ranges for FRAGMENTS to candidate LEAF.
Adjacent ranges merge only when both their owner and opaque tags match."
  (let ((active (make-hash-table :test #'eq))
        (owner-cache (make-hash-table :test #'equal))
        (offset 0)
        ranges)
    (dolist (fragment fragments)
      (let* ((role-ids (plist-get fragment :role-ids))
             (owners (gethash role-ids owner-cache 'ebox/no-owners))
             (source-p (plist-get fragment :text-source-p))
             (start (if source-p
                        (plist-get fragment :start)
                      offset))
             (end (if source-p
                      (plist-get fragment :end)
                    (+ offset (length (plist-get fragment :text))))))
        (when (eq owners 'ebox/no-owners)
          (setq owners
                (ebox-surface--fragment-owners
                 role-ids state node-objects region-objects))
          (puthash role-ids owners owner-cache))
        (dolist (owner owners)
          (let* ((object (nth 0 owner))
                 (tags (nth 1 owner))
                 (tag-ranges (or (gethash object active)
                                 (let ((table (make-hash-table :test #'equal)))
                                   (puthash object table active)
                                   table)))
                 (current (gethash tags tag-ranges)))
            (if (and current (= (plist-get current :end) start))
                (plist-put current :end end)
              (let ((range (list :object object :start start :end end
                                 :tags tags)))
                (push range ranges)
                (puthash tags range tag-ranges)))))
        (setq offset (if source-p end (+ offset (length (plist-get fragment :text)))))))
    (tp-object-attach-content-ranges-owned context leaf (nreverse ranges))
    ranges))

(defun ebox-surface--surface-plan
    (context surface-root output state node-objects region-objects)
  "Return one shared-text TP plan for OUTPUT and STATE.
NODE-OBJECTS and REGION-OBJECTS supply retained ownership ranges."
  (let* ((fragment-root
          (tp-object-ensure context surface-root
                            ebox-surface--fragments-key 'ebox/fragments))
         (fragment-data
          (if (stringp output)
              (ebox-surface--rendered-fragments output)
            output))
         (rendered
          (if (stringp output)
              output
            (if (and fragment-data
                     (plist-get (car fragment-data) :text-source-p))
                (plist-get (car fragment-data) :text)
              (apply #'concat
                     (mapcar (lambda (fragment)
                               (plist-get fragment :text))
                             fragment-data)))))
         (text-leaf
          (tp-object-ensure context fragment-root
                            ebox-surface--text-key 'ebox/text)))
    (ebox-surface--owned-ranges
     context text-leaf fragment-data state node-objects region-objects)
    (let* ((plan-text
            (ebox-surface--candidate-plan-text
             rendered (plist-get state :render-owned-text-values)))
           (plan
           (tp-surface-plan-create-owned
            :key ebox-surface--root-key :kind 'ebox/surface
            :children
            (list (tp-surface-plan-create-owned
                   :key ebox-surface--fragments-key :kind 'ebox/fragments
                   :children
                   (list (tp-surface-plan-create-owned
                          :key ebox-surface--text-key :kind 'ebox/text
                          :text plan-text
                          :capability 'content))
                   :capability 'content))
            :capability 'content)))
      (plist-put state :surface-fragments
                 (ebox-surface--fragment-metadata fragment-data))
      (let ((rendered-length (length rendered)))
        (list plan rendered
              (list (list :object text-leaf :start 0 :end rendered-length
                          :props nil :tags nil :leaf t)
                    (list :object fragment-root :start 0 :end rendered-length
                          :props nil :tags nil :leaf nil)
                    (list :object surface-root :start 0 :end rendered-length
                          :props nil :tags nil :leaf nil)))))))

(defconst ebox-surface--paint-base-roles
  '(content content-owner pt pb pl pr bl br)
  "Rendered roles that identify a box's painted border-box surface.")

(defun ebox-surface--node-depth (state node-id)
  "Return NODE-ID depth in Ebox runtime STATE."
  (let ((parents (plist-get state :parent-table)) (depth 0))
    (while (setq node-id (and node-id (gethash node-id parents)))
      (cl-incf depth))
    depth))

(defun ebox-surface--paint-node-chain (state role-ids)
  "Return the deepest rendered node and its ancestors for ROLE-IDS."
  (let ((region-nodes (plist-get state :region-node-table))
        (parents (plist-get state :parent-table)) deepest deepest-depth)
    (dolist (entry role-ids)
      (when-let ((node-id (gethash (cdr entry) region-nodes)))
        (let ((depth (ebox-surface--node-depth state node-id)))
          (when (or (null deepest-depth) (> depth deepest-depth))
            (setq deepest node-id deepest-depth depth)))))
    (let (chain)
      (while deepest
        (push deepest chain)
        (setq deepest (gethash deepest parents)))
      (nreverse chain))))

(defun ebox-surface--foreground-face (color)
  "Return the Ebox foreground face for COLOR."
  (if (eq color 'ebox/default-foreground)
      '(:inherit default)
    (list :foreground color)))

(defun ebox-surface--box-face-contributions (box)
  "Return BOX typography and color contributions in render order."
  (let (faces)
    (when-let ((font (ebox-buffer--font-face box)))
      (push font faces))
    (when-let ((color (plist-get box :color)))
      (push (ebox-surface--foreground-face color) faces))
    (when-let ((background (plist-get box :bgcolor)))
      (push (list :background background) faces))
    (nreverse faces)))

(defun ebox-surface--region-face-contributions (box roles ancestor-p)
  "Return BOX face contributions for ROLES.
ANCESTOR-P means BOX wraps a more specific rendered surface."
  (let (faces)
    (cond
     ((memq 'overflow-foreground roles)
      (when-let ((color (plist-get box :color)))
        (push (ebox-surface--foreground-face color) faces)))
     ((memq 'bl roles)
      (push (ebox-buffer-side-border-face
             (plist-get box :border-left-color)) faces))
     ((memq 'br roles)
      (push (ebox-buffer-side-border-face
             (plist-get box :border-right-color)) faces))
     ((or ancestor-p
          (cl-intersection roles '(content content-owner pt pb pl pr)))
      (setq faces (ebox-surface--box-face-contributions box))))
    (when (and (memq 'bt roles) (plist-get box :border-top-p))
      (setq faces
            (append faces
                    (list (list :overline
                                (or (plist-get box :border-top-color) t))))))
    (when (and (memq 'bb roles) (plist-get box :border-bottom-p))
      (setq faces
            (append
             faces
             (list
              (list :underline
                    (append '(:position t)
                            (when-let ((color
                                        (plist-get box :border-bottom-color)))
                              (list :color color))))))))
    faces))

(defun ebox-surface--face-contributions (state role-ids)
  "Return semantic Ebox face contributions for ROLE-IDS in STATE."
  (let ((nodes (plist-get state :node-table)) result first)
    (setq first t)
    (dolist (node-id (ebox-surface--paint-node-chain state role-ids))
      (when-let* ((node (gethash node-id nodes))
                  (box (ebox-fragment-style-source-node node)))
        (let ((region-id (plist-get box :region-id)))
          (setq result
                (append
                 result
                 (ebox-surface--region-face-contributions
                  box
                  (cl-loop for (role . owner) in role-ids
                           when (equal owner region-id) collect role)
                  (not first))))
          (setq first nil))))
    result))

(defun ebox-surface--face-list (face)
  "Return FACE as an ordered list of face entries."
  (cond ((null face) nil)
        ((and (listp face) (keywordp (car-safe face))) (list face))
        ((listp face) (copy-sequence face))
        (t (list face))))

(defun ebox-surface--face-value (entries)
  "Return canonical face value represented by ENTRIES."
  (pcase entries
    ('() nil)
    (`(,entry) entry)
    (_ entries)))

(defun ebox-surface--face-baseline (face contributions)
  "Remove trailing Ebox CONTRIBUTIONS from FACE and return its baseline."
  (let* ((entries (ebox-surface--face-list face))
         (count (length contributions))
         (prefix-count (- (length entries) count)))
    (if (and (>= prefix-count 0)
             (equal (nthcdr prefix-count entries) contributions))
        (ebox-surface--face-value (seq-take entries prefix-count))
      face)))

(defun ebox-surface--compose-face (baseline contributions)
  "Append Ebox CONTRIBUTIONS to BASELINE using Emacs face semantics."
  (let ((sample (make-string 1 ?x)))
    (when baseline
      (put-text-property 0 1 'face baseline sample))
    (dolist (face contributions)
      (add-face-text-property 0 1 face t sample))
    (get-text-property 0 'face sample)))

(defun ebox-surface--fragment-has-region-role-p
    (fragment region-id roles)
  "Return non-nil when FRAGMENT carries REGION-ID under any of ROLES."
  (cl-some (lambda (entry)
             (and (equal (cdr entry) region-id)
                  (memq (car entry) roles)))
           (plist-get fragment :paint-role-ids)))

(defun ebox-surface--horizontal-border-line (fragments region-id bottom-p)
  "Return REGION-ID top or BOTTOM-P anchor line from FRAGMENTS."
  (let (lines)
    (dolist (fragment fragments)
      (when (ebox-surface--fragment-has-region-role-p
             fragment region-id ebox-surface--paint-base-roles)
        (push (plist-get fragment :line) lines)))
    (when lines (apply (if bottom-p #'max #'min) lines))))

(defun ebox-surface--set-horizontal-border-role
    (fragments region-id role enabled)
  "Set REGION-ID horizontal border ROLE to ENABLED in FRAGMENTS."
  (let ((line (ebox-surface--horizontal-border-line
               fragments region-id (eq role 'bb)))
        (property (alist-get role ebox-region-types)))
    (dolist (fragment fragments)
      (let* ((anchor-p
              (and enabled (equal (plist-get fragment :line) line)
                   (ebox-surface--fragment-has-region-role-p
                    fragment region-id ebox-surface--paint-base-roles)))
             (pair (cons role region-id)))
        (dolist (key '(:paint-role-ids :role-ids))
          (let ((roles (cl-remove pair (plist-get fragment key) :test #'equal)))
            (plist-put fragment key (if anchor-p (append roles (list pair)) roles))))
        (when (> (length (plist-get fragment :text)) 0)
          (if-let ((owner
                    (cdr (cl-find role
                                  (plist-get fragment :paint-role-ids)
                                  :key #'car :test #'eq :from-end t))))
              (put-text-property 0 (length (plist-get fragment :text))
                                 property owner (plist-get fragment :text))
            (remove-text-properties
             0 (length (plist-get fragment :text))
             (list property nil) (plist-get fragment :text)))))))
  fragments)

(defun ebox-surface--paint-border-topology (fragments state dirty-set)
  "Return FRAGMENTS with horizontal border roles updated from STATE."
  (let ((nodes (plist-get state :node-table)))
    (dolist (dirty dirty-set fragments)
      (when-let* ((node (gethash (plist-get dirty :node-id) nodes))
                  (box (ebox-fragment-style-source-node node))
                  (region-id (plist-get box :region-id)))
        (dolist (entry '((:border-top-p . bt) (:border-bottom-p . bb)))
          (when (memq (car entry) (plist-get dirty :changed-keys))
            (ebox-surface--set-horizontal-border-role
             fragments region-id (cdr entry) (plist-get box (car entry)))))))))

(defun ebox-surface--repaint-fragment (fragment old-state new-state)
  "Return FRAGMENT with Ebox paint recomputed from OLD-STATE to NEW-STATE."
  (let* ((text (copy-sequence (plist-get fragment :text)))
         (old-roles (plist-get fragment :old-paint-role-ids))
         (new-roles (plist-get fragment :paint-role-ids))
         (old-faces (ebox-surface--face-contributions old-state old-roles))
         (new-faces (ebox-surface--face-contributions new-state new-roles))
         (baseline (and (> (length text) 0)
                        (ebox-surface--face-baseline
                         (get-text-property 0 'face text) old-faces)))
         (unchanged (and (equal old-roles new-roles)
                         (equal old-faces new-faces)))
         (face (and (not unchanged)
                    (ebox-surface--compose-face baseline new-faces))))
    (when (and (not unchanged) (> (length text) 0))
      (if face
          (put-text-property 0 (length text) 'face face text)
        (remove-text-properties 0 (length text) '(face nil) text)))
    (plist-put fragment :text text)
    (cl-remf fragment :old-paint-role-ids)
    fragment))

(defun ebox-surface--paint-fragments
    (old-state new-state dirty-set old-text)
  "Return OLD-STATE fragments repainted for NEW-STATE and DIRTY-SET.
OLD-TEXT is a defensive snapshot of the published TP content."
  (unless (stringp old-text)
    (error "Ebox paint projection has no published TP text"))
  (let ((fragments
         (mapcar
          (lambda (fragment)
            (let* ((copy (copy-tree fragment))
                   (text (substring old-text
                                    (plist-get fragment :start)
                                    (plist-get fragment :end))))
              (plist-put copy :text text)
              (plist-put copy :start 0)
              (plist-put copy :end (length text))
              (cl-remf copy :text-source-p)
              (plist-put copy :old-paint-role-ids
                         (copy-tree (plist-get fragment :paint-role-ids)))
              copy))
          (plist-get old-state :surface-fragments))))
    (unless fragments
      (error "Ebox paint projection has no published fragment topology"))
    (ebox-surface--paint-border-topology fragments new-state dirty-set)
    (mapcar (lambda (fragment)
              (ebox-surface--repaint-fragment fragment old-state new-state))
            fragments)))

(defun ebox-surface--refresh-paint-snapshots (state dirty-set)
  "Refresh paint-significant layout snapshots in STATE for DIRTY-SET."
  (let ((nodes (plist-get state :node-table))
        (snapshots (plist-get state :layout-snapshots)))
    (when (hash-table-p snapshots)
      (dolist (dirty dirty-set)
        (when-let* ((node-id (plist-get dirty :node-id))
                    (node (gethash node-id nodes))
                    (snapshot (gethash node-id snapshots)))
          (plist-put snapshot :style-signature
                     (ebox-fragment-node-style-signature node)))))
    state))

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

(defun ebox-surface--projection-state
    (root previous-state state-overrides projection-kind
           stylesheet-active-p cascade-required-p axes viewport-width
           viewport-height display-signature scroll-offsets)
  "Build candidate STATE with the mounted context values installed."
  (let ((state
         (ebox-surface--apply-state-overrides
          (if (eq projection-kind 'paint)
              (copy-sequence previous-state)
            (ebox--new-buffer-render-state root))
          (copy-sequence state-overrides))))
    (plist-put state :root-node root)
    (plist-put state :cascade-active-p stylesheet-active-p)
    (plist-put state :cascade-required-p cascade-required-p)
    (when axes
      (plist-put state :viewport-width viewport-width)
      (plist-put state :viewport-height viewport-height)
      (plist-put state :display-signature display-signature)
      (plist-put state :viewport-dependent-node-id-axes axes)
      (plist-put state :viewport-dependent-node-ids
                 (delete-dups (copy-sequence
                               (append (car axes) (cdr axes)))))
      (plist-put state :viewport-dependent-node-ids-ready t)
      (ebox-surface--apply-scroll-offsets root scroll-offsets))
    state))

(defun ebox-surface--project
    (context source previous-state preserve-identities-p state-overrides
             signals projection-kind source-isolated-p source-path-copied-p)
  "Project SOURCE in CONTEXT using PREVIOUS-STATE and identity policy.
PRESERVE-IDENTITIES-P retains existing Ebox node and region identities.
SIGNALS, when non-nil, supplies the mounted surface's host context.
PROJECTION-KIND may select a proven non-spatial projection.
SOURCE-ISOLATED-P means SOURCE is a private candidate owned by the current
publication attempt; it is safe to clear its transient attachments in place.
SOURCE-PATH-COPIED-P means SOURCE shares untouched Ebox nodes with the
published runtime and must be consumed without clearing those shared nodes."
  (if (stringp source)
      (let ((object
             (tp-object-ensure context nil ebox-surface--root-key
                               'ebox/string)))
        (ignore object)
        (tp-surface-result-create
         (tp-surface-plan-create
          :key ebox-surface--root-key :kind 'ebox/string
          :text source :capability 'content)))
      (let* ((stylesheet-active-p (ebox-style-cascade-active-p))
             (root (cond
                    (source-path-copied-p source)
                    (source-isolated-p
                     (ebox-surface--clear-runtime-attachments source))
                    (t
                     (ebox-surface--candidate-root
                      source preserve-identities-p))))
             (state-overrides
              (if (and (memq projection-kind
                              '(viewport-reflow viewport-reflow-mixed-scroll))
                       (not source-isolated-p)
                       (not source-path-copied-p))
                  (ebox-surface--isolated-viewport-overrides state-overrides)
                state-overrides))
             (inline-inheritance-required-p
              (ebox-surface--inline-inheritance-required-p root))
             (cascade-required-p
              (or stylesheet-active-p inline-inheritance-required-p))
             (style-required-p
              (or cascade-required-p
                  (plist-get previous-state :cascade-active-p)
                  (plist-get previous-state :cascade-required-p)))
             (projection
             (ebox-surface--projection-start
               context root style-required-p projection-kind previous-state)))
      (unless (or source-isolated-p source-path-copied-p)
        (ebox-surface--reconcile-candidate root previous-state))
      (let* ((axes (and signals (ebox-surface--context-axes root)))
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
              (ebox-surface--projection-state
               root previous-state state-overrides projection-kind
               stylesheet-active-p cascade-required-p axes viewport-width
               viewport-height display-signature scroll-offsets)))
        (when (eq projection-kind 'span-patch)
          (ebox-surface--attach-retained-node-objects state))
        (if (eq projection-kind 'paint)
            (let* ((dirty-set (plist-get state-overrides :paint-dirty-set))
                   (buffer (and signals
                                (ebox-surface--signals-buffer signals)))
                   (old-text
                   (and (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (save-restriction
                             (widen)
                             (buffer-substring (point-min) (point-max)))))))
              (setq state (ebox-surface--finish-runtime-state state))
              (ebox-surface--refresh-paint-snapshots state dirty-set)
              (cl-remf state :paint-dirty-set)
              (ebox-surface--projection-result
               context projection state
               (ebox-surface--paint-fragments
                previous-state state dirty-set old-text)))
          (plist-put state :region-box-table (make-hash-table :test 'equal))
          (let ((rendered
                 (if (eq projection-kind 'span-patch)
                     (if-let ((span-output
                               (ebox-surface--span-patch-output
                                (ebox-surface--signals-buffer signals) state)))
                         span-output
                       (setq projection
                             (ebox-surface--complete-projection
                              context root style-required-p projection))
                       (setq state
                             (ebox-surface--projection-state
                              root previous-state state-overrides nil
                              stylesheet-active-p cascade-required-p axes
                              viewport-width viewport-height display-signature
                              scroll-offsets))
                       (plist-put state :region-box-table
                                  (make-hash-table :test 'equal))
                       (ebox-surface--render-candidate state))
                   (ebox-surface--render-candidate state))))
            (when (and signals
                       (hash-table-p (plist-get state :scroll-state-table))
                       (> (hash-table-count
                           (plist-get state :scroll-state-table))
                          0))
              (tp-signal-read (ebox-surface--signals-scroll signals)))
            (setq state (ebox-surface--finish-runtime-state state))
            (when (memq projection-kind
                        '(viewport-reflow viewport-reflow-mixed-scroll))
              ;; The reflow source is copied at this boundary.  Attach the
              ;; retained objects only after its candidate indexes exist;
              ;; attaching before that point would mutate the published
              ;; node table through the old state's indexes.
              (ebox-surface--attach-retained-node-objects state))
            (ebox-surface--projection-result
             context projection state rendered)))))))

(defun ebox-surface-producer
    (source &optional previous-state preserve-identities-p state-overrides
            signals projection-kind source-isolated-p source-path-copied-p)
  "Return a TP producer for Ebox SOURCE and optional PREVIOUS-STATE.
PRESERVE-IDENTITIES-P retains existing Ebox node and region identities.
STATE-OVERRIDES augments the candidate Ebox runtime state.  SIGNALS carries
the mounted surface context; one-shot string materialization omits it.
PROJECTION-KIND may select a proven non-spatial projection.
SOURCE-ISOLATED-P means SOURCE is already an internally isolated runtime
candidate and must not be copied or reconciled again.  SOURCE-PATH-COPIED-P
means SOURCE shares untouched Ebox nodes with the published runtime and must
also bypass candidate copying and reconciliation without clearing those nodes."
  (lambda (context)
    (let ((buffer (and signals (ebox-surface--signals-buffer signals))))
      (if (buffer-live-p buffer)
          (with-current-buffer buffer
            (ebox-surface--project
             context source previous-state preserve-identities-p state-overrides
             signals projection-kind source-isolated-p source-path-copied-p))
        (ebox-surface--project
         context source previous-state preserve-identities-p state-overrides
         signals projection-kind source-isolated-p source-path-copied-p)))))

(provide 'ebox-surface)

;;; ebox-surface.el ends here
