;;; ebox-prepared-publication-tests.el --- Prepared publication behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise compiled geometry through supported source, publication and query APIs.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defmacro ebox-prepared-publication-test--with-buffer (&rest body)
  "Run BODY in a fresh mounted-buffer context with the Elisp backend."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
              (lambda () nil)))
     (let ((ebox-viewport-width 160) (ebox-viewport-height 12))
       (with-temp-buffer ,@body))))

(defun ebox-prepared-publication-test--input (&optional multi-row extra-host native-map
                                                       moving-style)
  "Build overlapping panels with explicit public Host identities.
MULTI-ROW gives the moving panel three unequal text rows in a taller surface.
EXTRA-HOST inserts another independently addressable positioned panel.
NATIVE-MAP enables the moving panel's native input and logical focus.
MOVING-STYLE appends declarations to the moving panel's style."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((box (identity style children &optional help)
           (let* ((declarations (ebox-style-compile-form 'box style))
                  (interactions (append (and help (list :help-echo help))
                                        (when (and native-map (eq identity 'moving))
                                          (list :keymap native-map :tab-index 0))))
                  (handle (ebox-source-builder-bind
                           builder :identity identity :key identity :id identity
                           :declarations declarations :interactions interactions)))
             (apply #'ebox-box-create
                    (append
                     (ebox-canonical-box-configuration 'box declarations)
                     (list :source-handle handle :source-builder builder
                           :owned-facts (ebox-canonical-facts-from-declarations
                                         'box declarations interactions)
                           :children
                           (if (stringp children)
                               (list (ebox-text-create
                                      :value children :source-handle
                                      (ebox-source-builder-bind
                                       builder :identity (list identity 'text))
                                      :owned-facts
                                      (ebox-canonical-facts-from-declarations 'text nil)))
                             children)))))))
      (let* ((lower (box 'covered
                         '(:position absolute :left (ch 0) :top (lh 1)
                           :width (ch 8) :height (lh 1) :z-index 1)
                         "LOWER001" "lower"))
             (upper (box 'moving
                         `(:position absolute :left (ch 0) :top (lh 1)
                           :width (ch 8) :height (lh ,(if multi-row 3 1)) :z-index 2
                           ,@moving-style)
                         (if multi-row "UPPER001\nMIDDLE\nZ" "UPPER001") "upper"))
             (extra (and extra-host
                         (box 'inserted
                              '(:position absolute :left (ch 10) :top (lh 1)
                                :width (ch 8) :height (lh 1) :z-index 3)
                              "EXTRA001" "inserted")))
             (root (box 'surface
                        `(:width (ch 20) :height (lh ,(if multi-row 12 5))
                          :padding ((lh 1) (ch 1))
                          :border ((px 1) solid "#778899"))
                        (if extra (list lower upper extra) (list lower upper)) "surface")))
        (ebox-canonical-input-create
         (list root) (ebox-source-builder-finish builder))))))

(defun ebox-prepared-publication-test--assert-authority ()
  "Compare live pixels, native interactions and Host bounds with a fresh mount."
  (let ((live (current-buffer))
        (input (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input)))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) input)
      (let ((expected (buffer-string))
            (actual (with-current-buffer live (buffer-string))))
        (should (equal (substring-no-properties actual)
                       (substring-no-properties expected)))
        (dotimes (position (length actual))
          (dolist (property '(display face font-lock-face help-echo keymap pointer mouse-face))
            (should (equal (get-text-property position property actual)
                           (get-text-property position property expected)))))
        (dolist (ref '(surface moving covered))
          (should (equal (ebox-host-ref-bounds live ref)
                         (ebox-host-ref-bounds (current-buffer) ref))))))))

(ert-deftest ebox-prepared-publication-reveals-occluded-host-and-wrapper-bounds ()
  "Prepared moves update exposed Host bounds, interactions and fixed wrapper edges."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (should-not (ebox-host-ref-bounds (current-buffer) 'covered))
    (let ((operation (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index])))
      (should operation)
      (dolist (values '([(ch 10) (lh 1) 2]
                        [(ch 0) (lh 1) 0]
                        [(ch 0) (lh 1) 2]))
        (should (ebox-geometry-apply operation values))
        (ebox-prepared-publication-test--assert-authority)))
    (should-not (ebox-host-ref-bounds (current-buffer) 'covered))))

(ert-deftest ebox-prepared-publication-retries-disjoint-multi-row-moves ()
  "Repeated multi-row moves retain unchanged rows and recover failed publication."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input t))
    (let* ((caller-state 0) (saved-state 0) (accepted 0) reject
           (operation
            (ebox-geometry-prepare
             (current-buffer) 'moving [:left :top :z-index]
             (lambda ()
               (setq caller-state (1+ caller-state))
               (when reject (error "Reject multi-row move")))
             (lambda () (setq caller-state saved-state))
             (lambda () (setq accepted (1+ accepted))))))
      (should operation)
      (dolist (values '([(ch 10) (lh 5) 2]
                        [(ch 4) (lh 1) 2]
                        [(ch 0) (lh 5) 0]
                        [(ch 10) (lh 1) 2]
                        [(ch 0) (lh 1) 2]))
        (let ((before (buffer-string))
              (revision (ebox-surface-buffer-revision (current-buffer)))
              (report (ebox-buffer-update-report (current-buffer)))
              (geometry (ebox-region-geometry 'moving))
              (bounds (mapcar (lambda (ref) (ebox-host-ref-bounds (current-buffer) ref))
                              '(surface moving covered))))
          (setq reject t saved-state caller-state)
          (should-error (ebox-geometry-apply operation values))
          (should (= caller-state saved-state))
          (should (= accepted saved-state))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal report (ebox-buffer-update-report (current-buffer))))
          (should (equal geometry (ebox-region-geometry 'moving)))
          (should (equal-including-properties before (buffer-string)))
          (should (equal bounds
                         (mapcar (lambda (ref) (ebox-host-ref-bounds (current-buffer) ref))
                                 '(surface moving covered))))
          (ebox-prepared-publication-test--assert-authority)
          (should (ebox-geometry-valid-p operation))
          (setq reject nil)
          (should (ebox-geometry-apply operation values))
          (should (= caller-state (1+ saved-state)))
          (should (= accepted caller-state))
          (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
          (should (eq (plist-get (ebox-buffer-update-report (current-buffer))
                                 :projection-kind)
                      'prepared-geometry))
          (ebox-prepared-publication-test--assert-authority))))))

(ert-deftest ebox-prepared-publication-rejects-unrecorded-buffer-hook-rewrite ()
  "A character rewrite in an external hook restores source, pixels, bounds and point."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (let* ((before (buffer-string))
           (revision (ebox-surface-buffer-revision (current-buffer)))
           (bounds (ebox-host-ref-bounds (current-buffer) 'moving))
           (operation (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index]))
           (armed t))
      (goto-char (+ (point-min) 3))
      (let ((before-point (point)))
        (add-hook 'after-change-functions
                  (lambda (&rest _)
                    (when armed
                      (setq armed nil)
                      (let ((inhibit-modification-hooks t) (buffer-undo-list t))
                        (save-excursion
                          (goto-char (point-min))
                          (delete-char 1)
                          (insert "!"))))) nil t)
        (should-error (ebox-geometry-apply operation [(ch 10) (lh 1) 2]))
        (should (= (point) before-point)))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (equal-including-properties before (buffer-string)))
      (should (equal bounds (ebox-host-ref-bounds (current-buffer) 'moving)))
      (should (equal (plist-get (ebox-region-geometry 'moving) :left) '(ch 0)))
      (ebox-prepared-publication-test--assert-authority)
      (should (ebox-geometry-valid-p operation))
      (should (ebox-geometry-apply operation [(ch 10) (lh 1) 2]))
      (ebox-prepared-publication-test--assert-authority))))

(ert-deftest ebox-prepared-publication-reprepares-after-ordinary-paint ()
  "Repreparation preserves ordinary publication authority through a failed retry."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (let ((previous (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index])))
      (should previous)
      (should (ebox-geometry-apply previous [(ch 10) (lh 1) 2]))
      (ebox-region-update 'moving :color "#0088cc")
      (should-not (ebox-geometry-valid-p previous))
      (let* ((before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer)))
             (report (ebox-buffer-update-report (current-buffer)))
             (bounds (ebox-host-ref-bounds (current-buffer) 'moving))
             (mount-id (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :mount-id))
             (caller-state 'before) (reject t)
             (operation
              (ebox-geometry-prepare
               (current-buffer) 'moving [:left :top :z-index]
               (lambda ()
                 (setq caller-state 'after)
                 (when reject (error "Reject reprepared move")))
               (lambda () (setq caller-state 'before)))))
        (should operation)
        (should-not (ebox-geometry-valid-p previous))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (should-error (ebox-geometry-apply operation [(ch 4) (lh 2) 2]))
        (should (eq caller-state 'before))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal report (ebox-buffer-update-report (current-buffer))))
        (should (equal bounds (ebox-host-ref-bounds (current-buffer) 'moving)))
        (should (equal-including-properties before (buffer-string)))
        (should (equal (plist-get (ebox-region-geometry 'moving) :left) '(ch 10)))
        (should (= mount-id
                   (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :mount-id)))
        (ebox-prepared-publication-test--assert-authority)
        (should (ebox-geometry-valid-p operation))
        (setq reject nil)
        (should (ebox-geometry-apply operation [(ch 4) (lh 2) 2]))
        (should (eq caller-state 'after))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (ebox-prepared-publication-test--assert-authority)))))

(ert-deftest ebox-prepared-publication-skips-rows-with-unchanged-pixels ()
  "Restacking a panel that occludes nothing publishes no text or properties.
Every row the panel occupies is recomposited, but rows whose pixels equal the
accepted output are settled without a buffer write."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (let ((operation (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index])))
      (should operation)
      (should (ebox-geometry-apply operation [(ch 10) (lh 1) 2]))
      (let ((before (buffer-string))
            (tick (buffer-modified-tick))
            (revision (ebox-surface-buffer-revision (current-buffer))))
        (should (ebox-geometry-apply operation [(ch 10) (lh 1) 0]))
        (let ((publication (plist-get (ebox-buffer-update-report (current-buffer)) :publication)))
          (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
          (should (= 0 (plist-get publication :text-operations)))
          (should (= 0 (plist-get publication :property-operations)))
          (should (= 0 (plist-get publication :touched-characters))))
        (should (= tick (buffer-modified-tick)))
        (should (equal-including-properties before (buffer-string)))
        (ebox-prepared-publication-test--assert-authority))
      ;; The restacked panel now yields to the covered one where they overlap.
      (should (ebox-geometry-apply operation [(ch 0) (lh 1) 0]))
      (should (> (plist-get (plist-get (ebox-buffer-update-report (current-buffer)) :publication)
                            :touched-characters)
                 0))
      (should (ebox-host-ref-bounds (current-buffer) 'covered))
      (ebox-prepared-publication-test--assert-authority))))

(ert-deftest ebox-prepared-publication-binds-paint-slot-after-spec-update ()
  "A paint slot keeps binding its prepared color cell after its face changes.
Slots are stable face addresses; the specification they carry may differ
between the source declaration and the mounted engine copy."
  (ebox-prepared-publication-test--with-buffer
    (let* ((slot (ebox-paint-slot-create '(:foreground "#336699")))
           (specifications (vector (vector 'moving [:left :top :z-index :color])))
           (values (vector (vector '(ch 0) '(lh 1) 2 slot)))
           (changed (vector 0)))
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-prepared-publication-test--input nil nil nil (list :color slot)))
      (let ((operation (ebox-update-prepare (current-buffer) specifications)))
        (should operation)
        (aset (aref values 0) 0 '(ch 6))
        (should (ebox-update-apply operation values changed))
        (ebox-prepared-publication-test--assert-authority))
      (ebox-paint-slot-apply-updates
       (current-buffer) (list (cons slot '(:foreground "#993366"))))
      (ebox-region-update 'covered :color "#0088cc")
      (let ((operation (ebox-update-prepare (current-buffer) specifications)))
        (should operation)
        (should (eq 'ready (plist-get (ebox-update-prepare-report (current-buffer))
                                      :status)))
        (aset (aref values 0) 0 '(ch 2))
        (should (ebox-update-apply operation values changed))
        (should (equal (plist-get (ebox-region-geometry 'moving) :left) '(ch 2)))
        (ebox-prepared-publication-test--assert-authority)))))

(ert-deftest ebox-prepared-publication-reprepares-after-inserting-host ()
  "An inserted Host invalidates preparation and participates in later occlusion."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (let ((previous (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index])))
      (should previous)
      (should (ebox-geometry-apply previous [(ch 4) (lh 2) 2]))
      (ebox-commit (current-buffer) (ebox-prepared-publication-test--input nil t))
      (should-not (ebox-geometry-valid-p previous))
      (should (ebox-host-ref-bounds (current-buffer) 'inserted))
      (let ((before (buffer-string))
            (revision (ebox-surface-buffer-revision (current-buffer))))
        (should-not (ebox-geometry-apply previous [(ch 10) (lh 1) 4]))
        (should (equal-including-properties before (buffer-string)))
        (should (= revision (ebox-surface-buffer-revision (current-buffer)))))
      (let ((operation (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index])))
        (should operation)
        (should (ebox-geometry-apply operation [(ch 10) (lh 1) 4]))
        (should-not (ebox-host-ref-bounds (current-buffer) 'inserted))
        (ebox-prepared-publication-test--assert-authority)
        (should (ebox-geometry-apply operation [(ch 0) (lh 1) 2]))
        (should (ebox-host-ref-bounds (current-buffer) 'inserted))
        (ebox-prepared-publication-test--assert-authority)))))

(ert-deftest ebox-prepared-publication-retains-source-through-focus-reentry ()
  "Retained focus and context generations resolve source facts after preparation."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (ebox-focus 'moving)
    (ebox-rerender-buffer-with-context (current-buffer) 160 14)
    (let* ((previous (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index]))
           (operation (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index])))
      (should previous)
      (should operation)
      (should-not (ebox-geometry-valid-p previous))
      (should (ebox-geometry-apply operation [(ch 10) (lh 1) 2]))
      (ebox-focus 'covered)
      (should (eq (ebox-focused-host-ref) 'covered))
      (ebox-region-update 'covered :content "EDITED01")
      (should (equal (plist-get (ebox-region-geometry 'moving) :left) '(ch 10)))
      (ebox-prepared-publication-test--assert-authority)
      (setq operation (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index]))
      (should operation)
      (should (ebox-geometry-apply operation [(ch 4) (lh 2) 2]))
      (ebox-focus 'moving)
      (ebox-region-update 'covered :help-echo "changed help")
      (should (eq (ebox-focused-host-ref) 'moving))
      (ebox-prepared-publication-test--assert-authority))))

(ert-deftest ebox-prepared-publication-rebuilds-inherited-paint-on-ordinary-update ()
  "Ordinary updates recompute inherited prepared paint, including after rollback."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(box :width (px 160) :height (lh 6)
         (box :id "panel" :position absolute :left (px 2) :top (lh 1)
              :width (px 60) :height (lh 2) :z-index 1 :color "#334455"
           (text :id "child" "CHILD"))
         (box :id "peer" :position absolute :left (px 80) :top (lh 1)
              :width (px 60) :height (lh 2) :z-index 2 "PEER"))))
    (cl-labels
        ((assert-render ()
           (let ((actual (buffer-string))
                 (expected (ebox-render
                            (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))))
             (should (equal (substring-no-properties actual) (substring-no-properties expected)))
             (dotimes (position (length actual))
               (dolist (property '(display face font-lock-face help-echo))
                 (should (equal (get-text-property position property actual)
                                (get-text-property position property expected))))))))
      (let* ((snapshot (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
             (snapshot-render (ebox-render snapshot))
             (operation (ebox-update-prepare (current-buffer) [["panel" [:color]]])))
        (should operation)
        (should (ebox-update-apply operation [["#0088cc"]] [0]))
        (assert-render)
        (let ((before (buffer-string))
              (revision (ebox-surface-buffer-revision (current-buffer))))
          (should-error
           (ebox-commit (current-buffer)
                        (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input)
                        (lambda (_report) (error "Reject cascade refresh"))))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string))))
        (ebox-region-update "peer" :content "CHANGED")
        (assert-render)
        (should (equal-including-properties snapshot-render (ebox-render snapshot)))
        (setq operation (ebox-update-prepare (current-buffer) [["panel" [:color]]]))
        (should operation)
        (should (ebox-update-apply operation [["#55aa22"]] [0]))
        ;; Even unchanged viewport axes must consume stale inherited styles.
        (ebox-rerender-buffer-with-context (current-buffer) 160 12)
        (assert-render)
        (ebox-region-update "peer" :help-echo "peer help")
        (assert-render)))))

(ert-deftest ebox-prepared-publication-rejects-stage-output-mutation ()
  "Unrecorded stage property writes roll back paired state and the accepted report."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (let* ((before (buffer-string))
           (revision (ebox-surface-buffer-revision (current-buffer)))
           (report (ebox-buffer-update-report (current-buffer)))
           (value 'before) (rewrite t) (accepted 0)
           (operation
            (ebox-geometry-prepare
             (current-buffer) 'moving [:left :top :z-index]
             (lambda ()
               (setq value 'after)
               (when rewrite
                 (let ((inhibit-modification-hooks t) (buffer-undo-list t)
                       (inhibit-read-only t))
                   (put-text-property (point-min) (1+ (point-min)) 'help-echo "tampered"))))
             (lambda () (setq value 'before))
             (lambda () (setq accepted (1+ accepted))))))
      (should-error (ebox-geometry-apply operation [(ch 10) (lh 1) 2]))
      (should (eq value 'before))
      (should (= accepted 0))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (equal report (ebox-buffer-update-report (current-buffer))))
      (should (equal-including-properties before (buffer-string)))
      (should (equal (plist-get (ebox-region-geometry 'moving) :left) '(ch 0)))
      (setq rewrite nil)
      (should (ebox-geometry-apply operation [(ch 10) (lh 1) 2]))
      (should (eq value 'after))
      (should (= accepted 1))
      (ebox-prepared-publication-test--assert-authority)
      (setq rewrite t
            before (buffer-string)
            report (ebox-buffer-update-report (current-buffer))
            revision (ebox-surface-buffer-revision (current-buffer)))
      (should-error (ebox-geometry-apply operation [(ch 0) (lh 1) 2]))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (equal report (ebox-buffer-update-report (current-buffer))))
      (should (equal-including-properties before (buffer-string)))
      (should (equal (plist-get (ebox-region-geometry 'moving) :left) '(ch 10)))
      (should (= accepted 1))
      (ebox-prepared-publication-test--assert-authority))))

(ert-deftest ebox-prepared-publication-snapshots-caller-values-before-hooks ()
  "A hook mutating the caller's reusable vector cannot change the staged source."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (let ((operation (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index]))
          (values (vector (list 'ch 10) (list 'lh 1) 2))
          (armed t))
      (add-hook 'after-change-functions
                (lambda (&rest _)
                  (when armed
                    (setq armed nil)
                    (setcar (cdr (aref values 0)) 19)
                    (aset values 2 -9))) nil t)
      (should (ebox-geometry-apply operation values))
      (should-not armed)
      (should (equal (aref values 0) '(ch 19)))
      (should (equal (plist-get (ebox-region-geometry 'moving) :left) '(ch 10)))
      (should (= (plist-get (ebox-region-geometry 'moving) :z-index) 2))
      (ebox-prepared-publication-test--assert-authority))))

(ert-deftest ebox-prepared-publication-follows-focus-unless-point-moved-manually ()
  "Logical focus follows accepted translation while manual point stays independent."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (ebox-focus 'moving)
    (let ((operation (ebox-geometry-prepare (current-buffer) 'moving [:left :top :z-index])))
      (should operation)
      (should (ebox-geometry-apply operation [(ch 10) (lh 1) 2]))
      (should (eq (ebox-focused-host-ref) 'moving))
      (should (= (point) (ebox-host-ref-position (current-buffer) 'moving)))
      (goto-char (point-min))
      (let ((manual-point (point)))
        (should (ebox-geometry-apply operation [(ch 8) (lh 2) 2]))
        (should (= (point) manual-point))
        (should (eq (ebox-focused-host-ref) 'moving)))
      (goto-char (ebox-host-ref-position (current-buffer) 'moving))
      (should (ebox-geometry-apply operation [(ch 4) (lh 1) 2]))
      (should (= (point) (ebox-host-ref-position (current-buffer) 'moving))))))

(ert-deftest ebox-prepared-publication-clears-occluded-focus-after-acceptance ()
  "Rejected occlusion preserves focus; accepted occlusion clears focus and selectors."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (ebox-focus 'moving)
    (let* ((before-point (point))
           (before (buffer-string))
           (reject t)
           (operation
            (ebox-geometry-prepare
             (current-buffer) 'moving [:left :top :z-index]
             (lambda () (when reject (error "Reject focused occlusion")))
             #'ignore)))
      (should operation)
      (should-error (ebox-geometry-apply operation [(ch 0) (lh 1) 0]))
      (should (eq (ebox-focused-host-ref) 'moving))
      (should (= (point) before-point))
      (should (equal-including-properties before (buffer-string)))
      (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#moving:focus"))))
      (setq reject nil)
      (should (ebox-geometry-apply operation [(ch 0) (lh 1) 0]))
      (should-not (ebox-host-ref-bounds (current-buffer) 'moving))
      (should-not (ebox-focused-host-ref))
      (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
      (ebox-prepared-publication-test--assert-authority))))

(ert-deftest ebox-prepared-publication-delivers-paired-defensive-observations ()
  "Accepted geometry reports both providers; rejected frames never notify observers."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-publication-test--input))
    (let* (reports reject
           (operation
            (ebox-geometry-prepare
             (current-buffer) 'moving [:left :top :z-index]
             (lambda () (when reject (error "Reject observed geometry"))) #'ignore)))
      (ebox-buffer-set-observer
       (current-buffer) (lambda (_buffer report) (push report reports)))
      (should (ebox-geometry-apply operation [(ch 10) (lh 1) 2]))
      (setq reports (nreverse reports))
      (should (equal (mapcar (lambda (report) (plist-get report :provider)) reports)
                     '(ebox-publication ebox)))
      (should (equal (plist-get (car reports) :correlation-id)
                     (plist-get (cadr reports) :correlation-id)))
      (should (eq (plist-get (cadr reports) :projection-kind) 'prepared-geometry))
      (should-not (eq (plist-get (cadr reports) :strategy) 'no-op))
      (should (numberp (plist-get (cadr reports) :duration-ms)))
      (dolist (phase '(source style plan layout projection transaction))
        (should (numberp (plist-get (plist-get (cadr reports) :phase-duration-ms) phase))))
      (setf (plist-get (cadr reports) :revision) -1)
      (should (= (plist-get (ebox-buffer-update-report (current-buffer)) :revision)
                 (ebox-surface-buffer-revision (current-buffer))))
      (setq reports nil reject t)
      (should-error (ebox-geometry-apply operation [(ch 0) (lh 1) 2]))
      (should-not reports))))

(ert-deftest ebox-prepared-publication-native-state-retains-rollback-banks ()
  "Native state between geometry frames preserves atomic rejection and retry."
  (save-window-excursion
    (ebox-prepared-publication-test--with-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (let ((buffer (current-buffer)) (window (selected-window))
            (caller-state 0) (saved-state 0) reject operation phases events reports
            (unread-command-events nil))
        (cl-labels
            ((retry (values)
               (let* ((before (buffer-string))
                      (revision (ebox-surface-buffer-revision buffer))
                      (report (ebox-buffer-update-report buffer))
                      (snapshot (ebox-surface-buffer-snapshot buffer))
                      (input (plist-get snapshot :input))
                      (point-before (point))
                      (focus (ebox-focused-host-ref buffer))
                      (bounds (mapcar (lambda (ref) (ebox-host-ref-bounds buffer ref))
                                      '(surface moving covered))))
                 (setq reject t saved-state caller-state)
                 (should-error (ebox-geometry-apply operation values))
                 (should (= caller-state saved-state))
                 (should (= revision (ebox-surface-buffer-revision buffer)))
                 (should (equal report (ebox-buffer-update-report buffer)))
                 (should (equal-including-properties before (buffer-string)))
                 (should (= point-before (point)))
                 (should (equal focus (ebox-focused-host-ref buffer)))
                 (should (equal bounds
                                (mapcar (lambda (ref) (ebox-host-ref-bounds buffer ref))
                                        '(surface moving covered))))
                 (let ((after (ebox-surface-buffer-snapshot buffer)))
                   (should (= (plist-get snapshot :mount-id) (plist-get after :mount-id)))
                   (should (ebox-canonical-input-equal-p input (plist-get after :input))))
                 (should (ebox-geometry-valid-p operation))
                 (setq reject nil)
                 (should (ebox-geometry-apply operation values))
                 (should (= caller-state (1+ saved-state)))
                 (should (= (1+ revision) (ebox-surface-buffer-revision buffer)))
                 (ebox-prepared-publication-test--assert-authority)))
             (event (kind position xy &optional end)
               (append (list kind (list window position xy 0))
                       (when end (list (list window position end 1))))))
          (let ((map (ebox-keymap-create
                      :drag
                      (lambda (gesture)
                        (push (plist-get gesture :phase) phases)
                        (when (memq (plist-get gesture :phase) '(start move end))
                          (ert-info ((format "Native phase %S" (plist-get gesture :phase)))
                            (should (= 1 (length (ebox-selector-query-buffer buffer "#moving:active"))))))
                        (pcase (plist-get gesture :phase)
                          ('start
                           (should (eq (plist-get (ebox-buffer-update-report buffer) :projection-kind)
                                       'prepared-interaction))
                           ;; One metadata publication must not rotate the
                           ;; live mount bank before a rejected geometry frame.
                           (retry [(ch 4) (lh 2) 2])
                           (ebox-focus 'moving buffer)
                           (should (eq (plist-get (ebox-buffer-update-report buffer) :projection-kind)
                                       'prepared-interaction))
                           (should (= 1 (length (ebox-selector-query-buffer buffer "#moving:focus"))))
                           (retry [(ch 6) (lh 3) 2]))
                          ('move (retry [(ch 8) (lh 2) 2])))))))
            (ebox-render-to-buffer buffer (ebox-prepared-publication-test--input t nil map)))
          (setq operation
                (ebox-geometry-prepare
                 buffer 'moving [:left :top :z-index]
                 (lambda ()
                   (setq caller-state (1+ caller-state))
                   (when reject (error "Reject native interleaved geometry")))
                 (lambda () (setq caller-state saved-state))))
          (should operation)
          (should (ebox-geometry-apply operation [(ch 10) (lh 1) 2]))
          (ebox-buffer-set-observer buffer (lambda (_buffer report) (push report reports)))
          (goto-char (point-min))
          (search-forward "UPPER")
          (let* ((position (match-beginning 0))
                 (press (event 'down-mouse-1 position '(1 . 1)))
                 (command (key-binding (vector press) nil nil position)))
            (setq events (list (event 'mouse-movement position '(4 . 2))
                               (event 'drag-mouse-1 position '(1 . 1) '(4 . 2))))
            (cl-letf (((symbol-function 'read-event)
                       (lambda (&optional _prompt _inherit seconds)
                         (cond (unread-command-events (pop unread-command-events))
                               (events (pop events))
                               ((equal seconds 0) nil)
                               (t ?q)))))
              (funcall command press)))
          (should (equal (reverse phases) '(start move end)))
          (should-not (ebox-selector-query-buffer buffer "#moving:active"))
          (should (= 1 (length (ebox-selector-query-buffer buffer "#moving:focus"))))
          (should (eq (plist-get (ebox-buffer-update-report buffer) :projection-kind)
                      'prepared-interaction))
          (should (= 3 (cl-count-if
                        (lambda (report)
                          (and (eq (plist-get report :provider) 'ebox)
                               (eq (plist-get report :projection-kind) 'prepared-interaction)))
                        reports)))
          (dolist (report reports)
            (when (and (eq (plist-get report :provider) 'ebox)
                       (eq (plist-get report :projection-kind) 'prepared-interaction))
              (let ((publication
                     (cl-find-if
                      (lambda (candidate)
                        (and (eq (plist-get candidate :provider) 'ebox-publication)
                             (equal (plist-get candidate :correlation-id)
                                    (plist-get report :correlation-id))))
                      reports)))
                (should publication)
                (should (= 0 (plist-get publication :text-operations)))
                (should (= 0 (plist-get publication :property-operations))))))
          (retry [(ch 10) (lh 1) 2]))))))

(ert-deftest ebox-prepared-publication-focus-selector-keeps-ordinary-paint ()
  "Prepared native state never skips selector-dependent focus paint."
  (ebox-prepared-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(box :width (ch 20) :height (lh 5)
            :ecss (("#moving:focus" :color "#ff0000"))
            (box :id "moving" :tab-index 0 :position absolute
                 :left (ch 1) :top (lh 1) :width (ch 8) :height (lh 1)
                 :z-index 1 "Moving"))))
    (let ((operation (ebox-geometry-prepare (current-buffer) "moving" [:left :top :z-index])))
      (should operation)
      (ebox-focus-first)
      (should (= 1 (length (ebox-selector-query-buffer (current-buffer) "#moving:focus"))))
      (should-not (eq (plist-get (ebox-buffer-update-report (current-buffer)) :projection-kind)
                      'prepared-interaction))
      (should-not (ebox-geometry-valid-p operation))
      (goto-char (point-min))
      (search-forward "Moving")
      (should (equal (get-text-property (match-beginning 0) 'face)
                     '(:foreground "#ff0000"))))))

(provide 'ebox-prepared-publication-tests)
;;; ebox-prepared-publication-tests.el ends here
