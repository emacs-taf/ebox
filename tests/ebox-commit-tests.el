;;; ebox-commit-tests.el --- Declarative commit smoke tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defun ebox-commit-test--buffer-string (buffer)
  "Return BUFFER's complete propertized contents."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (buffer-substring (point-min) (point-max)))))

(ert-deftest ebox-commit-publishes-content-change ()
  "A declarative commit should publish changed content."
  (let* ((buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-commit-content*")
                  (ebox-create :key 'root :content "Before" :width '(80))))
         (report (ebox-commit
                  buffer
                  (ebox-create :key 'root :content "After" :width '(80)))))
    (unwind-protect
        (progn
          (should (string-prefix-p
                   "After"
                   (string-trim-right
                    (substring-no-properties
                     (ebox-commit-test--buffer-string buffer)))))
          (should (plist-get report :runtime-published))
          (should (> (plist-get report :patch-count) 0)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-preserves-keyed-sibling-identity ()
  "Keyed siblings should remain addressable after a reorder commit."
  (let* ((buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-commit-keyed*")
                  (ebox-column
                   (ebox-create :key 'a :host-ref 'a :content "A" :width '(40))
                   (ebox-create :key 'b :host-ref 'b :content "B" :width '(40)))))
         (old-b (ebox-host-ref-position buffer 'b))
         (report (ebox-commit
                  buffer
                  (ebox-column
                   (ebox-create :key 'b :host-ref 'b :content "B2" :width '(40))
                   (ebox-create :key 'a :host-ref 'a :content "A" :width '(40))))))
    (unwind-protect
        (progn
          (should old-b)
          (should (ebox-host-ref-position buffer 'b))
          (should (plist-get report :runtime-published))
          (should (string-match-p "B2"
                                  (substring-no-properties
                                   (ebox-commit-test--buffer-string buffer)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-updates-raw-runtime-type-counts ()
  "A structural candidate should publish exact raw runtime type counts."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-commit-types*")
           (ebox-build
            '(flex :key root :width (80)
                   (item (box :key child :content "A" :width (40)))))))
         (before (gethash buffer ebox--buffer-render-state-table)))
    (unwind-protect
        (progn
          (should (= (gethash
                      'item (plist-get before :runtime-type-count-table))
                     1))
          (ebox-commit
           buffer (ebox-create :key 'root :content "B" :width '(80)))
          (let ((after (gethash buffer ebox--buffer-render-state-table)))
            (should-not
             (gethash 'item (plist-get after :runtime-type-count-table)))
            (should (= (gethash
                        'box (plist-get after :runtime-type-count-table))
                       1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-rolls-back-on-invalid-root ()
  "A failed candidate must leave the previously published buffer intact."
  (let ((buffer (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-commit-rollback*")
                 (ebox-create :key 'root :content "Stable" :width '(80)))))
    (unwind-protect
        (progn
          (should-error
           (ebox-commit buffer (ebox-create :key 'root :content nil
                                             :width 'invalid)))
          (should (string-prefix-p
                   "Stable"
                   (string-trim-right
                    (substring-no-properties
                     (ebox-commit-test--buffer-string buffer))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'ebox-commit-tests)

;;; ebox-commit-tests.el ends here
