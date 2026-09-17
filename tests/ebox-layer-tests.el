;;; ebox-layer-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
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

(ert-deftest ebox-layer-source-intervals-preserve-unicode-and-properties ()
  "Layer visibility retains untouched flow glyphs and their native properties."
  (let* ((text (propertize "中éZ" 'help-echo "Unicode source"))
         (make-input
          (lambda (hidden)
            (ebox-build
             `(row :width (ch 6) :height (lh 1)
                   (box :width (ch 2) "AA")
                   (box :width (ch 4) ,text)
                   (box :position absolute :left (ch 1) :width (ch 1)
                        :height (lh 1) :visibility ,(if hidden 'hidden 'visible)
                        "Q")))))
         (buffer (generate-new-buffer " *layer-source-intervals*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (funcall make-input t))
          (dolist (hidden '(nil t nil))
            (ebox-commit buffer (funcall make-input hidden))
            (with-current-buffer buffer
              (should (equal (buffer-substring-no-properties (point-min) (point-max))
                             (if hidden "AA中éZ" "AQ中éZ")))
              (should (equal (get-text-property (+ (point-min) 2) 'help-echo)
                             "Unicode source"))))
          (should (equal text (propertize "中éZ" 'help-echo "Unicode source"))))
      (when (buffer-live-p buffer)
        (when (ebox-surface-buffer-mounted-p buffer) (ebox-unmount-buffer buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-layer-flow-z-order-can-cross-overlay ()
  "Retained normal-flow content can move above and below a positioned layer."
  (let ((buffer (generate-new-buffer " *layer-flow-z*"))
        (input (lambda (z)
                 (ebox-build `(box :width (ch 6) :height (lh 1)
                                   (box :z-index ,z "BOTTOM")
                                   (box :position absolute :z-index 1
                                        :width (ch 6) :height (lh 1) "FRONT!"))))))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer (funcall input 0))
          (dolist (z '(2 0 2 0))
            (ebox-commit buffer (funcall input z))
            (with-current-buffer buffer
              (should (equal (buffer-substring-no-properties (point-min) (point-max))
                             (if (> z 1) "BOTTOM" "FRONT!"))))))
      (when (buffer-live-p buffer)
        (when (ebox-surface-buffer-mounted-p buffer) (ebox-unmount-buffer buffer))
        (kill-buffer buffer)))))

(provide 'ebox-layer-tests)
;;; ebox-layer-tests.el ends here
