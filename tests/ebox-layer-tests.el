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

(ert-deftest ebox-layer-max-content-row-paints-positioned-descendants ()
  (let ((output (ebox-layer-test--render
                 '(row :width max-content
                       (box :width (ch 4) :height (lh 1)
                            (box "ABCD")
                            (box :position absolute :left (ch 1)
                                 :width (ch 2) "XX"))))))
    (should (equal (substring-no-properties output) "AXXD"))))

(ert-deftest ebox-layer-anchor-dependency-resolves-before-paint-order ()
  (let ((output (ebox-layer-test--render
                 '(box :width (ch 10) :height (lh 4)
                       (box "0123456789\nabcdefghij\nABCDEFGHIJ\n0123456789")
                       (box :position absolute :anchor parent-panel :width (ch 4)
                            :z-index 2 "MENU")
                       (box :id parent-panel :position absolute :left (ch 2)
                            :top (lh 1) :width (ch 4) :z-index 1 "BASE")))))
    (should (equal (substring-no-properties output)
                   "0123456789\nabBASEghij\nABMENUGHIJ\n0123456789"))))

(ert-deftest ebox-layer-anchor-cycles-are-rejected ()
  (should-error
   (ebox-layer-test--render
    '(box :width (ch 10) :height (lh 4)
          (box :id a :position absolute :anchor b "A")
          (box :id b :position absolute :anchor a "B")))))

(ert-deftest ebox-layer-absolute-margins-do-not-cover-underlay ()
  (let ((output (ebox-layer-test--render
                 '(box :width (ch 8) :height (lh 3)
                       (box "abcdefgh\nABCDEFGH\n01234567")
                       (box :position absolute :width (ch 4) :height (lh 1)
                            :margin ((lh 1) (ch 1)) :background-color "red"
                            "TOP!")))))
    (should (equal (substring-no-properties output)
                   "abcdefgh\nATOP!FGH\n01234567"))))

(ert-deftest ebox-layer-absolute-keeps-all-flow-layout-sizes ()
  (dolist (tag '(box row column flex grid))
    (let* ((form `(,tag :width (ch 8)
                       (box :width (ch 8) :height (lh 1) "abcdefgh")
                       (box :position absolute :left (ch 2)
                            :width (ch 2) :height (lh 9) "XX")))
           (output (ebox-layer-test--render form)))
      (ert-info ((format "Layout %s" tag))
        (should (= (length (ebox-string-lines output)) 1))
        (should (equal (substring-no-properties output) "abXXefgh"))))))

(ert-deftest ebox-layer-root-projection-inside-an-absolute-panel ()
  (let ((output (ebox-layer-test--render
                 '(box :width (ch 10) :height (lh 4)
                       (box "0123456789\nabcdefghij\nABCDEFGHIJ\n0123456789")
                       (box :position absolute :left (ch 2) :top (lh 1)
                            :width (ch 4) :height (lh 1)
                            (box :id trigger "BASE")
                            (box :position absolute :layer root :anchor trigger
                                 :width (ch 4) :height (lh 1) "MENU"))))))
    (should (equal (substring-no-properties output)
                   "0123456789\nabBASEghij\nABMENUGHIJ\n0123456789"))))

(ert-deftest ebox-layer-native-to-layer-transition-keeps-composition ()
  (skip-unless (and (fboundp 'ebox-native-reflow-layout-ready-p)
                    (ebox-native-reflow-layout-ready-p)))
  (let ((ebox-viewport-width 80) (ebox-viewport-height 10)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build '(column :width (px 8) :height (lh 2)
                           (box :id "lower" :width (px 8) :height (lh 1) "LOWER001")
                           (box :id "upper" :width (px 8) :height (lh 1) "UPPER001"))))
      (should (eq (plist-get (ebox--buffer-render-state (current-buffer))
                             :projection-kind) 'native-frame))
      (should (ebox-region-update "upper" :position 'absolute))
      (should (plist-get (ebox--buffer-render-state (current-buffer)) :layered-p))
      (should-not (string-match-p "LOWER001" (buffer-string)))
      (should (string-match-p "UPPER001" (buffer-string)))
      (ebox-region-update "lower" :content "LOWER002")
      (ebox-region-update "upper" :visibility 'hidden)
      (should (string-match-p "LOWER002" (buffer-string)))
      (should-not (string-match-p "UPPER001" (buffer-string))))))

(provide 'ebox-layer-tests)
;;; ebox-layer-tests.el ends here
