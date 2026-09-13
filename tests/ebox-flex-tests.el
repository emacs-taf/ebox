;;; ebox-flex-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defun ebox-flex-test--render (node)
  "Render NODE once for flex tests."
  (ebox-render node))

(defun ebox-flex-test--plain-lines (node)
  "Return rendered NODE as plain lines."
  (ebox-string-lines (substring-no-properties (ebox-flex-test--render node))))

(defun ebox-flex-test--region-property-width (string region-id property)
  "Return max PROPERTY span width for REGION-ID in STRING."
  (let ((pos 0)
        (len (length string))
        (max-width 0))
    (while (< pos len)
      (if (equal (get-text-property pos property string) region-id)
          (let ((end (or (next-single-property-change
                          pos property string len)
                         len)))
            (setq max-width
                  (max max-width
                       (string-pixel-width (substring string pos end))))
            (setq pos end))
        (setq pos (or (next-single-property-change
                       pos 'ebox-content string len)
                      len))))
    max-width))

(ert-deftest ebox-flex-module-preserves-item-participation ()
  "Extracted flex code should preserve item participation semantics."
  (let* ((node (ebox-build
                '(flex :width (px 240)
                  (box :flex-grow 1 :width (px 40) "Grow")
                  (box :width (px 40) "Fixed"))))
         (rendered (ebox-render node)))
    (should (string-match-p "Grow" rendered))
    (should (string-match-p "Fixed" rendered))))

(ert-deftest ebox-flex-row-wrap-measures-column-items-at-natural-width ()
  "Column flex items should not stretch to the full row before line breaking."
  (let* ((layout
          (ebox-build
           '(flex :flex-flow (row wrap) :column-gap (px 12) :width (px 800)
             (column
              (box :width (px 220) "one")
              (box :width (px 42) "A"))
             (column
              (box :width (px 220) "two")
              (box :width (px 42) "B"))
             (column
              (box :width (px 220) "three")
              (box :width (px 42) "C")))))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 2))
    (should (string-match-p "one.*two.*three" (car lines)))
    (should (string-match-p "A.*B.*C" (cadr lines)))))

(ert-deftest ebox-flex-rerenders-composite-item-for-assigned-viewport ()
  "Composite flex items should re-render internals for final item width."
  (let* ((layout
          (ebox-build
           '(flex :flex-flow (row wrap) :column-gap (px 12) :width (px 800)
             (column
              (box :id "title" :max-width (px 293)
                   :padding ((lh 0) (px 10)) :border "#5E7F6A"
                   :text-align center "wrap")
              (flex :id "body" :max-width (px 293) :padding ((lh 0) (px 8))
                    :border-right "#5E7F6A"
                    :border-bottom "#5E7F6A"
                    :border-left "#5E7F6A"
                    :flex-wrap wrap :column-gap (px 8)
                    (box :flex-shrink 0 :width (px 118) "A 118")
                    (box :flex-shrink 0 :width (px 118) "B 118")
                    (box :flex-shrink 0 :width (px 118) "C 118"))))))
         (buffer (generate-new-buffer " *ebox-flex-viewport*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (let* ((rendered (with-current-buffer buffer (buffer-string)))
                 (title-id (plist-get
                            (car (ebox-selector-query-buffer buffer "#title"))
                            :region-id))
                 (body-id (plist-get
                           (car (ebox-selector-query-buffer buffer "#body"))
                           :region-id))
                 (title-width (ebox-flex-test--region-property-width
                               rendered title-id 'ebox-bt))
                 (body-width (ebox-flex-test--region-property-width
                              rendered body-id 'ebox-bb)))
            (should (> title-width 200))
            (should (> body-width 200))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-natural-reuse-preserves-stretched-scroll-state ()
  "Stretch sizing should publish the final box geometry to scroll state."
  (let* ((ebox-viewport-width 120)
         (ebox-viewport-height 2)
         (layout
          (ebox-build
           '(flex :width (px 120)
              (box :id "root" :width (px 80) :height (vh 100)
                   :overflow scroll :flex-grow 1
                (column :width (px 80)
                  (box :height (lh 1) "A")
                  (box :height (lh 1) "B")
                  (box :height (lh 1) "C")
                  (box :height (lh 1) "D"))))))
         (buffer (generate-new-buffer " *ebox-flex-scroll-state*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (let* ((match (car (ebox-selector-query-buffer buffer "#root")))
                 (state (ebox-scroll-state (plist-get match :region-id))))
            (should (equal (ebox-get (plist-get state :box) :height) 2))
            (should-not (plist-get state :content-lines-complete-p))
            (should-not (plist-get state :render-content-prefix))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'ebox-flex-tests)
;;; ebox-flex-tests.el ends here
