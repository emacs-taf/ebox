;;; ebox-package-tests.el --- Package contract tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(defconst ebox-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by package contract tests.")

(load-file (expand-file-name "ebox.el" ebox-test--root))

(defconst ebox-test--autoload-source-files
  '("ebox.el"
    "ebox-interaction.el"
    "ebox-layout-config.el"
    "ebox-node-factory.el"
    "ebox-measure.el"
    "ebox-layout.el"
    "ebox-flex.el"
    "ebox-grid.el"
    "ebox-canonical.el"
    "ebox-buffer-backend.el"
    "ebox-selector.el")
  "Source files that currently own public autoload entry points.")

(defun ebox-test--source-text ()
  "Return combined source text for files that own public autoloads."
  (with-temp-buffer
    (dolist (file ebox-test--autoload-source-files)
      (insert-file-contents (expand-file-name file ebox-test--root))
      (insert "\n"))
    (buffer-string)))

(defun ebox-test--production-lisp-text ()
  "Return all package-root Ebox Lisp production source as text."
  (with-temp-buffer
    (dolist (file (directory-files ebox-test--root t "\\`ebox.*\\.el\\'"))
      (insert-file-contents file)
      (insert "\n"))
    (buffer-string)))

(ert-deftest ebox-package-c1b-is-v2-only ()
  "Ebox 3 requires structured TP and contains no executable v1 bridge."
  (let ((facade
         (with-temp-buffer
           (insert-file-contents (expand-file-name "ebox.el" ebox-test--root))
           (buffer-string)))
        (source (ebox-test--production-lisp-text)))
    (should (string-match-p "Version: 3.0.0" facade))
    (should (string-match-p (regexp-quote "(tp \"2.0.0\")") facade))
    (should-not (string-match-p "ebox-transaction-participant-route" source))
    (should-not (string-match-p "(tp-transaction-participate\\_>" source))
    (should (string-match-p "(tp-transaction-participate-v2\\_>" source))
    (should (equal ebox-framework-spi-required-tp-version "2.0.0"))
    (should (memq tp-transaction-protocol
                  ebox-framework-spi-supported-tp-protocols))))

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
  (dolist (feature '(ebox-cache ebox-source ebox-state-contract
                                ebox-style ebox-tree ebox-measure
                                ebox-layout-config
                                ebox-node-factory
                                ebox-fragment ebox-layout ebox-flex ebox-grid
                                ebox-canonical
                                ebox-buffer-backend ebox-patch-plan
                                ebox-incremental
                                ebox-surface ebox-viewport ebox-dsl
                                ebox-selector ebox-spi
                                ebox-framework-spi-v2))
    (should (featurep feature))))

(ert-deftest ebox-canonical-module-loads-typed-port-without-facade ()
  "The canonical autoload boundary should not depend on loading `ebox.el'."
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
          "(progn (require 'ebox-canonical) "
          "(let* ((builder (ebox-source-builder-create)) "
          "       (handle (ebox-source-builder-bind "
          "                builder :declarations nil)) "
          "       (node (ebox-text-create "
          "              :value \"A\" :source-handle handle "
          "              :owned-facts "
          "              (ebox-canonical-facts-from-declarations "
          "               'text nil)))) "
          "  (unless (ebox-text-node-p node) "
          "    (error \"Typed Text autoload failed\"))))")))))))

(ert-deftest ebox-facade-defines-native-workflow-without-loading-it ()
  "The facade should define native commands without loading the subsystem."
  (require 'ebox)
  (should (commandp 'ebox-native-build))
  (should (commandp 'ebox-native-status))
  (should-not (autoloadp (symbol-function 'ebox-native-build)))
  (should-not (autoloadp (symbol-function 'ebox-native-status)))
  (should-not (featurep 'ebox-native-reflow)))

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
          "(when (featurep 'ebox-native-reflow) "
          "  (error \"Facade autoload eagerly loaded native subsystem\")))")))))))

(ert-deftest ebox-byte-compile-is-an-interactive-public-command ()
  "Users should be able to rebuild all active Ebox bytecode from Emacs."
  (should (commandp 'ebox-byte-compile))
  (should
   (equal ebox--compile-sources
          '("ebox-cache.el" "ebox-interaction.el" "ebox-source.el" "ebox-runtime-index.el"
            "ebox-state-contract.el"
            "ebox-font.el" "ebox-size.el" "ebox-style.el"
            "ebox-layout-config.el"
            "ebox-node-factory.el"
            "ebox-child-range.el"
            "ebox-tree.el" "ebox-measure.el"
            "ebox-fragment.el" "ebox-render-context.el" "ebox-layout.el"
            "ebox-flex.el" "ebox-grid.el" "ebox-canonical.el"
            "ebox-buffer-backend.el" "ebox-patch-plan.el"
            "ebox-incremental.el"
            "ebox-native-commit.el" "ebox-surface.el" "ebox-viewport.el"
            "ebox-dsl.el" "ebox-selector.el" "ebox-spi.el" "ebox.el"
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
    (should (file-readable-p (expand-file-name file ebox-test--root)))))

(ert-deftest ebox-public-entry-points-have-autoload-cookies ()
  "Stable public entry points should be discoverable by package autoloads."
  (let ((source (ebox-test--source-text)))
    (dolist (entry '(("ebox-clear-cache" . "defun")
                     ("ebox-render-burst-begin" . "defun")
                     ("ebox-render-burst-end" . "defun")
                     ("ebox-call-with-render-burst" . "defun")
                     ("ebox-render" . "defun")
                     ("ebox-region-ids" . "defun")
                     ("ebox-grid-layout-create" . "defun")
                     ("ebox-normal-layout-create" . "defun")
                     ("ebox-row-layout-create" . "defun")
                     ("ebox-column-layout-create" . "defun")
                     ("ebox-flex-layout-create" . "defun")
                     ("ebox-text-create" . "defun")
                     ("ebox-box-create" . "defun")
                     ("ebox-build" . "defun")
                     ("ebox-scroll-down" . "defun")
                     ("ebox-scroll-up" . "defun")
                     ("ebox-region-update" . "defun")
                     ("ebox-region-resolve" . "defun")
                     ("ebox-buffer-set-observer" . "defun")
                     ("ebox-buffer-update-report" . "defun")
                     ("ebox-byte-compile" . "defun")
                     ("ebox-native-build" . "defun")
                     ("ebox-native-status" . "defun")
                     ("ebox-next-interaction" . "defun")
                     ("ebox-previous-interaction" . "defun")
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
                   ebox-buffer-set-observer
                   ebox-buffer-update-report
                   ebox-build
                   ebox-buffer-mode
                   ebox-call-with-render-burst
                   ebox-candidate-begin
                   ebox-child-range
                   ebox-candidate-replace
                   ebox-candidate-replace-range-ref
                   ebox-candidate-replace-root
                   ebox-candidate-replace-host-ref
                   ebox-clear-cache
                   ebox-normal-layout-create
                   ebox-row-layout-create
                   ebox-column-layout-create
                   ebox-text-create
                   ebox-box-create
                   ebox-commit
                   ebox-display-buffer
                   ebox-display-signature
                   ebox-flex-layout-create
                   ebox-grid-layout-create
                   ebox-host-ref-bounds
                   ebox-host-ref-position
                   ebox-native-build
                   ebox-native-status
                   ebox-region-ids
                   ebox-region-resolve
                   ebox-region-update
                   ebox-render
                   ebox-render-burst-begin
                   ebox-render-burst-end
                   ebox-render-to-buffer
                   ebox-rerender-buffer-with-context
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
                   ebox-string-pixel-width))
    (should (memq entry ebox-public-api))))

(ert-deftest ebox-legacy-creation-surface-is-absent ()
  "Only typed constructors and `ebox-build' may create public nodes."
  (dolist (entry '(ebox-test-box ebox-concat ebox-stack ebox-spacer
                   ebox-row ebox-column ebox-flex ebox-flex-item
                   ebox-grid ebox-grid-fr))
    (should-not (fboundp entry))
    (should-not (memq entry ebox-public-api))))

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
