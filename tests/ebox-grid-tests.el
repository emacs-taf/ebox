;;; ebox-grid-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)
(require 'seq)

(ert-deftest ebox-grid-zero-height-track-contributes-only-its-gap ()
  "A zero-height track adds no text line, while declared gaps remain real."
  (dolist (gap '(0 1 2))
    (dolist (rows '((0 1) (1 0)))
      (let* ((leading-zero-p (zerop (car rows)))
             (input
              (ebox-build
               `(grid :width (px 40) :grid-template-columns ((px 40))
                      :grid-template-rows ,(mapcar (lambda (n) (list 'lh n)) rows)
                      :row-gap (lh ,gap)
                 (text ,(if leading-zero-p "hidden" "visible"))
                 (text ,(if leading-zero-p "visible" "hidden")))))
             (rendered (ebox-render input))
             (lines (ebox-string-lines rendered)))
        (should (= (length lines) (1+ gap)))
        (should-not (string-match-p "hidden" rendered))
        (should (string-match-p "visible"
                                (nth (if leading-zero-p gap 0) lines)))
        (dolist (line (if leading-zero-p (butlast lines) (cdr lines)))
          (should (string-blank-p line)))))))

(ert-deftest ebox-grid-fixed-row-preserves-tracks-and-paint-through-updates ()
  "Fixed tracks preserve clipped cell geometry across retained changes."
  (let ((ebox-viewport-width 40)
        (ebox-viewport-height 20)
        (native-ready (ebox-native-reflow-layout-ready-p)))
    (dolist (configuration '((content-box 0) (border-box 0)
                             (content-box 1) (border-box 1)))
      (let ((sizing (car configuration))
            (border (cadr configuration)))
        (dolist (padding '(0 1))
          (dolist (wrap '(none word))
            (let ((cell-padding padding)
                  (columns '((ch 5) (ch 7)))
                  (cell-width 'stretch)
                  projection)
              (cl-labels
                  ((input
                     ()
                     (ebox-build
                      `(grid :id table :width (px 20) :column-gap (ch 1)
                             :grid-template-columns ,columns
                             (box :id cell :width ,cell-width :overflow hidden
                                  :border-width (px ,border) :border-color "red"
                                  :box-sizing ,sizing :padding-inline (ch ,cell-padding)
                                  :wrap-mode ,wrap :background-color "red" "Alphabet")
                             (box :width stretch :overflow hidden :box-sizing ,sizing
                                  :border-width (px ,border) :border-color "blue"
                                  :padding-inline (ch ,padding) :wrap-mode ,wrap
                                  :background-color "blue" "CharlieDelta"))))
                   (paint
                     (string)
                     (mapcar
                      (lambda (line)
                        (let (pixels)
                          (dotimes (index (length line))
                            (dotimes (_ (ebox-string-pixel-width
                                         (substring line index (1+ index))))
                              (push (list (aref line index)
                                          (get-text-property index 'face line)) pixels)))
                          (nreverse pixels)))
                      (split-string string "\n" nil)))
                   (check-render
                     ()
                     (should (equal (paint (buffer-string))
                                    (paint (ebox-render (input)))))))
                (with-temp-buffer
                  (ebox-render-to-buffer
                   (current-buffer) (input)
                   (list :observer
                         (lambda (_buffer report)
                           (when (eq (plist-get report :provider) 'ebox)
                             (setq projection (plist-get report :projection-kind))))))
                  (when native-ready (should (eq projection 'native-frame)))
                  (check-render)
                  (setq cell-padding 2)
                  (ebox-region-update "cell" :padding-inline '(ch 2))
                  (check-render)
                  (setq columns '((ch 7) (ch 5)))
                  (ebox-region-update "table" :grid-template-columns columns)
                  (check-render)
                  ;; A cell can leave the fixed-row accelerator's supported
                  ;; sizing subset without retaining its previous allocation.
                  (setq cell-width '(ch 3))
                  (ebox-region-update "cell" :width cell-width)
                  (check-render)
                  (setq cell-width 'stretch)
                  (ebox-region-update "cell" :width cell-width)
                  (check-render))))))))))

(provide 'ebox-grid-tests)
;;; ebox-grid-tests.el ends here
