;;; ebox-size-native-tests.el --- Native CSS size capability tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'ebox)
(require 'ebox-native-reflow)

(ert-deftest ebox-size-native-rejects-pre-zero-height-module-abi ()
  "An installed module with old empty-line semantics cannot be activated."
  (let ((module (make-temp-file "ebox-old-native-abi-"))
        (ebox-native-reflow--load-attempted-p nil)
        (ebox-native-reflow--available-p nil)
        (ebox-native-reflow--load-error nil)
        (ebox-native-reflow--loaded-module-path nil)
        (ebox-native-reflow--loaded-module-hash nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow--candidate-paths)
                   (lambda () (list module)))
                  ((symbol-function 'module-load) #'ignore)
                  ((symbol-function 'ebox-native--module-version)
                   (lambda () "12:7:12")))
          (should-not (ebox-native-reflow-load))
          (should (string-match-p "ABI mismatch" ebox-native-reflow--load-error))
          (should-not ebox-native-reflow--loaded-module-path))
      (delete-file module))))

(ert-deftest ebox-size-native-rejects-pre-inline-clipping-module-abi ()
  "An older module cannot silently keep the previous visible inline overflow."
  (let ((module (make-temp-file "ebox-old-native-clipping-"))
        (ebox-native-reflow--load-attempted-p nil)
        (ebox-native-reflow--available-p nil)
        (ebox-native-reflow--load-error nil)
        (ebox-native-reflow--loaded-module-path nil)
        (ebox-native-reflow--loaded-module-hash nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow--candidate-paths)
                   (lambda () (list module)))
                  ((symbol-function 'module-load) #'ignore)
                  ((symbol-function 'ebox-native--module-version)
                   (lambda () "13:7:12")))
          (should-not (ebox-native-reflow-load))
          (should (string-match-p "ABI mismatch" ebox-native-reflow--load-error)))
      (delete-file module))))

(ert-deftest ebox-size-native-inline-clipping-matches-elisp ()
  "Native clipping retains content properties and Box chrome within its width."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (dolist (text '("ABCDEFGHIJ" "界界界" "ééé" "👨‍👩‍👧‍👦👨‍👩‍👧‍👦"))
    (dolist (width '(0 3 8 24))
      (let* ((input (ebox-build
                     `(box :width (px ,width) :box-sizing content-box
                           :padding-inline (px 2) :border "red"
                           :overflow hidden :wrap-mode none
                           (text :help-echo "clipped text" ,text))))
             (node (ebox-canonical-input--single-root input "Native clipping"))
             (normal (let ((ebox--surface-materialization-active t))
                       (ebox--render-with-cache node)))
             (frame (ebox-native-reflow-execute-sync
                     node '(:key 1 :viewport-width 80 :viewport-height 20
                            :runtime-revision 0 :context-hash 0 :complete t)))
             (actual (plist-get frame :rendered)))
        (ert-info ((format "width=%s text=%s" width text))
          (should (plist-get frame :native-frame))
          (should (= (ebox-string-pixel-width actual) (+ width 6)))
          (should (equal-including-properties actual normal)))))))

(ert-deftest ebox-size-native-inline-clipping-retains-update-and-rollback-parity ()
  "Retained native publication uses the same clip boundary as a fresh render."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (let ((ebox-viewport-width 80)
        (ebox-viewport-height 20)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil))
    (cl-labels ((source (text width overflow)
                  (ebox-build
                   `(column :key root :width (px 80)
                            (box :key clip :width (px ,width)
                                 :overflow ,overflow :wrap-mode none
                                 :border "red" :padding-inline (px 2)
                                 (text :key label :help-echo "value" ,text))
                            (box :key peer "unchanged"))))
                (assert-fresh ()
                  (let ((state (ebox--buffer-render-state (current-buffer))))
                    (should (equal-including-properties
                             (buffer-string)
                             (ebox--render-node
                              (plist-get state :root-node)
                              (plist-get state :source-index)))))))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) (source "ABCDEFGHIJ" 9 'hidden))
        (dolist (case '(("ZYXWVUT" 9 hidden) ("A" 9 hidden)
                        ("123456789" 9 visible) ("123456789" 9 hidden)
                        ("界界界" 11 hidden)))
          (let ((report (ebox-commit (current-buffer) (apply #'source case))))
            (should (eq (plist-get report :projection-kind) 'native-frame))
            (assert-fresh)))
        (let ((before (buffer-string))
              (revision (ebox-surface-buffer-revision (current-buffer))))
          (should-error
           (ebox-commit (current-buffer) (source "NEWVALUE" 10 'hidden)
                        (lambda (_report) (error "Reject clipping update"))))
          (should (equal-including-properties before (buffer-string)))
          (should (= (ebox-surface-buffer-revision (current-buffer)) revision)))
        (ebox-commit (current-buffer) (source "NEWVALUE" 10 'hidden))
        (assert-fresh)
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-size-native-declines-cross-property-graphemes ()
  "A single native atom cannot encode different properties inside a cluster."
  (dolist (parts '(("e" "́") ("👨" "‍👩‍👧‍👦") ("🇨" "🇳")))
    (let* ((base (propertize (car parts) 'help-echo "base"))
           (mark (propertize (cadr parts) 'help-echo "mark"))
           (source (concat base mark)))
      ;; Prime the property-run cache before checking the cross-run boundary.
      (should (ebox-native-reflow--compile-text base))
      (dotimes (_ 2)
        (let ((failure (should-error (ebox-native-reflow--compile-text source))))
          (should (string-match-p "grapheme" (error-message-string failure)))))
      (should (ebox-native-reflow--compile-text
               (concat (propertize (concat (car parts) (cadr parts))
                                   'help-echo "complete")
                       (propertize "x" 'help-echo "next")))))))

(ert-deftest ebox-size-native-cross-property-grapheme-fallback-and-rollback ()
  "Initial render and native-to-Elisp updates preserve complete styled clusters."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (let ((ebox-viewport-width 80)
        (ebox-viewport-height 20)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil))
    (dolist (parts '(("e" "́") ("👨" "‍👩‍👧‍👦") ("🇨" "🇳")))
      (let* ((plain (concat (car parts) (cadr parts)))
             (styled (concat (propertize (car parts) 'help-echo "base")
                             (propertize (cadr parts) 'help-echo "mark")))
             (width (ebox--string-pixel-width plain)))
        (cl-labels ((source (text)
                      (ebox-build `(box :key root :width (px ,width)
                                        :overflow hidden :wrap-mode none
                                        (text :key label ,(concat text plain)))))
                    (assert-fresh ()
                      (let ((state (ebox--buffer-render-state (current-buffer))))
                        (should (equal (buffer-substring-no-properties
                                        (point-min) (point-max)) plain))
                        (should (equal-including-properties
                                 (buffer-string)
                                 (ebox--render-node
                                  (plist-get state :root-node)
                                  (plist-get state :source-index)))))))
          (with-temp-buffer
            (ebox-render-to-buffer (current-buffer) (source styled))
            (assert-fresh)
            (should (equal (get-text-property (point-min) 'help-echo) "base"))
            (should (equal (get-text-property
                            (+ (point-min) (length (car parts))) 'help-echo)
                           "mark"))
            (ebox-unmount-buffer (current-buffer)))
          (with-temp-buffer
            (ebox-render-to-buffer (current-buffer) (source plain))
            (should (eq (plist-get (ebox--buffer-render-state (current-buffer))
                                  :projection-kind) 'native-frame))
            (let ((before (buffer-string))
                  (revision (ebox-surface-buffer-revision (current-buffer))))
              (should-error
               (ebox-commit (current-buffer) (source styled)
                            (lambda (_report) (error "Reject grapheme fallback"))))
              (should (equal-including-properties before (buffer-string)))
              (should (= (ebox-surface-buffer-revision (current-buffer)) revision)))
            (ebox-commit (current-buffer) (source styled))
            (assert-fresh)
            (should (equal (get-text-property (point-min) 'help-echo) "base"))
            (ebox-commit (current-buffer) (source plain))
            (assert-fresh)
            (ebox-unmount-buffer (current-buffer))))))))

(ert-deftest ebox-size-native-grouped-display-capability-preserves-pixel-runs ()
  "Opaque source displays fall back; formatted glue compiles as one atom."
  (let* ((display '(space :width (15)))
         (plain (propertize "   " 'display display))
         (formatted (ebox-native-reflow--compile-text plain t))
         (clusters (plist-get (aref (plist-get formatted :lines) 0) :clusters)))
    (should (= (length clusters) 1))
    (should (= (plist-get (aref clusters 0) :width) 15))
    (should (eq (plist-get (aref clusters 0) :pixel-space) t))
    (dolist (text (list plain
                       (concat (propertize "a" 'display display 'help-echo "first")
                               (propertize "bc" 'display display 'help-echo "rest"))))
      (let ((failure (should-error (ebox-native-reflow--compile-text text))))
        (should (string-match-p "unsafe property display"
                                (error-message-string failure)))))))

(ert-deftest ebox-size-native-grouped-display-fallback-keeps-suffix-and-rollback ()
  "Public native-capable mounts preserve one grouped display and its suffix."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (let* ((ebox-viewport-width 80)
         (ebox-viewport-height 20)
         (ebox-runtime-idle-prewarm nil)
         (ebox-runtime-idle-reflow-cache-prewarm nil)
         (display '(space :width (15)))
         (grouped (concat (propertize "a" 'display display 'help-echo "first")
                          (propertize "bc" 'display display 'help-echo "rest")
                          "suffix")))
    (cl-labels ((source (text)
                  (ebox-build `(box :key root :width (px 20) :overflow hidden
                                    :wrap-mode none (text :key label ,text))))
                (assert-grouped ()
                  (should (equal (buffer-substring-no-properties
                                  (point-min) (point-max)) "abcsuffi"))
                  (should (= (ebox-string-pixel-width (buffer-string)) 20))
                  (should (= (string-pixel-width (buffer-string)) 20))
                  (should (eq (get-text-property (point-min) 'display)
                              (get-text-property (1+ (point-min)) 'display)))
                  (should (equal (get-text-property (point-min) 'help-echo) "first"))
                  (should (equal (get-text-property (1+ (point-min)) 'help-echo) "rest"))))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) (source grouped))
        (assert-grouped)
        (should-not (eq (plist-get (ebox--buffer-render-state (current-buffer))
                                  :projection-kind) 'native-frame))
        (ebox-unmount-buffer (current-buffer)))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) (source "plain"))
        (should (eq (plist-get (ebox--buffer-render-state (current-buffer))
                              :projection-kind) 'native-frame))
        (let ((before (buffer-string))
              (revision (ebox-surface-buffer-revision (current-buffer))))
          (should-error
           (ebox-commit (current-buffer) (source grouped)
                        (lambda (_report) (error "Reject display fallback"))))
          (should (equal-including-properties before (buffer-string)))
          (should (= (ebox-surface-buffer-revision (current-buffer)) revision)))
        (ebox-commit (current-buffer) (source grouped))
        (assert-grouped)
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-size-native-fixed-units-use-owning-font ()
  "Fixed units and math compile using the source node's measured font."
  (let ((node (list :font-owner t)))
    (cl-letf (((symbol-function 'ebox--size-character-width)
               (lambda (&optional box) (should (eq node box)) 8))
              ((symbol-function 'ebox--size-line-height)
               (lambda (&optional box) (should (eq node box)) 20)))
      (dolist (case '(((px 80) horizontal 80)
                      ((ch 10) horizontal 80)
                      ((lh 3) vertical 3)
                      ((calc (- (ch 12) (px 16))) horizontal 80)
                      ((min (ch 10) (px 100)) horizontal 80)
                      ((max (ch 10) (px 40)) horizontal 80)
                      ((clamp (px 40) (ch 10) (px 100)) horizontal 80)))
        (should
         (equal (ebox-native-reflow--compile-size
                 (nth 0 case) (nth 1 case) "auto" node)
                (list :kind (if (eq (nth 1 case) 'horizontal) "pixels" "lines")
                      :value (nth 2 case))))))))

(ert-deftest ebox-size-native-declines-responsive-expressions ()
  "Viewport and container lengths cannot become retained constants."
  (let ((ebox-viewport-width 800)
        (ebox-viewport-height 40))
    (dolist (value '((% 50) (vw 100) (vh 100)
                    (calc (- (vh 100) (lh 1)))
                    (min (ch 80) (% 100))))
      (dolist (axis '(horizontal vertical))
        (should-error (ebox-native-reflow--compile-size value axis "auto")))
      (should-error (ebox-native-reflow--compile-gap value 'horizontal)))))

(ert-deftest ebox-size-native-declines-unrepresented-precision ()
  "The integral native ABI does not silently round fractional lengths."
  (cl-letf (((symbol-function 'ebox--size-line-height) (lambda (&optional _) 20)))
    (should-error (ebox-native-reflow--compile-size '(px 1.5) 'horizontal "auto"))
    (should-error (ebox-native-reflow--compile-size '(lh 1.25) 'vertical "auto"))
    (should-error (ebox-native-reflow--compile-gap '(lh 1.5) 'vertical)))
  (should (equal (ebox-native-reflow--compile-size 3 'vertical "auto")
                 '(:kind "lines" :value 3)))
  (should (equal (ebox-native-reflow--compile-size 40 'horizontal "auto")
                 '(:kind "pixels" :value 40)))
  ;; Emacs display spaces retain their private singleton pixel representation.
  (should (= (ebox-native-reflow--display-space-width
              '(display (space :width (7)))) 7))
  (cl-letf (((symbol-function 'ebox--space-pixel-width) (lambda () 7)))
    (should (= (ebox-native-reflow--display-space-width
                '(display (space :width 2))) 14)))
  (should-error (ebox-native-reflow--display-space-width
                 '(display (space :width (1.5))))))

(ert-deftest ebox-size-native-relative-edges-decline-before-resolution ()
  "A rendered relative edge must not be frozen into one native frame."
  (let ((reads 0))
    (cl-letf (((symbol-function 'ebox-get)
               (lambda (&rest _) (cl-incf reads) 50)))
      (dolist (property '(:padding-left-pixel :padding-top-height
                          :margin-right-pixel :border-left-pixel))
        (should-error
         (ebox-native-reflow--compile-edge (list property '(vw 10)) property)))
      (should (zerop reads)))))

(ert-deftest ebox-size-native-canonical-gaps-and-retained-edges ()
  "Canonical gaps share exact native values and retained edge classification."
  (let* ((input (ebox-build
                 '(row :width (px 80) :item-gap (ch 2)
                       (box "a") (box "b"))))
         (node (ebox-canonical-input--single-root input "Native size test")))
    (cl-letf (((symbol-function 'ebox--size-character-width)
               (lambda (&optional box) (if (eq box node) 7 3))))
      (let* ((package (ebox-native-reflow--compile-layout-package node))
             (root (plist-get (plist-get package :document) :root))
             (inner (plist-get root :child))
             (slots (ebox-native-reflow--compile-delta-slots node root)))
        (should (= (plist-get inner :column-gap) 14))
        (should (= (plist-get (aref slots 1) :column-gap) 14))
        (should (eq (plist-get (ebox-native-reflow--retained-edge-rule node)
                              :kind) 'typed-axis-item)))))
  (let* ((input (ebox-build '(row (box "a"))))
         (node (ebox-canonical-input--single-root input "Native zero gap test")))
    (should (eq (plist-get (ebox-native-reflow--retained-edge-rule node) :kind)
                'direct-axis))))

(ert-deftest ebox-size-native-capability-boundaries-use-elisp ()
  "Relative geometry and unsupported height keywords decline native layout."
  (dolist (form '((box :width (vw 100) "a")
                  (box :padding-block (vh 1) "a")
                  (row :item-gap (% 1) (box "a"))
                  (flex :column-gap (vw 1) (box "a"))
                  (box :height stretch "a")
                  (grid :grid-template-columns ((ch 10)) (box "a"))))
    (let* ((input (ebox-build form))
           (node (ebox-canonical-input--single-root input "Native capability test")))
      (should-not (ebox-native-reflow--native-node-supported-p node))
      (should-error (ebox-native-reflow--compile-layout-package node))))
  (dolist (keyword '(min-content max-content fit-content stretch))
    (should-error (ebox-native-reflow--compile-size keyword 'vertical "auto")))
  (let* ((input (ebox-build '(flex (box :min-width (px 0) "abcdef"))))
         (node (ebox-canonical-input--single-root input "Native minimum test")))
    (should-error (ebox-native-reflow--compile-layout-package node))))

(ert-deftest ebox-size-native-fixed-box-compiles-and-renders ()
  "Fixed canonical sizes produce valid IR and native output when available."
  (let* ((ebox-viewport-width 80)
         (ebox-viewport-height 20)
         (input (ebox-build '(box :width (px 20) :height (lh 3) "fixed")))
         (node (ebox-canonical-input--single-root input "Native fixed test"))
         (normal (let ((ebox--surface-materialization-active t))
                   (ebox--render-layout node)))
         (package (ebox-native-reflow--compile-layout-package node))
         (root (plist-get (plist-get package :document) :root)))
    (should (equal (plist-get root :width) '(:kind "pixels" :value 20)))
    (should (equal (plist-get root :height) '(:kind "lines" :value 3)))
    (should (ebox-native-reflow--native-node-supported-p node))
    (when (ebox-native-reflow-layout-ready-p)
      (let ((frame (ebox-native-reflow-execute-sync
                    node '(:key 1 :viewport-width 80 :viewport-height 20
                           :root-width 20 :runtime-revision 0
                           :context-hash 0 :complete t)
                    package)))
        (should (plist-get frame :native-frame))
        (should (equal-including-properties normal (plist-get frame :rendered)))))))

(ert-deftest ebox-size-native-empty-content-has-no-phantom-line ()
  "Empty source compiles to no lines; explicit height stays independent."
  (should (equal (ebox-native-reflow--compile-text "") '(:lines [])))
  (dolist (height '(auto (lh 0) (lh 2)))
    (let* ((input (ebox-build `(box :width (px 20) :height ,height)))
           (node (ebox-canonical-input--single-root input "Empty native size"))
           (package (ebox-native-reflow--compile-layout-package node))
           (root (plist-get (plist-get package :document) :root)))
      (should (equal (plist-get (plist-get root :content) :lines) []))
      (when (ebox-native-reflow-layout-ready-p)
        (let* ((frame (ebox-native-reflow-execute-sync
                       node '(:key 1 :viewport-width 80 :viewport-height 20
                              :root-width 20 :runtime-revision 0
                              :context-hash 0 :complete t)
                       package))
               (output (plist-get frame :rendered)))
          (should (= (ebox-string-height output)
                     (if (equal height '(lh 2)) 2 0))))))))

(ert-deftest ebox-size-native-zero-width-lines-retain-height-and-properties ()
  "Native zero-width lines retain their positive height and paint carrier."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (dolist (form '((box :width (px 0) :height (lh 1))
                  (box :width (px 0) :height (lh 2))
                  (box :width (px 0) :height (lh 1) :bgcolor "#123456")
                  (box :width (px 0) :padding-top (lh 1) :bgcolor "#123456")
                  (box :width (px 0) :border-top ((px 1) solid "red"))
                  (box :width (px 0) :margin-top (lh 1))))
    (ert-info ((format "zero-width native form: %S" form))
      (let* ((input (ebox-build form))
             (node (ebox-canonical-input--single-root input "Zero-width native"))
             (normal (ebox-render input))
             (frame (ebox-native-reflow-execute-sync
                     node '(:key 1 :viewport-width 80 :viewport-height 20
                            :runtime-revision 0 :context-hash 0 :complete t)))
             (actual (plist-get frame :rendered)))
        ;; Omitting :root-width is essential: it must not override the zero
        ;; declaration and turn this into a positive-width fixture.
        (should (plist-get frame :native-frame))
        (should (= (ebox-string-height actual) (ebox-string-height normal)))
        (should (> (ebox-string-height actual) 0))
        (should (= (ebox--string-max-pixel-width actual) 0))
        (should (equal-including-properties actual normal))))))

(ert-deftest ebox-size-native-empty-inline-items-retain-declared-width ()
  "Zero-height items retain their inline extent in Row and Flex."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (dolist (kind '(row flex))
    (dolist (empty '((box :width (px 10))
                    (box :width (px 10) :padding-left (px 2))
                    (box :width (px 10) :border-left ((px 1) solid "red"))
                    (column (box :width (px 10)))
                    (box)))
      (ert-info ((format "native %S empty item: %S" kind empty))
        (let* ((input (ebox-build `(,kind :width (px 30)
                                         ,empty (box :width (px 5) "B"))))
               (node (ebox-canonical-input--single-root input "Native empty item"))
               (normal (ebox-render input))
               (frame (ebox-native-reflow-execute-sync
                       node '(:key 1 :viewport-width 80 :viewport-height 20
                              :runtime-revision 0 :context-hash 0 :complete t)))
               (actual (plist-get frame :rendered))
               (normal-index (string-match "B" normal))
               (actual-index (string-match "B" actual)))
          (should (plist-get frame :native-frame))
          (should actual-index)
          (should (= (ebox-string-pixel-width (substring actual 0 actual-index))
                     (ebox-string-pixel-width (substring normal 0 normal-index))))
          (should (= (ebox--string-max-pixel-width actual)
                     (ebox--string-max-pixel-width normal))))))))

(ert-deftest ebox-size-native-zero-width-formatted-carrier-validation ()
  "Formatted zero-width carriers retain the source property boundary."
  (let* ((blank (propertize " " 'display '(space :width (0))))
         (compiled (ebox-native-reflow--compile-text blank t))
         (cluster (aref (plist-get (aref (plist-get compiled :lines) 0)
                                  :clusters) 0)))
    (should (= (plist-get cluster :width) 0))
    (should (eq (plist-get cluster :pixel-space) t))
    (should-not
     (ebox-native-reflow--validate-literal-properties blank [] t))
    ;; Source display forms remain outside the native property capability.
    (should-error (ebox-native-reflow--compile-text blank)))
  (dolist (width '(-1 0.5))
    (should-error
     (ebox-native-reflow--validate-literal-properties
      (propertize " " 'display `(space :width (,width))) [] t))))

(ert-deftest ebox-size-native-empty-leaf-delta-retains-content ()
  "A retained null child edge still leaves an empty measured text value."
  (dolist (form '((box) (box :height (lh 1)) (box "")))
    (let* ((input (ebox-build form))
           (node (ebox-canonical-input--single-root input "Empty native delta"))
           (package (ebox-native-reflow--compile-layout-package node))
           (root (plist-get (plist-get package :document) :root))
           (updated (aref (ebox-native-reflow--compile-delta-slots node root) 0)))
      (should (eq (plist-get updated :child) :null))
      (should (equal (plist-get updated :content) '(:lines []))))))

(ert-deftest ebox-size-native-zero-width-retained-height-paint-and-rollback ()
  "Retained zero-width carriers survive paint, height, and failed commits."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (let ((ebox-viewport-width 80)
        (ebox-viewport-height 20)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil))
    (dolist (peer '(nil t))
      (ert-info ((format "stable native peer: %S" peer))
        (cl-labels ((source (height color)
                      (ebox-build
                       `(column :key root :width (px 30)
                                (box :key child :width (px 0) :height (lh ,height)
                                     :bgcolor ,color)
                                ,@(when peer '((box :key peer "P")))))))
          (with-temp-buffer
            (ebox-render-to-buffer (current-buffer) (source 1 "#123456"))
            (should (eq (plist-get (ebox--buffer-render-state (current-buffer))
                                  :projection-kind) 'native-frame))
            (dolist (case '((1 "#654321") (2 "#123456") (0 "#123456") (1 "#123456")))
              (let* ((empty-base (zerop (buffer-size)))
                     (report (ebox-commit (current-buffer)
                                          (source (car case) (cadr case))))
                     (state (ebox--buffer-render-state (current-buffer))))
                (if empty-base
                    ;; No mounted ranges exist for scoped TP publication.
                    ;; Keep its ordinary full-surface fallback explicit.
                    (should (plist-get report :empty-range-owner-fallback))
                  (should (eq (plist-get report :projection-kind) 'native-frame)))
                (should (= (ebox-string-height (buffer-string))
                           (+ (car case) (if peer 1 0))))
                (should (equal-including-properties
                         (buffer-string)
                         (ebox--render-node (plist-get state :root-node)
                                            (plist-get state :source-index))))))
            (let ((revision (ebox-surface-buffer-revision (current-buffer)))
                  (before (buffer-string)))
              (should-error
               (ebox-commit (current-buffer) (source 0 "#123456")
                            (lambda (_report) (error "Reject zero-width carrier removal"))))
              (should (= (ebox-surface-buffer-revision (current-buffer)) revision))
              (should (equal-including-properties before (buffer-string)))
              (let* ((report (ebox-commit (current-buffer) (source 0 "#123456")))
                     (state (ebox--buffer-render-state (current-buffer))))
                (when peer
                  (should (eq (plist-get report :projection-kind) 'native-frame)))
                (should (= (ebox-string-height (buffer-string)) (if peer 1 0)))
                (should (equal-including-properties
                         (buffer-string)
                         (ebox--render-node (plist-get state :root-node)
                                            (plist-get state :source-index))))))
            (ebox-unmount-buffer (current-buffer))))))))

(provide 'ebox-size-native-tests)
;;; ebox-size-native-tests.el ends here
