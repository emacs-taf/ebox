;;; ebox-docs-contract-tests.el --- Documentation contracts -*- lexical-binding: t; -*-

(require 'ert)

(defconst ebox-docs-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by documentation contract tests.")

(defconst ebox-docs-test--current-docs
  '("AGENTS.md" "README.md" "README.zh-CN.md" "DESIGN.md" "DESIGN.zh.md"
    "docs/user/ebox-user-guide.en.md" "docs/user/ebox-user-guide.zh.md"
    "docs/user/ebox-api-reference.en.md" "docs/user/ebox-api-reference.zh.md"
    "docs/maintainer/ebox-current-implementation-reference.en.md"
    "docs/maintainer/ebox-current-implementation-reference.zh.md"
    "docs/maintainer/ebox-incremental-update-contract.en.md"
    "docs/maintainer/ebox-incremental-update-contract.zh.md")
  "Long-lived documentation files checked for stale path references.")

(defconst ebox-docs-test--active-files
  '("Makefile" ".github/workflows/ci.yml"
    "ebox.el" "ebox-cache.el" "ebox-style.el" "ebox-child-range.el" "ebox-tree.el"
    "ebox-measure.el" "ebox-fragment.el" "ebox-render-context.el"
    "ebox-layout.el" "ebox-flex.el" "ebox-grid.el"
    "ebox-buffer-backend.el" "ebox-incremental.el" "ebox-surface.el" "ebox-dsl.el"
    "ebox-selector.el" "ebox-native-reflow.el"
    "tests/ebox-core-render-tests.el" "tests/ebox-child-range-tests.el" "tests/ebox-grid-tests.el"
    "tests/ebox-commit-tests.el" "tests/ebox-surface-tests.el"
    "tests/ebox-dsl-tests.el" "tests/ebox-flex-tests.el"
    "tests/ebox-selector-tests.el" "tests/ebox-package-tests.el"
    "tests/ebox-visual-check-tests.el" "tests/ebox-docs-contract-tests.el"
    "tests/ebox-ci-contract-tests.el"
    "native/Cargo.toml" "native/Cargo.lock" "native/build.rs"
    "native/vendor/emacs-30/emacs-module.h" "native/src/lib.rs"
    "native/src/layout.rs" "native/c/ebox_module.c"
    "scripts/ebox-package-lint.el" "scripts/ebox-visual-check.el"
    "scripts/ebox-performance-evaluator.el")
  "Active Ebox files that the maintainer map must cover.")

(defconst ebox-docs-test--targets
  '("check" "ci" "load" "compile" "core-tests" "child-range-tests" "grid-tests"
    "ebox-commit-tests" "surface-tests" "visual-check-tests" "package-tests"
    "selector-tests" "dsl-tests" "flex-tests"
    "docs-contract-tests" "ci-contract-tests" "performance-evaluator"
    "visual-check"
    "native-rust-tests" "native-build" "package-lint" "diff-check")
  "Make targets that must be documented and executable.")

(defun ebox-docs-test--read (relative-path)
  "Return RELATIVE-PATH contents from the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-path ebox-docs-test--root))
    (buffer-string)))

(ert-deftest ebox-docs-active-files-exist-and-are-listed ()
  "The maintainer reference should describe every active package file."
  (let ((reference (ebox-docs-test--read
                    "docs/maintainer/ebox-current-implementation-reference.en.md")))
    (dolist (file ebox-docs-test--active-files)
      (should (file-exists-p (expand-file-name file ebox-docs-test--root)))
      (should (string-match-p (regexp-quote file) reference)))))

(ert-deftest ebox-docs-verification-targets-match-makefile ()
  "Documented verification targets should exist in the Makefile."
  (let ((makefile (ebox-docs-test--read "Makefile"))
        (reference (ebox-docs-test--read
                    "docs/maintainer/ebox-current-implementation-reference.en.md")))
    (dolist (target ebox-docs-test--targets)
      (should (string-match-p (concat "^" (regexp-quote target) ":") makefile))
      (should (string-match-p (regexp-quote (concat "make " target))
                              reference)))))

(ert-deftest ebox-docs-have-paired-language-files ()
  "Every long-lived user and maintainer document should have both languages."
  (dolist (pair '(("docs/user/ebox-user-guide.en.md"
                   "docs/user/ebox-user-guide.zh.md")
                  ("docs/user/ebox-api-reference.en.md"
                   "docs/user/ebox-api-reference.zh.md")
                  ("docs/maintainer/ebox-current-implementation-reference.en.md"
                   "docs/maintainer/ebox-current-implementation-reference.zh.md")
                  ("docs/maintainer/ebox-incremental-update-contract.en.md"
                   "docs/maintainer/ebox-incremental-update-contract.zh.md")))
    (dolist (file pair)
      (should (file-exists-p (expand-file-name file ebox-docs-test--root))))))

(ert-deftest ebox-docs-public-api-reference-covers-facade ()
  "The bilingual API references should name every facade entry point."
  (require 'ebox)
  (dolist (file '("docs/user/ebox-api-reference.en.md"
                  "docs/user/ebox-api-reference.zh.md"))
    (let ((source (ebox-docs-test--read file)))
      (dolist (entry ebox-public-api)
        (should (string-match-p
                 (regexp-quote (format "`%s`" entry))
                 source))))))

(ert-deftest ebox-docs-do-not-present-legacy-source-as-active ()
  "The standalone package documentation must not claim ETAF source ownership."
  (dolist (file ebox-docs-test--current-docs)
    (let ((source (ebox-docs-test--read file)))
      (should-not (string-match-p "`etaf-[[:alnum:]-]+\\.el`" source))
      (should-not (string-match-p "`etaf\\.el`" source)))))

(provide 'ebox-docs-contract-tests)

;;; ebox-docs-contract-tests.el ends here
