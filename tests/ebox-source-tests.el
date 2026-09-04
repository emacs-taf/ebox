;;; ebox-source-tests.el --- Source ownership contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'ebox)

(ert-deftest ebox-source-index-is-the-sole-source-fact-owner ()
  "Source construction and public reads cannot mutate an immutable index."
  (let* ((class (list (copy-sequence "row")))
         (declaration-value (vector (copy-sequence "red")))
         (declarations (list 'ebox/color declaration-value))
         (provenance-table (make-hash-table :test #'eq))
         (_ (puthash 'origin (copy-sequence "fixture") provenance-table))
         (builder (ebox-source-builder-create))
         (first
          (ebox-source-builder-bind
           builder
           :key 'row-1 :id "first" :class class
           :selector-attributes '((role . button))
           :selector-state '(focused)
           :declarations declarations
           :provenance (list :table provenance-table)))
         (second
          (ebox-source-builder-bind
           builder
           :key 'row-1 :id "first" :class class
           :declarations declarations))
         (builder-records (ebox-source--builder-records builder))
         (builder-handles (ebox-source--builder-handle-records builder))
         (index (ebox-source-builder-finish builder)))
    (should-not (eq first second))
    (should-not (eq (ebox-source-handle-id first)
                    (ebox-source-handle-id second)))
    (setcar class "damaged")
    (aset (aref declaration-value 0) 0 ?X)
    (puthash 'origin "damaged" provenance-table)
    (clrhash builder-records)
    (clrhash builder-handles)
    (should (ebox-source-index-handle-member-p index first))
    (should (ebox-source-index-record index first))
    (should-not (ebox-source--builder-records builder))
    (should-not (ebox-source--builder-handle-records builder))
    (let ((record (ebox-source-index-record index first)))
      (should (equal '("row") (ebox-source-record-classes record)))
      (should (equal ["red"]
                     (plist-get (ebox-source-record-declarations record)
                                'ebox/color)))
      (should (equal "fixture"
                     (gethash
                      'origin
                      (plist-get (ebox-source-record-provenance record)
                                 :table))))
      (setf (ebox-source-record-id record) "damaged")
      (setcar (ebox-source-record-classes record) "damaged")
      (aset (plist-get (ebox-source-record-declarations record) 'ebox/color)
            0 "damaged"))
    (let ((fresh (ebox-source-index-record index first)))
      (should (equal "first" (ebox-source-record-id fresh)))
      (should (equal '("row") (ebox-source-record-classes fresh)))
      (should (equal ["red"]
                     (plist-get (ebox-source-record-declarations fresh)
                                'ebox/color))))
    (let ((handles (ebox-source-index-handles index)))
      (setcar handles second)
      (should (equal (list first second)
                     (ebox-source-index-handles index))))
    (let ((duplicate-builder (ebox-source-builder-create)))
      (ebox-source-builder-bind duplicate-builder :identity 'same)
      (should-error
       (ebox-source-builder-bind duplicate-builder :identity 'same)
       :type 'error))
    (should-error (ebox-source-builder-bind builder :identity 'sealed)
                  :type 'error)
    (let* ((private (ebox-node-factory--create-from-properties
                     :bgcolor "red"))
           (empty-builder (ebox-source-builder-create))
           (empty-index (ebox-source-builder-finish empty-builder)))
      (should-not (plist-member private :ebox-style-declarations))
      (should-not (ebox-style-node-declarations empty-index private)))))

(ert-deftest ebox-source-rebind-keeps-order-and-bounded-persistence ()
  "Long-lived local updates must preserve order without growing recursion."
  (should (= ebox-source--persistent-max-depth 4))
  (let* ((builder (ebox-source-builder-create))
         (first (ebox-source-builder-bind builder :identity 'a))
         (middle (ebox-source-builder-bind builder :identity 'b))
         (last (ebox-source-builder-bind builder :identity 'c))
         (index (ebox-source-builder-finish builder))
         durations)
    (let ((gc-cons-threshold most-positive-fixnum)
          (gc-cons-percentage 1.0))
      (dotimes (revision 2000)
        (let ((started (float-time)))
          (pcase-let ((`(,next-index . ,next-handle)
                       (ebox-source-index-rebind
                        index middle
                        :declarations
                        (list 'ebox/color (number-to-string revision)))))
            (setq index next-index
                  middle next-handle))
          (push (* 1000.0 (- (float-time) started)) durations))))
    (let ((handles (ebox-source-index-handles index)))
      (should (= (length handles) 3))
      (should (eq first (car handles)))
      (should (eq middle (cadr handles)))
      (should (eq last (caddr handles)))
      (should (equal '(a b c) (mapcar #'ebox-source-handle-id handles))))
    (should (< (ebox-source-table-depth
                (ebox-source--index-records index))
               ebox-source--persistent-max-depth))
    (should (< (ebox-source-table-depth
                (ebox-source--index-handle-records index))
               ebox-source--persistent-max-depth))
    (should (< (ebox-source-order-depth (ebox-source--index-order index))
               ebox-source--persistent-max-depth))
    (let* ((ordered (sort durations #'<))
           (p95 (nth (1- (ceiling (* 0.95 (length ordered)))) ordered))
           (maximum (car (last ordered))))
      (should (< p95 50.0))
      (should (< maximum 50.0)))))

(ert-deftest ebox-source-persistent-lookups-compress-inherited-paths ()
  "An immutable overlay should not repeatedly traverse its retained history."
  (let* ((base-values (make-hash-table :test #'equal))
         (_ (puthash 'retained 'value base-values))
         (table (ebox-source--flat-table base-values #'equal)))
    (dotimes (revision (1- ebox-source--persistent-max-depth))
      (let ((added (make-hash-table :test #'equal))
            (removed (make-hash-table :test #'equal)))
        (puthash (list 'revision revision) revision added)
        (setq table
              (ebox-source--table-overlay
               table added removed (1+ (ebox-source-table-count table))))))
    (should (eq 'value
                (ebox-source--table-get table 'retained 'missing)))
    (should (eq 'value
                (gethash 'retained (ebox-source-table-memo table))))
    (should (eq 'missing
                (ebox-source--table-get table 'absent 'missing)))
    (should (eq ebox-source--memo-missing
                (gethash 'absent (ebox-source-table-memo table))))))

(ert-deftest ebox-source-hot-lookups-reuse-private-absence-markers ()
  "Persistent lookup and order reads must not allocate absence symbols."
  (let* ((opaque-value (make-symbol "opaque-source-value"))
         (base-values (make-hash-table :test #'eq))
         (_ (puthash 'present opaque-value base-values))
         (base (ebox-source--flat-table base-values #'eq))
         (added (make-hash-table :test #'eq))
         (removed (make-hash-table :test #'eq))
         (table (ebox-source--table-overlay base added removed 1))
         (replacements (make-hash-table :test #'eq))
         (order-removed (make-hash-table :test #'eq))
         (original-make-symbol (symbol-function 'make-symbol))
         (symbol-creations 0))
    (puthash 'old 'new replacements)
    (cl-letf (((symbol-function 'make-symbol)
               (lambda (name)
                 (cl-incf symbol-creations)
                 (funcall original-make-symbol name))))
      (should (eq opaque-value
                  (ebox-source--table-value table 'present)))
      (should (ebox-source--table-member-p table 'present))
      (should-not (ebox-source--table-member-p table 'absent))
      (should-not (ebox-source--table-value table 'absent))
      (should (equal '(new kept tail)
                     (ebox-source--order-apply
                      '(old kept) replacements order-removed '(tail)))))
    (should (zerop symbol-creations))))

(ert-deftest ebox-source-delta-resolves-each-node-record-once ()
  "Node-local source diff should materialize one record view per generation."
  (let* ((old-input (ebox-build '(box :id "before" "Same")))
         (new-input (ebox-build '(box :id "after" "Same")))
         (old-node
          (ebox-canonical-input--single-root old-input "source delta test"))
         (new-node
          (ebox-canonical-input--single-root new-input "source delta test"))
         (old-index (ebox-canonical-input--source-index old-input))
         (new-index (ebox-canonical-input--source-index new-input))
         (original (symbol-function 'ebox-source--index-record))
         (lookups 0)
         changed)
    (cl-letf (((symbol-function 'ebox-source--index-record)
               (lambda (index handle)
                 (cl-incf lookups)
                 (funcall original index handle))))
      (setq changed
            (ebox-incremental--candidate-local-changed-keys
             old-node old-index new-node new-index)))
    (should (= lookups 2))
    (should (equal changed '(:id)))))

(ert-deftest ebox-build-produces-handle-only-canonical-nodes ()
  "The DSL should place author source facts behind opaque handles only."
  (let* ((input
          (ebox-build
           '(column :id "root" :class "shelf"
             (box :key row-1 :class "row" "One")
             (box :key row-2 :class "row" "Two"))))
         (root (ebox-canonical-input--single-root input "source test"))
         (base-index (ebox-canonical-input--source-index input))
         nodes handles)
    (cl-labels
        ((visit (node)
           (push node nodes)
           (push (ebox-node-source-handle node) handles)
           (when (ebox-box-node-p node)
             (mapc #'visit (ebox-box-node-children node)))))
      (visit root))
    (setq nodes (nreverse nodes)
          handles (nreverse handles))
    (dolist (node nodes)
      (should (ebox-source-handle-p (ebox-node-source-handle node)))
      (should-not (fboundp 'ebox-source--handle-record))
      (dolist (field '(:key :id :class :ebox-style-declarations))
        (should-not (plist-member node field))))
    (let* ((index (ebox-tree-source-index root nil nil base-index))
           (root-record (ebox-source-index-record index (car handles)))
           (first-box (nth 1 nodes))
           (first-record
            (ebox-source-index-record
             index (ebox-node-source-handle first-box))))
      (should (equal "root" (ebox-source-record-id root-record)))
      (should (equal '("shelf")
                     (ebox-source-record-classes root-record)))
      (should (eq 'row-1 (ebox-source-record-key first-record)))
      (should (equal '("row")
                     (ebox-source-record-classes first-record))))
    (let* ((source-index (ebox-tree-source-index root nil nil base-index))
           (copy (copy-sequence root)))
      (should (eq (ebox-tree-node-subject source-index root)
                  (ebox-tree-node-subject source-index copy))))
    (should-error (ebox-render root) :type 'wrong-type-argument)
    (should (string-match-p "One" (ebox-render input)))
    (should (string-match-p "Two" (ebox-render input)))))

(ert-deftest ebox-canonical-input-owns-root-ref-and-full-equivalence ()
  "Root addressing and no-op comparison must include immutable source facts."
  (cl-labels
      ((input
        (color &optional identity)
        (let* ((builder (ebox-source-builder-create))
               (declarations
                (ebox-style-compile-form 'text (list :color color)))
               (handle
                (ebox-source-builder-bind
                 builder :identity (or identity '(host root))
                 :declarations declarations
                 :provenance '(:adapter source-test)))
               (node
                (ebox-text-create
                 :value "Same"
                 :owned-facts
                 (ebox-canonical-facts-from-declarations 'text declarations)
                 :source-handle handle)))
          (ebox-canonical-input-create
           (list node) (ebox-source-builder-finish builder)))))
    (let* ((first (input "red"))
           (same (input "red"))
           (changed (input "blue"))
           (root-ref (ebox-canonical-input-root-host-ref first)))
      (should (equal '(host root) root-ref))
      (setcar root-ref 'damaged)
      (should (equal '(host root)
                     (ebox-canonical-input-root-host-ref first)))
      (should (ebox-canonical-input-equal-p first same))
      (should-not (ebox-canonical-input-equal-p first changed))
      (let ((foreign-builder (ebox-source-builder-create)))
        (should-error
         (ebox-canonical-input-create
          (copy-sequence (ebox-canonical-input--nodes first))
          (ebox-source-builder-finish foreign-builder))
         :type 'error))
      (let* ((left (input "red" '(host left)))
             (right (input "red" '(host right)))
             (reverse-builder (ebox-source-builder-create)))
        (ebox-source-builder-import
         reverse-builder (ebox-canonical-input--source-index right))
        (ebox-source-builder-import
         reverse-builder (ebox-canonical-input--source-index left))
        (let* ((combined
                (ebox-canonical-input-create
                 (append (copy-sequence (ebox-canonical-input--nodes left))
                         (copy-sequence (ebox-canonical-input--nodes right)))
                 (ebox-source-builder-finish reverse-builder)))
               (ordered
                (ebox-source-index-handles
                 (ebox-canonical-input--source-index combined))))
          (should
           (equal '((host left) (host right))
                  (mapcar #'ebox-source-handle-id ordered))))))))

(ert-deftest ebox-canonical-input-selectively-imports-retained-roots ()
  "Retained roots should adopt only their exact immutable source subtrees."
  (let* ((builder (ebox-source-builder-create))
         (left-box-handle
          (ebox-source-builder-bind builder :identity '(box left)))
         (left-text-handle
          (ebox-source-builder-bind builder :identity '(text left)))
         (right-box-handle
          (ebox-source-builder-bind builder :identity '(box right)))
         (right-text-handle
          (ebox-source-builder-bind builder :identity '(text right)))
         (text-facts (ebox-canonical-facts-from-declarations 'text nil))
         (box-facts (ebox-canonical-facts-from-declarations 'box nil))
         (left-text
          (ebox-text-create
           :value "Left" :source-handle left-text-handle
           :owned-facts text-facts))
         (right-text
          (ebox-text-create
           :value "Right" :source-handle right-text-handle
           :owned-facts text-facts))
         (left
          (ebox-box-create
           :layout (ebox-normal-layout-create) :children (list left-text)
           :source-handle left-box-handle :owned-facts box-facts))
         (right
          (ebox-box-create
           :layout (ebox-normal-layout-create) :children (list right-text)
           :source-handle right-box-handle :owned-facts box-facts))
         (input
          (ebox-canonical-input-create
           (list left right) (ebox-source-builder-finish builder)))
         (selected-builder (ebox-source-builder-create)))
    (should (equal (list left right) (ebox-canonical-input-roots input)))
    (should
     (equal (list right)
            (ebox-canonical-input-import-roots
             input (list right) selected-builder)))
    (let* ((selected
            (ebox-canonical-input-create
             (list right)
             (ebox-source-builder-finish selected-builder)))
           (index (ebox-canonical-input--source-index selected)))
      (should-not
       (ebox-source-index-handle-member-p index left-box-handle))
      (should-not
       (ebox-source-index-handle-member-p index left-text-handle))
      (should (ebox-source-index-handle-member-p index right-box-handle))
      (should (ebox-source-index-handle-member-p index right-text-handle))
      (should
       (equal '((box right) (text right))
              (mapcar
               #'ebox-source-handle-id
               (ebox-source-index-handles index)))))
    (should-error
     (ebox-canonical-input-import-roots
      input (list right right) (ebox-source-builder-create))
     :type 'error)))

(ert-deftest ebox-selector-and-reconcile-read-only-source-index ()
  "Selectors and keyed reconciliation should consume generation source indexes."
  (let ((buffer (generate-new-buffer " *ebox-source-index-cutover*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-build
            '(column :id root :class list
              (box :key a :id first :class row "A")
              (box :key b :id second :class row "B"))))
          (let* ((old-state (ebox--buffer-render-state buffer))
                 (old-index (plist-get old-state :source-index))
                 (old-first (car (ebox-selector-query-buffer buffer "#first")))
                 (old-id (plist-get old-first :node-id))
                 (old-handle
                  (ebox-node-source-handle (plist-get old-first :node))))
            (ebox-commit
             buffer
             (ebox-build
              '(column :id root :class list
                (box :key b :id second :class row "B")
                (box :key a :id first :class (row selected) "A2"))))
            (let* ((state (ebox--buffer-render-state buffer))
                   (index (plist-get state :source-index))
                   (first (car (ebox-selector-query-buffer buffer "#first")))
                   (selected
                    (car (ebox-selector-query-buffer buffer ".selected"))))
              (should-not (eq index old-index))
              (should (= old-id (plist-get first :node-id)))
              (should (= old-id (plist-get selected :node-id)))
              (should
               (equal
                '(b a)
                (delq
                 nil
                 (mapcar
                  (lambda (handle)
                    (ebox-source-record-key
                     (ebox-source-index-record index handle)))
                  (ebox-source-index-handles index)))))
              (should (equal '("row")
                             (ebox-source-record-classes
                              (ebox-source-index-record
                               old-index old-handle))))
              (maphash
               (lambda (_node-id node)
                 (when (ebox-node-kind node)
                   (should (ebox-source-index-record
                            index (ebox-node-source-handle node)))
                   (dolist (field
                            '(:key :id :class :host-ref
                              :ebox-style-declarations))
                     (should-not (plist-member node field)))))
               (plist-get state :node-table))
              (let ((records (ebox-source--index-records index))
                    (subjects (ebox-source--index-subjects index))
                    (node-subjects (ebox-source--index-node-subjects index)))
                (ebox-selector-update-buffer
                 buffer "#first" :color "#123456")
                (let* ((next-index
                        (plist-get (ebox--buffer-render-state buffer)
                                   :source-index))
                       (next-records
                        (ebox-source--index-records next-index))
                       (next-subjects
                        (ebox-source--index-subjects next-index))
                       (next-node-subjects
                        (ebox-source--index-node-subjects next-index)))
                  (should (eq records (ebox-source-table-base next-records)))
                  (should (eq subjects next-subjects))
                  (should
                   (eq node-subjects
                       (ebox-source-table-base next-node-subjects))))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'ebox-source-tests)
;;; ebox-source-tests.el ends here
