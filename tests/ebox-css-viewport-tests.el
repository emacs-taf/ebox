;;; ebox-css-viewport-tests.el --- CSS viewport retention contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Public DSL construction and retained rendering must preserve viewport
;; dependencies through fixed containing blocks and retained updates.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defun ebox-css-viewport-test--root (input)
  "Return the canonical root owned by INPUT."
  (ebox-canonical-input--single-root input "CSS viewport test"))

(defun ebox-css-viewport-test--geometry (output)
  "Return OUTPUT's line count and line pixel widths without runtime IDs."
  (list (ebox-string-height output)
        (mapcar #'ebox--string-pixel-width (ebox-string-lines output))))

(ert-deftest ebox-css-viewport-own-dependencies-follow-valid-axis-units ()
  (dolist
      (case
       '(((box :width (vw 50) :height (lh 1) "x") t nil)
         ((box :width (px 20) :height (vh 20) "x") nil t)
         ((box :width (px 20) :height (lh 1)
               :padding ((vh 2) (px 0)) "x") nil t)
         ((box :width (px 20) :height (lh 1)
               :margin-top (calc (+ (vh 2) (lh 1))) "x") nil t)
         ((flex :width (px 20) :height (lh 1)
                :row-gap (max (lh 0) (vh 2)) :column-gap (px 0)
                (box "x")) nil t)
         ((grid :width (px 20) :height (lh 1)
                :grid-template-columns ((min (ch 8) (vw 50)) (fr 1))
                :grid-template-rows ((lh 1))
                (box "x")) t nil)
         ((box :width (ch 20) :height (lh 3)
               :padding ((lh 1) (px 1)) "x") nil nil)))
    (ert-info ((format "DSL: %S" (car case)))
      (let ((node (ebox-css-viewport-test--root (ebox-build (car case)))))
        (should (eq (not (null (ebox--node-size-viewport-dependent-p
                               node 'viewport-width)))
                    (nth 1 case)))
        (should (eq (not (null (ebox--node-size-viewport-dependent-p
                               node 'viewport-height)))
                    (nth 2 case)))))))

(ert-deftest ebox-css-viewport-width-id-survives-a-fixed-containing-block ()
  (let* ((input (ebox-build
                 '(box :width (px 80)
                       (box :width (vw 20) :height (lh 1) "x"))))
         (root (ebox-css-viewport-test--root input))
         (child (car (ebox--node-children root)))
         (axes (ebox--viewport-dependent-node-id-axes root)))
    (should (ebox--node-size-viewport-dependent-p child 'viewport-width))
    (should (memq (plist-get child :node-id) (car axes)))))

(ert-deftest ebox-css-viewport-both-axes-retained-resize-matches-fresh-render ()
  (let ((buffer (generate-new-buffer " *ebox-css-viewport*"))
        (ebox-viewport-width 100)
        (ebox-viewport-height 20)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil)
        (input (ebox-build
                '(box :width (vw 50)
                      :height (calc (- (vh 20) (lh 1))) "x"))))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                   (lambda () nil)))
          (ebox-render-to-buffer buffer input)
          (let* ((first (with-current-buffer buffer (buffer-string)))
                 (first-geometry (ebox-css-viewport-test--geometry first)))
            (ebox-rerender-buffer-with-context buffer 200 20)
            (let* ((second (with-current-buffer buffer (buffer-string)))
                   (second-geometry (ebox-css-viewport-test--geometry second))
                   (ebox-viewport-width 200)
                   (fresh (ebox-render input)))
              (should (eq (plist-get (ebox-buffer-update-report buffer)
                                    :viewport-axes)
                          'width))
              (should (= (car second-geometry) (car first-geometry)))
              (should (< (car (cadr first-geometry))
                         (car (cadr second-geometry))))
              (should (equal second-geometry
                             (ebox-css-viewport-test--geometry fresh)))
              (ebox-rerender-buffer-with-context buffer 200 40)
              (let* ((third (with-current-buffer buffer (buffer-string)))
                     (third-geometry (ebox-css-viewport-test--geometry third))
                     (ebox-viewport-height 40))
                (should (eq (plist-get (ebox-buffer-update-report buffer)
                                      :viewport-axes)
                            'height))
                (should (< (car second-geometry) (car third-geometry)))
                (should (= (car (cadr third-geometry))
                           (car (cadr second-geometry))))
                (should (equal third-geometry
                               (ebox-css-viewport-test--geometry
                                (ebox-render input))))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-css-viewport-nested-percent-and-viewport-use-different-bases ()
  (let* ((input (ebox-build
                 '(box :width (px 80)
                       (box :width (vw 10) "viewport")
                       (box :width (% 50) "percent"))))
         (resolve (symbol-function 'ebox-size-resolve))
         (ebox-viewport-height 20))
    (dolist (width '(200 400))
      (let ((ebox-viewport-width width)
            observations)
        (cl-letf (((symbol-function 'ebox-size-resolve)
                   (lambda (value context)
                     (let ((result (funcall resolve value context)))
                       (when (member value '((vw 10) (% 50)))
                         (push (list value result) observations))
                       result))))
          (ebox-render input))
        (should (member (list '(vw 10) (/ width 10.0)) observations))
        (should (member '((% 50) 40.0) observations))))))

(ert-deftest ebox-css-viewport-nested-fixed-parent-rerenders-viewport-child ()
  (let ((buffer (generate-new-buffer " *ebox-css-nested-viewport*"))
        (ebox-viewport-width 100)
        (ebox-viewport-height 20)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil)
        (input (ebox-build
                '(box :width (px 80)
                      (box :width (px 20) :height (vh 20) "x")))))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                   (lambda () nil)))
          (ebox-render-to-buffer buffer input)
          (let ((before (with-current-buffer buffer
                          (ebox-string-height (buffer-string)))))
            (ebox-rerender-buffer-with-context buffer 100 40)
            (let* ((ebox-viewport-height 40)
                   (actual (with-current-buffer buffer (buffer-string)))
                   (fresh (ebox-render input)))
              (should (> (ebox-string-height fresh) before))
              (should (equal (ebox-css-viewport-test--geometry actual)
                             (ebox-css-viewport-test--geometry fresh))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'ebox-css-viewport-tests)
;;; ebox-css-viewport-tests.el ends here
