;;; ebox-dsl-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(ert-deftest ebox-local-ecss-renders-nested-scopes ()
  "Actual publication consumes local rules and keeps outside nodes isolated."
  (let* ((input (ebox-build
                 '(box
                   (box :ecss (("&" :color "#111111")
                               (".item" :color "#223344")
                               (".item.active" :color "#00aa00"))
                        (box :class "item" "outer")
                        (box :ecss ((".item" :color "#aa0000"))
                             (box :class "item" "inner")
                             (box :class '("item" "active") "active")))
                   (box :color "#777777" :class '("item" "active") "outside"))))
         (text (ebox-render input)))
    (let (colors)
      (dotimes (position (length text))
        (when-let* ((face (get-text-property position 'face text))
                    (color (plist-get face :foreground)))
          (cl-pushnew color colors :test #'equal)))
      (dolist (color '("#223344" "#aa0000" "#00aa00" "#777777"))
        (should (member color colors))))))

(ert-deftest ebox-dsl-rejects-malformed-selector-state-metadata ()
  "Selector state metadata remains a token list at the author boundary."
  (should-error (ebox-build '(box :states '((checked)) "Invalid"))))

(ert-deftest ebox-style-strict-cache-does-not-hide-unknown-properties ()
  "Strict declaration validation should remain exact after an empty cache hit."
  (ebox-style-compile-declarations nil t)
  (should-error
   (ebox-style-compile-declarations '(:not-an-ebox-property 1) t)
   :type 'error))

(ert-deftest ebox-style-aliases-share-one-canonical-property-id ()
  "A concise alias should disappear before canonical declarations."
  (should
   (equal (ebox-style-compile-declarations '(:bgcolor "red") t)
          (ebox-style-compile-declarations '(:background-color "red") t))))

(ert-deftest ebox-normal-text-align-is-not-a-layout-wide-property ()
  "Only the Normal Box form owns text alignment author input."
  (should (ebox-build '(box :text-align center "A")))
  (dolist (tag '(row column flex grid))
    (should-error
     (ebox-build (list tag :text-align 'center "A"))
     :type 'error)))

(ert-deftest ebox-style-rejects-canonical-and-alias-duplicates ()
  "One declaration source should not spell one property twice."
  (should-error
   (ebox-style-compile-declarations
    '(:bgcolor "red" :background-color "blue") t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:background-color "red" :bgcolor "blue") t)
   :type 'error))

(ert-deftest ebox-style-border-present-is-a-typed-shorthand-not-an-alias ()
  "The concise border boolean should expand to canonical width and style."
  (should
   (equal (ebox-style-compile-declarations '(:border-top-p t) t)
          '(ebox/border-top-width (px 1) ebox/border-top-style solid)))
  (should
   (equal (ebox-style-compile-declarations '(:border-top-p nil) t)
          '(ebox/border-top-width (px 0) ebox/border-top-style none)))
  (should (eq (ebox-style-canonical-name :border-top-p) :border-top-p)))

(ert-deftest ebox-border-width-requires-an-explicit-length ()
  "Border declarations retain explicit lengths and reject singleton syntax."
  (should
   (equal
    (ebox-style-compile-declarations '(:border ((px 1) solid "#687386")) t)
    '(ebox/border-top-width (px 1) ebox/border-top-style solid
      ebox/border-top-color "#687386"
      ebox/border-right-width (px 1) ebox/border-right-style solid
      ebox/border-right-color "#687386"
      ebox/border-bottom-width (px 1) ebox/border-bottom-style solid
      ebox/border-bottom-color "#687386"
      ebox/border-left-width (px 1) ebox/border-left-style solid
      ebox/border-left-color "#687386")))
  (should-error
   (ebox-style-compile-declarations
    '(:border ((1) solid "#687386")) t)
   :type 'error))

(ert-deftest ebox-style-border-present-rejects-owned-longhand-conflicts ()
  "One source should not mix the boolean border shorthand with its outputs."
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-p t :border-top-width (px 2)) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-style dashed :border-top-p t) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-p t :border-top ((px 2) dashed "red")) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-p t :border-width (px 2)) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-style dashed :border-top-p t) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-bottom-p t :border ((px 1) solid "red")) t)
   :type 'error))

(ert-deftest ebox-canonical-box-materializes-inherited-foreground-once ()
  "A canonical Text should be the sole foreground paint owner under Box."
  (let* ((rendered (ebox-render (ebox-build '(box :color "#123456" "A"))))
         (face (get-text-property 0 'face rendered)))
    (should (equal face '(:foreground "#123456")))))

(ert-deftest ebox-canonical-box-rejects-paint-only-properties ()
  "Canonical Box geometry should not duplicate paint-only state."
  (let* ((builder (ebox-source-builder-create))
         (handle (ebox-source-builder-bind builder :declarations nil)))
    (should-error
     (ebox-box-create
      :layout (ebox-normal-layout-create) :children nil
      :source-handle handle
      :owned-facts (ebox-canonical-facts-from-declarations 'box nil)
      :bgcolor "red")
     :type 'error)))

(ert-deftest ebox-build-rejects-explicit-nil-outside-boolean-grammar ()
  "Internal nil initial values must not widen the public author grammar."
  (dolist (form
           '((text :color nil "A")
             (text :font-size nil "A")
             (grid :grid-template-columns nil "A")
             (grid :grid-template-rows nil "A")
             (grid :grid-auto-columns nil "A")
             (grid :grid-auto-rows nil "A")))
    (should-error (ebox-build form) :type 'error))
  (should (ebox-build '(box :border-top-p nil "A"))))

(ert-deftest ebox-source-metadata-uses-the-frozen-public-grammar ()
  "Key, class, and id should remain source facts with closed value domains."
  (should
   (ebox-build
    '(box :key stable :id 42 :class (card selected) "Valid")))
  (dolist (form '((box :key nil "bad")
                  (box :key (not stable) "bad")
                  (box :id nil "bad")
                  (box :id 1.5 "bad")
                  (box :class (card 2) "bad")
                  (box :class (card . selected) "bad")))
    (should-error (ebox-build form) :type 'error)))

(provide 'ebox-dsl-tests)
;;; ebox-dsl-tests.el ends here
