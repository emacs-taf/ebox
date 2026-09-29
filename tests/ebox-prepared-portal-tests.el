;;; ebox-prepared-portal-tests.el --- Fixed portal publication -*- lexical-binding: t; -*-

;;; Commentary:
;; Independent content updates preserve root portal occlusion and input owners.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-prepared-portal-test--input (label-map portal-map &optional anchor)
  "Build an independent label and root portal with LABEL-MAP and PORTAL-MAP.
ANCHOR makes the portal depend on the label instead of fixed placement."
  (ebox-build
   `(box :id "canvas" :width (ch 30) :height (lh 5)
      (box :id "pane" :position absolute :left (ch 0) :top (lh 1)
           :width (ch 18) :height (lh 1) :z-index 1
        (text :id "label" :keymap ,label-map :help-echo "label" "ABCDEFGHIJKLMNOPQR"))
      (box :id "portal-owner" :width (ch 1) :height (lh 1)
        (box :id "portal" :position absolute :layer root
             :left (ch 3) :top (lh 1) :width (ch 6) :height (lh 1) :z-index 10
             ,@(when anchor '(:anchor "label"))
             :keymap ,portal-map :help-echo "portal"
          (text :id "portal-text" "PORTAL"))))))

(defun ebox-prepared-portal-test--assert-fresh ()
  "Compare committed pixels, input properties and bounds with a fresh mount."
  (let ((live (current-buffer))
        (input (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input)))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) input)
      (let ((expected (buffer-string))
            (actual (with-current-buffer live (buffer-string))))
        (should (equal (substring-no-properties expected) (substring-no-properties actual)))
        (dotimes (position (length actual))
          (dolist (property '(display face font-lock-face help-echo keymap pointer mouse-face))
            (should (equal (get-text-property position property expected)
                           (get-text-property position property actual))))))
      (dolist (ref '("canvas" "pane" "label" "portal-owner" "portal" "portal-text"))
        (should (equal (ebox-host-ref-bounds live ref)
                       (ebox-host-ref-bounds (current-buffer) ref)))))))

(defun ebox-prepared-portal-test--activate (text owner)
  "Activate native input at visible TEXT and verify its declared OWNER."
  (goto-char (point-min))
  (search-forward text)
  (goto-char (- (point) (length text)))
  (should (equal owner (get-text-property (point) 'help-echo)))
  (let ((command (lookup-key (get-text-property (point) 'keymap) (kbd "RET"))))
    (should (commandp command))
    (call-interactively command)))

(ert-deftest ebox-prepared-content-keeps-fixed-portal-occlusion-and-input ()
  "Content below a fixed portal keeps visible coverage, input and later reveal."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 8)
        (label-presses 0) (portal-presses 0))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-prepared-portal-test--input
        (ebox-keymap-create :activate (lambda () (cl-incf label-presses)))
        (ebox-keymap-create :activate (lambda () (cl-incf portal-presses)))))
      (let* ((operation (ebox-update-prepare (current-buffer) [["label" [:content]]]))
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (dolist (value '("abcdefghijklmnopqr" "012345678901234567"))
          (should (ebox-update-apply operation (vector (vector value)) [0]))
          (should (eq (plist-get (ebox-buffer-update-report (current-buffer)) :projection-kind)
                      'prepared-update))
          (should (= (cl-incf revision) (ebox-surface-buffer-revision (current-buffer))))
          (should (string-match-p "PORTAL" (buffer-substring-no-properties (point-min) (point-max))))
          (ebox-prepared-portal-test--assert-fresh)
          (ebox-prepared-portal-test--activate "PORTAL" "portal")
          (ebox-prepared-portal-test--activate (substring value 0 3) "label"))
        (should (= label-presses 2))
        (should (= portal-presses 2))
        ;; The public geometry entry cannot reuse this content-only scene.
        (should-not (ebox-geometry-prepare (current-buffer) "pane" [:left :top :z-index]))
        (should (ebox-update-valid-p operation))
        ;; Ordinary movement reveals the newest retained text and invalidates
        ;; the old operation.  A new cohort binds the newly accepted portal.
        (ebox-region-update "portal" :left '(ch 20))
        (should-not (ebox-update-valid-p operation))
        (should-not (ebox-update-apply operation [["stale"]] [0]))
        (should (string-match-p "012345678901234567"
                                (buffer-substring-no-properties (point-min) (point-max))))
        (ebox-prepared-portal-test--assert-fresh)
        (setq operation (ebox-update-prepare (current-buffer) [["label" [:content]]]))
        (should operation)
        (should (ebox-update-apply operation [["RSTUVWXYZabcdefghi"]] [0]))
        (ebox-prepared-portal-test--activate "RST" "label")
        (ebox-prepared-portal-test--activate "PORTAL" "portal")
        (ebox-prepared-portal-test--assert-fresh)
        (ebox-region-update "portal" :left '(ch 3))
        (should-not (ebox-update-valid-p operation))
        (ebox-prepared-portal-test--assert-fresh)
        (should (= label-presses 3))
        (should (= portal-presses 3))
        ;; Fully occluded content still advances its source.  Revealing it
        ;; through an ordinary publication must show the newest accepted text.
        (ebox-region-update "portal" :left '(ch 0) :width '(ch 18))
        (should-not (ebox-host-ref-bounds (current-buffer) "label"))
        (setq operation (ebox-update-prepare (current-buffer) [["label" [:content]]]))
        (should operation)
        (should (ebox-update-apply operation [["Hidden but current"]] [0]))
        (should-not (ebox-host-ref-bounds (current-buffer) "label"))
        (ebox-prepared-portal-test--assert-fresh)
        (ebox-region-update "portal" :visibility 'hidden)
        (should-not (ebox-update-valid-p operation))
        (should (string-match-p "Hidden but current"
                                (buffer-substring-no-properties (point-min) (point-max))))
        (ebox-prepared-portal-test--assert-fresh)
        (setq operation (ebox-update-prepare (current-buffer) [["label" [:content]]]))
        (should operation)
        (should (ebox-update-apply operation [["Visible and latest"]] [0]))
        (ebox-region-update "portal" :visibility 'visible :left '(ch 3) :width '(ch 6))
        (should-not (ebox-update-valid-p operation))
        (ebox-prepared-portal-test--assert-fresh)))))

(ert-deftest ebox-prepared-content-rolls-back-beneath-fixed-portal ()
  "Rejected content restores source, pixels, bounds and portal input exactly."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 8)
        (reject t) (caller 'before) (pressed 0))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-prepared-portal-test--input
        nil (ebox-keymap-create :activate (lambda () (cl-incf pressed)))))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["label" [:content]]]
               (lambda () (setq caller 'after) (when reject (error "Reject content")))
               (lambda () (setq caller 'before))))
             (before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer)))
             (bounds (ebox-host-ref-bounds (current-buffer) "portal")))
        (should operation)
        (should-error (ebox-update-apply operation [["abcdefghijklmnopqr"]] [0]))
        (should (eq caller 'before))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (should (equal bounds (ebox-host-ref-bounds (current-buffer) "portal")))
        (ebox-prepared-portal-test--assert-fresh)
        (ebox-prepared-portal-test--activate "PORTAL" "portal")
        (should (= pressed 1))
        (setq reject nil)
        (should (ebox-update-apply operation [["abcdefghijklmnopqr"]] [0]))
        (should (eq caller 'after))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (ebox-prepared-portal-test--assert-fresh)))))

(ert-deftest ebox-prepared-content-rejects-portal-members-and-anchors ()
  "Unsafe members are identified so independent content can prepare separately."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 8))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-portal-test--input nil nil))
      (dolist (spec '(["portal" [:content]] ["portal-text" [:content]]
                     ["portal-owner" [:content]] ["canvas" [:content]]
                     ["pane" [:left]] ["label" [:color]] ["label" [:class]]))
        (let ((before (buffer-string))
              (revision (ebox-surface-buffer-revision (current-buffer))))
          (should-not (ebox-update-prepare (current-buffer)
                                          (vector ["label" [:content]] spec)))
          (let ((report (ebox-update-prepare-report (current-buffer))))
            (should (eq (plist-get report :status) 'unsupported))
            (should (= (plist-get report :member) 1)))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string)))))
      (should (ebox-update-prepare (current-buffer) [["label" [:content]]]))
      ;; The same guard applies when a valid shared scene is already present.
      (should-not (ebox-update-prepare (current-buffer) [["portal-text" [:content]]]))
      (should-not (ebox-geometry-prepare (current-buffer) "pane" [:left]))
      (ebox-commit (current-buffer) (ebox-prepared-portal-test--input nil nil t))
      (should-not (ebox-update-prepare (current-buffer) [["label" [:content]]]))
      (should (eq (plist-get (plist-get (ebox-update-prepare-report (current-buffer)) :detail)
                             :reason)
                  'root-portals))
      ;; A Text sibling is independent in the logical tree, but its nearest
      ;; raster owner also contains the portal.  Repainting it is not admitted.
      (ebox-commit
       (current-buffer)
       (ebox-build
        '(box :width (ch 30) :height (lh 5)
           (box :position absolute :left (ch 0) :top (lh 1)
                :width (ch 18) :height (lh 2) :z-index 1
             (text :id "label" "ABCDEFGHIJKLMNOPQR")
             (box :position absolute :layer root :left (ch 3) :top (lh 1)
                  :width (ch 6) :height (lh 1) :z-index 10 "PORTAL")))))
      (should-not (ebox-update-prepare (current-buffer) [["label" [:content]]]))
      (should (= (plist-get (ebox-update-prepare-report (current-buffer)) :member) 0)))))

(provide 'ebox-prepared-portal-tests)
;;; ebox-prepared-portal-tests.el ends here
