;;; ebox-ci-contract-tests.el --- CI and Makefile contracts -*- lexical-binding: t; -*-

(require 'ert)

(defconst ebox-ci-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by CI contract tests.")

(defun ebox-ci-test--read (relative-path)
  "Return RELATIVE-PATH contents from the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-path ebox-ci-test--root))
    (buffer-string)))

(ert-deftest ebox-ci-exposes-one-low-level-package-boundary ()
  "The Makefile should expose Ebox targets without bundling ETAF."
  (let ((source (ebox-ci-test--read "Makefile")))
    (dolist (target '("check:" "ci:" "load:" "compile:" "test:"
                      "core-tests:" "child-range-tests:" "grid-tests:" "ebox-commit-tests:"
                      "surface-tests:"
                      "state-contract-tests:"
                      "docs-contract-tests:"
                      "ci-contract-tests:" "native-rust-tests:"
                      "native-build:" "performance-evaluator:" "diff-check:"))
      (should (string-match-p (concat "^" (regexp-quote target)) source)))
    (should-not (string-match-p "ETAF" source))
    (should-not (string-match-p "etaf" source))))

(ert-deftest ebox-ci-compiles-the-active-source-list ()
  "The public compile command should use Ebox's source manifest."
  (let ((source (ebox-ci-test--read "Makefile"))
        (ebox (ebox-ci-test--read "ebox.el")))
    (should (string-match-p "byte-compile-error-on-warn" source))
    (should (string-match-p "ebox-byte-compile" source))
    (should (string-match-p "ebox-native-reflow.el" ebox))
    (should (string-match-p "ebox-child-range.el" ebox))
    (should-not (string-match-p "ebox-playground.el" ebox))))

(ert-deftest ebox-ci-prefers-newer-source-and-cleans-local-products ()
  "Batch entry points should avoid stale bytecode and global cleanup."
  (let ((source (ebox-ci-test--read "Makefile")))
    (should (string-match-p "load-prefer-newer t" source))
    (should (string-match-p "rm -rf native/target" source))
    (should-not (string-match-p "user-emacs-directory" source))))

(ert-deftest ebox-ci-workflow-uses-local-entry-points ()
  "GitHub Actions should call the same local checks as maintainers."
  (let ((source (ebox-ci-test--read ".github/workflows/ci.yml")))
    (should (string-match-p "emacs-nox" source))
    (should (string-match-p "Kinneyzhang/tp" source))
    (should (string-match-p "make ci" source))
    (should (string-match-p (regexp-quote "cargo +stable test") source))
    (should (string-match-p (regexp-quote "cargo +1.82.0 test") source))))

(provide 'ebox-ci-contract-tests)

;;; ebox-ci-contract-tests.el ends here
