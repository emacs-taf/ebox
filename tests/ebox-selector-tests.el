;;; ebox-selector-tests.el --- Selector query tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(load-file (expand-file-name "../ebox.el"
                             (file-name-directory
                              (or load-file-name buffer-file-name))))
(require 'ebox-selector)

(defun ebox-selector-test--reset-runtime-state ()
  "Reset runtime counters and tables for selector tests."
  (setq ebox--region-id-counter 0)
  (setq ebox--runtime-node-id-counter 0)
  (setq ebox--render-region-id nil)
  (dolist (table (list ebox--region-box-table
                       ebox--buffer-render-state-table
                       ebox--scroll-global-state))
    (clrhash table)))

(defun ebox-selector-test--width-unit-form (width)
  "Return a layout whose root WIDTH constrains nested auto layout."
  `(column :id root :width ,width
    (box :padding ((lh 0) (px 12)) :border "#111111"
         "Header text wraps when the root is narrow")
    (flex :flex-flow (row wrap) :column-gap (px 12)
          :padding ((lh 0) (px 12)) :border "#D97757"
          (column
           (box :width (px 220) :border "#D97757" "row")
           (flex :width (px 220) :height (lh 4) :border "#D97757"
                 (box :width (px 42) "A")
                 (box :width (px 42) "B")
                 (box :width (px 42) "C")))
          (column
           (box :width (px 220) :border "#D97757" "row-reverse")
           (flex :width (px 220) :height (lh 4) :border "#D97757"
                 (box :width (px 42) "A")
                 (box :width (px 42) "B")
                 (box :width (px 42) "C"))))))

(defun ebox-selector-test--rendered-widths (rendered)
  "Return pixel widths for RENDERED lines."
  (mapcar #'ebox--string-pixel-width (ebox-string-lines rendered)))

(ert-deftest ebox-selector-parses-type-id-class-and-attributes ()
  "Selectors should compile predicates into ECSS structured selector AST."
  (should (equal (ebox-selector-parse "box.warning#summary[key=main]")
                 '(:and (:type "box")
                        (:class "warning")
                        (:id "summary")
                        (:attr "key" "=" "main" nil)))))

(ert-deftest ebox-selector-parses-child-and-descendant-combinators ()
  "Selectors should compile relations into nested ECSS combinators."
  (should (equal (ebox-selector-parse ".panel > box .label")
                 '(:descendant
                   (:child (:class "panel") (:type "box"))
                   (:class "label")))))

(ert-deftest ebox-selector-parses-adjacent-and-general-sibling-combinators ()
  "Selectors should expose ECSS adjacent and general sibling relations."
  (should (equal (ebox-selector-parse "#first + box ~ .later")
                 '(:sibling
                   (:adjacent (:id "first") (:type "box"))
                   (:class "later")))))

(ert-deftest ebox-selector-queries-tree-by-id-class-and-type ()
  "Selector query should match metadata on the element tree."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :id root :class page
                  (box :id summary :class (card warning) "A")
                  (box :class card "B"))))
         (matches (ebox-selector-query-all node ".warning")))
    (should (= (length matches) 1))
    (should (equal (plist-get (car matches) :region-id)
                   (car (ebox-region-ids
                         (plist-get (car matches) :node)))))))

(ert-deftest ebox-selector-queries-child-and-descendant-paths ()
  "Selector query should support child and descendant combinators."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :class page
                  (row :class toolbar
                   (box :class action "Run"))
                  (box :class action "Loose")))))
    (should (= (length (ebox-selector-query-all node ".toolbar > box")) 1))
    (should (= (length (ebox-selector-query-all node ".page .action")) 2))))

(ert-deftest ebox-selector-queries-adjacent-and-general-siblings ()
  "Selector query should use TP sibling semantics on logical children."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :id first "A")
                  (box :id second :class later "B")
                  (box :id third :class later "C"))))
         (root (ebox-canonical-input--single-root node "selector test"))
         (source-index
          (ebox-tree-source-index
           root nil nil (ebox-canonical-input--source-index node))))
    (should (equal
             (mapcar (lambda (match)
                       (ebox-tree-node-id
                        source-index (plist-get match :node)))
                     (ebox-selector-query-all node "#first + #second"))
             '("second")))
    (should (equal
             (mapcar (lambda (match)
                       (ebox-tree-node-id
                        source-index (plist-get match :node)))
                     (ebox-selector-query-all node "#first ~ .later"))
             '("second" "third")))))

(ert-deftest ebox-selector-query-delegates-matching-to-ecss ()
  "Ebox should adapt nodes while ECSS remains the only matcher."
  (ebox-selector-test--reset-runtime-state)
  (let ((node (ebox-build
               '(column
                 (box :class card "A")
                 (box "B"))))
        (calls 0)
        (matcher (symbol-function 'ecss-selector-match-p)))
    (cl-letf (((symbol-function 'ecss-selector-match-p)
               (lambda (selector subject)
                 (cl-incf calls)
                 (funcall matcher selector subject))))
      (should (= (length (ebox-selector-query-all node ".card")) 1)))
    (should (> calls 0))))

(ert-deftest ebox-selector-subject-exposes-only-explicit-metadata ()
  "Selector adaptation should not serialize Ebox runtime containers."
  (let* ((opaque (vector (make-hash-table :test #'eq)))
         (input (ebox-test-box
                 :id 'card :class '(panel active)
                 :selector-state '(focused)
                 (ebox-test-text "visible") :width 12
                 :selector-attributes '((role . button) (rank . 3))))
         (node (ebox-test-root input))
         (_state (plist-put node :state opaque))
         (_cache (plist-put node :render-cache opaque))
         (source-index
          (ebox-tree-source-index
           node nil nil (ebox-test-source-index input)))
         (subject (ebox-tree-node-subject source-index node))
         (attributes (ecss-subject-attributes subject)))
    (should (equal (ecss-subject-classes subject) '("panel" "active")))
    (should (equal (ecss-subject-states subject) '("focused")))
    (should (equal (cdr (assoc "role" attributes)) "button"))
    (should (equal (cdr (assoc "rank" attributes)) "3"))
    (should-not (assoc "content" attributes))
    (should-not (assoc "width" attributes))
    (should-not (assoc "state" attributes))
    (should-not (assoc "render-cache" attributes))
    (should-not (assoc "ebox-type" attributes))))

(ert-deftest ebox-selector-queries-explicit-attributes ()
  "Attribute queries should read only explicit selector metadata."
  (let ((node (ebox-test-box
               (ebox-test-text "Run")
               :selector-attributes '((role . button)))))
    (should (= (length (ebox-selector-query-all node "[role=button]")) 1))
    (should-not (ebox-selector-query-all node "[content=Run]"))))

(ert-deftest ebox-selector-queries-rendered-buffer-runtime ()
  "Selector query should return handles owned by a rendered buffer."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :id summary :class card "Summary")
                  (box :class card "Other"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (let ((matches (ebox-selector-query-buffer buffer ".card")))
            (should (= (length matches) 2))
            (should (cl-every (lambda (match)
                                (and (plist-get match :node-id)
                                     (plist-get match :region-id)
                                     (eq (plist-get match :buffer) buffer)))
                              matches))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-buffer-id-query-uses-runtime-index ()
  "Rendered buffer #id queries should not walk the whole runtime tree."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :id summary :class card "Summary")
                  (box :class card "Other"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (cl-letf (((symbol-function 'ebox-tree-subject-index)
                     (lambda (&rest _)
                       (error "id query should use runtime index"))))
            (let ((matches (ebox-selector-query-buffer buffer "#summary")))
              (should (= (length matches) 1))
              (should (equal (plist-get (car matches) :buffer) buffer)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-buffer-class-query-uses-runtime-index ()
  "Rendered buffer .class queries should not walk the whole runtime tree."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :id summary :class (card warning) "Summary")
                  (box :class card "Other"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (cl-letf (((symbol-function 'ebox-tree-subject-index)
                     (lambda (&rest _)
                       (error "class query should use runtime index"))))
            (let ((matches (ebox-selector-query-buffer buffer ".card")))
              (should (= (length matches) 2))
              (should (cl-every (lambda (match)
                                  (equal (plist-get match :buffer) buffer))
                                matches)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-buffer-descendant-query-uses-runtime-index ()
  "Rendered buffer descendant class queries should start from indexed leaves."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :class page
                  (row :class toolbar
                   (box :class action "Run"))
                  (box :class action "Loose"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (cl-letf (((symbol-function 'ebox-tree-subject-index)
                     (lambda (&rest _)
                       (error "descendant query should use runtime index"))))
            (let ((matches (ebox-selector-query-buffer buffer ".page .action")))
              (should (= (length matches) 2))
              (should (cl-every (lambda (match)
                                  (plist-get match :region-id))
                                matches)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-buffer-index-preserves-author-form-types ()
  "Indexed queries should preserve typed author-form selector subjects."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :id shell
                  (box :class target "A")
                  (box "B"))))
         buffer)
    (unwind-protect
        (progn
          (should (= (length (ebox-selector-query-all
                              node "column .target"))
                     1))
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (let ((state (gethash buffer ebox--buffer-render-state-table)))
            (should (= (gethash
                        'column
                        (plist-get state :runtime-type-count-table))
                       1))
            (should (= (gethash
                        'box
                        (plist-get state :runtime-type-count-table))
                       2))
            (should (= (gethash
                        'text
                        (plist-get state :runtime-type-count-table))
                       2)))
          (should (= (length (ebox-selector-query-buffer
                              buffer "column .target"))
                     1)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-buffer-handles-survive-viewport-rerender ()
  "Selector query should resolve current handles after viewport rerender."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :id card
                       :wrap-mode word
                       "Text wraps when narrow"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (let ((ebox-viewport-width 360))
                         (ebox-render-to-buffer
                          (generate-new-buffer-name " *ebox-selector-test*")
                          node)))
          (let* ((before (car (ebox-selector-query-buffer buffer "#card")))
                 (node-id (plist-get before :node-id)))
            (ebox-rerender-buffer-with-context buffer 180)
            (let ((after (car (ebox-selector-query-buffer buffer "#card"))))
              (should (equal (plist-get after :node-id) node-id))
              (should (plist-get after :region-id)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-update-buffer-uses-paint-patch-for-paint-style ()
  "Selector updates should route paint-only changes through paint patches."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :id card :border "#111111" "Card"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (let* ((result (ebox-selector-update-buffer
                          buffer "#card" :border-color "#ef4444"))
                 (report (car (plist-get result :reports))))
            (should (eq (plist-get report :strategy) 'paint-patch))
            (should (equal (plist-get report :patch-ops) '(paint-patch)))
            (should (equal report (ebox-buffer-update-report buffer)))
            (should-not (plist-get report :full-rerender))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-update-buffer-adds-absent-properties ()
  "Selector updates should add valid box properties that were initially absent."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :id card "Card"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (let ((result (ebox-selector-update-buffer
                         buffer "#card" :padding '((lh 1) (ch 2)) :bgcolor "#fef3c7")))
            (should (= (plist-get result :matched) 1))
            (should (= (plist-get result :updated) 1)))
          (let* ((match (car (ebox-selector-query-buffer buffer "#card")))
                 (node (plist-get match :node)))
            (should (equal (ebox-get node :bgcolor) "#fef3c7"))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-width-unit-change-invalidates-render-cache ()
  "Changing width units should not reuse stale containing-block output."
  (ebox-selector-test--reset-runtime-state)
  (let (buffer char-widths live-widths direct-widths)
    (cl-letf (((symbol-function 'ebox--size-character-width)
               (lambda (&optional _box) 7)))
      (unwind-protect
          (let ((ebox-viewport-width 1200))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-selector-test*")
                   (ebox-build
                    (ebox-selector-test--width-unit-form '(px 550)))))
            (ebox-selector-update-buffer buffer "#root" :width '(ch 300))
            (setq char-widths
                  (with-current-buffer buffer
                    (ebox-selector-test--rendered-widths (buffer-string))))
            (ebox-selector-update-buffer buffer "#root" :width '(px 300))
            (with-current-buffer buffer
              (setq live-widths
                    (ebox-selector-test--rendered-widths
                     (buffer-substring (point-min) (point-max)))))
            (setq direct-widths
                  (ebox-selector-test--rendered-widths
                   (ebox-render
                    (ebox-build
                     (ebox-selector-test--width-unit-form '(px 300))))))
            (should-not (equal char-widths live-widths))
            (should (equal live-widths direct-widths)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer))))))

(ert-deftest ebox-selector-update-buffer-reports-target-buffer-direct-update ()
  "Single selector updates should return the target buffer's direct report."
  (ebox-selector-test--reset-runtime-state)
  (let* ((target-node (ebox-build
                       '(column
                         (box :id target-card "Target"))))
         (other-node (ebox-build
                      '(column
                        (box :id other-card "Other"))))
         target-buffer other-buffer)
    (unwind-protect
        (progn
          (setq target-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-selector-target*")
                 target-node))
          (setq other-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-selector-other*")
                 other-node))
          (let ((calls nil))
            (cl-letf (((symbol-function 'ebox-region-update)
                       (lambda (region-handle &rest _props)
                         (should (ebox-region-handle-p region-handle))
                         (let ((buffer
                                (car (ebox-selector--region-target
                                      region-handle))))
                           (push (cons region-handle buffer) calls)
                           (list :buffer buffer
                                 :region-handle region-handle
                                 :strategy 'stub-direct)))))
              (ebox-selector-update-buffer
               other-buffer "#other-card" :border-color "#0f766e")
              (let* ((result (ebox-selector-update-buffer
                              target-buffer "#target-card"
                              :border-color "#ef4444"))
                     (report (car (plist-get result :reports))))
                (should (eq (plist-get report :buffer) target-buffer))
                (should (eq (plist-get report :strategy) 'stub-direct))
                (should (eq (cdar calls) target-buffer))))))
      (when (and target-buffer (buffer-live-p target-buffer))
        (kill-buffer target-buffer))
      (when (and other-buffer (buffer-live-p other-buffer))
        (kill-buffer other-buffer)))))

(ert-deftest ebox-selector-update-buffer-does-not-write-handle-node-to-global-table ()
  "Selector updates should leave process-global region ownership unchanged."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :id card "Card"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (let* ((match (car (ebox-selector-query-buffer buffer "#card")))
                 (region-id (plist-get match :region-id))
                 (region-handle (plist-get match :region-handle))
                 (poisoned-entry (list :poisoned-region region-id)))
            (puthash region-id poisoned-entry ebox--region-box-table)
            (cl-letf (((symbol-function 'ebox-region-update)
                       (lambda (called-handle &rest _props)
                         (should (ebox-region-handle-p called-handle))
                         (should (equal
                                  (ebox-selector--region-target called-handle)
                                  (ebox-selector--region-target region-handle)))
                         (should (eq (gethash region-id ebox--region-box-table)
                                     poisoned-entry))
                         (list :strategy 'stub-direct))))
              (let* ((result (ebox-selector-update-buffer
                              buffer "#card" :border-color "#ef4444"))
                     (report (car (plist-get result :reports))))
                (should (eq (plist-get report :strategy) 'stub-direct))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-update-buffer-multi-match-uses-flush-return ()
  "Multi-match selector updates should report `ebox-incremental-flush' result."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :class card "One")
                  (box :class card "Two"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (let ((direct-reports nil)
                (flush-report (list :strategy 'stub-batch
                                    :patch-ops '(owner-rerender)
                                    :batched-count 2)))
            (cl-letf (((symbol-function 'ebox-region-update)
                       (lambda (region-handle &rest _props)
                         (should (ebox-region-handle-p region-handle))
                         (push (list :region-handle region-handle
                                     :strategy 'wrong-direct)
                               direct-reports)))
                      ((symbol-function 'ebox-incremental-flush)
                       (lambda (flush-buffer)
                         (should (eq flush-buffer buffer))
                         flush-report)))
              (let ((result (ebox-selector-update-buffer
                             buffer ".card" :border-color "#ef4444")))
                (should (= (plist-get result :updated) 2))
                (should (= (length direct-reports) 2))
                (should (equal (plist-get result :reports)
                               (list flush-report)))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-multi-match-publishes-one-scoped-generation ()
  "Multi-match updates should publish once through a scoped TP transaction."
  (ebox-selector-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :class card "One")
                  (box :class card "Two"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (ebox-render-to-buffer
                        (generate-new-buffer-name " *ebox-selector-test*")
                        node))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (revision (tp-surface-revision surface))
                 (result
                  (ebox-selector-update-buffer
                   buffer ".card" :border-color "#ef4444"))
                 (report (car (plist-get result :reports))))
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should-not (plist-get (tp-surface-report surface) :full-root))
            (should (= (plist-get report :flush-count) 1))
            (should (= (plist-get report :batched-count) 2))
            (should (equal report (ebox-buffer-update-report buffer)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(provide 'ebox-selector-tests)
;;; ebox-selector-tests.el ends here
