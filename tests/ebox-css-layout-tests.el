;;; ebox-css-layout-tests.el --- CSS used-size regression tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise the boundary between pure CSS lengths and buffer layout geometry.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox-fixtures)

(defun ebox-css-layout-test--glyph-width (string)
  "Measure STRING with seven-pixel glyphs and Emacs's per-space truncation."
  (cl-loop for index below (or (string-match "\n" string) (length string))
           for display = (get-text-property index 'display string)
           for width = (and (consp display) (eq (car display) 'space)
                            (plist-get (cdr display) :width))
           sum (cond ((and (consp width) (numberp (car width)))
                      (floor (car width)))
                     ((numberp width) (floor (* 7 width)))
                     (t 7))))

(defmacro ebox-css-layout-test--with-pixel-display (&rest body)
  "Run BODY with an independent whole-pixel display oracle."
  (declare (indent 0) (debug t))
  `(let ((ebox-runtime-idle-prewarm nil)
         (ebox-runtime-idle-reflow-cache-prewarm nil))
     (cl-letf (((symbol-function 'string-pixel-width)
                #'ebox-css-layout-test--glyph-width)
               ((symbol-function 'ebox-native-reflow-layout-ready-p)
                (lambda () nil)))
       (ebox-clear-cache)
       (unwind-protect (progn ,@body)
         (ebox-clear-cache)))))

(defun ebox-css-layout-test--display (string)
  "Return STRING text and display properties without retained identities."
  (list (substring-no-properties string)
        (cl-loop for index below (length string)
                 collect (get-text-property index 'display string))))

(defun ebox-css-layout-test--assert-pixel-lines (output width)
  "Assert every OUTPUT line measures WIDTH in the model and real glyph oracle."
  (dolist (line (ebox-string-lines output))
    (should (= (ebox--string-pixel-width line) width))
    (should (= (ebox-css-layout-test--glyph-width line) width))))

(ert-deftest ebox-css-layout-percentage-text-and-blank-share-pixel-boundaries ()
  "Centered text and blank fill consume the same final percentage width."
  (ebox-css-layout-test--with-pixel-display
    (let* ((ebox-viewport-width 207)
           (input (ebox-build
                   '(box :width (% 50) :height (lh 2) :border "red"
                         :text-align center "X")))
           (output (ebox-render input)))
      (should (= (ebox-size-resolve '(% 50) '(:percent-base 207)) 103.5))
      (should (= (ebox-string-height output) 2))
      (ebox-css-layout-test--assert-pixel-lines output 103))))

(ert-deftest ebox-css-layout-percentage-siblings-share-the-remaining-pixel ()
  "Two 50-percent Row children divide an odd extent into 50 and 51 pixels."
  (ebox-css-layout-test--with-pixel-display
    (let* ((ebox-viewport-width 101)
           (output
            (ebox-render
             (ebox-build
              '(row :width (px 101)
                    (box :width (% 50) :height (lh 2) :border "red"
                         :text-align center "A")
                    (box :width (% 50) :height (lh 2) :border "blue"
                         :text-align center "B"))))))
      (ebox-css-layout-test--assert-pixel-lines output 101)
      (dolist (line (ebox-string-lines output))
        (let ((offsets
               (cl-loop for index below (length line)
                        when (get-text-property index 'ebox-bl line)
                        collect (ebox-css-layout-test--glyph-width
                                 (substring line 0 index)))))
          (should (equal offsets '(0 50))))))))

(ert-deftest ebox-css-layout-fractional-chrome-shares-the-content-boundary ()
  "Margins, padding and centered content share one cumulative pixel grid."
  (ebox-css-layout-test--with-pixel-display
    (ebox-css-layout-test--assert-pixel-lines
     (ebox-render
      (ebox-build
       '(box :width (px 20) :height (lh 2) :box-sizing border-box
             :padding-inline (px 0.5) :margin-inline (px 0.5)
             :border "red" :text-align center "X")))
     21)))

(ert-deftest ebox-css-layout-pixel-quantization-preserves-private-input ()
  "Distinct fractional display glyphs retain ownership and line boundaries."
  (let* ((display '(space :width (0.5) :height 1))
         ;; Each replacement needs its own EQ identity.  One shared display
         ;; object over several characters represents only one Emacs glyph.
         (source (mapconcat (lambda (text)
                              (if (equal text "\n") text
                                (propertize text 'display (copy-tree display)
                                            'ebox-content 17)))
                            '(" " " " "\n" " " " ") ""))
         (before (copy-sequence source))
         (result (ebox--quantize-pixel-spaces source)))
    (should (equal-including-properties source before))
    (should (equal display '(space :width (0.5) :height 1)))
    (should (equal (mapcar (lambda (index)
                            (plist-get (cdr (get-text-property index 'display
                                                             result)) :width))
                          '(0 1 3 4))
                   '((0) (1) (0) (1))))
    (dolist (index '(0 1 3 4))
      (should (= (get-text-property index 'ebox-content result) 17))
      (should (= (plist-get (cdr (get-text-property index 'display result))
                            :height)
                 1)))
    (should (eq result (ebox--quantize-pixel-spaces result)))
    (let ((integer (ebox-pixel-space 12)))
      (should (eq integer (ebox--quantize-pixel-spaces integer))))))

(defun ebox-css-layout-test--retained-label (label &optional color)
  "Build a stable percentage LABEL whose text parity can introduce fractions."
  (ebox-build
   `(column :key root :width (vw 100)
      (box :key label :width (% 100) :height (lh 2) :border "red"
           :text-align center :bgcolor ,(or color "#FFFFFF") ,label))))

(ert-deftest ebox-css-layout-retained-new-fractions-and-paint-match-fresh ()
  "A local text edit can introduce a half-pixel, even with unchanged sizes."
  (ebox-css-layout-test--with-pixel-display
    (let ((ebox-viewport-width 101)
          (ebox-viewport-height 20))
      (with-temp-buffer
        (ebox-render-to-buffer
         (current-buffer) (ebox-css-layout-test--retained-label "A"))
        (should-not (plist-get (ebox--buffer-render-state (current-buffer))
                               :fractional-pixel-output-p))
        ;; The first update introduces fractions into an integer-only prior
        ;; frame.  Paint must preserve the flag; later integer output clears it.
        (dolist (case '(("AA" nil t) ("AA" "#DDEEFF" t)
                        ("AAA" "#DDEEFF" nil) ("AAAA" "#DDEEFF" t)
                        ("A" "#DDEEFF" nil)))
          (let* ((input (ebox-css-layout-test--retained-label
                         (nth 0 case) (nth 1 case)))
                 (_report (ebox-commit (current-buffer) input))
                 (actual (buffer-string))
                 (fresh (ebox-render input)))
            (should (eq (plist-get (ebox--buffer-render-state (current-buffer))
                                  :fractional-pixel-output-p)
                        (nth 2 case)))
            (ebox-css-layout-test--assert-pixel-lines actual 101)
            (should (equal (ebox-css-layout-test--display actual)
                           (ebox-css-layout-test--display fresh)))))))))

(ert-deftest ebox-css-layout-retained-fractional-sibling-origin-matches-fresh ()
  "Sequential edits never quantize the second fractional sibling at origin zero."
  (ebox-css-layout-test--with-pixel-display
    (let ((ebox-viewport-width 101)
          (ebox-viewport-height 20))
      (cl-labels ((input (width right)
                    (ebox-build
                     `(row :key root :width (px 101)
                        (box :key left :width ,width :height (lh 2)
                             :border "red" :text-align center "A")
                        (box :key right :width ,width :height (lh 2)
                             :border "blue" :text-align center ,right)))))
        (with-temp-buffer
          (ebox-render-to-buffer (current-buffer) (input '(% 50) "B"))
          (dolist (case '(((% 50) "BB" t) ((% 50) "BBB" t)
                          ((px 50) "BBB" nil) ((px 50) "B" nil)
                          ((% 50) "BB" t)))
            (let* ((next (input (nth 0 case) (nth 1 case)))
                   (_report (ebox-commit (current-buffer) next))
                   (actual (buffer-string)))
              (should (eq (plist-get (ebox--buffer-render-state (current-buffer))
                                    :fractional-pixel-output-p)
                          (nth 2 case)))
              (ebox-css-layout-test--assert-pixel-lines actual 101)
              (should (equal (ebox-css-layout-test--display actual)
                             (ebox-css-layout-test--display
                              (ebox-render next)))))))))))

(defun ebox-css-layout-test--fractional-scroll (offset &optional boundary mixed)
  "Build a centered percentage scroll at OFFSET with optional BOUNDARY.
MIXED starts with three integral rows before the fractional cached rows."
  (let ((scroll
         (apply #'ebox-test-box
          :key 'scroll :width '(% 100) :height 3 :overflow 'scroll
          :text-align 'center :scroll-offset offset
          (append
           (and (eq boundary 'chrome) (list :border "red"))
           (list
            (ebox-test-text
             (mapconcat (lambda (index)
                          (format (if (and mixed (< index 3)) "%03d" "%02d")
                                  index))
                        (number-sequence 0 31) "\n")))))))
    (if (eq boundary 'nested)
        (ebox-test-box :width '(101) scroll)
      scroll)))

(ert-deftest ebox-css-layout-fractional-root-scroll-reuses-complete-pixel-lines ()
  "Cached full physical rows scroll without layout or projection work."
  (ebox-css-layout-test--with-pixel-display
    (let ((ebox-viewport-width 101)
          (ebox-viewport-height 3))
      (with-temp-buffer
        (ebox-render-to-buffer
         (current-buffer) (ebox-css-layout-test--fractional-scroll 10))
        (let* ((state (ebox--buffer-render-state (current-buffer)))
               (region (car (plist-get state :scroll-region-ids)))
               (scroll (gethash region (plist-get state :scroll-state-table)))
               (raw (plist-get scroll :content-lines))
               (rendered (plist-get scroll :rendered-content-lines))
               (before (copy-tree (mapcar #'ebox-css-layout-test--display
                                         rendered)))
               (offset 10))
          (should (plist-get state :fractional-pixel-output-p))
          (should (ebox--scroll-state-retained-window-ready-p scroll))
          (dolist (next '(11 12 11 16 10))
            (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                       (lambda (&rest _) (ert-fail "cached scroll rendered root")))
                      ((symbol-function 'ebox-surface--render-candidate-node)
                       (lambda (&rest _) (ert-fail "cached scroll reran layout")))
                      ((symbol-function 'ebox-surface--complete-projection)
                       (lambda (&rest _) (ert-fail "cached scroll reprojected styles"))))
              (should (= (ebox--scroll-region-by region (- next offset) 1)
                         (- next offset))))
            (setq offset next
                  state (ebox--buffer-render-state (current-buffer))
                  scroll (gethash region (plist-get state :scroll-state-table)))
            (let ((lines (plist-get (plist-get state :surface-fragments)
                                    :scroll-lines)))
              (should lines)
              (should-not (cl-some #'ebox--fractional-pixel-spaces-p lines))
              (should (equal (ebox-css-layout-test--display (ebox-lines-join lines))
                             (ebox-css-layout-test--display (buffer-string)))))
            (should (eq (plist-get (ebox-buffer-update-report (current-buffer))
                                  :projection-kind)
                        'scroll-patch))
            (should (plist-get state :fractional-pixel-output-p))
            (should (eq raw (plist-get scroll :content-lines)))
            (should (eq rendered (plist-get scroll :rendered-content-lines)))
            (should (equal before
                           (mapcar #'ebox-css-layout-test--display rendered)))
            (ebox-css-layout-test--assert-pixel-lines (buffer-string) 101)
            (should (equal (ebox-css-layout-test--display (buffer-string))
                           (ebox-css-layout-test--display
                            (ebox-render
                             (ebox-css-layout-test--fractional-scroll offset)))))))))))

(ert-deftest ebox-css-layout-fractional-root-scroll-retains-new-raw-fraction-flag ()
  "A newly visible fractional row keeps its raw flag after returning to integers."
  (ebox-css-layout-test--with-pixel-display
    (let ((ebox-viewport-width 101)
          (ebox-viewport-height 3))
      (with-temp-buffer
        (ebox-render-to-buffer
         (current-buffer) (ebox-css-layout-test--fractional-scroll 0 nil t))
        (let* ((state (ebox--buffer-render-state (current-buffer)))
               (region (car (plist-get state :scroll-region-ids)))
               (raw (plist-get (gethash region (plist-get state :scroll-state-table))
                               :rendered-content-lines)))
          (should-not (plist-get state :fractional-pixel-output-p))
          (dolist (delta '(1 -1))
            (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                       (lambda (&rest _) (ert-fail "fractional row rerendered root"))))
              (should (= (ebox--scroll-region-by region delta 1) delta)))
            (setq state (ebox--buffer-render-state (current-buffer)))
            (should (plist-get state :fractional-pixel-output-p))
            (ebox-css-layout-test--assert-pixel-lines (buffer-string) 101))
          ;; Integral line strings keep their existing ownership-template keys.
          (let ((lines (plist-get (plist-get state :surface-fragments) :scroll-lines)))
            (cl-mapc (lambda (actual source) (should (eq actual source)))
                     lines (seq-take raw 3))))))))

(ert-deftest ebox-css-layout-fractional-scroll-respects-wrapper-boundaries ()
  "Root chrome normalizes complete rows; nested fractional origins fall back."
  (ebox-css-layout-test--with-pixel-display
    (let ((ebox-viewport-width 101)
          (ebox-viewport-height 3))
      (dolist (boundary '(nested chrome))
        (with-temp-buffer
          (ebox-render-to-buffer
           (current-buffer) (ebox-css-layout-test--fractional-scroll 10 boundary))
          (let* ((state (ebox--buffer-render-state (current-buffer)))
                 (region (car (plist-get state :scroll-region-ids)))
                 (original (symbol-function 'ebox-surface--render-candidate))
                 (calls 0))
            (should (plist-get state :fractional-pixel-output-p))
            (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                       (lambda (&rest args)
                         (cl-incf calls)
                         (apply original args))))
              (should (= (ebox--scroll-region-by region 1 1) 1)))
            (should (= calls (if (eq boundary 'nested) 1 0)))
            (should (equal (ebox-css-layout-test--display (buffer-string))
                           (ebox-css-layout-test--display
                            (ebox-render
                             (ebox-css-layout-test--fractional-scroll
                              11 boundary)))))))))))

(ert-deftest ebox-css-layout-fractional-scroll-rolls-back-normalized-output ()
  "Failed publication preserves raw caches and retries the cached scroll path."
  (ebox-css-layout-test--with-pixel-display
    (let ((ebox-viewport-width 101)
          (ebox-viewport-height 3))
      (with-temp-buffer
        (ebox-render-to-buffer
         (current-buffer) (ebox-css-layout-test--fractional-scroll 10))
        (let* ((surface ebox-surface--buffer-surface)
               (state (tp-surface-client-state surface))
               (revision (tp-surface-revision surface))
               (region (car (plist-get state :scroll-region-ids)))
               (scroll (gethash region (plist-get state :scroll-state-table)))
               (raw (plist-get scroll :rendered-content-lines))
               (before (copy-tree (mapcar #'ebox-css-layout-test--display raw)))
               (contents (buffer-string)))
          (let ((tp--surface-publication-step-function
                 (lambda (step _surface)
                   (when (eq step 'client-state)
                     (error "reject normalized scroll publication")))))
            (should-error (ebox--scroll-region-by region 1 1)))
          (should (= (tp-surface-revision surface) revision))
          (should (eq (tp-surface-client-state surface) state))
          (should (= (plist-get (ebox-scroll-state region) :scroll-offset) 10))
          (should (eq raw (plist-get (ebox-scroll-state region) :rendered-content-lines)))
          (should (equal before (mapcar #'ebox-css-layout-test--display raw)))
          (should (equal-including-properties contents (buffer-string)))
          (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                     (lambda (&rest _) (ert-fail "retry rerendered root"))))
            (should (= (ebox--scroll-region-by region 1 1) 1)))
          (ebox-css-layout-test--assert-pixel-lines (buffer-string) 101))))))

(ert-deftest ebox-css-layout-percent-and-viewport-use-distinct-bases ()
  (let* ((ebox-viewport-width 800)
         (ebox-viewport-height 40)
         (ebox--css-viewport-width 800)
         (ebox--css-viewport-height 800)
         (ebox--css-containing-height 800)
         (ebox--css-size-context-active-p t)
         (box (ebox-test-root
               (ebox-build '(box :width (px 200) :height (vh 50) "x")))))
    (ebox--call-with-box-content-context
     box
     (lambda ()
       (should (= (ebox--size-pixels '(% 50) nil 'width) 100))
       (should (= (ebox--size-pixels '(vw 50) nil 'width) 400))
       (should (= (ebox--size-pixels '(% 50) nil 'height) 200))
       (should (= (ebox--size-pixels '(vh 50) nil 'height) 400))))))

(ert-deftest ebox-css-layout-auto-height-does-not-resolve-child-percent ()
  (let* ((ebox-viewport-width 800)
         (ebox--css-containing-height 800)
         (box (ebox-test-root
               (ebox-build '(box :width (px 200) "x")))))
    (ebox--call-with-box-content-context
     box
     (lambda ()
       (should-not (ebox--size-pixels '(% 50) nil 'height))
       (should (= (ebox--resolve-size-content-height
                   box '(% 50) 3)
                  3))))))

(ert-deftest ebox-css-layout-explicit-indefinite-percent-basis ()
  (let ((ebox-viewport-width 400)
        (ebox--css-containing-height 600))
    (should-not (ebox--size-pixels '(% 100) nil 'width nil))
    (should-not (ebox--size-pixels '(% 100) nil 'height nil))
    (should (= (ebox--size-pixels '(% 100) nil 'width 0) 0))))

(ert-deftest ebox-css-layout-definite-parent-height-applies-constraints ()
  (let ((ebox-viewport-width 400)
        (ebox--css-size-context-active-p t)
        (ebox--css-viewport-height 400)
        (box (ebox-test-root
              (ebox-build '(box :height (vh 50) :min-height (vh 12.5)
                                :max-height (vh 25) "x")))))
    (ebox--call-with-box-content-context
     box
     (lambda ()
       (should (= (ebox--size-pixels '(% 50) nil 'height) 50))))))

(ert-deftest ebox-css-layout-font-units-use-projected-zero-and-line ()
  (let* ((fact (ebox-font--make-fact
                :measurement-metrics '(:zero-width 9 :height 24)))
         (box (list :ebox-font-fact fact)))
    (should (= (ebox--size-pixels '(ch 10) box) 90))
    (should (= (ebox--size-pixels '(lh 3) box 'height) 72))
    (should (= (ebox--resolve-height-expression-lines '(lh 3) box) 3))
    (let ((ebox--css-font-fact fact))
      (should (= (ebox--size-pixels '(ch 10)) 90)))))

(ert-deftest ebox-css-layout-rounds-height-after-complete-expression ()
  (let* ((fact (ebox-font--make-fact
                :measurement-metrics '(:zero-width 10 :height 20)))
         (box (ebox-test-root
               (ebox-build
                '(box :height (calc (- (vh 50) (lh 0.4))) "x"))))
         (ebox--css-size-context-active-p t)
         (ebox--css-viewport-height 490))
    (setq box (plist-put box :ebox-font-fact fact))
    (should (< (abs (- (ebox--resolve-height-expression-lines
                       '(calc (- (vh 50) (lh 0.4))) box)
                      11.85))
               1e-9))
    (should (= (ebox--content-height box 1) 11))))

(ert-deftest ebox-css-layout-vertical-padding-percent-refers-to-width ()
  (let ((ebox-viewport-width 200)
        (ebox--css-containing-height 1000)
        (box (list :ebox-font-fact
                   (ebox-font--make-fact
                    :measurement-metrics '(:zero-width 10 :height 20)))))
    (should (= (ebox--edge-used-value box :padding-top-height '(% 10)) 1))
    (should (= (ebox--edge-used-value box :padding-left-pixel '(% 10)) 20))))

(ert-deftest ebox-css-layout-height-keywords-and-minimum-precedence ()
  (let ((ebox--css-containing-height 10))
    (dolist (keyword '(min-content max-content fit-content))
      (let ((box (ebox-test-root
                  (ebox-build `(box :height ,keyword "x")))))
        (should (= (ebox--content-height box 4) 4))))
    (let ((box (ebox-test-root
                (ebox-build '(box :height (lh 2)
                                  :min-height (lh 5)
                                  :max-height (lh 3) "x")))))
      (should (= (ebox--content-height box 1) 5)))))

(ert-deftest ebox-css-layout-inline-content-wraps-at-final-used-width ()
  "Intrinsic keywords and bounds size the text flow as well as its paint."
  (ebox-css-layout-test--with-pixel-display
    (let ((ebox-viewport-width 56))
      (dolist (kind '(single multiple column))
        (dolist (case '(((:width min-content)
                         28 ("red" "ink" "on" "blue"))
                        ((:width fit-content)
                         56 ("red ink" "on blue"))
                        ((:width max-content)
                         105 ("red ink on blue"))
                        ((:width (px 7) :min-width min-content)
                         28 ("red" "ink" "on" "blue"))
                        ((:width (px 7) :min-width fit-content)
                         56 ("red ink" "on blue"))
                        ((:width (px 7) :min-width max-content)
                         105 ("red ink on blue"))
                        ((:width (px 140) :max-width min-content)
                         28 ("red" "ink" "on" "blue"))
                        ((:width (px 140) :max-width fit-content)
                         56 ("red ink" "on blue"))
                        ((:width (px 140) :max-width max-content)
                         105 ("red ink on blue"))
                        ((:width max-content :max-width (px 56))
                         56 ("red ink" "on blue"))
                        ((:width min-content :min-width (px 56))
                         56 ("red ink" "on blue"))
                        ((:width (px 7) :min-width (px 56)
                          :max-width (px 28))
                         56 ("red ink" "on blue"))))
          (ert-info ((format "%S flow, declarations %S" kind (car case)))
            (let* ((form
                    (append
                     (list (if (eq kind 'column) 'column 'box))
                     (car case)
                     (pcase kind
                       ('single '("red ink on blue"))
                       ('multiple '((text "red ink ") (text "on blue")))
                       ('column '((text "red ink on blue"))))))
                   (output (ebox-render (ebox-build form))))
              (ebox-css-layout-test--assert-pixel-lines output (nth 1 case))
              (should (equal (mapcar #'string-trim (ebox-string-lines output))
                             (nth 2 case))))))))))

(ert-deftest ebox-css-layout-intrinsic-text-viewport-keeps-nested-contexts ()
  "Intrinsic probes stay unwrapped; final nested percentages use the used width."
  (ebox-css-layout-test--with-pixel-display
    (dolist (form '((box :width fit-content
                         (column (text "red ink on blue")))
                    (column :width fit-content
                            (box :width (% 100) "red ink on blue"))))
      (let* ((input (ebox-build form))
             (node (ebox-test-root input)))
        (dolist (width '(56 140 14 84 28 56))
          (let* ((ebox-viewport-width width)
                 (output (ebox-render input)))
            (ebox-css-layout-test--assert-pixel-lines
             output (max 28 (min 105 width)))
            (should (equal (mapcar #'string-trim (ebox-string-lines output))
                           (pcase width
                             ((or 14 28) '("red" "ink" "on" "blue"))
                             (56 '("red ink" "on blue"))
                             (84 '("red ink on" "blue"))
                             (140 '("red ink on blue")))))
            (should (eq (ebox-get node :width) 'fit-content))
            (should (eq (ebox-get node :wrap-mode) 'word))))))
    (let ((ebox-viewport-width 56))
      (dolist (kind '(box column))
        (let ((output (ebox-render
                       (ebox-build
                        `(,kind :width min-content :wrap-mode none
                                (text "red ink on blue"))))))
          (ebox-css-layout-test--assert-pixel-lines output 105)
          (should (equal (substring-no-properties output)
                         "red ink on blue")))))))

(ert-deftest ebox-css-layout-intrinsic-parent-keeps-child-width-constraints ()
  "Measuring a parent must retain each nested child's independent used width."
  (ebox-css-layout-test--with-pixel-display
    (let ((ebox-viewport-width 56))
      (dolist (parent '(box column))
        (dolist (child '(box column))
          (dolist (properties '((:width min-content)
                               (:width (px 7) :min-width min-content)
                               (:width (px 140) :max-width min-content)))
            (ert-info ((format "%S parent, %S child %S"
                               parent child properties))
              (let ((output
                     (ebox-render
                      (ebox-build
                       `(,parent :width max-content
                                 (,child ,@properties
                                         (text "red ink on blue")))))))
                (ebox-css-layout-test--assert-pixel-lines output 28)
                (should (equal (mapcar #'string-trim (ebox-string-lines output))
                               '("red" "ink" "on" "blue")))))))))))

(ert-deftest ebox-css-layout-used-edge-ranges-are-explicit ()
  (should-error
   (ebox--edge-used-value nil :margin-left-pixel
                          '(calc (- (px 1) (px 2)))))
  (should (= (ebox--edge-used-value nil :padding-left-pixel
                                    '(calc (- (px 1) (px 2))))
             0)))

(ert-deftest ebox-css-layout-equivalent-pixels-have-identical-display ()
  (should (equal-including-properties (ebox-pixel-space 214)
                                     (ebox-pixel-space 214.0)))
  (should (equal (get-text-property 0 'display (ebox-pixel-space 2.5))
                 '(space :width (2.5)))))

(ert-deftest ebox-css-layout-cyclic-grid-gaps-overflow-intrinsic-box ()
  (dolist
      (case
       '(((grid :width max-content
                :grid-template-columns ((px 10) (px 10))
                :column-gap (% 50) :overflow visible
                (box "A") (box "B"))
          20 1 30 1)
         ((grid :width (px 10)
                :grid-template-columns ((px 10))
                :grid-template-rows ((lh 2) (lh 2))
                :row-gap (% 50) :overflow visible
                (box "A") (box "B"))
          10 4 10 6)))
    (let* ((input (ebox-build (car case)))
           (node (ebox-test-root input))
           (ebox--render-source-index (ebox-test-source-index input))
           (ebox--surface-materialization-active t)
           (rendered (ebox--render-layout node)))
      (should (= (ebox--content-pixel node) (nth 1 case)))
      (should (= (ebox--total-height node) (nth 2 case)))
      (should (= (ebox--string-max-pixel-width rendered) (nth 3 case)))
      (should (= (ebox-string-height rendered) (nth 4 case))))))

(provide 'ebox-css-layout-tests)
;;; ebox-css-layout-tests.el ends here
