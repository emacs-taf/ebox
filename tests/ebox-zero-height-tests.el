;;; ebox-zero-height-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(ert-deftest ebox-zero-height-retained-surface-empty-content-transitions ()
  (dolist (initial '((box :id "root")
                     (column :id "root" (box :id "child"))))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-build initial))
      (should (equal (buffer-string) ""))
      (let ((revision (ebox-surface-buffer-revision (current-buffer))))
        (dolist (content '("A\nB" "" "C" ""))
          (let ((input
                 (ebox-build
                  (if (eq (car initial) 'column)
                      `(column :id "root" (box :id "child" ,content))
                    `(box :id "root" ,content)))))
            (ebox-commit (current-buffer) input)
            (should (> (ebox-surface-buffer-revision (current-buffer)) revision))
            (setq revision (ebox-surface-buffer-revision (current-buffer)))
            (should (equal (buffer-string) content))
            (should (equal (buffer-string)
                           (substring-no-properties (ebox-render input)))))))
      (ebox-unmount-buffer (current-buffer)))))

(ert-deftest ebox-zero-height-retained-surface-transition-rollback ()
  (dolist (contents '(("" "Added") ("Removed" "")))
    (with-temp-buffer
      (let ((before (ebox-build `(box :id "root" ,(car contents))))
            (after (ebox-build `(box :id "root" ,(cadr contents)))))
        (ebox-render-to-buffer (current-buffer) before)
        (let ((revision (ebox-surface-buffer-revision (current-buffer)))
              (rendered (buffer-string)))
          (should-error
           (ebox-commit (current-buffer) after
                        (lambda (_report) (error "Reject height transition"))))
          (should (= (ebox-surface-buffer-revision (current-buffer)) revision))
          (should (equal-including-properties (buffer-string) rendered))
          (ebox-commit (current-buffer) after)
          (should (equal (buffer-string) (cadr contents))))
        (ebox-unmount-buffer (current-buffer))))))

(provide 'ebox-zero-height-tests)
;;; ebox-zero-height-tests.el ends here
