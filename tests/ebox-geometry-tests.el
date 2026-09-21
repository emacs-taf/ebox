;;; ebox-geometry-tests.el --- Public geometry update contract -*- lexical-binding: t; -*-

;;; Commentary:
;; Verify the low-level Box geometry query and incremental update boundary.
;; Gesture and window-management policy intentionally remain outside Ebox.

;;; Code:
(require 'ert)
(require 'cl-lib)
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

(provide 'ebox-geometry-tests)
;;; ebox-geometry-tests.el ends here
