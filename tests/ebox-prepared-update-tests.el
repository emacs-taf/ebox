;;; ebox-prepared-update-tests.el --- Mixed primitive publication contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Validate sparse mixed source publication through the public retained API.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-prepared-update-test--input ()
  "Build a fixed canvas with a positioned mixed-update target."
  (ebox-build
   '(box :width (ch 30) :height (lh 5)
      (box :id "panel" :position absolute :left (ch 0) :top (lh 1)
           :width (ch 12) :height (lh 2) :z-index 1
           :color "#224466" :hover-content "Hover01"
        (text :id "label" "Value00")))))

(defun ebox-prepared-update-test--assert-fresh ()
  "Compare current visible primitive output with the exported canonical input."
  (let ((actual (buffer-string))
        (expected (ebox-render (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))))
    (should (equal (substring-no-properties actual) (substring-no-properties expected)))
    (dotimes (position (length actual))
      (dolist (property '(display face font-lock-face help-echo keymap pointer mouse-face))
        (should (equal (get-text-property position property actual)
                       (get-text-property position property expected)))))))

(ert-deftest ebox-prepared-update-publishes-mixed-members-once ()
  "Geometry, inherited paint, native hover and Text advance one accepted revision."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-update-test--input))
      (let* ((staged 0) (accepted 0)
             (operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:left :top :z-index]]
                                 ["panel" [:color :hover-content]]
                                 ["label" [:content]]]
               (lambda () (setq staged (1+ staged)))
               (lambda () (setq staged (1- staged)))
               (lambda () (setq accepted (1+ accepted)))))
             (values [[(ch 4) (lh 2) 3] ["#884422" "Hover02"] ["Value01"]])
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should (ebox-update-valid-p operation))
        (should (ebox-update-apply operation values [0 1 2]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (should (= staged 1)) (should (= accepted 1))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [(ch 8) (lh 1) 4])
        (should (ebox-update-apply operation values [0]))
        (ebox-prepared-update-test--assert-fresh)
        (should (= staged 2)) (should (= accepted 2))
        ;; A later sparse geometry member must retain the accepted hover
        ;; source and its prebound native capability from the earlier batch.
        (save-window-excursion
          (set-window-buffer (selected-window) (current-buffer))
          (goto-char (point-min))
          (search-forward "Value01")
          (funcall (lookup-key ebox-buffer-mode-map [mouse-movement])
                   (list 'mouse-movement (list (selected-window) (- (point) 7) '(1 . 1) 0)))
          (should (string-match-p "Hover02" (buffer-string))))))))

(ert-deftest ebox-prepared-update-rolls-back-all-members-and-retries ()
  "A rejected paired stage restores pixels, source, revision and every member."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-update-test--input))
      (let* ((reject t) (caller 'before) (caller-count 0)
             (operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:left :color]] ["label" [:content]]]
               (lambda () (setq caller 'after caller-count (1+ caller-count))
                 (when reject (error "Reject mixed update")))
               (lambda () (setq caller 'before caller-count (1- caller-count)))))
             (values [[(ch 5) "#885522"] ["Value02"]])
             (before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should-error (ebox-update-apply operation values [0 1]))
        (should (eq caller 'before))
        (should (= caller-count 0))
        (should (equal-including-properties before (buffer-string)))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (ebox-prepared-update-test--assert-fresh)
        (setq reject nil)
        (should (ebox-update-apply operation values [0 1]))
        (should (eq caller 'after))
        (should (= caller-count 1))
        (ebox-prepared-update-test--assert-fresh)
        ;; An absolute panel does not participate in flow, so content that
        ;; changes its wrapped rows replaces the panel's retained pixels.
        (aset values 1 ["A longer replacement"])
        (setq revision (ebox-surface-buffer-revision (current-buffer)))
        (should (ebox-update-apply operation values [1]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-translates-without-repainting-repeated-paint ()
  "Members whose raster values repeat only translate; a changed one repaints."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-update-test--input))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:left :top :z-index :color]] ["label" [:content]]]
               #'ignore #'ignore))
             (values [[(ch 4) (lh 2) 3 "#224466"] ["Value00"]])
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should (ebox-update-apply operation values [0 1]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (should (equal '(geometry) (plist-get (ebox-buffer-update-report (current-buffer)) :dirty-kinds)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [(ch 6) (lh 1) 4 "#884422"])
        (should (ebox-update-apply operation values [0]))
        (let ((kinds (plist-get (ebox-buffer-update-report (current-buffer)) :dirty-kinds)))
          (should (memq 'paint kinds)) (should (memq 'span kinds)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 1 ["Value01"])
        (should (ebox-update-apply operation values [1]))
        (should (equal '(span) (plist-get (ebox-buffer-update-report (current-buffer)) :dirty-kinds)))
        (should (string-match-p "Value01" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        ;; Repeating the displayed values after a repaint stays fresh too.
        (should (ebox-update-apply operation values [0 1]))
        (should (equal '(geometry) (plist-get (ebox-buffer-update-report (current-buffer)) :dirty-kinds)))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-hides-and-shows-positioned-panel ()
  "A prepared visibility member removes and restores a panel's footprint."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 30) :height (lh 5)
           (text "Desk")
           (box :id "panel" :position absolute :left (ch 2) :top (lh 1)
                :width (ch 12) :height (lh 2) :z-index 1 :visibility visible
                :color "#224466"
             (text :id "label" "Value00")))))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:visibility :left]]]
               #'ignore #'ignore))
             (values [[hidden (ch 2)]])
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (should-not (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [visible (ch 6)])
        (should (ebox-update-apply operation values [0]))
        (should (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-toggles-visibility-over-deep-subtree ()
  "Hiding and showing a Host with a deep subtree keeps every descendant fresh.
Visibility is a paint boundary of the changed Host rather than an inherited
value, so descendants keep their computed styles; an inherited paint change
on the same Host still reaches descendants that inherit it while explicit
overrides stay untouched."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 40) :height (lh 8)
           (text "Desk")
           (box :id "panel" :position absolute :left (ch 2) :top (lh 1)
                :width (ch 30) :height (lh 5) :z-index 1 :visibility visible
                :color "#224466" :font-weight normal
             (column
              (row (text "Head") (text :color "#AA2222" "Own"))
              (column (row (text "Body01")) (row (text "Body02")))
              (row (text :font-weight bold "Foot")))))))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:visibility :color :font-weight]]]
               #'ignore #'ignore))
             (values [[hidden "#224466" normal]])
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (should-not (string-match-p "Body02" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [visible "#224466" normal])
        (should (ebox-update-apply operation values [0]))
        (should (string-match-p "Body02" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [visible "#116633" bold])
        (should (ebox-update-apply operation values [0]))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [hidden "#116633" bold])
        (should (ebox-update-apply operation values [0]))
        (aset values 0 [visible "#224466" normal])
        (should (ebox-update-apply operation values [0]))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-shows-initially-hidden-positioned-panel ()
  "A panel mounted hidden stays addressable: prepared moves park it and a
prepared visibility change paints it at its current placement."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 30) :height (lh 5)
           (text "Desk")
           (box :id "panel" :position absolute :left (ch 2) :top (lh 1)
                :width (ch 12) :height (lh 2) :z-index 1 :visibility hidden
                :color "#224466"
             (text :id "label" "Value00")))))
      (should-not (string-match-p "Value00" (buffer-string)))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:visibility :left :top]]]
               #'ignore #'ignore))
             (values [[hidden (ch 4) (lh 2)]]))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (should-not (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [visible (ch 4) (lh 2)])
        (should (ebox-update-apply operation values [0]))
        (should (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [hidden (ch 4) (lh 2)])
        (should (ebox-update-apply operation values [0]))
        (should-not (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-fits-variable-text-in-fixed-flex-allocation ()
  "A fixed status allocation accepts variable text and preserves adjacent controls."
  (let ((ebox-viewport-width 320) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(column :width (ch 40) :height (lh 6)
           (flex :width (ch 40) :height (lh 1) :flex-direction row :flex-wrap nowrap
             (box :flex-shrink 0 :min-width max-content "Left")
             (box :id "status-slot" :flex-grow 1 :flex-basis (px 0) :min-width (px 0)
                  :height (lh 1) :wrap-mode none :overflow hidden
               (text :id "status" "Ready"))
             (box :id "controls" :flex-shrink 0 :min-width max-content "Controls"))
           (box :id "panel" :position absolute :left (ch 0) :top (lh 3)
                :width (ch 8) :height (lh 1) :z-index 1 "Panel"))))
      (let* ((reject nil)
             (operation
              (ebox-update-prepare
               (current-buffer) [["status" [:content]]]
               (lambda () (when reject (error "Reject status"))) #'ignore))
             (values [["Window one"]]))
        (should operation)
        (dolist (text '("Window one" "Window three" "A very long status title that clips before Controls" "Ready"))
          (aset values 0 (vector text))
          (should (ebox-update-apply operation values [0]))
          (should (string-match-p "Controls" (buffer-string)))
          (ebox-prepared-update-test--assert-fresh))
        (let ((before (buffer-string)) (revision (ebox-surface-buffer-revision (current-buffer))))
          (setq reject t)
          (aset values 0 ["Rejected status"])
          (should-error (ebox-update-apply operation values [0]))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string))))))))

(ert-deftest ebox-prepared-update-declines-unproved-variable-text-allocation ()
  "Empty, initially clipped and full slots reject unproved width changes atomically."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 8))
    (dolist (initial '("" "1234567890123456" "12345678"))
      (with-temp-buffer
        (ebox-render-to-buffer
         (current-buffer)
         (ebox-build
          `(column :width (ch 20) :height (lh 4)
             (box :width (ch 8) :height (lh 1) :wrap-mode none :overflow hidden
               (text :id "status" ,initial))
             (box :id "panel" :position absolute :left (ch 0) :top (lh 2)
                  :width (ch 8) :height (lh 1) :z-index 1 "Panel"))))
        (let* ((staged nil)
               (operation (ebox-update-prepare
                           (current-buffer) [["status" [:content]]]
                           (lambda () (setq staged t)) #'ignore))
               (before (buffer-string))
               (revision (ebox-surface-buffer-revision (current-buffer)))
               (snapshot (ebox-render (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))))
          (when operation (should-not (ebox-update-apply operation [["x"]] [0])))
          (should-not staged)
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string)))
          (should (equal-including-properties
                   snapshot (ebox-render (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input)))))))))

(provide 'ebox-prepared-update-tests)
;;; ebox-prepared-update-tests.el ends here
