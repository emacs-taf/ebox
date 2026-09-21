;;; ebox-layer-publication-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

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

(defun ebox-layer-publication-test--assert-fresh-properties ()
  "Compare visible text, geometry, paint and interactions with a fresh render."
  (let ((actual (buffer-string))
        (fresh (ebox-render
                (plist-get (ebox-surface-buffer-snapshot (current-buffer))
                           :input))))
    (should (equal (substring-no-properties actual)
                   (substring-no-properties fresh)))
    (dotimes (position (length actual))
      (dolist (property '(face font-lock-face display help-echo keymap
                         mouse-face pointer))
        (ert-info ((format "Property %S at character %d" property position))
          (should (equal (get-text-property position property actual)
                         (get-text-property position property fresh))))))))

(ert-deftest ebox-layer-publication-intrinsic-host-width-can-grow ()
  "Content-dependent hosts must grow naturally and move their following sibling."
  (dolist (width '(max-content min-content fit-content auto))
    (ert-info ((format "Intrinsic host width %S" width))
      (ebox-layer-publication-test--with-buffer
        (ebox-render-to-buffer
         (current-buffer)
         (ebox-build
          `(row :width (ch 20) :height (lh 2)
                (box :id "host" :width ,width :height (lh 1)
                     (box :id "lower" "AAAA")
                     (box :position absolute :width (ch 2)
                          :height (lh 1) "XX"))
                (box "TAIL"))))
        (dolist (content '("AAAAAA" "AAA"))
          (ebox-region-update "lower" :content content)
          (ebox-layer-publication-test--assert-fresh-properties))))))

(ert-deftest ebox-layer-publication-inline-auto-host-width-can-grow ()
  "Automatic inline widths remain content-dependent even under normal flow."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(box :width (ch 20) :height (lh 2)
            (box :id "host" :outer inline :height (lh 1)
                 (box :id "lower" :outer inline "AAAA")
                 (box :position absolute :width (ch 2)
                      :height (lh 1) "XX"))
            (box :outer inline "TAIL"))))
    (dolist (content '("AAA" "AAAAAA"))
      (ebox-region-update "lower" :content content)
      (ebox-layer-publication-test--assert-fresh-properties))))

(ert-deftest ebox-layer-positioned-host-allows-nonpositioned-font-descendants ()
  "A positioned host may contain ordinary text with a different font metric.

Only positioned descendants must share the containing host's line height;
ordinary flow content is allowed to choose its own font presentation."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(row :width (ch 24) :height (lh 3)
            (box :position relative :width (ch 20) :height (lh 2)
                 (box :font-weight bold "Title")
                 (box :position absolute :left (px 0) :top (lh 0)
                      :width (ch 8) :height (lh 1) :font-size 10 "Overlay")))))))

(ert-deftest ebox-layer-publication-hidden-ancestor-portals-stay-hidden-in-active-root ()
  "Root composition must not collect portals under a hidden flow ancestor."
  (dolist (other-root-paint '(absolute portal))
    (ert-info ((format "Other root paint %S" other-root-paint))
      (ebox-layer-publication-test--with-buffer
        (ebox-render-to-buffer
         (current-buffer)
         (ebox-build
          `(box :width (ch 12) :height (lh 3)
                (box "BASE00000000\nABCDEFGHIJKL\n0123456789ab")
                (box :id "hidden-owner" :visibility hidden :height (lh 1)
                     (box :height (lh 1)
                          (box :id "hidden-portal" :position absolute :layer root
                               :left (ch 0) :top (lh 0) :width (ch 8)
                               :height (lh 1) :z-index 9 "HIDDEN01")))
                ,(if (eq other-root-paint 'absolute)
                     '(box :position absolute :left (ch 10) :top (lh 2)
                           :width (ch 2) :height (lh 1) "XY")
                   '(box :height (lh 1)
                         (box :position absolute :layer root
                              :left (ch 10) :top (lh 2)
                              :width (ch 2) :height (lh 1) "XY"))))))
        (should-not (string-match-p "HIDDEN01" (buffer-string)))
        (should (string-match-p "XY" (buffer-string)))
        (ebox-layer-publication-test--assert-fresh-properties)
        (ebox-region-update "hidden-portal" :content "HIDDEN02")
        (should-not (string-match-p "HIDDEN02" (buffer-string)))
        (ebox-layer-publication-test--assert-fresh-properties)
        (dotimes (_ 2)
          (ebox-region-update "hidden-owner" :visibility 'visible)
          (should (string-match-p "HIDDEN02" (buffer-string)))
          (should (string-match-p "XY" (buffer-string)))
          (ebox-layer-publication-test--assert-fresh-properties)
          (ebox-region-update "hidden-owner" :visibility 'hidden)
          (should-not (string-match-p "HIDDEN02" (buffer-string)))
          (should (string-match-p "XY" (buffer-string)))
          (ebox-layer-publication-test--assert-fresh-properties))))))

(provide 'ebox-layer-publication-tests)
;;; ebox-layer-publication-tests.el ends here
