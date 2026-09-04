;;; ebox-m0a-characterization-tests.el --- M0a commit characterization -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'ebox-fixtures)

(define-error 'ebox-m0a-test-condition "M0a sentinel condition")

(ert-deftest ebox-m0a-success-return-preserves-framework-report-identity ()
  "One report moves from provisional publish to completed return in place."
  (let ((buffer (generate-new-buffer " *ebox-m0a-report-identity*"))
        seen provisional-state)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-test-box :key 'root (ebox-test-text "before")))
          (let ((returned
                 (ebox-commit
                  buffer
                  (ebox-test-box :key 'root (ebox-test-text "after"))
                  (lambda (report)
                    (setq seen report
                          provisional-state
                          (plist-get report :framework-participant-state))))))
            (should (eq provisional-state 'published))
            (should (eq seen returned))
            (should (eq (plist-get returned :framework-participant-state)
                        'completed))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-m0a-framework-failure-resignals-raw-condition-symbol-and-data ()
  "Framework failure keeps its original condition symbol and data payload."
  (let ((buffer (generate-new-buffer " *ebox-m0a-raw-condition*")) caught)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-test-box :key 'root (ebox-test-text "before")))
          (setq caught
                (condition-case condition
                    (ebox-commit
                     buffer
                     (ebox-test-box :key 'root (ebox-test-text "after"))
                     (lambda (_report)
                       (signal 'ebox-m0a-test-condition '(alpha 17))))
                  (ebox-m0a-test-condition condition)))
          (should (eq (car caught) 'ebox-m0a-test-condition))
          (should (equal (cdr caught) '(alpha 17))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-m0a-framework-rollback-receives-publish-report-object ()
  "Framework rollback receives the exact report passed to failed publish."
  (let ((buffer (generate-new-buffer " *ebox-m0a-rollback-identity*"))
        published rolled-back)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-test-box :key 'root (ebox-test-text "before")))
          (condition-case nil
              (ebox-commit
               buffer
               (ebox-test-box :key 'root (ebox-test-text "after"))
               (lambda (report)
                 (setq published report)
                 (error "reject"))
               (lambda (report) (setq rolled-back report)))
            (error nil))
          (should published)
          (should (eq published rolled-back))
          (should (eq (plist-get rolled-back :framework-participant-state)
                      'rolled-back)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'ebox-m0a-characterization-tests)

;;; ebox-m0a-characterization-tests.el ends here
