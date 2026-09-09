;;; ebox-composite-tests.el --- Pixel row compositor tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Independent deterministic display metrics exercise cuts and coverage without
;; requiring a GUI frame.  Production measurement still handles EQ display runs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)
(require 'ebox-composite)

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
