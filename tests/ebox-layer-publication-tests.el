;;; ebox-layer-publication-tests.el --- Retained layer updates -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise layer composition through public mounted update APIs.  Hidden
;; source objects remain logical inputs, while only visible roles are mounted.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'ebox)
(require 'ebox-selector)

(defmacro ebox-layer-publication-test--with-buffer (&rest body)
  "Run BODY with an isolated buffer and the explicit Elisp backend."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
              (lambda () nil)))
     (let ((ebox-viewport-width 160) (ebox-viewport-height 10))
       (with-temp-buffer ,@body))))

(defun ebox-layer-publication-test--input (&optional lower upper-visible)
  "Build a nested fixed host with LOWER text and UPPER-VISIBLE overlay."
  (ebox-build
   `(column :id "root" :width (ch 12) :height (lh 5)
      (box :id "before" "Before")
      (box :id "host" :width (ch 8) :height (lh 2)
        (box :id "lower" :width (ch 8) :height (lh 1)
          ,(or lower "LOWER001"))
        (box :id "upper" :position absolute :left (px 0) :top (lh 0)
          :width (ch 8) :height (lh 1) :z-index 1
          :visibility ,(if upper-visible 'visible 'hidden)
          "UPPER001"))
      (box :id "after" "After"))))

(defun ebox-layer-publication-test--assert-fresh-render ()
  "Check visible text against a fresh render of the committed logical input."
  (should
   (equal (buffer-substring-no-properties (point-min) (point-max))
          (substring-no-properties
           (ebox-render
            (plist-get (ebox-surface-buffer-snapshot (current-buffer))
                       :input))))))

(ert-deftest ebox-layer-publication-updates-every-placement-property ()
  "Each layer declaration reaches the mounted runtime through a region update."
  (dolist (properties '((:position relative) (:left (ch 2)) (:top (lh 1))
                        (:z-index -1) (:layer root) (:anchor "lower")
                        (:placement top-end)))
    (ert-info ((format "Update %S" properties))
      (ebox-layer-publication-test--with-buffer
        (ebox-render-to-buffer
         (current-buffer) (ebox-layer-publication-test--input nil t))
        (let* ((handle (ebox-region-resolve (current-buffer) "upper"))
               (region-id (cdr (ebox-selector--region-target handle)))
               (revision (ebox-surface-buffer-revision (current-buffer))))
          (should (apply #'ebox-region-update handle properties))
          (should (> (ebox-surface-buffer-revision (current-buffer)) revision))
          (should (equal (plist-get
                          (ebox--buffer-region-render-owner-node
                           (current-buffer) region-id)
                          (car properties))
                         (cadr properties)))
          (ebox-layer-publication-test--assert-fresh-render))))))

(ert-deftest ebox-layer-publication-hidden-updates-reveal-current-input ()
  "Hidden content and paint updates survive without painting over upper text."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-publication-test--input nil t))
    (let ((render (symbol-function 'ebox-surface--render-candidate))
          (full-renders 0))
      (should (string-match-p "UPPER001" (buffer-string)))
      (should-not (string-match-p "LOWER001" (buffer-string)))
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (&rest arguments)
                   (cl-incf full-renders)
                   (apply render arguments))))
        (ebox-region-update "lower" :content "LOWER002")
        (ebox-selector-update-buffer
         (current-buffer) "#lower" :color "#ff0000")
        (should (string-match-p "UPPER001" (buffer-string)))
        (should-not (string-match-p "LOWER002" (buffer-string)))
        (ebox-region-update "upper" :visibility 'hidden)
        (should (string-match-p "LOWER002" (buffer-string)))
        (should-not (string-match-p "UPPER001" (buffer-string)))
        (let* ((start (string-match "LOWER002" (buffer-string)))
               (face (get-text-property (+ (point-min) start) 'face)))
          (should (string-match-p "#ff0000" (prin1-to-string face)))))
      (should (= full-renders 0))
      (ebox-layer-publication-test--assert-fresh-render))))

(ert-deftest ebox-layer-publication-rejected-hidden-commit-rolls-back ()
  "Rejected hidden updates leave retained input, revision and text unchanged."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-publication-test--input nil t))
    (let ((before (buffer-string))
          (revision (ebox-surface-buffer-revision (current-buffer))))
      (should-error
       (ebox-commit
        (current-buffer) (ebox-layer-publication-test--input "REJECTED" t)
        (lambda (_report) (error "Reject hidden layer candidate"))))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (equal-including-properties before (buffer-string)))
      (ebox-region-update "upper" :visibility 'hidden)
      (should (string-match-p "LOWER001" (buffer-string)))
      (should-not (string-match-p "REJECTED" (buffer-string)))
      (ebox-layer-publication-test--assert-fresh-render))))

(ert-deftest ebox-layer-publication-footprint-change-falls-back ()
  "Host geometry changes preserve siblings through the existing root fallback."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-publication-test--input nil t))
    (let ((render (symbol-function 'ebox-surface--render-candidate))
          (full-renders 0))
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (&rest arguments)
                   (cl-incf full-renders)
                   (apply render arguments))))
        (ebox-region-update "host" :height '(lh 3)))
      (should (> full-renders 0))
      (should (string-match-p "Before" (buffer-string)))
      (should (string-match-p "After" (buffer-string)))
      (ebox-layer-publication-test--assert-fresh-render))))

(ert-deftest ebox-layer-publication-ordinary-update-skips-layer-walk ()
  "A non-layer tree's owner planner does not scan on content changes."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(column :width (ch 12) :height (lh 3)
                   (box :id "text" :width (ch 8) :height (lh 1) "BEFORE00"))))
    (let ((plan (symbol-function 'ebox-incremental--layer-owner-plan)))
      (cl-letf (((symbol-function 'ebox-incremental--layer-owner-plan)
                 (lambda (&rest arguments)
                   (cl-letf (((symbol-function 'ebox-layer-host-p)
                              (lambda (&rest _)
                                (ert-fail "Unexpected layer host walk")))
                             ((symbol-function 'ebox-layer-subtree-p)
                              (lambda (&rest _)
                                (ert-fail "Unexpected layer subtree scan"))))
                     (apply plan arguments)))))
        (ebox-region-update "text" :content "AFTER000")))
    (should (string-match-p "AFTER000" (buffer-string)))))

(ert-deftest ebox-layer-publication-declines-unsupported-native-layout ()
  "A retained layer tree is ineligible for both native layout entry points."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-publication-test--input nil t))
    (let* ((state (ebox--buffer-render-state (current-buffer)))
           (root (plist-get state :root-node)))
      (should-not (ebox-native-reflow--native-node-supported-p root))
      (should-not (ebox-native-commit--runtime-types-supported-p state))
      (should-not (plist-get state :native-render-p)))
    (ebox-region-update "lower" :content "LOWER002")
    (ebox-region-update "upper" :visibility 'hidden)
    (ebox-layer-publication-test--assert-fresh-render)))

(ert-deftest ebox-layer-publication-visible-interactions-follow-occlusion ()
  "Only the visible layer owns interaction properties after hidden updates."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-publication-test--input nil t))
    (ebox-region-update "lower" :keymap '(keymap (13 . backward-char))
                        :help-echo "lower-old")
    (ebox-region-update "upper" :keymap '(keymap (13 . forward-char))
                        :help-echo "upper")
    (ebox-region-update "lower" :keymap '(keymap (13 . ignore))
                        :help-echo "lower-new")
    (let ((position (+ (point-min) (string-match "UPPER001" (buffer-string)))))
      (should (eq (lookup-key (get-text-property position 'keymap) (kbd "RET"))
                  #'forward-char))
      (should (equal (get-text-property position 'help-echo) "upper")))
    (ebox-region-update "upper" :visibility 'hidden)
    (let ((position (+ (point-min) (string-match "LOWER001" (buffer-string)))))
      (should (eq (lookup-key (get-text-property position 'keymap) (kbd "RET"))
                  #'ignore))
      (should (equal (get-text-property position 'help-echo) "lower-new")))
    (ebox-layer-publication-test--assert-fresh-render)))

(ert-deftest ebox-layer-publication-ancestor-paint-survives-recomposition ()
  "A detached host retains enclosing paint and interaction contributions."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-publication-test--input nil t))
    (ebox-region-update "root" :color "#00ff00" :background-color "#000080"
                        :help-echo "ancestor")
    (ebox-region-update "lower" :content "LOWER002")
    (ebox-region-update "upper" :visibility 'hidden)
    (let* ((actual (buffer-string))
           (expected (ebox-render
                      (plist-get (ebox-surface-buffer-snapshot (current-buffer))
                                 :input)))
           (actual-position (string-match "LOWER002" actual))
           (expected-position (string-match "LOWER002" expected)))
      (should (equal (get-text-property actual-position 'face actual)
                     (get-text-property expected-position 'face expected)))
      (should (equal (get-text-property actual-position 'help-echo actual)
                     "ancestor")))
    (ebox-layer-publication-test--assert-fresh-render)))

(ert-deftest ebox-layer-publication-batch-retains-disjoint-owner-updates ()
  "A hidden update and an ordinary sibling update publish one current input."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-publication-test--input nil t))
    (ebox-incremental-begin-batch (current-buffer))
    (ebox-region-update "lower" :content "LOWER002")
    (ebox-region-update "after" :content "Later")
    (ebox-incremental-flush (current-buffer))
    (should (string-match-p "UPPER001" (buffer-string)))
    (should (string-match-p "Later" (buffer-string)))
    (should-not (string-match-p "LOWER002" (buffer-string)))
    (ebox-region-update "upper" :visibility 'hidden)
    (should (string-match-p "LOWER002" (buffer-string)))
    (ebox-layer-publication-test--assert-fresh-render)))

(ert-deftest ebox-layer-publication-root-portal-occludes-unrelated-owner ()
  "Updates outside a root portal's local host cannot paint over the portal."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(column :id "root" :width (ch 12) :height (lh 5)
         (box :id "body" :width (ch 8) :height (lh 1) "BODY0001")
         (box :id "host" :width (ch 4) :height (lh 1)
           (box :id "portal" :position absolute :layer root
             :left (px 0) :top (lh 0) :width (ch 8) :height (lh 1)
             :z-index 1 "PORTAL01")))))
    (ebox-region-update "body" :content "BODY0002")
    (should (string-match-p "PORTAL01" (buffer-string)))
    (should-not (string-match-p "BODY0002" (buffer-string)))
    (ebox-region-update "portal" :visibility 'hidden)
    (should (string-match-p "BODY0002" (buffer-string)))
    (ebox-layer-publication-test--assert-fresh-render)))

(ert-deftest ebox-layer-publication-root-portal-survives-cached-branch ()
  "An unchanged cached branch still collects its root portal on later renders."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(column :id "root" :width (ch 12) :height (lh 5)
         (box :id "body" :width (ch 12) :height (lh 1) "BODY0001")
         (box :id "host" :width (ch 4) :height (lh 1)
           (box :id "local" :width (ch 4) :height (lh 1) "HOST")
           (box :id "portal" :position absolute :layer root
             :left (ch 4) :top (lh 3) :width (ch 6) :height (lh 1)
             "PORTAL")))))
    (dotimes (index 3)
      (ebox-region-update "body" :content (format "BODY000%d" (+ index 2)))
      (should (string-match-p "PORTAL" (buffer-string)))
      (ebox-layer-publication-test--assert-fresh-render))
    (ebox-region-update "portal" :visibility 'hidden)
    (should-not (string-match-p "PORTAL" (buffer-string)))
    (ebox-region-update "portal" :content "LATEST")
    (ebox-region-update "portal" :visibility 'visible)
    (should (string-match-p "LATEST" (buffer-string)))
    (ebox-layer-publication-test--assert-fresh-render)))

(ert-deftest ebox-layer-publication-revealed-anchor-uses-candidate-source ()
  "A revealed portal resolves its semantic anchor against current input."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(column :id "root" :width (ch 12) :height (lh 5)
         (box :id "trigger" :width (ch 8) :height (lh 1) "ANCHOR01")
         (box :id "host" :width (ch 4) :height (lh 1)
           (box :id "portal" :position absolute :layer root
             :anchor "trigger" :width (ch 6) :height (lh 1)
             :visibility hidden "PORTAL")))))
    (ebox-region-update "portal" :visibility 'visible)
    (should (string-match-p "PORTAL" (buffer-string)))
    (ebox-layer-publication-test--assert-fresh-render)
    (ebox-region-update "trigger" :position 'relative :left '(ch 2))
    (should (string-match-p "PORTAL" (buffer-string)))
    (ebox-layer-publication-test--assert-fresh-render)))

(ert-deftest ebox-layer-publication-scroll-under-overlay-and-rollback ()
  "Scrolling lower content recomposes its host and rolls back with TP."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(column :id "root" :width (ch 12) :height (lh 5)
         (box :id "before" "Before")
         (box :id "host" :width (ch 8) :height (lh 2)
           (box :id "scroll" :width (ch 8) :height (lh 2) :overflow scroll
             "ZERO0000\nONE00000\nTWO00000\nTHREE000")
           (box :id "upper" :position absolute :width (ch 8) :height (lh 1)
             "UPPER001"))
         (box :id "after" "After"))))
    (let* ((region-id (plist-get
                       (car (ebox-selector-query-buffer (current-buffer) "#scroll"))
                       :region-id))
           (revision (ebox-surface-buffer-revision (current-buffer)))
           (before (buffer-string)))
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (&rest _)
                   (ert-fail "Fixed local layer scroll rendered the root"))))
        (let ((tp--surface-publication-step-function
               (lambda (step _surface)
                 (when (eq step 'client-state) (error "Reject layer scroll")))))
          (should-error (ebox--scroll-region-by region-id 1 1)))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (should (= 0 (plist-get (ebox-scroll-state region-id) :scroll-offset)))
        (should (= 1 (ebox--scroll-region-by region-id 1 1)))
        (should (string-match-p "UPPER001" (buffer-string)))
        (should (string-match-p "TWO00000" (buffer-string)))
        (should-not (string-match-p "ONE00000" (buffer-string)))
        (ebox-region-update "upper" :visibility 'hidden)
        (should (string-match-p "ONE00000" (buffer-string)))
        (should (string-match-p "TWO00000" (buffer-string)))
        (should (string-match-p "Before" (buffer-string)))
        (should (string-match-p "After" (buffer-string)))))))

(provide 'ebox-layer-publication-tests)
;;; ebox-layer-publication-tests.el ends here
