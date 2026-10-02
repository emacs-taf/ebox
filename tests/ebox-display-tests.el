;;; ebox-display-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(ert-deftest ebox-display-native-decline-reports-missing-viewport ()
  "An unbounded mount renders normally and explains absent native geometry."
  (let ((ebox-viewport-width nil) (ebox-viewport-height nil) reports)
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer) (ebox-build '(box :width (ch 20) "Visible fallback"))
       (list :observer (lambda (_buffer report)
                         (when (eq (plist-get report :provider) 'ebox)
                           (push report reports)))))
      (should (string-match-p "Visible fallback" (buffer-string)))
      (should reports)
      (when (ebox-native-reflow-layout-ready-p)
        (should (eq (plist-get (plist-get (car reports) :native-declined-reason) :reason)
                    'viewport-context))
        (should-not (plist-get (car reports) :native-fallback-reason)))
      (ebox-rerender-buffer-with-context (current-buffer) 80 20)
      (should (string-match-p "Visible fallback" (buffer-string)))
      (should-not (plist-get (ebox-buffer-update-report (current-buffer))
                            :native-declined-reason)))))

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

(defun ebox-display--display-runs (string)
  "Return STRING's `display' property runs as (VALUE . LENGTH) pairs."
  (let ((position 0) (limit (length string)) runs)
    (while (< position limit)
      (let ((value (get-text-property position 'display string))
            (next (or (next-single-property-change
                       position 'display string limit)
                      limit)))
        (when value
          (push (cons value (- next position)) runs))
        (setq position next)))
    (nreverse runs)))

(ert-deftest ebox-display-inline-runs-wrap-like-one-text ()
  "The same content wraps identically whether one or several runs hold it."
  (dolist (width '(40 24 17))
    (let* ((text "中文与 words 内容更多一些的第二段文本，换行位置应当一致")
           (single-form (list 'box :width (list 'px width) :wrap-mode 'word text))
           (runs-form (list 'box :width (list 'px width) :wrap-mode 'word
                            (list 'text (substring text 0 8))
                            (list 'text (substring text 8 21))
                            (list 'text (substring text 21)))))
      (should (equal (substring-no-properties (ebox-render (ebox-build single-form)))
                     (substring-no-properties (ebox-render (ebox-build runs-form))))))))

(ert-deftest ebox-display-column-text-fills-the-column-width ()
  "A Column wraps a soft-wrapping Text item to the column content width."
  (let* ((ebox-viewport-width 92)
         (ebox-viewport-height 20)
         (text (concat "作者 ETAF Contributors  ·  日期 2026-10-03  ·  "
                       "版本 1.0.0  ·  许可 GPL-3.0-or-later  ·  状态 稳定"))
         (form (list 'column :width (list 'ch 92) (list 'text text)))
         projection)
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer) (ebox-build form)
       (list :observer (lambda (_buffer report)
                         (when (eq (plist-get report :provider) 'ebox)
                           (setq projection (plist-get report :projection-kind))))))
      (when (ebox-native-reflow-layout-ready-p)
        (should (eq projection 'native-frame)))
      (should (equal (substring-no-properties (buffer-string))
                     (substring-no-properties
                      (ebox-render (ebox-build form))))))))

(ert-deftest ebox-display-values-cross-the-native-boundary ()
  "Fixed pixel spaces and one-cell image slices stay identical through native."
  (let* ((char-width (max 1 (frame-char-width)))
         (line-height (max 1 (frame-char-height)))
         (png (base64-decode-string
               (concat "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
                       "AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")))
         (image (create-image png 'png t :width char-width :height line-height))
         (text (concat
                "A" (propertize " " 'display (list 'space :width (list 11)))
                "B" (propertize " " 'display
                                 (list (list 'slice 0 0 char-width line-height)
                                       image))
                "C"))
         (form (list 'box :width (list 'ch 40) :wrap-mode 'word text))
         projection)
    (with-temp-buffer
      (let ((ebox-viewport-width 40) (ebox-viewport-height 20))
        (ebox-render-to-buffer
         (current-buffer) (ebox-build form)
         (list :observer (lambda (_buffer report)
                           (when (eq (plist-get report :provider) 'ebox)
                             (setq projection (plist-get report :projection-kind)))))))
      (when (ebox-native-reflow-layout-ready-p)
        (should (eq projection 'native-frame)))
      (let ((reference (ebox-render (ebox-build form))))
        (should (equal (substring-no-properties (buffer-string))
                       (substring-no-properties reference)))
        (should (equal (ebox-display--display-runs (buffer-string))
                       (ebox-display--display-runs reference)))))))

(provide 'ebox-display-tests)
;;; ebox-display-tests.el ends here
