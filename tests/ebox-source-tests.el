;;; ebox-source-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(ert-deftest ebox-canonical-range-construction-has-explicit-source-ownership ()
  "Typed Range construction needs only a public builder, with exact ownership."
  (let* ((builder (ebox-source-builder-create))
         (box-handle (ebox-source-builder-bind builder :identity 'range-parent))
         (text-handle (ebox-source-builder-bind builder :identity 'range-text :key 'first))
         (text (ebox-text-create
                :value "explicit range" :source-handle text-handle
                :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (arguments
          (list :layout (ebox-normal-layout-create)
                :children (list (ebox-child-range 'items text))
                :source-handle box-handle
                :owned-facts (ebox-canonical-facts-from-declarations 'box nil))))
    (should-error (apply #'ebox-box-create arguments))
    (should-error
     (apply #'ebox-box-create :source-builder (ebox-source-builder-create) arguments))
    (let* ((node (apply #'ebox-box-create :source-builder builder arguments))
           (input (ebox-canonical-input-create
                   (list node) (ebox-source-builder-finish builder))))
      (should (eq text-handle
                  (ebox-node-source-handle (car (ebox-box-node-children node)))))
      (should (equal '((:ref items :before 0 :after 1))
                     (ebox-box-node-range-anchors node)))
      (should (string-match-p "explicit range" (ebox-render input)))
      (should-error (apply #'ebox-box-create :source-builder builder arguments)))))

(ert-deftest ebox-canonical-builder-validates-empty-ranges-and-static-siblings ()
  "Empty ranges retain ownership, and static siblings cannot borrow foreign facts."
  (let* ((builder (ebox-source-builder-create))
         (foreign (ebox-source-builder-create))
         (parent (ebox-source-builder-bind builder :identity 'parent))
         (foreign-parent (ebox-source-builder-bind foreign :identity 'foreign-parent))
         (foreign-text
          (ebox-text-create
           :value "foreign" :source-handle
           (ebox-source-builder-bind foreign :identity 'foreign-text)
           :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (arguments (list :layout (ebox-normal-layout-create)
                          :source-handle parent
                          :owned-facts (ebox-canonical-facts-from-declarations 'box nil))))
    (should-error
     (apply #'ebox-box-create :children (list (ebox-child-range 'empty)) arguments))
    (should-error
     (apply #'ebox-box-create :source-builder builder
            :children (list (ebox-child-range 'empty) foreign-text) arguments))
    (should-error
     (ebox-box-create :layout (ebox-normal-layout-create)
                      :source-builder builder :source-handle foreign-parent
                      :owned-facts (ebox-canonical-facts-from-declarations 'box nil)))
    (let ((node (apply #'ebox-box-create :source-builder builder
                       :children (list (ebox-child-range 'empty)) arguments)))
      (should (equal '((:ref empty :before 0 :after 0))
                     (ebox-box-node-range-anchors node)))
      (should-not (memq builder node))
      (ebox-source-builder-finish builder)
      (should-error
       (apply #'ebox-box-create :source-builder builder
              :children (list (ebox-child-range 'empty)) arguments)))))

(provide 'ebox-source-tests)
;;; ebox-source-tests.el ends here
