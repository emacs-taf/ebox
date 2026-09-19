;;; ebox-flex-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defun ebox-flex-test--render (node)
  "Render NODE once for flex tests."
  (ebox-render node))

(defun ebox-flex-test--plain-lines (node)
  "Return rendered NODE as plain lines."
  (ebox-string-lines (substring-no-properties (ebox-flex-test--render node))))

(defun ebox-flex-test--region-property-width (string region-id property)
  "Return max PROPERTY span width for REGION-ID in STRING."
  (let ((pos 0)
        (len (length string))
        (max-width 0))
    (while (< pos len)
      (if (equal (get-text-property pos property string) region-id)
          (let ((end (or (next-single-property-change
                          pos property string len)
                         len)))
            (setq max-width
                  (max max-width
                       (string-pixel-width (substring string pos end))))
            (setq pos end))
        (setq pos (or (next-single-property-change
                       pos 'ebox-content string len)
                      len))))
    max-width))

(ert-deftest ebox-flex-module-preserves-item-participation ()
  "Extracted flex code should preserve item participation semantics."
  (let* ((node (ebox-build
                '(flex :width (px 240)
                  (box :flex-grow 1 :width (px 40) "Grow")
                  (box :width (px 40) "Fixed"))))
         (rendered (ebox-render node)))
    (should (string-match-p "Grow" rendered))
    (should (string-match-p "Fixed" rendered))))

(ert-deftest ebox-flex-row-wrap-measures-column-items-at-natural-width ()
  "Column flex items should not stretch to the full row before line breaking."
  (let* ((layout
          (ebox-build
           '(flex :flex-flow (row wrap) :column-gap (px 12) :width (px 800)
             (column
              (box :width (px 220) "one")
              (box :width (px 42) "A"))
             (column
              (box :width (px 220) "two")
              (box :width (px 42) "B"))
             (column
              (box :width (px 220) "three")
              (box :width (px 42) "C")))))
         (lines (ebox-flex-test--plain-lines layout)))
    (should (= (length lines) 2))
    (should (string-match-p "one.*two.*three" (car lines)))
    (should (string-match-p "A.*B.*C" (cadr lines)))))

(ert-deftest ebox-flex-rerenders-composite-item-for-assigned-viewport ()
  "Composite flex items should re-render internals for final item width."
  (let* ((layout
          (ebox-build
           '(flex :flex-flow (row wrap) :column-gap (px 12) :width (px 800)
             (column
              (box :id "title" :max-width (px 293)
                   :padding ((lh 0) (px 10)) :border "#5E7F6A"
                   :text-align center "wrap")
              (flex :id "body" :max-width (px 293) :padding ((lh 0) (px 8))
                    :border-right "#5E7F6A"
                    :border-bottom "#5E7F6A"
                    :border-left "#5E7F6A"
                    :flex-wrap wrap :column-gap (px 8)
                    (box :flex-shrink 0 :width (px 118) "A 118")
                    (box :flex-shrink 0 :width (px 118) "B 118")
                    (box :flex-shrink 0 :width (px 118) "C 118"))))))
         (buffer (generate-new-buffer " *ebox-flex-viewport*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (let* ((rendered (with-current-buffer buffer (buffer-string)))
                 (title-id (plist-get
                            (car (ebox-selector-query-buffer buffer "#title"))
                            :region-id))
                 (body-id (plist-get
                           (car (ebox-selector-query-buffer buffer "#body"))
                           :region-id))
                 (title-width (ebox-flex-test--region-property-width
                               rendered title-id 'ebox-bt))
                 (body-width (ebox-flex-test--region-property-width
                              rendered body-id 'ebox-bb)))
            (should (> title-width 200))
            (should (> body-width 200))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-natural-reuse-preserves-stretched-scroll-state ()
  "Stretch sizing should publish the final box geometry to scroll state."
  (let* ((ebox-viewport-width 120)
         (ebox-viewport-height 2)
         (layout
          (ebox-build
           '(flex :width (px 120)
              (box :id "root" :width (px 80) :height (vh 100)
                   :overflow scroll :flex-grow 1
                (column :width (px 80)
                  (box :height (lh 1) "A")
                  (box :height (lh 1) "B")
                  (box :height (lh 1) "C")
                  (box :height (lh 1) "D"))))))
         (buffer (generate-new-buffer " *ebox-flex-scroll-state*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer layout)
          (let* ((match (car (ebox-selector-query-buffer buffer "#root")))
                 (state (ebox-scroll-state (plist-get match :region-id))))
            (should (= (plist-get state :content-height) 2))
            (with-current-buffer buffer
              (should (= (length (ebox-string-lines (buffer-string))) 2))
              (goto-char (point-min))
              (ebox-scroll-down 1)
              (should (string-match-p "B" (buffer-string)))
              (should (string-match-p "C" (buffer-string)))
              (should-not (string-match-p "A" (buffer-string)))
              (ebox-rerender-buffer-with-context buffer 120 1)
              (should (= (length (ebox-string-lines (buffer-string))) 1))
              (should (string-match-p "B" (buffer-string))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-composed-lines-are-not-rewrapped-by-outer-box ()
  "Outer text wrapping preserves Flex item positions and child wrapping."
  (let ((ebox-viewport-width 160)
        (ebox-viewport-height 20))
    (dolist (wrap '(none word char))
      (with-temp-buffer
        (ebox-render-to-buffer
         (current-buffer)
         (ebox-build
          `(flex :width (px 8) :wrap-mode ,wrap
                 (box :id a :overflow visible :wrap-mode word "Alpha Bravo")
                 (box :id b :overflow visible :wrap-mode word "Charlie Delta"))))
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "AlphaCharlie\nBravoDelta "))
        (ebox-region-update "a" :content "Other Words")
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "OtherCharlie\nWordsDelta "))))))

(defun ebox-flex-test--progress-scene (width percent label background)
  "Build a dashboard with WIDTH, PERCENT, LABEL and enclosing BACKGROUND."
  (ebox-build
   `(flex :id frame :width (px ,width) :background-color ,background
          :column-gap (px 1.5) :align-items stretch :wrap-mode none
      (box :width (px 10.5) :flex-shrink 0 "Left")
      (column :flex-basis (px 30) :flex-shrink 0 :min-width (px 0)
              :padding ((lh 1) (px 1.5)) :overflow hidden
        (box :id label :width (% 100) :height (lh 1)
             :tab-index 0 ,label)
        (box :width (% 100) :height (lh 1) :background-color "gray"
          (box :id fill :width (% ,percent) :height (lh 1)
               :background-color "red")))
      (box :flex-grow 1 :min-width (px 0) "Right"))))

(defun ebox-flex-test--visible-runs (buffer)
  "Describe BUFFER's visible text, display geometry and colors."
  (with-current-buffer buffer
    (let ((text (buffer-string)) result)
      (dotimes (position (length text) (nreverse result))
        (push (list (aref text position)
                    (get-text-property position 'display text)
                    (get-text-property position 'face text))
              result)))))

(ert-deftest ebox-flex-progress-updates-preserve-fractional-sibling-geometry ()
  "Mixed text and dimension updates match full rendering in a stable Flex slot."
  (let ((ebox-viewport-width 81) (ebox-viewport-height 20)
        (live (generate-new-buffer " *ebox-progress-live*"))
        (reference (generate-new-buffer " *ebox-progress-reference*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer live
                                (ebox-flex-test--progress-scene 81 67 "67%" "blue"))
          (dolist (context '((81 "blue") (81 "green") (93 "green")
                            (93 "blue") (74 "blue")))
            (with-current-buffer live
              (ebox-call-with-update-batch
               (lambda ()
                 (ebox-region-update "frame" :width (list 'px (car context))
                                     :background-color (cadr context)))))
            (dolist (percent '(100 67 0 50 100 67))
              (let ((label (format "%d%%" percent)))
                (ebox-focus nil live)
                (ebox-focus-first live)
                (with-current-buffer live
                  (ebox-call-with-update-batch
                   (lambda ()
                     (ebox-region-update "label" :content label)
                     (ebox-region-update "fill" :width (list '% percent)))))
                (ebox-render-to-buffer
                 reference (ebox-flex-test--progress-scene
                            (car context) percent label (cadr context)))
                (should (equal (ebox-flex-test--visible-runs live)
                               (ebox-flex-test--visible-runs reference)))))))
      (dolist (buffer (list live reference))
        (when (buffer-live-p buffer)
          (when (ebox-surface-buffer-mounted-p buffer)
            (ebox-unmount-buffer buffer))
          (kill-buffer buffer))))))

(ert-deftest ebox-flex-rich-local-updates-preserve-paint-and-targets ()
  "Changed property runs preserve sibling paint and live interaction bounds."
  (let ((ebox-viewport-width 81) (ebox-viewport-height 20)
        (live (generate-new-buffer " *rich-progress-live*"))
        (reference (generate-new-buffer " *rich-progress-reference*"))
        (keys (make-sparse-keymap)) (calls 0) ref)
    (define-key keys (kbd "C-c") keys)
    (define-key keys (kbd "x") (lambda () (interactive) (cl-incf calls)))
    (unwind-protect
        (progn
          (ebox-render-to-buffer live (ebox-flex-test--progress-scene 81 67 "X" "blue"))
          (setq ref (ebox-focus-first live))
          (dolist (value '(100 0 67 100))
            (let ((label (propertize (format "X%d%%" value) 'keymap keys 'help-echo "Live label")))
              (put-text-property 0 (if (= value 100) 2 1) 'face '(:foreground "yellow") label)
              (with-current-buffer live
                (ebox-call-with-update-batch
                 (lambda ()
                   (ebox-region-update "label" :content label)
                   (ebox-region-update "fill" :width (list '% value)))))
              ;; A later parent paint update must use the merged ledger,
              ;; including caller paint underneath the changed role runs.
              (dolist (background '("green" "blue"))
                (with-current-buffer live (ebox-region-update "frame" :background-color background))
                (ebox-render-to-buffer reference
                                      (ebox-flex-test--progress-scene 81 value label background))
                (let ((expected-ref (ebox-focus-first reference)))
                  (should (equal (ebox-host-ref-bounds live ref)
                                 (ebox-host-ref-bounds reference expected-ref))))
                (should (equal (ebox-flex-test--visible-runs live)
                               (ebox-flex-test--visible-runs reference))))
              (with-current-buffer live
                (save-excursion
                  (goto-char (point-min)) (search-forward "X")
                  (let ((keymap (get-text-property (1- (point)) 'keymap)))
                    (should (equal (get-text-property (1- (point)) 'help-echo) "Live label"))
                    (call-interactively (lookup-key keymap (kbd "x"))))))))
          (should (= calls 4)))
      (dolist (buffer (list live reference))
        (when (buffer-live-p buffer)
          (when (ebox-surface-buffer-mounted-p buffer) (ebox-unmount-buffer buffer))
          (kill-buffer buffer))))))

(ert-deftest ebox-row-disjoint-rich-updates-preserve-line-dependencies ()
  "Two changed windows retain their middle sibling and whole-line paint."
  (let ((live (generate-new-buffer " *row-windows-live*"))
        (reference (generate-new-buffer " *row-windows-reference*"))
        (input (lambda (left right color)
                 (ebox-build
                  `(row :id frame :width (px 90) :height (lh 2) :wrap-mode none
                        :background-color ,color
                        (box :id left :key left :width (px 30) :height (lh 2) :tab-index 0 ,left)
                        (box :key middle :width (px 30) :height (lh 2) "KEEP")
                        (box :id right :key right :width (px 30) :height (lh 2) :tab-index 1 ,right)))))
        left-ref right-ref)
    (unwind-protect
        (progn
          (ebox-render-to-buffer live (funcall input "A\nBB" "C\nDD" "blue"))
          (setq left-ref (ebox-focus-first live) right-ref (ebox-focus-next 1 nil live))
          (dolist (pair '(("AA\nB" "CCC\nD") ("A\nBBB" "CC\nDD") ("AAA\nB" "C\nDDD")))
            (let ((left (propertize (car pair) 'face '(:foreground "yellow")))
                  (right (copy-sequence (cadr pair))))
              (put-text-property 0 1 'face '(:foreground "cyan") right)
              (with-current-buffer live
                (ebox-call-with-update-batch
                 (lambda () (ebox-region-update "left" :content left)
                            (ebox-region-update "right" :content right))))
              (with-current-buffer live (ebox-region-update "frame" :background-color "green"))
              (ebox-render-to-buffer reference (funcall input left right "green"))
              (let* ((expected-left (ebox-focus-first reference))
                     (expected-right (ebox-focus-next 1 nil reference)))
                (should (equal (ebox-host-ref-bounds live left-ref)
                               (ebox-host-ref-bounds reference expected-left)))
                (should (equal (ebox-host-ref-bounds live right-ref)
                               (ebox-host-ref-bounds reference expected-right))))
              (should (equal (ebox-flex-test--visible-runs live)
                             (ebox-flex-test--visible-runs reference))))))
      (dolist (buffer (list live reference))
        (when (buffer-live-p buffer)
          (when (ebox-surface-buffer-mounted-p buffer) (ebox-unmount-buffer buffer))
          (kill-buffer buffer))))))

(ert-deftest ebox-local-ownership-follows-reparented-targets ()
  "Local updates after reparenting use current paint and interaction bounds."
  (let ((live (generate-new-buffer " *ownership-live*"))
        (reference (generate-new-buffer " *ownership-reference*"))
        (scene
         (lambda (side label color)
           (ebox-build
            `(row :key root :width (px 96) :height (lh 2) :wrap-mode none
                  ,@(mapcar
                     (lambda (id)
                       `(box :key ,id :id ,id :width (px 48) :height (lh 2)
                             :background-color ,(if (eq id side) color "gray")
                             ,(if (eq id side)
                                  `(box :key target :id target :tab-index 0
                                        :width (% 100) :height (lh 1) ,label)
                                "Peer")))
                     '(left right)))))))
    (unwind-protect
        (progn
          (ebox-render-to-buffer live (funcall scene 'left "Seed" "blue"))
          (dolist (side '(left right left))
            (ebox-commit live (funcall scene side "Seed" "blue"))
            (let ((ref (ebox-focus-first live)))
              (dolist (text '("Short" "A longer label" "X"))
                (let ((label (propertize text 'face '(:foreground "yellow"))))
                  (with-current-buffer live
                    (ebox-region-update "target" :content label)
                    (ebox-region-update (symbol-name side) :background-color "green"))
                  (ebox-render-to-buffer reference (funcall scene side label "green"))
                  (should (equal (ebox-flex-test--visible-runs live)
                                 (ebox-flex-test--visible-runs reference)))
                  (should (equal (ebox-host-ref-bounds live ref)
                                 (ebox-host-ref-bounds
                                  reference (ebox-focus-first reference)))))))))
      (dolist (buffer (list live reference))
        (when (buffer-live-p buffer)
          (when (ebox-surface-buffer-mounted-p buffer) (ebox-unmount-buffer buffer))
          (kill-buffer buffer))))))

(provide 'ebox-flex-tests)
;;; ebox-flex-tests.el ends here
