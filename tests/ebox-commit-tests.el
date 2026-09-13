;;; ebox-commit-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

;; These tests lock the named Elisp projection proofs.  Native commit has its
;; own focused contract tests below; disable runtime module discovery here so
;; a locally built optional module cannot silently replace paint/span/mixed
;; plans with `native-frame' and make this suite environment-dependent.
(defvar ebox-native-reflow-module-path)

(ert-deftest ebox-commit-updates-selector-type-counts ()
  "A structural candidate should publish exact author selector-type counts."
  (let* ((buffer
          (ebox-render-to-buffer
           (generate-new-buffer-name " *ebox-commit-types*")
           (ebox-build
            '(flex :key root :width (px 80)
                   (box :key child :width (px 40) "A")))))
         (before (gethash buffer ebox--buffer-render-state-table)))
    (unwind-protect
        (progn
          (should (= (gethash
                      'box (plist-get before :runtime-type-count-table))
                     1))
          (should (= (gethash
                      'flex (plist-get before :runtime-type-count-table))
                     1))
          (should (= (gethash
                      'text (plist-get before :runtime-type-count-table))
                     1))
          (ebox-commit
           buffer (ebox-build '(box :key root :width (px 80) "B")))
          (let ((after (gethash buffer ebox--buffer-render-state-table)))
            (should-not
             (gethash 'item (plist-get after :runtime-type-count-table)))
            (should-not
             (gethash 'flex (plist-get after :runtime-type-count-table)))
            (should (= (gethash
                        'box (plist-get after :runtime-type-count-table))
                       1))
            (should (= (gethash
                        'text (plist-get after :runtime-type-count-table))
                       1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'ebox-commit-tests)
;;; ebox-commit-tests.el ends here
