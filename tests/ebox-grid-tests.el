;;; ebox-grid-tests.el --- Ebox grid layout tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'seq)

(load-file (expand-file-name "../ebox.el"
                            (file-name-directory (or load-file-name
                                                     buffer-file-name))))

(defun ebox-grid-test--plain (node)
  "Render NODE and remove text properties."
  (substring-no-properties (ebox-render node)))

(ert-deftest ebox-grid-renders-row-major-cells ()
  "Grid should place unpositioned children in row-major order."
  (let ((plain
         (ebox-grid-test--plain
          (ebox-test-grid
           :grid-template-columns '((20) (20))
           :grid-template-rows '(1 1)
           :gap '(0 (1))
           (ebox-test-box (ebox-test-text "A"))
           (ebox-test-box (ebox-test-text "B"))
           (ebox-test-box (ebox-test-text "C"))
           (ebox-test-box (ebox-test-text "D"))))))
    (should (string-match-p "A.*B" plain))
    (should (string-match-p "C.*D" plain))))

(ert-deftest ebox-grid-supports-fractional-columns ()
  "Fractional tracks should fill a definite grid width."
  (let* ((node (ebox-test-grid
                :width '(120)
                :grid-template-columns '((fr 1) (fr 2))
                (ebox-test-box (ebox-test-text "A"))
                (ebox-test-box (ebox-test-text "B"))))
         (lines (ebox-string-lines (ebox-render node))))
    (should (= (length lines) 1))
    (should (= (ebox--string-pixel-width (car lines)) 120))))

(ert-deftest ebox-grid-intrinsic-track-keywords-use-distinct-measures ()
  "min-content and max-content should reuse Ebox intrinsic measurements."
  (let* ((left (ebox-test-root (ebox-test-text "alpha beta")))
         (right (ebox-test-root (ebox-test-text "gamma delta epsilon")))
         (entries (list (list :node left :column 1 :column-span 1)
                        (list :node right :column 2 :column-span 1)))
         (rendered (make-hash-table :test #'eq))
         (tracks (ebox-grid--normalize-tracks
                  '(min-content max-content) 'columns)))
    (puthash left "alpha beta" rendered)
    (puthash right "gamma delta epsilon" rendered)
    (let ((sizes (ebox-grid--resolve-sizes
                  tracks 2 'columns entries rendered 0 nil)))
      (should
       (= (car sizes) (ebox--line-min-content-pixel "alpha beta")))
      (should
       (= (cadr sizes) (ebox--string-pixel-width "gamma delta epsilon")))
      (should (< (car sizes) (ebox--string-pixel-width "alpha beta"))))))

(ert-deftest ebox-grid-repeat-expands-a-complete-track-list ()
  "repeat should duplicate its ordered track-list body."
  (should
   (equal
    (ebox-grid--normalize-tracks '((repeat 2 (auto (fr 1)))) 'columns)
    '((:kind auto :factor 0) (:kind fr :factor 1)
      (:kind auto :factor 0) (:kind fr :factor 1)))))

(ert-deftest ebox-grid-repeated-render-reuses-construction-time-config ()
  "Grid render and resize paths should not reparse canonical track config."
  (let* ((node (ebox-test-grid :width '(120)
                          :grid-template-columns '((fr 1) (fr 2))
                          (ebox-test-box (ebox-test-text "A"))
                          (ebox-test-box (ebox-test-text "B"))))
         (calls 0)
         (original (symbol-function 'ebox-grid--normalize-config-props)))
    (cl-letf (((symbol-function 'ebox-grid--normalize-config-props)
               (lambda (props)
                 (cl-incf calls)
                 (funcall original props))))
      (ebox-render node)
      (ebox-render node))
    (should (zerop calls))))

(ert-deftest ebox-grid-minmax-fractional-columns-fill-and-shrink ()
  "Zero-minimum fractional maxima should remain responsive to width."
  (dolist (width '(120 60))
    (let* ((node (ebox-test-grid
                  :width (list width)
                  :grid-template-columns
                  '((minmax (0) (fr 1)) (minmax (0) (fr 2)))
                  (ebox-test-box (ebox-test-text "A") :width 'stretch)
                  (ebox-test-box (ebox-test-text "B") :width 'stretch)))
           (lines (ebox-string-lines (ebox-render node))))
      (should (= (ebox--string-max-pixel-width
                  (car lines)) width)))))

(ert-deftest ebox-grid-stretch-children-fill-fractional-tracks ()
  "Stretch-width children must reflow to their assigned fractional tracks."
  (let* ((left (ebox-test-box (ebox-test-text "left") :width 'stretch))
         (calls 0)
         (entry-left (list :node left :column 1 :column-span 1))
         (rendered (make-hash-table :test #'eq)))
    (puthash left "left" rendered)
    (cl-letf (((symbol-function 'ebox--render-with-cache)
               (lambda (&rest _)
                 (cl-incf calls)
                 "track-width")))
      (should (equal "track-width"
                     (ebox-grid--entry-source
                      entry-left rendered 100 '(:justify-items stretch))))
      (should (= calls 1)))))

(defun ebox-grid-test--background-widths (rendered color)
  "Return the width painted COLOR on each line of RENDERED."
  (mapcar
   (lambda (line)
     (let ((start 0) (width 0))
       (while (< start (length line))
         (let ((end (next-single-property-change
                     start 'face line (length line))))
           (when (equal (plist-get (get-text-property start 'face line)
                                  :background)
                        color)
             (cl-incf width (ebox--string-pixel-width
                             (substring line start end))))
           (setq start end)))
       width))
   (ebox-string-lines rendered)))

(ert-deftest ebox-grid-block-alignment-stretches-the-item-background ()
  "Default and explicit stretch paint the item; other alignments position it."
  (dolist (case '((nil (40 40 40)) (normal (40 40 40))
                  (stretch (40 40 40)) (start (40 0 0))
                  (center (0 40 0)) (end (0 0 40))
                  (flex-start (40 0 0)) (flex-end (0 0 40))))
    (dolist (height '(nil auto))
      (let* ((form `(grid :width (px 40)
                         :grid-template-columns ((fr 1))
                         :grid-template-rows ((lh 3))
                         ,@(when (car case) (list :align-items (car case)))
                    (box :bgcolor "#ddeeff"
                         ,@(when height (list :height height)) "A")))
             (rendered (ebox-render (ebox-build form))))
        (ert-info ((format "Grid alignment %S, height %S" (car case) height))
          (should (equal (ebox-grid-test--background-widths rendered "#ddeeff")
                         (cadr case))))))))

(ert-deftest ebox-grid-stretch-preserves-height-constraints-and-edges ()
  "Track stretch respects explicit heights, min/max constraints and margins."
  (dolist (case '((nil (40 40 40 40 40))
                  ((:height (lh 1)) (40 0 0 0 0))
                  ((:height (% 40)) (40 40 0 0 0))
                  ((:height min-content) (40 0 0 0 0))
                  ((:height max-content) (40 0 0 0 0))
                  ((:height fit-content) (40 0 0 0 0))
                  ((:min-height (lh 2)) (40 40 40 40 40))
                  ((:max-height (lh 2)) (40 40 0 0 0))
                  ((:min-height (lh 3) :max-height (lh 2)) (40 40 40 0 0))
                  ((:margin ((lh 1) (px 0))) (0 40 40 40 0))
                  ((:padding ((lh 1) (px 0))) (40 40 40 40 40))
                  ((:box-sizing border-box :padding ((lh 1) (px 0)))
                   (40 40 40 40 40))))
    (let* ((rendered
            (ebox-render
             (ebox-build
              `(grid :width (px 40) :grid-template-columns ((fr 1))
                     :grid-template-rows ((lh 5))
                 (box :bgcolor "#ddeeff" ,@(car case) "A"))))))
      (ert-info ((format "Grid item properties %S" (car case)))
        (should (equal (ebox-grid-test--background-widths rendered "#ddeeff")
                       (cadr case)))))))

(ert-deftest ebox-grid-align-self-overrides-container-block-alignment ()
  "The child's align-self controls both used height and vertical position."
  (dolist (case '((start stretch (40 40 40))
                  (start normal (40 40 40))
                  (stretch start (40 0 0))
                  (stretch center (0 40 0))
                  (stretch end (0 0 40))
                  (end auto (0 0 40))))
    (let ((rendered
           (ebox-render
            (ebox-build
             `(grid :width (px 40) :grid-template-columns ((fr 1))
                    :grid-template-rows ((lh 3)) :align-items ,(nth 0 case)
                (box :bgcolor "#ddeeff" :align-self ,(nth 1 case) "A"))))))
      (should (equal (ebox-grid-test--background-widths rendered "#ddeeff")
                     (nth 2 case))))))

(ert-deftest ebox-grid-stretched-height-preserves-inline-alignment ()
  "Stretching the block axis must preserve a naturally sized inline axis."
  (dolist (justify '(start center end))
    (let* ((rendered
            (ebox-render
             (ebox-build
              `(grid :width (px 40) :grid-template-columns ((fr 1))
                     :grid-template-rows ((lh 3)) :justify-items ,justify
                 (box :bgcolor "#ddeeff" "A")))))
           (width (ebox--string-pixel-width "A"))
           (offset (pcase justify ('center (/ (- 40 width) 2))
                          ('end (- 40 width)) (_ 0)))
           (first (car (ebox-string-lines rendered))))
      (should (equal (ebox-grid-test--background-widths rendered "#ddeeff")
                     (make-list 3 width)))
      (should (= (ebox--string-pixel-width
                  (substring first 0 (string-match "A" first)))
                 offset)))))

(ert-deftest ebox-grid-stretch-paints-composites-across-row-spans ()
  "Nested layouts stretch across the full row span including intervening gaps."
  (dolist (kind '(box column row flex grid))
    (let ((rendered
           (ebox-render
            (ebox-build
             `(grid :width (px 40) :grid-template-columns ((fr 1))
                    :grid-template-rows ((lh 2) (lh 2)) :row-gap (lh 1)
                (,kind :grid-row (1 :span 2) :bgcolor "#ddeeff"
                       (box "A")))))))
      (ert-info ((format "Stretched Grid item layout %S" kind))
        (should (equal (ebox-grid-test--background-widths rendered "#ddeeff")
                       '(40 40 40 40 40)))))))

(ert-deftest ebox-grid-stretched-item-commits-preserve-source-geometry ()
  "Retained updates recompute stretch without retaining its temporary Box copy."
  (with-temp-buffer
    (dolist (case '((40 3 stretch) (60 5 stretch)
                    (60 5 start) (40 3 stretch)))
      (let ((input
             (ebox-build
              `(grid :key root :width (px ,(nth 0 case))
                     :grid-template-columns ((fr 1))
                     :grid-template-rows ((lh ,(nth 1 case)))
                     :align-items ,(nth 2 case)
                 (box :key item :bgcolor "#ddeeff" "A")))))
        (if (ebox--buffer-render-state (current-buffer))
            (ebox-commit (current-buffer) input)
          (ebox-render-to-buffer (current-buffer) input))
        (let* ((state (ebox--buffer-render-state (current-buffer)))
               (child (car (ebox-tree-node-children
                            (plist-get state :root-node))))
               (actual (buffer-string))
               (fresh (ebox-render input)))
          (should (memq (ebox-get child :height) '(nil auto)))
          (should (eq child (gethash (ebox-get child :region-id)
                                     (plist-get state :region-box-table))))
          (should (equal (ebox-grid-test--background-widths actual "#ddeeff")
                         (ebox-grid-test--background-widths fresh "#ddeeff")))
          (should (equal (substring-no-properties actual)
                         (substring-no-properties fresh))))))))

(ert-deftest ebox-grid-renders-assigned-cell-width-once ()
  "Final Grid assembly must reuse the width-sized cell's complete output."
  (let* ((cell-region 91001)
         (input
          (ebox-test-grid
           :width '(80)
           :grid-template-columns '((minmax (0) (fr 1)) (fr 1))
           :column-gap '(4)
           (ebox-test-box
            :region-id cell-region :width 'stretch :wrap-mode 'word
            :color "#112233" :bgcolor "#ddeeff"
            (ebox-test-text "alpha beta gamma delta epsilon zeta eta theta"))
           (ebox-test-box (ebox-test-text "peer") :width 'stretch)))
         (original (symbol-function 'ebox--render-box))
         contexts
         sized-output
         output)
    (cl-letf (((symbol-function 'ebox--render-box)
               (lambda (box)
                 (let ((rendered (funcall original box)))
                   (when (eq (ebox-get box :region-id) cell-region)
                     (push (list ebox-viewport-width
                                 ebox--intrinsic-layout-measurement)
                           contexts)
                     (when (and (equal ebox-viewport-width 38)
                                (not ebox--intrinsic-layout-measurement))
                       (setq sized-output rendered)))
                   rendered))))
      (setq output (ebox-render input)))
    ;; The intrinsic pass is still required by the general Grid algorithm;
    ;; one final render establishes both row height and the published cell.
    (should (= 1 (cl-count '(nil t) contexts :test #'equal)))
    (should (= 1 (cl-count '(38 nil) contexts :test #'equal)))
    (let ((face (get-text-property
                 (string-match "alpha" sized-output) 'face sized-output)))
      (should face)
      (should (equal face (get-text-property
                          (string-match "alpha" output) 'face output))))
    (let ((lines (ebox-string-lines output)))
      (should (> (length lines) 1))
      (should (equal (mapcar #'ebox--string-pixel-width lines)
                     (make-list (length lines) 80))))))

(ert-deftest ebox-grid-definite-stretched-cells-skip-unused-intrinsic-output ()
  "Definite fixed/fr columns need only the stretched cell's final output."
  (dolist (width '(80 120))
    (dolist (cell-width '(nil auto stretch))
      (let* ((cell-region 91002)
             (input
              (ebox-test-grid
               :width (list width)
               :grid-template-columns '((fr 1) (28)) :column-gap '(4)
               (apply #'ebox-test-box
                      (append
                       (list :region-id cell-region :wrap-mode 'word
                             :color "#112233" :bgcolor "#ddeeff")
                       (and cell-width (list :width cell-width))
                       (list
                        (ebox-test-text
                         "alpha beta gamma delta epsilon zeta eta theta iota kappa"))))
               (ebox-test-box (ebox-test-text "peer") :width 'stretch)))
             (original (symbol-function 'ebox--render-box))
             (intrinsic-count 0)
             (assigned-count 0)
             fast slow)
        (cl-letf (((symbol-function 'ebox--render-box)
                   (lambda (box)
                     (when (eq (ebox-get box :region-id) cell-region)
                       (if (and (null ebox-viewport-width)
                                ebox--intrinsic-layout-measurement)
                           (cl-incf intrinsic-count)
                         (when (equal ebox-viewport-width (- width 32))
                           (cl-incf assigned-count))))
                     (funcall original box))))
          (setq fast (ebox-render input)))
        (should (zerop intrinsic-count))
        (should (= assigned-count 1))
        (cl-letf (((symbol-function 'ebox-grid--content-independent-columns-p)
                   (lambda (&rest _) nil)))
          (setq slow (ebox-render input)))
        (should (equal-including-properties fast slow))))))

(ert-deftest ebox-grid-intrinsic-elision-preserves-spans-nesting-and-row-height ()
  "Reusing final cell output preserves wrapped rows, spans, and paint."
  (dolist (alignment '(start center end stretch))
    (let* ((input
            (ebox-test-grid
             :width '(96) :grid-template-columns '((fr 1) (fr 1))
             :grid-template-rows '(auto auto auto)
             :column-gap '(4) :row-gap 1 :align-items alignment
             (ebox-test-column
              :grid-column '(1 :span 2) :width 'stretch
              :color "#123456" :bgcolor "#ddeeff"
              (ebox-test-text "spanning header")
              (ebox-test-row
               (ebox-test-box (ebox-test-text "control") :padding '(0 (2)))
               (ebox-test-box (ebox-test-text "action") :padding '(0 (2)))))
             (ebox-test-box
              :grid-row '(2 :span 2) :grid-column 1
              :width 'stretch :wrap-mode 'word :min-width 'min-content
              (ebox-test-text
               "alpha beta gamma delta epsilon zeta eta theta iota kappa"))
             (ebox-test-box :grid-row 2 :grid-column 2 :width 'stretch
                            (ebox-test-text "peer"))
             (ebox-test-box :grid-row 3 :grid-column 2 :width 'stretch
                            (ebox-test-text "tail"))))
           (fast (ebox-render input))
           slow)
      (cl-letf (((symbol-function 'ebox-grid--content-independent-columns-p)
                 (lambda (&rest _) nil)))
        (setq slow (ebox-render input)))
      (should (equal-including-properties fast slow))
      (should (> (ebox-string-height fast) 3)))))

(ert-deftest ebox-grid-keeps-consumed-intrinsic-output ()
  "Content tracks, natural alignment, and indefinite sizes keep measurement."
  (dolist (case
           '((:width (80) :columns (auto (fr 1)))
             (:width (80) :columns (min-content (fr 1)))
             (:width (80) :columns (max-content (fr 1)))
             (:width (80) :columns ((minmax (0) (fr 1)) (fr 1)))
             (:width (80) :columns ((40)) :implicit t)
             (:width max-content :columns ((fr 1) (fr 1)))
             (:width (0) :columns ((fr 1) (fr 1)))
             (:width (80) :columns ((fr 1) (fr 1)) :justify start)
             (:width (80) :columns ((fr 1) (fr 1)) :justify center)
             (:width (80) :columns ((fr 1) (fr 1)) :justify end)
             (:width (80) :columns ((fr 1) (fr 1)) :cell-width (20))))
    (let* ((cell-region 91003)
           (input
            (ebox-test-grid
             :width (plist-get case :width)
             :grid-template-columns (plist-get case :columns)
             :grid-auto-flow (if (plist-get case :implicit) 'column 'row)
             :justify-items (or (plist-get case :justify) 'stretch)
             (ebox-test-box
              :region-id cell-region
              :width (or (plist-get case :cell-width) 'stretch)
              (ebox-test-text "natural content"))
             (ebox-test-box (ebox-test-text "peer") :width 'stretch)))
           (original (symbol-function 'ebox--render-box))
           (intrinsic-count 0))
      (cl-letf (((symbol-function 'ebox--render-box)
                 (lambda (box)
                   (when (and (eq (ebox-get box :region-id) cell-region)
                              (null ebox-viewport-width)
                              ebox--intrinsic-layout-measurement)
                     (cl-incf intrinsic-count))
                   (funcall original box))))
        (ebox-render input))
      (should (> intrinsic-count 0)))))

(ert-deftest ebox-grid-missing-intrinsic-output-requires-unconditional-stretch ()
  "Only unconditional width-sized rendering may consume an unmeasured cell."
  (let* ((node (ebox-test-root
                (ebox-test-box (ebox-test-text "cell") :width 'stretch)))
         (entry (list :node node))
         (rendered (make-hash-table :test #'eq))
         (calls 0))
    (cl-letf (((symbol-function 'ebox--render-with-cache)
               (lambda (&rest _)
                 (cl-incf calls)
                 "assigned")))
      (should (equal "assigned"
                     (ebox-grid--entry-source
                      entry rendered 40 '(:justify-items stretch))))
      (should-error
       (ebox-grid--entry-source entry rendered 40 '(:justify-items start)))
      (plist-put node :width '(20))
      (should-error
       (ebox-grid--entry-source entry rendered 40 '(:justify-items stretch)))
      (should (= calls 1)))))

(ert-deftest ebox-grid-constrains-auto-width-children-to-track-size ()
  "Auto-width grid children should render within their assigned track."
  (let* ((ebox-viewport-width 120)
         (node (ebox-test-grid
                :width '(120)
                :grid-template-columns '((50) (50))
                :gap '(0 (10))
                :border "#334155"
                (ebox-test-box (ebox-test-text "A\nA-long") :padding '(0 (4)))
                (ebox-test-box (ebox-test-text "B\nB-long") :padding '(0 (4)))))
         (lines (ebox-string-lines (ebox-render node)))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (equal widths (make-list (length widths) 120)))))

(ert-deftest ebox-grid-composite-auto-row-respects-track-width ()
  "A composite auto-width row must not duplicate its Grid track viewport."
  (let* ((node (ebox-test-grid
                :width '(120)
                :grid-template-columns '((120))
                (ebox-test-row
                 (ebox-test-box (ebox-test-text "Left") :border '(1 solid))
                 (ebox-test-box (ebox-test-text "Right") :border '(1 solid)))))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines (ebox-render node)))))
    (should (equal widths '(120)))))

(ert-deftest ebox-grid-sizes-auto-row-after-assigned-width-wrap ()
  "Auto rows should use the height of width-constrained child content."
  (let* ((node (ebox-test-grid
                :width '(40)
                :grid-template-columns '((38))
                :border "#334155"
                (ebox-test-box
                 (ebox-test-text "WIDE CONTENT WIDE CONTENT WIDE CONTENT WIDE CONTENT")
                 :wrap-mode 'word)))
         (lines (ebox-string-lines (ebox-render node)))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (= (length lines) 2))
    (should (equal widths (make-list (length widths) 40)))))

(ert-deftest ebox-grid-sizes-column-row-after-assigned-width-wrap ()
  "A composite Column row should use its final track-width text height."
  (let* ((node
          (ebox-test-grid
           :width '(20)
           :grid-template-columns '((20))
           :grid-auto-rows 'auto
           (ebox-test-column
            :width '(20)
            (ebox-test-box
             (ebox-test-text "fractional symbols\n1fr distributes by weight")
             :padding '(0 (2)) :border "#B85C3C"
             :wrap-mode 'word)
            (ebox-test-box (ebox-test-text "body") :height 1))))
         (lines (ebox-string-lines (ebox-render node)))
         (plain (mapcar #'substring-no-properties lines)))
    (should (> (length lines) 3))
    (should (equal (mapcar #'ebox--string-pixel-width lines)
                   (make-list (length lines) 20)))
    (should (cl-some (lambda (line) (string-match-p "weight" line)) plain))
    (should (string-match-p "body" (car (last plain))))))

(ert-deftest ebox-grid-aligns-every-line-before-border-render ()
  "Grid wrapper borders should stay on one right edge across child lines."
  (let* ((node (ebox-test-grid
                :width '(120)
                :grid-template-columns '((30) auto (fr 1))
                :grid-template-rows '(2)
                :gap '(1 (4))
                :justify-content 'space-between
                :border "#334155"
                (ebox-test-box (ebox-test-text "FIXED\n30 PX"))
                (ebox-test-box (ebox-test-text "AUTO\nINTRINSIC"))
                (ebox-test-box (ebox-test-text "1FR\nREMAINDER"))))
         (lines (ebox-string-lines (ebox-render node)))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (equal widths (make-list (length widths) 120)))))

(ert-deftest ebox-grid-keeps-padded-items-inside-column-width ()
  "Stack padding should use the widest Grid line instead of its first line."
  (let* ((header (ebox-test-box (ebox-test-text "Header") :width '(720)))
         (grid (ebox-test-grid
                :width '(718)
                :grid-template-columns '((220) (fr 1))
                :gap '(1 (12))
                :border "#C97252"
                (ebox-test-box (ebox-test-text "Fixed") :width '(196)
                             :padding '(1 (12)))
                (ebox-test-box (ebox-test-text "Fractional") :width '(460)
                             :padding '(1 (12)))))
         (lines (ebox-string-lines (ebox-render (ebox-test-column header grid))))
         (widths (mapcar #'ebox--string-pixel-width lines)))
    (should (= (apply #'max widths) 720))))

(ert-deftest ebox-grid-supports-explicit-placement-and-span ()
  "Explicit placement should support a cell spanning two columns."
  (let ((plain
         (ebox-grid-test--plain
          (ebox-test-grid
           :grid-template-columns '((20) (20))
           :grid-template-rows '(1 1)
           (ebox-test-box (ebox-test-text "Header") :grid-column '(1 :span 2))
           (ebox-test-box (ebox-test-text "Left") :grid-row 2 :grid-column 1)
           (ebox-test-box (ebox-test-text "Right") :grid-row 2 :grid-column 2)))))
    (should (string-match-p "Header" plain))
    (should (string-match-p "Left.*Right" plain))))

(ert-deftest ebox-grid-grown-rows-keep-independent-occupancy ()
  "Growing several rows must allocate a distinct occupancy vector per row."
  (let* ((original (ebox-grid--occupancy 1 2))
         (grown (ebox-grid--grow original 3 2)))
    (should (eq (aref original 0) (aref grown 0)))
    (should-not (eq (aref grown 1) (aref grown 2)))
    (aset (aref grown 1) 1 'occupied)
    (should-not (aref (aref grown 0) 1))
    (should-not (aref (aref grown 2) 1)))
  (let* ((input
          (ebox-test-grid
           :grid-template-columns '((20) (20)) :row-gap 0
           (ebox-test-box :grid-row 1 :grid-column '(1 :span 2)
                          (ebox-test-text "header"))
           (ebox-test-box :grid-row '(2 :span 2) :grid-column 1
                          (ebox-test-text "spanned"))
           (ebox-test-box :grid-row 2 :grid-column 2
                          (ebox-test-text "middle"))
           (ebox-test-box :grid-row 3 :grid-column 2
                          (ebox-test-text "last"))))
         (lines (seq-remove
                 #'string-blank-p
                 (mapcar #'substring-no-properties
                         (ebox-string-lines (ebox-render input))))))
    (should (= (length lines) 3))
    (should (string-match-p "header" (nth 0 lines)))
    (should (string-match-p "spanned.*middle" (nth 1 lines)))
    (should (string-match-p "last" (nth 2 lines)))))

(ert-deftest ebox-grid-zero-row-gap-adds-no-display-line ()
  "Row gaps contribute exactly their declared line count, including zero."
  (dolist (gap '(0 1 2))
    (let* ((input
            (ebox-test-grid
             :grid-template-columns '((20) (20))
             :grid-template-rows '(1 2) :row-gap gap
             (ebox-test-box :grid-row 1 :grid-column '(1 :span 2)
                            (ebox-test-text "header"))
             (ebox-test-box :grid-row 2 :grid-column 1
                            (ebox-test-text "body\ntail"))
             (ebox-test-box :grid-row 2 :grid-column 2
                            (ebox-test-text ""))))
           (lines (ebox-string-lines (ebox-render input))))
      (should (= (length lines) (+ 3 gap)))
      (should (string-match-p "header" (nth 0 lines)))
      (dotimes (index gap)
        (should (string-blank-p (nth (1+ index) lines))))
      (should (string-match-p "body" (nth (1+ gap) lines)))
      (should (string-match-p "tail" (nth (+ 2 gap) lines))))))

(ert-deftest ebox-grid-row-spans-preserve-text-across-gaps ()
  "A spanning cell retains text and paint across rows and positive gaps."
  (dolist (gap '(0 1 2))
    (dolist (alignment '(start center end stretch))
      (let* ((input
              (ebox-test-grid
               :grid-template-columns '((20) (20))
               :grid-template-rows '(2 2) :row-gap gap :align-items alignment
               (ebox-test-box
                :grid-row '(1 :span 2) :grid-column 1
                :color "#123456"
                :surface-properties '(help-echo "spanning-help")
                (ebox-test-text "spanned\ncontinued"))
               (ebox-test-box :grid-row 1 :grid-column 2
                              (ebox-test-text "top"))
               (ebox-test-box :grid-row 2 :grid-column 2
                              (ebox-test-text "bottom"))))
             (rendered (ebox-render input))
             (lines (ebox-string-lines rendered))
             (start (pcase alignment
                      ('center (/ (+ 2 gap) 2))
                      ('end (+ 2 gap))
                      (_ 0))))
        (should (= (length lines) (+ 4 gap)))
        (should (string-match-p "spanned" (nth start lines)))
        (should (string-match-p "continued" (nth (1+ start) lines)))
        (dotimes (index gap)
          (should-not (string-match-p "top\\|bottom" (nth (+ 2 index) lines))))
        (let ((face (get-text-property (string-match "spanned" rendered)
                                       'face rendered)))
          (should face)
          (should (equal face (get-text-property
                               (string-match "continued" rendered)
                               'face rendered)))
          (dolist (label '("spanned" "continued"))
            (should (equal "spanning-help"
                           (get-text-property (string-match label rendered)
                                              'help-echo rendered)))))))))

(ert-deftest ebox-grid-zero-height-track-contributes-only-its-gap ()
  "A zero-height track adds no text line, while declared gaps remain real."
  (dolist (gap '(0 1 2))
    (dolist (rows '((0 1) (1 0)))
      (let* ((leading-zero-p (zerop (car rows)))
             (input
              (ebox-build
               `(grid :width (px 40) :grid-template-columns ((px 40))
                      :grid-template-rows ,(mapcar (lambda (n) (list 'lh n)) rows)
                      :row-gap (lh ,gap)
                 (text ,(if leading-zero-p "hidden" "visible"))
                 (text ,(if leading-zero-p "visible" "hidden")))))
             (rendered (ebox-render input))
             (lines (ebox-string-lines rendered)))
        (should (= (length lines) (1+ gap)))
        (should-not (string-match-p "hidden" rendered))
        (should (string-match-p "visible"
                                (nth (if leading-zero-p gap 0) lines)))
        (dolist (line (if leading-zero-p (butlast lines) (cdr lines)))
          (should (string-blank-p line)))))))

(ert-deftest ebox-grid-row-span-preserves-lines-across-zero-height-track ()
  "A zero-height row within a span changes offsets only through its gaps."
  (dolist (gap '(0 1 2))
    (let* ((height (+ 2 (* 2 gap)))
           (labels (cl-loop for index below height
                            collect (format "line-%d" index)))
           (input
            (ebox-test-grid
             :width '(40) :grid-template-columns '((20) (20))
             :grid-template-rows '(1 0 1) :row-gap gap
             (ebox-test-box
              :grid-row '(1 :span 3) :grid-column 1
              :surface-properties '(help-echo "spanning-help")
              (ebox-test-text (mapconcat #'identity labels "\n")))
             (ebox-test-box :grid-row 1 :grid-column 2
                            (ebox-test-text "top"))
             (ebox-test-box :grid-row 2 :grid-column 2
                            (ebox-test-text "hidden"))
             (ebox-test-box :grid-row 3 :grid-column 2
                            (ebox-test-text "bottom"))))
           (rendered (ebox-render input))
           (lines (ebox-string-lines rendered)))
      (should (= (length lines) height))
      (should-not (string-match-p "hidden" rendered))
      (cl-loop for label in labels
               for line in lines
               do (should (string-match-p label line))
               do (should (equal "spanning-help"
                                 (get-text-property (string-match label line)
                                                    'help-echo line)))))))

(ert-deftest ebox-grid-uses-implicit-track-templates ()
  "Implicit columns should use `:grid-auto-columns' when they grow."
  (let* ((node (ebox-test-grid
                :grid-template-columns '((20))
                :grid-auto-columns '((30))
                :grid-auto-flow 'column
                (ebox-test-box (ebox-test-text "A"))
                (ebox-test-box (ebox-test-text "B"))))
         (line (car (ebox-string-lines (ebox-render node)))))
    (should (= (ebox--string-pixel-width line) 50))))

(ert-deftest ebox-grid-preserves-template-width-when-rows-grow ()
  "Implicit rows should retain the declared template column count."
  (let ((plain
         (ebox-grid-test--plain
          (ebox-test-grid
           :grid-template-columns '((20) (20) (20))
           (ebox-test-box (ebox-test-text "A"))
           (ebox-test-box (ebox-test-text "B"))
           (ebox-test-box (ebox-test-text "C"))
           (ebox-test-box (ebox-test-text "D"))
           (ebox-test-box (ebox-test-text "E"))
           (ebox-test-box (ebox-test-text "F"))))))
    (dolist (letter '("A" "B" "C" "D" "E" "F"))
      (should (string-match-p letter plain)))))

(ert-deftest ebox-grid-supports-repeat-minmax-and-content-alignment ()
  "Grid should normalize repeat/minmax tracks and align fixed tracks."
  (let* ((node (ebox-test-grid
                :width '(100)
                :justify-content 'center
                :grid-template-columns '((minmax (20) (30)) (repeat 1 (20)))
                (ebox-test-box (ebox-test-text "A"))
                (ebox-test-box (ebox-test-text "B"))))
         (line (car (ebox-string-lines (ebox-render node)))))
    (should (= (ebox--string-pixel-width line) 100))
    (should (= (length (seq-filter (lambda (char) (= char ?\s)) line))
               4))))

(ert-deftest ebox-grid-validates-flow-and-spans ()
  "Invalid flow and non-positive spans should be rejected."
  (should-error
   (ebox-render
    (ebox-test-grid :grid-auto-flow 'diagonal (ebox-test-box (ebox-test-text "A")))))
  (should-error
   (ebox-render
    (ebox-test-grid
     (ebox-test-box (ebox-test-text "A") :grid-column-span 0))))
  (should-error
   (ebox-render
    (ebox-test-grid
     (ebox-test-box (ebox-test-text "A") :grid-column 0)))))

(ert-deftest ebox-grid-rejects-invalid-ecss-placement-before-layout ()
  "ECSS rules should reject invalid Grid placement before layout runs."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
    (dolist (declarations
             '((:grid-column-span 0)
               (:grid-row-span 0)
               (:grid-column 0)
               (:grid-row (1 :span 0))))
      (should-error (ebox-style-add-rule ".invalid" declarations)))
    (dolist (placement '(1 (1) (1 :span 2) (1 3)))
      (should (ebox-style-add-rule ".valid" (list :grid-column placement))))))

(ert-deftest ebox-grid-region-update-reflows-grid-child ()
  "Replacing one typed Grid child should reflow and preserve its sibling."
  (let* ((left (ebox-test-box (ebox-test-text "A") :source-identity 'left :width 20))
         (right (ebox-test-box (ebox-test-text "B") :id "right" :width 20))
         (node (ebox-test-grid :grid-template-columns '((20) (20)) left right))
         (buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-grid-update*") node)))
    (unwind-protect
        (progn
          (should (with-current-buffer buffer
                    (and (string-match-p "A" (buffer-string))
                         (string-match-p "B" (buffer-string)))))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'left
             (ebox-test-box (ebox-test-text "Updated") :source-identity 'left :width 20))
            (ebox-commit buffer candidate))
          (let ((updated (with-current-buffer buffer (buffer-string))))
            (should (string-match-p "Updated" updated))
            (should (string-match-p "B" updated))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-build-compiles-grid-layout ()
  "The public Ebox DSL should compile a grid node."
  (let* ((input
          (ebox-build
           '(grid :grid-template-columns ((px 20) (px 20))
              (box "A")
              (box "B"))))
         (node (ebox-test-root input)))
    (should (ebox-box-node-p node))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout node)) 'grid))
    (should (string-match-p "A" (ebox-grid-test--plain input)))
    (should (string-match-p "B" (ebox-grid-test--plain input)))))

(ert-deftest ebox-build-compiles-direct-grid-placement ()
  "The Ebox DSL should preserve direct child Box placement metadata."
  (let* ((input
          (ebox-build
           '(grid :grid-template-columns ((px 20) (px 20))
              (box :grid-column (1 :span 2) "Header"))))
         (node (ebox-test-root input)))
    (should (string-match-p "Header" (ebox-grid-test--plain input)))
    (should (equal (ebox-style-node-specified-value
                    (car (ebox-box-node-children node)) :grid-column nil
                    (ebox-test-source-index input))
                   '(1 :span 2)))))

(provide 'ebox-grid-tests)

;;; ebox-grid-tests.el ends here
