;;; ebox-scope-ownership-tests.el --- Scoped author targets -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise canonical author ownership through rendered and retained behavior.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defun ebox-scope-test-input (targets &optional reverse)
  "Build a parent-owned slot and child-owned fallback using TARGETS.
REVERSE reverses their physical order without changing author identities."
  (let* ((builder (ebox-source-builder-create))
         (root (ebox-source-builder-bind
                builder :identity 'root
                :ecss (ebox-style-compile-rules
                       '((".item" :color "#ff0000")
                         (".child > .item:first-child" :color "#00ff00")))
                :ecss-targets targets))
         (child (ebox-source-builder-bind
                 builder :identity 'child :class 'child
                 :ecss (ebox-style-compile-rules '((".item" :color "#0000ff")))
                 :ecss-targets '(fallback)))
         (children
          (mapcar
           (lambda (identity)
             (ebox-text-create
              :value (symbol-name identity)
              :source-handle (ebox-source-builder-bind
                              builder :identity identity :id identity :class 'item)
              :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
           (if reverse '(fallback slot) '(slot fallback))))
         (inner (ebox-box-create
                 :layout (ebox-normal-layout-create) :children children
                 :source-handle child :source-builder builder
                 :owned-facts (ebox-canonical-facts-from-declarations 'box nil)))
         (outer (ebox-box-create
                 :layout (ebox-normal-layout-create) :children (list inner)
                 :source-handle root :source-builder builder
                 :owned-facts (ebox-canonical-facts-from-declarations 'box nil))))
    (ebox-canonical-input-create
     (list outer) (ebox-source-builder-finish builder))))

(defun ebox-scope-test-color (text word)
  "Read the rendered foreground of WORD from TEXT."
  (let ((face (get-text-property (string-match word text) 'face text)))
    (if (keywordp (car face)) (plist-get face :foreground)
      (cl-loop for attributes in face
               when (plist-member attributes :foreground)
               return (plist-get attributes :foreground)))))

(ert-deftest ebox-scope-targets-separate-ownership-from-structure ()
  "A nested slot retains author rules and actual sibling position."
  (let* ((targets (list 'slot))
         (input (ebox-scope-test-input targets)))
    (setcar targets 'fallback)
    (let ((text (ebox-render input)))
      (should (equal "#00ff00" (ebox-scope-test-color text "slot")))
      (should (equal "#0000ff" (ebox-scope-test-color text "fallback")))))
  (let ((text (ebox-render (ebox-scope-test-input '(slot) t))))
    (should (equal "#ff0000" (ebox-scope-test-color text "slot")))
    (should (equal "#0000ff" (ebox-scope-test-color text "fallback")))))

(ert-deftest ebox-scope-targets-retain-committed-ownership-on-failure ()
  "Retained updates preserve target identity; invalid candidates do not publish."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-scope-test-input '(slot)))
    (ebox-region-update 'slot :background-color "#ffff00")
    (should (equal "#00ff00" (ebox-scope-test-color (buffer-string) "slot")))
    (let ((before (buffer-string)))
      (should-error (ebox-commit (current-buffer) (ebox-scope-test-input '(missing))))
      (should (equal-including-properties before (buffer-string))))
    (ebox-commit (current-buffer) (ebox-scope-test-input '(slot) t))
    (should (equal "#ff0000" (ebox-scope-test-color (buffer-string) "slot")))
    (should (equal "#0000ff" (ebox-scope-test-color (buffer-string) "fallback")))))

(ert-deftest ebox-scope-targets-snapshot-remounts-independently ()
  "Exported ownership survives later commits and the original buffer's lifetime."
  (let (snapshot)
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-scope-test-input '(slot)))
      (setq snapshot (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
      (ebox-commit (current-buffer) (ebox-scope-test-input nil)))
    (let ((text (ebox-render snapshot)))
      (should (equal "#00ff00" (ebox-scope-test-color text "slot")))
      (should (equal "#0000ff" (ebox-scope-test-color text "fallback"))))))

(ert-deftest ebox-scope-targets-empty-and-invalid-input ()
  "An explicit empty target set disables local rules and malformed input errors."
  (let ((text (ebox-render (ebox-scope-test-input nil))))
    (should-not (member (ebox-scope-test-color text "slot") '("#ff0000" "#00ff00")))
    (should (equal "#0000ff" (ebox-scope-test-color text "fallback"))))
  (should-error (ebox-scope-test-input '(slot . invalid)) :type 'wrong-type-argument))

(provide 'ebox-scope-ownership-tests)
;;; ebox-scope-ownership-tests.el ends here
