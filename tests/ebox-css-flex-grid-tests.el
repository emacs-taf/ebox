;;; ebox-css-flex-grid-tests.el --- CSS sizes in formatting contexts -*- lexical-binding: t; -*-

;;; Commentary:
;; Regression coverage for delayed relative sizes and the author/used boundary.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)

(ert-deftest ebox-css-flex-grid-empty-auto-height-is-zero ()
  "Empty formatting contexts and empty auto-sized children have no height."
  (dolist (form '((flex) (grid)
                  (flex (box)) (flex (box) (box))
                  (flex :flex-direction column (box) (box))
                  (grid (box)) (grid (box) (box))
                  (grid :grid-auto-rows (lh 3))
                  (grid :grid-auto-columns (px 40) :grid-auto-rows (lh 3))
                  (flex :row-gap (lh 2) :column-gap (px 8))))
    (let ((rendered (ebox-render (ebox-build form))))
      (should (equal rendered ""))
      (should (= (ebox-string-height rendered) 0)))))

(ert-deftest ebox-css-flex-grid-empty-items-preserve-gap-and-explicit-height ()
  "Empty children count toward gaps; explicit dimensions remain visible."
  (dolist (case '(((flex :flex-direction column :row-gap (lh 2)
                         (box) (box)) 2)
                  ((flex :flex-direction column :row-gap (lh 2)
                         (box) (box "A") (box)) 5)
                  ((flex :width (px 40) :flex-wrap wrap :row-gap (lh 2)
                         (box :width (px 40)) (box :width (px 40))) 2)
                  ((flex :column-gap (px 8) (box) (box)) 0)
                  ((flex :height (lh 3)) 3)
                  ((grid :height (lh 3)) 3)
                  ((grid :grid-template-columns ((px 20))
                         :row-gap (lh 2) (box) (box)) 2)
                  ((grid :grid-template-rows ((lh 0) (lh 0))
                         :row-gap (lh 2)) 2)
                  ((grid :grid-template-rows ((lh 2) (lh 0) (lh 3))
                         :row-gap (lh 1)) 7)
                  ((grid :height (lh 4)
                         :grid-template-columns ((px 20))
                         :grid-template-rows ((lh 0) (fr 1))
                         :row-gap (lh 1) (box) (box)) 4)))
    (ert-info ((format "Formatting case: %S" (car case)))
      (let ((rendered (ebox-render (ebox-build (car case)))))
        (should (= (ebox-string-height rendered) (cadr case)))))))

(ert-deftest ebox-css-flex-grid-empty-items-do-not-add-content-lines ()
  "An empty sibling adds no line before or after real content."
  (dolist (form '((flex (box) (box "A") (box))
                  (flex :flex-direction column (box) (box "A") (box))
                  (grid :grid-template-columns ((px 20))
                        (box) (box "A") (box))))
    (let ((rendered (ebox-render (ebox-build form))))
      (should (= (ebox-string-height rendered) 1))
      (should (string-match-p "A" rendered)))))

(ert-deftest ebox-css-flex-grid-empty-items-keep-their-inline-size ()
  "A zero-height item's declared width still positions its visible sibling."
  (dolist (form '((flex (box :width (px 20)) (box "A"))
                  (grid :width max-content :grid-template-columns (auto auto)
                        (box :width (px 20)) (box "A"))))
    (let* ((rendered (ebox-render (ebox-build form)))
           (position (string-match "A" rendered)))
      (should position)
      (should (= (ebox-string-height rendered) 1))
      (should (= (ebox--string-pixel-width (substring rendered 0 position)) 20)))))

(ert-deftest ebox-css-flex-grid-empty-composites-keep-their-inline-size ()
  "A nested empty layout keeps geometry without introducing a text line."
  (dolist (case '(((row :item-gap (px 3)
                        (box :width (px 10)) (box :width (px 4))) 17)
                  ((column (box :width (px 10))) 10)
                  ((flex (box :width (px 10))) 10)
                  ((flex :flex-direction column (box :width (px 10))) 10)
                  ((grid :grid-template-columns ((px 10) (px 4))
                         :column-gap (px 3) (box) (box)) 17)
                  ((box (box :width (px 10))) 10)))
    (dolist (outer '(row flex grid))
      (ert-info ((format "Nested empty layout: %S in %S" (car case) outer))
        (let* ((form (append (list outer :width '(px 60))
                             (when (eq outer 'grid)
                               '(:grid-template-columns (auto auto)
                                 :justify-items start))
                             (list (car case) '(box :width (px 5) "B"))))
               (rendered (ebox-render (ebox-build form)))
               (position (string-match "B" rendered)))
          (should position)
          (should (= (ebox-string-height rendered) 1))
          (should (= (ebox--string-pixel-width (substring rendered 0 position))
                     (cadr case)))
          (should (= (ebox-string-height
                      (ebox-render (ebox-build (car case))))
                     0)))))))

(ert-deftest ebox-css-flex-grid-empty-composite-widths-follow-render-context ()
  "Distinct empty layouts keep separate widths and resolve each new viewport."
  (let ((tree (ebox-build
               '(row :width (px 100)
                     (grid :grid-template-columns ((px 23)))
                     (column (box :width (vw 25)))
                     (box :width (px 5) "B")))))
    (dolist (case '((80 43) (120 53) (80 43)))
      (let* ((ebox-viewport-width (car case))
             (rendered (ebox-render tree))
             (position (string-match "B" rendered)))
        (should position)
        (should (= (ebox-string-height rendered) 1))
        (should (= (ebox--string-pixel-width (substring rendered 0 position))
                   (cadr case)))))))

(ert-deftest ebox-css-flex-grid-reject-cross-axis-config-units ()
  "Typed configs reject cross-axis lengths, including nested track functions."
  (dolist (value '((px 0) (ch 2) (vw 5)
                   (calc (* 0 (px 2)))
                   (min (lh 2) (max (lh 1) (px 2)))))
    (should-error (ebox-flex-layout-create :row-gap value))
    (should-error (ebox-grid-layout-create :grid-template-rows (list value)))
    (should-error (ebox-grid-layout-create :grid-auto-rows value)))
  (dolist (value '((lh 0) (vh 2)
                   (clamp (px 1) (calc (+ (px 2) (lh 1))) (px 10))))
    (should-error (ebox-flex-layout-create :column-gap value))
    (should-error (ebox-grid-layout-create :grid-template-columns (list value)))
    (should-error (ebox-grid-layout-create :grid-auto-columns value)))
  (should-error
   (ebox-grid-layout-create :grid-template-rows
                            '((repeat 2 (minmax (lh 0) (px 20))))))
  (should-error
   (ebox-grid-layout-create :grid-template-columns
                            '((repeat 2 (minmax (px 0) (vh 20)))))))

(ert-deftest ebox-css-flex-basis-validates-parent-axis-before-render ()
  "Building a Flex parent validates item bases against its resolved direction."
  (dolist (direction '(row row-reverse column column-reverse))
    (let ((inline (memq direction '(row row-reverse))))
      (dolist (basis (if inline '((lh 0) (vh 5) (calc (* 0 (lh 1))))
                      '((px 0) (ch 2) (vw 5) (calc (* 0 (px 1))))))
        (should-error
         (ebox-build `(flex :flex-direction ,direction
                            (box :flex-basis ,basis)))))
      (dolist (basis (if inline '((px 0) (ch 2) (vw 5) (% 20))
                      '((lh 0) (vh 5) (% 20))))
        (should
         (ebox-build `(flex :flex-direction ,direction
                            (box :flex-basis ,basis))))))
    (should (ebox-build `(flex :flex-direction ,direction (box :flex 1)))))
  (should-error
   (ebox-build '(flex :flex-flow (column nowrap)
                      (box :flex (1 1 (px 0))))))
  (should
   (ebox-build '(flex :flex-direction column
                      (flex :flex-basis (lh 2) :flex-direction row
                            (box :flex-basis (px 20)))))))

(ert-deftest ebox-css-flex-basis-validates-computed-parent-context ()
  "Stylesheet directions and bases are validated before layout starts."
  (dolist (rule '(("#parent" (:flex-direction column))
                  ("#item" (:flex-basis (lh 2)))))
    (let ((ebox-style-stylesheet (ecss-stylesheet-create))
          (original (symbol-function 'ebox--render-flex-children))
          (layout-count 0))
      (ebox-style-add-rule (car rule) (cadr rule))
      (cl-letf (((symbol-function 'ebox--render-flex-children)
                 (lambda (&rest arguments)
                   (cl-incf layout-count)
                   (apply original arguments))))
        (should-error
         (ebox-render
          (ebox-build
           (if (equal (car rule) "#parent")
               '(flex :id "parent" (box :id "item" :flex-basis (px 10) "A"))
             '(flex :id "parent" (box :id "item" "A")))))
         :type 'ebox-size-error))
      (should (= layout-count 0)))))

(ert-deftest ebox-css-flex-basis-invalid-context-update-rolls-back ()
  "Changing either side of a parent/basis relation fails before publication."
  (dolist (case '((nil "parent" :flex-direction column)
                  (nil "item" :flex-basis (lh 2))
                  (t "parent" :flex-direction column)
                  (t "item" :flex-basis (lh 2))))
    (let ((buffer (generate-new-buffer " *ebox-flex-axis-update*"))
          (ebox-style-stylesheet (ecss-stylesheet-create)))
      (unwind-protect
          (progn
            (when (car case)
              (ebox-style-add-rule "flex" '(:color "red")))
            (ebox-render-to-buffer
             buffer (ebox-build '(flex :id "parent" :width (px 40)
                                       (box :id "item" :flex-basis (px 10) "A"))))
            (let* ((before (with-current-buffer buffer (buffer-string)))
                   (report (ebox-buffer-update-report buffer))
                   (state (ebox--buffer-render-state buffer))
                   (runtime-revision (plist-get state :runtime-revision))
                   (surface-revision (tp-surface-revision (plist-get state :surface)))
                   (original (symbol-function 'ebox--render-flex-children))
                   (layout-count 0))
              (cl-letf (((symbol-function 'ebox--render-flex-children)
                         (lambda (&rest arguments)
                           (cl-incf layout-count)
                           (apply original arguments))))
                (should-error
                 (apply #'ebox-region-update
                        (ebox-region-resolve buffer (cadr case)) (cddr case))
                 :type 'ebox-size-error))
              (should (= layout-count 0))
              (should (equal-including-properties
                       before (with-current-buffer buffer (buffer-string))))
              (should (equal report (ebox-buffer-update-report buffer)))
              (should (= runtime-revision
                         (plist-get (ebox--buffer-render-state buffer)
                                    :runtime-revision)))
              (should (= surface-revision
                         (tp-surface-revision (plist-get state :surface)))))
            (should (ebox-region-update (ebox-region-resolve buffer "item")
                                        :flex-basis '(px 12))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ebox-css-flex-basis-validates-final-batched-context ()
  "A batch can change both parent axis and child basis as one valid update."
  (let ((buffer (generate-new-buffer " *ebox-flex-axis-batch*"))
        (ebox-style-stylesheet (ecss-stylesheet-create)))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-build '(flex :id "parent" :width (px 40)
                                     (box :id "item" :flex-basis (px 10) "A"))))
          (ebox-incremental-begin-batch buffer)
          (ebox-region-update (ebox-region-resolve buffer "parent")
                              :flex-direction 'column)
          (ebox-region-update (ebox-region-resolve buffer "item")
                              :flex-basis '(lh 2))
          (should (ebox-incremental-flush buffer))
          (should (= (ebox-string-height
                      (with-current-buffer buffer (buffer-string))) 2)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-css-flex-basis-validates-final-class-context ()
  "Class selectors compute the parent axis and child basis before validation."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
    (ebox-style-add-rule "#item" '(:flex-basis (px 10)))
    (ebox-style-add-rule ".vertical" '(:flex-direction column))
    (ebox-style-add-rule ".vertical > #item" '(:flex-basis (lh 2)))
    (dolist (case '((nil 1) (("vertical") 2) (nil 1)))
      (should (= (ebox-string-height
                  (ebox-render
                   (ebox-build `(flex :class ,(car case) :width (px 40)
                                      (box :id "item" "A")))))
                 (cadr case))))))

(ert-deftest ebox-css-flex-grid-configs-preserve-size-expressions ()
  "Layout configs keep context-dependent author sizes until layout."
  (let* ((gap '(calc (+ (% 10) (px 2))))
         (flex (ebox-layout-config-props
                (ebox-flex-layout-create :column-gap gap :row-gap '(lh 1))))
         (grid (ebox-layout-config-props
                (ebox-grid-layout-create
                 :column-gap gap :grid-template-columns
                 '((repeat 2 (% 50)))))))
    (should (equal (plist-get flex :column-gap) gap))
    (should (equal (plist-get flex :row-gap) '(lh 1)))
    (should (equal (plist-get grid :grid-template-columns)
                   '((:kind fixed :size (% 50))
                     (:kind fixed :size (% 50)))))
    (should (ebox-flex-layout-config-props-p flex))
    (should (ebox-grid-layout-config-props-p grid))))

(ert-deftest ebox-css-flex-grid-reject-implicit-size-syntax ()
  "Unitless values and parameterized fit-content never enter configs."
  (dolist (value '(2 (2) viewport (viewport-height) (fit-content (ch 80))))
    (should-error (ebox-flex-layout-create :column-gap value))
    (should-error (ebox-flex-layout-create :row-gap value))
    (should-error
     (ebox-grid-layout-create :grid-template-columns (list value)))))

(ert-deftest ebox-css-flex-grid-gaps-use-definite-containing-axis ()
  "Percentages use each layout axis and unresolved gap percentages are zero."
  (cl-letf (((symbol-function 'ebox--size-line-height) (lambda (&optional _) 10)))
    (should (= (ebox--layout-used-gap '(% 25) 'width 200) 50))
    (should (= (ebox--layout-used-gap '(% 25) 'height 10) 2))
    (let ((ebox--css-containing-height 1000))
      (should (= (ebox--layout-used-gap '(% 25) 'height nil) 0)))
    (should (= (ebox--layout-used-gap '(calc (+ (% 25) (px 5)))
                                     'width nil) 5))
    (should (= (ebox--layout-used-gap '(calc (+ (px 5) (lh 1)))
                                     'height 20) 1))))

(ert-deftest ebox-css-grid-relative-tracks-reresolve-and-share-rounding ()
  "Track expressions survive resizing and do not each lose their fractions."
  (let ((tracks (ebox-grid--normalize-tracks '((% 50) (% 50)) 'columns))
        (rendered (make-hash-table :test 'eq)))
    (should (equal (ebox-grid--resolve-sizes tracks 2 'columns
                                            nil rendered 0 101)
                   '(50 51)))
    (should (equal (ebox-grid--resolve-sizes tracks 2 'columns
                                            nil rendered 0 201)
                   '(100 101)))
    (should (equal (plist-get (car tracks) :size) '(% 50)))))

(ert-deftest ebox-css-grid-minmax-minimum-wins-after-unit-resolution ()
  "A definite minmax maximum below its minimum becomes the minimum."
  (let ((track (ebox-grid--normalize-track
                '(minmax (% 60) (px 40)) 'columns)))
    (should (equal (ebox-grid--resolve-sizes
                    (list track) 1 'columns nil (make-hash-table) 0 100)
                   '(60)))))

(ert-deftest ebox-css-grid-percent-height-without-containing-height-is-auto ()
  "An indefinite percentage row sizes from content instead of viewport height."
  (let* ((node 'cell)
         (entries (list (list :node node :row 1 :row-span 1)))
         (rendered (make-hash-table :test 'eq))
         (tracks (ebox-grid--normalize-tracks '((% 100)) 'rows))
         (ebox-viewport-height 100))
    (puthash node "first\nsecond" rendered)
    (should (equal (ebox-grid--resolve-sizes
                    tracks 1 'rows entries rendered 0 nil) '(2)))))

(ert-deftest ebox-css-flex-grid-render-public-size-expressions ()
  "The public DSL renders both formatting contexts with canonical units."
  (dolist (dsl '((flex :width (px 100) :height (lh 3)
                       :column-gap (px 4)
                       (box :min-width (px 0) :flex-basis (% 50) "A")
                       (box :min-width (px 0) :flex-basis (% 50) "B"))
                 (grid :width (px 100) :height (lh 3)
                       :grid-template-columns ((fr 1) (fr 1))
                       :column-gap (px 4)
                       (box "A") (box "B"))))
    (let ((rendered (ebox-render (ebox-build dsl))))
      (should (= (ebox--string-max-pixel-width rendered) 100))
      (should (= (ebox-string-height rendered) 3))
      (should (string-match-p "A.*B" rendered)))))

(ert-deftest ebox-css-flex-column-fractional-bases-round-at-final-boundaries ()
  "Two percentage bases divide an odd height without fractional line errors."
  (let* ((rendered
          (ebox-render
           (ebox-build
            '(flex :flex-direction column :width (px 50) :height (lh 5)
                   (box :min-height (lh 0) :flex-basis (% 50) "A")
                   (box :min-height (lh 0) :flex-basis (% 50) "B")))))
         (lines (ebox-string-lines rendered)))
    (should (= (length lines) 5))
    (should (string-match-p "A" (nth 0 lines)))
    (should (string-match-p "B" (nth 2 lines)))))

(ert-deftest ebox-css-size-quantize-preserves-extents-and-zero ()
  "Boundary rounding preserves zero sizes and handles floating-point residue."
  (should (equal (ebox-size-quantize '(0 0.5 0 0.5 0)) '(0 0 0 1 0)))
  (should (equal (ebox-size-quantize '(100.49999999999999 100.49999999999999))
                 '(100 101)))
  (should-error (ebox-size-quantize '(2 -1))))

(ert-deftest ebox-css-flex-automatic-minimum-respects-overflow-and-explicit-zero ()
  "Automatic minima are content-based only for non-scrollable overflow."
  (dolist (case '((visible auto t) (scroll auto nil) (hidden auto nil)
                  (visible (px 0) nil)))
    (let* ((input (ebox-build `(box :overflow ,(nth 0 case)
                                   :min-width ,(nth 1 case)
                                   :wrap-mode none "UNBREAKABLE")))
           (node (car (ebox-canonical-input--nodes input)))
           (rendered (ebox-render input))
           (minimum (ebox--flex-box-min-main node rendered 'row)))
      (if (nth 2 case)
          (should (= minimum (ebox--string-pixel-width "UNBREAKABLE")))
        (should (= minimum 0))))))

(ert-deftest ebox-css-flex-column-automatic-minimum-preserves-visible-content ()
  "Column auto minima retain content height when overflow is visible."
  (let* ((input (ebox-build '(box :overflow visible :min-height auto "A\nB\nC")))
         (node (car (ebox-canonical-input--nodes input))))
    (should (= (ebox--flex-box-min-main node (ebox-render input) 'column) 3))))

(ert-deftest ebox-css-grid-fractions-freeze-content-minima-before-sharing-space ()
  "Flexible tracks honor automatic minima and still fill remaining space."
  (let* ((first-input (ebox-build '(box :min-width auto :overflow visible
                                        :wrap-mode none "abcdefgh")))
         (second-input (ebox-build '(box :min-width auto :overflow visible
                                         :wrap-mode none "X")))
         (first (car (ebox-canonical-input--nodes first-input)))
         (second (car (ebox-canonical-input--nodes second-input)))
         (entries (list (list :node first :column 1 :column-span 1)
                        (list :node second :column 2 :column-span 1)))
         (rendered (make-hash-table :test 'eq))
         (tracks (ebox-grid--normalize-tracks '((fr 1) (fr 1)) 'columns))
         (minimum (ebox--string-pixel-width "abcdefgh"))
         (available (+ minimum 2)))
    (puthash first (ebox-render first-input) rendered)
    (puthash second (ebox-render second-input) rendered)
    (should (equal (ebox-grid--resolve-sizes
                    tracks 2 'columns entries rendered 0 available)
                   (list minimum 2)))
    (should-not (ebox-grid--content-independent-columns-p
                 tracks 2 available (list first second)))))

(ert-deftest ebox-css-grid-percent-child-sizes-use-final-cell ()
  "Relative children re-render once the grid area has definite dimensions."
  (let ((original (symbol-function 'ebox--render-with-cache)) sizes)
    (cl-letf (((symbol-function 'ebox--render-with-cache)
               (lambda (node &rest arguments)
                 (let ((result (apply original node arguments)))
                   (when (and (equal (plist-get node :width) '(% 50))
                              (equal (plist-get node :height) '(% 50)))
                     (push (list (ebox--string-max-pixel-width result)
                                 (ebox-string-height result)) sizes))
                   result))))
      (ebox-render
       (ebox-build '(grid :width (px 200) :height (lh 12)
                         :grid-template-columns ((px 100) (px 100))
                         :grid-template-rows ((lh 6))
                         :align-content start
                         (box :width (% 50) :height (% 50) "A")
                         (box "B")))))
    (should (= (caar sizes) 50))
    (should (= (cadar sizes) 3))))

(ert-deftest ebox-css-grid-indefinite-fractions-size-from-content ()
  "An intrinsic Grid width does not collapse fractional tracks to zero."
  (let ((rendered (make-hash-table :test 'eq))
        (tracks (ebox-grid--normalize-tracks '((fr 1) (fr 1)) 'columns))
        (entries '((:node first :column 1 :column-span 1)
                   (:node second :column 2 :column-span 1))))
    (puthash 'first "abcdefgh" rendered)
    (puthash 'second "X" rendered)
    (let ((width (ebox--string-pixel-width "abcdefgh")))
      (should (equal (ebox-grid--resolve-sizes
                      tracks 2 'columns entries rendered 0 nil)
                     (list width width))))))

(ert-deftest ebox-css-grid-cyclic-percentage-gap-resolves-after-intrinsic-size ()
  "A cyclic Grid gap uses the intrinsic extent and can overflow it."
  (let ((columns (ebox-grid--final-content-layout
                  '(40 40) '(% 25) 'width nil 'start nil))
        (rows (ebox-grid--final-content-layout
               '(4 4) '(% 25) 'height nil 'start nil)))
    (should (equal (plist-get columns :sizes) '(40 40)))
    (should (= (plist-get columns :between) 20))
    (should (= (plist-get columns :target) 80))
    (should (= (plist-get rows :between) 2))
    (should (= (plist-get rows :target) 8))))

(ert-deftest ebox-css-flex-percentage-edges-use-container-before-item-allocation ()
  "Assigned item widths do not become percentage padding and margin bases."
  (let* ((input (ebox-build
                 '(flex :width (px 200)
                        (box :flex-basis (px 60)
                             :padding ((lh 0) (% 10))
                             :margin ((lh 0) (% 5)) "X"))))
         (child (car (ebox-tree-layout-children
                      (car (ebox-canonical-input--nodes input)))))
         (rendered (ebox-render input))
         (position (string-match "X" rendered)))
    (should position)
    (should (= (ebox--string-pixel-width (substring rendered 0 position)) 30))
    (should (equal (plist-get child :padding-left-pixel) '(% 10)))
    (should (equal (plist-get child :margin-left-pixel) '(% 5)))))

(ert-deftest ebox-css-grid-cyclic-gap-overflows-intrinsic-box-without-growing-it ()
  "Cyclic gaps overflow the auto-sized box while hidden overflow clips them."
  (dolist (overflow '(hidden visible))
    (let* ((vertical
            (ebox-render
             (ebox-build
              `(grid :width (px 40) :overflow ,overflow
                     :grid-template-columns ((px 40))
                     :grid-template-rows ((lh 4) (lh 4))
                     :row-gap (% 25) (box "A") (box "B")))))
           (horizontal
            (ebox-render
             (ebox-build
              `(grid :width max-content :overflow ,overflow
                     :grid-template-columns ((px 40) (px 40))
                     :column-gap (% 25) (box "A") (box "B"))))))
      (should (= (ebox-string-height vertical) (if (eq overflow 'hidden) 8 10)))
      (should (= (ebox--rendered-intrinsic-size horizontal :width) 80))
      (should (= (ebox--string-max-pixel-width horizontal)
                 (if (eq overflow 'hidden) 80 100))))))

(ert-deftest ebox-css-flex-preserves-nested-grid-intrinsic-extents ()
  "A Grid child's cyclic gap spill does not enlarge its Flex layout size."
  (let* ((input
          (ebox-build
           '(flex :width (px 40) :flex-direction column :overflow visible
                  (grid :overflow visible
                        :grid-template-columns ((px 40))
                        :grid-template-rows ((lh 4) (lh 4))
                        :row-gap (% 25) (box "A") (box "B"))
                  (box "Z"))))
         (rendered (ebox-render input)))
    (should (= (ebox--rendered-intrinsic-size rendered :height) 9))
    (should (= (ebox-string-height rendered) 11))))

(provide 'ebox-css-flex-grid-tests)
;;; ebox-css-flex-grid-tests.el ends here
