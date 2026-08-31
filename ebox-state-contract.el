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
               :selector-id-table :selector-class-table :selector-type-table)
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
               :region-box-table :layout-snapshots)
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
               ebox--scroll-idle-prefetch-timers)
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
               ebox-native-reflow-preparation ebox-native-reflow-session)
     :current-contract candidate-preparation-and-confirmed-session-handles
     :target-contract generation-token-authority
     :category generation-bound-mutable-authority
     :owner ebox-native
     :mutation-api native-candidate-confirm-or-abort
     :generation-binding required
     :rollback abort-candidate-and-keep-confirmed-session
     :rebuild-proof not-rebuildable-from-cache
     :cleanup release-losing-session)
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
    (:id derived-caches
     :storage (ebox--char-width-cache ebox--face-height-width-cache
               ebox--display-signature-cache
               ebox--render-cache-signature-cache)
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
  (let ((seen (make-hash-table :test #'eq)))
    (dolist (record ebox-state-contract--inventory)
      (dolist (field ebox-state-contract-required-fields)
        (unless (plist-get record field)
          (signal 'ebox-state-contract-error
                  (list :missing-field field :record record))))
      (let ((id (plist-get record :id))
            (category (plist-get record :category)))
        (when (gethash id seen)
          (signal 'ebox-state-contract-error
                  (list :duplicate-id id)))
        (puthash id t seen)
        (unless (memq category ebox-state-contract-categories)
          (signal 'ebox-state-contract-error
                  (list :unknown-category category :id id)))))
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
