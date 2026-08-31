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
      :selector-type-table)
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
      ebox--scroll-idle-prefetch-timers)
     generation-bound-mutable-authority ebox-scroll
     stable-scroll-id-and-generation-token required
     participant-journal-restores-prior-authority
     not-rebuildable-from-cache cancel-timers-and-retire-generation)
    (native-runtime-authority
     (:native-sync-session :native-sync-pending :native-session
      ebox-native-reflow-preparation ebox-native-reflow-session)
     generation-bound-mutable-authority ebox-native
     native-candidate-confirm-or-abort required
     abort-candidate-and-keep-confirmed-session
     not-rebuildable-from-cache release-losing-session)
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
    (derived-caches
     (ebox--char-width-cache ebox--face-height-width-cache
      ebox--display-signature-cache ebox--render-cache-signature-cache)
     disposable-cache ebox-cache cache-fill-and-evict
     cache-key-or-display-signature
     discard recompute-with-identical-semantic-result
     bounded-eviction-or-clear))
  "Exact M2a section 7.2 lifecycle expectations used by the E1 gate.")

(ert-deftest ebox-state-contract-inventory-is-complete-and-closed ()
  "Every retained-state family has one complete closed classification."
  (let* ((inventory (ebox-state-contract-validate))
         (ids (mapcar (lambda (record) (plist-get record :id)) inventory)))
    (should (= (length inventory) 9))
    (should (= (length ids) (length (delete-dups (copy-sequence ids)))))
    (dolist (record inventory)
      (dolist (field ebox-state-contract-required-fields)
        (should (plist-get record field)))
      (should (memq (plist-get record :category)
                    ebox-state-contract-categories)))
    (should
     (equal
      ids
      '(runtime-generation-indexes region-generation-indexes
        scroll-membership scroll-runtime-authority native-runtime-authority
        tp-client-state-custody buffer-render-state-mirror
        region-box-lookup-mirror derived-caches)))))

(ert-deftest ebox-state-contract-inventory-matches-plan-table-exactly ()
  "Every plan-named storage family keeps its exact lifecycle classification."
  (dolist (expected ebox-state-contract-test--plan-expectations)
    (let ((record (ebox-state-contract-record (nth 0 expected))))
      (should (equal (plist-get record :storage) (nth 1 expected)))
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
  "Scroll and native handles retain generation-bound mutable authority."
  (dolist (id '(scroll-runtime-authority native-runtime-authority))
    (let ((record (ebox-state-contract-record id)))
      (should (eq (plist-get record :category)
                  'generation-bound-mutable-authority))
      (should (eq (plist-get record :generation-binding) 'required))
      (should (eq (plist-get record :rebuild-proof)
                  'not-rebuildable-from-cache)))))

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
