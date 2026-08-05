;;; ebox-examples-tests.el --- Ebox example contracts -*- lexical-binding: t; -*-

(require 'ert)
(require 'ebox)
(defconst ebox-examples-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by example tests.")
(load-file (expand-file-name "examples/ebox-basic-examples.el"
                             ebox-examples-test--root))

(ert-deftest ebox-basic-example-builds-a-public-tree ()
  "The basic example should build through public constructors."
  (let ((node (ebox-basic-examples-build)))
    (should (listp node))
    (should (string-match-p "Ebox"
                            (substring-no-properties (ebox-render node))))))

(ert-deftest ebox-dsl-examples-render-without-playground-code ()
  "The maintained DSL fixtures should render through the Ebox facade."
  (dolist (file '("basic.ebox" "comprehensive.ebox" "flex-reference.ebox"
                  "responsive-reference.ebox"))
    (let ((form
           (with-temp-buffer
             (insert-file-contents
              (expand-file-name (concat "examples/playground/" file)
                                ebox-examples-test--root))
             (read (current-buffer)))))
      (should (stringp (ebox-render (ebox-build form)))))))

(provide 'ebox-examples-tests)

;;; ebox-examples-tests.el ends here
