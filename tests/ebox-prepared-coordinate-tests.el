;;; ebox-prepared-coordinate-tests.el --- Prepared coordinate authority -*- lexical-binding: t; -*-

;;; Commentary:
;; Source, public geometry and visible pixels remain paired across restyling.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-prepared-coordinate-test--input (values)
  "Build a positioned scroll pane using primitive VALUES."
  (ebox-build
   `(box :width (px 800) :height (lh 30) :overflow hidden
      (box :id "pane" :position absolute
           :left ,(aref values 0) :top ,(aref values 1)
           :width ,(aref values 2) :height ,(aref values 3)
           :z-index ,(aref values 4) :color ,(aref values 5)
           :border ,(aref values 6)
        (column (text "Title")
          (box :id "body" :height (lh 9) :overflow scroll
            "One\nTwo\nThree\nFour\nFive\nSix\nSeven\nEight\nNine\nTen\nEleven\nTwelve"))))))

(defun ebox-prepared-coordinate-test--appearance (text)
  "Return TEXT's public visible character, face and display facts."
  (list (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (list (get-text-property position 'face text)
                               (get-text-property position 'display text)))))

(defun ebox-prepared-coordinate-test--assert-current (values)
  "Check current geometry and exported source against fresh VALUES rendering."
  (let ((geometry (ebox-region-geometry "pane"))
        (expected (ebox-prepared-coordinate-test--appearance
                   (ebox-render (ebox-prepared-coordinate-test--input values)))))
    (cl-loop for property in '(:left :top :width :height :z-index)
             for index from 0
             do (should (equal (plist-get geometry property) (aref values index))))
    (should (equal expected (ebox-prepared-coordinate-test--appearance (buffer-string))))
    (should (equal expected
                   (ebox-prepared-coordinate-test--appearance
                    (ebox-render (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input)))))))

(ert-deftest ebox-prepared-coordinates-survive-paint-scroll-resize-and-retry ()
  "Restyling cannot detach geometry writes or accumulate stale movement deltas."
  (let ((ebox-viewport-width 800) (ebox-viewport-height 30))
    (with-temp-buffer
      (let* ((initial [(px 24) (lh 1) (px 480) (lh 12) 1 "#223344" ((px 1) solid "#445566")])
             (values (vector initial))
             (reject nil)
             operation)
        (ebox-render-to-buffer (current-buffer) (ebox-prepared-coordinate-test--input initial))
        (setq operation
              (ebox-update-prepare
               (current-buffer) [["pane" [:left :top :width :height :z-index :color :border]]]
               (lambda () (when reject (error "Reject coordinates"))) #'ignore))
        (should operation)
        (dolist (next '([(px 24) (lh 1) (px 480) (lh 12) 1 "#998877" ((px 1) solid "#776655")]
                        [(px 92) (lh 9) (px 480) (lh 12) 2 "#998877" ((px 1) solid "#776655")]
                        [(px 92) (lh 9) (px 468) (lh 13) 2 "#998877" ((px 1) solid "#776655")]
                        [(px 92) (lh 9) (px 468) (lh 13) 3 "#998877" ((px 1) solid "#776655")]
                        [(px 92) (lh 9) (px 468) (lh 13) 3 "#226688" ((px 1) solid "#337799")]
                        [(px 40) (lh 2) (px 496) (lh 11) 4 "#226688" ((px 1) solid "#337799")]))
          (aset values 0 next)
          (should (ebox-update-apply operation values [0]))
          (ebox-prepared-coordinate-test--assert-current next))
        (let ((before (buffer-string))
              (geometry (ebox-region-geometry "pane"))
              (revision (ebox-surface-buffer-revision (current-buffer))))
          (setq reject t)
          (aset values 0 [(px 128) (lh 5) (px 456) (lh 14) 5 "#772244" ((px 1) solid "#886633")])
          (should-error (ebox-update-apply operation values [0]))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal geometry (ebox-region-geometry "pane")))
          (should (equal-including-properties before (buffer-string))))
        (setq reject nil)
        (should (ebox-update-apply operation values [0]))
        (ebox-prepared-coordinate-test--assert-current (aref values 0))
        ;; Repeating exact accepted values must not translate a second time.
        (should (ebox-update-apply operation values [0]))
        (ebox-prepared-coordinate-test--assert-current (aref values 0))))))

(provide 'ebox-prepared-coordinate-tests)
;;; ebox-prepared-coordinate-tests.el ends here
