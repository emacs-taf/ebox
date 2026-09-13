;;; ebox-file-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(ert-deftest ebox-file-relative-nested-styles-are-inert-snapshots ()
  (let ((dir (make-temp-file "ebox-files-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "panel.ecss" dir)
            (insert "((\".item\" :color \"#ff0000\")) ; trailing comment\n"))
          (let* ((dsl (ebox-file-evaluate-form
                       ''(box (box :ecss-file "panel.ecss"
                                   (box :class "item" "inside"))
                              (box :class "item" :color "#00ff00" "outside"))
                       (expand-file-name "app.ebox" dir)))
                 (input (ebox-build dsl))
                 (rendered (ebox-render input)))
            (delete-file (expand-file-name "panel.ecss" dir))
            (should (equal-including-properties rendered (ebox-render input)))
            (should (equal (plist-get (get-text-property
                                       (string-match "inside" rendered) 'face rendered)
                                      :foreground) "#ff0000"))
            (should (equal (plist-get (get-text-property
                                       (string-match "outside" rendered) 'face rendered)
                                      :foreground) "#00ff00"))))
      (delete-directory dir t))))

(ert-deftest ebox-compiled-rules-use-canonical-source-pipeline ()
  "Programmatic rules produce the same inherited paint as authored DSL rules."
  (let* ((rules '(("&" :color "#ff0000")))
         (builder (ebox-source-builder-create))
         (root (ebox-source-builder-bind
                builder :identity 'root :ecss (ebox-style-compile-rules rules)))
         (text-source (ebox-source-builder-bind builder :identity 'text))
         (text (ebox-text-create
                :value "Compiled" :source-handle text-source
                :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (node (ebox-box-create
                :layout (ebox-normal-layout-create) :children (list text)
                :source-handle root :source-builder builder
                :owned-facts (ebox-canonical-facts-from-declarations 'box nil)))
         (input (ebox-canonical-input-create
                 (list node) (ebox-source-builder-finish builder))))
    (should (equal-including-properties
             (ebox-render input)
             (ebox-render (ebox-build (list 'box :ecss rules "Compiled"))))))
  (should-error (ebox-style-compile-rules '((".item" :unknown-property t))))
  (should-error (ebox-style-compile-rules '((".item" :color))))
  (should-not (ebox-style-compile-rules nil)))

(provide 'ebox-file-tests)
;;; ebox-file-tests.el ends here
