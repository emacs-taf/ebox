;;; ebox-retained-paint-tests.el --- Retained paint contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Check paint, source authority and publication through the public cohort API.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-retained-paint-test--mount ()
  "Mount overlapping panes with inherited, explicit and caller-owned faces."
  (ebox-render-to-buffer
   (current-buffer)
   (ebox-build
    `(box :width (ch 36) :height (lh 8)
       (box :id "pane" :position absolute :left (ch 1) :top (lh 1)
            :width (ch 22) :height (lh 4) :z-index 1
            :color "#334455" :background-color "#EEEEEE"
            :border ((px 1) solid "#445566")
         (column
          (text :id "title" :color "#334455" :font-weight normal
                :hover-style (:background-color "#FFEEAA") "Title")
          (row (text "Inherited") (text :color "#AA0022" "Own"))
          (text ,(propertize "Caller" 'face '(:foreground "#22AA44" :underline t)))))
       (box :id "cover" :position absolute :left (ch 2) :top (lh 2)
            :width (ch 15) :height (lh 2) :z-index 2 :background-color "#CCCCCC"
         (text "Cover"))))))

(defun ebox-retained-paint-test--fresh ()
  "Assert visible pixels and native properties equal a fresh canonical render."
  (let ((actual (buffer-string))
        (expected (ebox-render (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))))
    (should (equal (substring-no-properties actual) (substring-no-properties expected)))
    (dotimes (position (length actual))
      (dolist (property '(face font-lock-face display keymap mouse-face pointer help-echo))
        (should (equal (get-text-property position property actual)
                       (get-text-property position property expected)))))))

(ert-deftest ebox-retained-paint-preserves-inheritance-and-occluded-raster ()
  "Paint behind a cover survives movement, including inherited and caller faces."
  (let ((ebox-viewport-width 288) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-retained-paint-test--mount)
      (let ((operation (ebox-update-prepare
                        (current-buffer)
                        [["pane" [:color :background-color :border]]
                         ["cover" [:left]] ["title" [:color]]]))
            (values [["#113377" "#FFF0CC" ((px 1) solid "#CC5511")]
                     [(ch 25)] ["#441188"]]))
        (should operation)
        (should (ebox-update-apply operation values [0 2]))
        (ebox-retained-paint-test--fresh)
        (should (ebox-update-apply operation values [1]))
        (ebox-retained-paint-test--fresh)
        (aset values 0 ["#667722" "#DDEEFF" ((px 1) solid "#1166AA")])
        (should (ebox-update-apply operation values [0]))
        (ebox-retained-paint-test--fresh)
        (aset values 1 [(ch 2)])
        (should (ebox-update-apply operation values [1]))
        (ebox-retained-paint-test--fresh)))))

(ert-deftest ebox-retained-paint-rolls-back-and-validates-participant-edits ()
  "Failed paint restores source and raster; external buffer writes still reject."
  (let ((ebox-viewport-width 288) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-retained-paint-test--mount)
      (let* ((reject t) (mutate nil) (caller 'before)
             (operation
              (ebox-update-prepare
               (current-buffer) [["pane" [:color :background-color]]]
               (lambda ()
                 (setq caller 'after)
                 (when mutate
                   (let ((inhibit-read-only t))
                     (add-text-properties (point-min) (1+ (point-min)) '(face (:foreground "red")))))
                 (when reject (error "Reject paint")))
               (lambda () (setq caller 'before))))
             (values [["#226644" "#EEDDCC"]])
             (before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should-error (ebox-update-apply operation values [0]))
        (should (eq caller 'before))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (ebox-retained-paint-test--fresh)
        (setq reject nil mutate t)
        (should-error (ebox-update-apply operation values [0]))
        (should (equal-including-properties before (buffer-string)))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (setq mutate nil)
        (should (ebox-update-apply operation values [0]))
        (ebox-retained-paint-test--fresh)
        (aset values 0 ["#991144" "#CCEEFF"])
        (should (ebox-update-apply operation values [0]))
        (ebox-retained-paint-test--fresh)))))

(ert-deftest ebox-retained-paint-follows-content-and-font-replacement ()
  "Ordinary text/font updates refresh the baseline for subsequent colours."
  (let ((ebox-viewport-width 288) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-retained-paint-test--mount)
      (let ((operation (ebox-update-prepare
                        (current-buffer)
                        [["pane" [:color]] ["title" [:content :font-weight]]]))
            (values [["#113366"] ["Replaced" bold]]))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (should (ebox-update-apply operation values [1]))
        (ebox-retained-paint-test--fresh)
        (aset values 0 ["#882211"])
        (should (ebox-update-apply operation values [0]))
        (ebox-retained-paint-test--fresh)
        (aset values 1 ["Title" normal])
        (should (ebox-update-apply operation values [1]))
        (ebox-retained-paint-test--fresh)))))

(ert-deftest ebox-retained-paint-composes-proved-placement-and-stacking ()
  "One paint/move/raise transaction preserves occlusion, source and rollback."
  (let ((ebox-viewport-width 288) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-retained-paint-test--mount)
      (let* ((reject nil)
             (operation
              (ebox-update-prepare
               (current-buffer) [["pane" [:left :top :z-index :color :border]]]
               (lambda () (when reject (error "Reject moved paint"))) #'ignore))
             (values [[(ch 3) (lh 2) 3 "#225588" ((px 1) solid "#CC3311")]]))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (ebox-retained-paint-test--fresh)
        (let ((before (buffer-string))
              (revision (ebox-surface-buffer-revision (current-buffer))))
          (setq reject t)
          (aset values 0 [(ch 1) (lh 1) 1 "#885522" ((px 1) solid "#1177BB")])
          (should-error (ebox-update-apply operation values [0]))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string)))
          (ebox-retained-paint-test--fresh))
        (setq reject nil)
        (should (ebox-update-apply operation values [0]))
        (ebox-retained-paint-test--fresh)
        (aset values 0 [(ch 5) (lh 1) 4 "#449922" ((px 1) solid "#6622AA")])
        (should (ebox-update-apply operation values [0]))
        (ebox-retained-paint-test--fresh)))))

(provide 'ebox-retained-paint-tests)
;;; ebox-retained-paint-tests.el ends here
