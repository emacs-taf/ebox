;;; ebox-cascade-values-tests.el --- ECSS values through rendering -*- lexical-binding: t; -*-

;;; Commentary:
;; Final paint and layout consume computed values, including retained updates.

;;; Code:
(require 'ert)
(require 'ebox)
(require 'ecss)

(defun ebox-cascade-value-test--color (rendered)
  "Read the observable foreground of RENDERED text."
  (plist-get (get-text-property 0 'face rendered) :foreground))

(defun ebox-cascade-value-test--appearance (rendered)
  "Return RENDERED text and visible display/face properties."
  (cons (substring-no-properties rendered)
        (cl-loop for position below (length rendered)
                 collect (list (get-text-property position 'display rendered)
                               (get-text-property position 'face rendered)))))

(ert-deftest ebox-cascade-values-compute-inline-tags-before-paint ()
  "Inline special values never become raw Emacs face values."
  (dolist (entry (list (cons (ecss-important "#ff0000") "#ff0000")
                       (cons (ecss-wide-value 'inherit) "#00ff00")
                       (cons (ecss-var '--missing "#ff0000") "#ff0000")))
    (should (equal (cdr entry)
                   (ebox-cascade-value-test--color
                    (ebox-render
                     (ebox-build
                      (list 'box :color "#00ff00"
                            (list 'text :color (car entry) "Cascade"))))))))
  (should-error (ebox-build (list 'text :color (ecss-important 42) "Invalid"))))

(ert-deftest ebox-cascade-values-share-inline-and-rule-importance ()
  "Author important rules beat ordinary inline input; important inline wins ties."
  (let ((rules (list (list ".target" :color (ecss-important "#ff0000")))))
    (dolist (entry (list (cons "#00ff00" "#ff0000")
                         (cons (ecss-important "#0000ff") "#0000ff")))
      (should (equal (cdr entry)
                     (ebox-cascade-value-test--color
                      (ebox-render
                       (ebox-build
                        (list 'box :ecss rules
                              (list 'text :class "target" :color (car entry)
                                    "Cascade"))))))))))

(ert-deftest ebox-cascade-values-resolve-before-geometry ()
  "Tagged dimensions and shorthand importance reach layout only after computation."
  (dolist (entry (list (list :width '(ch 8) (ecss-important '(ch 8)))
                       (list :padding '((lh 1) (ch 2))
                             (ecss-important '((lh 1) (ch 2))))))
    (should (equal
             (ebox-cascade-value-test--appearance
              (ebox-render (ebox-build (list 'box (car entry) (cadr entry) "Box"))))
             (ebox-cascade-value-test--appearance
              (ebox-render (ebox-build (list 'box (car entry) (caddr entry) "Box")))))))
  (dolist (entry '((:flex-direction column) (:justify-content center) (:align-items center)))
    (should
     (equal
      (ebox-cascade-value-test--appearance
       (ebox-render (ebox-build (list 'flex :width '(ch 20) (car entry) (cadr entry)
                                      '(box "One") '(box "Two")))))
      (ebox-cascade-value-test--appearance
       (ebox-render (ebox-build (list 'flex :width '(ch 20) (car entry)
                                      (ecss-important (cadr entry))
                                      '(box "One") '(box "Two"))))))))
  (should (string-match-p
           "Box" (ebox-render
                  (ebox-build (list 'box :width (ecss-wide-value 'initial) "Box"))))))

(ert-deftest ebox-cascade-values-update-inherited-custom-properties ()
  "Retained variable consumers follow source updates and keep valid output on error."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      (list 'box :id "root" '--brand "#0000ff"
            (list 'text :id "label" :color (ecss-var '--brand) "Cascade"))))
    (should (equal "#0000ff" (ebox-cascade-value-test--color (buffer-string))))
    (ebox-region-update "root" '--brand "#ff0000")
    (should (equal "#ff0000" (ebox-cascade-value-test--color (buffer-string))))
    (ebox-region-update "label" :color (ecss-important "#00ff00"))
    (should (equal "#00ff00" (ebox-cascade-value-test--color (buffer-string))))
    (ebox-region-update "label" :color (ecss-var '--brand))
    (should (equal "#ff0000" (ebox-cascade-value-test--color (buffer-string))))
    (should-error (ebox-region-update "label" :color (ecss-important 42)))
    (should (equal "#ff0000" (ebox-cascade-value-test--color (buffer-string))))))

(ert-deftest ebox-cascade-values-update-inherited-geometry ()
  "A custom length update changes retained geometry exactly like fresh computation."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      (list 'box :id "root" '--span '(ch 8)
            (list 'box :id "item" :width (ecss-var '--span) "Box"))))
    (ebox-region-update "root" '--span '(ch 12))
    (let ((expected (ebox-render (ebox-build '(box (box :width (ch 12) "Box")))))
          (actual (buffer-string)))
      (should (equal (substring-no-properties expected)
                     (substring-no-properties actual)))
      (dotimes (position (length expected))
        (should (equal (get-text-property position 'display expected)
                       (get-text-property position 'display actual)))))
    (ebox-region-update "item" :width (ecss-important '(ch 16)))
    (let ((expected (ebox-render (ebox-build '(box (box :width (ch 16) "Box")))))
          (actual (buffer-string)))
      (should (equal (substring-no-properties expected)
                     (substring-no-properties actual)))
      (dotimes (position (length expected))
        (should (equal (get-text-property position 'display expected)
                       (get-text-property position 'display actual)))))))

(provide 'ebox-cascade-values-tests)
;;; ebox-cascade-values-tests.el ends here
