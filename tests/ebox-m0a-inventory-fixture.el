;;; ebox-m0a-inventory-fixture.el --- M0a architecture inventory -*- lexical-binding: t; -*-

;;; Commentary:
;; Machine-readable characterization of the current Ebox ownership model.
;; This is an observed-v1 inventory, not a declaration that the future v2 SPI
;; or state split already exists.

;;; Code:

(defconst ebox-m0a-state-table-required-fields
  '(:id :storage :owner :authority :current-mutation :aliasing :lifetime
        :rollback :rebuild :cleanup)
  "Fields required on every M0a state-table inventory record.")

(defconst ebox-m0a-non-store-exclusions
  '((:storage (:global ebox--defer-scroll-content-index)
     :why dynamic-scalar-not-a-store :owner ebox-layout
     :evidence defvar-is-a-dynamic-boolean-or-index-value)
    (:storage (:global ebox--string-pixel-width-cache-ring-index)
     :why eviction-cursor-not-a-store :owner ebox-measure
     :evidence defvar-holds-a-numeric-ring-cursor)
    (:storage (:state-key :content-index)
     :why address-scalar-not-a-store :owner ebox-surface
     :evidence plist-key-holds-a-numeric-content-address)
    (:storage (:state-key :max-jobs)
     :why native-limit-not-a-store :owner ebox-native-reflow
     :evidence plist-key-holds-a-numeric-capacity)
    (:storage (:state-key :next-index)
     :why traversal-cursor-not-a-store :owner ebox-layout
     :evidence plist-key-holds-a-numeric-traversal-cursor)
    (:storage (:state-key :line-index)
     :why prewarm-cursor-not-a-store :owner ebox
     :evidence plist-key-is-incremented-as-a-numeric-task-cursor)
    (:storage (:state-key :measure-index)
     :why flex-prewarm-cursor-not-a-store :owner ebox-flex
     :evidence plist-key-is-incremented-as-a-numeric-measure-cursor)
    (:storage (:state-key :partial-index)
     :why native-result-scalar-not-a-store :owner ebox-native-reflow
     :evidence plist-key-holds-a-numeric-native-result-index)
    (:storage (:state-key :render-index)
     :why flex-prewarm-cursor-not-a-store :owner ebox-flex
     :evidence plist-key-is-incremented-as-a-numeric-render-cursor)
    (:storage (:state-key :segment-index)
     :why range-address-scalar-not-a-store :owner ebox-child-range
     :evidence plist-key-holds-a-numeric-range-address)
    (:storage (:state-key :buffer-table)
     :why fresh-projection-result-not-retained :owner ebox-state-contract
     :evidence plist-key-exists-only-in-a-detached-rebuild-return-value)
    (:storage (:state-key :region-table)
     :why fresh-projection-result-not-retained :owner ebox-state-contract
     :evidence plist-key-exists-only-in-a-detached-rebuild-return-value)
    (:storage (:state-key :cyclic-parent-table)
     :why condition-data-key-not-a-store :owner ebox-patch-plan
     :evidence keyword-labels-a-validation-error-payload)
    (:storage (:state-key :malformed-parent-table)
     :why condition-data-key-not-a-store :owner ebox-patch-plan
     :evidence keyword-labels-a-validation-error-payload)
    (:storage (:state-key :missing-parent-table)
     :why condition-data-key-not-a-store :owner ebox-incremental
     :evidence keyword-labels-a-validation-error-payload)
    (:storage (:state-key :malformed-region-index)
     :why condition-data-key-not-a-store :owner ebox-state-contract
     :evidence keyword-labels-a-validation-error-payload)
    (:storage (:state-key :public-rule-in-internal-table)
     :why condition-data-key-not-a-store :owner ebox-style
     :evidence keyword-labels-a-validation-error-payload))
  "Scanner-name matches proven by source usage not to be stores.")

(defconst ebox-m0a-observed-unclassified-stores nil
  "Real store candidates lacking classification; M0a requires this to be nil.")

(defun ebox-m0a--storage-module-owner (storage)
  "Return the current implementation module responsible for STORAGE."
  (let ((kind (car storage))
        (container (cadr storage))
        (name (symbol-name (car (last storage)))))
    (cond
     ((and (eq kind :struct-slot)
           (string-prefix-p "ebox-source" (symbol-name container)))
      'ebox-source)
     ((and (eq kind :struct-slot)
           (string-prefix-p "ebox-native-reflow" (symbol-name container)))
      'ebox-native-reflow)
     ((and (eq kind :struct-slot)
           (eq container 'ebox-incremental--detached-history))
      'ebox-incremental)
     ((string-match-p "cache--" name) 'ebox-cache)
     ((string-match-p "canonical" name) 'ebox-canonical)
     ((string-match-p "render-burst" name) 'ebox-buffer-backend)
     ((string-match-p "render-owned-text-values" name) 'ebox-render-context)
     ((string-match-p "font\\|char-width\\|pixel-width\\|face-height\\|space-pixel\\|display-signature" name)
      'ebox-measure)
     ((string-match-p "style" name) 'ebox-style)
     ((string-match-p "surface\\|paint-node\\|inline-style" name) 'ebox-surface)
     ((string-match-p "native" name) 'ebox-native-reflow)
     ((string-match-p "source\\|host-ref" name) 'ebox-source)
     ((string-match-p "child-range\\|ref-index" name) 'ebox-child-range)
     ((string-match-p "flex" name) 'ebox-flex)
     ((string-match-p "layout-fragment" name) 'ebox-fragment)
     ((string-match-p "node-region" name) 'ebox-tree)
     ((string-match-p "subject-table" name) 'ebox-tree)
     ((string-match-p "frame-cache\\|key-table" name) 'ebox-native-reflow)
     ((string-match-p "region-line\\|owner-table" name) 'ebox-incremental)
     ((string-match-p "render-output-provenance" name) 'ebox-render-context)
     ((string-match-p "uniform-width\\|scroll-table" name) 'ebox-layout)
     ((string-match-p "deferred-render-gc" name) 'ebox-buffer-backend)
     ((string-match-p "window-line\\|box-content\\|region-box\\|scroll-window" name)
      'ebox-layout)
     ((string-match-p "incremental\\|render-cache\\|viewport\\|detached\\|ancestor\\|proof\\|patchable" name)
      'ebox-incremental)
     ((string-match-p "selector" name) 'ebox-tree)
     (t 'ebox))))

(defun ebox-m0a--supplemental-record
    (storage proposed-category owner lifecycle)
  "Classify STORAGE by PROPOSED-CATEGORY, OWNER, and LIFECYCLE."
  (list :id (list 'supplemental storage) :storage storage
        :proposed-category proposed-category
        :owner (if (eq owner 'ebox)
                   (ebox-m0a--storage-module-owner storage)
                 owner)
        :authority 'ebox
        :lifetime lifecycle :rollback 'candidate-discard-or-not-authoritative
        :rebuild 'lazy-or-generation-rebuild
        :cleanup 'scope-retirement-or-cache-clear))

(defconst ebox-m0a--disposable-global-cache-symbols
  '(ebox--box-content-render-cache ebox--char-width-cache
    ebox--display-signature-cache ebox--face-height-width-cache
    ebox--flex-content-min-width-table ebox--flex-sized-render-observation-table
    ebox--flex-slot-safety-cache ebox--layout-fragments-table
    ebox--node-region-ids-cache ebox--patchable-owner-cache
    ebox--render-cache-scroll-state-retained-cost-cache
    ebox--render-cache-signature-cache ebox--render-cache-table
    ebox--render-output-provenance-table ebox--render-recached-source-node-cache
    ebox--render-string-max-pixel-width-cache
    ebox--render-string-pixel-width-cache ebox--rendered-uniform-width-table
    ebox--runtime-ancestor-cache ebox--space-pixel-cache
    ebox--string-pixel-width-cache ebox--viewport-dependent-node-ids-cache
    ebox--viewport-dependent-subtree-cache
    ebox--viewport-height-dependent-subtree-cache
    ebox--window-line-prewarmer-table ebox--window-line-renderer-table
    ebox-cache--buffer-report-table ebox-cache--registry
    ebox-canonical--declaration-fact-cache
    ebox-incremental--allocated-slot-proof-cache
    ebox-incremental--candidate-path-copy-origin-table
    ebox-incremental--candidate-proof-node-table
    ebox-style--box-engine-longhand-cache ebox-style--closed-computed-cache
    ebox-style--closed-inheritance-cache ebox-style--computed-snapshot-cache
    ebox-style--declaration-cache ebox-style--text-engine-longhand-cache
    ebox-surface--inline-style-value-cache ebox-surface--paint-node-chain-cache
    ebox-surface--paint-node-depth-cache ebox-surface--scroll-line-fragment-cache)
  "Process or dynamically scoped disposable cache/table variables.")

(defconst ebox-m0a--generation-bound-global-store-symbols
  '(ebox--deferred-render-gc-timer ebox--reflow-cache-prewarm-timers
    ebox--render-burst-records ebox--render-owned-text-values
    ebox--region-box-table
    ebox--region-line-index ebox--render-source-index
    ebox--runtime-prewarm-jobs ebox--runtime-prewarm-timers
    ebox--scroll-idle-prefetch-inhibited-buffers
    ebox--scroll-idle-prefetch-timers
    ebox-native-reflow--compile-property-template-ids
    ebox-incremental--candidate-full-source-base-index
    ebox-incremental--previous-source-base-index
    ebox-incremental--source-base-index ebox-style--property-index)
  "Generation facts and mutable scheduling stores outside the state plist.")

(defconst ebox-m0a--nested-generation-store-identities
  '((:state-key :ancestor-table) (:state-key :candidate-subject-table)
    (:state-key :host-ref-table)
    (:state-key :node-subject-table) (:state-key :owner-table)
    (:state-key :ref-index) (:state-key :region-line-bounds-index)
    (:state-key :region-line-span-index)
    (:state-key :rendered-region-line-span-index) (:state-key :source-base-index)
    (:state-key :source-index) (:state-key :surface-source-base-index)
    (:struct-slot ebox-canonical-input source-index)
    (:struct-slot ebox-child-range--sequence ref-index)
    (:struct-slot ebox-incremental--candidate-paint-patch source-index)
    (:struct-slot ebox-incremental--candidate-replacement source-index)
    (:struct-slot ebox-source-index records)
    (:struct-slot ebox-source-index handle-records)
    (:struct-slot ebox-source-index subjects)
    (:struct-slot ebox-source-index node-subjects)
    (:struct-slot ebox-source-builder records)
    (:struct-slot ebox-source-builder handle-records)
    (:struct-slot ebox-source-table added)
    (:struct-slot ebox-source-table removed)
    (:struct-slot ebox-source-order replacements)
    (:struct-slot ebox-source-order removed)
    (:struct-slot ebox-source-index host-ref-table)
    (:struct-slot ebox-source-index selector-class-table)
    (:struct-slot ebox-source-index selector-id-table)
    (:struct-slot ebox-source-index selector-type-table))
  "Nested immutable or generation-derived index/table stores.")

(defconst ebox-m0a--nested-mutable-store-identities
  '((:state-key :detached-identity-history) (:state-key :native-session)
    (:state-key :scroll-table)
    (:struct-slot ebox-incremental--detached-history table)
    (:struct-slot ebox-native-reflow-preparation ready-timer)
    (:struct-slot ebox-native-reflow-preparation native-session))
  "Nested generation-bound mutable authority stores.")

(defconst ebox-m0a--nested-cache-store-identities
  '((:state-key :frame-cache) (:state-key :key-table)
    (:state-key :layout-fragment-cache)
    (:state-key :native-fragment-owner-cache)
    (:state-key :node-region-ids-cache)
    (:state-key :string-max-pixel-width-cache)
    (:state-key :string-pixel-width-cache)
    (:state-key :viewport-dependent-node-ids-cache)
    (:state-key :viewport-dependent-subtree-cache)
    (:struct-slot ebox-native-reflow-layout-builder string-max-pixel-width-cache)
    (:struct-slot ebox-native-reflow-layout-builder string-pixel-width-cache)
    (:struct-slot ebox-source-table memo)
    (:struct-slot ebox-native-reflow-preparation frame-cache)
    (:struct-slot ebox-native-reflow-preparation key-table)
    (:struct-slot ebox-native-reflow-session layout-fragment-cache))
  "Nested disposable native, viewport, render, and measurement caches.")

(defconst ebox-m0a-supplemental-state-table-inventory
  (append
   (mapcar (lambda (symbol)
             (ebox-m0a--supplemental-record
              (list :global symbol) 'disposable-cache 'ebox 'dynamic-or-process))
           ebox-m0a--disposable-global-cache-symbols)
   (mapcar (lambda (symbol)
             (ebox-m0a--supplemental-record
              (list :global symbol) 'generation-bound-mutable
              'ebox 'dynamic-or-generation))
           ebox-m0a--generation-bound-global-store-symbols)
   (mapcar (lambda (storage)
             (ebox-m0a--supplemental-record
              storage 'generation-fact 'ebox 'candidate-or-generation))
           ebox-m0a--nested-generation-store-identities)
   (mapcar (lambda (storage)
             (ebox-m0a--supplemental-record
              storage 'generation-bound-mutable 'ebox 'candidate-or-runtime))
           ebox-m0a--nested-mutable-store-identities)
   (mapcar (lambda (storage)
             (ebox-m0a--supplemental-record
              storage 'disposable-cache 'ebox 'candidate-or-dynamic))
           ebox-m0a--nested-cache-store-identities))
  "Stores found by static schema scan beyond the primary retained-state list.")

(defun ebox-m0a--current-store-facts (storage)
  "Return conservative current mutation and aliasing facts for STORAGE."
  (cond
   ((equal storage '(:state-key :layout-snapshots))
    '(:current-mutation in-place-puthash-on-committed-state
      :aliasing committed-state-table-retained-and-mutated))
   ((memq (car storage) '(:global :struct-slot))
    '(:current-mutation mutable-container-or-whole-value-replacement
      :aliasing dynamic-or-enclosing-object-aliasing-not-proven-absent))
   ((memq (cadr storage)
          '(:native-sync-session :native-sync-pending :native-session
            :scroll-state-table :scroll-table :detached-identity-history))
    '(:current-mutation in-place-mutation-and-whole-value-replacement
      :aliasing candidate-and-committed-state-may-share-owned-handles))
   (t
    '(:current-mutation in-place-mutation-or-whole-table-replacement
      :aliasing candidate-and-committed-aliasing-not-proven-absent))))

(defun ebox-m0a--normalize-current-record (record)
  "Return RECORD augmented with current observable M0a facts."
  (let* ((copy (copy-sequence record))
         (facts (ebox-m0a--current-store-facts (plist-get copy :storage))))
    (setq copy (plist-put copy :current-mutation
                          (plist-get facts :current-mutation)))
    (setq copy (plist-put copy :aliasing (plist-get facts :aliasing)))
    (when (plist-get copy :proposed-category)
      (setq copy (plist-put copy :proposal-status 'not-active)))
    copy))

(defconst ebox-m0a-state-table-inventory
  '((:id buffer-runtime/state-store
     :storage (:global ebox--buffer-render-state-table)
     :proposed-category generation-bound-mutable :owner ebox-incremental
     :authority ebox :lifetime process-by-buffer
     :rollback tp-client-state-or-snapshot :rebuild render-or-commit
     :cleanup buffer-kill-and-unmount)
    (:id buffer-runtime/node-table
     :storage (:state-key :node-table)
     :proposed-category generation-fact :owner ebox-tree :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild runtime-index :cleanup generation-replacement)
    (:id buffer-runtime/parent-table
     :storage (:state-key :parent-table)
     :proposed-category generation-fact :owner ebox-tree :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild runtime-index :cleanup generation-replacement)
    (:id buffer-runtime/runtime-type-count-table
     :storage (:state-key :runtime-type-count-table)
     :proposed-category generation-fact :owner ebox-tree :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild runtime-index :cleanup generation-replacement)
    (:id buffer-runtime/range-ref-table
     :storage (:state-key :range-ref-table)
     :proposed-category generation-fact :owner ebox-child-range :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild runtime-index :cleanup generation-replacement)
    (:id buffer-runtime/region-id-set
     :storage (:state-key :region-id-set)
     :proposed-category generation-fact :owner ebox-tree :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild runtime-index :cleanup generation-replacement)
    (:id buffer-runtime/region-node-table
     :storage (:state-key :region-node-table)
     :proposed-category generation-fact :owner ebox-tree :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild runtime-index :cleanup generation-replacement)
    (:id buffer-runtime/region-box-count-table
     :storage (:state-key :region-box-count-table)
     :proposed-category generation-fact :owner ebox-tree :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild runtime-index :cleanup generation-replacement)
    (:id buffer-runtime/region-box-table
     :storage (:state-key :region-box-table)
     :proposed-category generation-bound-mutable :owner ebox-layout :authority ebox
     :lifetime committed-generation :rollback candidate-snapshot
     :rebuild layout-materialization :cleanup generation-replacement)
    (:id buffer-runtime/selector-id-table
     :storage (:state-key :selector-id-table)
     :proposed-category generation-fact :owner ebox-tree :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild selector-index :cleanup generation-replacement)
    (:id buffer-runtime/selector-class-table
     :storage (:state-key :selector-class-table)
     :proposed-category generation-fact :owner ebox-tree :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild selector-index :cleanup generation-replacement)
    (:id buffer-runtime/selector-type-table
     :storage (:state-key :selector-type-table)
     :proposed-category generation-fact :owner ebox-tree :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild selector-index :cleanup generation-replacement)
    (:id buffer-runtime/layout-snapshots
     :storage (:state-key :layout-snapshots)
     :proposed-category generation-fact :owner ebox-fragment :authority ebox
     :lifetime committed-generation :rollback candidate-discard
     :rebuild layout-snapshot-pass :cleanup generation-replacement)
    (:id buffer-runtime/layout-fragments
     :storage (:state-key :layout-fragments)
     :proposed-category disposable-cache :owner ebox-fragment :authority ebox
     :lifetime buffer-runtime :rollback copy-on-candidate
     :rebuild lazy-layout :cleanup clear-cache-or-buffer-kill)
    (:id buffer-runtime/render-cache
     :storage (:state-key :render-cache)
     :proposed-category disposable-cache :owner ebox-incremental :authority ebox
     :lifetime buffer-runtime :rollback copy-on-candidate
     :rebuild lazy-render :cleanup clear-cache-or-buffer-kill)
    (:id buffer-runtime/render-signature-cache
     :storage (:state-key :render-signature-cache)
     :proposed-category disposable-cache :owner ebox-incremental :authority ebox
     :lifetime buffer-runtime :rollback copy-on-candidate
     :rebuild lazy-render :cleanup clear-cache-or-buffer-kill)
    (:id buffer-runtime/flex-content-min-widths
     :storage (:state-key :flex-content-min-widths)
     :proposed-category disposable-cache :owner ebox-flex :authority ebox
     :lifetime buffer-runtime :rollback candidate-discard
     :rebuild lazy-measure :cleanup generation-replacement)
    (:id buffer-runtime/viewport-height-dependent-subtree-cache
     :storage (:state-key :viewport-height-dependent-subtree-cache)
     :proposed-category disposable-cache :owner ebox-incremental :authority ebox
     :lifetime buffer-runtime :rollback copy-on-candidate
     :rebuild viewport-proof :cleanup clear-cache-or-buffer-kill)
    (:id buffer-runtime/render-owned-text-values
     :storage (:state-key :render-owned-text-values)
     :proposed-category generation-bound-mutable :owner ebox-surface :authority ebox
     :lifetime committed-generation :rollback tp-transaction
     :rebuild surface-projection :cleanup generation-replacement)
    (:id buffer-runtime/style-binding-states
     :storage (:state-key :style-binding-states)
     :proposed-category generation-bound-mutable :owner ebox-surface :authority tp
     :lifetime mounted-surface :rollback tp-transaction
     :rebuild surface-projection :cleanup surface-unmount)
    (:id buffer-runtime/surface-node-object-table
     :storage (:state-key :surface-node-object-table)
     :proposed-category disposable-mirror :owner ebox-surface :authority tp
     :lifetime mounted-surface :rollback tp-transaction
     :rebuild surface-projection :cleanup surface-unmount)
    (:id buffer-runtime/region-surface-object-table
     :storage (:state-key :region-surface-object-table)
     :proposed-category disposable-mirror :owner ebox-surface :authority tp
     :lifetime mounted-surface :rollback tp-transaction
     :rebuild surface-projection :cleanup surface-unmount)
    (:id buffer-runtime/surface-object-region-table
     :storage (:state-key :surface-object-region-table)
     :proposed-category disposable-mirror :owner ebox-surface :authority tp
     :lifetime mounted-surface :rollback tp-transaction
     :rebuild surface-projection :cleanup surface-unmount)
    (:id buffer-runtime/logical-id-region-table
     :storage (:state-key :logical-id-region-table)
     :proposed-category disposable-mirror :owner ebox-surface :authority ebox
     :lifetime committed-generation :rollback tp-transaction
     :rebuild surface-projection :cleanup generation-replacement)
    (:id buffer-runtime/scroll-state-table
     :storage (:state-key :scroll-state-table)
     :proposed-category generation-bound-mutable :owner ebox-layout :authority ebox
     :lifetime buffer-runtime :rollback scroll-state-snapshot
     :rebuild layout-or-scroll-reconciliation :cleanup buffer-kill)
    (:id buffer-runtime/native-sync-session
     :storage (:state-key :native-sync-session)
     :proposed-category generation-bound-mutable :owner ebox-native-commit
     :authority ebox :lifetime buffer-runtime :rollback private-session-discard
     :rebuild create-or-fork-session :cleanup buffer-kill)
    (:id buffer-runtime/native-sync-pending
     :storage (:state-key :native-sync-pending)
     :proposed-category generation-bound-mutable :owner ebox-native-commit
     :authority ebox :lifetime candidate-until-final-accept
     :rollback private-session-discard :rebuild native-frame-stage
     :cleanup confirm-or-rollback)
    (:id process/scroll-global-state
     :storage (:global ebox--scroll-global-state)
     :proposed-category generation-bound-mutable :owner ebox-incremental
     :authority ebox :lifetime process-by-region :rollback explicit-snapshot
     :rebuild render-or-scroll :cleanup region-retirement)
    (:id process/smooth-scroll-state-table
     :storage (:global ebox--smooth-scroll-state-table)
     :proposed-category generation-bound-mutable :owner ebox :authority ebox
     :lifetime active-scroll :rollback stop-and-restore
     :rebuild scroll-input :cleanup scroll-stop-or-buffer-kill)
    (:id process/incremental-batch-table
     :storage (:global ebox-incremental--batch-table)
     :proposed-category generation-bound-mutable :owner ebox-incremental
     :authority ebox :lifetime explicit-batch :rollback discard-pending
     :rebuild batch-begin :cleanup batch-end-or-buffer-kill)
    (:id process/render-cache-ring-table
     :storage (:global ebox--render-cache-ring-table)
     :proposed-category disposable-cache :owner ebox-incremental :authority ebox
     :lifetime process-by-render-cache :rollback not-authoritative
     :rebuild lazy-eviction-index :cleanup cache-retirement)
    (:id process/render-root-cache-table-table
     :storage (:global ebox--render-root-cache-table-table)
     :proposed-category disposable-cache :owner ebox-incremental :authority ebox
     :lifetime process-by-render-cache :rollback not-authoritative
     :rebuild lazy-root-cache :cleanup cache-retirement)
    (:id process/render-cache-entry-side-effects-table
     :storage (:global ebox--render-cache-entry-side-effects-table)
     :proposed-category disposable-cache :owner ebox-incremental :authority ebox
     :lifetime process-by-render-cache :rollback not-authoritative
     :rebuild lazy-render :cleanup cache-retirement)
    (:id process/font-cache
     :storage (:global ebox-font--cache)
     :proposed-category disposable-cache :owner ebox-font :authority ebox
     :lifetime process :rollback not-authoritative :rebuild lazy-measure
     :cleanup ebox-font-clear-cache)
    (:id process/native-source-cluster-cache
     :storage (:global ebox-native-reflow--source-cluster-cache)
     :proposed-category disposable-cache :owner ebox-native-reflow :authority ebox
     :lifetime process :rollback not-authoritative :rebuild lazy-native-compile
     :cleanup bounded-eviction-or-clear))
  "Observed current Ebox runtime, region, scroll, native, and cache stores.")

(defun ebox-m0a-current-state-inventory ()
  "Return all stores with observable facts and inactive M2a proposals."
  (mapcar #'ebox-m0a--normalize-current-record
          (append ebox-m0a-state-table-inventory
                  ebox-m0a-supplemental-state-table-inventory)))

(defconst ebox-m0a-spi-inventory
  '((:id ebox-to-tp/publication :provider tp :consumer ebox-surface
     :version unversioned-v1 :discovery required-feature
     :entry-points (tp-with-transaction tp-surface-mount tp-surface-update
                    tp-surface-update-scoped tp-transaction-participate)
     :rollback tp-transaction :future-v2-status not-required-in-m0a)
    (:id ebox-to-ecss/cascade :provider ecss :consumer ebox-style
     :version unversioned-v1 :discovery required-feature
     :entry-points (ecss-cascade-compute ecss-stylesheet-create)
     :rollback prepare-only :future-v2-status not-required-in-m0a)
    (:id ebox-to-ekp/wrap-backend :provider ekp :consumer ebox-layout
     :version optional-string-v1 :discovery dynamic-require-and-fboundp
     :entry-points (ekp-pixel-justify)
     :rollback word-wrap-fallback :future-v2-status not-required-in-m0a)
    (:id etaf-to-ebox/lowering :provider ebox :consumer etaf-renderer
     :version unversioned-v1 :discovery required-feature
     :entry-points (ebox-source-builder-create ebox-source-builder-bind
                    ebox-text-create ebox-box-create ebox-canonical-input-create)
     :rollback candidate-discard :future-v2-status not-required-in-m0a)
    (:id etaf-to-ebox/commit :provider ebox :consumer etaf-runtime
     :version callback-pair-v1 :discovery required-feature
     :entry-points (ebox-candidate-begin ebox-candidate-replace-host-ref
                    ebox-candidate-replace-range-ref ebox-commit)
     :rollback framework-callback-pair :future-v2-status not-required-in-m0a)
    (:id etaf-to-ebox/event-burst :provider ebox :consumer etaf-events
     :version capability-probe-v1 :discovery fboundp
     :entry-points (ebox-call-with-render-burst ebox-host-ref-bounds
                    ebox-host-ref-position)
     :rollback unwind-protect :future-v2-status not-required-in-m0a))
  "Observed cross-package call groups; no v2 capability object exists yet.")

(defconst ebox-m0a-public-load-inventory
  '((:feature ebox :file "ebox.el"
     :public-entry-points (ebox-render ebox-render-to-buffer ebox-commit
                           ebox-buffer-update-report ebox-candidate-begin
                           ebox-call-with-render-burst))
    (:feature ebox-dsl :file "ebox-dsl.el"
     :public-entry-points (ebox-build))
    (:feature ebox-selector :file "ebox-selector.el"
     :public-entry-points (ebox-selector-query-buffer
                           ebox-selector-update-buffer)))
  "Current public feature/load and representative entry-point inventory.")

(defconst ebox-m0a-characterization-inventory
  '((:id framework/same-report-success :status current-green
     :file "tests/ebox-m0a-characterization-tests.el"
     :test ebox-m0a-success-return-preserves-framework-report-identity)
    (:id framework/same-report-rollback :status current-green
     :file "tests/ebox-m0a-characterization-tests.el"
     :test ebox-m0a-framework-rollback-receives-publish-report-object)
    (:id condition/raw-symbol-and-data :status current-green
     :file "tests/ebox-m0a-characterization-tests.el"
     :test ebox-m0a-framework-failure-resignals-raw-condition-symbol-and-data)
    (:id framework/full-and-scoped-rollback :status current-green
     :file "tests/ebox-commit-tests.el"
     :test ebox-commit-framework-publish-failure-rolls-back-full-and-scoped)
    (:id framework/final-accept-rollback :status current-green
     :file "tests/ebox-commit-tests.el"
     :test ebox-commit-final-accept-failure-rolls-framework-back)
    (:id native/private-session-failure-isolation :status current-green
     :file "tests/ebox-commit-tests.el"
     :test ebox-native-session-isolation-rejects-create-and-fork-errors)
    (:id paint/atomic-rollback :status current-green
     :file "tests/ebox-core-render-tests.el"
     :test ebox-region-update-valid-paint-and-invalid-edge-is-atomic)
    (:id future/versioned-spi-v2 :status future-not-required
     :file nil :test nil))
  "Executable current gates and explicitly non-green future targets for M0a.")

(provide 'ebox-m0a-inventory-fixture)

;;; ebox-m0a-inventory-fixture.el ends here
