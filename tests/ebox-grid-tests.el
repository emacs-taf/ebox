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

(provide 'ebox-grid-tests)
;;; ebox-grid-tests.el ends here
