;;; ebox-scroll-tests.el --- Public nested scroll lifecycle -*- lexical-binding: t; -*-

;;; Commentary:
;; Retained nested scroll owners preserve independent state through publication.

;;; Code:
(require 'ert)
(require 'ebox)

(ert-deftest ebox-nested-scroll-preserves-independent-publication-and-cleanup ()
  "Nested owners scroll independently, roll back, clamp and retire cleanly."
  (let ((ebox-viewport-width 80)
        (ebox-viewport-height 20))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(column :width (px 8)
                 (box :id a :key a :width (px 8) :height (lh 1)
                      :overflow scroll "A1\nA2\nA3")
                 (box :id b :key b :width (px 8) :height (lh 1)
                      :overflow scroll "B1\nB2\nB3"))))
      (let ((a (plist-get (car (ebox-selector-query-buffer (current-buffer) "#a"))
                          :region-id))
            (b (plist-get (car (ebox-selector-query-buffer (current-buffer) "#b"))
                          :region-id)))
        (should (ebox-scroll-state a))
        (should (ebox-scroll-state b))
        (goto-char (point-min))
        (ebox-scroll-down 1)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "A2 \nB1 "))
        (goto-char (point-min))
        (search-forward "B1")
        (backward-char 2)
        (ebox-scroll-down 1)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "A2 \nB2 "))
        (let ((before (buffer-string)) (position (point)))
          (should-error
           (ebox-commit (current-buffer) (ebox-build '(text "Replacement"))
                        (lambda (_report) (error "Reject scroll owner removal"))))
          (should (equal-including-properties before (buffer-string)))
          (should (= position (point))))
        (goto-char (point-min))
        (ebox-scroll-up 1)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "A1 \nB2 "))
        (ebox-scroll-down 1)
        (ebox-region-update "a" :content "A0")
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "A0 \nB2 "))
        (should-not (ebox-scroll-state a))
        (should (ebox-scroll-state b))
        (ebox-unmount-buffer (current-buffer))
        (should-not (ebox-scroll-state a))
        (should-not (ebox-scroll-state b))))))

(provide 'ebox-scroll-tests)
;;; ebox-scroll-tests.el ends here
