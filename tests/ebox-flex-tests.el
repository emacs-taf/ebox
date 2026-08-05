;;; ebox-flex-tests.el --- Ebox flex layout tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(load-file (expand-file-name "../ebox.el" (file-name-directory (or load-file-name buffer-file-name))))

(defun ebox-flex-test--render (node)
  "Render NODE once for flex tests."
  (ebox-render node))

(defun ebox-flex-test--plain-lines (node)
  "Return rendered NODE as plain lines."
  (ebox-string-lines (substring-no-properties (ebox-flex-test--render node))))

(defun ebox-flex-test--line-widths (node)
  "Return rendered NODE pixel widths line by line."
  (mapcar #'ebox--string-pixel-width
          (ebox-string-lines (ebox-flex-test--render node))))

(defun ebox-flex-test--region-property-width (string region-id property)
  "Return max PROPERTY span width for REGION-ID in STRING."
  (let ((pos 0)
        (len (length string))
        (max-width 0))
    (while (< pos len)
      (if (equal (get-text-property pos property string) region-id)
          (let ((end (or (next-single-property-change
                          pos property string len)
                         len)))
            (setq max-width
                  (max max-width
                       (string-pixel-width (substring string pos end))))
            (setq pos end))
        (setq pos (or (next-single-property-change
                       pos 'ebox-content string len)
                      len))))
    max-width))

(defun ebox-flex-test--region-content-width (string region-id)
  "Return max content span width for REGION-ID in STRING."
  (ebox-flex-test--region-property-width string region-id 'ebox-content))

(defun ebox-flex-test--content-widths (node)
  "Return max content widths for NODE region ids."
  (let* ((ids (ebox-region-ids node))
         (rendered (ebox-flex-test--render node)))
    (mapcar (lambda (id)
              (ebox-flex-test--region-content-width rendered id))
            ids)))

(defun ebox-flex-test--face-has-key-value-p (face key value)
  "Return non-nil when FACE contains KEY with VALUE."
  (cond
   ((null face) nil)
   ((and (listp face) (keywordp (car face)))
    (equal (plist-get face key) value))
   ((listp face)
    (cl-some (lambda (item)
               (ebox-flex-test--face-has-key-value-p item key value))
             face))
   (t nil)))

(defun ebox-flex-test--face-at-property (string property)
  "Return first face in STRING at PROPERTY."
  (let ((pos 0)
        (len (length string))
        face)
    (while (and (< pos len) (not face))
      (when (get-text-property pos property string)
        (setq face (get-text-property pos 'face string)))
      (setq pos (or (next-single-property-change pos property string)
                    (1+ pos))))
    face))

(defun ebox-flex-test--property-values (string property)
  "Return distinct values for PROPERTY in STRING."
  (let ((pos 0)
        (len (length string))
        values)
    (while (< pos len)
      (when-let ((value (get-text-property pos property string)))
        (unless (memq value values)
          (setq values (append values (list value)))))
      (setq pos (1+ pos)))
    values))

(ert-deftest ebox-flex-module-preserves-item-participation ()
  "Extracted flex code should preserve item participation semantics."
  (let* ((node (ebox-build
                '(flex :width (240)
                  (item :flex-grow 1
                        (box :content "Grow" :width (40)))
                  (item (box :content "Fixed" :width (40))))))
         (rendered (ebox-render node)))
    (should (string-match-p "Grow" rendered))
    (should (string-match-p "Fixed" rendered))))

(ert-deftest ebox-flex-accepts-flex-props-on-direct-child-box ()
  "Flex item participation props may live directly on child boxes."
  (let* ((layout (ebox-flex
                  :width 300
                  (ebox-create :content "A" :flex-grow 1 :flex-basis '(80))
                  (ebox-create :content "B" :flex-grow 1 :flex-basis '(80))))
         (rendered (let ((ebox-viewport-width 300))
                     (ebox-render layout)))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines rendered))))
    (should (cl-every (lambda (width) (<= width 300)) widths))
    (should (string-match-p "A" (substring-no-properties rendered)))
    (should (string-match-p "B" (substring-no-properties rendered)))))

(ert-deftest ebox-flex-grows-items-to-fill-row-container ()
  "Flex grow should distribute extra row width by grow factors."
  (let* ((layout
          (ebox-flex :width '(300)
            (ebox-flex-item
             (ebox-create :content "A" :width '(80))
             :flex-grow 1 :flex-basis '(80))
            (ebox-flex-item
             (ebox-create :content "B" :width '(80))
             :flex-grow 2 :flex-basis '(80))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (= (length widths) 2))
    (should (= (apply #'+ widths) 300))
    (should (> (cadr widths) (car widths)))
    (should (equal (ebox-flex-test--line-widths layout) '(300)))))

(ert-deftest ebox-flex-margin-box-target-subtracts-inline-margins-for-border-box ()
  "A row flex target should include a border-box item's inline margins."
  (let ((layout
         (ebox-flex :width '(200) :align-items 'flex-start
           (ebox-create :content "A"
                        :width '(40)
                        :box-sizing 'border-box
                        :margin-left '(20)
                        :margin-right '(20)
                        :flex-grow 1))))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-margin-box-target-subtracts-block-margins-for-border-box ()
  "A column flex target should include a border-box item's block margins."
  (let ((layout
         (ebox-flex :width '(80) :height 6
                    :flex-direction 'column
                    :align-items 'flex-start
           (ebox-create :content "A"
                        :width '(40)
                        :height 1
                        :box-sizing 'border-box
                        :margin-top 1
                        :margin-bottom 1
                        :flex-grow 1))))
    (should (= (ebox-string-height (ebox-flex-test--render layout)) 6))))

(ert-deftest ebox-flex-margin-box-target-preserves-content-box-outer-sides ()
  "Content-box flex targets should subtract padding, borders, and margins."
  (let ((layout
         (ebox-flex :width '(200) :align-items 'flex-start
           (ebox-create :content "A"
                        :width '(40)
                        :box-sizing 'content-box
                        :padding-left '(10)
                        :padding-right '(10)
                        :border-left '(5)
                        :border-right '(5)
                        :margin-left '(20)
                        :margin-right '(20)
                        :flex-grow 1))))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-row-render-uses-sized-line-concat ()
  "Row flex rendering should not remeasure known-width line parts."
  (let* ((layout
          (ebox-flex :width '(360)
            (ebox-create :content "Alpha" :width '(80) :height 2)
            (ebox-create :content "Beta" :width '(80) :height 2)
            (ebox-create :content "Gamma" :width '(80) :height 2)))
         (concat-calls 0)
         (original (symbol-function 'ebox--lines-concat-horizontal)))
    (cl-letf (((symbol-function 'ebox--lines-concat-horizontal)
               (lambda (&rest args)
                 (cl-incf concat-calls)
                 (apply original args))))
      (should (equal (ebox-flex-test--line-widths layout) '(360 360))))
    (should (= concat-calls 0))))

(ert-deftest ebox-flex-shrinks-items-by-shrink-factors ()
  "Flex shrink should remove more width from larger shrink factors."
  (let* ((layout
          (ebox-flex :width '(150)
            (ebox-flex-item
             (ebox-create :content "A" :width '(100))
             :flex-shrink 1 :flex-basis '(100))
            (ebox-flex-item
             (ebox-create :content "B" :width '(100))
             :flex-shrink 3 :flex-basis '(100))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (= (length widths) 2))
    (should (= (apply #'+ widths) 150))
    (should (> (car widths) (cadr widths)))))

(ert-deftest ebox-flex-basis-supports-content-and-intrinsic-keywords ()
  "Flex basis content and intrinsic keywords should use content-derived sizes."
  (let* ((content "aa bbbb")
         (max-content (ebox--string-pixel-width content))
         (min-content (ebox--string-pixel-width "bbbb"))
         (layout
          (ebox-flex :width '(300)
            (ebox-flex-item
             (ebox-create :content content :width '(160) :wrap-mode 'word)
             :flex-basis 'content)
            (ebox-flex-item
             (ebox-create :content content :width '(160) :wrap-mode 'word)
             :flex-basis 'min-content)))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths (list max-content min-content)))))

(ert-deftest ebox-flex-grow-redistributes-space-after-max-width-clamp ()
  "A max-width-clamped item should freeze and leave space for flexible siblings."
  (let* ((layout
          (ebox-flex :width '(200)
            (ebox-flex-item
             (ebox-create :content "A" :width '(60) :max-width '(80))
             :flex-grow 1 :flex-basis '(60))
            (ebox-flex-item
             (ebox-create :content "B" :width '(60))
             :flex-grow 1 :flex-basis '(60))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(80 120)))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-grow-starts-from-flex-base-before-min-width-clamp ()
  "Grow distribution should start from flex base sizes, not hypothetical sizes."
  (let* ((layout
          (ebox-flex :width '(200)
            (ebox-flex-item
             (ebox-create :content "A" :width '(50) :min-width '(80))
             :flex-grow 1 :flex-basis '(50))
            (ebox-flex-item
             (ebox-create :content "B" :width '(50))
             :flex-grow 1 :flex-basis '(50))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(100 100)))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-grow-factors-below-one-partially-fill-free-space ()
  "Grow factors whose sum is below 1 should leave some free space unclaimed."
  (let* ((layout
          (ebox-flex :width '(300)
            (ebox-flex-item
             (ebox-create :content "A" :width '(50))
             :flex-grow 0.25)
            (ebox-flex-item
             (ebox-create :content "B" :width '(50))
             :flex-grow 0.25)))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(100 100)))
    (should (equal (ebox-flex-test--line-widths layout) '(300)))))

(ert-deftest ebox-flex-shrink-redistributes-space-after-min-width-clamp ()
  "A min-width-clamped item should freeze and push shrinkage to siblings."
  (let* ((layout
          (ebox-flex :width '(150)
            (ebox-flex-item
             (ebox-create :content "A" :width '(100) :min-width '(80))
             :flex-shrink 1 :flex-basis '(100))
            (ebox-flex-item
             (ebox-create :content "B" :width '(100))
             :flex-shrink 1 :flex-basis '(100))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(80 70)))
    (should (equal (ebox-flex-test--line-widths layout) '(150)))))

(ert-deftest ebox-flex-shrink-starts-from-flex-base-before-max-width-clamp ()
  "Shrink distribution should start from flex base sizes, not hypothetical sizes."
  (let* ((layout
          (ebox-flex :width '(150)
            (ebox-flex-item
             (ebox-create :content "A" :width '(100) :max-width '(80)
                          :wrap-mode 'word)
             :flex-shrink 1 :flex-basis '(100))
            (ebox-flex-item
             (ebox-create :content "B" :width '(100) :wrap-mode 'word)
             :flex-shrink 1 :flex-basis '(100))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(75 75)))
    (should (equal (ebox-flex-test--line-widths layout) '(150)))))

(ert-deftest ebox-flex-shrink-factors-below-one-partially-shrink-overflow ()
  "Shrink factors whose sum is below 1 should leave some overflow unclaimed."
  (let* ((layout
          (ebox-flex :width '(150)
            (ebox-flex-item
             (ebox-create :content "A" :width '(100))
             :flex-shrink 0.25)
            (ebox-flex-item
             (ebox-create :content "B" :width '(100))
             :flex-shrink 0.25)))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(87 88)))
    (should (equal (ebox-flex-test--line-widths layout) '(175)))))

(ert-deftest ebox-flex-properties-reject-negative-values ()
  "Flex width, basis, grow, and shrink factors should reject negatives."
  (should-error
   (ebox-flex-test--render
    (ebox-flex :width '(-1)
      (ebox-create :content "A" :width '(20))))
   :type 'error)
  (should-error
   (ebox-flex-test--render
    (ebox-flex
      (ebox-flex-item (ebox-create :content "A" :width '(20))
                      :flex-grow -1)))
   :type 'error)
  (should-error
   (ebox-flex-test--render
    (ebox-flex
      (ebox-flex-item (ebox-create :content "A" :width '(20))
                      :flex-shrink -1)))
   :type 'error)
  (should-error
   (ebox-flex-test--render
    (ebox-flex
      (ebox-flex-item (ebox-create :content "A" :width '(20))
                      :flex-basis '(-1))))
   :type 'error))

(ert-deftest ebox-flex-wraps-rows-with-column-gap ()
  "Row wrap should create new flex lines using column gaps."
  (let* ((layout
          (ebox-flex :width '(210) :flex-wrap 'wrap :column-gap '(10)
            (ebox-create :content "A" :width '(100))
            (ebox-create :content "B" :width '(100))
            (ebox-create :content "C" :width '(100))))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 2))
    (should (string-match-p "A.*B" (car lines)))
    (should (string-match-p "C" (cadr lines)))
    (should (equal (ebox-flex-test--line-widths layout) '(210 210)))))

(ert-deftest ebox-flex-row-wrap-measures-column-items-at-natural-width ()
  "Column flex items should not stretch to the full row before line breaking."
  (let* ((layout
          (ebox-build
           '(flex :flex-flow (row wrap) :column-gap (12) :width (800)
             (column
              (box :content "one" :width (220))
              (box :content "A" :width (42)))
             (column
              (box :content "two" :width (220))
              (box :content "B" :width (42)))
             (column
              (box :content "three" :width (220))
              (box :content "C" :width (42))))))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 2))
    (should (string-match-p "one.*two.*three" (car lines)))
    (should (string-match-p "A.*B.*C" (cadr lines)))))

(ert-deftest ebox-flex-rerenders-composite-item-for-assigned-viewport ()
  "Composite flex items should re-render internals for final item width."
  (let* ((layout
          (ebox-build
           '(flex :flex-flow (row wrap) :column-gap (12) :width (800)
             (column
              (box :content "wrap" :id "title" :max-width (293)
                   :padding (0 (10)) :border "#5E7F6A"
                   :text-align center)
              (flex :id "body" :max-width (293) :padding (0 (8))
                    :border "#5E7F6A" :border-top-p nil
                    :flex-wrap wrap :column-gap (8)
                    (item :flex-shrink 0
                          (box :content "A 118" :width (118)))
                    (item :flex-shrink 0
                          (box :content "B 118" :width (118)))
                    (item :flex-shrink 0
                          (box :content "C 118" :width (118))))))))
         (rendered (ebox-flex-test--render layout))
         (ids (ebox-region-ids layout))
         (title-width (ebox-flex-test--region-property-width
                       rendered (car ids) 'ebox-bt))
         (body-width (ebox-flex-test--region-property-width
                      rendered (cadr ids) 'ebox-bb)))
    (should (> title-width 200))
    (should (> body-width 200))))

(ert-deftest ebox-flex-wrapper-bounds-preformatted-child-layout ()
  "Flex container boxes should not let child layout overflow widen them."
  (let* ((ebox-viewport-width 500)
         (layout
          (ebox-build
           '(flex :flex-flow (row wrap) :row-gap 1 :column-gap (12)
             :padding (0 (12)) :border "#6F6A95" :border-top-p nil
             :bgcolor "#FBF9FF"
             (column
              (box :content ":flex-flow (row wrap)" :max-width (440)
                   :padding (0 (10)) :border "#6F6A95"
                   :text-align center)
              (flex :max-width (440) :padding (0 (8))
                    :border "#6F6A95" :border-top-p nil
                    :flex-flow (row wrap) :gap (1 (12))
                    (item (box :content "A" :width (170)))
                    (item (box :content "B" :width (170)))
                    (item (box :content "C wraps" :width (170)))))
             (column
              (box :content ":flex-flow (column wrap)" :max-width (440)
                   :padding (0 (10)) :border "#6F6A95"
                   :text-align center)
              (flex :max-width (440) :padding (0 (8))
                    :border "#6F6A95" :border-top-p nil
                    :flex-flow (column wrap) :gap (1 (12))
                    (item (box :content "A" :width (140)))
                    (item (box :content "B" :width (140)))
                    (item (box :content "C new column" :width (140))))))))
         (rendered (ebox-flex-test--render layout))
         (line-widths (ebox-flex-test--line-widths layout))
         (border-widths
          (cl-loop for id in (ebox-flex-test--property-values rendered
                                                              'ebox-bb)
                   collect (ebox-flex-test--region-property-width
                            rendered id 'ebox-bb))))
    (should (cl-every (lambda (width) (<= width ebox-viewport-width))
                      line-widths))
    (should (cl-some (lambda (width) (> width 400)) border-widths))))

(ert-deftest ebox-flex-wraps-with-max-width-clamped-hypothetical-size ()
  "Line collection should use max-width-clamped hypothetical main sizes."
  (let* ((layout
          (ebox-flex :width '(210) :flex-wrap 'wrap :column-gap '(10)
            (ebox-flex-item
             (ebox-create :content "A" :width '(200) :max-width '(100))
             :flex-basis '(200))
            (ebox-flex-item
             (ebox-create :content "B" :width '(200) :max-width '(100))
             :flex-basis '(200))))
         (lines (ebox-flex-test--plain-lines layout))
         (widths (ebox-flex-test--content-widths layout)))
    (should (= (length lines) 1))
    (should (equal widths '(100 100)))
    (should (equal (ebox-flex-test--line-widths layout) '(210)))))

(ert-deftest ebox-flex-omitted-width-stretches-to-viewport-when-bound ()
  "A row flex container without :width should use the current viewport."
  (let* ((ebox-viewport-width 240)
         (layout
          (ebox-flex :flex-wrap 'wrap :column-gap '(10)
            (ebox-create :content "A" :width '(100))
            (ebox-create :content "B" :width '(100))
            (ebox-create :content "C" :width '(100)))))
    (should (equal (ebox-flex-test--line-widths layout) '(240 240)))))

(ert-deftest ebox-flex-stretch-width-is-independent-of-container-wrapper ()
  "Stretch width should use the viewport with or without a neutral wrapper."
  (let* ((ebox-viewport-width 200)
         (plain
          (ebox-flex :width 'stretch
            (ebox-create :content "A" :width '(40))))
         (padded
          (ebox-flex :width 'stretch :padding 0
            (ebox-create :content "A" :width '(40)))))
    (should-not (plist-get plain :box))
    (should (plist-get padded :box))
    (should (equal (mapcar #'ebox-flex-test--line-widths
                           (list plain padded))
                   '((200) (200))))))

(ert-deftest ebox-flex-indefinite-width-keeps-natural-size-across-wrapper ()
  "Indefinite width should stay natural with or without a neutral wrapper."
  (let* ((ebox-viewport-width nil)
         (cases
          (mapcar
           (lambda (width)
             (let ((plain
                    (ebox-flex :width width
                      (ebox-create :content "A" :width '(40))))
                   (padded
                    (ebox-flex :width width :padding 0
                      (ebox-create :content "A" :width '(40)))))
               (should-not (plist-get plain :box))
               (should (plist-get padded :box))
               (list width plain padded)))
           '(stretch auto)))
         (results
          (mapcar
           (lambda (case)
             (list (car case)
                   (car (ebox-flex-test--line-widths (nth 1 case)))
                   (car (ebox-flex-test--line-widths (nth 2 case)))))
           cases)))
    (should (equal results
                   '((stretch 40 40)
                     (auto 40 40))))))

(ert-deftest ebox-flex-omitted-wrapper-width-uses-viewport-content-box ()
  "A styled flex container should lay out inside its viewport-sized box."
  (let* ((ebox-viewport-width 240)
         (layout
          (ebox-flex :padding-inline '(20)
                     :border-left '(10)
                     :border-right '(10)
                     :justify-content 'space-between
            (ebox-create :content "A" :width '(40))
            (ebox-create :content "B" :width '(40))))
         (rendered (ebox-flex-test--render layout))
         (display-widths
          (cl-loop for index below (length rendered)
                   for display = (get-text-property index 'display rendered)
                   when (and (consp display)
                             (eq (car display) 'space))
                   collect (car (plist-get (cdr display) :width)))))
    (should (equal (ebox-flex-test--line-widths layout) '(240)))
    (should (member 100 display-widths))))

(ert-deftest ebox-flex-viewport-wrapper-width-uses-content-box ()
  "A viewport-sized styled flex container should use its content box for lines."
  (let* ((ebox-viewport-width 240)
         (layout
          (ebox-flex :width '(viewport)
                     :padding-inline '(20)
                     :border-left '(10)
                     :border-right '(10)
                     :flex-wrap 'wrap
            (ebox-flex-item (ebox-create :content "A" :width '(180)))
            (ebox-flex-item (ebox-create :content "B" :width '(180))))))
    (should (cl-every (lambda (width) (<= width ebox-viewport-width))
                      (ebox-flex-test--line-widths layout)))))

(ert-deftest ebox-flex-auto-height-is-independent-of-container-wrapper ()
  "Auto height should preserve natural child height across wrapper branches."
  (let* ((plain
          (ebox-flex :width '(80) :height 'auto
            (ebox-create :content "A\nB" :width '(40))))
         (padded
          (ebox-flex :width '(80) :height 'auto :padding 0
            (ebox-create :content "A\nB" :width '(40))))
         (results
          (mapcar
           (lambda (layout)
             (condition-case err
                 (ebox-string-height (ebox-flex-test--render layout))
               (error err)))
           (list plain padded))))
    (should-not (plist-get plain :box))
    (should (plist-get padded :box))
    (should (equal results '(2 2)))))

(ert-deftest ebox-flex-reuses-measured-non-box-child-render ()
  "Flex should not fully rerender a measured non-box child during one render."
  (let* ((child (ebox-column
                 (ebox-create :content "A" :width '(100))
                 (ebox-create :content "B" :width '(100))))
         (layout (ebox-flex :width '(240) :flex-wrap 'wrap
                   child
                   (ebox-column
                    (ebox-create :content "C" :width '(100))
                    (ebox-create :content "D" :width '(100)))))
         (calls 0)
         (original-render (symbol-function 'ebox-render)))
    (cl-letf (((symbol-function 'ebox-render)
               (lambda (node)
                 (when (eq node child)
                   (cl-incf calls))
                 (funcall original-render node))))
      (ebox-render layout))
    (should (= calls 1))))

(ert-deftest ebox-flex-reuses-measured-box-render-when-size-unchanged ()
  "Flex should reuse a measured box when target main size is unchanged."
  (let* ((box (ebox-create :content "A" :width '(80)))
         (layout
          (ebox-flex :width '(220) :height 3
            :flex-wrap 'nowrap :align-items 'flex-start
            box
            (ebox-create :content "B" :width '(80))))
         (calls 0)
         (original (symbol-function 'ebox--render-box)))
    (cl-letf (((symbol-function 'ebox--render-box)
               (lambda (candidate)
                 (when (equal (ebox-get candidate :content) "A")
                   (cl-incf calls))
                 (funcall original candidate))))
      (ebox-render layout))
    (should (= calls 1))))

(ert-deftest ebox-flex-reuses-natural-sized-render-when-cross-is-unchanged ()
  "Final cross sizing should reuse an equal natural-sized item render."
  (let* ((box (ebox-create :content "A" :width '(80) :flex-grow 1))
         (region-id (car (ebox-region-ids box)))
         (layout (ebox-flex :width '(220) :align-items 'flex-start box))
         (calls 0)
         (original (symbol-function 'ebox--render-box))
         rendered)
    (cl-letf (((symbol-function 'ebox--render-box)
               (lambda (candidate)
                 (when (equal (ebox-get candidate :content) "A")
                   (cl-incf calls))
                 (funcall original candidate))))
      (setq rendered (ebox-render layout)))
    (should (equal (mapcar #'ebox--string-pixel-width
                           (ebox-string-lines rendered))
                   '(220)))
    (should (= (ebox-flex-test--region-content-width rendered region-id)
               220))
    (should (= calls 2))))

(ert-deftest ebox-flex-reuses-natural-non-box-render-before-cross-padding ()
  "Final cross padding should reuse a naturally sized non-box render."
  (let* ((source (ebox-column
                  (ebox-create :content "A" :width '(80))
                  (ebox-create :content "A2" :width '(80))))
         (layout
          (ebox-flex :width '(220)
            (ebox-flex-item source :flex-grow 1 :flex-basis '(80))
            (ebox-create :content "B" :width '(80) :height 4)))
         (calls 0)
         (original (symbol-function 'ebox-render))
         rendered)
    (cl-letf (((symbol-function 'ebox-render)
               (lambda (node)
                 (when (eq node source)
                   (cl-incf calls))
                 (funcall original node))))
      (setq rendered (ebox-render layout)))
    (should (= (ebox-string-height rendered) 4))
    (should (equal (mapcar #'ebox--string-pixel-width
                           (ebox-string-lines rendered))
                   '(220 220 220 220)))
    (should (= calls 2))))

(ert-deftest ebox-flex-natural-reuse-preserves-stretched-visible-overflow-ownership ()
  "Stretch sizing should absorb visible overflow into the final box region."
  (let* ((box (ebox-create :content "A\nB" :width '(80) :height 1
                           :overflow 'visible :flex-grow 1))
         (region-id (car (ebox-region-ids box)))
         (rendered (ebox-render (ebox-flex :width '(120) box)))
         (lines (ebox-string-lines rendered)))
    (should (= (length lines) 2))
    (should (= (ebox-flex-test--region-content-width
                (nth 1 lines) region-id)
               120))))

(ert-deftest ebox-flex-natural-reuse-preserves-stretched-scroll-state ()
  "Stretch sizing should publish the final box geometry to scroll state."
  (let* ((ebox-viewport-width 120)
         (ebox-viewport-height 2)
         (layout
          (ebox-build
           '(flex :width (120)
              (box :id "root" :width (80) :height (viewport-height)
                   :overflow scroll :flex-grow 1
                (column :width (80)
                  (box :content "A" :height 1)
                  (box :content "B" :height 1)
                  (box :content "C" :height 1)
                  (box :content "D" :height 1))))))
         (root-id
          (plist-get (car (ebox-selector-query-all layout "#root"))
                     :region-id)))
    (ebox-render layout)
    (let ((state (ebox-scroll-state root-id)))
      (should (equal (ebox-get (plist-get state :box) :height) 2))
      (should-not (plist-get state :content-lines-complete-p))
      (should-not (plist-get state :render-content-prefix)))))

(ert-deftest ebox-flex-natural-row-padding-uses-rendered-overflow-width ()
  "Natural cross padding should preserve a row item's rendered overflow width."
  (let* ((viewport-child
          (ebox-create :content "A" :width '(viewport)
                       :box-sizing 'content-box
                       :padding-left '(10) :padding-right '(10)))
         (source
          (ebox-column viewport-child
                       (ebox-create :content "A2" :width '(20))))
         (layout
          (ebox-flex :width '(240)
            (ebox-flex-item source :flex-basis '(20))
            (ebox-create :content "B" :width '(20) :height 4)))
         (widths
          (mapcar #'ebox--string-pixel-width
                  (ebox-string-lines (ebox-render layout)))))
    (should (= (length widths) 4))
    (should (= (nth 2 widths) (nth 0 widths)))
    (should (= (nth 3 widths) (nth 0 widths)))))

(ert-deftest ebox-flex-sized-persistent-hit-populates-pass-local-cache ()
  "Persistent sized renders should become reusable in the current pass."
  (let* ((source (ebox-create :content "A" :width '(80)))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (first (car (ebox--flex-collect-items (list source) 'row 220)))
         (main (plist-get first :target))
         (cache-key (list 'row main nil 'flex-start)))
    (ebox--flex-render-sized-entry first 'row main nil 'flex-start)
    (should (assoc cache-key (plist-get first :render-cache)))
    (let ((second (car (ebox--flex-collect-items (list source) 'row 220))))
      (should-not (assoc cache-key (plist-get second :render-cache)))
      (ebox--flex-render-sized-entry second 'row main nil 'flex-start)
      (should (assoc cache-key (plist-get second :render-cache))))))

(defun ebox-flex-test--face-signature (string)
  "Return a printed list of every face value carried by STRING."
  (let ((faces nil)
        (pos 0)
        (len (length string)))
    (while (< pos len)
      (push (get-text-property pos 'face string) faces)
      (setq pos (or (next-single-property-change pos 'face string) len)))
    (format "%S" (nreverse faces))))

(ert-deftest ebox-flex-measurement-cache-honors-content-properties ()
  "Property-only content changes must invalidate flex measurement reuse."
  (let* ((child (ebox-create
                 :content (propertize "AB" 'face '(:foreground "red"))
                 :width '(80)))
         (layout (ebox-flex :width '(160) child))
         (ebox--render-cache-table (make-hash-table :test 'equal)))
    (let ((ebox--render-cache-signature-cache (make-hash-table :test 'eq)))
      (ebox-render layout))
    (plist-put child :content
               (propertize "AB" 'face '(:foreground "blue")))
    (let* ((ebox--render-cache-signature-cache (make-hash-table :test 'eq))
           (faces (ebox-flex-test--face-signature (ebox-render layout))))
      (should (string-match-p "blue" faces))
      (should-not (string-match-p "red" faces)))))

(ert-deftest ebox-flex-fixed-basis-wrapped-box-skips-intrinsic-render ()
  "Known flex metrics should not render a wrapped fixed-basis box twice."
  (let* ((source
          (ebox-create
           :content "A responsive wrapped child"
           :width '(viewport) :min-width 0 :height 4 :wrap-mode 'word))
         (item
          (ebox-flex-item
           source :flex-grow 1 :flex-shrink 1 :flex-basis '(80)))
         (layout (ebox-flex :width '(240) :height 4 item))
         (ebox-viewport-width 240)
         (measurement-renders 0)
         fast slow)
    (let ((original
           (symbol-function 'ebox--flex-render-source-for-measurement)))
      (cl-letf (((symbol-function 'ebox--flex-render-source-for-measurement)
                 (lambda (&rest arguments)
                   (cl-incf measurement-renders)
                   (apply original arguments))))
        (setq fast (ebox-render layout))))
    (should (zerop measurement-renders))
    (cl-letf (((symbol-function 'ebox--flex-unrendered-measurement)
               (lambda (&rest _) nil)))
      (setq slow (ebox-render layout)))
    (should (equal-including-properties fast slow))))

(ert-deftest ebox-flex-fixed-basis-nowrap-box-keeps-intrinsic-measurement ()
  "No-wrap auto minimums should retain their intrinsic render measurement."
  (let* ((source
          (ebox-create :content "UNBREAKABLE" :min-width 0 :height 1
                       :wrap-mode nil))
         (props
          (ebox--flex-item-props
           (ebox-flex-item source :flex-basis '(40)))))
    (should-not (ebox--flex-unrendered-measurement source props 'row))))

(ert-deftest ebox-flex-bounded-auto-basis-keeps-intrinsic-measurement ()
  "Clipping must not replace an auto-basis item's intrinsic contribution."
  (let* ((source
          (ebox-create :content "UNBREAKABLE" :width '(120) :height 2
                       :min-width 0 :wrap-mode nil :overflow 'hidden))
         (props (ebox--flex-item-props source)))
    (should (eq (plist-get props :flex-basis) 'auto))
    (should-not (ebox--flex-unrendered-measurement source props 'row))))

(ert-deftest ebox-flex-yielding-prewarm-renders-one-sized-item-per-slice ()
  "Fixed flex cards should prewarm incrementally without changing output."
  (let* ((children
          (cl-loop for label in '("Alpha" "Beta" "Gamma")
                   collect
                   (ebox-flex-item
                    (ebox-create :content label :height 3 :min-width 0
                                 :wrap-mode 'word :overflow 'hidden)
                    :flex-grow 1 :flex-shrink 1 :flex-basis '(60))))
         (layout (apply #'ebox-flex
                        (append '(:width (240) :height 3
                                  :flex-flow (row nowrap))
                                children)))
         (ebox-viewport-width 240)
         baseline warmed)
    ;; Establish stable region ids before comparing propertized output.
    (let ((ebox--render-cache-table (make-hash-table :test 'equal))
          (ebox--render-cache-signature-cache (make-hash-table :test 'eq)))
      (setq baseline (ebox-render layout)))
    (let ((ebox--render-cache-table (make-hash-table :test 'equal))
          (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
          (ebox--scroll-window-prewarm-state (make-hash-table :test 'eq))
          (measurement-count 0)
          (sized-render-count 0)
          (original-measurement
           (symbol-function 'ebox--flex-item-measurement))
          (original-sized-render
           (symbol-function 'ebox--flex-render-sized-entry)))
      (cl-letf (((symbol-function 'ebox--flex-item-measurement)
                 (lambda (&rest arguments)
                   (cl-incf measurement-count)
                   (apply original-measurement arguments)))
                ((symbol-function 'ebox--flex-render-sized-entry)
                 (lambda (&rest arguments)
                   (cl-incf sized-render-count)
                   (apply original-sized-render arguments))))
        (should (ebox--flex-prewarm-sized-item layout 240))
        (should (= measurement-count 1))
        (should (zerop sized-render-count))
        (should (ebox--flex-prewarm-sized-item layout 240))
        (should (= measurement-count 2))
        (should (zerop sized-render-count))
        (should (ebox--flex-prewarm-sized-item layout 240))
        (should (= measurement-count 3))
        (should (zerop sized-render-count))
        (should (ebox--flex-prewarm-sized-item layout 240))
        (should (= sized-render-count 1))
        (should (ebox--flex-prewarm-sized-item layout 240))
        (should (= sized-render-count 2))
        (should (ebox--flex-prewarm-sized-item layout 240))
        (should (= sized-render-count 3))
        (should-not (ebox--flex-prewarm-sized-item layout 240))
        (setq warmed (ebox-render layout)))
      (should (equal-including-properties baseline warmed)))))

(ert-deftest ebox-flex-repeated-responsive-sized-render-uses-scoped-cache ()
  "Repeated composite item geometry should ignore the ambient root width."
  (let* ((leaf (ebox-create :content "A" :width '(viewport)))
         (source
          (ebox-column leaf (ebox-create :content "tail" :width '(40))))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--flex-sized-render-observation-table
          (make-hash-table :test 'eq :weakness 'key))
         (calls 0)
         (original (symbol-function 'ebox-render)))
    (cl-labels
        ((render-at
          (ambient-width item-width)
          (let ((ebox-viewport-width ambient-width)
                (ebox--render-cache-allow-viewport-dependent nil)
                (ebox--render-cache-signature-cache
                 (make-hash-table :test 'eq)))
            (ebox--flex-render-sized-entry
             (list :source source) 'row item-width nil 'flex-start))))
      (cl-letf (((symbol-function 'ebox-render)
                 (lambda (node)
                   (when (eq node source)
                     (cl-incf calls))
                   (funcall original node))))
        ;; The first occurrence observes the geometry, the second stores it,
        ;; and a third pass at another root width reuses the scoped result.
        (render-at 300 120)
        (render-at 600 120)
        (render-at 900 120)
        (should (= calls 2))
        ;; A source mutation changes the body signature even though geometry
        ;; and the repeated-context observation remain warm.
        (ebox-put leaf :content "B")
        (render-at 900 120)
        (should (= calls 3))
        ;; A different local viewport earns its own observation and cache.
        (render-at 300 130)
        (render-at 600 130)
        (render-at 900 130)
        (should (= calls 5))))))

(ert-deftest ebox-flex-column-natural-cache-respects-final-cross-viewport ()
  "Column flex must render composite items in the final cross viewport."
  (let* ((viewport-child
          (ebox-create :content "VP" :width '(viewport)))
         (source
          (ebox-column
           viewport-child
           (ebox-create :content "F" :width '(100))))
         (region-id (car (ebox-region-ids viewport-child)))
         (layout
          (ebox-flex :height 4
                     :flex-direction 'column
                     :align-items 'stretch
            (ebox-flex-item source :flex-grow 1 :flex-basis 2)))
         (rendered (ebox-render layout)))
    ;; Two children keep the column as a composite stack.
    (should (eq (plist-get source :ebox-type) 'stack))
    (should (= (ebox-flex-test--region-content-width rendered region-id)
               100))))

(ert-deftest ebox-flex-nowrap-explicit-cross-skips-natural-cross-measure ()
  "Nowrap containers with fixed cross size should not measure natural cross."
  (let* ((layout
          (ebox-flex :width '(220) :height 4 :flex-wrap 'nowrap
            (ebox-create :content "A" :width '(80))
            (ebox-create :content "B" :width '(80))))
         (calls 0)
         (original (symbol-function 'ebox--flex-line-cross)))
    (cl-letf (((symbol-function 'ebox--flex-line-cross)
               (lambda (&rest args)
                 (cl-incf calls)
                 (apply original args))))
      (ebox-render layout))
    (should (= calls 0))))

(ert-deftest ebox-flex-aligns-items-on-row-cross-axis ()
  "Align-items center should move short row items within the line height."
  (let* ((layout
          (ebox-flex :width '(180) :height 3 :align-items 'center
            (ebox-create :content "A" :width '(80) :height 1)
            (ebox-create :content "B\nB\nB" :width '(80) :height 3)))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 3))
    (should (= (cl-position-if (lambda (line)
                                 (string-match-p "A" line))
                               lines)
               1))))

(ert-deftest ebox-flex-honors-order-and-reverse-directions ()
  "Order and reverse directions should change visual item order."
  (let* ((ordered
          (ebox-flex
            (ebox-flex-item (ebox-create :content "A" :width '(40)) :order 2)
            (ebox-flex-item (ebox-create :content "B" :width '(40)) :order 1)))
         (column-reverse
          (ebox-flex :flex-direction 'column-reverse
            (ebox-create :content "A" :width '(40))
            (ebox-create :content "B" :width '(40)))))
    (should (string-match-p "B.*A"
                            (car (ebox-flex-test--plain-lines ordered))))
    (should (string-match-p "B"
                            (car (ebox-flex-test--plain-lines column-reverse))))))

(ert-deftest ebox-flex-align-self-overrides-align-items ()
  "Align-self should override the container cross-axis alignment."
  (let* ((layout
          (ebox-flex :width '(180) :height 3 :align-items 'flex-start
            (ebox-flex-item
             (ebox-create :content "A" :width '(80) :height 1)
             :align-self 'flex-end)
            (ebox-create :content "B\nB\nB" :width '(80) :height 3)))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 3))
    (should (= (cl-position-if (lambda (line)
                                 (string-match-p "A" line))
                               lines)
               2))))

(ert-deftest ebox-flex-wrap-single-line-align-content-keeps-natural-cross-size ()
  "A wrapped one-line container should still use multi-line align-content rules."
  (let* ((layout
          (ebox-flex :width '(180) :height 4
            :flex-wrap 'wrap
            :align-content 'flex-start
            :align-items 'center
            (ebox-create :content "A" :width '(60) :height 1)))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 4))
    (should (= (cl-position-if (lambda (line)
                                 (string-match-p "A" line))
                               lines)
               0))))

(ert-deftest ebox-flex-applies-container-box-properties ()
  "Flex container visual box properties should render around the flex layout."
  (let* ((layout
          (ebox-flex :width '(160) :box-sizing 'border-box
            :padding '(1 (8))
            :border '(1 "#ff0000")
            :bgcolor "#101010"
            (ebox-create :content "A" :width '(60))))
         (rendered (ebox-flex-test--render layout))
         (left-face (ebox-flex-test--face-at-property rendered 'ebox-bl))
         (right-face (ebox-flex-test--face-at-property rendered 'ebox-br))
         (top-face (ebox-flex-test--face-at-property rendered 'ebox-bt))
         (bottom-face (ebox-flex-test--face-at-property rendered 'ebox-bb))
         (content-face (ebox-flex-test--face-at-property rendered 'ebox-content)))
    (should (equal (ebox-flex-test--line-widths layout) '(160 160 160)))
    (should (ebox-flex-test--face-has-key-value-p
             left-face :background "#ff0000"))
    (should (ebox-flex-test--face-has-key-value-p
             right-face :background "#ff0000"))
    (should (ebox-flex-test--face-has-key-value-p top-face :overline "#ff0000"))
    (should (ebox-flex-test--face-has-key-value-p
             bottom-face
             :underline
             '(:position t :color "#ff0000")))
    (should (ebox-flex-test--face-has-key-value-p
             content-face :background "#101010"))))

(ert-deftest ebox-flex-container-box-preserves-blank-child-bottom-border ()
  "A visual flex container should preserve child bottom borders on blank lines."
  (let* ((child (ebox-create :content "A"
                             :width '(80)
                             :height 2
                             :padding '(0 (6))
                             :border '(1 "#00aa00")))
         (child-id (car (ebox-region-ids child)))
         (layout (ebox-flex :width '(140)
                   :padding '(1 (4))
                   :border '(1 "#444444")
                   (ebox-flex-item child :flex-basis '(80))))
         (rendered (ebox-flex-test--render layout)))
    (should (memq child-id
                  (ebox-flex-test--property-values rendered 'ebox-bb)))))

(ert-deftest ebox-flex-container-box-wrapper-preserves-rendered-layout ()
  "A flex container box wrapper should not rewrap the rendered flex layout."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'ekp) t)))
            ((symbol-function 'ekp-pixel-justify)
             (lambda (text _width)
               (if (string-match-p "\n" text)
                   "REWRAPPED"
                 text))))
    (let* ((layout
            (ebox-flex :width '(260) :height 3 :border "gray"
              :flex-flow '(row wrap)
              :justify-content 'space-between
              (ebox-create :content "sample box two"
                           :height 3
                           :box-sizing 'border-box
                           :padding '(0 (8))
                           :border t
                           :wrap-mode nil)
              (ebox-create :content "sample box three"
                           :height 3
                           :box-sizing 'border-box
                           :padding '(0 (8))
                           :border t
                           :wrap-mode nil)))
           (plain (substring-no-properties (ebox-flex-test--render layout))))
      (should-not (string-match-p "REWRAPPED" plain))
      (should (string-match-p "sample box two" plain))
      (should (string-match-p "sample box three" plain)))))

(ert-deftest ebox-flex-item-applies-box-properties-with-flex-metadata ()
  "An item wrapper should keep flex metadata and apply visual box properties."
  (let* ((layout
          (ebox-flex :width '(180)
            (ebox-flex-item
             (ebox-create :content "A" :width '(60))
             :flex 1
             :box-sizing 'border-box
             :padding '(0 (6))
             :border '(1 "#00aa00"))))
         (rendered (ebox-flex-test--render layout))
         (left-face (ebox-flex-test--face-at-property rendered 'ebox-bl))
         (right-face (ebox-flex-test--face-at-property rendered 'ebox-br))
         (top-face (ebox-flex-test--face-at-property rendered 'ebox-bt))
         (bottom-face (ebox-flex-test--face-at-property rendered 'ebox-bb)))
    (should (equal (ebox-flex-test--line-widths layout) '(180)))
    (should (string-match-p "A" (substring-no-properties rendered)))
    (should (ebox-flex-test--face-has-key-value-p
             left-face :background "#00aa00"))
    (should (ebox-flex-test--face-has-key-value-p
             right-face :background "#00aa00"))
    (should (ebox-flex-test--face-has-key-value-p top-face :overline "#00aa00"))
    (should (ebox-flex-test--face-has-key-value-p
             bottom-face
             :underline
             '(:position t :color "#00aa00")))))

(ert-deftest ebox-flex-item-wrapper-preserves-preformatted-layout ()
  "An item wrapper with box properties should not rewrap rendered children."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'ekp) t)))
            ((symbol-function 'ekp-pixel-justify)
             (lambda (text _width)
               (if (string-match-p "\n" text)
                   "REWRAPPED"
                 text))))
    (let* ((layout
            (ebox-flex :width '(220)
              (ebox-flex-item
               (ebox-column
                (ebox-create :content "Top" :width '(80))
                (ebox-create :content "Bottom" :width '(80)))
               :width '(180)
               :box-sizing 'border-box
               :border t)))
           (plain (substring-no-properties (ebox-flex-test--render layout))))
      (should-not (string-match-p "REWRAPPED" plain))
      (should (string-match-p "Top" plain))
      (should (string-match-p "Bottom" plain)))))

(ert-deftest ebox-build-flex-item-applies-box-properties-with-flex-metadata ()
  "The DSL item form should keep flex metadata and visual box properties."
  (let* ((layout
          (ebox-build
           '(flex :width (180)
             (item :flex 1
              :box-sizing border-box
              :padding (0 (6))
              :border (1 "#00aa00")
              (box :content "A" :width (60))))))
         (rendered (ebox-flex-test--render layout))
         (top-face (ebox-flex-test--face-at-property rendered 'ebox-bt))
         (bottom-face (ebox-flex-test--face-at-property rendered 'ebox-bb)))
    (should (equal (ebox-flex-test--line-widths layout) '(180)))
    (should (string-match-p "A" (substring-no-properties rendered)))
    (should (ebox-flex-test--face-has-key-value-p top-face :overline "#00aa00"))
    (should (ebox-flex-test--face-has-key-value-p
             bottom-face
             :underline
             '(:position t :color "#00aa00")))))

(ert-deftest ebox-flex-neutral-size-properties-keep-child-identity ()
  "Width, height, and box-sizing alone should not wrap a flex container."
  (dolist (props '((:width (120))
                   (:height 2)
                   (:box-sizing border-box)))
    (let ((layout
           (apply #'ebox-flex
                  (append props
                          (list (ebox-create :content "A" :width '(40))
                                (ebox-create :content "B" :width '(40)))))))
      (should-not (plist-get layout :box))
      (should (= (length (ebox-region-ids layout)) 2)))))

(ert-deftest ebox-flex-box-sizing-alone-keeps-child-region-ids ()
  "Box-sizing by itself should not wrap a flex container."
  (let ((layout
         (ebox-flex :width '(120) :box-sizing 'border-box
           (ebox-create :content "A" :width '(40))
           (ebox-create :content "B" :width '(40)))))
    (should (= (length (ebox-region-ids layout)) 2))
    (should (equal (ebox-flex-test--line-widths layout) '(120)))))

(ert-deftest ebox-flex-item-box-wrapper-preserves-direct-child-item-props ()
  "Wrapping an item in box properties should not hide child flex metadata."
  (let* ((layout
          (ebox-flex :width '(160)
            (ebox-flex-item
             (ebox-create :content "A" :width '(60)
                          :flex-grow 1 :flex-basis '(60))
             :box-sizing 'border-box
             :border t)
            (ebox-create :content "B" :width '(40))))
         (ids (ebox-region-ids layout))
         (rendered (ebox-flex-test--render layout))
         (wrapper-width
          (ebox-flex-test--region-property-width
           rendered (car ids) 'ebox-content-owner))
         (right-width
          (ebox-flex-test--region-content-width rendered (car (last ids)))))
    (should (= (length ids) 3))
    (should (> wrapper-width 60))
    (should (> wrapper-width right-width))))

(ert-deftest ebox-flex-wraps-before-shrinking-no-wrap-item-below-minimum ()
  "A no-wrap flex item should keep its rendered minimum width when wrapping."
  (let* ((layout
          (ebox-flex :width '(160)
            :flex-flow '(row wrap)
            :column-gap '(10)
            (ebox-flex-item
             (ebox-create :content "wide no-wrap label"
                          :width '(150)
                          :box-sizing 'border-box
                          :wrap-mode nil)
             :flex 1)
            (ebox-create :content "B" :width '(120))))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 2))
    (should (cl-every (lambda (width) (<= width 160))
                      (ebox-flex-test--line-widths layout)))
    (should (string-match-p "wide no-wrap label" (car lines)))
    (should (string-match-p "B" (cadr lines)))))

(ert-deftest ebox-flex-supports-standard-value-matrix ()
  "Every supported flex value should render without falling out of the model."
  (dolist (direction '(row row-reverse column column-reverse))
    (should (stringp
             (ebox-render
              (ebox-flex :width '(220) :height 4 :flex-direction direction
                (ebox-create :content "A" :width '(60) :height 1)
                (ebox-create :content "B" :width '(60) :height 1))))))
  (dolist (wrap '(nowrap wrap wrap-reverse))
    (should (stringp
             (ebox-render
              (ebox-flex :width '(130) :height 4 :flex-wrap wrap
                (ebox-create :content "A" :width '(60) :height 1)
                (ebox-create :content "B" :width '(60) :height 1)
                (ebox-create :content "C" :width '(60) :height 1))))))
  (dolist (justify '(flex-start flex-end center space-between space-around space-evenly start end left right normal))
    (should (stringp
             (ebox-render
              (ebox-flex :width '(220) :justify-content justify
                (ebox-create :content "A" :width '(60))
                (ebox-create :content "B" :width '(60)))))))
  (dolist (align '(stretch flex-start flex-end center baseline normal start end self-start self-end))
    (should (stringp
             (ebox-render
              (ebox-flex :width '(220) :height 4
                :align-items align
                (ebox-create :content "A" :width '(60) :height 1)
                (ebox-create :content "B" :width '(60) :height 1))))))
  (dolist (align '(stretch flex-start flex-end center space-between space-around space-evenly baseline normal start end))
    (should (stringp
             (ebox-render
              (ebox-flex :width '(130) :height 5 :flex-wrap 'wrap
                :align-content align
                (ebox-create :content "A" :width '(60) :height 1)
                (ebox-create :content "B" :width '(60) :height 1)
                (ebox-create :content "C" :width '(60) :height 1)))))))

(ert-deftest ebox-build-compiles-flex-and-item-dsl ()
  "The public DSL should expose flex and item forms."
  (let* ((node
          (ebox-build
           '(flex :width (240) :flex-flow (row wrap) :column-gap (10)
             (item :flex 1 (box :content "A" :width (80)))
             (box :content "B" :width (80) :flex-grow 1 :flex-basis (80)))))
         (rendered (ebox-flex-test--render node)))
    (should (eq (plist-get node :ebox-type) 'flex))
    (should (= (length (ebox-region-ids node)) 2))
    (should (= (string-pixel-width (car (ebox-string-lines rendered))) 240))
    (should (string-match-p "A.*B" (substring-no-properties rendered)))))

(provide 'ebox-flex-tests)
;;; ebox-flex-tests.el ends here
