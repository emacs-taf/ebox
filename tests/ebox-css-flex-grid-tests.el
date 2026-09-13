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

(provide 'ebox-css-flex-grid-tests)
;;; ebox-css-flex-grid-tests.el ends here
