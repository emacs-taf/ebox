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
                         :selector-state (and disabled '(disabled))))
                (node (ebox-text-create
                       :value "Control" :source-handle handle
                       :owned-facts (ebox-canonical-facts-from-declarations 'text nil))))
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

(provide 'ebox-selector-tests)
;;; ebox-selector-tests.el ends here
