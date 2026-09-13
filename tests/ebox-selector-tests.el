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

(provide 'ebox-selector-tests)
;;; ebox-selector-tests.el ends here
