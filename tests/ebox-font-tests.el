;;; ebox-font-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(ert-deftest ebox-measure-display-replacements-own-one-run ()
  "A display replacement is one unit even across face and metadata changes."
  (dolist (display (list '(space :width (15)) "X"))
    (let ((text (propertize "abc" 'display display)))
      (should (= (ebox-string-pixel-width text) (string-pixel-width text)))
      (put-text-property 1 2 'face 'bold text)
      (put-text-property 2 3 'help-echo "last" text)
      (should (= (ebox-string-pixel-width text) (string-pixel-width text)))
      (should (= (ebox-string-pixel-width (concat text "Z"))
                 (string-pixel-width (concat text "Z")))))))

(ert-deftest ebox-measure-distinguishes-adjacent-display-identities ()
  "Equal but distinct display values are two replacements, including cache hits."
  (let* ((one (propertize "ab" 'display (list 'space :width (list 15))))
         (two (concat (propertize "a" 'display (list 'space :width (list 15)))
                      (propertize "b" 'display (list 'space :width (list 15))))))
    (dotimes (_ 2)
      (should (= (ebox-string-pixel-width one) 15))
      (should (= (ebox-string-pixel-width two) 30)))))

(provide 'ebox-font-tests)
;;; ebox-font-tests.el ends here
