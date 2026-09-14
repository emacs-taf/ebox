;;; ebox-shared-scope-tests.el --- Nonvisual shared scopes -*- lexical-binding: t; -*-

;;; Commentary:
;; Canonical producers express forest roots and author membership independently.

;;; Code:
(require 'ert)
(require 'ebox)
(require 'ecss)

(defun ebox-shared-scope-test-text (builder identity memberships &optional roots)
  "Create IDENTITY text with MEMBERSHIPS and ROOTS in BUILDER."
  (ebox-text-create
   :value (symbol-name identity)
   :source-handle (ebox-source-builder-bind
                   builder :identity identity :id identity :ecss-scopes memberships
                   :ecss-scope-roots roots)
   :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))

(defun ebox-shared-scope-test-box (builder identity children roots)
  "Create an unowned Box with IDENTITY, CHILDREN and scope ROOTS in BUILDER."
  (ebox-box-create
   :layout (ebox-column-layout-create) :children children
   :source-handle (ebox-source-builder-bind
                   builder :identity identity :ecss-scope-roots roots)
   :owned-facts (ebox-canonical-facts-from-declarations 'column nil)))

(defun ebox-shared-scope-test-input (parent child &optional transfer reverse)
  "Build two PARENT roots, a CHILD fallback, and a caller-owned slot.
TRANSFER assigns the slot to CHILD; REVERSE reverses the physical root order."
  (let* ((builder (ebox-source-builder-create))
         (slot (ebox-shared-scope-test-text builder 'Slot (list (if transfer child parent))))
         (fallback (ebox-shared-scope-test-text builder 'Fallback (list child)))
         (foreign (ebox-shared-scope-test-text builder 'Foreign nil))
         (nested (ebox-shared-scope-test-box builder 'child (list slot fallback foreign) (list child)))
         (a (ebox-shared-scope-test-box
             builder 'a (list (ebox-shared-scope-test-text builder 'Alpha (list parent)) nested)
             (list parent)))
         (b (ebox-shared-scope-test-box
             builder 'b (list (ebox-shared-scope-test-text builder 'Beta (list parent))) (list parent)))
         (root (ebox-shared-scope-test-box builder 'app (if reverse (list b a) (list a b)) nil)))
    (ebox-canonical-input-create (list root) (ebox-source-builder-finish builder))))

(defun ebox-shared-scope-test-color (text word)
  "Read WORD's visible foreground in TEXT."
  (plist-get (get-text-property (string-match word text) 'face text) :foreground))

(ert-deftest ebox-shared-scopes-preserve-multiple-roots-and-slot-ownership ()
  "One scope styles multiple trees and projected content without piercing fallback."
  (let* ((rules (list (list "text" :color "#ff0000")))
         (parent (ebox-style-scope-create rules))
         (child (ebox-style-scope-create '(("text" :color "#0000ff"))))
         (input (ebox-shared-scope-test-input parent child)))
    (setcar (cddr (car rules)) "#00ff00")
    (let ((text (ebox-render input)))
      (dolist (word '("Alpha" "Beta" "Slot"))
        (should (equal "#ff0000" (ebox-shared-scope-test-color text word))))
      (should (equal "#0000ff" (ebox-shared-scope-test-color text "Fallback")))
      (should-not (ebox-shared-scope-test-color text "Foreign")))
    (should (= 4 (length (ebox-selector-query-all input "column"))))))

(ert-deftest ebox-shared-scopes-membership-updates-and-snapshots ()
  "Ownership changes repaint retained output while snapshots retain old membership."
  (let ((parent (ebox-style-scope-create '(("text" :color "#ff0000"))))
        (child (ebox-style-scope-create '(("text" :color "#0000ff"))))
        snapshot)
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-shared-scope-test-input parent child))
      (setq snapshot (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
      (ebox-commit (current-buffer) (ebox-shared-scope-test-input parent child t))
      (should (equal "#0000ff" (ebox-shared-scope-test-color (buffer-string) "Slot")))
      (let ((before (buffer-string)))
        (should-error (ebox-commit (current-buffer) (ebox-shared-scope-test-input 'invalid child)))
        (should (equal-including-properties before (buffer-string))))
      (ebox-commit (current-buffer) (ebox-shared-scope-test-input parent child nil t))
      (should (equal "#ff0000" (ebox-shared-scope-test-color (buffer-string) "Slot"))))
    (should (equal "#ff0000" (ebox-shared-scope-test-color (ebox-render snapshot) "Slot")))))

(ert-deftest ebox-shared-scopes-roots-and-membership-are-independent ()
  "Root matching requires membership, while unanchored slices contribute no rules."
  (let ((scope (ebox-style-scope-create '(("&" :color "#ff0000")))))
    (dolist (case '((t t "#ff0000") (nil t nil) (t nil nil)))
      (let* ((builder (ebox-source-builder-create))
             (node (ebox-shared-scope-test-text
                    builder 'Root (and (car case) (list scope))
                    (and (cadr case) (list scope))))
             (input (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder))))
        (should (equal (nth 2 case) (ebox-shared-scope-test-color (ebox-render input) "Root")))))))

(ert-deftest ebox-shared-scopes-use-ecss-origin-and-source-order ()
  "Theme defaults and author scopes retain ECSS precedence and explicit ordering."
  (let ((ua (ebox-style-scope-create '(("&" :color "#ff0000")) :origin 'ua))
        (author (ebox-style-scope-create '(("&" :color "#0000ff"))))
        (later (ebox-style-scope-create '(("&" :color "#00ff00")))))
    (dolist (case (list (list (list author ua) "#0000ff")
                        (list (list author later) "#00ff00")
                        (list (list later author) "#0000ff")))
      (let* ((builder (ebox-source-builder-create))
             (node (ebox-shared-scope-test-text builder 'Root (car case) (car case)))
             (input (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder))))
        (should (equal (cadr case) (ebox-shared-scope-test-color (ebox-render input) "Root")))))))

(ert-deftest ebox-shared-scopes-compose-unanchored-fragments ()
  "Import preserves author membership until a containing source supplies its root."
  (let* ((scope (ebox-style-scope-create '(("text" :color "#ff0000"))))
         (child-builder (ebox-source-builder-create))
         (child (ebox-shared-scope-test-text child-builder 'Child (list scope)))
         (fragment (ebox-canonical-input-create
                    (list child) (ebox-source-builder-finish child-builder))))
    (should-not (ebox-shared-scope-test-color (ebox-render fragment) "Child"))
    (let* ((builder (ebox-source-builder-create))
           (children (ebox-canonical-input-import-roots
                      fragment (ebox-canonical-input-roots fragment) builder))
           (root (ebox-shared-scope-test-box builder 'parent children (list scope)))
           (input (ebox-canonical-input-create (list root) (ebox-source-builder-finish builder))))
      (should (equal "#ff0000" (ebox-shared-scope-test-color (ebox-render input) "Child"))))))

(ert-deftest ebox-shared-scopes-reject-invalid-input ()
  "Invalid rules, origins and source membership never produce usable scopes."
  (should-error (ebox-style-scope-create '(("[" :color "#ff0000"))))
  (should-error (ebox-style-scope-create '(("&" :unknown t))))
  (should-error (ebox-style-scope-create nil :origin 'invalid))
  (let ((scope (ebox-style-scope-create nil)))
    (should-error (ebox-source-builder-bind (ebox-source-builder-create)
                                            :ecss-scopes (list scope scope)))
    (should-error (ebox-source-builder-bind (ebox-source-builder-create)
                                            :ecss-scope-roots '(invalid)))))

(ert-deftest ebox-shared-scopes-revise-rules-with-retained-members ()
  "Root revisions restyle imported members while old inputs and failed updates stay intact."
  (let* ((old (ebox-style-scope-create '(("text" :color "#ff0000"))))
         (next (ebox-style-scope-with-rules old '(("text" :color "#0000ff")))))
    (cl-labels
        ((input (revision)
           (let* ((builder (ebox-source-builder-create))
                  (child (ebox-shared-scope-test-text builder 'Child (list old)))
                  (slice (ebox-canonical-input-create
                          (list child) (ebox-source-builder-finish builder)))
                  (target (ebox-source-builder-create))
                  (children (ebox-canonical-input-import-roots
                             slice (ebox-canonical-input-roots slice) target))
                  (root (ebox-shared-scope-test-box target 'parent children (list revision))))
             (ebox-canonical-input-create (list root) (ebox-source-builder-finish target)))))
      (let ((before (input old)) (after (input next)))
        (with-temp-buffer
          (ebox-render-to-buffer (current-buffer) before)
          (ebox-commit (current-buffer) after)
          (should (equal "#0000ff" (ebox-shared-scope-test-color (buffer-string) "Child")))
          (should-error (ebox-style-scope-with-rules next '(("[" :color "red"))))
          (should (equal "#0000ff" (ebox-shared-scope-test-color (buffer-string) "Child")))
          (ebox-commit (current-buffer) before)
          (should (equal "#ff0000" (ebox-shared-scope-test-color (buffer-string) "Child"))))
        (should (equal "#ff0000" (ebox-shared-scope-test-color (ebox-render before) "Child")))
        (should (equal "#0000ff" (ebox-shared-scope-test-color (ebox-render after) "Child")))))
    (dolist (field '(:ecss-scopes :ecss-scope-roots))
      (should-error (apply #'ebox-source-builder-bind (ebox-source-builder-create)
                          (list field (list old next)))))
    (should-error (ebox-style-scope-with-rules 'invalid nil))
    (should-error (ebox-style-scope-with-rules old nil :origin 'invalid))))

(ert-deftest ebox-shared-scopes-select-rules-per-root-revision ()
  "Roots select their own rule revisions and origins for the same member identity."
  (let* ((old (ebox-style-scope-create '(("&" :color "#ff0000")) :origin 'ua))
         (next (ebox-style-scope-with-rules old '(("&" :color "#0000ff"))))
         (ua (ebox-style-scope-with-rules next '(("&" :color "#00ff00")) :origin 'ua))
         (author (ebox-style-scope-create '(("&" :color "#aabbcc"))))
         (builder (ebox-source-builder-create))
         (nodes
          (list (ebox-shared-scope-test-text builder 'Old (list next) (list old))
                (ebox-shared-scope-test-text builder 'New (list old) (list next))
                (ebox-shared-scope-test-text builder 'Default (list old author) (list author ua))))
         (root (ebox-shared-scope-test-box builder 'app nodes nil))
         (input (ebox-canonical-input-create (list root) (ebox-source-builder-finish builder)))
         (text (ebox-render input)))
    (should (equal "#ff0000" (ebox-shared-scope-test-color text "Old")))
    (should (equal "#0000ff" (ebox-shared-scope-test-color text "New")))
    (should (equal "#aabbcc" (ebox-shared-scope-test-color text "Default")))))

(ert-deftest ebox-scoped-viewport-reflow-preserves-cascade-and-layout ()
  "Unchanged local scopes retain viewport reflow and match a fresh rendering."
  (let* ((input (ebox-build
                 '(column :width (vw 100)
                          :ecss (("text" :color "#ff0000"))
                          (text :id label "Alpha Bravo Charlie Delta"))))
         (ebox-viewport-width 160)
         (ebox-viewport-height 20))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) input)
      (dolist (width '(80 240 160))
        (let ((report (ebox-rerender-buffer-with-context (current-buffer) width 20))
              (ebox-viewport-width width))
          (should (memq (plist-get report :projection-kind)
                        '(viewport-reflow native-frame)))
          (should (plist-get report :runtime-published))
          (should-not (plist-get report :tp-scope-fallback))
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         (substring-no-properties (ebox-render input))))
          (should (equal "#ff0000"
                         (ebox-shared-scope-test-color (buffer-string) "Alpha"))))))))

(ert-deftest ebox-scoped-content-updates-retain-native-interaction ()
  "Local content keeps scoped paint and copied keymaps; changed bindings publish."
  (let* ((hits 0)
         (map (ebox-keymap-create :activate (lambda () (cl-incf hits))))
         (rules '((".label" :color "#ff0000")))
         (input (lambda (value keymap)
                  (ebox-build
                   `(column :id root :width (ch 40) :ecss ,rules
                            (box :id button :keymap ,keymap :width (ch 10)
                                 (text :id label :class label ,value))
                            (text "Untouched"))))))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (funcall input "Alpha" map))
      (let ((label (ebox-region-resolve (current-buffer) "label"))
            (button (ebox-region-resolve (current-buffer) "button")))
        (dolist (value '("Bravo" "Delta" "Alpha"))
          (ebox-region-update label :content value)
          (let ((report (ebox-buffer-update-report (current-buffer)))
                (fresh (ebox-render (funcall input value map))))
            (should (memq (plist-get report :projection-kind)
                          '(span-patch owner-scoped)))
            (should-not (plist-get report :tp-scope-fallback))
            (should (equal (buffer-substring-no-properties (point-min) (point-max))
                           (substring-no-properties fresh)))
            (should (equal "#ff0000"
                           (ebox-shared-scope-test-color (buffer-string) value))))
          (ebox-activate (point-min)))
        (should (= hits 3))
        (let ((replacement
               (ebox-keymap-create :activate (lambda () (cl-incf hits 10)))))
          (ebox-region-update button :keymap replacement)
          (ebox-region-update label :content "Bravo")
          (ebox-activate (point-min))
          (should (= hits 13))
          (let ((before (buffer-substring-no-properties (point-min) (point-max))))
            (should-error (ebox-region-update button :keymap 'invalid-map))
            (should (equal before
                           (buffer-substring-no-properties (point-min) (point-max)))))
          (ebox-activate (point-min))
          (should (= hits 23)))))))

(provide 'ebox-shared-scope-tests)
;;; ebox-shared-scope-tests.el ends here
