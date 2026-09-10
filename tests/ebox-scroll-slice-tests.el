;;; ebox-scroll-slice-tests.el --- Retained visible scroll slices -*- lexical-binding: t; -*-

;;; Commentary:
;; Complete line caches index stable cons handles, preserving current row
;; strings through equal-length rewrites and isolated publication rollback.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defun ebox-scroll-slice-test--lines (count)
  "Return COUNT independently allocated deterministic source lines."
  (cl-loop for index below count collect (format "Row %05d" index)))

(defun ebox-scroll-slice-test--state (lines &optional incomplete)
  "Return a scroll state containing LINES, or a lazy prefix if INCOMPLETE."
  (list :content-height 3 :scroll-offset 0
        :content-lines lines :rendered-content-lines lines
        :content-lines-complete-p (not incomplete)
        :render-content-prefix (and incomplete #'ignore)))

(ert-deftest ebox-scroll-slice-complete-window-avoids-prefix-walks ()
  "Cached windows index only visible rows even at a distant document offset."
  (let* ((lines (ebox-scroll-slice-test--lines 10000))
         (state (ebox-scroll-slice-test--state lines))
         (expected (seq-subseq lines 9000 9003))
         (native-comp-enable-subr-trampolines nil)
         (length-function (symbol-function 'length))
         (subseq-function (symbol-function 'seq-subseq))
         (full-lengths 0) (list-slices 0))
    (ebox--scroll-state-rendered-visible-window state)
    (should (vectorp (plist-get state :rendered-content-line-cells)))
    (plist-put state :scroll-offset 9000)
    (cl-letf (((symbol-function 'length)
               (lambda (value)
                 (when (eq value lines) (cl-incf full-lengths))
                 (funcall length-function value)))
              ((symbol-function 'seq-subseq)
               (lambda (value start &optional end)
                 (when (eq value lines) (cl-incf list-slices))
                 (funcall subseq-function value start end))))
      (let ((visible (ebox--scroll-state-rendered-visible-window state)))
        (should (= (car visible) 9000))
        (should (cl-every #'eq (cadr visible) expected))))
    (should (= full-lengths 0))
    (should (= list-slices 0))))

(ert-deftest ebox-scroll-slice-index-observes-current-cons-cars ()
  "Same-spine row rewrites retain exact strings, opaque callbacks and hover groups."
  (let* ((first (lambda () 'first))
         (second (lambda () 'second))
         (hover (list :background "blue"))
         (line (propertize "before" 'help-echo first 'mouse-face hover))
         (replacement (propertize "after" 'help-echo second 'mouse-face hover))
         (lines (list line (propertize "tail" 'mouse-face (copy-sequence hover))))
         (state (ebox-scroll-slice-test--state lines)))
    (ebox--scroll-state-rendered-visible-window state)
    (let ((index (plist-get state :rendered-content-line-cells)))
      (ebox--line-list-rewrite! lines 0 (list replacement))
      (let ((visible (cadr (ebox--scroll-state-rendered-visible-window state))))
        (should (eq index (plist-get state :rendered-content-line-cells)))
        (should (eq replacement (car visible)))
        (should (eq second (get-text-property 0 'help-echo (car visible))))
        (should (eq hover (get-text-property 0 'mouse-face (car visible))))
        (should-not (eq hover (get-text-property 0 'mouse-face (cadr visible))))))))

(ert-deftest ebox-scroll-slice-extension-and-replacement-refresh-index ()
  "Tail extension and replacement heads cannot reuse stale positional indexes."
  (let* ((lines (ebox-scroll-slice-test--lines 4))
         (state (ebox-scroll-slice-test--state lines)))
    (ebox--scroll-state-rendered-visible-window state)
    (let ((first-index (plist-get state :rendered-content-line-cells)))
      (ebox--line-list-append! lines (last lines) (list "new fourth" "new fifth"))
      (plist-put state :scroll-offset 3)
      (should (equal (cadr (ebox--scroll-state-rendered-visible-window state))
                     '("Row 00003" "new fourth" "new fifth")))
      (should-not (eq first-index (plist-get state :rendered-content-line-cells))))
    (let* ((old-index (plist-get state :rendered-content-line-cells))
           (replacement (copy-sequence lines))
           (ebox--defer-scroll-content-index t))
      (setcar (nthcdr 3 replacement) "replacement")
      (setq state (ebox--scroll-state-set-lines state replacement replacement))
      (should-not (eq old-index (plist-get state :rendered-content-line-cells)))
      (should (equal (car (cadr (ebox--scroll-state-rendered-visible-window state)))
                     "replacement"))
      (let ((index (plist-get state :rendered-content-line-cells)))
        (setq state (ebox--scroll-state-set-lines state replacement replacement))
        (should (eq index (plist-get state :rendered-content-line-cells)))))))

(ert-deftest ebox-scroll-slice-lazy-prefix-remains-unindexed ()
  "Incrementally extended prefixes avoid rebuilding a complete vector each slice."
  (let* ((lines (ebox-scroll-slice-test--lines 4))
         (state (ebox-scroll-slice-test--state lines t))
         (ebox--defer-scroll-content-index t))
    (ebox--scroll-state-rendered-visible-window state)
    (should-not (plist-get state :rendered-content-line-cells))
    (ebox--line-list-rewrite! lines 3 '("rewritten tail"))
    (ebox--line-list-append! lines (last lines) '("appended"))
    (setq state (ebox--scroll-state-set-lines state lines lines))
    (plist-put state :scroll-offset 2)
    (should (equal (cadr (ebox--scroll-state-rendered-visible-window state))
                   '("Row 00002" "rewritten tail" "appended")))
    (should-not (plist-get state :rendered-content-line-cells))
    (plist-put state :content-lines-complete-p t)
    (ebox--scroll-state-rendered-visible-window state)
    (should (vectorp (plist-get state :rendered-content-line-cells)))))

(ert-deftest ebox-scroll-slice-native-empty-and-short-windows ()
  "Native windows take precedence; empty, short and clamped windows stay exact."
  (dolist (count '(0 1 2 3 4))
    (let* ((lines (ebox-scroll-slice-test--lines count))
           (state (ebox-scroll-slice-test--state lines)))
      (dolist (offset '(-4 0 1 20))
        (plist-put state :scroll-offset offset)
        (if lines
            (let* ((start (max 0 (min (max 0 (- count 3)) offset)))
                   (expected (list start (seq-subseq lines start (min count (+ start 3))))))
              (should (equal (ebox--scroll-state-rendered-visible-window state)
                             expected)))
          (should-not (ebox--scroll-state-rendered-visible-window state))))))
  (let* ((state (ebox-scroll-slice-test--state '("ordinary")))
         (native (list "native one" "native two" "native three")))
    (plist-put state :scroll-offset 100)
    (plist-put state :native-reflow-visible-offset 100)
    (plist-put state :native-reflow-visible-lines native)
    (let ((visible (ebox--scroll-state-rendered-visible-window state)))
      (should (= (car visible) 100))
      (should (eq (cadr visible) native))
      (should-not (plist-get state :rendered-content-line-cells)))))

(ert-deftest ebox-scroll-slice-template-discards-derived-index ()
  "Render-cache templates retain source lines without retaining the derived vector."
  (let* ((lines (ebox-scroll-slice-test--lines 5))
         (state (ebox-scroll-slice-test--state lines)))
    (ebox--scroll-state-rendered-visible-window state)
    (let ((template (ebox--scroll-cache-state-template state)))
      (should (eq lines (plist-get template :rendered-content-lines)))
      (should-not (plist-member template :rendered-content-line-cells)))))

(ert-deftest ebox-scroll-slice-candidate-replacement-keeps-prior-index ()
  "A copied candidate state can replace its lines without mutating the old index."
  (let* ((lines (ebox-scroll-slice-test--lines 8))
         (state (ebox-scroll-slice-test--state lines))
         (ebox--defer-scroll-content-index t))
    (ebox--scroll-state-rendered-visible-window state)
    (let* ((old-index (plist-get state :rendered-content-line-cells))
           (candidate (copy-sequence state))
           (candidate-lines (copy-sequence lines)))
      (setcar candidate-lines "candidate only")
      (setq candidate (ebox--scroll-state-set-lines candidate candidate-lines candidate-lines))
      (should (equal (car (cadr (ebox--scroll-state-rendered-visible-window candidate)))
                     "candidate only"))
      (should (eq old-index (plist-get state :rendered-content-line-cells)))
      (should (eq lines (aref old-index 0)))
      (should (eq (car lines) (car (cadr (ebox--scroll-state-rendered-visible-window state))))))))

(ert-deftest ebox-scroll-slice-publication-rollback-retains-index-generation ()
  "Failed publication leaves old row handles usable and the next scroll succeeds."
  (let ((ebox-viewport-width 104) (ebox-viewport-height 5)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil))
    (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p) (lambda () nil)))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer
               (current-buffer)
               (ebox-build `(box :id "scroll" :width (vw 100) :height (vh 100)
                                 :overflow scroll
                                 ,(string-join (ebox-scroll-slice-test--lines 100) "\n"))))
              (let* ((buffer (current-buffer))
                     (region (cdr (ebox-selector--region-target
                                   (ebox-region-resolve buffer "scroll")))))
                (ebox--scroll-state-materialize-lines region (ebox-scroll-state region))
                (ebox--surface-scroll-to-offset buffer region 1)
                (ebox--surface-scroll-to-offset buffer region 0)
                (let* ((state (ebox-scroll-state region))
                       (index (plist-get state :rendered-content-line-cells))
                       (before (buffer-string))
                       (revision (ebox-surface-buffer-revision buffer)))
                  (should (vectorp index))
                  (cl-letf (((symbol-function 'accept-change-group)
                             (lambda (_) (error "Reject indexed scroll"))))
                    (should-error (ebox--surface-scroll-to-offset buffer region 1)))
                  (should (eq state (ebox-scroll-state region)))
                  (should (eq index (plist-get state :rendered-content-line-cells)))
                  (should (equal-including-properties before (buffer-string)))
                  (should (= revision (ebox-surface-buffer-revision buffer)))
                  (ebox--surface-scroll-to-offset buffer region 1)
                  (should (eq index (plist-get (ebox-scroll-state region)
                                              :rendered-content-line-cells)))
                  (should (= 1 (plist-get (ebox-scroll-state region) :scroll-offset)))
                  (should (string-prefix-p "Row 00001" (buffer-string))))))
          (when (ebox-surface-buffer-mounted-p (current-buffer))
            (ebox-unmount-buffer (current-buffer))))))))

(provide 'ebox-scroll-slice-tests)

;;; ebox-scroll-slice-tests.el ends here
