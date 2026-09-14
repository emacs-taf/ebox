;;; ebox-scroll-tests.el --- Public nested scroll lifecycle -*- lexical-binding: t; -*-

;;; Commentary:
;; Retained nested scroll owners preserve independent state through publication.

;;; Code:
(require 'ert)
(require 'ebox)

(ert-deftest ebox-scroll-containers-compose-through-layout-and-updates ()
  "Nested and sibling scroll containers keep independent visible content."
  (let ((ebox-viewport-width 80)
        (ebox-viewport-height 20))
    (dolist (layout '(column flex))
      (with-temp-buffer
        (let (projection)
          (ebox-render-to-buffer
           (current-buffer)
           (ebox-build
            `(,layout :width (px 12)
                      ,@(when (eq layout 'flex) '(:flex-direction column))
                      (column :id outer :height (lh 2) :overflow scroll
                              (box :id a :width (px 8) :height (lh 1)
                                   :overflow scroll "A1\nA2\nA3")
                              "Tail1" "Tail2")
                      (box :id b :width (px 8) :height (lh 1)
                           :overflow scroll "B1\nB2\nB3")))
           (list :observer
                 (lambda (_buffer report)
                   (when (eq (plist-get report :provider) 'ebox)
                     (setq projection (plist-get report :projection-kind))))))
          (when (ebox-native-reflow-layout-ready-p)
            (should (eq projection 'native-frame))))
        (dolist (id '("outer" "a" "b"))
          (should (ebox-scroll-state
                   (plist-get (car (ebox-selector-query-buffer
                                    (current-buffer) (concat "#" id)))
                              :region-id))))
        (goto-char (point-min))
        (ebox-scroll-down 1)
        (should (string-match-p "A2" (buffer-string)))
        (goto-char (point-min))
        (search-forward "B1")
        (backward-char 2)
        (ebox-scroll-down 1)
        (should (string-match-p "A2" (buffer-string)))
        (should (string-match-p "B2" (buffer-string)))
        (goto-char (point-min))
        (search-forward "Tail1")
        (backward-char 5)
        (ebox-scroll-down 1)
        (should (string-match-p "Tail2" (buffer-string)))
        (should-not (string-match-p "A2" (buffer-string)))
        (should (string-match-p "B2" (buffer-string)))
        (goto-char (point-min))
        (ebox-scroll-up 1)
        (should (string-match-p "A2" (buffer-string)))
        (ebox-region-update "a" :content "A0")
        (should (string-match-p "A0" (buffer-string)))
        (should (string-match-p "B2" (buffer-string)))
        (ebox-rerender-buffer-with-context (current-buffer) 40 12)
        (should (string-match-p "A0" (buffer-string)))
        (should (string-match-p "B2" (buffer-string)))
        (ebox-region-update "b" :content "B0")
        (should (string-match-p "B0" (buffer-string)))))))

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
