;;; ebox-selector-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

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

(ert-deftest ebox-selector-canonical-metadata-commit-refreshes-tree-queries ()
  "Queries read accepted attributes and states after a metadata-only commit."
  (cl-labels
      ((input (disabled)
         (let* ((builder (ebox-source-builder-create))
                (handle (ebox-source-builder-bind
                         builder :identity 'control :id 'control
                         :selector-attributes (list (cons :role (if disabled 'checkbox 'button)))
                         :interactions (list :disabled disabled)))
                (node (ebox-text-create
                       :value "Control" :source-handle handle
                       :owned-facts (ebox-canonical-facts-from-declarations
                                     'text nil (list :disabled disabled)))))
           (ebox-canonical-input-create
            (list node) (ebox-source-builder-finish builder)))))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (input nil))
      (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "[role=button]"))))
      (ebox-commit (current-buffer) (input t))
      (dolist (selector '("[role=checkbox]" ":disabled" "#control:disabled"))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) selector)))))
      (should-not (ebox-selector-query-buffer (current-buffer) "[role=button]"))
      (ebox-commit (current-buffer) (input nil))
      (should-not (ebox-selector-query-buffer (current-buffer) ":disabled"))
      (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "[role=button]")))))))

(defun ebox-selector-test--disabled-input (disabled)
  "Build a control whose state styles itself, descendants and a sibling."
  (ebox-build
   (list 'column :ecss
         '(("#control" :color "#111111")
           ("#control:disabled" :color "#999999")
           ("#control:disabled > text" :color "#888888")
           ("#control:disabled + text" :color "#777777"))
         (list 'box :id 'control :key 'control :disabled disabled
               :states '(checked) :tab-index 0
               '(text :id label "Label"))
         '(text :id sibling "Sibling"))))

(defun ebox-selector-test--colors (text)
  "Return observable foregrounds for Label and Sibling in TEXT."
  (mapcar (lambda (word)
            (plist-get (get-text-property (string-match word text) 'face text)
                       :foreground))
          '("Label" "Sibling")))

(ert-deftest ebox-disabled-state-drives-pure-and-retained-cascade ()
  "Disabled facts invalidate own, descendant and sibling rules without a keymap."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-selector-test--disabled-input nil))
    (dolist (disabled '(t nil t nil))
      (ebox-region-update "control" :disabled disabled)
      (should (equal (ebox-selector-test--colors (buffer-string))
                     (ebox-selector-test--colors
                      (ebox-render (ebox-selector-test--disabled-input disabled)))))
      (should (= (length (ebox-selector-query-buffer (current-buffer) ":disabled"))
                 (if disabled 1 0)))
      (should (= 1 (length (ebox-selector-query-buffer
                           (current-buffer) "#control:checked"))))
      (when disabled
        (should (equal (ebox-selector-test--colors (buffer-string))
                       '("#888888" "#777777")))))))

(ert-deftest ebox-disabled-state-rejected-commit-restores-style-and-focus ()
  "Rejected state publication restores selectors, paint and focus together."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-selector-test--disabled-input nil))
    (let* ((ref (ebox-focus-first))
           (colors (ebox-selector-test--colors (buffer-string))))
      (should-error
       (ebox-commit (current-buffer) (ebox-selector-test--disabled-input t)
                    (lambda (_report) (error "Reject disabled candidate"))))
      (should (equal ref (ebox-focused-host-ref)))
      (should-not (ebox-selector-query-buffer (current-buffer) ":disabled"))
      (should (equal colors (ebox-selector-test--colors (buffer-string))))
      (ebox-commit (current-buffer) (ebox-selector-test--disabled-input t))
      (should-not (ebox-focused-host-ref))
      (should (= 1 (length (ebox-selector-query-buffer (current-buffer) ":disabled")))))))

(ert-deftest ebox-disabled-state-rejects-authored-duplicates ()
  "Only interaction input may declare the disabled state, in DSL and typed input."
  (dolist (states '(disabled "disabled" (checked disabled) ("disabled")))
    (should-error (ebox-build (list 'text :states states "Invalid")))
    (should-error (ebox-source-builder-bind (ebox-source-builder-create)
                                            :selector-state states)))
  (should (= 1 (length (ebox-selector-query-all
                       (ebox-build '(text :disabled t :states checked "Valid"))
                       "text:disabled:checked")))))

(ert-deftest ebox-selector-candidates-preserve-relations-and-rollback ()
  "Repeated subtree changes keep ancestry, siblings and old snapshots coherent."
  (let ((rules '(("&" :color "#111111")
                 ("&:has(.ready)" :color "#222222")
                 ("#flag.ready + #sibling" :color "#333333")
                 ("#flag > text:nth-child(2)" :color "#444444"))))
    (cl-labels
        ((branch (ready extra)
           `(column :id flag :key flag :class ,(if ready 'ready 'idle)
                    (text :id first :key first "First")
                    ,@(when extra '((text :id second :key second "Second")))))
         (input (ready extra)
           (ebox-build `(column :width (ch 30) :ecss ,rules
                                ,(branch ready extra)
                                (text :id sibling :key sibling "Sibling"))))
         (shape (text)
           (list (substring-no-properties text)
                 (cl-loop for position below (length text)
                          collect (list (get-text-property position 'display text)
                                        (get-text-property position 'face text))))))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) (input nil nil))
        (let* ((id (plist-get (car (ebox-selector-query-buffer
                                   (current-buffer) "#flag")) :node-id))
               (snapshot (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
               (initial (shape (ebox-render snapshot))))
          ;; Resolve once: later commits must work without intervening queries.
          (dotimes (index 12)
            (let* ((ready (= (% index 2) 0))
                   (extra (= (% index 3) 0))
                   (candidate (ebox-candidate-begin (current-buffer)))
                   (before (shape (buffer-string))))
              (ebox-candidate-replace candidate id (ebox-build (branch ready extra)))
              (when (= index 4)
                (should-error
                 (ebox-commit (current-buffer) candidate
                              (lambda (_report) (error "Reject candidate"))))
                (should (equal before (shape (buffer-string))))
                (setq candidate (ebox-candidate-begin (current-buffer)))
                (ebox-candidate-replace candidate id (ebox-build (branch ready extra))))
              (ebox-commit (current-buffer) candidate)
              (should (equal (shape (buffer-string))
                             (shape (ebox-render (input ready extra)))))
              (should (equal initial (shape (ebox-render snapshot))))))
          (should (= 1 (length (ebox-selector-query-buffer
                               (current-buffer) "#flag.idle + #sibling"))))
          (should-not (ebox-selector-query-buffer (current-buffer) "#second")))))))

(ert-deftest ebox-scoped-candidates-combine-content-and-selector-paint ()
  "A paint-only class change and adjacent text publish one coherent result."
  (cl-labels
      ((nodes (active)
         (list `(box :id content :class value ,(if active "After!" "Before"))
               `(box :id control :class ,(if active '(control active) '(control inactive))
                     "Control")))
       (input (active)
         (ebox-build
          `(column :width (ch 40)
                   :ecss ((".value" :width (ch 8))
                          (".control" :width (ch 10))
                          (".control.inactive" :color "#777777")
                          (".control.active" :color "#2255aa"))
                   (row :width (ch 40) ,@(nodes active))
                   (text "Untouched"))))
       (visible (text)
         (list (substring-no-properties text)
               (cl-loop for position below (length text)
                        collect (list (get-text-property position 'display text)
                                      (get-text-property position 'face text))))))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (input nil))
      (let ((ids (mapcar (lambda (selector)
                          (plist-get (car (ebox-selector-query-buffer
                                           (current-buffer) selector)) :node-id))
                        '("#content" "#control"))))
        (dolist (active '(t nil t nil))
          (ebox-buffer-set-observer (current-buffer) (and active #'ignore))
          (let ((candidate (ebox-candidate-begin (current-buffer))))
            (cl-mapc (lambda (id node)
                       (ebox-candidate-replace candidate id (ebox-build node)))
                     ids (nodes active))
            (ebox-commit (current-buffer) candidate))
          (should (equal (visible (buffer-string))
                         (visible (ebox-render (input active)))))
          (let* ((report (ebox-buffer-update-report (current-buffer)))
                 (saved (copy-tree report))
                 (rejections (plist-get report :projection-rejections)))
            (unless active (should-not rejections))
            (dolist (attempt rejections)
              (should (symbolp (plist-get attempt :projection)))
              (should (cl-every #'symbolp (plist-get attempt :reasons))))
            ;; Diagnostic values share the report's defensive-copy and
            ;; last-successful-publication contract.
            (when rejections (setcar rejections 'changed-by-reader))
            (should (equal saved (ebox-buffer-update-report (current-buffer))))
            (should-error (ebox-region-update 'control :width '(px -1)))
            (should (equal saved (ebox-buffer-update-report (current-buffer))))))))))

(ert-deftest ebox-selector-located-batch-composes-local-content-updates ()
  "Located content changes compose one scoped batch and failed batches discard."
  (cl-labels
      ((input (value)
         (ebox-build
          `(column :width (ch 20)
                   (box :key first :class located :width (ch 20) ,value)
                   (box :key second :class located :width (ch 20) ,value)
                   (box :key retained :width (ch 20) "Untouched"))))
       (shape (text)
         (list (substring-no-properties text)
               (vconcat
                (cl-loop for index below (length text)
                         collect (list (get-text-property index 'display text)
                                       (get-text-property index 'face text)))))))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (input "Before"))
      (let* ((matches (ebox-selector-query-buffer
                       (current-buffer) ".located"))
             (before (shape (buffer-string))))
        (should-error
         (ebox-call-with-update-batch
          (lambda ()
            (dolist (match matches)
              (ebox-region-update (plist-get match :region-handle)
                                  :content "After!"))
            (ebox-region-update "absent" :content "Rejected"))
          (current-buffer)))
        (should (equal before (shape (buffer-string)))))
      (let* ((summary
              (ebox-selector-update-buffer
               (current-buffer) ".located" :content "After!"))
             (report (ebox-buffer-update-report (current-buffer))))
        (should (= 2 (plist-get summary :matched)))
        (should (= 2 (plist-get summary :updated)))
        (should (equal (shape (buffer-string))
                       (shape (ebox-render (input "After!")))))
        (should (string-match-p "Untouched" (buffer-string)))
        (should (eq 'span-patch (plist-get report :projection-kind)))
        (should (= 2 (plist-get report :dirty-count)))
        (should (= 2 (plist-get report :patch-count)))))))

(provide 'ebox-selector-tests)
;;; ebox-selector-tests.el ends here
