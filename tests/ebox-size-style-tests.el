;;; ebox-size-style-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(ert-deftest ebox-size-style-canonical-values ()
  "Each size property accepts explicit lengths in its own rendering axis."
  (dolist (case '(((:width :min-width :max-width)
                   (px 12) (% 50) (vw 33.5) (ch 80)
                   (calc (- (vw 100) (ch 1)))
                   (min (% 100) (ch 80))
                   (clamp (px 1) (% 50) (ch 80)))
                  ((:height :min-height :max-height)
                   (lh 3) (vh 100) (% 50)
                   (calc (- (vh 100) (lh 1)))
                   (min (% 100) (lh 8))
                   (clamp (lh 1) (% 50) (vh 80)))))
    (dolist (property (car case))
      (dolist (value (cdr case))
        (should (ebox-style-compile-form 'box (list property value)))))))

(ert-deftest ebox-size-style-rejects-legacy-values ()
  "Legacy implicit lengths fail at every author dimension boundary."
  (dolist (value '(12 0 (12) (0) viewport (viewport) viewport-height
                  (viewport-height) contain (fit-content (ch 80))))
    (dolist (property '(:width :height :min-width :min-height
                       :max-width :max-height))
      (should-error (ebox-style-compile-form 'box (list property value))))))

(ert-deftest ebox-size-style-keyword-applicability ()
  "Maximum sizes accept none and reject auto on either axis."
  (dolist (property '(:max-width :max-height))
    (should-error (ebox-style-compile-form 'box (list property 'auto)))
    (dolist (keyword '(none min-content max-content fit-content stretch))
      (should (ebox-style-compile-form 'box (list property keyword)))))
  (dolist (property '(:width :height :min-width :min-height))
    (should-error (ebox-style-compile-form 'box (list property 'none)))))

(ert-deftest ebox-size-style-shorthands-preserve-atomic-expressions ()
  "Shorthands distinguish one size expression from several edge values."
  (let ((declarations (ebox-style-compile-form
                       'box '(:padding ((lh 1) (ch 2))
                              :margin ((lh 1) (ch 2))
                              :border ((px 1) solid "red")))))
    (should (equal (plist-get declarations 'ebox/padding-block-start) '(lh 1)))
    (should (equal (plist-get declarations 'ebox/padding-inline-end) '(ch 2)))
    (should (equal (plist-get declarations 'ebox/margin-block-start) '(lh 1)))
    (should (equal (plist-get declarations 'ebox/margin-inline-end) '(ch 2)))
    (should (equal (plist-get declarations 'ebox/border-top-width) '(px 1)))))

(ert-deftest ebox-size-style-trbl-shorthand-arity ()
  "Four-side shorthands keep arity rules and each target edge's unit domain."
  (dolist (property '(:padding :margin :border-width))
    (let ((unit (if (eq property :border-width) 'px '%)))
      (dolist (amounts '((1) (1 2) (1 2 3) (1 2 3 4)))
        (should (ebox-style-compile-form
                 'box (list property (mapcar (lambda (n) (list unit n))
                                             amounts)))))))
  (let ((declarations
         (ebox-style-compile-form
          'box '(:padding ((lh 1) (px 2) (lh 3) (px 4))))))
    (should
     (equal declarations
            '(ebox/padding-block-start (lh 1)
              ebox/padding-inline-end (px 2)
              ebox/padding-block-end (lh 3)
              ebox/padding-inline-start (px 4)))))
  (dolist (property '(:padding :margin :border-width))
    (dolist (values '(nil ((px 1) (px 2) (px 3) (px 4) (px 5))))
      (should-error (ebox-style-compile-form 'box (list property values))))))

(ert-deftest ebox-size-style-pair-shorthand-arity ()
  "Axis and gap shorthands preserve atomic expressions and target axes."
  (dolist (case '((:padding-inline px) (:padding-block lh)
                  (:margin-inline px) (:margin-block lh) (:gap %)))
    (dolist (amounts '((1) (1 2)))
      (should (ebox-style-compile-form
               'flex (list (car case)
                           (mapcar (lambda (n) (list (cadr case) n))
                                   amounts))))))
  (should
   (equal (ebox-style-compile-form 'flex '(:gap ((lh 1) (ch 2))))
          '(ebox/row-gap (lh 1) ebox/column-gap (ch 2))))
  (let ((expression '(min (% 1) (% 2) (% 3) (% 4) (% 5))))
    (should
     (equal (ebox-style-compile-form 'flex (list :gap expression))
            (list 'ebox/row-gap expression 'ebox/column-gap expression))))
  (dolist (property '(:padding-inline :padding-block
                     :margin-inline :margin-block :gap))
    (dolist (values '(nil ((px 1) (px 2) (px 3))))
      (should-error (ebox-style-compile-form 'flex (list property values))))))

(ert-deftest ebox-size-style-property-ranges ()
  "Each property enforces its supported size and percentage ranges."
  (dolist (property '(:padding :gap :border-width :border-top-width))
    (should-error (ebox-style-compile-form 'flex (list property 1))))
  (should-error (ebox-style-compile-form 'box '(:padding (px -1))))
  (should-error (ebox-style-compile-form 'box '(:margin (px -1))))
  (should-error (ebox-style-compile-form 'box '(:border-width (% 2))))
  (should-error (ebox-style-compile-form
                 'box '(:border-width (calc (+ (px 1) (% 2)))))))

(ert-deftest ebox-size-style-recursive-axis-errors-reject-shorthands-and-tracks ()
  "Expressions cannot hide forbidden units in shorthand or Grid wrappers."
  (require 'ebox)
  (dolist (form
           '((box :height (calc (* 0 (px 1))))
             (box :max-width (clamp (px 1) (lh 1) (ch 80)))
             (box :padding ((calc (+ (lh 1) (px 0))) (ch 1)))
             (box :margin-inline (min (ch 1) (vh 1)))
             (box :padding (lh 1))
             (box :margin (px 1))
             (flex :gap (px 1))
             (grid :grid-template-rows ((minmax (lh 1) (px 2))))
             (grid :grid-template-columns ((repeat 2 (minmax (lh 1) (fr 1)))))))
    (should-error (ebox-build form)))
  (dolist (form
           '((grid :grid-template-rows ((repeat 2 (minmax (lh 1) (fr 1)))))
             (grid :grid-template-columns ((minmax (ch 1) (vw 20))))
             (grid :grid-auto-rows (max (lh 1) (vh 20)))
             (grid :grid-auto-columns (calc (+ (ch 1) (% 20))))))
    (should (ebox-build form))))

(ert-deftest ebox-size-style-stroke-units-are-independent-of-edge-orientation ()
  "All border edges retain their non-percentage paint-thickness domain."
  (dolist (property '(:border-top-width :border-right-width
                     :border-bottom-width :border-left-width))
    (dolist (unit '(px ch lh vw vh))
      (should (ebox-style-compile-form 'box (list property (list unit 1)))))
    (should-error (ebox-style-compile-form 'box (list property '(% 1))))))

(ert-deftest ebox-size-style-malformed-shorthand-functions-keep-unit-diagnostics ()
  "Malformed atomic expressions report the receiving property's unit domain."
  (dolist (case '((:gap (calc (lh 1) (lh 2) (lh 3)) ":row-gap")
                  (:padding (clamp (lh 1)) ":padding-block-start")
                  (:border ((calc (px 1) (px 2)) solid "red")
                   ":border-top-width")))
    (let ((message
           (condition-case condition
               (progn (ebox-style-compile-form 'flex (list (car case) (cadr case)))
                      nil)
             (error (error-message-string condition)))))
      (should (string-match-p (nth 2 case) message))
      (should (string-match-p "allowed units:" message)))))

(provide 'ebox-size-style-tests)
;;; ebox-size-style-tests.el ends here
