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

(defun ebox-flex-test--region-owner-width (string region-id)
  "Return max rendered owner span width for REGION-ID in STRING."
  (let ((pos 0)
        (len (length string))
        (current-width 0)
        (max-width 0))
    (while (< pos len)
      (let* ((owners (get-text-property pos 'ebox-content-owners string))
             (end (or (next-single-property-change
                       pos 'ebox-content-owners string len)
                      len)))
        (if (memq region-id owners)
            (setq current-width
                  (+ current-width
                     (string-pixel-width (substring string pos end))))
          (setq max-width (max max-width current-width)
                current-width 0))
        (setq pos end)))
    (max max-width current-width)))

(defun ebox-flex-test--content-widths (input)
  "Return max content widths for INPUT's direct material children."
  (let ((node (ebox-test-root input)))
  (let* ((ids (mapcar (lambda (child)
                        (car (ebox-region-ids child)))
                      (ebox-box-node-children node)))
         (rendered (ebox-flex-test--render input)))
    (mapcar (lambda (id)
              (ebox-flex-test--region-owner-width rendered id))
              ids))))

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
      (when-let* ((value (get-text-property pos property string)))
        (unless (memq value values)
          (setq values (append values (list value)))))
      (setq pos (1+ pos)))
    values))

(ert-deftest ebox-flex-batch-line-sizing-preserves-fallback-semantics ()
  "Batch line sizing should preserve the scalar Flexbox algorithm."
  (let* ((line
          (list
           (list :base 80 :hypothetical 80 :min-main 0 :max-main nil
                 :props '(:flex-grow 1 :flex-shrink 1))
           (list :base 80 :hypothetical 80 :min-main 0 :max-main nil
                 :props '(:flex-grow 2 :flex-shrink 1))))
         (expected
          (mapcar (lambda (item) (plist-get item :target))
                  (ebox--flex-size-line line 200 10)))
         (actual
          (mapcar (lambda (item) (plist-get item :target))
                  (car (ebox--flex-size-lines (list line) 200 10)))))
    (should (equal actual expected))))

(ert-deftest ebox-flex-module-preserves-item-participation ()
  "Extracted flex code should preserve item participation semantics."
  (let* ((node (ebox-build
                '(flex :width (240)
                  (box :flex-grow 1 :width (40) "Grow")
                  (box :width (40) "Fixed"))))
         (rendered (ebox-render node)))
    (should (string-match-p "Grow" rendered))
    (should (string-match-p "Fixed" rendered))))

(ert-deftest ebox-flex-measures-direct-text-without-box-geometry ()
  "A canonical Text child should participate as text, not a geometry Box."
  (let* ((node (ebox-build '(flex :width (120) "Direct text")))
         (rendered (ebox-render node)))
    (should (string-match-p "Direct text"
                            (substring-no-properties rendered)))
    (should (= (ebox--string-max-pixel-width rendered) 120))))

(ert-deftest ebox-flex-item-clears-disappeared-ecss-props-on-region-update ()
  "A region update should clear removed rule props but retain inline item props."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (layout
          (ebox-test-flex
            (ebox-test-box :id "rule" :class 'grow
                         (ebox-test-text "Rule") :width '(40))
            (ebox-test-box :id "inline" (ebox-test-text "Inline") :width '(40)
                         :flex-grow 2)))
         (buffer (generate-new-buffer " *ebox-flex-style-reset*")))
    (unwind-protect
        (progn
          (ebox-style-add-rule ".grow" '(:flex-grow 1) :layer 'layout)
          (ebox-render-to-buffer buffer layout)
          (let ((items (plist-get (plist-get (ebox--buffer-render-state buffer)
                                               :root-node)
                                 :children)))
            (should (= (ebox-get (car items) :flex-grow) 1))
            (should (= (ebox-get (cadr items) :flex-grow) 2)))
          (ebox-style-reset-rules)
          (ebox-region-update (ebox-region-resolve buffer "rule")
                              :width '(41))
          (let ((items (plist-get (plist-get (ebox--buffer-render-state buffer)
                                               :root-node)
                                 :children)))
            (should-not (ebox-get (car items) :flex-grow))
            (should (= (ebox-get (cadr items) :flex-grow) 2))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-accepts-flex-props-on-direct-child-box ()
  "Flex item participation props may live directly on child boxes."
  (let* ((layout (ebox-test-flex
                  :width 300
                  (ebox-test-box (ebox-test-text "A") :flex-grow 1 :flex-basis '(80))
                  (ebox-test-box (ebox-test-text "B") :flex-grow 1 :flex-basis '(80))))
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
          (ebox-test-flex :width '(300)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(80))
             :flex-grow 1 :flex-basis '(80))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(80))
             :flex-grow 2 :flex-basis '(80))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (= (length widths) 2))
    (should (= (apply #'+ widths) 300))
    (should (> (cadr widths) (car widths)))
    (should (equal (ebox-flex-test--line-widths layout) '(300)))))

(ert-deftest ebox-flex-margin-box-target-subtracts-inline-margins-for-border-box ()
  "A row flex target should include a border-box item's inline margins."
  (let ((layout
         (ebox-test-flex :width '(200) :align-items 'flex-start
           (ebox-test-box (ebox-test-text "A")
                        :width '(40)
                        :box-sizing 'border-box
                        :margin-left '(20)
                        :margin-right '(20)
                        :flex-grow 1))))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-margin-box-target-subtracts-block-margins-for-border-box ()
  "A column flex target should include a border-box item's block margins."
  (let ((layout
         (ebox-test-flex :width '(80) :height 6
                    :flex-direction 'column
                    :align-items 'flex-start
           (ebox-test-box (ebox-test-text "A")
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
         (ebox-test-flex :width '(200) :align-items 'flex-start
           (ebox-test-box (ebox-test-text "A")
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

(ert-deftest ebox-flex-shrinks-items-by-shrink-factors ()
  "Flex shrink should remove more width from larger shrink factors."
  (let* ((layout
          (ebox-test-flex :width '(150)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(100))
             :flex-shrink 1 :flex-basis '(100))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(100))
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
          (ebox-test-flex :width '(300)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text content) :width '(160) :wrap-mode 'word)
             :flex-basis 'content)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text content) :width '(160) :wrap-mode 'word)
             :flex-basis 'min-content)))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths (list max-content min-content)))))

(ert-deftest ebox-flex-grow-redistributes-space-after-max-width-clamp ()
  "A max-width-clamped item should freeze and leave space for flexible siblings."
  (let* ((layout
          (ebox-test-flex :width '(200)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(60) :max-width '(80))
             :flex-grow 1 :flex-basis '(60))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(60))
             :flex-grow 1 :flex-basis '(60))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(80 120)))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-grow-starts-from-flex-base-before-min-width-clamp ()
  "Grow distribution should start from flex base sizes, not hypothetical sizes."
  (let* ((layout
          (ebox-test-flex :width '(200)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(50) :min-width '(80))
             :flex-grow 1 :flex-basis '(50))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(50))
             :flex-grow 1 :flex-basis '(50))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(100 100)))
    (should (equal (ebox-flex-test--line-widths layout) '(200)))))

(ert-deftest ebox-flex-grow-factors-below-one-partially-fill-free-space ()
  "Grow factors whose sum is below 1 should leave some free space unclaimed."
  (let* ((layout
          (ebox-test-flex :width '(300)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(50))
             :flex-grow 0.25)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(50))
             :flex-grow 0.25)))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(100 100)))
    (should (equal (ebox-flex-test--line-widths layout) '(300)))))

(ert-deftest ebox-flex-shrink-redistributes-space-after-min-width-clamp ()
  "A min-width-clamped item should freeze and push shrinkage to siblings."
  (let* ((layout
          (ebox-test-flex :width '(150)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(100) :min-width '(80))
             :flex-shrink 1 :flex-basis '(100))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(100))
             :flex-shrink 1 :flex-basis '(100))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(80 70)))
    (should (equal (ebox-flex-test--line-widths layout) '(150)))))

(ert-deftest ebox-flex-shrink-starts-from-flex-base-before-max-width-clamp ()
  "Shrink distribution should start from flex base sizes, not hypothetical sizes."
  (let* ((layout
          (ebox-test-flex :width '(150)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(100) :max-width '(80)
                          :wrap-mode 'word)
             :flex-shrink 1 :flex-basis '(100))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(100) :wrap-mode 'word)
             :flex-shrink 1 :flex-basis '(100))))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(75 75)))
    (should (equal (ebox-flex-test--line-widths layout) '(150)))))

(ert-deftest ebox-flex-shrink-factors-below-one-partially-shrink-overflow ()
  "Shrink factors whose sum is below 1 should leave some overflow unclaimed."
  (let* ((layout
          (ebox-test-flex :width '(150)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(100))
             :flex-shrink 0.25)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(100))
             :flex-shrink 0.25)))
         (widths (ebox-flex-test--content-widths layout)))
    (should (equal widths '(87 88)))
    (should (equal (ebox-flex-test--line-widths layout) '(175)))))

(ert-deftest ebox-flex-properties-reject-negative-values ()
  "Flex width, basis, grow, and shrink factors should reject negatives."
  (should-error
   (ebox-flex-test--render
    (ebox-test-flex :width '(-1)
      (ebox-test-box (ebox-test-text "A") :width '(20))))
   :type 'error)
  (should-error
   (ebox-flex-test--render
    (ebox-test-flex
      (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(20))
                      :flex-grow -1)))
   :type 'error)
  (should-error
   (ebox-flex-test--render
    (ebox-test-flex
      (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(20))
                      :flex-shrink -1)))
   :type 'error)
  (should-error
   (ebox-flex-test--render
    (ebox-test-flex
      (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(20))
                      :flex-basis '(-1))))
   :type 'error))

(ert-deftest ebox-flex-wraps-rows-with-column-gap ()
  "Row wrap should create new flex lines using column gaps."
  (let* ((layout
          (ebox-test-flex :width '(210) :flex-wrap 'wrap :column-gap '(10)
            (ebox-test-box (ebox-test-text "A") :width '(100))
            (ebox-test-box (ebox-test-text "B") :width '(100))
            (ebox-test-box (ebox-test-text "C") :width '(100))))
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
              (box :width (220) "one")
              (box :width (42) "A"))
             (column
              (box :width (220) "two")
              (box :width (42) "B"))
             (column
              (box :width (220) "three")
              (box :width (42) "C")))))
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
              (box :id "title" :max-width (293)
                   :padding (0 (10)) :border "#5E7F6A"
                   :text-align center "wrap")
              (flex :id "body" :max-width (293) :padding (0 (8))
                    :border-right "#5E7F6A"
                    :border-bottom "#5E7F6A"
                    :border-left "#5E7F6A"
                    :flex-wrap wrap :column-gap (8)
                    (box :flex-shrink 0 :width (118) "A 118")
                    (box :flex-shrink 0 :width (118) "B 118")
                    (box :flex-shrink 0 :width (118) "C 118"))))))
         (buffer (generate-new-buffer " *ebox-flex-viewport*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (let* ((rendered (with-current-buffer buffer (buffer-string)))
                 (title-id (plist-get
                            (car (ebox-selector-query-buffer buffer "#title"))
                            :region-id))
                 (body-id (plist-get
                           (car (ebox-selector-query-buffer buffer "#body"))
                           :region-id))
                 (title-width (ebox-flex-test--region-property-width
                               rendered title-id 'ebox-bt))
                 (body-width (ebox-flex-test--region-property-width
                              rendered body-id 'ebox-bb)))
            (should (> title-width 200))
            (should (> body-width 200))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-wrapper-bounds-preformatted-child-layout ()
  "Flex container boxes should not let child layout overflow widen them."
  (let* ((ebox-viewport-width 500)
         (layout
          (ebox-build
           '(flex :flex-flow (row wrap) :row-gap 1 :column-gap (12)
             :padding (0 (12))
             :border-right "#6F6A95"
             :border-bottom "#6F6A95"
             :border-left "#6F6A95"
             :bgcolor "#FBF9FF"
             (column
              (box :max-width (440)
                   :padding (0 (10)) :border "#6F6A95"
                   :text-align center ":flex-flow (row wrap)")
              (flex :max-width (440) :padding (0 (8))
                    :border-right "#6F6A95"
                    :border-bottom "#6F6A95"
                    :border-left "#6F6A95"
                    :flex-flow (row wrap) :gap (1 (12))
                    (box :width (170) "A")
                    (box :width (170) "B")
                    (box :width (170) "C wraps")))
             (column
              (box :max-width (440)
                   :padding (0 (10)) :border "#6F6A95"
                   :text-align center ":flex-flow (column wrap)")
              (flex :max-width (440) :padding (0 (8))
                    :border-right "#6F6A95"
                    :border-bottom "#6F6A95"
                    :border-left "#6F6A95"
                    :flex-flow (column wrap) :gap (1 (12))
                    (box :width (140) "A")
                    (box :width (140) "B")
                    (box :width (140) "C new column"))))))
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
          (ebox-test-flex :width '(210) :flex-wrap 'wrap :column-gap '(10)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(200) :max-width '(100))
             :flex-basis '(200))
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "B") :width '(200) :max-width '(100))
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
          (ebox-test-flex :flex-wrap 'wrap :column-gap '(10)
            (ebox-test-box (ebox-test-text "A") :width '(100))
            (ebox-test-box (ebox-test-text "B") :width '(100))
            (ebox-test-box (ebox-test-text "C") :width '(100)))))
    (should (equal (ebox-flex-test--line-widths layout) '(240 240)))))

(ert-deftest ebox-flex-stretch-width-is-independent-of-container-wrapper ()
  "Stretch width should use the viewport with or without a neutral wrapper."
  (let* ((ebox-viewport-width 200)
         (plain
          (ebox-test-flex :width 'stretch
            (ebox-test-box (ebox-test-text "A") :width '(40))))
         (padded
          (ebox-test-flex :width 'stretch :padding 0
            (ebox-test-box (ebox-test-text "A") :width '(40)))))
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
                    (ebox-test-flex :width width
                      (ebox-test-box (ebox-test-text "A") :width '(40))))
                   (padded
                    (ebox-test-flex :width width :padding 0
                      (ebox-test-box (ebox-test-text "A") :width '(40)))))
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
          (ebox-test-flex :padding-inline '(20)
                     :border-left '(10)
                     :border-right '(10)
                     :justify-content 'space-between
            (ebox-test-box (ebox-test-text "A") :width '(40))
            (ebox-test-box (ebox-test-text "B") :width '(40))))
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
          (ebox-test-flex :width '(viewport)
                     :padding-inline '(20)
                     :border-left '(10)
                     :border-right '(10)
                     :flex-wrap 'wrap
            (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(180)))
            (ebox-test-flex-item (ebox-test-box (ebox-test-text "B") :width '(180))))))
    (should (cl-every (lambda (width) (<= width ebox-viewport-width))
                      (ebox-flex-test--line-widths layout)))))

(ert-deftest ebox-flex-auto-height-is-independent-of-container-wrapper ()
  "Auto height should preserve natural child height across wrapper branches."
  (let* ((plain
          (ebox-test-flex :width '(80) :height 'auto
            (ebox-test-box (ebox-test-text "A\nB") :width '(40))))
         (padded
          (ebox-test-flex :width '(80) :height 'auto :padding 0
            (ebox-test-box (ebox-test-text "A\nB") :width '(40))))
         (results
          (mapcar
           (lambda (layout)
             (condition-case err
                 (ebox-string-height (ebox-flex-test--render layout))
               (error err)))
           (list plain padded))))
    (should (equal results '(2 2)))))

(ert-deftest ebox-flex-reuses-measured-non-box-child-render ()
  "Flex should not fully rerender a measured non-box child during one render."
  (let* ((child (ebox-test-column
                 :key 'measured-child
                 (ebox-test-box (ebox-test-text "A") :width '(100))
                 (ebox-test-box (ebox-test-text "B") :width '(100))))
         (layout (ebox-test-flex :width '(240) :flex-wrap 'wrap
                   child
                   (ebox-test-column
                    (ebox-test-box (ebox-test-text "C") :width '(100))
                    (ebox-test-box (ebox-test-text "D") :width '(100)))))
         (target-handle
          (ebox-node-source-handle (ebox-test-root child)))
         (calls 0)
         (original-render
          (symbol-function 'ebox--flex-render-source-for-measurement)))
    (cl-letf (((symbol-function 'ebox--flex-render-source-for-measurement)
               (lambda (node viewport)
                 (when (eq (ebox-node-source-handle node) target-handle)
                   (cl-incf calls))
                 (funcall original-render node viewport))))
      (ebox-render layout))
    (should (= calls 1))))

(ert-deftest ebox-flex-reuses-natural-non-box-render-before-cross-padding ()
  "Final cross padding should reuse a naturally sized non-box render."
  (let* ((source (ebox-test-column
                  :key 'natural-child
                  (ebox-test-box (ebox-test-text "A") :width '(80))
                  (ebox-test-box (ebox-test-text "A2") :width '(80))))
         (item (ebox-test-flex-item
                source :flex-grow 1 :flex-basis '(80)))
         (layout
          (ebox-test-flex :width '(220)
            item
            (ebox-test-box (ebox-test-text "B") :width '(80) :height 4)))
         (target-handle
          (ebox-node-source-handle (ebox-test-root item)))
         (calls 0)
         (original (symbol-function 'ebox--render-node))
         rendered)
    (cl-letf (((symbol-function 'ebox--render-node)
               (lambda (node &optional source-index)
                 (when (eq (ebox-node-source-handle node) target-handle)
                   (cl-incf calls))
                 (funcall original node source-index))))
      (setq rendered (ebox-render layout)))
    (should (= (ebox-string-height rendered) 4))
    (should (equal (mapcar #'ebox--string-pixel-width
                           (ebox-string-lines rendered))
                   '(220 220 220 220)))
    (should (= calls 2))))

(ert-deftest ebox-flex-natural-reuse-preserves-stretched-visible-overflow-ownership ()
  "Stretch sizing should absorb visible overflow into the final box region."
  (let* ((box (ebox-test-box (ebox-test-text "A\nB") :width '(80) :height 1
                           :overflow 'visible :flex-grow 1))
         (region-id (car (ebox-region-ids (ebox-test-root box))))
         (rendered (ebox-render (ebox-test-flex :width '(120) box)))
         (lines (ebox-string-lines rendered)))
    (should (= (length lines) 2))
    (should (= (ebox-flex-test--region-owner-width
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
                  (box :height 1 "A")
                  (box :height 1 "B")
                  (box :height 1 "C")
                  (box :height 1 "D"))))))
         (buffer (generate-new-buffer " *ebox-flex-scroll-state*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (let* ((match (car (ebox-selector-query-buffer buffer "#root")))
                 (state (ebox-scroll-state (plist-get match :region-id))))
            (should (equal (ebox-get (plist-get state :box) :height) 2))
            (should-not (plist-get state :content-lines-complete-p))
            (should-not (plist-get state :render-content-prefix))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-natural-row-padding-keeps-overflow-line-local ()
  "Visible overflow should widen only the line that actually overflows."
  (let* ((viewport-child
          (ebox-test-box (ebox-test-text "A") :width '(viewport)
                       :box-sizing 'content-box
                       :padding-left '(10) :padding-right '(10)))
         (source
          (ebox-test-column viewport-child
                       (ebox-test-box (ebox-test-text "A2") :width '(20))))
         (layout
          (ebox-test-flex :width '(240)
            (ebox-test-flex-item source :flex-basis '(20))
            (ebox-test-box (ebox-test-text "B") :width '(20) :height 4)))
         (widths
          (mapcar #'ebox--string-pixel-width
                  (ebox-string-lines (ebox-render layout)))))
    (should (= (length widths) 4))
    (should (= (car widths) 260))
    (should (equal (cdr widths) '(240 240 240)))))

(ert-deftest ebox-flex-composite-auto-row-respects-assigned-width ()
  "A composite auto-width row must not duplicate its Flex item viewport."
  (let* ((layout
          (ebox-test-flex :width '(120)
            (ebox-test-row
             (ebox-test-box (ebox-test-text "Left") :border t)
             (ebox-test-box (ebox-test-text "Right") :border t))))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines (ebox-render layout)))))
    (should (cl-every (lambda (width) (<= width 120)) widths))))

(ert-deftest ebox-flex-sized-persistent-hit-populates-pass-local-cache ()
  "Persistent sized renders should become reusable in the current pass."
  (let* ((source-input (ebox-test-box (ebox-test-text "A") :width '(80)))
         (source (ebox-test-root source-input))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (ebox--surface-materialization-active t)
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

(ert-deftest ebox-flex-measurement-miss-probes-cache-once ()
  "A flex measurement miss should compute one exact cache probe."
  (let* ((source-input
          (ebox-test-box (ebox-test-text "Measured once") :width '(80)))
         (source (ebox-test-root source-input))
         (props '(:flex-basis auto))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (ebox--viewport-dependent-subtree-cache (make-hash-table :test 'eq))
         (ebox--surface-materialization-active t)
         (signature-calls 0)
         (lookup-calls 0)
         (original-signature
          (symbol-function 'ebox--flex-render-cache-signature))
         (original-lookup (symbol-function 'ebox--render-cache-lookup)))
    (cl-letf (((symbol-function 'ebox--flex-render-cache-signature)
               (lambda (node)
                 (cl-incf signature-calls)
                 (funcall original-signature node)))
              ((symbol-function 'ebox--render-cache-lookup)
               (lambda (cache-key signature &rest arguments)
                 (when (and (consp cache-key)
                            (eq (nth 1 cache-key) 'flex-measure))
                   (cl-incf lookup-calls))
                 (apply original-lookup cache-key signature arguments))))
      (ebox--flex-item-measurement source props 'row 120))
    (should (= signature-calls 1))
    (should (= lookup-calls 1))))

(ert-deftest ebox-flex-reuses-direct-column-natural-measurement ()
  "A direct Column's nil-viewport natural size should survive parent resize."
  (let* ((source-input
          (ebox-test-column
           (ebox-test-box (ebox-test-text "A") :width '(80))
           (ebox-test-box (ebox-test-text "B") :width '(80))))
         (source (ebox-test-root source-input))
         (props '(:flex-basis auto))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (ebox--viewport-dependent-subtree-cache (make-hash-table :test 'eq))
         (ebox--surface-materialization-active t)
         (renders 0)
         (original
          (symbol-function 'ebox--flex-render-source-for-measurement)))
    (cl-letf (((symbol-function 'ebox--flex-render-source-for-measurement)
               (lambda (&rest arguments)
                 (cl-incf renders)
                 (apply original arguments))))
      (ebox--flex-item-measurement source props 'row 320)
      (ebox--flex-item-measurement source props 'row 640))
    (should (= renders 1))))

(ert-deftest ebox-flex-fixed-basis-wrapped-box-skips-intrinsic-render ()
  "Known flex metrics should not render a wrapped fixed-basis box twice."
  (let* ((source
          (ebox-test-box
           (ebox-test-text "A responsive wrapped child")
           :width '(viewport) :min-width 0 :height 4 :wrap-mode 'word))
         (item
          (ebox-test-flex-item
           source :flex-grow 1 :flex-shrink 1 :flex-basis '(80)))
         (layout (ebox-test-flex :width '(240) :height 4 item))
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
  (let* ((source-input
          (ebox-test-box (ebox-test-text "UNBREAKABLE") :min-width 0 :height 1
                       :wrap-mode 'none))
         (source (ebox-test-root source-input))
         (item-input (ebox-test-flex-item source-input :flex-basis '(40)))
         (props
          (ebox--flex-item-props (ebox-test-root item-input))))
    (should-not (ebox--flex-unrendered-measurement source props 'row))))

(ert-deftest ebox-flex-explicit-zero-min-width-allows-no-wrap-shrink ()
  "An explicit zero minimum lets a no-wrap card shrink in its Flex line."
  (let* ((source-input
          (ebox-test-box (ebox-test-text "A long no-wrap card title")
                       :min-width 0 :wrap-mode 'none))
         (source (ebox-test-root source-input))
         (rendered (ebox-render source-input)))
    (should (zerop (ebox--flex-box-min-main source rendered 'row)))))

(ert-deftest ebox-flex-bounded-auto-basis-keeps-intrinsic-measurement ()
  "Clipping must not replace an auto-basis item's intrinsic contribution."
  (let* ((source-input
          (ebox-test-box (ebox-test-text "UNBREAKABLE") :width '(120) :height 2
                       :min-width 0 :wrap-mode 'none :overflow 'hidden))
         (source (ebox-test-root source-input))
         (props (ebox--flex-item-props source)))
    (should (eq (plist-get props :flex-basis) 'auto))
    (should-not (ebox--flex-unrendered-measurement source props 'row))))

(ert-deftest ebox-flex-column-natural-cache-respects-final-cross-viewport ()
  "Column flex must render composite items in the final cross viewport."
  (let* ((viewport-child
          (ebox-test-box (ebox-test-text "VP") :width '(viewport)))
         (source-input
          (ebox-test-column
           viewport-child
           (ebox-test-box (ebox-test-text "F") :width '(100))))
         (source (ebox-test-root source-input))
         (region-id
          (car (ebox-region-ids (ebox-test-root viewport-child))))
         (layout
          (ebox-test-flex :height 4
                     :flex-direction 'column
                     :align-items 'stretch
            (ebox-test-flex-item source-input :flex-grow 1 :flex-basis 2)))
         (rendered (ebox-render layout)))
    (should (ebox-box-node-p source))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout source))
                'column))
    (should (= (ebox-flex-test--region-owner-width rendered region-id)
               100))))

(ert-deftest ebox-flex-nowrap-explicit-cross-skips-natural-cross-measure ()
  "Nowrap containers with fixed cross size should not measure natural cross."
  (let* ((layout
          (ebox-test-flex :width '(220) :height 4 :flex-wrap 'nowrap
            (ebox-test-box (ebox-test-text "A") :width '(80))
            (ebox-test-box (ebox-test-text "B") :width '(80))))
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
          (ebox-test-flex :width '(180) :height 3 :align-items 'center
            (ebox-test-box (ebox-test-text "A") :width '(80) :height 1)
            (ebox-test-box (ebox-test-text "B\nB\nB") :width '(80) :height 3)))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 3))
    (should (= (cl-position-if (lambda (line)
                                 (string-match-p "A" line))
                               lines)
               1))))

(ert-deftest ebox-flex-honors-order-and-reverse-directions ()
  "Order and reverse directions should change visual item order."
  (let* ((ordered
          (ebox-test-flex
            (ebox-test-flex-item (ebox-test-box (ebox-test-text "A") :width '(40)) :order 2)
            (ebox-test-flex-item (ebox-test-box (ebox-test-text "B") :width '(40)) :order 1)))
         (column-reverse
          (ebox-test-flex :flex-direction 'column-reverse
            (ebox-test-box (ebox-test-text "A") :width '(40))
            (ebox-test-box (ebox-test-text "B") :width '(40)))))
    (should (string-match-p "B.*A"
                            (car (ebox-flex-test--plain-lines ordered))))
    (should (string-match-p "B"
                            (car (ebox-flex-test--plain-lines column-reverse))))))

(ert-deftest ebox-flex-align-self-overrides-align-items ()
  "Align-self should override the container cross-axis alignment."
  (let* ((layout
          (ebox-test-flex :width '(180) :height 3 :align-items 'flex-start
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(80) :height 1)
             :align-self 'flex-end)
            (ebox-test-box (ebox-test-text "B\nB\nB") :width '(80) :height 3)))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 3))
    (should (= (cl-position-if (lambda (line)
                                 (string-match-p "A" line))
                               lines)
               2))))

(ert-deftest ebox-flex-wrap-single-line-align-content-keeps-natural-cross-size ()
  "A wrapped one-line container should still use multi-line align-content rules."
  (let* ((layout
          (ebox-test-flex :width '(180) :height 4
            :flex-wrap 'wrap
            :align-content 'flex-start
            :align-items 'center
            (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 4))
    (should (= (cl-position-if (lambda (line)
                                 (string-match-p "A" line))
                               lines)
               0))))

(ert-deftest ebox-flex-applies-container-box-properties ()
  "Flex container visual box properties should render around the flex layout."
  (let* ((layout
          (ebox-test-flex :width '(160) :box-sizing 'border-box
            :padding '(1 (8))
            :border '(1 "#ff0000")
            :bgcolor "#101010"
            (ebox-test-box (ebox-test-text "A") :width '(60))))
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
  (let* ((child (ebox-test-box (ebox-test-text "A")
                             :width '(80)
                             :height 2
                             :padding '(0 (6))
                             :border '(1 "#00aa00")
                             :flex-basis '(80)))
         (child-id (car (ebox-region-ids (ebox-test-root child))))
         (layout (ebox-test-flex :width '(140)
                   :padding '(1 (4))
                   :border '(1 "#444444")
                   child))
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
            (ebox-test-flex :width '(260) :height 3 :border "gray"
              :flex-flow '(row wrap)
              :justify-content 'space-between
              (ebox-test-box (ebox-test-text "sample box two")
                           :height 3
                           :box-sizing 'border-box
                           :padding '(0 (8))
                           :border t
                           :wrap-mode 'none)
              (ebox-test-box (ebox-test-text "sample box three")
                           :height 3
                           :box-sizing 'border-box
                           :padding '(0 (8))
                           :border t
                           :wrap-mode 'none)))
           (plain (substring-no-properties (ebox-flex-test--render layout))))
      (should-not (string-match-p "REWRAPPED" plain))
      (should (string-match-p "sample box two" plain))
      (should (string-match-p "sample box three" plain)))))

(ert-deftest ebox-flex-item-applies-box-properties-with-flex-metadata ()
  "An item wrapper should keep flex metadata and apply visual box properties."
  (let* ((layout
          (ebox-test-flex :width '(180)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "A") :width '(60))
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
            (ebox-test-flex :width '(220)
              (ebox-test-flex-item
               (ebox-test-column
                (ebox-test-box (ebox-test-text "Top") :width '(80))
                (ebox-test-box (ebox-test-text "Bottom") :width '(80)))
               :width '(180)
               :box-sizing 'border-box
               :border t)))
           (plain (substring-no-properties (ebox-flex-test--render layout))))
      (should-not (string-match-p "REWRAPPED" plain))
      (should (string-match-p "Top" plain))
      (should (string-match-p "Bottom" plain)))))

(ert-deftest ebox-flex-neutral-size-properties-keep-child-identity ()
  "Width, height, and box-sizing alone should not wrap a flex container."
  (dolist (props '((:width (120))
                   (:height 2)
                   (:box-sizing border-box)))
    (let* ((left (ebox-test-box (ebox-test-text "A") :width '(40)))
           (right (ebox-test-box (ebox-test-text "B") :width '(40)))
           (layout
            (apply #'ebox-test-flex
                   (append props (list left right)))))
      (should (equal (ebox-box-node-children (ebox-test-root layout))
                     (mapcar #'ebox-test-root (list left right))))
      (should (string-match-p "A.*B"
                              (substring-no-properties
                               (ebox-flex-test--render layout)))))))

(ert-deftest ebox-flex-box-sizing-alone-keeps-child-region-ids ()
  "Box-sizing by itself should not wrap a flex container."
  (let* ((left (ebox-test-box (ebox-test-text "A") :width '(40)))
         (right (ebox-test-box (ebox-test-text "B") :width '(40)))
         (layout
          (ebox-test-flex :width '(120) :box-sizing 'border-box left right)))
    (should (equal (ebox-box-node-children (ebox-test-root layout))
                   (mapcar #'ebox-test-root (list left right))))
    (should (equal (ebox-flex-test--line-widths layout) '(120)))))

(ert-deftest ebox-flex-direct-child-combines-frame-and-participation ()
  "One child Box should own both frame and Flex participation facts."
  (let* ((left (ebox-test-box (ebox-test-text "A") :width '(60)
                            :flex-grow 1 :flex-basis '(60)
                            :box-sizing 'border-box :border t))
         (right (ebox-test-box (ebox-test-text "B") :width '(40)))
         (layout (ebox-test-flex :width '(160) left right))
         (left-id (car (ebox-region-ids (ebox-test-root left))))
         (right-id (car (ebox-region-ids (ebox-test-root right))))
         (rendered (ebox-flex-test--render layout))
         (left-width
          (ebox-flex-test--region-owner-width rendered left-id))
         (right-width
          (ebox-flex-test--region-owner-width rendered right-id)))
    (should (equal (ebox-box-node-children (ebox-test-root layout))
                   (mapcar #'ebox-test-root (list left right))))
    (should (> left-width 60))
    (should (> left-width right-width))))

(ert-deftest ebox-flex-wraps-before-shrinking-no-wrap-item-below-minimum ()
  "A no-wrap flex item should keep its rendered minimum width when wrapping."
  (let* ((layout
          (ebox-test-flex :width '(160)
            :flex-flow '(row wrap)
            :column-gap '(10)
            (ebox-test-flex-item
             (ebox-test-box (ebox-test-text "wide no-wrap label")
                          :width '(150)
                          :box-sizing 'border-box
                          :wrap-mode 'none)
             :flex 1)
            (ebox-test-box (ebox-test-text "B") :width '(120))))
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
              (ebox-test-flex :width '(220) :height 4 :flex-direction direction
                (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "B") :width '(60) :height 1))))))
  (dolist (wrap '(nowrap wrap wrap-reverse))
    (should (stringp
             (ebox-render
              (ebox-test-flex :width '(130) :height 4 :flex-wrap wrap
                (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "B") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "C") :width '(60) :height 1))))))
  (dolist (justify '(flex-start flex-end center space-between space-around space-evenly start end left right normal))
    (should (stringp
             (ebox-render
              (ebox-test-flex :width '(220) :justify-content justify
                (ebox-test-box (ebox-test-text "A") :width '(60))
                (ebox-test-box (ebox-test-text "B") :width '(60)))))))
  (dolist (align '(stretch flex-start flex-end center baseline normal start end self-start self-end))
    (should (stringp
             (ebox-render
              (ebox-test-flex :width '(220) :height 4
                :align-items align
                (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "B") :width '(60) :height 1))))))
  (dolist (align '(stretch flex-start flex-end center space-between space-around space-evenly baseline normal start end))
    (should (stringp
             (ebox-render
              (ebox-test-flex :width '(130) :height 5 :flex-wrap 'wrap
                :align-content align
                (ebox-test-box (ebox-test-text "A") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "B") :width '(60) :height 1)
                (ebox-test-box (ebox-test-text "C") :width '(60) :height 1)))))))

(provide 'ebox-flex-tests)
;;; ebox-flex-tests.el ends here
