;;; ebox-prepared-focus-tests.el --- Direct focus cohort behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Preserve taskbar presentation and selector/source authority in one focus batch.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-prepared-focus-test--input ()
  "Build the visible presentation channels changed by desktop focus."
  (ebox-build
   '(column :width (ch 60) :height (lh 8)
      (flex :width (ch 60) :flex-direction row :flex-wrap nowrap
        (box :id "tab-one" :class ("task" "active") :width max-content
             :padding ((lh 0) (ch 0.75)) :color "#334155" :background-color "#CBD5E1"
             :border ((px 1) solid "#64748B") :font-weight bold
          (text "Window one"))
        (box :id "tab-three" :class ("task" "idle") :width max-content
             :padding ((lh 0) (ch 0.75)) :color "#64748B" :background-color "#DCE6F0"
             :border ((px 1) solid "#DCE6F0") :font-weight normal
          (text "Window three")))
      (flex :width (ch 60) :height (lh 1) :flex-direction row :flex-wrap nowrap
        (box :flex-grow 1 :flex-basis (px 0) :min-width (px 0) :height (lh 1)
             :wrap-mode none :overflow hidden
          (text :id "status" "Window one"))
        (box :flex-shrink 0 :min-width max-content "Controls"))
      (box :id "window-one" :position absolute :left (ch 0) :top (lh 3)
           :width (ch 24) :height (lh 3) :z-index 2 "One body")
      (box :id "window-three" :position absolute :left (ch 18) :top (lh 4)
           :width (ch 24) :height (lh 3) :z-index 1 "Three body"))))

(defun ebox-prepared-focus-test--specifications ()
  "Return a stable focus cohort with finite class variants."
  [["window-one" [:z-index]]
   ["window-three" [:z-index]]
   ["tab-one" [:class :color :background-color :border :font-weight]
    [[("task" "active") ("task" "idle")] nil nil nil nil]]
   ["tab-three" [:class :color :background-color :border :font-weight]
    [[("task" "active") ("task" "idle")] nil nil nil nil]]
   ["status" [:content]]])

(defun ebox-prepared-focus-test--values (three)
  "Return focus channel values selecting THREE when non-nil."
  (vector
   (vector (if three 1 2)) (vector (if three 2 1))
   (if three [("task" "idle") "#64748B" "#DCE6F0" ((px 1) solid "#DCE6F0") normal]
     [("task" "active") "#334155" "#CBD5E1" ((px 1) solid "#64748B") bold])
   (if three [("task" "active") "#334155" "#CBD5E1" ((px 1) solid "#64748B") bold]
     [("task" "idle") "#64748B" "#DCE6F0" ((px 1) solid "#DCE6F0") normal])
   (vector (if three "Window three" "Window one"))))

(defun ebox-prepared-focus-test--assert-fresh ()
  "Compare the live focused scene with its exported source's fresh rendering."
  (let ((actual (buffer-string))
        (expected (ebox-render (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))))
    (should (equal (substring-no-properties actual) (substring-no-properties expected)))
    (dotimes (position (length actual))
      (dolist (property '(face display font-lock-face pointer help-echo mouse-face))
        (should (equal (get-text-property position property actual)
                       (get-text-property position property expected)))))))

(ert-deftest ebox-prepared-focus-publishes-all-visible-channels-once ()
  "Focus raises the window and updates classes, borders, weights and variable status once."
  (let ((ebox-viewport-width 480) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-focus-test--input))
      (let* ((token (ebox-update-binding-token (current-buffer)))
             (old-input (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
             (old-render (ebox-render old-input))
             (operation (ebox-update-prepare (current-buffer) (ebox-prepared-focus-test--specifications))))
        (should operation)
        (should (eq (plist-get (ebox-update-prepare-report (current-buffer)) :status) 'ready))
        (dolist (three '(t nil t nil))
          (let ((revision (ebox-surface-buffer-revision (current-buffer))))
            (should (ebox-update-apply operation (ebox-prepared-focus-test--values three) [0 1 2 3 4]))
            (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
            (should (eq token (ebox-update-binding-token (current-buffer))))
            (should (eq (plist-get (ebox-buffer-update-report (current-buffer)) :projection-kind) 'prepared-update))
            (should (= 1 (length (ebox-selector-query-buffer
                                 (current-buffer) (if three "#tab-three.active" "#tab-one.active")))))
            (should-not (ebox-selector-query-buffer
                         (current-buffer) (if three "#tab-one.active" "#tab-three.active")))
            (ebox-prepared-focus-test--assert-fresh)))
        (should (equal-including-properties old-render (ebox-render old-input)))))))

(ert-deftest ebox-prepared-focus-rejection-restores-selector-font-and-caller ()
  "A failed focus callback restores every visual, selector and caller fact before retry."
  (let ((ebox-viewport-width 480) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-focus-test--input))
      (let* ((selected 'one) (callbacks 0) (reject t)
             (operation
              (ebox-update-prepare
               (current-buffer) (ebox-prepared-focus-test--specifications)
               (lambda () (setq selected 'three callbacks (1+ callbacks))
                 (when reject (error "Reject focus")))
               (lambda () (setq selected 'one callbacks (1- callbacks)))))
             (before (buffer-string)) (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should-error (ebox-update-apply operation (ebox-prepared-focus-test--values t) [0 1 2 3 4]))
        (should (eq selected 'one)) (should (= callbacks 0))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#tab-one.active"))))
        (should-not (ebox-selector-query-buffer (current-buffer) "#tab-three.active"))
        (ebox-prepared-focus-test--assert-fresh)
        (setq reject nil)
        (should (ebox-update-apply operation (ebox-prepared-focus-test--values t) [0 1 2 3 4]))
        (should (eq selected 'three)) (should (= callbacks 1))
        (ebox-prepared-focus-test--assert-fresh)))))

(provide 'ebox-prepared-focus-tests)
;;; ebox-prepared-focus-tests.el ends here
