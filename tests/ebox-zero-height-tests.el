;;; ebox-zero-height-tests.el --- Empty layout height contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Empty content has no line box.  Explicit lines and box chrome retain their
;; own extents, including when their inline width is zero.

;;; Code:

(require 'ert)
(require 'ebox-fixtures)

(ert-deftest ebox-zero-height-empty-boxes-and-containers ()
  (dolist (dsl '((box) (box "") (box :width (px 20))
                 (box :bgcolor "#112233") (box :height auto)
                 (box :height (lh 0))
                 (box :padding-inline (px 2))
                 (box (box)) (column) (row)
                 (column (box) (box ""))
                 (row (box) (box ""))))
    (ert-info ((format "empty DSL: %S" dsl))
      (let* ((input (ebox-build dsl))
             (root (ebox-test-root input))
             (ebox--render-source-index (ebox-test-source-index input))
             (rendered (ebox-render input)))
        (should (equal rendered ""))
        (should (= (ebox-string-height rendered) 0))
        (should (= (ebox--total-height root) 0))))))

(ert-deftest ebox-zero-height-retains-content-and-explicit-lines ()
  (dolist (case '(((box "x") 1)
                  ((box " ") 1)
                  ((box "x\ny") 2)
                  ((box "\n") 2)
                  ((box :height (lh 1)) 1)
                  ((box :width (px 0) :height (lh 2)) 2)
                  ((box :min-height (lh 2)) 2)
                  ((box :height (lh 0.75)) 0)
                  ((box :height (lh 0) "x") 0)
                  ((box :height (lh 0) :overflow hidden "x") 0)
                  ((box :height (lh 0) :overflow visible "x") 1)
                  ((column :height (lh 0) (box "x")) 0)
                  ((row :height (lh 0) (box "x")) 0)
                  ((column :item-gap (lh 1) (box) (box)) 1)
                  ((column :item-gap (lh 2) (box) (box)) 2)))
    (ert-info ((format "line DSL: %S" (car case)))
      (let ((rendered (ebox-render (ebox-build (car case)))))
        (should (= (ebox-string-height rendered) (cadr case)))))))

(ert-deftest ebox-zero-height-composition-does-not-invent-separators ()
  (dolist (dsl '((column (box "A") (box) (box "B"))
                 (box (box :outer block "A")
                      (box :outer block)
                      (box :outer block "B"))))
    (should (equal (substring-no-properties (ebox-render (ebox-build dsl)))
                   "A\nB")))
  (should (equal (substring-no-properties
                  (ebox-render (ebox-build '(row (box "A") (box) (box "B")))))
                 "AB"))
  (should (= (ebox--string-pixel-width
              (ebox-render (ebox-build '(row (box "A") (box :width (px 20))
                                            (box "B")))))
             (+ 20 (ebox--string-pixel-width "AB"))))
  (should (= (ebox-string-height
              (ebox-render (ebox-build '(column (box :height (lh 1))
                                              (box :height (lh 1))))))
             2)))

(ert-deftest ebox-zero-height-retains-padding-margin-and-border ()
  (dolist (case '(((box :padding-block (lh 1)) 2)
                  ((box :width (px 20) :padding-block (lh 1)) 2)
                  ((box :margin-block (lh 1)) 2)
                  ((box :width (px 20) :border-top "red") 1)
                  ((box :width (px 20) :border "red") 1)
                  ((box :width (px 20) :height (lh 0) :border "red") 1)
                  ((box :width (px 20) :padding-block (lh 1) :border "red") 2)))
    (ert-info ((format "chrome DSL: %S" (car case)))
      (let* ((input (ebox-build (car case)))
             (root (ebox-test-root input))
             (rendered (ebox-render input)))
        (should (= (ebox-string-height rendered) (cadr case)))
        (should (= (ebox--total-height root) (cadr case)))))))

(ert-deftest ebox-zero-height-shared-line-representation ()
  (should-not (ebox-string-lines ""))
  (should (= (ebox-string-height nil) 0))
  (should (= (ebox-string-height "") 0))
  (should (= (ebox-string-height (ebox-lines-join '(""))) 1))
  (should (= (ebox--string-pixel-width (ebox-lines-join '(""))) 0))
  (should (= (ebox-string-height (ebox--pixel-blank 0 2)) 2))
  (should (equal (ebox--lines-stack-vertical "A" "" "B") "A\nB"))
  (should (equal (ebox--lines-concat-horizontal "" "") "")))

(ert-deftest ebox-line-measurement-preserves-display-space-widths ()
  (dolist (width '(0 86.4))
    (let ((line (propertize " " 'display `(space :width (,width)))))
      (should (= (ebox--string-pixel-width line) width))
      (should (= (ebox--string-pixel-width (ebox--lines-justify line 240))
                 240)))))

(ert-deftest ebox-zero-height-retained-surface-empty-content-transitions ()
  (dolist (initial '((box :id "root")
                     (column :id "root" (box :id "child"))))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-build initial))
      (should (equal (buffer-string) ""))
      (let ((revision (ebox-surface-buffer-revision (current-buffer))))
        (dolist (content '("A\nB" "" "C" ""))
          (let ((input
                 (ebox-build
                  (if (eq (car initial) 'column)
                      `(column :id "root" (box :id "child" ,content))
                    `(box :id "root" ,content)))))
            (ebox-commit (current-buffer) input)
            (should (> (ebox-surface-buffer-revision (current-buffer)) revision))
            (setq revision (ebox-surface-buffer-revision (current-buffer)))
            (should (equal (buffer-string) content))
            (should (equal (buffer-string)
                           (substring-no-properties (ebox-render input)))))))
      (ebox-unmount-buffer (current-buffer)))))

(ert-deftest ebox-zero-height-retained-surface-transition-rollback ()
  (dolist (contents '(("" "Added") ("Removed" "")))
    (with-temp-buffer
      (let ((before (ebox-build `(box :id "root" ,(car contents))))
            (after (ebox-build `(box :id "root" ,(cadr contents)))))
        (ebox-render-to-buffer (current-buffer) before)
        (let ((revision (ebox-surface-buffer-revision (current-buffer)))
              (rendered (buffer-string)))
          (should-error
           (ebox-commit (current-buffer) after
                        (lambda (_report) (error "Reject height transition"))))
          (should (= (ebox-surface-buffer-revision (current-buffer)) revision))
          (should (equal-including-properties (buffer-string) rendered))
          (ebox-commit (current-buffer) after)
          (should (equal (buffer-string) (cadr contents))))
        (ebox-unmount-buffer (current-buffer))))))

(provide 'ebox-zero-height-tests)
;;; ebox-zero-height-tests.el ends here
