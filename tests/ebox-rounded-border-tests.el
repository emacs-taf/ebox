;;; -*- lexical-binding: t; -*-
;;; ebox-rounded-border-tests.el --- Rounded frame public behaviour

(require 'ebox-test-support)

(ert-deftest ebox-rounded-frame-preserves-content-geometry-and-activation ()
  "Rounding is paint only; native labels and keyboard targets stay live."
  (let ((presses 0))
    (ebox-test-with-mounted
        (buffer root
                (list 'column :background-color "#eef2f7"
                      (list 'box :id "control" :width '(ch 24)
                            :padding '((lh 1) (ch 2)) :tab-index 0
                            :background-color "#ffffff"
                            :border '((px 1) solid "#8798ae")
                            :keymap (ebox-keymap-create
                                     :activate (lambda () (cl-incf presses)))
                            '(text :id "label" "Apply 60.183"))))
      (let* ((control (car (ebox-selector-query root "#control")))
             (label (car (ebox-selector-query root "#label")))
             (geometry (ebox-node-geometry control)))
        (ebox-focus control buffer)
        (dolist (radius '(8 16 100 0 7))
          (ebox-node-put control :border-radius (list 'px radius))
          (let ((current (ebox-node-geometry control))
                (focused (eq control (ebox-focused-node buffer))))
            (should (equal current geometry))
            (should focused))
          (should (string-match-p "Apply 60\\.183" (ebox-test-buffer-text buffer)))
          (ebox-activate)
          (ebox-activate (ebox-node-position label)))
        (should (= presses 10))
        (ebox-node-set-text label "Applied 59.125")
        (should (string-match-p "Applied 59\\.125" (ebox-test-buffer-text buffer)))
        (let ((snapshot (ebox-test-buffer-text buffer)))
          (ebox-unmount-buffer buffer)
          (should-not (ebox-buffer-root buffer))
          (ebox-node-set-text label "Detached")
          (should (equal snapshot (ebox-test-buffer-text buffer))))))))

(ert-deftest ebox-rounded-frame-never-removes-corner-glyphs ()
  "A corner cutting through native ink falls back without clipping text."
  (dolist (label '("W" "界" "60.183"))
    (ebox-test-with-mounted
        (buffer root
                (list 'box :width '(ch 24) :height '(lh 1)
                      :background-color "#ffffff"
                      :border '((px 1) solid "#8798ae") label))
      (let ((original (ebox-test-buffer-text buffer)))
        (dolist (radius '(2 7 16 100))
          (ebox-node-put root :border-radius (list 'px radius))
          (should (equal original (ebox-test-buffer-text buffer))))))))

(ert-deftest ebox-rounded-frame-keeps-nonuniform-borders-and-header-content ()
  "A header band and nonuniform border fallback keep the same geometry."
  (ebox-test-with-mounted
      (buffer root
              '(column :width (ch 30) :background-color "#ffffff"
                       :border-top ((px 1) solid "#8798ae")
                       :border-right ((px 1) solid "#8798ae")
                       :border-bottom ((px 1) solid "#8798ae")
                       :border-left ((px 1) solid "#8798ae")
                       (box :background-color "#eaf0f7"
                            :padding ((lh 1) (ch 2)) "Clip inspector")
                       (box :padding ((lh 1) (ch 2)) "60.183 seconds")))
    (let ((geometry (ebox-node-geometry root)))
      (ebox-node-put root :border-radius '(px 16))
      (dolist (border '(((px 1) solid "#8798ae")
                        ((px 3) solid "#8798ae")
                        ((px 1) solid "#cc3344")))
        (ebox-node-put root :border-left border)
        (let ((current (ebox-node-geometry root)))
          (should (equal current geometry)))
        (should (string-match-p "Clip inspector" (ebox-test-buffer-text buffer)))
        (should (string-match-p "60\\.183 seconds" (ebox-test-buffer-text buffer)))))))

(ert-deftest ebox-rounded-frame-paints-only-its-outer-horizontal-edges ()
  "Top and bottom decoration must not leak into shared blank row cells."
  (ebox-test-with-mounted
      (buffer _root
              '(box :width (ch 24) :padding ((lh 1) (ch 2))
                    :background-color "#f8fafc"
                    :border ((px 1) solid "#b7c4d5")
                    :border-radius (px 7) "60.183"))
    (let (edges)
      (goto-char (point-min))
      (dotimes (_ 3)
        (let ((start (line-beginning-position)) (end (line-end-position)))
          (push (mapcar
                 (lambda (attribute)
                   (and (cl-loop for position from start below end
                                 thereis (memq attribute
                                               (flatten-tree
                                                (get-text-property position 'face))))
                        t))
                 '(:overline :underline))
                edges))
        (forward-line 1))
      (should (equal (nreverse edges) '((t nil) (nil nil) (nil t)))))))

;;; ebox-rounded-border-tests.el ends here
