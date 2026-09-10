;;; ebox-display-tests.el --- Display integration tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'ebox)

(ert-deftest ebox-display-border-metrics-restore-on-unmount ()
  "Mounted borders keep the line grid without leaking redisplay settings."
  (let ((default-margin (default-value 'overline-margin)))
    (dolist (local-margin '(nil 7))
      (with-temp-buffer
        (when local-margin (setq-local overline-margin local-margin))
        (let ((input (ebox-build '(box :border "red" "Border"))))
          (ebox-render-to-buffer (current-buffer) input)
          (should (local-variable-p 'overline-margin))
          (should (zerop overline-margin))
          ;; Remounting must not replace the original setting with zero.
          (ebox-render-to-buffer (current-buffer) input)
          (should (zerop overline-margin))
          (ebox-unmount-buffer (current-buffer))
          (should (eq (local-variable-p 'overline-margin) (and local-margin t)))
          (should (= overline-margin (or local-margin default-margin))))))
    (should (= (default-value 'overline-margin) default-margin))))

(ert-deftest ebox-display-failed-mount-preserves-border-metrics ()
  "An unsuccessful initial publication must leave native metrics alone."
  (with-temp-buffer
    (setq-local overline-margin 7)
    (let ((tp--surface-publication-step-function
           (lambda (step _surface)
             (when (eq step 'client-state) (error "Reject initial mount")))))
      (should-error
       (ebox-render-to-buffer (current-buffer)
         (ebox-build '(box :border "red" "Border")))))
    (should (= overline-margin 7))
    (should-not ebox-buffer-mode)))

(ert-deftest ebox-display-invalid-input-preserves-windows ()
  "Invalid input must fail before changing the caller's window layout."
  (save-window-excursion
    (split-window-right)
    (let ((before (current-window-configuration))
          (buffer (generate-new-buffer " *ebox-invalid-display*")))
      (unwind-protect
          (progn
            (should-error (ebox-display-buffer buffer 'invalid-input))
            (should (compare-window-configurations
                     before (current-window-configuration))))
        (kill-buffer buffer)))))

(ert-deftest ebox-display-honors-native-display-action ()
  "The caller chooses the display window without changing selection."
  (save-window-excursion
    (let* ((selected (selected-window))
           (other (split-window-right))
           (buffer (generate-new-buffer " *ebox-display-action*"))
           (input (ebox-build '(box "Ready"))))
      (unwind-protect
          (progn
            (should
             (eq buffer
                 (ebox-display-buffer
                  buffer input
                  (list (lambda (target alist)
                          (let ((window (alist-get 'window alist)))
                            (set-window-buffer window target)
                            window))
                        (cons 'window other)))))
            (should (eq selected (selected-window)))
            (should (= 2 (length (window-list))))
            (should (eq buffer (window-buffer other)))
            (with-current-buffer buffer
              (should (string-match-p "Ready" (buffer-string)))
              (should ebox-buffer-mode)))
        (kill-buffer buffer)))))

(ert-deftest ebox-display-honors-display-buffer-alist ()
  "Native display rules also apply when no explicit action is supplied."
  (let ((buffer (generate-new-buffer " *ebox-display-rule*")) called)
    (unwind-protect
        (let ((display-buffer-alist
               (list (list (regexp-quote (buffer-name buffer))
                           (lambda (target _action)
                             (setq called target)
                             (selected-window))))))
          (should (eq buffer (ebox-display-buffer buffer (ebox-build "Ready"))))
          (should (eq buffer called)))
      (kill-buffer buffer))))

(ert-deftest ebox-display-delivers-the-target-viewport-intent ()
  "A newly displayed buffer uses the ordinary deferred viewport bridge."
  (let ((buffer (generate-new-buffer " *ebox-display-viewport*")) frame)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (_buffer _action) (selected-window)))
                  ((symbol-function 'ebox--window-size-change)
                   (lambda (target) (setq frame target))))
          (ebox-display-buffer buffer (ebox-build "Ready"))
          (should (eq frame (selected-frame))))
      (kill-buffer buffer))))

(provide 'ebox-display-tests)
;;; ebox-display-tests.el ends here
