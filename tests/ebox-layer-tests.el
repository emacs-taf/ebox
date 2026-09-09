;;; ebox-layer-tests.el --- Box composition contracts -*- lexical-binding: t; -*-

(require 'ert)
(require 'ebox)

(defun ebox-layer-test--render (form)
  "Render FORM through the public canonical boundary."
  (ebox-render (ebox-build form)))

(ert-deftest ebox-layer-minimal-opaque-overlap ()
  (let ((output
         (ebox-layer-test--render
          '(box :width (ch 10) :height (lh 3)
                (box "abcdefghij\nABCDEFGHIJ\n0123456789")
                (box :position absolute :left (ch 2) :top (lh 1)
                     :width (ch 4) :height (lh 1) :background-color "red"
                     "TOP")))))
    (should (equal (substring-no-properties output)
                   "abcdefghij\nABTOP GHIJ\n0123456789"))
    (should (= (length (ebox-string-lines output)) 3))))

(ert-deftest ebox-layer-relative-reserves-flow-slot ()
  (let ((lines
         (ebox-string-lines
          (ebox-layer-test--render
           '(column :width (ch 10) :height (lh 3)
                    (box :position relative :left (ch 2) :top (lh 1)
                         :z-index 1 :width (ch 4) "MOVE")
                    (box "abcdefghij")
                    (box "0123456789"))))))
    (should (= (length lines) 3))
    (should-not (string-match-p "MOVE" (car lines)))
    (should (equal (substring-no-properties (cadr lines)) "abMOVEghij"))
    (should (equal (substring-no-properties (nth 2 lines)) "0123456789"))))

(ert-deftest ebox-layer-negative-z-stays-below-normal-content ()
  (let ((output (ebox-layer-test--render
                 '(box :width (ch 6) :height (lh 1)
                       (box "BOTTOM")
                       (box :position absolute :width (ch 6) :z-index -1 "HIDDEN")))))
    (should (equal (substring-no-properties output) "BOTTOM"))))

(ert-deftest ebox-layer-nested-isolation-orders-groups ()
  (let ((output (ebox-layer-test--render
                 '(box :width (ch 6) :height (lh 1)
                       (box
                            (box "BOTTOM")
                            (box :position absolute :width (ch 6)
                                 :z-index 100 "INSIDE"))
                       (box :position absolute :width (ch 6) :z-index 1 "FRONT!")))))
    (should (equal (substring-no-properties output) "FRONT!"))))

(ert-deftest ebox-layer-root-projection-escapes-local-clipping ()
  (let ((output (ebox-layer-test--render
                 '(box :width (ch 10) :height (lh 3)
                       (box :height (lh 1) :overflow hidden
                            (box :id trigger "BUTTON")
                            (box :position absolute :layer root :anchor trigger
                                 :width (ch 4) :height (lh 1) "MENU"))
                       (box "abcdefghij\n0123456789")))))
    (should (equal (substring-no-properties output)
                   "BUTTON \nMENUefghij\n0123456789"))))

(ert-deftest ebox-layer-missing-anchor-does-not-paint ()
  (let ((output (ebox-layer-test--render
                 '(box :width (ch 6) :height (lh 1)
                       (box "BOTTOM")
                       (box :position absolute :anchor missing
                            :width (ch 6) "HIDDEN")))))
    (should (equal (substring-no-properties output) "BOTTOM"))))

(ert-deftest ebox-layer-hidden-upper-reveals-base ()
  (let ((output (ebox-layer-test--render
                 '(box :width (ch 6) :height (lh 1)
                       (box "LATEST")
                       (box :position absolute :visibility hidden
                            :width (ch 6) "HIDDEN")))))
    (should (equal (substring-no-properties output) "LATEST"))))

(provide 'ebox-layer-tests)
;;; ebox-layer-tests.el ends here
