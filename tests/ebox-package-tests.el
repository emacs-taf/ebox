;;; ebox-package-tests.el --- Package contract tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(defconst ebox-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by package contract tests.")

(load-file (expand-file-name "ebox.el" ebox-test--root))

(defconst ebox-test--autoload-source-files
  '("ebox.el"
    "ebox-measure.el"
    "ebox-layout.el"
    "ebox-flex.el"
    "ebox-grid.el"
    "ebox-selector.el"
    "ebox-native-reflow.el")
  "Source files that currently own public autoload entry points.")

(defun ebox-test--source-text ()
  "Return combined source text for files that own public autoloads."
  (with-temp-buffer
    (dolist (file ebox-test--autoload-source-files)
      (insert-file-contents (expand-file-name file ebox-test--root))
      (insert "\n"))
    (buffer-string)))

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

(ert-deftest ebox-facade-loads-internal-model-modules ()
  "The public ebox facade should load all internal foundation modules."
  (require 'ebox)
  (dolist (feature '(ebox-cache ebox-style ebox-tree ebox-measure
                                ebox-fragment ebox-layout ebox-flex ebox-grid
                                ebox-buffer-backend ebox-incremental
                                ebox-surface ebox-dsl ebox-selector))
    (should (featurep feature))))

(ert-deftest ebox-facade-exposes-native-workflow-without-loading-it ()
  "The two native commands should be available without native load work."
  (require 'ebox)
  (should (autoloadp (symbol-function 'ebox-native-build)))
  (should (autoloadp (symbol-function 'ebox-native-status)))
  (should-not (featurep 'ebox-native-reflow)))

(ert-deftest ebox-byte-compile-is-an-interactive-public-command ()
  "Users should be able to rebuild all active Ebox bytecode from Emacs."
  (should (commandp 'ebox-byte-compile))
  (should
   (equal ebox--compile-sources
          '("ebox-cache.el" "ebox-style.el" "ebox-tree.el" "ebox-measure.el"
            "ebox-fragment.el" "ebox-render-context.el" "ebox-layout.el"
            "ebox-flex.el" "ebox-grid.el" "ebox-buffer-backend.el" "ebox-incremental.el"
            "ebox-surface.el" "ebox-dsl.el" "ebox-selector.el" "ebox.el"
            "ebox-native-reflow.el"))))

(ert-deftest ebox-surface-depends-only-on-public-tp-api ()
  "The Ebox projection boundary should never call private TP symbols."
  (let ((source
         (with-temp-buffer
           (insert-file-contents
            (expand-file-name "ebox-surface.el" ebox-test--root))
           (buffer-string))))
    (should-not (string-match-p "\\_<tp--" source))))

(ert-deftest ebox-css-semantics-depend-only-on-public-ecss-api ()
  "Selectors and cascade must come from ECSS rather than TP or Ebox copies."
  (let ((source
         (with-temp-buffer
           (dolist (file '("ebox-style.el" "ebox-tree.el" "ebox-selector.el"))
             (insert-file-contents (expand-file-name file ebox-test--root))
             (insert "\n"))
           (buffer-string))))
    (should-not
     (string-match-p
      "\\_<tp-\\(?:subject\\|selector\\|stylesheet\\|compute-style\\|computed-style\\)"
      source))
    (should-not (string-match-p "\\_<ecss--" source))))

(ert-deftest ebox-byte-compile-rebuilds-the-declared-source-set ()
  "The interactive command should recompile every declared source in order."
  (require 'bytecomp)
  (let (compiled)
    (unwind-protect
        (cl-letf (((symbol-function 'byte-compile-file)
                   (lambda (file &optional _load)
                     (push (file-name-nondirectory file) compiled)
                     t))
                  ((symbol-function 'message) #'ignore))
          (should (ebox-byte-compile))
          (should (equal (nreverse compiled) ebox--compile-sources)))
      (when-let ((buffer (get-buffer "*Ebox Byte Compile*")))
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
    (should (file-readable-p (expand-file-name file ebox-test--root)))))

(ert-deftest ebox-public-entry-points-have-autoload-cookies ()
  "Stable public entry points should be discoverable by package autoloads."
  (let ((source (ebox-test--source-text)))
    (dolist (entry '(("ebox-clear-cache" . "defun")
                     ("ebox-render" . "defun")
                     ("ebox-region-ids" . "defun")
                     ("ebox-concat" . "defun")
                     ("ebox-spacer" . "defun")
                     ("ebox-row" . "defun")
                     ("ebox-stack" . "defun")
                     ("ebox-column" . "defun")
                     ("ebox-flex-item" . "defun")
                     ("ebox-flex" . "defun")
                     ("ebox-grid-fr" . "defun")
                     ("ebox-grid-item" . "defun")
                     ("ebox-grid" . "defun")
                     ("ebox-build" . "defun")
                     ("ebox-create" . "defun")
                     ("ebox-scroll-down" . "defun")
                     ("ebox-scroll-up" . "defun")
                     ("ebox-region-update" . "defun")
                     ("ebox-region-resolve" . "defun")
                     ("ebox-buffer-update-report" . "defun")
                     ("ebox-byte-compile" . "defun")
                     ("ebox-native-build" . "defun")
                     ("ebox-native-status" . "defun")
                     ("ebox-buffer-mode" . "define-minor-mode")
                     ("ebox-render-to-buffer" . "defun")
                     ("ebox-display-buffer" . "defun")))
      (should
       (string-match-p
        (format ";;;###autoload[[:space:]\n]+(%s %s\\_>"
                (regexp-quote (cdr entry))
                (regexp-quote (car entry)))
        source)))))

(ert-deftest ebox-public-api-includes-all-public-autoloaded-entry-points ()
  "The facade inventory should not omit an autoloaded public entry point."
  (dolist (entry '(ebox-byte-compile
                   ebox-buffer-update-report
                   ebox-build
                   ebox-buffer-mode
                   ebox-candidate-begin
                   ebox-candidate-replace
                   ebox-candidate-replace-host-ref
                   ebox-clear-cache
                   ebox-column
                   ebox-commit
                   ebox-concat
                   ebox-create
                   ebox-display-buffer
                   ebox-display-signature
                   ebox-flex
                   ebox-flex-item
                   ebox-grid
                   ebox-grid-fr
                   ebox-grid-item
                   ebox-host-ref-bounds
                   ebox-host-ref-position
                   ebox-native-build
                   ebox-native-status
                   ebox-region-ids
                   ebox-region-resolve
                   ebox-region-update
                   ebox-render
                   ebox-render-to-buffer
                   ebox-rerender-buffer-with-context
                   ebox-row
                   ebox-scroll-down
                   ebox-scroll-page-down
                   ebox-scroll-page-up
                   ebox-scroll-state
                   ebox-scroll-up
                   ebox-selector-match-node-p
                   ebox-selector-parse
                   ebox-selector-query-all
                   ebox-selector-query-buffer
                   ebox-selector-update-buffer
                   ebox-spacer
                   ebox-stack
                   ebox-string-pixel-width))
    (should (memq entry ebox-public-api))))

(ert-deftest ebox-live-buffer-publication-uses-only-tp-surfaces ()
  "The facade should expose no raw live-buffer writer beside TP surfaces."
  (require 'ebox)
  (dolist (entry '(ebox-render-to-buffer ebox-display-buffer))
    (should (fboundp entry))
    (should (memq entry ebox-public-api)))
  (dolist (entry '(ebox-pop-to-buffer ebox-switch-to-buffer))
    (should-not (fboundp entry))
    (should-not (memq entry ebox-public-api)))
  (let ((source
         (with-temp-buffer
           (insert-file-contents (expand-file-name "ebox.el" ebox-test--root))
           (buffer-string))))
    (dolist (definition '("ebox--to-buffer"
                          "ebox-pop-to-buffer"
                          "ebox-switch-to-buffer"))
      (should-not
       (string-match-p
        (format "(defmacro[[:space:]]+%s\\_>" (regexp-quote definition))
        source)))))

(ert-deftest ebox-package-exposes-buffer-report-accessor-only ()
  "The package surface should expose buffer-owned reports, not a global API."
  (require 'ebox)
  (should (fboundp 'ebox-buffer-update-report))
  (should-not (fboundp 'ebox-last-update-report))
  (let ((source (ebox-test--source-text)))
    (should
     (string-match-p
      ";;;###autoload[[:space:]\n]+(defun ebox-buffer-update-report\\_>"
      source))
    (should-not
     (string-match-p
      ";;;###autoload[[:space:]\n]+(defun ebox-last-update-report\\_>"
      source))))

(provide 'ebox-package-tests)
;;; ebox-package-tests.el ends here
