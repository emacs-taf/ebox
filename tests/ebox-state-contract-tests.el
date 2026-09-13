;;; ebox-state-contract-tests.el --- M2a state ownership contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)
(require 'ebox-state-contract)
(require 'ebox-fixtures)

(defconst ebox-state-contract-test--plan-expectations
  '((runtime-generation-indexes
     (:source-index ebox-source-index/records
      ebox-source-index/handle-records ebox-source-index/host-ref-table
      :root-node :node-table :parent-table :runtime-type-count-table
      :range-ref-table :selector-id-table :selector-class-table
      :selector-type-table ebox--region-line-index ebox--render-source-index)
     generation-fact ebox candidate-construction-only
     immutable-generation-token
     discard-candidate source-and-runtime-index-rebuild
     generation-replacement)
    (region-generation-indexes
     (:region-id-set :region-node-table :region-box-count-table
      :region-box-table :layout-snapshots)
     generation-fact ebox candidate-layout-materialization-only
     immutable-generation-token
     discard-candidate layout-and-region-index-rebuild
     generation-replacement)
    (scroll-membership (:scroll-region-ids)
     generation-fact ebox candidate-layout-materialization-only
     immutable-generation-token
     discard-candidate layout-scroll-membership-rebuild
     generation-replacement)
    (scroll-runtime-authority
     (:scroll-state-table :scroll-offset :scroll-window
      ebox--scroll-global-state ebox--smooth-scroll-state-table
      ebox--scroll-idle-prefetch-timers
      ebox--scroll-idle-prefetch-inhibited-buffers)
     generation-bound-mutable-authority ebox-scroll
     stable-scroll-id-and-generation-token required
     participant-journal-restores-prior-authority
     not-rebuildable-from-cache cancel-timers-and-retire-generation)
    (native-runtime-authority
     (:native-sync-session :native-sync-pending :native-session
      ebox-native-reflow-preparation ebox-native-reflow-session
      ebox-native-reflow-preparation/ready-timer)
     generation-bound-mutable-authority ebox-native
     native-candidate-confirm-or-abort required
     abort-candidate-and-keep-confirmed-session
     not-rebuildable-from-cache release-losing-session)
    (runtime-prewarm-authority
     (ebox--deferred-render-gc-state ebox--deferred-render-gc-timer
      ebox--deferred-render-gc-depth ebox--deferred-render-gc-generation
      ebox--render-burst-records ebox--render-burst-stack
      ebox--reflow-cache-prewarm-timers
      ebox--runtime-prewarm-jobs ebox--runtime-prewarm-timers)
     generation-bound-mutable-authority ebox-runtime-scheduler
     schedule-cancel-and-revision-validate buffer-and-runtime-revision
     cancel-candidate-work reschedule-from-committed-generation
     cancel-timers-jobs-and-gc-lease)
    (incremental-batch-authority (ebox-incremental--batch-table)
     generation-bound-mutable-authority ebox-incremental
     batch-begin-record-flush-or-abort captured-base-generation
     discard-pending-batch batch-begin-from-committed-generation
     batch-end-or-buffer-kill)
    (layout-context-port-authority (ebox--layout-context-port)
     generation-bound-mutable-authority ebox-render-context
     facade-install-and-dynamic-bind one-port-captured-per-render-call
     dynamic-binding-unwind reinstall-default-surface-port
     package-reload-or-binding-unwind)
    (identity-allocation-authority
     (ebox--region-id-counter ebox--runtime-node-id-counter)
     generation-bound-mutable-authority ebox-identity
     next-region-or-runtime-node-id
     allocated-identity-enters-one-candidate
     allocator-gaps-are-non-authoritative monotonic-next-allocation
     process-lifetime-test-reset-only)
    (buffer-surface-runtime-authority
     (ebox-surface--buffer-surface ebox-surface--buffer-observer
      ebox-surface--tp-observer ebox-surface--observation-contexts
      ebox-surface--context-signals)
     generation-bound-mutable-authority ebox-surface
     mount-observe-publish-and-unmount
     buffer-surface-and-publication-revision
     restore-prior-surface-signals-and-observer-bridge
     not-rebuildable-from-cache
     remove-observers-cancel-contexts-and-unmount)
    (tp-client-state-custody (tp-surface-client-state)
     tp-storage-custody tp opaque-ebox-generation-correlation-only
     opaque-correlation tp-restores-client-state
     ebox-generation-remains-source-of-truth tp-surface-unmount)
    (buffer-render-state-mirror (ebox--buffer-render-state-table)
     compatibility-mirror ebox-compatibility
     project-from-committed-generation committed-generation-token
     participant-restores-prior-projection
     project-buffer-mirror-from-committed-states remove-buffer-entry)
    (region-box-lookup-mirror (ebox--region-box-table)
     compatibility-mirror ebox-compatibility
     project-from-committed-generation committed-generation-token
     participant-restores-prior-projection
     project-region-mirror-from-generation-indexes
     remove-retired-generation-entries)
    (font-cache (ebox-font--cache)
     disposable-cache ebox-font cache-fill-and-evict
     display-capability-signature discard resolve-font-fact-again
     ebox-font-clear-cache)
    (native-hover-face-cache (ebox-interaction--hover-face-cache)
     disposable-cache ebox-interaction weak-cache-fill
     hover-owner-and-computed-paint discard-unreferenced-candidates
     reproject-owner-native-hover-face garbage-collect-unreferenced-faces)
    (derived-caches
     (ebox--char-width-cache ebox--face-height-width-cache
      ebox--display-signature-cache ebox--render-cache-signature-cache
      ebox-style--property-index)
     disposable-cache ebox-cache cache-fill-and-evict
     cache-key-or-display-signature
     discard recompute-with-identical-semantic-result
     bounded-eviction-or-clear))
  "M2a section 7.2 minimum lifecycle expectations used by the E1 gate.")

(ert-deftest ebox-state-contract-inventory-is-complete-and-closed ()
  "Every retained-state family has one complete closed classification."
  (let* ((inventory (ebox-state-contract-validate))
         (ids (mapcar (lambda (record) (plist-get record :id)) inventory))
         (storage
          (cl-mapcan
           (lambda (record)
             (cl-remove-if-not
              (lambda (symbol)
                (and (symbolp symbol) (not (keywordp symbol))))
              (copy-sequence (plist-get record :storage))))
           inventory)))
    (should (= (length ids) (length (delete-dups (copy-sequence ids)))))
    (should (= (length storage)
               (length (delete-dups (copy-sequence storage)))))
    (dolist (record inventory)
      (dolist (field ebox-state-contract-required-fields)
        (should (plist-get record field)))
      (should (memq (plist-get record :category)
                    ebox-state-contract-categories)))
    (dolist (expected ebox-state-contract-test--plan-expectations)
      (should (memq (car expected) ids)))))

(ert-deftest ebox-state-contract-validator-rejects-duplicate-storage ()
  "One source storage identity cannot belong to two inventory records."
  (let* ((inventory (ebox-state-contract-inventory))
         (duplicate 'ebox--render-source-index)
         (second (cadr inventory))
         (ebox-state-contract--inventory
          (cons (car inventory)
                (cons (plist-put second :storage
                                 (cons duplicate
                                       (plist-get second :storage)))
                      (cddr inventory)))))
    (should-error (ebox-state-contract-validate)
                  :type 'ebox-state-contract-error)))

(ert-deftest ebox-state-contract-inventory-covers-plan-table-minimums ()
  "Every plan-named storage family keeps its required lifecycle classification."
  (dolist (expected ebox-state-contract-test--plan-expectations)
    (let ((record (ebox-state-contract-record (nth 0 expected))))
      (should (cl-subsetp (nth 1 expected) (plist-get record :storage)
                          :test #'equal))
      (should (eq (plist-get record :category) (nth 2 expected)))
      (should (eq (plist-get record :owner) (nth 3 expected)))
      (should (eq (plist-get record :mutation-api) (nth 4 expected)))
      (should (eq (plist-get record :generation-binding) (nth 5 expected)))
      (should (eq (plist-get record :rollback) (nth 6 expected)))
      (should (eq (plist-get record :rebuild-proof) (nth 7 expected)))
      (should (eq (plist-get record :cleanup) (nth 8 expected))))))

(ert-deftest ebox-state-contract-inventory-is-detached ()
  "Callers cannot mutate the retained package inventory."
  (let ((copy (ebox-state-contract-inventory)))
    (setf (plist-get (car copy) :category) 'disposable-cache)
    (should (eq (plist-get (ebox-state-contract-record
                            'runtime-generation-indexes)
                           :category)
                'generation-fact))))

(ert-deftest ebox-state-contract-never-classifies-live-authority-as-cache ()
  "Cleanup-sensitive handles retain generation-bound mutable authority."
  (dolist (id '(scroll-runtime-authority native-runtime-authority
                runtime-prewarm-authority viewport-event-authority
                incremental-batch-authority
                layout-context-port-authority identity-allocation-authority
                buffer-surface-runtime-authority))
    (let ((record (ebox-state-contract-record id)))
      (should (eq (plist-get record :category)
                  'generation-bound-mutable-authority))
      (should (plist-get record :generation-binding))
      (should (plist-get record :cleanup))))
  (dolist (id '(scroll-runtime-authority native-runtime-authority))
    (should (eq (plist-get (ebox-state-contract-record id) :rebuild-proof)
                'not-rebuildable-from-cache))))

(ert-deftest ebox-state-contract-classifies-buffer-local-surface-authority ()
  "Mounted surfaces, signals, and observer state remain explicit authority."
  (let ((record
         (ebox-state-contract-record 'buffer-surface-runtime-authority)))
    (dolist (symbol '(ebox-surface--buffer-surface
                      ebox-surface--buffer-observer
                      ebox-surface--tp-observer
                      ebox-surface--observation-contexts
                      ebox-surface--context-signals))
      (should (memq symbol (plist-get record :storage))))
    (should (eq (plist-get record :category)
                'generation-bound-mutable-authority))
    (should (eq (plist-get record :rebuild-proof)
                'not-rebuildable-from-cache))))

(ert-deftest ebox-state-contract-excludes-dynamic-render-source-containers ()
  "Transient old/candidate render inputs are not mislabeled as retained facts."
  (dolist (symbol '(ebox--render-source-generations
                    ebox--render-source-states))
    (should-not (memq symbol (ebox-state-contract-storage-symbols)))
    (let ((entry
           (cl-find symbol ebox-state-contract-source-scan-exclusions
                    :key (lambda (item) (plist-get item :symbol)))))
      (should entry)
      (should (eq (plist-get entry :reason)
                  'dynamically-bound-render-proof-input)))))

(ert-deftest ebox-state-contract-classifies-font-and-prewarm-stores-explicitly ()
  "Font cache and cleanup-sensitive prewarm stores cannot hide in broad prose."
  (let ((font (ebox-state-contract-record 'font-cache))
        (prewarm (ebox-state-contract-record 'runtime-prewarm-authority)))
    (should (equal (plist-get font :storage) '(ebox-font--cache)))
    (should (eq (plist-get font :category) 'disposable-cache))
    (dolist (symbol '(ebox--runtime-prewarm-jobs
                      ebox--runtime-prewarm-timers
                      ebox--reflow-cache-prewarm-timers
                      ebox--deferred-render-gc-state
                      ebox--deferred-render-gc-timer
                      ebox--deferred-render-gc-depth
                      ebox--deferred-render-gc-generation
                      ebox--render-burst-records
                      ebox--render-burst-stack))
      (should (memq symbol (plist-get prewarm :storage))))
    (should (eq (plist-get prewarm :category)
                'generation-bound-mutable-authority))))

(ert-deftest ebox-state-contract-excludes-native-compile-scratch-from-authority ()
  "Compile-local indexes are not mislabeled as native session authority."
  (let ((authority-storage
         (plist-get (ebox-state-contract-record 'native-runtime-authority)
                    :storage)))
    (dolist (symbol '(ebox-native-reflow--compile-property-template-ids
                      ebox-native-reflow--compile-property-template-index
                      ebox-native-reflow--compile-style-index))
      (should-not (memq symbol authority-storage))
      (let ((exclusion
             (cl-find symbol ebox-state-contract-source-scan-exclusions
                      :key (lambda (entry) (plist-get entry :symbol)))))
        (should exclusion)
        (should (eq (plist-get exclusion :reason)
                    'dynamically-bound-compile-local-scratch))))))

(ert-deftest ebox-state-contract-tp-custody-is-opaque ()
  "The inventory separates current whole-state custody from its M2a target."
  (let ((record (ebox-state-contract-record 'tp-client-state-custody)))
    (should (eq (plist-get record :owner) 'tp))
    (should (eq (plist-get record :current-contract)
                'entire-ebox-state-plist))
    (should (eq (plist-get record :target-contract)
                'opaque-generation-correlation-only))
    (should (eq (plist-get record :mutation-api)
                'opaque-ebox-generation-correlation-only))
    (should (eq (plist-get record :rebuild-proof)
                'ebox-generation-remains-source-of-truth))))

(ert-deftest ebox-state-contract-rebuilds-current-compatibility-mirrors ()
  "Committed client state rebuilds the current buffer and region mirrors."
  (let ((buffer (generate-new-buffer " *ebox-m2a-e1-mirror*")))
    (unwind-protect
        (let* ((_rendered
                (ebox-render-to-buffer
                 buffer
                 (ebox-test-column
                  (ebox-test-box :key 'first (ebox-test-text "first"))
                  (ebox-test-box :key 'second (ebox-test-text "second")))))
               (surface (ebox-surface--live-buffer-surface buffer))
               (state (tp-surface-client-state surface))
               (before-text
                (with-current-buffer buffer
                  (buffer-substring (point-min) (point-max))))
               (before-revision (tp-surface-revision surface))
               (entries (list (cons buffer state)))
               (rebuilt
                (ebox-state-contract-rebuild-compatibility-mirrors entries))
               (report
                (ebox-state-contract-probe-compatibility-mirrors
                 entries ebox--buffer-render-state-table
                 ebox--region-box-table)))
          (should (plist-get report :consistent-p))
          (should-not (plist-get report :buffer-differences))
          (should-not (plist-get report :region-differences))
          (should-not (eq (plist-get rebuilt :buffer-table)
                          ebox--buffer-render-state-table))
          (should-not (eq (plist-get rebuilt :region-table)
                          ebox--region-box-table))
          (should (eq (gethash buffer (plist-get rebuilt :buffer-table))
                      state))
          (should
           (equal (hash-table-count (plist-get rebuilt :region-table))
                  (hash-table-count (plist-get state :region-box-table))))
          (should (eq (tp-surface-client-state surface) state))
          (should (= (tp-surface-revision surface) before-revision))
          (should
           (equal (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max)))
                  before-text)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-state-contract-probe-detects-mirror-drift-without-mutation ()
  "The read-only probe reports stale compatibility entries."
  (let* ((buffer (generate-new-buffer " *ebox-m2a-e1-drift*"))
         (region-id 'ebox/m2a-e1-region)
         (box (list :node-id 'ebox/m2a-e1-box))
         (regions (make-hash-table :test #'equal))
         (state (list :region-box-table regions))
         (entries (list (cons buffer state)))
         (buffer-mirror (make-hash-table :test #'eq))
         (region-mirror (make-hash-table :test #'equal))
         (stale (list :node-id 'stale)))
    (unwind-protect
        (progn
          (puthash region-id box regions)
          (puthash buffer state buffer-mirror)
          (puthash region-id stale region-mirror)
          (let ((report
                 (ebox-state-contract-probe-compatibility-mirrors
                  entries buffer-mirror region-mirror)))
            (should-not (plist-get report :consistent-p))
            (should (equal (plist-get report :region-differences)
                           (list region-id)))
            (should (eq (gethash region-id region-mirror) stale))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-state-contract-rejects-cross-generation-region-collision ()
  "Two committed generations cannot project different boxes for one region."
  (let ((first-buffer (generate-new-buffer " *ebox-m2a-e1-first*"))
        (second-buffer (generate-new-buffer " *ebox-m2a-e1-second*"))
        (first-regions (make-hash-table :test #'equal))
        (second-regions (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (puthash 'shared (list :node-id 'first) first-regions)
          (puthash 'shared (list :node-id 'second) second-regions)
          (should-error
           (ebox-state-contract-rebuild-compatibility-mirrors
            (list (cons first-buffer (list :region-box-table first-regions))
                  (cons second-buffer (list :region-box-table second-regions))))
           :type 'ebox-state-contract-error))
      (when (buffer-live-p first-buffer) (kill-buffer first-buffer))
      (when (buffer-live-p second-buffer) (kill-buffer second-buffer)))))

(ert-deftest ebox-state-contract-probe-work-is-bounded-by-projection-size ()
  "The E1 probe performs bounded table work and never traverses a node tree."
  (let (buffers entries)
    (unwind-protect
        (progn
          (dotimes (buffer-index 64)
            (let ((buffer
                   (generate-new-buffer
                    (format " *ebox-m2a-e1-perf-%d*" buffer-index)))
                  (regions (make-hash-table :test #'equal)))
              (push buffer buffers)
              (dotimes (region-index 16)
                (puthash (cons buffer-index region-index)
                         (list :node-id (cons buffer-index region-index))
                         regions))
              (push (cons buffer (list :region-box-table regions)) entries)))
          (setq entries (nreverse entries))
          (let* ((rebuilt
                  (ebox-state-contract-rebuild-compatibility-mirrors entries))
                 (report
                  (cl-letf (((symbol-function 'ebox-tree-map)
                             (lambda (&rest _arguments)
                               (error "E1 probe traversed the node tree"))))
                    (ebox-state-contract-probe-compatibility-mirrors
                     entries (plist-get rebuilt :buffer-table)
                     (plist-get rebuilt :region-table)))))
            (should (plist-get report :consistent-p))
            (should (= (plist-get report :entry-count) 64))
            (should (= (plist-get report :projected-region-count) 1024))
            (should (= (plist-get report :buffer-comparisons) 64))
            (should (= (plist-get report :region-comparisons) 1024))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'ebox-state-contract-tests)

;;; ebox-state-contract-tests.el ends here
