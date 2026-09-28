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

(ert-deftest ebox-prepared-selector-reprepares-after-ordinary-commit ()
  "An ordinary commit after prepared class writes keeps later cohorts bindable."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10)
        (specifications
         [["a" [:class :border] [[("tab" "active") ("tab")] nil]]
          ["b" [:class :border] [[("tab") ("tab" "active")] nil]]])
        (values [[("tab") ((px 1) solid "#DCE6F0")]
                 [("tab" "active") ((px 1) solid "#68809A")]]))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-selector-test--input))
      (let ((operation (ebox-update-prepare (current-buffer) specifications)))
        (should operation)
        (should (ebox-update-apply operation values [0 1]))
        (ebox-commit (current-buffer)
                     (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
        (ebox-prepared-selector-test--assert-render)
        (should-not (ebox-update-valid-p operation))
        (setq operation (ebox-update-prepare (current-buffer) specifications))
        (should operation)
        (aset values 0 [("tab" "active") ((px 1) solid "#68809A")])
        (aset values 1 [("tab") ((px 1) solid "#DCE6F0")])
        (should (ebox-update-apply operation values [0 1]))
        (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#a.active"))))
        (should-not (ebox-selector-query-buffer (current-buffer) "#b.active"))
        (ebox-prepared-selector-test--assert-render)))))

(defun ebox-prepared-selector-test--item-input (label)
  "Build a flex row whose first item declares participation, showing LABEL."
  (ebox-build
   `(box :width (ch 30) :height (lh 4)
      (flex :id "bar" :color "#000000" :flex-direction row :height (lh 1) :width stretch
        (box :flex-grow 1 :flex-shrink 1 :min-width (ch 0) :height (lh 1)
          (box :class "label" :width max-content ,label))
        (box :width (ch 4) :height (lh 1) "CD"))
      (box :id "panel" :position absolute :left (ch 0) :top (lh 3)
           :width (ch 8) :height (lh 1) :z-index 1 "Panel"))))

(ert-deftest ebox-prepared-selector-rollback-restores-restyled-flex-items ()
  "A rejected paint change restores descendants whose restyle rewrote item properties."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer)
                             (ebox-prepared-selector-test--item-input "AB"))
      (let* ((reject t)
             (before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer)))
             (operation
              (ebox-update-prepare
               (current-buffer) [["bar" [:color]]]
               (lambda () (when reject (error "Reject bar color")))
               #'ignore)))
        (should operation)
        (should-error (ebox-update-apply operation [["#ff0000"]] [0]))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (ebox-prepared-selector-test--assert-render)
        (setq reject nil)
        (should (ebox-update-apply operation [["#ff0000"]] [0]))
        (ebox-prepared-selector-test--assert-render)
        (should (ebox-update-apply operation [["#000000"]] [0]))
        (should (equal-including-properties before (buffer-string)))
        ;; A structural commit walks the restored tree's children.
        (ebox-commit (current-buffer)
                     (ebox-prepared-selector-test--item-input "ABC"))
        (should (string-prefix-p "ABC" (buffer-substring-no-properties
                                        (point-min) (point-max))))
        (ebox-prepared-selector-test--assert-render)))))

(ert-deftest ebox-prepared-selector-rebinds-after-scroll-publication ()
  "Scrolling preserves class bindings, unique selector matches and atomic resize."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 12)
        (specifications [["panel" [:class :height] [["cold" "hot"] nil]]]))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (px 100) :height (lh 10) :overflow hidden
              (box :id "panel" :class "cold" :position absolute
                   :left (px 0) :top (lh 1) :width (px 40) :height (lh 2)
                   :z-index 1 :overflow scroll
                   (text "A1\nA2\nA3\nA4\nA5")))))
      (let* ((region (plist-get (car (ebox-selector-query-buffer (current-buffer) "#panel")) :region-id))
             (operation (ebox-update-prepare (current-buffer) specifications)))
        (should operation)
        (should (ebox-update-apply operation [["hot" (lh 2)]] [0]))
        (dotimes (_ 3)
          (goto-char (point-min))
          (search-forward "A1")
          (backward-char 2)
          (ebox-scroll-down 1)
          (should (= 1 (plist-get (ebox-scroll-state region) :scroll-offset)))
          (should-not (ebox-update-valid-p operation))
          (goto-char (point-min))
          (search-forward "A2")
          (backward-char 2)
          (ebox-scroll-up 1)
          (should (= 0 (plist-get (ebox-scroll-state region) :scroll-offset)))
          (let* ((before (buffer-string))
                 (revision (ebox-surface-buffer-revision (current-buffer)))
                 (snapshot (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
                 (reject t) (state 'before))
            (setq operation
                  (ebox-update-prepare
                   (current-buffer) specifications
                   (lambda ()
                     (setq state 'after)
                     (when reject (error "Reject class after scroll")))
                   (lambda () (setq state 'before))))
            (should operation)
            (should-error (ebox-update-apply operation [["cold" (lh 5)]] [0]))
            (should (eq state 'before))
            (should (= revision (ebox-surface-buffer-revision (current-buffer))))
            (should (equal-including-properties before (buffer-string)))
            (should (= 1 (length (ebox-selector-query-buffer (current-buffer) ".hot"))))
            (should-not (ebox-selector-query-buffer (current-buffer) ".cold"))
            (should (= 0 (plist-get (ebox-scroll-state region) :scroll-offset)))
            (setq reject nil)
            (should (ebox-update-apply operation [["cold" (lh 5)]] [0]))
            (should (eq state 'after))
            (should-not (ebox-scroll-state region))
            (should (= 1 (length (ebox-selector-query-buffer (current-buffer) ".cold"))))
            (should-not (ebox-selector-query-buffer (current-buffer) ".hot"))
            (should (= 1 (length (ebox-selector-query-all snapshot ".hot"))))
            (should-not (ebox-selector-query-all snapshot ".cold"))
            (ebox-prepared-selector-test--assert-render)
            (should (ebox-update-apply operation [["hot" (lh 2)]] [0]))
            (should (= 1 (length (ebox-selector-query-buffer (current-buffer) ".hot"))))
            (should (= 2 (plist-get (ebox-scroll-state region) :content-height)))
            (ebox-prepared-selector-test--assert-render)))))))

(provide 'ebox-prepared-selector-tests)
;;; ebox-prepared-selector-tests.el ends here
