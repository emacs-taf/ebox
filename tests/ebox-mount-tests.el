;;; -*- lexical-binding: t; -*-
;;; ebox-mount-tests.el --- Public mount-time observer acceptance

(require 'ert)
(require 'ebox)

(ert-deftest ebox-mount-observer-reports-first-flush-and-validates-before-replace ()
  "A mount observer sees initial paint and later writes; invalid options keep the mount."
  (with-temp-buffer
    (let ((text (ebox-text-create "First")) reports)
      (ebox-mount (current-buffer) text :width 200 :height 10
                  :observer (lambda (_buffer report) (push report reports)))
      (let ((report (car reports)))
        (should (eq (plist-get report :provider) 'ebox))
        (should (> (plist-get report :lines) 0))
        (should (numberp (plist-get report :duration-ms))))
      (setq reports nil)
      (ebox-node-set-text text "Second")
      (let ((report (car reports)))
        (should (> (plist-get report :lines) 0))
        (should (numberp (plist-get report :duration-ms))))
      (let ((failed (condition-case nil
                        (progn (ebox-mount (current-buffer) '(text "Invalid") :observer 42) nil)
                      (wrong-type-argument t)))
            (current (buffer-substring-no-properties (point-min) (point-max))))
        (should failed)
        (should (equal (string-trim current) "Second")))
      (ebox-node-set-text text "Still mounted")
      (let ((current (buffer-substring-no-properties (point-min) (point-max))))
        (should (equal (string-trim current) "Still mounted"))))))

(provide 'ebox-mount-tests)
