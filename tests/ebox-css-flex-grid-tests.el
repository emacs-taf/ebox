;;; ebox-css-flex-grid-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

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

(ert-deftest ebox-css-flex-grid-reject-implicit-size-syntax ()
  "Unitless values and parameterized fit-content never enter configs."
  (dolist (value '(2 (2) viewport (viewport-height) (fit-content (ch 80))))
    (should-error (ebox-flex-layout-create :column-gap value))
    (should-error (ebox-flex-layout-create :row-gap value))
    (should-error
     (ebox-grid-layout-create :grid-template-columns (list value)))))

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

(ert-deftest ebox-flex-minima-preserve-overflow-semantics-in-both-backends ()
  "Explicit minima replace content floors; scrollable auto minima permit shrink."
  (let ((ebox-viewport-width 8)
        (ebox-viewport-height 20))
    (dolist (axis '(row column))
      (dolist (minimum '(auto zero small floor))
        (dolist (overflow '(visible hidden scroll))
          (let* ((row (eq axis 'row))
                 (size (if row '(px 8) '(lh 4)))
                 (min (pcase minimum
                        ('auto 'auto)
                        ('zero (if row '(ch 0) '(lh 0)))
                        ('floor (if row '(ch 6) '(lh 3)))
                        (_ (if row '(ch 2) '(lh 1)))))
                 (input
                  (ebox-build
                   `(flex :wrap-mode none :overflow visible
                          :flex-direction ,axis ,(if row :width :height) ,size
                          (box :id a :flex-shrink 1 :overflow ,overflow :wrap-mode word
                               ,(if row :min-width :min-height) ,min "Alpha Bravo")
                          (box :id b :flex-shrink 1 :overflow ,overflow :wrap-mode word
                               ,(if row :min-width :min-height) ,min "Charlie Delta")))))
            (with-temp-buffer
              (ebox-render-to-buffer (current-buffer) input)
              (ert-info ((format "%S %S %S" axis minimum overflow))
                (should
                 (equal (buffer-substring-no-properties (point-min) (point-max))
                        (cond
                         ((eq minimum 'floor)
                          (if row "Alpha Charli\nBravo e  \n Delta "
                            "Alpha  \nBravo \n \nCharlie \nDelta \n "))
                         (row
                          (if (and (eq minimum 'auto) (eq overflow 'visible))
                              "AlphaCharlie\nBravoDelta "
                            "AlpCharl\nha ie  \nBraDelta\nvo  "))
                         ((eq overflow 'visible)
                          "Alpha  \nBravo \nCharlie \nDelta ")
                         (t "Alpha  \nCharlie \n \n "))))))))))))

(ert-deftest ebox-stretched-row-preserves-cell-paint-through-updates ()
  "Grid and nested Flex retain clipping and cell paint at an assigned height."
  (let ((ebox-viewport-width 80)
        (ebox-viewport-height 20))
    (dolist (configuration '((grid row) (grid column) (flex row) (flex column)))
      (let ((layout (car configuration))
            (direction (cadr configuration)))
        (with-temp-buffer
          (ebox-render-to-buffer
           (current-buffer)
           (ebox-build
            `(flex :id frame :width (px 20) :height (lh 4) :align-items stretch
                   :flex-direction ,direction
                   (,layout :width (px 20) :column-gap (ch 1) :flex-grow 1
                            ,@(when (eq layout 'grid)
                                '(:grid-template-columns ((ch 5) (ch 7))))
                            (box :id a :width ,(if (eq layout 'grid) 'stretch '(ch 5))
                                 ,@(when (eq layout 'flex) '(:flex-shrink 0))
                                 :overflow hidden :wrap-mode none
                                 :background-color "red" "Alphabet")
                            (box :width ,(if (eq layout 'grid) 'stretch '(ch 7))
                                 ,@(when (eq layout 'flex) '(:flex-shrink 0))
                                 :overflow hidden :wrap-mode none
                                 :background-color "blue" "CharlieDelta")))))
          (cl-labels
              ((check-rows
                 (height prefix)
                 (let ((lines (split-string (buffer-string) "\n" nil)))
                   (should (= (length lines) height))
                   (should (string-prefix-p prefix (car lines)))
                   (dolist (line lines)
                     (should (= (ebox-string-pixel-width line) 20))
                     (dolist (paint '(("red" . 5) ("blue" . 7)))
                       (let ((width 0))
                         (dotimes (index (length line))
                           (when (equal (plist-get (get-text-property index 'face line)
                                                   :background)
                                        (car paint))
                             (setq width (+ width (ebox-string-pixel-width
                                                   (substring line index (1+ index)))))))
                         (should (= width (cdr paint)))))))))
            (check-rows 4 "Alpha Charlie")
            (ebox-region-update "a" :content "OtherText")
            (check-rows 4 "Other Charlie")
            (ebox-region-update "frame" :height '(lh 2))
            (check-rows 2 "Other Charlie")
            (ebox-rerender-buffer-with-context (current-buffer) 40 10)
            (check-rows 2 "Other Charlie")
            (ebox-region-update "frame" :height 'auto)
            (check-rows 1 "Other Charlie")))))))

(provide 'ebox-css-flex-grid-tests)
;;; ebox-css-flex-grid-tests.el ends here
