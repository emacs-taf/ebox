;;; ebox-composite-tests.el --- Pixel row compositor tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Independent deterministic display metrics exercise cuts and coverage without
;; requiring a GUI frame.  Production measurement still handles EQ display runs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)
(require 'ebox-composite)
(require 'ebox-fixtures)

(defun ebox-composite-test--plain-width (text)
  "Measure TEXT with seven-pixel glyphs, zero-width marks, and fi shaping."
  (let ((width 0) (position 0))
    (dolist (char (string-to-list text))
      (unless (or (memq (get-char-code-property char 'general-category)
                        '(Mn Mc Me))
                  (= char #x200d)
                  (and (>= char #x1f3fb) (<= char #x1f3ff)))
        (cl-incf width 7)))
    (while (string-match "fi" text position)
      (cl-decf width 3)
      (setq position (match-end 0)))
    width))

(defun ebox-composite-test--pixel-width (text)
  "Return TEXT's deterministic width, replacing each EQ display run once."
  (let ((position 0) (width 0) (end (length text)))
    (while (< position end)
      (let* ((display (get-text-property position 'display text))
             (next (next-single-property-change position 'display text end)))
        (cl-incf
         width
         (cond
          ((and (consp display) (eq (car display) 'space))
           (car (plist-get (cdr display) :width)))
          ((and (consp display) (eq (car display) 'image))
           (plist-get (cdr display) :width))
          ((stringp display) (ebox-composite-test--pixel-width display))
          (t (ebox-composite-test--plain-width
              (substring-no-properties text position next)))))
        (setq position next)))
    width))

(defmacro ebox-composite-test--with-metrics (&rest body)
  "Run BODY using the independent pixel oracle and fresh measurement caches."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'string-pixel-width)
              #'ebox-composite-test--pixel-width))
     (ebox-clear-cache)
     (unwind-protect (progn ,@body)
       (ebox-clear-cache))))

(defun ebox-composite-test--assert-width (text width)
  "Assert TEXT is WIDTH pixels in the production and independent metrics."
  (should (= (ebox--string-pixel-width text) width))
  (should (= (ebox-composite-test--pixel-width text) width)))

(ert-deftest ebox-composite-slice-keeps-original-coordinates ()
  "Partial edge glyphs leave neutral blanks and do not shift retained text."
  (ebox-composite-test--with-metrics
    (let* ((keymap (make-sparse-keymap))
           (owner (list 'owner))
           (source (propertize "ABCD" 'keymap keymap 'ebox-owner owner)))
      (dotimes (index (length source))
        (put-text-property index (1+ index) 'source-position index source))
      (let ((output (ebox-composite-slice source 3 24)))
        (should (equal (substring-no-properties output) " BC "))
        (ebox-composite-test--assert-width output 21)
        (should-not (get-text-property 0 'keymap output))
        (should-not (get-text-property 3 'keymap output))
        (should-not (get-text-property 0 'ebox-owner output))
        (should (eq (get-text-property 1 'keymap output) keymap))
        (should (eq (get-text-property 2 'ebox-owner output) owner))
        (should (= (get-text-property 1 'source-position output) 1))
        (should (= (get-text-property 2 'source-position output) 2))
        (should (= (ebox--string-pixel-width (substring output 0 1)) 4))))))

(ert-deftest ebox-composite-slice-fills-exhausted-and-empty-source ()
  "Intervals beyond source content retain their exact neutral canvas width."
  (ebox-composite-test--with-metrics
    (dolist (case '((nil 0 21) ("" 3 10) ("A" 10 21) ("A" 3 21)))
      (pcase-let ((`(,source ,start ,end) case))
        (let ((output (ebox-composite-slice source start end)))
          (ebox-composite-test--assert-width output (- end start))
          (should (string-blank-p output))
          (should-not (text-property-not-all 0 (length output)
                                           'keymap nil output)))))
    (should (equal (ebox-composite-slice "abc" 2 2) ""))))

(ert-deftest ebox-composite-cut-fill-keeps-source-paint-without-interaction ()
  "Cut glyphs keep their face, including dynamic slots, but not source actions."
  (ebox-composite-test--with-metrics
    (let* ((slot (tp-paint-slot-create '(:background "#eee5ce")))
           (face (list 'bold (tp-paint-slot-face slot)))
           (font-lock-face (list :background "#765fa1"))
           (source (propertize "ABCD" 'face face 'font-lock-face font-lock-face
                               'keymap (make-sparse-keymap) 'help-echo "hidden"
                               'mouse-face 'highlight 'ebox-owner '(owner)))
           (before (copy-sequence source))
           (output (ebox-composite-slice source 3 24)))
      (dolist (position '(0 3))
        (should (eq (get-text-property position 'face output) face))
        (should (eq (get-text-property position 'font-lock-face output)
                    font-lock-face))
        (dolist (property '(keymap help-echo mouse-face ebox-owner))
          (should-not (get-text-property position property output))))
      (ebox-composite-test--assert-width output 21)
      (tp-paint-slot-update slot '(:background "#aabbcc"))
      (should (memq (tp-paint-slot-face slot)
                    (get-text-property 0 'face output)))
      (should (equal (face-attribute (tp-paint-slot-face slot) :background)
                     "#aabbcc"))
      (should (equal-including-properties source before)))))

(ert-deftest ebox-composite-cut-fill-covers-shaping-and-replacement-boundaries ()
  "Reshaped glyphs, images and replacement strings retain source paint."
  (ebox-composite-test--with-metrics
    (let ((face (list :background "#eee5ce")))
      (dolist (source (list (propertize "fiZ" 'face face)
                            (propertize "abc" 'face face 'display "WXYZ")
                            (propertize "abc" 'face face 'display
                                        '(image :type xpm :width 28))))
        (let ((output (ebox-composite-slice source 7 18)))
          (should (eq (get-text-property 0 'face output) face))
          (ebox-composite-test--assert-width output 11))))))

(ert-deftest ebox-composite-overlap-keeps-underlay-paint-at-both-cut-edges ()
  "Occluding part of two glyphs preserves both exposed background strips."
  (ebox-composite-test--with-metrics
    (let* ((under (list :background "#eee5ce"))
           (over (list :background "#20353e"))
           (base (propertize "ABCD" 'face under))
           (top (propertize (ebox-pixel-space 10) 'face over))
           (output (ebox-composite-line base (list (list :text top :x 3)) 35)))
      (should (eq (get-text-property 0 'face output) under))
      (should (eq (get-text-property 1 'face output) over))
      (should (eq (get-text-property 2 'face output) under))
      (should-not (get-text-property (1- (length output)) 'face output))
      (ebox-composite-test--assert-width output 35))))

(ert-deftest ebox-composite-layout-cut-keeps-rich-child-paint ()
  "Layout clipping preserves child paint and does not resurrect child actions."
  (ebox-composite-test--with-metrics
    (dolist (child '("ABCD"
                     (text :background-color "red" :help-echo "child" "ABCD")
                     (box :background-color "red" :help-echo "child" "ABCD")))
      (let* ((output (ebox-render
                      (ebox-build
                       `(box :width (px 17) :wrap-mode none :overflow hidden
                             :background-color "blue" ,child))))
             (fill (1- (length output)))
             (expected (if (stringp child) "blue" "red")))
        (should (equal (substring-no-properties output) "AB "))
        (should (member expected
                        (flatten-tree (get-text-property fill 'face output))))
        (should-not (get-text-property fill 'help-echo output))
        (ebox-composite-test--assert-width output 17)))))

(ert-deftest ebox-composite-shaped-shorter-unit-keeps-painted-remainder ()
  "A detached narrower glyph leaves painted fill in its original allocation."
  (ebox-composite-test--with-metrics
    (cl-letf (((symbol-function 'ebox-composite-test--plain-width)
               (lambda (text)
                 (+ (* 7 (length text))
                    (if (string-match-p "fi" text) 3 0)))))
      (let* ((face (list :background "#eee5ce"))
             (output (ebox-composite-slice (propertize "fiZ" 'face face) 7 24)))
        (should (equal (substring-no-properties output) "i Z"))
        (should (eq (get-text-property 1 'face output) face))
        (ebox-composite-test--assert-width output 17)))))

(ert-deftest ebox-composite-mounted-overlap-keeps-painted-edges-after-updates ()
  "Real publication preserves edge paint when moving, recoloring and hiding."
  (ebox-composite-test--with-metrics
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             (current-buffer)
             (ebox-build
              '(box :width (px 35) :height (lh 1) :background-color "blue"
                    (box :id "lower" :width (px 35) :height (lh 1)
                         :background-color "red" "ABCDE")
                    (box :id "upper" :position absolute :left (px 3)
                         :width (px 10) :height (lh 1)
                         :background-color "cyan"))))
            (cl-labels
                ((check (left color visible)
                   (let* ((actual (buffer-string))
                          (fresh (ebox-render
                                  (plist-get (ebox-surface-buffer-snapshot
                                              (current-buffer)) :input))))
                     (ebox-composite-test--assert-width actual 35)
                     (should (equal (substring-no-properties actual)
                                    (substring-no-properties fresh)))
                     (dotimes (position (length actual))
                       (let* ((x (ebox--substring-pixel-width actual 0 position))
                              (end (ebox--substring-pixel-width
                                    actual 0 (1+ position))))
                         (when (< x end)
                           (should
                            (equal (cadr (memq :background
                                               (flatten-tree
                                                (get-text-property
                                                 position 'face actual))))
                                   (if (and visible (>= x left) (< x (+ left 10)))
                                       "cyan" color))))
                         (should (equal (get-text-property position 'face actual)
                                        (get-text-property position 'face fresh))))))))
              (check 3 "red" t)
              (ebox-region-update (ebox-region-resolve (current-buffer) "upper")
                                  :left '(px 9))
              (check 9 "red" t)
              (ebox-region-update (ebox-region-resolve (current-buffer) "lower")
                                  :background-color "orange")
              (check 9 "orange" t)
              (ebox-region-update (ebox-region-resolve (current-buffer) "upper")
                                  :visibility 'hidden)
              (check 9 "orange" nil)))
        (when (ebox-surface-buffer-mounted-p (current-buffer))
          (ebox-unmount-buffer (current-buffer)))))))

(ert-deftest ebox-composite-mounted-layout-fill-tracks-child-paint ()
  "Clipped fill follows paint, content, border and mixed geometry updates."
  (ebox-composite-test--with-metrics
    (dolist (kind '(text box))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer
               (current-buffer)
               (ebox-build
                `(box :id "parent" :width (px 17) :wrap-mode none :overflow hidden
                      :background-color "blue"
                      (,kind :id "child" :background-color "red"
                             :help-echo "child" "ABCD"))))
              (cl-labels
                  ((check (color)
                     (let* ((actual (buffer-string))
                            (fill (1- (length actual)))
                            (fresh (ebox-render
                                    (plist-get (ebox-surface-buffer-snapshot
                                                (current-buffer)) :input))))
                       (should (equal (substring-no-properties actual)
                                      (substring-no-properties fresh)))
                       (should (equal (cadr (memq :background
                                                 (flatten-tree
                                                  (get-text-property fill 'face actual))))
                                      color))
                       (should-not (get-text-property fill 'help-echo actual))
                       (should-not (get-text-property fill 'ebox-content actual))
                       (should-not (get-text-property fill ebox--paint-origin-property actual))
                       (dotimes (position (length actual))
                         (should (equal (get-text-property position 'face actual)
                                        (get-text-property position 'face fresh)))))))
                (check "red")
                (ebox-region-update "child" :background-color "yellow")
                (check "yellow")
                (dolist (failure-step '(text client-state))
                  (let ((before (buffer-string))
                        (state (ebox--buffer-render-state (current-buffer)))
                        (revision (ebox-surface-buffer-revision (current-buffer)))
                        (tp--surface-publication-step-function
                         (lambda (step _surface)
                           (when (eq step failure-step) (error "Reject fill paint")))))
                    (should-error (ebox-region-update "child" :background-color "orange"))
                    (should (equal-including-properties before (buffer-string)))
                    (should (eq state (ebox--buffer-render-state (current-buffer))))
                    (should (= revision (ebox-surface-buffer-revision (current-buffer))))))
                (check "yellow")
                (ebox-region-update "parent" :background-color "green")
                (check "yellow")
                (when (eq kind 'box)
                  (ebox-region-update "child" :border-top-width '(lh 1)
                                      :border-top-style 'solid :border-top-color "pink")
                  (check "yellow")
                  (ebox-region-update "child" :border-top-width '(lh 0))
                  (check "yellow"))
                (ebox-region-update "child" :content "WXYZ")
                (check "yellow")
                (ebox-call-with-update-batch
                 (lambda ()
                   (ebox-region-update "parent" :width '(px 18))
                   (ebox-region-update "child" :background-color "purple")))
                (check "purple")))
          (when (ebox-surface-buffer-mounted-p (current-buffer))
            (ebox-unmount-buffer (current-buffer))))))))

(ert-deftest ebox-composite-retained-slot-fill-keeps-paint-origin ()
  "Transported clipped content still tracks later paint and rolls back safely."
  (ebox-composite-test--with-metrics
    (with-temp-buffer
      (unwind-protect
          (cl-labels
              ((paint (content color)
                 (ebox-test-text content :key 'paint-text :source-identity 'paint-text
                                 :bgcolor color))
               (slot (content)
                 (ebox-test-box :key 'left :source-identity 'left
                                :wrap-mode 'none :overflow 'hidden
                                (paint content "red")))
               (root (content)
                 (ebox-test-box
                  :bgcolor "blue"
                  (ebox-test-grid :key 'grid :width '(60)
                                  :grid-template-columns '((17) (36)) :column-gap '(7)
                                  (slot content)
                                  (ebox-test-box :key 'right :source-identity 'right
                                                 (ebox-test-text "R")))))
               (repaint (content)
                 (let ((candidate (ebox-candidate-begin (current-buffer))))
                   (ebox-candidate-patch-host-paint
                    candidate 'paint-text (paint content "red") (paint content "yellow"))
                   (ebox-commit (current-buffer) candidate))))
            (ebox-render-to-buffer (current-buffer) (root "ABCD"))
            (let ((content (concat "A" (string #x0301) "BCD"))
                  (transport (symbol-function 'ebox-surface--retained-slot-owner-text))
                  (transported 0))
              (cl-letf (((symbol-function 'ebox-surface--retained-slot-owner-text)
                         (lambda (&rest args)
                           (let ((result (apply transport args)))
                             (when result (cl-incf transported))
                             result))))
                (let ((candidate (ebox-candidate-begin (current-buffer))))
                  (ebox-candidate-replace-host-ref candidate 'left (slot content))
                  (ebox-commit (current-buffer) candidate)))
              (should (= transported 1))
              (dolist (failure-step '(text client-state))
                (let ((before (buffer-string))
                      (revision (ebox-surface-buffer-revision (current-buffer)))
                      (tp--surface-publication-step-function
                       (lambda (step _surface)
                         (when (eq step failure-step) (error "Reject transported paint")))))
                  (should-error (repaint content))
                  (should (equal-including-properties before (buffer-string)))
                  (should (= revision (ebox-surface-buffer-revision (current-buffer))))))
              (repaint content)
              (let ((actual (buffer-string))
                    (fresh (ebox-render (plist-get
                                         (ebox-surface-buffer-snapshot (current-buffer))
                                         :input))))
                (should (equal (substring-no-properties actual)
                               (substring-no-properties fresh)))
                (dotimes (position (length actual))
                  (should (equal (get-text-property position 'face actual)
                                 (get-text-property position 'face fresh)))))))
        (when (ebox-surface-buffer-mounted-p (current-buffer))
          (ebox-unmount-buffer (current-buffer)))))))

(ert-deftest ebox-composite-slice-keeps-supported-graphemes-whole ()
  "Both cut edges preserve combining, variation, modifier, ZWJ, and flags."
  (ebox-composite-test--with-metrics
    (dolist (cluster '("é" "✈️" "👍🏽" "👩‍💻" "🇨🇳"))
      (let* ((source (concat "A" cluster "Z"))
             (right (+ 7 (ebox--string-pixel-width cluster)))
             (whole (ebox-composite-slice source 7 right))
             (cut-left (ebox-composite-slice source 8 (+ right 7)))
             (cut-right (ebox-composite-slice source 0 (1- right))))
        (should (equal (substring-no-properties whole) cluster))
        (should (equal (substring-no-properties cut-left) " Z"))
        (should (equal (substring-no-properties cut-right) "A "))
        (ebox-composite-test--assert-width whole (- right 7))
        (ebox-composite-test--assert-width cut-left (- right 1))
        (ebox-composite-test--assert-width cut-right (1- right))))))

(ert-deftest ebox-composite-slice-preserves-whole-prefix-shaping ()
  "A shaped fitting prefix is retained, and a detached glyph cannot spill."
  (ebox-composite-test--with-metrics
    (let ((whole (ebox-composite-slice "fiZ" 0 11))
          (suffix (ebox-composite-slice "fiZ" 7 18)))
      (should (equal whole "fi"))
      (ebox-composite-test--assert-width whole 11)
      (should (equal (substring-no-properties suffix) " Z"))
      (should (= (ebox--string-pixel-width (substring suffix 0 1)) 4))
      (ebox-composite-test--assert-width suffix 11))))

(ert-deftest ebox-composite-slice-cuts-grouped-fractional-spaces ()
  "A shared space can be cut on both ends without copying nested properties."
  (ebox-composite-test--with-metrics
    (let* ((height (list 20))
           (ascent (list 80))
           (display (list 'space :width '(15.5) :height height :ascent ascent))
           (keymap (make-sparse-keymap))
           (face (list :foreground "red"))
           (source (concat (propertize "abc" 'display display
                                       'keymap keymap 'face face) "Z"))
           (before (copy-sequence source))
           (output (ebox-composite-slice source 2.25 13.75))
           (result-display (get-text-property 0 'display output))
           (whole (ebox-composite-slice source 0 15.5)))
      (ebox-composite-test--assert-width output 11.5)
      (should (equal (substring-no-properties output) "abc"))
      (should (= (car (plist-get (cdr result-display) :width)) 11.5))
      (should (eq (plist-get (cdr result-display) :height) height))
      (should (eq (plist-get (cdr result-display) :ascent) ascent))
      (dotimes (index (length output))
        (should (eq (get-text-property index 'display output) result-display))
        (should (eq (get-text-property index 'keymap output) keymap))
        (should (eq (get-text-property index 'face output) face)))
      (should (eq (get-text-property 0 'display whole) display))
      (should (equal-including-properties before source))
      (should (equal (plist-get (cdr display) :width) '(15.5))))))

(ert-deftest ebox-composite-slice-canonicalizes-whole-pixel-cuts ()
  "Equal cuts share display properties regardless of numeric allocation type."
  (ebox-composite-test--with-metrics
    (let* ((height (list 20))
           (display (list 'space :width '(15.5) :height height))
           (source (propertize "abc" 'display display))
           (integer-cut (ebox-composite-slice source 2 13))
           (float-cut (ebox-composite-slice source 2.0 13.0))
           (fractional-cut (ebox-composite-slice source 2.0 13.5)))
      (should (equal-including-properties integer-cut float-cut))
      (should (equal (plist-get (cdr (get-text-property 0 'display float-cut))
                                :width)
                     '(11)))
      (should (eq (plist-get (cdr (get-text-property 0 'display float-cut))
                             :height)
                  height))
      (ebox-composite-test--assert-width fractional-cut 11.5)
      (should (eq (get-text-property 0 'display source) display))
      (should (equal (plist-get (cdr display) :width) '(15.5))))))

(ert-deftest ebox-composite-slice-never-splits-replacement-runs ()
  "Shared string and image replacements are kept whole, even across faces."
  (ebox-composite-test--with-metrics
    (dolist (display (list (copy-sequence "WXYZ")
                          (list 'image :type 'xpm :width 28)))
      (let* ((keymap (make-sparse-keymap))
             (source (propertize "abc" 'display display 'keymap keymap)))
        (put-text-property 1 2 'face 'bold source)
        (let ((whole (ebox-composite-slice source 0 28))
              (middle (ebox-composite-slice source 7 21)))
          (should (equal-including-properties source whole))
          (should (eq (get-text-property 2 'display whole) display))
          (should (string-blank-p middle))
          (should-not (get-text-property 0 'keymap middle))
          (ebox-composite-test--assert-width whole 28)
          (ebox-composite-test--assert-width middle 14))))))

(ert-deftest ebox-composite-line-resolves-overlapping-opaque-a-b-c ()
  "The last placement wins, including its blank pixels, at stable positions."
  (ebox-composite-test--with-metrics
    (let* ((base "0123456789")
           (placements (list (list :text "AAAAAA" :x 7)
                             (list :text "BBBB" :x 21)
                             (list :text " C " :x 28)))
           (output (ebox-composite-line base placements 70)))
      (should (equal (substring-no-properties output) "0AAB C 789"))
      (ebox-composite-test--assert-width output 70)
      (should (equal base "0123456789"))
      (should (equal placements '((:text "AAAAAA" :x 7)
                                  (:text "BBBB" :x 21)
                                  (:text " C " :x 28)))))))

(ert-deftest ebox-composite-line-preserves-underlay-right-coordinates ()
  "Cutting an underlay glyph cannot pull its right-hand neighbor leftward."
  (ebox-composite-test--with-metrics
    (let ((output (ebox-composite-line
                   "ABCD" (list (list :text (ebox-pixel-space 10) :x 3)) 28)))
      (should (equal (substring-no-properties output) "   CD"))
      (ebox-composite-test--assert-width output 28)
      (should (= (ebox--string-pixel-width
                  (substring output 0 (string-match "C" output))) 14)))))

(ert-deftest ebox-composite-line-handles-negative-and-clipped-placements ()
  "Canvas clipping retains original placement coordinates at both edges."
  (ebox-composite-test--with-metrics
    (let ((output
           (ebox-composite-line
            "012345" (list (list :text "ABC" :x -10)
                           (list :text "XY" :x 35)
                           (list :text "hidden" :x 100)) 42)))
      (should (equal (substring-no-properties output) " C 234X"))
      (ebox-composite-test--assert-width output 42))))

(ert-deftest ebox-composite-line-hidden-boundaries-do-not-split-top-glyph ()
  "A hidden lower placement cannot fragment a fully visible replacement."
  (ebox-composite-test--with-metrics
    (let* ((display (copy-sequence "ABC"))
           (top (propertize "source" 'display display))
           (output (ebox-composite-line
                    nil (list (list :text (ebox-pixel-space 2) :x 4)
                              (list :text (ebox-pixel-space 3) :x 10)
                              (list :text top :x 0)) 21)))
      (should (equal-including-properties output top))
      (should (eq (get-text-property 0 'display output) display))
      (ebox-composite-test--assert-width output 21))))

(ert-deftest ebox-composite-line-keeps-adjacent-eq-runs-separate ()
  "Independent touching placements sharing a display still occupy two runs."
  (ebox-composite-test--with-metrics
    (let* ((display (list 'space :width '(10)))
           (keymap (make-sparse-keymap))
           (text (propertize "ab" 'display display 'keymap keymap))
           (output (ebox-composite-line
                    nil (list (list :text text :x 0)
                              (list :text text :x 10)) 20)))
      (ebox-composite-test--assert-width output 20)
      (should (eq (get-text-property 0 'display output) display))
      (should (eq (get-text-property (1- (length output)) 'display output)
                  display))
      (should-not (get-text-property 2 'keymap output))
      (should (eq (get-text-property 3 'keymap output) keymap)))))

(ert-deftest ebox-composite-line-keeps-independent-shaping-extents ()
  "Neighboring sources cannot form a ligature that moves the right edge."
  (ebox-composite-test--with-metrics
    (let ((output (ebox-composite-line
                   "fZ" (list (list :text "i" :x 7)) 14)))
      (ebox-composite-test--assert-width output 14)
      (should (equal (substring-no-properties output) "f i"))
      (should (equal (get-text-property 1 'display output)
                     '(space :width (0)))))))

(ert-deftest ebox-composite-slice-full-line-keeps-zero-width-source-units ()
  "A complete line retains even a zero-width source's display height."
  (ebox-composite-test--with-metrics
    (let* ((display (list 'space :width '(0) :height '(24)))
           (source (concat "A" (propertize "tail" 'display display)))
           (output (ebox-composite-slice source 0 7)))
      (should (equal-including-properties output source))
      (should (eq (get-text-property 1 'display output) display))
      (ebox-composite-test--assert-width output 7))))

(ert-deftest ebox-composite-line-uses-latest-base-after-placement-removal ()
  "Composition retains no stale underlay state between successive calls."
  (ebox-composite-test--with-metrics
    (let* ((placements (list (list :text "XX" :x 7)))
           (old (ebox-composite-line "abcdef" placements 42))
           (updated (ebox-composite-line "123456" placements 42))
           (restored (ebox-composite-line "123456" nil 42)))
      (should (equal old "aXXdef"))
      (should (equal updated "1XX456"))
      (should (equal restored "123456"))
      (dolist (output (list old updated restored))
        (ebox-composite-test--assert-width output 42)))))

(ert-deftest ebox-composite-line-neutral-gaps-have-no-source-properties ()
  "A short or absent base does not lend interaction properties to root fill."
  (ebox-composite-test--with-metrics
    (let* ((keymap (make-sparse-keymap))
           (base (propertize "A" 'keymap keymap 'help-echo "base"))
           (output (ebox-composite-line base nil 21)))
      (ebox-composite-test--assert-width output 21)
      (should (eq (get-text-property 0 'keymap output) keymap))
      (should-not (get-text-property 1 'keymap output))
      (should-not (get-text-property 1 'help-echo output)))
    (ebox-composite-test--assert-width (ebox-composite-line nil nil 12.5) 12.5)))

(ert-deftest ebox-composite-rejects-invalid-bounds-and-lines ()
  "Invalid extents and multiline inputs fail before source mutation."
  (dolist (bounds '((-1 2) (3 2) (nil 1) (0 nope) (0 1.0e+INF)))
    (should-error (apply #'ebox-composite-slice "abc" bounds)))
  (should-error (ebox-composite-slice "a\nb" 0 1))
  (should-error (ebox-composite-line "a\nb" nil 10))
  (should-error (ebox-composite-line nil '((:text "x" :x nope)) 10))
  (should-error (ebox-composite-line nil '((:text "x\ny" :x 0)) 10))
  (should-error (ebox-composite-line nil nil -1))
  (should-error (ebox-composite-line nil '(broken . list) 10)))

(provide 'ebox-composite-tests)
;;; ebox-composite-tests.el ends here
