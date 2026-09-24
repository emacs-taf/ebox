;;; ebox-prepared-selector-tests.el --- Prepared selector publication -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise selector/source authority and fixed border updates through public APIs.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-prepared-selector-test--input (&optional relational)
  "Build taskbar-like selection Hosts, optionally with a RELATIONAL rule."
  (ebox-build
   `(box :width (ch 30) :height (lh 6)
         ,@(when relational '(:ecss (("&:has(.inactive-a):has(.active-b)" :color "#ff0000"))))
      (row :height (lh 1)
        (box :id "a" :class ,(if relational "active-a" '(tab active))
             :width max-content :padding ((lh 0) (ch 0.75))
             :border ((px 1) solid "#68809A") :font-weight normal :tab-index 0 "Alpha")
        (box :id "b" :class ,(if relational "inactive-b" '(tab))
             :width max-content :padding ((lh 0) (ch 0.75))
             :border ((px 1) solid "#DCE6F0") :font-weight normal :tab-index 0 "Beta"))
      (box :id "panel" :position absolute :left (ch 0) :top (lh 3)
           :width (ch 8) :height (lh 1) :z-index 1 "Panel"))))

(defun ebox-prepared-selector-test--assert-render ()
  "Compare accepted output with a fresh render of the exported source facts."
  (let ((actual (buffer-string))
        (expected (ebox-render (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))))
    (should (equal (substring-no-properties actual) (substring-no-properties expected)))
    (dotimes (position (length actual))
      (dolist (property '(display face font-lock-face keymap mouse-face))
        (should (equal (get-text-property position property actual)
                       (get-text-property position property expected)))))))

(ert-deftest ebox-prepared-selector-publishes-class-border-and-rollback ()
  "Selection classes, four border colors and queries publish atomically."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-selector-test--input))
      (let* ((reject t) (stages 0)
             (snapshot (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
             (before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer)))
             (operation
              (ebox-update-prepare
               (current-buffer)
               [["a" [:class :border] [[("tab" "active") ("tab") nil] nil]]
                ["b" [:class :border] [[("tab") ("tab" "active")] nil]]]
               (lambda ()
                 (setq stages (1+ stages))
                 (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#b.active"))))
                 (should-not (ebox-selector-query-buffer (current-buffer) "#a.active"))
                 (when reject (error "Reject taskbar selection")))
               (lambda () (setq stages (1- stages)))))
             (values [[("tab") ((px 1) solid "#DCE6F0")]
                      [("tab" "active") ((px 1) solid "#68809A")]]))
        (should operation)
        (should-error (ebox-update-apply operation values [0 1]))
        (should (= stages 0))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#a.active"))))
        (should-not (ebox-selector-query-buffer (current-buffer) "#b.active"))
        (setq reject nil)
        (should (ebox-update-apply operation values [0 1]))
        (should (= stages 1))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) ".active"))))
        (should (= 1 (length (ebox-selector-query-all snapshot "#a.active"))))
        (should-not (ebox-selector-query-all snapshot "#b.active"))
        (ebox-prepared-selector-test--assert-render)
        (aset values 0 [nil ((px 1) solid "#DCE6F0")])
        (should (ebox-update-apply operation values [0]))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#a:not(.tab)"))))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) ".tab"))))
        (ebox-prepared-selector-test--assert-render)
        (setq before (buffer-string) revision (ebox-surface-buffer-revision (current-buffer)))
        (aset values 0 ["not-admitted" ((px 1) solid "#DCE6F0")])
        (should-not (ebox-update-apply operation values [0]))
        (aset values 0 [nil ((px 2) solid "#DCE6F0")])
        (should-not (ebox-update-apply operation values [0]))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))))))

(ert-deftest ebox-prepared-selector-rejects-combined-relational-effects ()
  "Two class changes that jointly activate an ancestor rule require ordinary cascade."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-selector-test--input t))
      (let ((before (buffer-string)) (revision (ebox-surface-buffer-revision (current-buffer))))
        (should-not
         (ebox-update-prepare
          (current-buffer)
          [["a" [:class] [["active-a" "inactive-a"]]]
           ["b" [:class] [["inactive-b" "active-b"]]]]))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) ".active-a"))))
        (should-not (ebox-selector-query-buffer (current-buffer) ".active-b"))))))

(ert-deftest ebox-prepared-selector-preserves-source-token-grammar ()
  "Single strings stay single class tokens; symbols and nil retain source meaning."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 30) :height (lh 5)
           (box :id "literal" :class "tab active" :position absolute
                :left (ch 1) :top (lh 1) :width (ch 10) :height (lh 1) :z-index 1 "Literal"))))
      (let* ((snapshot (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
             (operation (ebox-update-prepare
                         (current-buffer) [["literal" [:class] [["tab active" active nil]]]])))
        (should operation)
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) ".tab\\ active"))))
        (should-not (ebox-selector-query-buffer (current-buffer) ".active"))
        (should (ebox-update-apply operation [[active]] [0]))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) ".active"))))
        (should-not (ebox-selector-query-buffer (current-buffer) ".tab\\ active"))
        (should (ebox-update-apply operation [[nil]] [0]))
        (should-not (ebox-selector-query-buffer (current-buffer) ".active"))
        (should (ebox-update-apply operation [["tab active"]] [0]))
        (let ((before (buffer-string)) (revision (ebox-surface-buffer-revision (current-buffer))))
          (should-not (ebox-update-apply operation [[("tab" "active")]] [0]))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string))))
        (should (= 1 (length (ebox-selector-query-all snapshot ".tab\\ active"))))
        (should-not (ebox-selector-query-all snapshot ".active"))))))

(provide 'ebox-prepared-selector-tests)
;;; ebox-prepared-selector-tests.el ends here
