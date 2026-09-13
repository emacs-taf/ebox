;;; ebox-layer-style-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defconst ebox-layer-style-test--defaults
  '(:position static :left (px 0) :top (lh 0)
    :z-index 0 :layer local :anchor nil :placement bottom-start)
  "Initial values of the public layer style properties.")

(defconst ebox-layer-style-test--values
  '(:position absolute :left (ch -1.25) :top (lh -0.5)
    :z-index -2 :layer root :anchor menu-button :placement top-end)
  "Nondefault layer declarations covering every public layer property.")

(ert-deftest ebox-layer-style-accepts-existing-box-layouts-only ()
  "Every box layout accepts layer facts, while Text rejects every property."
  (dolist (tag '(box row column flex grid))
    (let ((compiled (ebox-style-compile-form
                     tag ebox-layer-style-test--values)))
      (cl-loop for (name value) on ebox-layer-style-test--values by #'cddr
               do (should (equal (plist-get compiled (ebox-style-schema-id name))
                                 value)))))
  (cl-loop for (name value) on ebox-layer-style-test--defaults by #'cddr
           do (should-error (ebox-style-compile-form 'text (list name value)))))

(ert-deftest ebox-layer-style-enums-and-anchor-grammar ()
  "Public enums, signed integer depth, and optional semantic anchors compile."
  (dolist (case '((:position static relative absolute)
                  (:z-index -100 0 100)
                  (:layer local root)
                  (:anchor nil menu-button "menu-button")
                  (:placement bottom-start bottom-end top-start top-end)))
    (dolist (value (cdr case))
      (should (equal (ebox-style-compile-form 'box (list (car case) value))
                     (list (ebox-style-schema-id (car case)) value))))))

(ert-deftest ebox-layer-style-rejects-invalid-static-declarations ()
  "Invalid layer values signal at both DSL and stylesheet boundaries."
  (dolist (case '((:position nil t fixed sticky normal "absolute" (absolute))
                  (:z-index nil t auto 1.0 -1.5 "2" (px 2) (lambda () 2))
                  (:layer nil t absolute global "root" (root))
                  (:anchor 1 1.5 (target) (:id target) [target])
                  (:placement nil t bottom center left "top-end" (top-end))))
    (dolist (value (cdr case))
      (ert-info ((format "%S rejects %S" (car case) value))
        (should-error (ebox-style-compile-form 'box (list (car case) value)))
        (should-error (ebox-style-compile-declarations
                       (list (car case) value) t))))))

(ert-deftest ebox-layer-style-offset-expressions-preserve-axis-and-sign ()
  "Expression operands keep axis validation even when they cancel out."
  (dolist (case '((:left (calc (- (ch 1) (% 50))))
                  (:left (min (px -2) (vw -10)))
                  (:left (clamp (ch -3) (% -20) (px 4)))
                  (:top (calc (+ (lh -0.5) (vh 10))))
                  (:top (max (lh -2) (% -30)))
                  (:top (clamp (lh -3) (% -20) (vh 4)))))
    (should (equal (ebox-style-compile-form 'box case)
                   (list (ebox-style-schema-id (car case)) (cadr case)))))
  (dolist (case '((:left (calc (* 0 (lh -1))))
                  (:left (min (ch -1) (vh 0)))
                  (:top (calc (* 0 (px -1))))
                  (:top (max (lh -1) (vw 0)))))
    (should-error (ebox-style-compile-form 'box case) :type 'ebox-size-error)))

(provide 'ebox-layer-style-tests)
;;; ebox-layer-style-tests.el ends here
