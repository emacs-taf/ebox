;;; ebox-rendering-tests.el --- Ebox rendering behaviour tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-render-text-and-box-forms ()
  (should (equal (ebox-test-render-text "Hello") "Hello"))
  (should (equal (ebox-test-render-text '(text "Hello")) "Hello"))
  (should (equal (ebox-test-render-text '(box :width (ch 5) "Hello")) "Hello")))

(ert-deftest ebox-render-row-and-column-flow ()
  (should (equal (ebox-test-render-text
                  '(row :item-gap (ch 2)
                        (box :width (ch 3) "A")
                        (box :width (ch 3) "B")))
                 "A  B  "))
  (should (equal (ebox-test-render-text
                  '(column :width (ch 3)
                           (box :height (lh 1) "A")
                           (box :height (lh 1) "B")))
                 "A 
B ")))

(ert-deftest ebox-render-wraps-aligns-and-measures-cjk ()
  (should (equal (ebox-test-render-text '(box :width (ch 3) "abcdef"))
                 "abc
def"))
  (should (equal (ebox-test-render-text '(box :width (ch 4) :text-align right "Hi"))
                 " Hi"))
  (should (equal (ebox-test-render-text '(box :width (ch 4) :text-align center "Hi"))
                 " Hi "))
  (should (equal (ebox-test-render-text '(box :width (ch 4) "你好吗"))
                 "你好
吗 ")))

(ert-deftest ebox-render-paints-face-and-display-spaces ()
  (let* ((rendered (ebox-render
                    '(box :width (px 10) :height (lh 1)
                          :color "#112233"
                          :background-color "#ddeeff"
                          :text-decoration-line underline
                          "Hi"))))
    (should (equal (substring-no-properties rendered) "Hi "))
    (should (equal (get-text-property 0 'face rendered)
                   '((:underline (:color "#112233"))
                     (:foreground "#112233")
                     (:background "#ddeeff"))))
    (should (equal (get-text-property 2 'display rendered)
                   '(space :width (8))))))

(ert-deftest ebox-render-border-uses-display-spaces-and-border-faces ()
  (let ((rendered (ebox-render
                   '(box :width (px 10) :height (lh 1)
                         :border ((px 1) solid "#ff0000")
                         "Hi"))))
    (should (equal (substring-no-properties rendered) " Hi  "))
    (should (equal (get-text-property 0 'display rendered) '(space :width (1))))
    (let ((face (get-text-property 0 'face rendered)))
      (should (equal (plist-get (car face) :background) "#ff0000"))
      (should (equal (plist-get (cadr face) :overline) "#ff0000"))
      (should (equal (cl-some (lambda (entry) (plist-get entry :underline)) face)
                     '(:position t :color "#ff0000"))))))

(ert-deftest ebox-render-side-borders-paint-their-width ()
  (let ((rendered (ebox-render
                   '(box :width (px 10) :height (lh 1)
                         :border-left ((px 3) solid "#00ff00")
                         "Hi"))))
    (should (equal (substring-no-properties rendered) " Hi "))
    (should (equal (get-text-property 0 'display rendered) '(space :width (3))))
    (let ((face (get-text-property 0 'face rendered)))
      (should (equal (plist-get (if (keywordp (car face)) face (car face)) :background)
                     "#00ff00"))))
  (should-error (ebox-render '(box :border-top ((px 2) solid "#00ff00") "Hi"))
                :type 'ebox-error))

(ert-deftest ebox-render-flex-wraps-and-gaps-items ()
  (ebox-test-with-mounted (buffer root
                           '(flex :width (ch 8) :flex-flow (row wrap)
                                  :column-gap (ch 1) :row-gap (lh 1)
                                  (box :id "a" :width (ch 3) "A")
                                  (box :id "b" :width (ch 3) "B")
                                  (box :id "c" :width (ch 3) "C")))
    (let ((a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b")))
          (c (car (ebox-selector-query root "#c"))))
      (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 8 :height 3)))
      (should (equal (ebox-node-geometry a) '(:x 0 :y 0 :width 3 :height 1)))
      (should (equal (ebox-node-geometry b) '(:x 4 :y 0 :width 3 :height 1)))
      (should (equal (ebox-node-geometry c) '(:x 0 :y 2 :width 3 :height 1))))))

(ert-deftest ebox-render-grid-places-items-in-tracks ()
  (ebox-test-with-mounted (buffer root
                           '(grid :width (ch 6)
                                  :grid-template-columns ((ch 2) (ch 4))
                                  :grid-template-rows ((lh 1) (lh 1))
                                  (box :id "g1" :grid-column 1 :grid-row 1 "A")
                                  (box :id "g2" :grid-column 2 :grid-row 2 "B")))
    (let ((g1 (car (ebox-selector-query root "#g1")))
          (g2 (car (ebox-selector-query root "#g2"))))
      (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 6 :height 2)))
      (should (equal (ebox-node-geometry g1) '(:x 0 :y 0 :width 2 :height 1)))
      (should (equal (ebox-node-geometry g2) '(:x 2 :y 1 :width 4 :height 1))))))

(ert-deftest ebox-render-stretched-heights-fill-definite-areas ()
  (ebox-test-with-mounted (buffer root
                           '(grid :width (ch 4) :height (lh 6)
                                  :grid-template-columns ((ch 4))
                                  :grid-template-rows ((lh 1) (fr 1))
                                  (box :grid-row 1 "H")
                                  (column :id "area" :grid-row 2 :height stretch
                                          (column :id "fill" :height stretch
                                                  (box :id "grow" :height stretch "x")))))
    (should (equal (ebox-node-geometry (car (ebox-selector-query root "#area")))
                   '(:x 0 :y 1 :width 4 :height 5)))
    (should (equal (ebox-node-geometry (car (ebox-selector-query root "#fill")))
                   '(:x 0 :y 1 :width 4 :height 5)))
    (should (equal (ebox-node-geometry (car (ebox-selector-query root "#grow")))
                   '(:x 0 :y 1 :width 4 :height 5)))))

(ert-deftest ebox-render-visibility-hidden-preserves-layout-space ()
  (should (equal (ebox-test-render-text
                  '(column :width (ch 3)
                           (box :height (lh 1) "A")
                           (box :height (lh 1) :visibility hidden "B")
                           (box :height (lh 1) "C")))
                 "A 
 
C ")))

(ert-deftest ebox-node-constructors-build-detached-trees ()
  (let* ((text (ebox-text-create "OK" '(:color "#00aa00")))
         (root (ebox-node-create 'box '(:width (ch 3)) (list text)))
         (copy (ebox-node-copy root)))
    (should (eq (ebox-node-child root 0) text))
    (should (ebox-node-text-p text))
    (should (= (ebox-node-child-count root) 1))
    (should-not (eq copy root))
    (should (equal (ebox-test-render-text copy) "OK "))
    (ebox-node-set-text text "NO")
    (should (equal (ebox-test-render-text root) "NO "))
    (should (equal (ebox-test-render-text copy) "OK "))))

(ert-deftest ebox-build-rejects-invalid-author-forms ()
  (should-error (ebox-build '(unknown "x")) :type 'ebox-error)
  (should-error (ebox-build '(text :ecss (("&" :color "red")) "x"))
                :type 'ebox-error)
  (should-error (ebox-build '(box :height (px 1))) :type 'ebox-error)
  (should-error (ebox-node-create 'unknown) :type 'ebox-error))

;;; ebox-rendering-tests.el ends here
