;;; ebox-focus-style-tests.el --- Focus through the shared cascade -*- lexical-binding: t; -*-

;;; Commentary:
;; Observe buffer-owned focus through selectors, layout and final paint.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-focus-style-test--input (&optional reverse disabled)
  "Build two styled controls; REVERSE reorders them and DISABLED disables a."
  (ebox-build
   (append
    '(column :ecss (("box" :color "#111111" :width (ch 5))
                   ("box:focus" :color "#ff0000" :width (ch 9))))
    (let ((nodes (list (list 'box :id 'a :key 'a :tab-index 0
                             :disabled disabled "Alpha")
                       '(box :id b :key b :tab-index 1 "Bravo"))))
      (if reverse (reverse nodes) nodes)))))

(defun ebox-focus-style-test--color (text word)
  "Return WORD's rendered foreground in TEXT."
  (plist-get (get-text-property (string-match word text) 'face text) :foreground))

(ert-deftest ebox-focus-retains-local-facts-and-structural-inheritance ()
  "Repeated focus and content updates preserve scoped and relational rules."
  (dolist (structural '(nil t))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             (current-buffer)
             (ebox-build
              `(column :width (ch 40) :color "#112233"
                       :ecss ,(if structural
                                  '(("#a:focus > text" :color "#cc0000")
                                    ("#a:focus + #b" :color "#0000cc"))
                                '(("#a:focus" :color "#cc0000")))
                 (box :id a :tab-index 0 (text :id label "Alpha"))
                 (box :id b :tab-index 1 "Bravo"))))
            (dotimes (_ 3)
              (ebox-focus-first)
              (should (= 1 (length (ebox-selector-query-buffer
                                   (current-buffer) "#a:focus > #label"))))
              (should (equal "#cc0000"
                             (ebox-focus-style-test--color (buffer-string) "Alpha")))
              (should (equal (if structural "#0000cc" "#112233")
                             (ebox-focus-style-test--color (buffer-string) "Bravo")))
              (ebox-focus-next)
              (should-not (ebox-selector-query-buffer (current-buffer) "#a:focus"))
              (should (equal "#112233"
                             (ebox-focus-style-test--color (buffer-string) "Alpha")))
              (ebox-region-update "label" :content "Alpha updated")
              (should (ebox-selector-query-buffer (current-buffer) "#b:focus"))
              (should (equal "#112233"
                             (ebox-focus-style-test--color (buffer-string) "Alpha")))))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-focus-metadata-retains-scroll-content-and-later-style-updates ()
  "A visually unchanged focus still drives selectors and future style changes."
  (cl-labels
      ((input (focused-color)
         (ebox-build
          `(column :width (ch 40) :height (lh 12) :overflow scroll
                    :ecss (("#a" :color "#112233")
                           ("#a:focus" :color ,focused-color))
             (box :id a :key a :tab-index 0 "Alpha")
             (box :id b :key b :tab-index 0 "Bravo")))))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (input "#112233"))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (ebox-focus-first)
              (should (ebox-selector-query-buffer (current-buffer) "#a:focus"))
              (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
              (ebox-commit (current-buffer) (input "#ff0000"))
              (should (ebox-selector-query-buffer (current-buffer) "#a:focus"))
              (should (equal "#ff0000" (ebox-focus-style-test--color (buffer-string) "Alpha")))
              (ebox-region-update "b" :content "Updated")
              (should (string-match-p "Updated" (buffer-string)))
              (ebox-focus-next)
              (should (ebox-selector-query-buffer (current-buffer) "#b:focus"))
              (should (equal "#112233" (ebox-focus-style-test--color (buffer-string) "Alpha")))))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-focus-state-shares-selectors-paint-and-layout ()
  "Setting and clearing focus recompute shared rules and preserve manual point."
  (dolist (viewport '((nil nil) (160 20)))
    (let ((ebox-viewport-width (car viewport))
          (ebox-viewport-height (cadr viewport)))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) (ebox-focus-style-test--input))
        (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
          (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
          (ebox-focus-first)
          (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#a:focus"))))
          (should (equal "#ff0000" (ebox-focus-style-test--color (buffer-string) "Alpha")))
          (should (> (buffer-size) (length plain)))
          (should (looking-at "Alpha"))
          (ebox-focus-next)
          (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#b:focus"))))
          (should (equal "#111111" (ebox-focus-style-test--color (buffer-string) "Alpha")))
          (should (equal "#ff0000" (ebox-focus-style-test--color (buffer-string) "Bravo")))
          (goto-char (point-min))
          (let ((position (point)))
            (ebox-focus nil)
            (should (= position (point))))
          (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
          (should (equal plain (buffer-substring-no-properties (point-min) (point-max)))))))))

(ert-deftest ebox-focus-state-isolates-shared-input-mounts-and-pure-render ()
  "One canonical input supplies independent mounted states and stateless pure output."
  (let ((input (ebox-focus-style-test--input))
        (first (generate-new-buffer " *focus-style-first*"))
        (second (generate-new-buffer " *focus-style-second*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer first input)
          (ebox-render-to-buffer second input)
          (ebox-focus-first first)
          (should (= 1 (length (ebox-selector-query-buffer first "#a:focus"))))
          (should-not (ebox-selector-query-buffer second ":focus"))
          (should-not (ebox-selector-query-all input ":focus"))
          (with-current-buffer first
            (should (equal "#111111"
                           (ebox-focus-style-test--color (ebox-render input) "Alpha"))))
          (ebox-focus-next 2 nil second)
          (should (= 1 (length (ebox-selector-query-buffer second "#b:focus"))))
          (should (= 1 (length (ebox-selector-query-buffer first "#a:focus"))))
          (ebox-unmount-buffer first)
          (should-not (ebox-focused-host-ref first))
          (should (= 1 (length (ebox-selector-query-buffer second "#b:focus")))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest ebox-focus-state-follows-reorder-and-rejected-publication ()
  "Retained focus styles follow keyed reorder, roll back and clear on disable."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-focus-style-test--input))
    (ebox-focus-first)
    (ebox-commit (current-buffer) (ebox-focus-style-test--input t))
    (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#a:focus"))))
    (should (looking-at "Alpha"))
    (let ((before (buffer-string)) (position (point)))
      (should-error
       (ebox-commit (current-buffer) (ebox-focus-style-test--input nil t)
                    (lambda (_report) (error "Reject disabled focus"))))
      (should (equal-including-properties before (buffer-string)))
      (should (= position (point)))
      (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#a:focus")))))
    (ebox-commit (current-buffer) (ebox-focus-style-test--input nil t))
    (should-not (ebox-focused-host-ref))
    (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
    (should (equal "#111111" (ebox-focus-style-test--color (buffer-string) "Alpha")))))

(ert-deftest ebox-focus-state-follows-region-updates ()
  "Local content, disabling and hiding updates keep focus facts and paint aligned."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-focus-style-test--input))
    (ebox-focus-first)
    (ebox-region-update "a" :content "Other")
    (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#a:focus"))))
    (should (equal "#ff0000" (ebox-focus-style-test--color (buffer-string) "Other")))
    (ebox-region-update "a" :disabled t)
    (should-not (ebox-focused-host-ref))
    (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
    (should (equal "#111111" (ebox-focus-style-test--color (buffer-string) "Other")))
    (ebox-region-update "a" :disabled nil)
    (ebox-focus-first)
    (ebox-region-update "a" :visibility 'hidden)
    (should-not (ebox-focused-host-ref))
    (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))))

(ert-deftest ebox-focus-state-rejects-inaccessible-styled-target ()
  "A focus rule that removes the target rejects selection and restores the view."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(column :ecss (("box:focus" :visibility hidden))
                          (box :id a :key a :tab-index 0 "Alpha"))))
    (let ((before (buffer-string)) (position (point)))
      (should-error (ebox-focus-first) :type 'user-error)
      (should-not (ebox-focused-host-ref))
      (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
      (should (equal-including-properties before (buffer-string)))
      (should (= position (point))))))

(ert-deftest ebox-focus-state-clears-when-cascade-hides-retained-target ()
  "A committed hiding rule clears retained focus and removes its selector state."
  (cl-labels ((input (hidden)
               (ebox-build
                (list 'column :ecss
                      '(("box:focus" :color "#ff0000")
                        (".concealed" :visibility hidden))
                      (list 'box :id 'a :key 'a :tab-index 0
                            :class (and hidden 'concealed) "Alpha")
                      '(box :id b :key b :tab-index 1 "Bravo")))))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (input nil))
      (ebox-focus-first)
      (ebox-commit (current-buffer) (input t))
      (should-not (ebox-focused-host-ref))
      (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
      (ebox-focus-first)
      (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#b:focus")))))))

(ert-deftest ebox-focus-state-clears-when-layout-clips-retained-target ()
  "A layout update that clips the focused row removes both focus and its state."
  (cl-labels ((input (height)
               (ebox-build
                (list 'column :height (list 'lh height) :overflow 'hidden
                      :ecss '(("text:focus" :color "#ff0000"))
                      '(text :key a :id a :tab-index 0 "Alpha")
                      '(text :key b :id b :tab-index 1 "Bravo")))))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (input 2))
      (ebox-focus-next 2)
      (let ((before (buffer-string)) (position (point)))
        (should-error (ebox-commit (current-buffer) (input 1)
                                  (lambda (_report) (error "Reject clipped candidate"))))
        (should (equal-including-properties before (buffer-string)))
        (should (= position (point)))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#b:focus")))))
      (ebox-commit (current-buffer) (input 1))
      (should-not (ebox-focused-host-ref))
      (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
      (ebox-focus-first)
      (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#a:focus")))))))

(ert-deftest ebox-focus-state-rejects-authored-focus-tokens ()
  "Author input cannot supply the state owned by mounted logical focus."
  (dolist (states '(focus "focus" (checked focus)))
    (should-error (ebox-build (list 'box :states states "Invalid")))
    (should-error (ebox-source-builder-bind (ebox-source-builder-create)
                                            :selector-state states))))

(ert-deftest ebox-focus-state-observer-commit-uses-accepted-generation ()
  "An observer's new keyed commit preserves focus without replaying its old request."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-focus-style-test--input))
    (let (handled accepted)
      (ebox-buffer-set-observer
       (current-buffer)
       (lambda (buffer _report)
         (unless handled
           (setq handled t)
           (ebox-buffer-set-observer buffer nil)
           (ebox-commit buffer (ebox-build '(column :ecss (("box:focus" :color "#ff0000"))
                                                   (box :id a :key a :tab-index 0 "After"))))
           (setq accepted t))))
      (ebox-focus-first)
      (should accepted)
      (should (string-match-p "After" (buffer-string)))
      (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#a:focus"))))
      (should (looking-at "After")))))

(ert-deftest ebox-focus-state-clears-when-scrolling-hides-target ()
  "Scrolling a focused row out of view clears its style state before acceptance."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(column :height (lh 2) :overflow scroll
                          :ecss (("text:focus" :color "#ff0000"))
                          (text :key a :id a :tab-index 0 "Alpha")
                          (text :key b :id b :tab-index 1 "Bravo")
                          (text :key c :id c :tab-index 2 "Third"))))
    (ebox-focus-first)
    (ebox-scroll-down 1)
    (should-not (ebox-focused-host-ref))
    (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
    (should (string-match-p "Third" (buffer-string)))
    (ebox-focus-first)
    (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#b:focus"))))))

(ert-deftest ebox-focus-state-clears-invisible-target-during-sibling-update ()
  "An unrelated local update clears inaccessible focus and restores its base paint."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-focus-style-test--input))
    (let* ((ref (ebox-focus-first))
           (bounds (ebox-host-ref-bounds (current-buffer) ref))
           (overlay (make-overlay (car bounds) (cdr bounds))))
      (unwind-protect
          (progn
            (overlay-put overlay 'invisible t)
            (ebox-region-update "b" :content "Other")
            (should-not (ebox-focused-host-ref))
            (should-not (ebox-selector-query-buffer (current-buffer) ":focus")))
        (delete-overlay overlay))
      (should (equal "#111111" (ebox-focus-style-test--color (buffer-string) "Alpha"))))))

(ert-deftest ebox-focus-state-only-observation-keeps-independent-inputs ()
  "State-only updates preserve shared inputs and report exclusive stage times."
  (let ((input (ebox-build '(column :color "#334155"
                                    (box :id a :tab-index 0 "Alpha")
                                    (box :id b :tab-index 0 "Bravo"))))
        (first (generate-new-buffer " *focus-observed-first*"))
        (second (generate-new-buffer " *focus-observed-second*")) reports)
    (unwind-protect
        (progn
          (ebox-render-to-buffer first input)
          (ebox-render-to-buffer second input)
          (ebox-buffer-set-observer first
                                   (lambda (_buffer report)
                                     (when (eq (plist-get report :provider) 'ebox) (push report reports))))
          (dotimes (_ 4)
            (ebox-focus-first first)
            (should (= 1 (length (ebox-selector-query-buffer first "#a:focus"))))
            (ebox-focus-next 1 nil first)
            (should (= 1 (length (ebox-selector-query-buffer first "#b:focus"))))
            (should-not (ebox-selector-query-buffer second ":focus"))
            (should-not (ebox-selector-query-all input ":focus")))
          (should reports)
          (dolist (report reports)
            (let ((phases (plist-get report :phase-duration-ms)) (sum 0))
              (dolist (phase '(source style plan layout projection transaction))
                (should (numberp (plist-get phases phase)))
                (should (>= (plist-get phases phase) 0))
                (setq sum (+ sum (plist-get phases phase))))
              (should (< (abs (- sum (plist-get report :duration-ms))) .001)))))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (when (ebox-surface-buffer-mounted-p buffer) (ebox-unmount-buffer buffer))
          (kill-buffer buffer))))))

(provide 'ebox-focus-style-tests)
;;; ebox-focus-style-tests.el ends here
