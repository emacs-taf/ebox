;;; ebox-publication-error-tests.el --- Printable publication failures -*- lexical-binding: t; -*-

;;; Commentary:
;; Rejected public updates must remain safe for Emacs's ordinary error printer.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-publication-error-test--scene ()
  "Build a positioned control whose callback retains a cyclic caller graph."
  (let* ((references (vector nil))
         (map (ebox-keymap-create :activate (lambda () (aref references 0)))))
    (aset references 0 map)
    (ebox-build
     `(box :width (px 160) :height (lh 6)
           (box :id "moving" :position absolute :left (px 2) :top (lh 1)
                :width (px 60) :height (lh 2) :z-index 1 :keymap ,map
                "Before")
           (box :id "peer" :position absolute :left (px 80) :top (lh 1)
                :width (px 60) :height (lh 2) :z-index 2 "Peer")))))

(defun ebox-publication-error-test--assert-printable (condition)
  "Print CONDITION under Emacs's ordinary unbounded error-reporting settings."
  (let* ((print-circle nil) (print-length nil) (print-level nil)
         (message (error-message-string condition))
         (timer-message (format "%S" condition)))
    (should (string-match-p "Ebox " message))
    (should (< (length message) 2048))
    (should (< (length timer-message) 2048))
    (should (equal-including-properties message (substring-no-properties message)))
    (should (equal-including-properties timer-message
                                       (substring-no-properties timer-message)))))

(ert-deftest ebox-publication-error-ordinary-output-rejection-is-printable ()
  "Ordinary hook corruption reports a bounded error and preserves the old mount."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-publication-error-test--scene))
      (let ((before (buffer-string))
            (revision (ebox-surface-buffer-revision (current-buffer)))
            (report (ebox-buffer-update-report (current-buffer)))
            (target (ebox-region-resolve (current-buffer) "moving"))
            (armed t))
        (add-hook 'after-change-functions
                  (lambda (start end _old-length)
                    (when (and armed (< start end))
                      (setq armed nil)
                      (let ((inhibit-read-only t))
                        (put-text-property start end 'display "Corrupted")))) nil t)
        (ebox-publication-error-test--assert-printable
         (should-error (ebox-region-update target :content "After") :type 'error))
        (should-not armed)
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal report (ebox-buffer-update-report (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (ebox-region-update target :content "Recovered")
        (should (string-match-p "Recovered" (buffer-substring-no-properties
                                              (point-min) (point-max))))))))

(ert-deftest ebox-publication-error-prepared-output-rejection-is-printable ()
  "Prepared stage corruption reports bounded diagnostics and permits a retry."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-publication-error-test--scene))
      (let* ((before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer)))
             (report (ebox-buffer-update-report (current-buffer)))
             (geometry (ebox-region-geometry "moving"))
             (reject t) (state 'before) (accepted 0)
             (operation
              (ebox-geometry-prepare
               (current-buffer) "moving" [:left]
               (lambda ()
                 (setq state 'after)
                 (when reject
                   (let ((inhibit-read-only t) (inhibit-modification-hooks t)
                         (buffer-undo-list t))
                     (put-text-property (point-min) (1+ (point-min))
                                        'display "Corrupted"))))
               (lambda () (setq state 'before))
               (lambda () (setq accepted (1+ accepted))))))
        (should operation)
        (ebox-publication-error-test--assert-printable
         (should-error (ebox-geometry-apply operation [(px 12)]) :type 'error))
        (should (eq state 'before))
        (should (= accepted 0))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal report (ebox-buffer-update-report (current-buffer))))
        (should (equal geometry (ebox-region-geometry "moving")))
        (should (equal-including-properties before (buffer-string)))
        (should (ebox-geometry-valid-p operation))
        (setq reject nil)
        (should (ebox-geometry-apply operation [(px 12)]))
        (should (eq state 'after))
        (should (= accepted 1))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))))))

(ert-deftest ebox-publication-error-preserves-caller-condition ()
  "Publication preserves application condition identity and rollback semantics."
  (dolist (rollback-failure '(nil t))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-build '(box "Before")))
      (let* ((payload (vector 'caller-owned))
             (data (list "Caller rejection" payload))
             (before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer)))
             restored
             (stage (lambda () (signal 'user-error data)))
             (rollback (lambda ()
                         (setq restored t)
                         (when rollback-failure
                           (user-error "Caller rollback failed"))))
             (condition
              (should-error
               (if rollback-failure
                   (ebox-with-transaction
                     (ebox-transaction-participate
                      :key 'caller :stage stage :rollback rollback))
                 (ebox-framework-spi-update
                  (current-buffer) (ebox-build '(box "After"))
                  (lambda (_report) (funcall stage))
                  (lambda (_report) (funcall rollback))))
               :type 'user-error)))
        (should (eq (car data) (cadr condition)))
        (should (eq payload (nth 2 condition)))
        (if rollback-failure
            (should (string-match-p "Caller rollback failed"
                                    (error-message-string condition)))
          (should (eq data (cdr condition))))
        (should restored)
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))))))

(ert-deftest ebox-publication-error-rollback-diagnostics-preserve-order ()
  "Several failed rollbacks retain ordered printable diagnostics and the primary type."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-build '(box "Before")))
    (let* ((before (buffer-string))
           (revision (ebox-surface-buffer-revision (current-buffer)))
           (payload (vector nil))
           (states (list (cons 'first 'before) (cons 'second 'before)
                         (cons 'reject 'before)))
           (primary (should-error
                     (ebox-with-transaction (ebox-unmount-buffer (current-buffer)))
                     :type 'error))
           restored)
      (aset payload 0 payload)
      (let ((condition
             (should-error
              (ebox-with-transaction
                (dolist (entry states)
                  (let ((entry entry))
                    (ebox-transaction-participate
                     :key (car entry)
                     :stage (lambda ()
                              (setcdr entry 'after)
                              (when (eq (car entry) 'reject)
                                (ebox-unmount-buffer (current-buffer))))
                     :rollback (lambda ()
                                 (setcdr entry 'before)
                                 (setq restored (append restored (list (car entry))))
                                 (signal 'user-error
                                         (list (format "Rollback %s" (car entry))
                                               payload)))))))
              :type 'error)))
        (should (eq (car primary) (car condition)))
        (ebox-publication-error-test--assert-printable condition)
        (let ((message (error-message-string condition)))
          (should (string-match-p "Rollback reject.*Rollback second.*Rollback first"
                                  message))))
      (should (equal restored '(reject second first)))
      (should (equal states '((first . before) (second . before) (reject . before))))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (equal-including-properties before (buffer-string))))))

(ert-deftest ebox-publication-error-rollback-diagnostics-remain-printable ()
  "Secondary rollback errors cannot reintroduce cyclic data into rejection."
  (dolist (prepared '(nil t))
    (let ((ebox-viewport-width 160) (ebox-viewport-height 12))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) (ebox-publication-error-test--scene))
        (let* ((before (buffer-string))
               (revision (ebox-surface-buffer-revision (current-buffer)))
               (report (ebox-buffer-update-report (current-buffer)))
               (payload (vector nil))
               (state 'before)
               (stage (lambda (&rest _)
                        (setq state 'after)
                        (let ((inhibit-read-only t) (inhibit-modification-hooks t)
                              (buffer-undo-list t))
                          (put-text-property (point-min) (1+ (point-min))
                                             'display "Corrupted"))))
               (rollback (lambda (&rest _)
                           (setq state 'before)
                           (signal 'user-error (list "Rollback failed" payload)))))
          (aset payload 0 payload)
          (let ((condition
                 (if prepared
                     (let ((operation (ebox-geometry-prepare
                                       (current-buffer) "moving" [:left] stage rollback)))
                       (should operation)
                       (should-error (ebox-geometry-apply operation [(px 12)]) :type 'error))
                   (should-error
                    (ebox-with-transaction
                      (ebox-transaction-participate
                       :key payload
                       :stage (lambda ()
                                (setq state 'after)
                                (ebox-unmount-buffer (current-buffer)))
                       :rollback rollback))
                    :type 'error))))
            (ebox-publication-error-test--assert-printable condition)
            (should (string-match-p "Rollback failed" (error-message-string condition))))
          (should (eq state 'before))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal report (ebox-buffer-update-report (current-buffer))))
          (should (equal-including-properties before (buffer-string)))
          (ebox-region-update "moving" :content "Recovered")
          (should (string-match-p "Recovered" (buffer-substring-no-properties
                                                (point-min) (point-max)))))))))

(provide 'ebox-publication-error-tests)
;;; ebox-publication-error-tests.el ends here
