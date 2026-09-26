;;; ebox-prepared-resize-tests.el --- Public retained crop resize -*- lexical-binding: t; -*-

;;; Commentary:
;; Compare resized mounted output against ordinary rendering of exported input.
;; Preparation and rejection must leave the same source, display and revision.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-resize-test--input (&optional wrap activate)
  "Build a fixed plane with WRAP, ACTIVATE and an independently owned peer."
  (ebox-build
   `(box :width (px 240) :height (lh 12) :background-color "#EAF0F6"
      (box :id "crop" :position absolute :left (px 8) :top (lh 2)
           :width (px 96) :height (lh 4) :min-width (px 0) :min-height (lh 0)
           :overflow hidden
           :wrap-mode ,(or wrap 'none) :background-color "#243447"
           :color "#F1F5F9" :z-index 2 :tab-index 0
           :keymap ,(ebox-keymap-create :activate (or activate #'ignore))
        "Fixed text abcdefghijklmnopqrstuvwxyz\nSecond row\nThird row")
      (box :id "peer" :position absolute :left (px 130) :top (lh 3)
           :width (px 80) :height (lh 4) :z-index 1
           :background-color "#705070" "Independent peer"))))

(defun ebox-resize-test--assert-fresh ()
  "Check live text, ownership-independent paint and native input properties."
  (let* ((actual (buffer-string))
         (expected (ebox-render (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))))
    (should (equal (substring-no-properties actual) (substring-no-properties expected)))
    (dotimes (position (length actual))
      (dolist (property '(face display font-lock-face keymap help-echo pointer mouse-face))
        (should (equal (get-text-property position property actual)
                       (get-text-property position property expected)))))))

(ert-deftest ebox-prepared-resize-crops-and-restores-fixed-text ()
  "Width and height changes publish source facts and restore clipped text."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-resize-test--input))
      (let* ((saved (ebox-surface-buffer-snapshot (current-buffer)))
             (saved-text (ebox-render (plist-get saved :input)))
             (operation (ebox-geometry-prepare (current-buffer) "crop" [:width :height :left :top])))
        (should operation)
        (dolist (values '([(px 152) (lh 6) (px 8) (lh 2)]
                          [(px 64) (lh 2) (px 16) (lh 3)]
                          [(px 200) (lh 5) (px 4) (lh 1)]
                          [(px 96) (lh 4) (px 8) (lh 2)]))
          (let ((revision (ebox-surface-buffer-revision (current-buffer))))
            (should (ebox-geometry-apply operation values))
            (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
            (should (equal (plist-get (ebox-region-geometry "crop") :width) (aref values 0)))
            (should (equal (plist-get (ebox-region-geometry "crop") :height) (aref values 1)))
            (ebox-resize-test--assert-fresh)))
        (should (equal-including-properties saved-text (ebox-render (plist-get saved :input))))))))

(ert-deftest ebox-prepared-resize-rolls-back-and-retries ()
  "A rejected resize restores its accepted pixels, source and caller state."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-resize-test--input))
      (let* ((reject t) (accepted nil)
             (operation (ebox-geometry-prepare
                         (current-buffer) "crop" [:width :height]
                         (lambda () (setq accepted t) (when reject (error "Reject resize")))
                         (lambda () (setq accepted nil))))
             (before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should-error (ebox-geometry-apply operation [(px 160) (lh 7)]))
        (should-not accepted)
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (ebox-resize-test--assert-fresh)
        (setq reject nil)
        (should (ebox-geometry-apply operation [(px 160) (lh 7)]))
        (should accepted)
        (ebox-resize-test--assert-fresh)))))

(defun ebox-resize-test--framed-input (&optional width height)
  "Build a plane holding a framed flex panel WIDTH by HEIGHT with a body peer."
  (ebox-build
   `(box :width (px 400) :height (lh 14) :background-color "#EAF0F6"
      (box :id "frame" :position absolute :left (px 8) :top (lh 1)
           :width (px ,(or width 200)) :height (lh ,(or height 6))
           :background-color "#243447" :color "#F1F5F9" :z-index 2
           (flex :flex-direction row :justify-content space-between :align-items center
             (box :width (px 24) "x")
             (box :flex 1 :text-align center "Panel title")
             (box :width (px 24) "o"))
           (box "Body line")
           (box "Footer"))
      (box :id "peer" :position absolute :left (px 300) :top (lh 3)
           :width (px 80) :height (lh 4) :z-index 1
           :background-color "#705070" "Independent peer"))))

(ert-deftest ebox-prepared-resize-framed-panel-matches-fresh-render-at-every-size ()
  "Repeated framed panel resizes equal fresh renders across parities and limits."
  (let ((ebox-viewport-width 400) (ebox-viewport-height 14))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-resize-test--framed-input))
      (let ((operation (ebox-update-prepare (current-buffer) [["frame" [:width :height]]])))
        (should operation)
        (dolist (value '([(px 208) (lh 6)] [(px 216) (lh 6)] [(px 217) (lh 6)] [(px 224) (lh 6)]
                         [(px 224) (lh 7)] [(px 224) (lh 9)] [(px 224) (lh 4)] [(px 224) (lh 3)]
                         [(px 232) (lh 5)] [(px 300) (lh 12)] [(px 60) (lh 3)] [(px 61) (lh 2)]
                         [(px 200) (lh 6)] [(px 391) (lh 6)] [(px 392) (lh 13)] [(px 200) (lh 6)]))
          (should (ebox-update-apply operation (vector value) [0]))
          (should (equal (plist-get (ebox-region-geometry "frame") :width) (aref value 0)))
          (should (equal (plist-get (ebox-region-geometry "frame") :height) (aref value 1)))
          (ebox-resize-test--assert-fresh))))))

(ert-deftest ebox-prepared-resize-framed-panel-follows-paint-between-resizes ()
  "Paint and content changes between framed resizes appear in later sizes."
  (let ((ebox-viewport-width 400) (ebox-viewport-height 14))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-resize-test--framed-input))
      (let ((operation (ebox-update-prepare
                        (current-buffer) [["frame" [:width :height :background-color :color]]])))
        (should operation)
        (dolist (step '(([(px 208) (lh 6) "#243447" "#F1F5F9"] [0])
                        ([(px 216) (lh 7) "#243447" "#F1F5F9"] [0])
                        ([(px 216) (lh 7) "#304050" "#F1F5F9"] [0])
                        ([(px 224) (lh 8) "#304050" "#F1F5F9"] [0])
                        ([(px 232) (lh 8) "#304050" "#FFD700"] [0])
                        ([(px 240) (lh 5) "#304050" "#FFD700"] [0])
                        ([(px 200) (lh 6) "#243447" "#F1F5F9"] [0])))
          (should (ebox-update-apply operation (vector (car step)) (cadr step)))
          (ebox-resize-test--assert-fresh))))))

(ert-deftest ebox-prepared-resize-framed-panel-rolls-back-after-replayed-sizes ()
  "A rejected framed resize after accepted ones restores its exact pixels."
  (let ((ebox-viewport-width 400) (ebox-viewport-height 14))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-resize-test--framed-input))
      (let* ((reject nil) (accepted nil)
             (operation (ebox-update-prepare
                         (current-buffer) [["frame" [:width :height]]]
                         (lambda () (setq accepted t) (when reject (error "Reject resize")))
                         (lambda () (setq accepted nil)))))
        (should operation)
        (dolist (value '([(px 208) (lh 6)] [(px 216) (lh 7)] [(px 224) (lh 8)]))
          (should (ebox-update-apply operation (vector value) [0]))
          (ebox-resize-test--assert-fresh))
        (let ((before (buffer-string))
              (revision (ebox-surface-buffer-revision (current-buffer))))
          (setq reject t)
          (should-error (ebox-update-apply operation (vector [(px 232) (lh 9)]) [0]))
          (should-not accepted)
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string)))
          (ebox-resize-test--assert-fresh)
          (setq reject nil)
          (should (ebox-update-apply operation (vector [(px 232) (lh 9)]) [0]))
          (should accepted)
          (ebox-resize-test--assert-fresh))))))

(ert-deftest ebox-prepared-resize-declines-unproved-layout-and-capacity ()
  "Wrapping and dimensions beyond a prepared canvas never silently crop."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 12))
    (dolist (wrap '(none word))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) (ebox-resize-test--input wrap))
        (let* ((operation (ebox-geometry-prepare (current-buffer) "crop" [:width :height]))
               (before (buffer-string))
               (revision (ebox-surface-buffer-revision (current-buffer))))
          (should operation)
          (should-not (ebox-geometry-apply operation
                                          (if (eq wrap 'none) [(px 241) (lh 4)] [(px 160) (lh 4)])))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string)))
          (ebox-resize-test--assert-fresh))))))

(ert-deftest ebox-prepared-resize-cohort-mixes-size-and-paint ()
  "A mixed cohort resizes and repaints the same retained text panel."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-resize-test--input))
      (let ((operation (ebox-update-prepare
                        (current-buffer) [["crop" [:width :height :background-color]]])))
        (should operation)
        (dolist (value '([(px 160) (lh 7) "#304050"]
                         [(px 64) (lh 2) "#405060"]
                         [(px 192) (lh 6) "#506070"]))
          (should (ebox-update-apply operation (vector value) [0]))
          (ebox-resize-test--assert-fresh))))))

(ert-deftest ebox-prepared-resize-survives-appended-peer-primitives ()
  "A crop keeps working after a peer's growing footprint appends primitives."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-resize-test--input))
      (let ((operation (ebox-update-prepare
                        (current-buffer) [["peer" [:height]] ["crop" [:width :height]]])))
        (should operation)
        (should (ebox-update-apply operation (vector [(lh 8)] [(px 96) (lh 4)]) [0]))
        (ebox-resize-test--assert-fresh)
        (dolist (value '([(px 160) (lh 6)] [(px 64) (lh 2)] [(px 96) (lh 4)]))
          (should (ebox-update-apply operation (vector [(lh 8)] value) [1]))
          (ebox-resize-test--assert-fresh))
        (should (ebox-update-apply operation (vector [(lh 4)] [(px 96) (lh 4)]) [0]))
        (ebox-resize-test--assert-fresh)))))

(ert-deftest ebox-prepared-resize-keeps-focus-and-native-activation ()
  "Resize keeps the focused native target and its current activation binding."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 12) (pressed 0))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer)
                            (ebox-resize-test--input nil (lambda () (cl-incf pressed))))
      (let* ((operation (ebox-geometry-prepare (current-buffer) "crop" [:width :height]))
             (ref (ebox-focus-first)))
        (should operation)
        (dolist (values '([(px 160) (lh 7)] [(px 64) (lh 2)] [(px 192) (lh 6)]))
          (should (ebox-geometry-apply operation values))
          (should (equal ref (ebox-focused-host-ref)))
          (should (ebox-host-ref-bounds (current-buffer) ref))
          (let ((command (key-binding (kbd "RET"))))
            (should (commandp command))
            (call-interactively command))
          (ebox-resize-test--assert-fresh))
        (should (= pressed 3))))))

(ert-deftest ebox-prepared-resize-preserves-shaped-text-and-replacement-spaces ()
  "Repeated non-cell-aligned crops retain glyphs, spaces and replacement content."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-resize-test--input))
      (dolist (text (list (concat "ÁV ffi 中文 "
                                  (propertize " " 'display '(space :width (13)))
                                  "right hand text\nSecond row")
                          "Changed text Ω λ é\nNew source after invalidation"))
        (ebox-region-update "crop" :content text)
        (let ((operation (ebox-geometry-prepare (current-buffer) "crop" [:width :height])))
          (should operation)
          (dolist (width '(73 121 39 199 96))
            (should (ebox-geometry-apply operation (vector (list 'px width) '(lh 4))))
            (ebox-resize-test--assert-fresh)))))))

(provide 'ebox-prepared-resize-tests)
;;; ebox-prepared-resize-tests.el ends here
