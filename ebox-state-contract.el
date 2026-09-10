;;; ebox-state-contract.el --- Ebox retained-state ownership contract -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Records the M2a target ownership classification for retained Ebox state and
;; the distinct current v1 storage shape.  It also offers read-only
;; compatibility-mirror rebuild probes.  This module does not publish a
;; generation, mutate live runtime state, or select a transaction route.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(define-error 'ebox-state-contract-error
  "Invalid Ebox retained-state contract")

(defconst ebox-state-contract-categories
  '(generation-fact generation-bound-mutable-authority
    tp-storage-custody compatibility-mirror disposable-cache)
  "Closed set of retained-state categories used by the M2a inventory.")

(defconst ebox-state-contract-required-fields
  '(:id :storage :current-contract :target-contract :category :owner
    :mutation-api :generation-binding :rollback :rebuild-proof :cleanup)
  "Fields required on every M2a retained-state inventory record.")

(defconst ebox-state-contract--inventory
  '((:id runtime-generation-indexes
     :storage (:source-index ebox-source-index/records
               ebox-source-index/handle-records
               ebox-source-index/host-ref-table
               :root-node :node-table :parent-table
               :runtime-type-count-table :range-ref-table
               :selector-id-table :selector-class-table :selector-type-table
               ebox--region-line-index ebox--render-source-index
               ebox-incremental--candidate-full-source-base-index
               ebox-incremental--previous-source-base-index
               ebox-incremental--source-base-index)
     :current-contract mixed-candidate-and-committed-state
     :target-contract immutable-generation-value
     :category generation-fact
     :owner ebox
     :mutation-api candidate-construction-only
     :generation-binding immutable-generation-token
     :rollback discard-candidate
     :rebuild-proof source-and-runtime-index-rebuild
     :cleanup generation-replacement)
    (:id region-generation-indexes
     :storage (:region-id-set :region-node-table :region-box-count-table
               :region-box-table :layout-snapshots
               :fractional-pixel-output-p
               :render-owned-text-values ebox--render-owned-text-values)
     :current-contract candidate-state-plus-global-projection
     :target-contract immutable-generation-value
     :category generation-fact
     :owner ebox
     :mutation-api candidate-layout-materialization-only
     :generation-binding immutable-generation-token
     :rollback discard-candidate
     :rebuild-proof layout-and-region-index-rebuild
     :cleanup generation-replacement)
    (:id scroll-membership
     :storage (:scroll-region-ids)
     :current-contract committed-state-membership-list
     :target-contract immutable-generation-value
     :category generation-fact
     :owner ebox
     :mutation-api candidate-layout-materialization-only
     :generation-binding immutable-generation-token
     :rollback discard-candidate
     :rebuild-proof layout-scroll-membership-rebuild
     :cleanup generation-replacement)
    (:id scroll-runtime-authority
     :storage (:scroll-state-table :scroll-offset :scroll-window
               ebox--scroll-global-state
               ebox--smooth-scroll-state-table
               ebox--scroll-idle-prefetch-timers
               ebox--scroll-idle-prefetch-inhibited-buffers)
     :current-contract global-and-state-table-mutable-handles
     :target-contract stable-id-plus-generation-token-authority
     :category generation-bound-mutable-authority
     :owner ebox-scroll
     :mutation-api stable-scroll-id-and-generation-token
     :generation-binding required
     :rollback participant-journal-restores-prior-authority
     :rebuild-proof not-rebuildable-from-cache
     :cleanup cancel-timers-and-retire-generation)
    (:id native-runtime-authority
     :storage (:native-sync-session :native-sync-pending :native-session
               ebox-native-reflow-preparation ebox-native-reflow-session
               ebox-native-reflow-preparation/ready-timer)
     :current-contract candidate-preparation-and-confirmed-session-handles
     :target-contract generation-token-authority
     :category generation-bound-mutable-authority
     :owner ebox-native
     :mutation-api native-candidate-confirm-or-abort
     :generation-binding required
     :rollback abort-candidate-and-keep-confirmed-session
     :rebuild-proof not-rebuildable-from-cache
     :cleanup release-losing-session)
    (:id runtime-prewarm-authority
     :storage (ebox--deferred-render-gc-state
               ebox--deferred-render-gc-timer
               ebox--deferred-render-gc-depth
               ebox--deferred-render-gc-generation
               ebox--reflow-cache-prewarm-timers
               ebox--runtime-prewarm-jobs ebox--runtime-prewarm-timers
               ebox--render-burst-records ebox--render-burst-stack)
     :current-contract buffer-keyed-jobs-and-cleanup-sensitive-timers
     :target-contract generation-revision-guarded-scheduler-authority
     :category generation-bound-mutable-authority
     :owner ebox-runtime-scheduler
     :mutation-api schedule-cancel-and-revision-validate
     :generation-binding buffer-and-runtime-revision
     :rollback cancel-candidate-work
     :rebuild-proof reschedule-from-committed-generation
     :cleanup cancel-timers-jobs-and-gc-lease)
    (:id viewport-event-authority
     :storage (ebox--window-size-change-pending-frames
               ebox--window-size-change-timer)
     :current-contract frame-intent-queue-and-single-event-loop-task
     :target-contract frame-intent-queue-and-single-event-loop-task
     :category generation-bound-mutable-authority
     :owner ebox-viewport
     :mutation-api window-notify-schedule-and-drain
     :generation-binding current-mounted-generation-sampled-at-delivery
     :rollback publication-owned-rollback-and-requeue-unstarted-frames
     :rebuild-proof subsequent-window-notification
     :cleanup consume-frame-intents-and-release-dispatched-timer)
    (:id incremental-batch-authority
     :storage (ebox-incremental--batch-table)
     :current-contract process-buffer-keyed-open-batch-state
     :target-contract generation-token-bound-batch-authority
     :category generation-bound-mutable-authority
     :owner ebox-incremental
     :mutation-api batch-begin-record-flush-or-abort
     :generation-binding captured-base-generation
     :rollback discard-pending-batch
     :rebuild-proof batch-begin-from-committed-generation
     :cleanup batch-end-or-buffer-kill)
    (:id layout-context-port-authority
     :storage (ebox--layout-context-port)
     :current-contract process-global-port-with-dynamic-test-rebinding
     :target-contract immutable-package-bootstrap-port
     :category generation-bound-mutable-authority
     :owner ebox-render-context
     :mutation-api facade-install-and-dynamic-bind
     :generation-binding one-port-captured-per-render-call
     :rollback dynamic-binding-unwind
     :rebuild-proof reinstall-default-surface-port
     :cleanup package-reload-or-binding-unwind)
    (:id identity-allocation-authority
     :storage (ebox--region-id-counter ebox--runtime-node-id-counter)
     :current-contract process-monotonic-identity-counters
     :target-contract allocator-output-copied-into-generation
     :category generation-bound-mutable-authority
     :owner ebox-identity
     :mutation-api next-region-or-runtime-node-id
     :generation-binding allocated-identity-enters-one-candidate
     :rollback allocator-gaps-are-non-authoritative
     :rebuild-proof monotonic-next-allocation
     :cleanup process-lifetime-test-reset-only)
    (:id buffer-surface-runtime-authority
     :storage (ebox-surface--buffer-surface
               ebox-surface--buffer-observer
               ebox-surface--tp-observer
               ebox-surface--observation-contexts
               ebox-surface--context-signals)
     :current-contract buffer-local-mounted-surface-and-observation-handles
     :target-contract generation-revision-bound-surface-authority
     :category generation-bound-mutable-authority
     :owner ebox-surface
     :mutation-api mount-observe-publish-and-unmount
     :generation-binding buffer-surface-and-publication-revision
     :rollback restore-prior-surface-signals-and-observer-bridge
     :rebuild-proof not-rebuildable-from-cache
     :cleanup remove-observers-cancel-contexts-and-unmount)
    (:id tp-client-state-custody
     :storage (tp-surface-client-state)
     :current-contract entire-ebox-state-plist
     :target-contract opaque-generation-correlation-only
     :category tp-storage-custody
     :owner tp
     :mutation-api opaque-ebox-generation-correlation-only
     :generation-binding opaque-correlation
     :rollback tp-restores-client-state
     :rebuild-proof ebox-generation-remains-source-of-truth
     :cleanup tp-surface-unmount)
    (:id buffer-render-state-mirror
     :storage (ebox--buffer-render-state-table)
     :current-contract same-object-alias-of-tp-client-state
     :target-contract one-way-generation-projection
     :category compatibility-mirror
     :owner ebox-compatibility
     :mutation-api project-from-committed-generation
     :generation-binding committed-generation-token
     :rollback participant-restores-prior-projection
     :rebuild-proof project-buffer-mirror-from-committed-states
     :cleanup remove-buffer-entry)
    (:id region-box-lookup-mirror
     :storage (ebox--region-box-table)
     :current-contract participant-maintained-global-projection
     :target-contract rebuildable-generation-projection
     :category compatibility-mirror
     :owner ebox-compatibility
     :mutation-api project-from-committed-generation
     :generation-binding committed-generation-token
     :rollback participant-restores-prior-projection
     :rebuild-proof project-region-mirror-from-generation-indexes
     :cleanup remove-retired-generation-entries)
    (:id font-cache
     :storage (ebox-font--cache)
     :current-contract process-display-capability-cache
     :target-contract discardable-derived-values
     :category disposable-cache
     :owner ebox-font
     :mutation-api cache-fill-and-evict
     :generation-binding display-capability-signature
     :rollback discard
     :rebuild-proof resolve-font-fact-again
     :cleanup ebox-font-clear-cache)
    (:id native-hover-face-cache
     :storage (ebox-interaction--hover-face-cache)
     :current-contract weakly-shared-native-hover-faces
     :target-contract discardable-derived-values
     :category disposable-cache
     :owner ebox-interaction
     :mutation-api weak-cache-fill
     :generation-binding hover-owner-and-computed-paint
     :rollback discard-unreferenced-candidates
     :rebuild-proof reproject-owner-native-hover-face
     :cleanup garbage-collect-unreferenced-faces)
    (:id scroll-viewport-owner-cache
     :storage (:scroll-viewport-owner-cache)
     :current-contract candidate-private-resolved-owner-table
     :target-contract discardable-derived-values
     :category disposable-cache
     :owner ebox-surface
     :mutation-api copy-before-candidate-fill
     :generation-binding unchanged-parent-region-and-tp-object-indexes
     :rollback discard-candidate-cache
     :rebuild-proof resolve-rich-line-roles-against-retained-topology
     :cleanup ordinary-projection-or-generation-replacement)
    (:id derived-caches
     :storage (ebox--box-content-render-cache ebox--char-width-cache
               ebox--display-signature-cache ebox--face-height-width-cache
               ebox--physical-memory-bytes
               ebox--flex-content-min-width-table
               ebox--flex-sized-render-observation-table
               ebox--flex-slot-safety-cache ebox--layout-fragments-table
               ebox--node-region-ids-cache ebox--patchable-owner-cache
               ebox--render-cache-entry-side-effects-table
               ebox--render-cache-ring-table
               ebox--render-cache-scroll-state-region-ids
               ebox--render-cache-scroll-state-retained-cost-cache
               ebox--render-cache-signature-cache ebox--render-cache-table
               ebox--render-output-provenance-table
               ebox--render-recached-source-node-cache
               ebox--render-root-cache-table-table
               ebox--render-string-max-pixel-width-cache
               ebox--render-string-pixel-width-cache
               ebox--rendered-uniform-width-table ebox--rendered-intrinsic-size-table
               ebox--runtime-ancestor-cache
               ebox--scroll-window-cached-state :rendered-content-line-cells
               ebox--space-pixel-cache
               ebox--string-pixel-width-cache
               ebox--string-pixel-width-cache-ring
               ebox--viewport-dependent-node-ids-cache
               ebox--viewport-dependent-subtree-cache
               ebox--viewport-height-dependent-subtree-cache
               ebox--css-viewport-dependent-subtree-cache
               ebox--window-line-prewarmer-table
               ebox--window-line-renderer-table
               ebox-cache--buffer-report-table ebox-cache--registry
               ebox-canonical--declaration-fact-cache
               ebox-incremental--allocated-slot-proof-cache
               ebox-incremental--candidate-path-copy-origin-table
               ebox-incremental--candidate-proof-node-table
               ebox-native-reflow--source-cluster-cache
               ebox-style--box-engine-longhand-cache
               ebox-style--closed-computed-cache
               ebox-style--closed-inheritance-cache
               ebox-style--computed-snapshot-cache
               ebox-style--declaration-cache ebox-style--property-index
               ebox-style--text-engine-longhand-cache
               ebox-surface--inline-style-value-cache
               ebox-surface--paint-node-chain-cache
               ebox-surface--paint-node-depth-cache
               ebox-surface--scroll-line-fragment-cache)
     :current-contract process-or-render-local-derived-values
     :target-contract discardable-derived-values
     :category disposable-cache
     :owner ebox-cache
     :mutation-api cache-fill-and-evict
     :generation-binding cache-key-or-display-signature
     :rollback discard
     :rebuild-proof recompute-with-identical-semantic-result
     :cleanup bounded-eviction-or-clear))
  "M2a retained-state inventory.

The records classify every state family named by the architecture plan.  They
do not claim that later M2a target storage is already active.  The inventory is
fail-closed: adding a retained-state family requires adding a complete record
rather than relying on an implicit default.")

(defconst ebox-state-contract-source-scan-exclusions
  '((:symbol ebox--defer-scroll-content-index
     :reason dynamic-boolean-or-index-mode
     :evidence value-is-never-a-container)
    (:symbol ebox--box-content-empty-width
     :reason dynamic-scalar-result
     :evidence numeric-inline-extent-returned-with-one-content-materialization)
    (:symbol ebox-layer--portals
     :reason dynamically-bound-render-collection
     :evidence let-bound-per-spatial-root-and-discarded-with-the-candidate-render)
    (:symbol ebox-layer--piece-width-cache
     :reason dynamically-bound-composition-index
     :evidence let-bound-per-layer-host-and-never-retained-between-renders)
    (:symbol ebox--string-pixel-width-cache-ring-index
     :reason numeric-eviction-cursor
     :evidence value-is-an-integer-ring-position)
    (:symbol ebox-native-reflow--compile-property-template-ids
     :reason dynamically-bound-compile-local-scratch
     :evidence let-bound-per-compile-and-never-committed)
    (:symbol ebox-native-reflow--compile-property-template-index
     :reason dynamically-bound-compile-local-scratch
     :evidence let-bound-per-compile-and-published-only-through-session-root)
    (:symbol ebox-native-reflow--compile-style-index
     :reason dynamically-bound-compile-local-scratch
     :evidence let-bound-per-compile-and-published-only-through-session-root)
    (:symbol ebox-native-reflow--compile-size-node
     :reason dynamically-bound-compile-local-scratch
     :evidence owning-node-font-context-for-one-native-size-projection)
    (:symbol ebox--render-source-generations
     :reason dynamically-bound-render-proof-input
     :evidence let-bound-to-candidate-and-prior-generations-for-one-plan)
    (:symbol ebox--render-source-states
     :reason dynamically-bound-render-proof-input
     :evidence let-bound-to-candidate-and-prior-states-for-one-plan)
    (:symbol ebox-tree--incoming-source-indexes
     :reason dynamically-bound-tree-build-input
     :evidence let-bound-for-one-persistent-tree-construction)
    (:symbol ebox--rebuilt-scroll-state-region-ids
     :reason dynamically-bound-render-observation
     :evidence collects-rebuilt-scroll-ids-for-one-transaction)
    (:symbol ebox-incremental--buffer-render-state-override
     :reason dynamically-bound-candidate-view
     :evidence let-bound-to-one-buffer-and-candidate-state)
    (:symbol ebox-incremental--candidate-base-state
     :reason dynamically-bound-candidate-view
     :evidence let-bound-to-one-buffer-and-published-base-state)
    (:symbol ebox-incremental--candidate-incoming-source-indexes
     :reason dynamically-bound-candidate-input
     :evidence let-bound-for-one-logical-candidate-preparation)
    (:symbol ebox--prepared-root-render
     :reason transaction-local-render-scratch
     :evidence dynamically-bound-around-one-prepared-render)
    (:symbol ebox--scroll-window-prewarm-state
     :reason render-local-prewarm-scratch
     :evidence dynamically-bound-for-one-yielding-prefix-pass)
    (:symbol ebox--scroll-window-render-result
     :reason render-local-result-scratch
     :evidence dynamically-bound-for-one-window-render)
    (:symbol ebox-incremental--candidate-path-copy-trace
     :reason candidate-local-proof-scratch
     :evidence dynamically-bound-during-one-candidate-build)
    (:symbol ebox-incremental--candidate-range-index-deltas
     :reason candidate-local-index-scratch
     :evidence dynamically-bound-during-one-candidate-build)
    (:symbol ebox-native-reflow--compile-property-templates
     :reason dynamically-bound-compile-local-scratch
     :evidence let-bound-per-native-compile)
    (:symbol ebox-native-reflow--compile-styles
     :reason dynamically-bound-compile-local-scratch
     :evidence let-bound-per-native-compile)
    (:symbol ebox--flex-native-size-lines-backend
     :reason optional-backend-capability-not-retained-generation-state
     :evidence function-capability-selected-outside-publication)
    (:symbol ebox-native-reflow--available-p
     :reason process-native-loader-capability
     :evidence adapter-availability-not-render-generation-state)
    (:symbol ebox-native-reflow--load-attempted-p
     :reason process-native-loader-control
     :evidence one-time-loader-guard-not-domain-state)
    (:symbol ebox-native-reflow--load-error
     :reason process-native-loader-diagnostic
     :evidence diagnostic-only-not-publication-authority)
    (:symbol ebox-native-reflow--loaded-module-hash
     :reason process-native-loader-diagnostic
     :evidence loaded-binary-identity-outside-render-generation)
    (:symbol ebox-native-reflow--loaded-module-path
     :reason process-native-loader-diagnostic
     :evidence loaded-binary-location-outside-render-generation)
    (:symbol ebox-native-reflow--build-process
     :reason developer-native-build-handle
     :evidence optional-build-command-outside-render-runtime)
    (:symbol ebox-native-reflow--last-build-report
     :reason developer-native-build-diagnostic
     :evidence optional-build-report-outside-render-runtime)
    (:symbol ebox-native-status--diagnosis
     :reason buffer-local-native-status-diagnostic
     :evidence status-buffer-presentation-only)
    (:symbol ebox-surface--observation-context
     :reason dynamically-bound-publication-observation
     :evidence let-bound-for-one-public-ebox-call)
    (:symbol ebox-fragment-flex-retention-hit-count
     :reason diagnostic-counter
     :evidence test-and-observation-metric-only)
    (:symbol ebox-fragment-flex-retention-rerender-count
     :reason diagnostic-counter
     :evidence test-and-observation-metric-only)
    (:symbol ebox-fragment-flex-retention-store-count
     :reason diagnostic-counter
     :evidence test-and-observation-metric-only)
    (:symbol ebox-native-reflow--flex-geometry-call-count
     :reason diagnostic-counter
     :evidence performance-observation-only)
    (:symbol ebox-scroll-map
     :reason static-ui-keymap
     :evidence command-binding-table-not-render-state))
  "Source-state symbols proven not to hold retained runtime authority.")

(defun ebox-state-contract-storage-symbols ()
  "Return all symbol-valued storage identities in the retained inventory."
  (delete-dups
   (cl-mapcan
    (lambda (record)
      (cl-remove-if-not #'symbolp
                        (copy-sequence (plist-get record :storage))))
    ebox-state-contract--inventory)))

(defun ebox-state-contract-inventory ()
  "Return a detached copy of the retained-state inventory."
  (copy-tree ebox-state-contract--inventory))

(defun ebox-state-contract-record (id)
  "Return a detached inventory record identified by ID, or nil."
  (when-let* ((record
               (cl-find id ebox-state-contract--inventory
                        :key (lambda (item) (plist-get item :id)))))
    (copy-tree record)))

(defun ebox-state-contract-validate ()
  "Validate and return a detached retained-state inventory.
Signal `ebox-state-contract-error' when a record is incomplete, duplicated, or
uses a category outside `ebox-state-contract-categories'."
  (let ((seen-ids (make-hash-table :test #'eq))
        (seen-storage (make-hash-table :test #'eq)))
    (dolist (record ebox-state-contract--inventory)
      (dolist (field ebox-state-contract-required-fields)
        (unless (plist-get record field)
          (signal 'ebox-state-contract-error
                  (list :missing-field field :record record))))
      (let ((id (plist-get record :id))
            (category (plist-get record :category)))
        (when (gethash id seen-ids)
          (signal 'ebox-state-contract-error
                  (list :duplicate-id id)))
        (puthash id t seen-ids)
        (unless (memq category ebox-state-contract-categories)
          (signal 'ebox-state-contract-error
                  (list :unknown-category category :id id)))
        (dolist (storage (plist-get record :storage))
          (when (and (symbolp storage) (not (keywordp storage)))
            (when-let* ((prior-id (gethash storage seen-storage)))
              (signal 'ebox-state-contract-error
                      (list :duplicate-storage storage
                            :first-record prior-id
                            :second-record id)))
            (puthash storage id seen-storage)))))
    (ebox-state-contract-inventory)))

(defun ebox-state-contract--project-buffer-mirror (entries)
  "Project BUFFER . STATE ENTRIES into a fresh compatibility mirror."
  (let ((table (make-hash-table :test #'eq))
        (missing (make-symbol "missing")))
    (dolist (entry entries)
      (unless (and (consp entry) (bufferp (car entry)) (listp (cdr entry)))
        (signal 'ebox-state-contract-error
                (list :malformed-committed-state-entry entry)))
      (unless (eq (gethash (car entry) table missing) missing)
        (signal 'ebox-state-contract-error
                (list :duplicate-buffer (car entry))))
      (puthash (car entry) (cdr entry) table))
    table))

(defun ebox-state-contract--project-region-mirror (entries)
  "Project BUFFER . STATE ENTRIES into a fresh region compatibility mirror."
  (let ((table (make-hash-table :test #'equal))
        (missing (make-symbol "missing")))
    (dolist (entry entries)
      (when-let* ((regions (plist-get (cdr entry) :region-box-table)))
        (unless (hash-table-p regions)
          (signal 'ebox-state-contract-error
                  (list :malformed-region-index (car entry))))
        (maphash
         (lambda (region-id box)
           (let ((existing (gethash region-id table missing)))
             (when (and (not (eq existing missing)) (not (eq existing box)))
               (signal 'ebox-state-contract-error
                       (list :duplicate-region-id region-id)))
             (puthash region-id box table)))
         regions)))
    table))

(defun ebox-state-contract-rebuild-compatibility-mirrors (entries)
  "Return fresh buffer and region mirrors projected from committed ENTRIES.

ENTRIES is a list of `(BUFFER . STATE)' pairs.  STATE is the current v1 Ebox
state plist held by TP client-state custody; a later checkpoint may narrow that
custody to opaque generation correlation.  The returned plist contains
`:buffer-table' and `:region-table'; neither table mutates live Ebox state."
  (list :buffer-table
        (ebox-state-contract--project-buffer-mirror entries)
        :region-table
        (ebox-state-contract--project-region-mirror entries)))

(defun ebox-state-contract--hash-diff-report (expected actual)
  "Return deterministic differences and work count for two hash tables."
  (unless (and (hash-table-p expected) (hash-table-p actual))
    (signal 'wrong-type-argument (list 'hash-table-p expected actual)))
  (let ((missing (make-symbol "missing")) differences keys)
    (maphash (lambda (key _value) (push key keys)) expected)
    (maphash (lambda (key _value) (push key keys)) actual)
    (dolist (key (delete-dups keys))
      (let ((left (gethash key expected missing))
            (right (gethash key actual missing)))
        (unless (or (eq left right)
                    (and (not (eq left missing))
                         (not (eq right missing))
                         (equal left right)))
          (push key differences))))
    (list
     :differences
     (sort differences
           (lambda (left right)
             (string< (prin1-to-string left) (prin1-to-string right))))
     :comparisons (length (delete-dups keys)))))

(defun ebox-state-contract-probe-compatibility-mirrors
    (entries buffer-mirror region-mirror)
  "Compare live mirrors with fresh projections from committed ENTRIES.

BUFFER-MIRROR and REGION-MIRROR are observed compatibility tables.  The return
value is a read-only report with deterministic mismatch lists and a boolean
`:consistent-p'."
  (let* ((rebuilt
          (ebox-state-contract-rebuild-compatibility-mirrors entries))
         (buffer-report
          (ebox-state-contract--hash-diff-report
           (plist-get rebuilt :buffer-table) buffer-mirror))
         (region-report
          (ebox-state-contract--hash-diff-report
           (plist-get rebuilt :region-table) region-mirror))
         (buffer-differences (plist-get buffer-report :differences))
         (region-differences (plist-get region-report :differences)))
    (list :consistent-p (and (null buffer-differences)
                             (null region-differences))
          :buffer-differences buffer-differences
          :region-differences region-differences
          :entry-count (length entries)
          :projected-region-count
          (hash-table-count (plist-get rebuilt :region-table))
          :buffer-comparisons (plist-get buffer-report :comparisons)
          :region-comparisons (plist-get region-report :comparisons))))

(provide 'ebox-state-contract)

;;; ebox-state-contract.el ends here
