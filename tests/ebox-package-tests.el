;;; ebox-package-tests.el --- Package contract tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(defconst ebox-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by package contract tests.")

(load-file (expand-file-name "ebox.el" ebox-test--root))

(ert-deftest ebox-package-defines-custom-group-and-scroll-option ()
  "The package exposes a real customization group and default scroll option."
  (should (get 'ebox 'custom-group))
  (should (custom-variable-p 'ebox-scroll-step))
  (should (integerp ebox-scroll-step))
  (should (> ebox-scroll-step 0))
  (should (custom-variable-p 'ebox-wheel-scroll-step))
  (should (integerp ebox-wheel-scroll-step))
  (should (> ebox-wheel-scroll-step 0))
  (should (custom-variable-p 'ebox-wheel-smooth-scroll))
  (should (custom-variable-p 'ebox-wheel-smooth-scroll-interval))
  (should (numberp ebox-wheel-smooth-scroll-interval))
  (should (> ebox-wheel-smooth-scroll-interval 0))
  (should (custom-variable-p 'ebox-wheel-smooth-scroll-lines-per-tick))
  (should (integerp ebox-wheel-smooth-scroll-lines-per-tick))
  (should (> ebox-wheel-smooth-scroll-lines-per-tick 0)))

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

(ert-deftest ebox-byte-compile-rebuilds-the-declared-source-set ()
  "The interactive command should recompile every declared source in order."
  (require 'bytecomp)
  (let (compiled)
    (unwind-protect
        (cl-letf (((symbol-function 'byte-compile-file)
                   (lambda (file &optional _load)
                     (push (file-relative-name file ebox--directory) compiled)
                     t))
                  ((symbol-function 'message) #'ignore))
          (should (ebox-byte-compile))
          (should (equal (nreverse compiled) ebox--compile-sources)))
      (when-let* ((buffer (get-buffer "*Ebox Byte Compile*")))
        (kill-buffer buffer)))))

(ert-deftest ebox-package-includes-native-build-source ()
  "Source-only distribution should contain every native build input."
  (dolist (file '("native/Cargo.toml"
                  "native/Cargo.lock"
                  "native/build.rs"
                  "native/src/lib.rs"
                  "native/src/layout.rs"
                  "native/c/ebox_module.c"
                  "native/vendor/emacs-30/emacs-module.h"))
    (should (file-readable-p (expand-file-name
       (if (and (string-suffix-p ".el" file) (not (file-name-directory file)))
           (concat "lisp/" file) file) ebox-test--root)))))

(provide 'ebox-package-tests)
;;; ebox-package-tests.el ends here
