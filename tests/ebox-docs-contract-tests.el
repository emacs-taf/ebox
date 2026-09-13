;;; ebox-docs-contract-tests.el --- Documentation contracts -*- lexical-binding: t; -*-

(require 'ert)

(defconst ebox-docs-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by documentation contract tests.")

(defconst ebox-docs-test--current-docs
  '("AGENTS.md" "README.md" "README.zh-CN.md"
    "docs/manual.md" "docs/manual.zh-CN.md"
    "docs/manual.md" "docs/manual.zh-CN.md"
    "docs/architecture.md"
    "docs/architecture.zh-CN.md"
    "docs/architecture.md"
    "docs/architecture.zh-CN.md")
  "Long-lived documentation files checked for stale path references.")

(defconst ebox-docs-test--public-user-docs
  '("README.md" "README.zh-CN.md"
    "docs/manual.md" "docs/manual.zh-CN.md"
    "docs/manual.md" "docs/manual.zh-CN.md")
  "Public documents that must describe only the canonical author grammar.")

(defun ebox-docs-test--read (relative-path)
  "Return RELATIVE-PATH contents from the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-path ebox-docs-test--root))
    (buffer-string)))

(ert-deftest ebox-docs-do-not-present-legacy-source-as-active ()
  "The standalone package documentation must not claim ETAF source ownership."
  (dolist (file ebox-docs-test--current-docs)
    (let ((source (ebox-docs-test--read file)))
      (should-not (string-match-p "`etaf-[[:alnum:]-]+\\.el`" source))
      (should-not (string-match-p "`etaf\\.el`" source)))))

(ert-deftest ebox-docs-do-not-present-removed-grid-item-api ()
  "Public documentation must expose direct child Grid placement only."
  (dolist (file '("docs/manual.md"
                  "docs/manual.zh-CN.md"
                  "docs/manual.md"
                  "docs/manual.zh-CN.md"))
    (let ((source (ebox-docs-test--read file)))
      (should-not (string-match-p "ebox-grid-item" source))
      (should-not (string-match-p "`grid-item`" source)))))

(ert-deftest ebox-docs-public-author-surface-excludes-removed-forms ()
  "Public docs must not revive removed constructors or field-based children."
  (dolist (file ebox-docs-test--public-user-docs)
    (let ((source (ebox-docs-test--read file)))
      (dolist (removed '("ebox-create" "ebox-concat" "ebox-stack"
                         "ebox-spacer" "ebox-flex-item" "ebox-grid-item"
                         "raw-ebox" ":content"))
        (should-not (string-match-p (regexp-quote removed) source)))
      (dolist (removed-form '("(item " "(spacer " "(raw-ebox "))
        (should-not (string-match-p (regexp-quote removed-form) source))))))

(ert-deftest ebox-docs-canonical-author-grammar-executes ()
  "Every documented author entry must build the advertised typed node."
  (require 'ebox)
  (let ((text-forms '("short" (text "explicit"))))
    (dolist (form text-forms)
      (should
       (ebox-text-node-p
        (ebox-canonical-input--single-root
         (ebox-build form) "Ebox documented Text form")))))
  (dolist (entry '((box "normal")
                   (row (box "row child"))
                   (column (box "column child"))
                   (flex (box "flex child"))
                   (grid (box "grid child"))))
    (let* ((node
            (ebox-canonical-input--single-root
             (ebox-build entry) "Ebox documented Box form"))
           (layout (ebox-box-node-layout node)))
      (should (ebox-box-node-p node))
      (should (eq (ebox-layout-config-kind layout)
                  (pcase (car entry)
                    ('box 'normal)
                    (kind kind)))))))

(provide 'ebox-docs-contract-tests)

;;; ebox-docs-contract-tests.el ends here
