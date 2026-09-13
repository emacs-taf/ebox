;;; ebox-package-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defconst ebox-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by package contract tests.")

(ert-deftest ebox-native-command-autoloads-may-target-the-facade ()
  "Startup registries may safely autoload native commands from `ebox'."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (ecss (file-name-directory (locate-library "ecss")))
         (tp (file-name-directory (locate-library "tp"))))
    (with-temp-buffer
      (should
       (zerop
        (process-file
         emacs nil (current-buffer) nil
         "-Q" "--batch"
         "-L" ebox-test--root "-L" ecss "-L" tp
         "--eval" "(setq load-prefer-newer t)"
         "--eval"
         (concat
          "(progn "
          "(autoload 'ebox-native-status \"ebox\" nil t) "
          "(autoload 'ebox-native-build \"ebox\" nil t) "
          "(autoload-do-load (symbol-function 'ebox-native-status) "
          "                  'ebox-native-status) "
          "(unless (and (commandp 'ebox-native-status) "
          "             (commandp 'ebox-native-build)) "
          "  (error \"Facade did not define native commands\")) "
          ")")))))))

(provide 'ebox-package-tests)
;;; ebox-package-tests.el ends here
