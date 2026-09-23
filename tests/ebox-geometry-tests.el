;;; ebox-geometry-tests.el --- Public geometry update contract -*- lexical-binding: t; -*-

;;; Commentary:
;; Verify the low-level Box geometry query and incremental update boundary.
;; Gesture and window-management policy intentionally remain outside Ebox.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'ebox)

(defmacro ebox-geometry-test--with-buffer (&rest body)
  "Run BODY in an isolated mounted Ebox buffer."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
              (lambda () nil)))
     (let ((ebox-viewport-width 160) (ebox-viewport-height 12))
       (with-temp-buffer ,@body))))

(defun ebox-geometry-test--input ()
  "Return a fixed layered Box used by the geometry acceptance tests."
  (ebox-build
   '(box :id "root" :width (px 160) :height (lh 8)
      (box :id "panel" :position absolute :left (px 2) :top (lh 1)
           :width (px 40) :height (lh 2) :z-index 1
           (text :id "panel-text" "Panel"))
      (box :id "peer" :position absolute :left (px 60) :top (lh 1)
           :width (px 20) :height (lh 1) :z-index 0 "Peer"))))

(ert-deftest ebox-region-geometry-updates-position-size-and-layer-atomically ()
  "One typed geometry update changes all Box facts through retained publication."
  (ebox-geometry-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-geometry-test--input))
    (let ((initial (ebox-region-geometry "panel")))
      (should (equal (plist-get initial :left) '(px 2)))
      (should (equal (plist-get initial :top) '(lh 1)))
      (should (equal (plist-get initial :width) '(px 40)))
      (should (equal (plist-get initial :height) '(lh 2)))
      (should (= (plist-get initial :z-index) 1)))
    (let ((report
           (ebox-region-update-geometry
            "panel" :left '(px 12) :top '(lh 3)
            :width '(px 64) :height '(lh 4) :z-index 4)))
      (should (listp report))
      (should (memq 'geometry (plist-get report :dirty-kinds))))
    (let ((geometry (ebox-region-geometry "panel")))
      (should (equal (plist-get geometry :left) '(px 12)))
      (should (equal (plist-get geometry :top) '(lh 3)))
      (should (equal (plist-get geometry :width) '(px 64)))
      (should (equal (plist-get geometry :height) '(lh 4)))
      (should (= (plist-get geometry :z-index) 4)))
    ;; The query is defensive and does not expose the mounted Box plist.
    (let ((geometry (ebox-region-geometry "panel")))
      (setf (plist-get geometry :left) '(px 99))
      (should (equal (plist-get (ebox-region-geometry "panel") :left)
                     '(px 12))))
    (let ((fresh
           (ebox-render
            (plist-get (ebox-surface-buffer-snapshot (current-buffer))
                       :input))))
      (should (equal (substring-no-properties (buffer-string))
                     (substring-no-properties fresh))))))

(ert-deftest ebox-region-update-geometry-rejects-non-geometry-and-text ()
  "The typed geometry boundary rejects policy/content properties and Text."
  (ebox-geometry-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-geometry-test--input))
    (should-error (ebox-region-update-geometry "panel" :content "No"))
    (should-error (ebox-region-update-geometry "panel" :background-color "red"))
    (should-error (ebox-region-update-geometry "panel" :left))
    (should-error (ebox-region-geometry "panel" :extra))
    ;; The direct child Text receives a semantic identity but does not own Box
    ;; geometry.  Its content remains available through region-update.
    (should-error (ebox-region-update-geometry
                   (ebox-region-resolve (current-buffer) "panel-text")
                   :width '(px 20)))))

(defun ebox-geometry-test--assert-current-render ()
  "Compare committed pixels and native properties with a fresh source render."
  (let ((actual (buffer-string))
        (expected (ebox-render
                   (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))))
    (should (equal (substring-no-properties actual) (substring-no-properties expected)))
    (dotimes (position (length actual))
      (dolist (property '(display face font-lock-face keymap help-echo mouse-face pointer))
        (should (equal (get-text-property position property actual)
                       (get-text-property position property expected)))))))

(ert-deftest ebox-prepared-geometry-retains-source-and-snapshots ()
  "Prepared moves preserve old exports and feed the next ordinary publication."
  (ebox-geometry-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-geometry-test--input))
    (should-error (ebox-geometry-prepare (current-buffer) "panel" [:left :left]))
    (let* ((initial (ebox-surface-buffer-snapshot (current-buffer)))
           (initial-text (ebox-render (plist-get initial :input)))
           (operation (ebox-geometry-prepare
                       (current-buffer) "panel" [:left :top :width :height :z-index]))
           (values (vector '(px 12) '(lh 3) '(px 40) '(lh 2) 4)))
      (should operation)
      (should (ebox-geometry-valid-p operation))
      (should (ebox-geometry-apply operation values))
      (ebox-geometry-test--assert-current-render)
      (let* ((middle (ebox-surface-buffer-snapshot (current-buffer)))
             (middle-text (ebox-render (plist-get middle :input))))
        (aset values 0 '(px 20))
        (aset values 1 '(lh 1))
        (aset values 4 0)
        (should (ebox-geometry-apply operation values))
        (ebox-geometry-test--assert-current-render)
        (should (equal-including-properties
                 middle-text (ebox-render (plist-get middle :input)))))
      (should (equal-including-properties
               initial-text (ebox-render (plist-get initial :input))))
      (ebox-region-update "peer" :content "New")
      (should-not (ebox-geometry-valid-p operation))
      (should (equal (plist-get (ebox-region-geometry "panel") :left) '(px 20)))
      (ebox-geometry-test--assert-current-render))))

(ert-deftest ebox-prepared-geometry-rejects-and-recovers-paired-state ()
  "A failed prepared publication restores pixels, source and its caller state."
  (ebox-geometry-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-geometry-test--input))
    (let* ((value 'before) (reject t)
           (before (buffer-string))
           (revision (ebox-surface-buffer-revision (current-buffer)))
           (operation
            (ebox-geometry-prepare
             (current-buffer) "panel" [:left :top :z-index]
             (lambda () (setq value 'after) (when reject (error "Reject geometry")))
             (lambda () (setq value 'before))))
           (values (vector '(px 12) '(lh 3) 4)))
      (should operation)
      (should-error (ebox-geometry-apply operation values))
      (should (eq value 'before))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (equal-including-properties before (buffer-string)))
      (should (equal (plist-get (ebox-region-geometry "panel") :left) '(px 2)))
      (ebox-geometry-test--assert-current-render)
      (setq reject nil)
      (should (ebox-geometry-apply operation values))
      (should (eq value 'after))
      (ebox-geometry-test--assert-current-render))))

(ert-deftest ebox-prepared-geometry-composes-nested-fixed-canvas ()
  "Moves inside a bordered nested canvas preserve enclosing rows and paint."
  (ebox-geometry-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(column :width (px 160) :height (lh 10)
               :color "#dddddd" :background-color "#101010"
         (box :height (lh 1) "HEADER")
         (box :id "canvas" :position relative :width (px 160) :height (lh 8)
              :border ((px 1) solid "#999999") :background-color "#202020"
           (box :id "panel" :position absolute :left (px 2) :top (lh 0)
                :width (px 48) :height (lh 2) :z-index 1
                :background-color "#404040" :help-echo "panel" "PANEL")
           (box :id "peer" :position absolute :left (px 30) :top (lh 1)
                :width (px 48) :height (lh 2) :z-index 2
                :background-color "#606060" :help-echo "peer" "PEER"))
         (box :height (lh 1) "FOOTER"))))
    (let ((operation (ebox-geometry-prepare
                      (current-buffer) "panel" [:left :top :width :height :z-index])))
      (should operation)
      (dolist (values '([(px 14) (lh 2) (px 48) (lh 2) 3]
                        [(px 60) (lh 0) (px 48) (lh 2) 0]
                        [(px 2) (lh 0) (px 48) (lh 2) 1]))
        (should (ebox-geometry-apply operation values))
        (ebox-geometry-test--assert-current-render))
      (ebox-region-update "canvas" :background-color "#303030")
      (ebox-geometry-test--assert-current-render)
      (ebox-region-update "panel" :color "#00ff00")
      (ebox-geometry-test--assert-current-render))))

(ert-deftest ebox-prepared-geometry-respects-important-cascade ()
  "Equal initial values do not let an inline move bypass an important rule."
  (ebox-geometry-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      `(box :width (px 160) :height (lh 8)
            :ecss (("#panel" :left ,(ecss-important '(px 2))))
         (box :id "panel" :position absolute :left (px 2) :top (lh 1)
              :width (px 40) :height (lh 2) :z-index 1 "Panel"))))
    (let ((operation (ebox-geometry-prepare
                      (current-buffer) "panel" [:left :top :z-index])))
      (unless (and operation (ebox-geometry-apply operation [(px 22) (lh 2) 2]))
        (ebox-region-update-geometry "panel" :left '(px 22) :top '(lh 2) :z-index 2))
      (should (equal (plist-get (ebox-region-geometry "panel") :left) '(px 2)))
      (should (equal (plist-get (ebox-region-geometry "panel") :top) '(lh 2)))
      (ebox-geometry-test--assert-current-render))))

(ert-deftest ebox-prepared-geometry-crosses-flow-stacking-and-visible-clip ()
  "Prepared z and position changes preserve occlusion across flow and clip edges."
  (ebox-geometry-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(box :width (px 160) :height (lh 5)
         (box :id "flow" :width (px 160) :height (lh 2) "FLOW000000000000")
         (box :id "panel" :position absolute :left (px 2) :top (lh 1)
              :width (px 40) :height (lh 2) :z-index 1 :help-echo "panel" "Panel"))))
    (let ((operation (ebox-geometry-prepare
                      (current-buffer) "panel" [:left :top :z-index])))
      (should operation)
      (dolist (values '([(px 2) (lh 1) -1]
                        [(px 12.5) (lh 1.5) 3]
                        [(px -12) (lh -1) 3]
                        [(px 150) (lh 4) 3]
                        [(px 2) (lh 1) 1]))
        (should (ebox-geometry-apply operation values))
        (ebox-geometry-test--assert-current-render)))))

(ert-deftest ebox-prepared-geometry-switches-target-with-current-pixels ()
  "Preparing another target after a move never recovers stale canvas pixels."
  (ebox-geometry-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-geometry-test--input))
    (let ((first (ebox-geometry-prepare
                  (current-buffer) "panel" [:left :top :z-index])))
      (should first)
      (let ((replacement (ebox-geometry-prepare
                          (current-buffer) "panel" [:left :top :z-index])))
        (should replacement)
        (should-not (ebox-geometry-valid-p first))
        (should-not (ebox-geometry-apply first [(px 99) (lh 3) 2]))
        (setq first replacement))
      (should (ebox-geometry-prepare (current-buffer) "peer" [:left :top :z-index]))
      (should (ebox-geometry-valid-p first))
      (should (ebox-geometry-apply first [(px 30) (lh 3) 2]))
      (ebox-geometry-test--assert-current-render)
      (let ((second (ebox-geometry-prepare
                     (current-buffer) "peer" [:left :top :z-index])))
        (should second)
        (should (ebox-geometry-apply second [(px 70) (lh 2) 3])))
      (should (equal (plist-get (ebox-region-geometry "panel") :left) '(px 30)))
      (should (ebox-geometry-valid-p first))
      (should (ebox-geometry-apply first [(px 34) (lh 1) 4]))
      (ebox-geometry-test--assert-current-render))))

(ert-deftest ebox-prepared-geometry-declines-root-without-containing-plane ()
  "A standalone absolute root declines preparation and keeps ordinary updates."
  (ebox-geometry-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build '(box :id "root" :position absolute :left (px 0) :top (lh 0)
                      :width (px 40) :height (lh 2) "Root")))
    (should-not (ebox-geometry-prepare (current-buffer) "root" [:left :top]))
    (ebox-region-update-geometry "root" :left '(px 12))
    (should (equal (plist-get (ebox-region-geometry "root") :left) '(px 12)))
    (ebox-geometry-test--assert-current-render)))

(defun ebox-geometry-test--reject-display-change (change &optional setup)
  "Verify prepared publication rejects CHANGE after optional display SETUP."
  (ebox-geometry-test--with-buffer
    (when setup (funcall setup))
    (ebox-render-to-buffer (current-buffer) (ebox-geometry-test--input))
    (let* ((staged 0)
           (operation (ebox-geometry-prepare
                       (current-buffer) "panel" [:left :top :z-index]
                       (lambda () (setq staged (1+ staged))) #'ignore))
           (before (buffer-string))
           (revision (ebox-surface-buffer-revision (current-buffer)))
           (report (ebox-buffer-update-report (current-buffer)))
           (bounds (ebox-host-ref-bounds (current-buffer) "panel")))
      (should operation)
      (funcall change)
      (should (null (ebox-geometry-valid-p operation)))
      (should (null (ebox-geometry-apply operation [(px 12) (lh 3) 4])))
      (should (= staged 0))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (equal report (ebox-buffer-update-report (current-buffer))))
      (should (equal bounds (ebox-host-ref-bounds (current-buffer) "panel")))
      (should (equal-including-properties before (buffer-string)))
      (should (equal (plist-get (ebox-region-geometry "panel") :left) '(px 2)))
      ;; Repreparation cannot bless raster data from the previous display.
      (should (null (ebox-geometry-prepare (current-buffer) "panel" [:left :top :z-index]))))
    (ebox-rerender-buffer-with-context (current-buffer) 160 12)
    (let ((operation (ebox-geometry-prepare (current-buffer) "panel" [:left :top :z-index])))
      (should operation)
      (should (ebox-geometry-apply operation [(px 12) (lh 3) 4]))
      (ebox-geometry-test--assert-current-render))))

(ert-deftest ebox-prepared-geometry-rejects-changed-text-scale ()
  "Buffer-local text scaling invalidates prepared pixels before any callback."
  (ebox-geometry-test--reject-display-change
   (lambda () (text-scale-set 2)) (lambda () (text-scale-set 0))))

(ert-deftest ebox-prepared-geometry-rejects-changed-face-remapping ()
  "Changing an existing remapping invalidates its retained display proof."
  (ebox-geometry-test--reject-display-change
   (lambda () (face-remap-add-relative 'default :height 1.4))
   (lambda () (face-remap-add-relative 'default :height 1.1))))

(provide 'ebox-geometry-tests)
;;; ebox-geometry-tests.el ends here
