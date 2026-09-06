;;; ebox-m0a-inventory-tests.el --- M0a inventory contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)
(require 'ebox-m0a-inventory-fixture)
(require 'ebox-fixtures)

(defun ebox-m0a-test--all-state-inventory ()
  "Return primary and supplemental classified state inventories."
  (ebox-m0a-current-state-inventory))

(defun ebox-m0a-test--state-key-records ()
  "Return inventory records stored as retained state keys."
  (cl-remove-if-not
   (lambda (record) (eq (car (plist-get record :storage)) :state-key))
   (ebox-m0a-test--all-state-inventory)))

(defun ebox-m0a-test--store-name-p (symbol)
  "Return non-nil when SYMBOL names a table-like state store."
  (and (symbolp symbol)
       (string-match-p
        "\\(?:-table\\|-cache\\|-index\\|-registry\\|-history\\|-session\\|-jobs\\|-timer\\|-timers\\)\\'"
        (symbol-name symbol))))

(defun ebox-m0a-test--keyword-store-name-p (symbol)
  "Return non-nil when keyword SYMBOL names a nested state store."
  (and (keywordp symbol) (ebox-m0a-test--store-name-p symbol)))

(defun ebox-m0a-test--hash-constructor-p (form)
  "Return non-nil when FORM directly materializes a hash table."
  (eq (car-safe form) 'make-hash-table))

(defun ebox-m0a-test--declared-globals (forms)
  "Return variables declared by top-level FORMS."
  (let (globals)
    (dolist (form forms)
      (when (and (memq (car-safe form) '(defvar defconst))
                 (symbolp (cadr form)))
        (push (cadr form) globals)))
    (delete-dups globals)))

(defun ebox-m0a-test--materialized-global-bindings (form declared-globals)
  "Return declared globals directly bound to hashes inside FORM.
DECLARED-GLOBALS distinguishes dynamic package stores from ordinary lexical
scratch tables, which are intentionally outside the retained-store inventory."
  (let (globals)
    (ebox-m0a-test--walk-form
     form
     (lambda (nested)
       (pcase (car-safe nested)
         ((or 'let 'let*)
          (dolist (binding (cadr nested))
            (when (and (consp binding)
                       (memq (car binding) declared-globals)
                       (ebox-m0a-test--hash-constructor-p (cadr binding)))
              (push (car binding) globals))))
         ((or 'setq 'setq-default)
          (let ((pairs (cdr nested)))
            (while pairs
              (when (and (memq (car pairs) declared-globals)
                         (ebox-m0a-test--hash-constructor-p (cadr pairs)))
                (push (car pairs) globals))
              (setq pairs (cddr pairs))))))))
    (delete-dups globals)))

(defun ebox-m0a-test--read-forms (file)
  "Read and return every top-level Lisp form in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms form)
      (condition-case nil
          (while t
            (setq form (read (current-buffer)))
            (push form forms))
        (end-of-file nil))
      (nreverse forms))))

(defun ebox-m0a-test--walk-form (form function)
  "Call FUNCTION for FORM and every nested cons or vector element."
  (funcall function form)
  (cond
   ((consp form)
    (ebox-m0a-test--walk-form (car form) function)
    (ebox-m0a-test--walk-form (cdr form) function))
   ((vectorp form)
    (mapc (lambda (item) (ebox-m0a-test--walk-form item function)) form))))

(defun ebox-m0a-test--struct-name (definition)
  "Return the structure name declared by `cl-defstruct' DEFINITION."
  (let ((head (cadr definition)))
    (if (symbolp head) head (car head))))

(defun ebox-m0a-test--struct-slots (definition)
  "Return plain slot names declared by `cl-defstruct' DEFINITION."
  (let ((tail (cddr definition)) slots)
    (while (and tail (stringp (car tail))) (pop tail))
    (dolist (slot tail)
      (let ((name (if (symbolp slot) slot (car-safe slot))))
        (when (symbolp name) (push name slots))))
    (nreverse slots)))

(defun ebox-m0a-test--schema-store-slot-p (structure slot)
  "Return non-nil when STRUCTURE's SLOT is a known nested store schema."
  (or (ebox-m0a-test--store-name-p slot)
      (member
       (cons structure slot)
       '((ebox-source-index . records)
         (ebox-source-index . handle-records)
         (ebox-source-index . subjects)
         (ebox-source-index . node-subjects)
         (ebox-source-builder . records)
         (ebox-source-builder . handle-records)
         (ebox-source-table . added)
         (ebox-source-table . removed)
         (ebox-source-table . memo)
         (ebox-source-order . replacements)
         (ebox-source-order . removed)
         (ebox-incremental--detached-history . table)))))

(defun ebox-m0a-test--static-store-candidates ()
  "Return located store candidates found in active Ebox source forms."
  (let* ((sources (delete-dups (copy-sequence ebox--compile-sources)))
         (source-forms
          (mapcar (lambda (source)
                    (cons source (ebox-m0a-test--read-forms source)))
                  sources))
         (declared-globals
          (delete-dups
           (apply #'append
                  (mapcar (lambda (entry)
                            (ebox-m0a-test--declared-globals (cdr entry)))
                          source-forms))))
         candidates)
    (dolist (entry source-forms)
      (let* ((source (car entry))
             (module (intern (file-name-base source)))
             (forms (cdr entry)))
        (dolist (form forms)
          (when (and (memq (car-safe form) '(defvar defconst))
                     (or (ebox-m0a-test--store-name-p (cadr form))
                         (ebox-m0a-test--hash-constructor-p (caddr form))))
            (push (list :storage (list :global (cadr form))
                        :defined-in source :declaring-module module)
                  candidates))
          (dolist (symbol
                   (ebox-m0a-test--materialized-global-bindings
                    form declared-globals))
            (push (list :storage (list :global symbol)
                        :defined-in source :declaring-module module)
                  candidates))
          (when (eq (car-safe form) 'cl-defstruct)
            (let ((structure (ebox-m0a-test--struct-name form)))
              (dolist (slot (ebox-m0a-test--struct-slots form))
                (when (ebox-m0a-test--schema-store-slot-p structure slot)
                  (push (list :storage (list :struct-slot structure slot)
                              :defined-in source :declaring-module module)
                        candidates)))))
          (ebox-m0a-test--walk-form
           form
           (lambda (nested)
             (when (ebox-m0a-test--keyword-store-name-p nested)
               (push (list :storage (list :state-key nested)
                           :defined-in source :declaring-module module)
                     candidates)))))))
    (sort (delete-dups candidates)
          (lambda (left right)
            (string< (prin1-to-string left) (prin1-to-string right))))))

(defun ebox-m0a-test--inventory-storage-identities ()
  "Return all classified and explicitly blocked storage identities."
  (append
   (mapcar (lambda (record) (plist-get record :storage))
           (ebox-m0a-test--all-state-inventory))
   (mapcar (lambda (record) (plist-get record :storage))
           ebox-m0a-non-store-exclusions)))

(ert-deftest ebox-m0a-inventory-records-have-complete-lifecycle-fields ()
  "Every state inventory record names its current lifecycle contract."
  (dolist (record (ebox-m0a-test--all-state-inventory))
    (dolist (field ebox-m0a-state-table-required-fields)
      (should (plist-member record field))
      (should (plist-get record field)))))

(ert-deftest ebox-m0a-non-store-exclusions-carry-source-evidence ()
  "Every scanner exclusion records why its matching name is not a store."
  (dolist (record ebox-m0a-non-store-exclusions)
    (should (plist-get record :storage))
    (should (plist-get record :why))
    (should (plist-get record :owner))
    (should (plist-get record :evidence))))

(ert-deftest ebox-m0a-has-no-observed-unclassified-stores ()
  "M0a cannot pass while a real discovered store remains unclassified."
  (should-not ebox-m0a-observed-unclassified-stores))

(ert-deftest ebox-m0a-static-store-scan-is-fail-closed ()
  "Every located static candidate is classified or proven not to be a store."
  (let ((known (ebox-m0a-test--inventory-storage-identities)))
    (dolist (candidate (ebox-m0a-test--static-store-candidates))
      (should (plist-get candidate :defined-in))
      (should (plist-get candidate :declaring-module))
      (should (member (plist-get candidate :storage) known)))))

(ert-deftest ebox-m0a-materialized-global-scan-excludes-lexical-scratch-tables ()
  "Dynamic package stores are candidates; ordinary lexical tables are not."
  (should
   (equal
    (ebox-m0a-test--materialized-global-bindings
     '(let ((scratch (make-hash-table :test #'eq))
            (ebox-m0a-test--dynamic-store (make-hash-table :test #'equal)))
        (puthash 'key 'value scratch))
     '(ebox-m0a-test--dynamic-store))
    '(ebox-m0a-test--dynamic-store))))

(ert-deftest ebox-m0a-lazy-and-nested-stores-are-classified-not-blocked ()
  "Known lazy native/viewport/scroll and nested stores have classifications."
  (let ((classified
         (mapcar (lambda (record) (plist-get record :storage))
                 (ebox-m0a-test--all-state-inventory)))
        (critical
         '((:global ebox-cache--registry)
           (:global ebox-cache--buffer-report-table)
           (:global ebox--char-width-cache)
           (:global ebox--render-burst-records)
           (:global ebox--render-owned-text-values)
           (:global ebox--string-pixel-width-cache)
           (:global ebox--scroll-idle-prefetch-inhibited-buffers)
           (:global ebox--scroll-idle-prefetch-timers)
           (:global ebox--runtime-prewarm-jobs)
           (:global ebox--runtime-prewarm-timers)
           (:global ebox--window-size-change-pending-frames)
           (:global ebox--window-size-change-timer)
           (:global ebox--window-line-renderer-table)
           (:global ebox--window-line-prewarmer-table)
           (:global ebox-native-reflow--compile-property-template-ids)
           (:state-key :source-index)
           (:state-key :detached-identity-history)
           (:state-key :viewport-dependent-node-ids-cache)
           (:state-key :native-session)
           (:struct-slot ebox-source-index host-ref-table)
           (:struct-slot ebox-source-table added)
           (:struct-slot ebox-source-table removed)
           (:struct-slot ebox-source-table memo)
           (:struct-slot ebox-incremental--detached-history table)
           (:struct-slot ebox-native-reflow-preparation frame-cache)
           (:struct-slot ebox-native-reflow-preparation ready-timer)
           (:struct-slot ebox-native-reflow-session layout-fragment-cache))))
    (dolist (storage critical)
      (should (member storage classified)))))

(ert-deftest ebox-m0a-supplemental-stores-name-concrete-module-owners ()
  "Representative supplemental stores resolve to their implementation modules."
  (dolist (expected
           '(((:global ebox-cache--registry) . ebox-cache)
             ((:global ebox--char-width-cache) . ebox-measure)
             ((:global ebox--render-burst-records) . ebox-buffer-backend)
             ((:global ebox--render-owned-text-values) . ebox-render-context)
             ((:state-key :owner-table) . ebox-incremental)
             ((:struct-slot ebox-source-index host-ref-table) . ebox-source)
             ((:struct-slot ebox-native-reflow-preparation frame-cache)
              . ebox-native-reflow)))
    (let ((record
           (cl-find (car expected) (ebox-m0a-test--all-state-inventory)
                    :key (lambda (item) (plist-get item :storage))
                    :test #'equal)))
      (should (eq (plist-get record :owner) (cdr expected))))))

(ert-deftest ebox-m0a-inventory-record-identities-are-unique ()
  "Every inventory record has one stable machine-readable identity."
  (let ((ids (mapcar (lambda (record) (plist-get record :id))
                     (ebox-m0a-test--all-state-inventory))))
    (should (= (length ids) (length (delete-dups (copy-sequence ids)))))))

(ert-deftest ebox-m0a-proposed-state-categories-remain-inactive ()
  "M0a records proposed M2a categories without asserting their activation."
  (dolist (record (ebox-m0a-test--all-state-inventory))
    (when (plist-get record :proposed-category)
      (should (eq (plist-get record :proposal-status) 'not-active)))))

(ert-deftest ebox-m0a-layout-snapshots-record-current-in-place-aliasing ()
  "Layout snapshots expose current committed-state mutation, not target purity."
  (let ((record
         (cl-find '(:state-key :layout-snapshots)
                  (ebox-m0a-test--all-state-inventory)
                  :key (lambda (item) (plist-get item :storage))
                  :test #'equal)))
    (should (eq (plist-get record :current-mutation)
                'in-place-puthash-on-committed-state))
    (should (eq (plist-get record :aliasing)
                'committed-state-table-retained-and-mutated))))

(ert-deftest ebox-m0a-global-store-inventory-resolves-current-bindings ()
  "Every inventoried process store names a currently bound variable."
  (dolist (record (ebox-m0a-test--all-state-inventory))
    (when (eq (car (plist-get record :storage)) :global)
      (should (boundp (cadr (plist-get record :storage)))))))

(ert-deftest ebox-m0a-inventory-covers-all-materialized-runtime-hash-tables ()
  "A normal committed runtime exposes no unclassified retained hash table."
  (let ((buffer (generate-new-buffer " *ebox-m0a-runtime-inventory*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-test-column
            (ebox-test-box :key 'first (ebox-test-text "first"))
            (ebox-test-box :key 'second (ebox-test-text "second"))))
          (let ((state (ebox--buffer-render-state buffer))
                actual expected)
            (while state
              (when (hash-table-p (cadr state))
                (push (car state) actual))
              (setq state (cddr state)))
            (dolist (record (ebox-m0a-test--state-key-records))
              (let ((key (cadr (plist-get record :storage))))
                (when (hash-table-p
                       (plist-get (ebox--buffer-render-state buffer) key))
                  (push key expected))))
            (should (equal (sort actual #'string-lessp)
                           (sort expected #'string-lessp)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-m0a-current-spi-entry-points-are-symbol-lists ()
  "Every observed SPI group names a non-empty symbolic call surface."
  (dolist (record ebox-m0a-spi-inventory)
    (let ((entry-points (plist-get record :entry-points)))
      (should entry-points)
      (should (cl-every #'symbolp entry-points))
      (should (eq (plist-get record :future-v2-status)
                  'not-required-in-m0a)))))

(ert-deftest ebox-m0a-public-load-inventory-resolves-current-entry-points ()
  "Every inventoried public feature and representative function currently loads."
  (dolist (record ebox-m0a-public-load-inventory)
    (should (require (plist-get record :feature) nil t))
    (dolist (entry-point (plist-get record :public-entry-points))
      (should (fboundp entry-point)))))

(ert-deftest ebox-m0a-current-characterization-references-existing-tests ()
  "Every current-green behavior gate points at an existing ERT definition."
  (dolist (record ebox-m0a-characterization-inventory)
    (when (eq (plist-get record :status) 'current-green)
      (let* ((file (plist-get record :file))
             (test (plist-get record :test))
             (source
              (with-temp-buffer
                (insert-file-contents file)
                (buffer-string))))
        (should
         (string-match-p
          (format "(ert-deftest[[:space:]\n]+%s\\_>"
                  (regexp-quote (symbol-name test)))
          source))))))

(provide 'ebox-m0a-inventory-tests)

;;; ebox-m0a-inventory-tests.el ends here
