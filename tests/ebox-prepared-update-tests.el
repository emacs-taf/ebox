;;; ebox-prepared-update-tests.el --- Mixed primitive publication contracts -*- lexical-binding: t; -*-

;;; Commentary:
;; Validate sparse mixed source publication through the public retained API.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-prepared-update-test--input ()
  "Build a fixed canvas with a positioned mixed-update target."
  (ebox-build
   '(box :width (ch 30) :height (lh 5)
      (box :id "panel" :position absolute :left (ch 0) :top (lh 1)
           :width (ch 12) :height (lh 2) :z-index 1
           :color "#224466" :hover-content "Hover01"
        (text :id "label" "Value00")))))

(defun ebox-prepared-update-test--assert-fresh ()
  "Compare current visible primitive output with the exported canonical input."
  (let ((actual (buffer-string))
        (expected (ebox-render (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))))
    (should (equal (substring-no-properties actual) (substring-no-properties expected)))
    (dotimes (position (length actual))
      (dolist (property '(display face font-lock-face help-echo keymap pointer mouse-face))
        (should (equal (get-text-property position property actual)
                       (get-text-property position property expected)))))))

(ert-deftest ebox-prepared-update-cohorts-share-current-pane-content ()
  "Independent operations keep current sibling text and paint after rejection."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 40) :height (lh 4)
           (box :id "panel" :position absolute :left (ch 0) :top (lh 0)
                :width (ch 24) :height (lh 2) :z-index 1 :color "#334455"
             (text :id "status" "Selected 0")
             (text :id "clock" "12:00:00"))
           (box :id "peer" :position absolute :left (ch 28) :top (lh 0)
                :width (ch 10) :height (lh 2) :z-index 2 :color "green"
             "Peer"))))
      (let* (reject
             (selection
              (ebox-update-prepare
               (current-buffer) [["panel" [:color]] ["status" [:content]]]
               (lambda () (when reject (error "Reject selection"))) #'ignore))
             (clock (ebox-update-prepare (current-buffer) [["clock" [:content]]])))
        (should selection)
        (should clock)
        (cl-labels ((apply-current (operation values changed)
                      (should (ebox-update-valid-p selection))
                      (should (ebox-update-valid-p clock))
                      (should (ebox-update-apply operation values changed))
                      (ebox-prepared-update-test--assert-fresh)))
          (apply-current selection [["#AA2233"] ["Selected 1"]] [0 1])
          (apply-current clock [["12:00:01"]] [0])
          (apply-current selection [["#334455"] ["Selected 2"]] [0 1])
          (let ((before (buffer-string))
                (revision (ebox-surface-buffer-revision (current-buffer))))
            (setq reject t)
            (should-error
             (ebox-update-apply selection [["#AA2233"] ["Selected 3"]] [0 1]))
            (should (= revision (ebox-surface-buffer-revision (current-buffer))))
            (should (equal-including-properties before (buffer-string)))
            (ebox-prepared-update-test--assert-fresh))
          ;; The other operation can publish immediately after rejection,
          ;; then continue after the rejected operation is retried.
          (apply-current clock [["12:00:02"]] [0])
          (setq reject nil)
          (apply-current selection [["#AA2233"] ["Selected 3"]] [0 1])
          (apply-current clock [["12:00:03"]] [0])
          (apply-current selection [["#AA2233"] ["Selected 4"]] [1])
          (apply-current clock [["12:00:04"]] [0]))))))

(defun ebox-prepared-update-test--batch-source-isolation ()
  "Prepare many independent sources while preserving exported snapshots."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 24))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build `(box :width (ch 30) :height (lh 24)
                        (box :position absolute :left (ch 0) :top (lh 0) :z-index 1
                             :width (ch 24) :height (lh 24)
                             ,@(cl-loop for i below 24
                                        collect `(box :id ,(format "row%d" i)
                                                      :width (ch 24) :height (lh 1) :color "#224466"
                                                      (text :id ,(format "text%d" i) ,(format "Old%02d" i))))))))
      (dotimes (round 3)
        (let* ((snapshot (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
               (before (ebox-render snapshot))
               (specifications (vconcat (cl-loop for i below 24
                                                 append (list (vector (format "row%d" i) [:color])
                                                              (vector (format "text%d" i) [:content])))))
               (values (vconcat (cl-loop for i below 24
                                        append (list (vector (if (cl-evenp round) "#884422" "#224466"))
                                                     (vector (format "R%d-%02d" round i))))))
               (operation (ebox-update-prepare (current-buffer) specifications))
               (revision (ebox-surface-buffer-revision (current-buffer))))
          (should (or operation (ert-fail (list :round round :report (ebox-update-prepare-report (current-buffer))))))
          (should (equal before (ebox-render snapshot)))
          (should (ebox-update-apply operation values (vconcat (number-sequence 0 47))))
          (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
          (should (equal before (ebox-render snapshot)))
          (ebox-prepared-update-test--assert-fresh))))))

(ert-deftest ebox-prepared-update-publishes-mixed-members-once ()
  "Geometry, inherited paint, native hover and Text advance one accepted revision."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-update-test--input))
      (let* ((staged 0) (accepted 0)
             (operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:left :top :z-index]]
                                 ["panel" [:color :hover-content]]
                                 ["label" [:content]]]
               (lambda () (setq staged (1+ staged)))
               (lambda () (setq staged (1- staged)))
               (lambda () (setq accepted (1+ accepted)))))
             (values [[(ch 4) (lh 2) 3] ["#884422" "Hover02"] ["Value01"]])
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should (ebox-update-valid-p operation))
        (should (ebox-update-apply operation values [0 1 2]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (should (= staged 1)) (should (= accepted 1))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [(ch 8) (lh 1) 4])
        (should (ebox-update-apply operation values [0]))
        (ebox-prepared-update-test--assert-fresh)
        (should (= staged 2)) (should (= accepted 2))
        ;; A later sparse geometry member must retain the accepted hover
        ;; source and its prebound native capability from the earlier batch.
        (save-window-excursion
          (set-window-buffer (selected-window) (current-buffer))
          (goto-char (point-min))
          (search-forward "Value01")
          (funcall (lookup-key ebox-buffer-mode-map [mouse-movement])
                   (list 'mouse-movement (list (selected-window) (- (point) 7) '(1 . 1) 0)))
          (should (string-match-p "Hover02" (buffer-string)))))))
  (ebox-prepared-update-test--batch-source-isolation))

(ert-deftest ebox-prepared-update-rolls-back-all-members-and-retries ()
  "A rejected paired stage restores pixels, source, revision and every member."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-update-test--input))
      (let* ((reject t) (caller 'before) (caller-count 0)
             (operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:left :color]] ["label" [:content]]]
               (lambda () (setq caller 'after caller-count (1+ caller-count))
                 (when reject (error "Reject mixed update")))
               (lambda () (setq caller 'before caller-count (1- caller-count)))))
             (values [[(ch 5) "#885522"] ["Value02"]])
             (before (buffer-string))
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should-error (ebox-update-apply operation values [0 1]))
        (should (eq caller 'before))
        (should (= caller-count 0))
        (should (equal-including-properties before (buffer-string)))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (ebox-prepared-update-test--assert-fresh)
        (setq reject nil)
        (should (ebox-update-apply operation values [0 1]))
        (should (eq caller 'after))
        (should (= caller-count 1))
        (ebox-prepared-update-test--assert-fresh)
        ;; An absolute panel does not participate in flow, so content that
        ;; changes its wrapped rows replaces the panel's retained pixels.
        (aset values 1 ["A longer replacement"])
        (setq revision (ebox-surface-buffer-revision (current-buffer)))
        (should (ebox-update-apply operation values [1]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-recovers-after-abandoned-preparation ()
  "A preparation left by a non-local exit keeps output and prepares cold again."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-update-test--input))
      (let ((earlier (ebox-update-prepare (current-buffer) [["panel" [:left]]]))
            (before (buffer-string))
            (revision (ebox-surface-buffer-revision (current-buffer))))
        (should earlier)
        (should-error (ebox-update-prepare
                       (current-buffer) [["panel" [:left]] ["panel" [:left]]]))
        (should (eq (plist-get (ebox-update-prepare-report (current-buffer)) :reason)
                    'interrupted))
        ;; A failed preparation leaves unrelated prepared canvases alone.
        (should (ebox-update-valid-p earlier))
        (should (equal-including-properties before (buffer-string)))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (ebox-update-apply earlier [[(ch 3)]] [0]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (ebox-prepared-update-test--assert-fresh)
        (setq revision (ebox-surface-buffer-revision (current-buffer)))
        (let ((operation (ebox-update-prepare
                          (current-buffer) [["panel" [:left :top]] ["label" [:content]]])))
          (should operation)
          (should (ebox-update-apply operation [[(ch 6) (lh 2)] ["Value03"]] [0 1]))
          (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
          (ebox-prepared-update-test--assert-fresh))))))

(ert-deftest ebox-prepared-update-keeps-disjoint-panels-preparable ()
  "Prepared canvases for disjoint panels stay valid and apply alternately.
One surface keeps several retained panels alive, so using one panel must not
retire another panel's prepared operation."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 40) :height (lh 5)
           (box :id "left" :position absolute :left (ch 1) :top (lh 1)
                :width (ch 10) :height (lh 2) :z-index 1 :color "#224466"
             (text :id "left-label" "Left00"))
           (box :id "right" :position absolute :left (ch 20) :top (lh 1)
                :width (ch 10) :height (lh 2) :z-index 2 :color "#662244"
                :visibility visible
             (text :id "right-label" "Right00")))))
      (let* ((left (ebox-update-prepare (current-buffer) [["left" [:color]] ["left-label" [:content]]]))
             (right (ebox-update-prepare (current-buffer) [["right" [:visibility]] ["right-label" [:content]]]))
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should left)
        (should right)
        ;; Preparing the second panel must keep the first operation usable.
        (should (ebox-update-valid-p left))
        (should (ebox-update-valid-p right))
        (should (ebox-update-apply left [["#AA2233"] ["Left01"]] [0 1]))
        (should (ebox-update-valid-p right))
        (ebox-prepared-update-test--assert-fresh)
        (should (ebox-update-apply right [[hidden] ["Right01"]] [0 1]))
        (should (ebox-update-valid-p left))
        (should (= (+ revision 2) (ebox-surface-buffer-revision (current-buffer))))
        (ebox-prepared-update-test--assert-fresh)
        (should (ebox-update-apply left [["#224466"] ["Left02"]] [0 1]))
        (should (ebox-update-apply right [[visible] ["Right02"]] [0 1]))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-translates-without-repainting-repeated-paint ()
  "Members whose raster values repeat only translate; a changed one repaints."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) (ebox-prepared-update-test--input))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:left :top :z-index :color]] ["label" [:content]]]
               #'ignore #'ignore))
             (values [[(ch 4) (lh 2) 3 "#224466"] ["Value00"]])
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should (ebox-update-apply operation values [0 1]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (should (equal '(geometry) (plist-get (ebox-buffer-update-report (current-buffer)) :dirty-kinds)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [(ch 6) (lh 1) 4 "#884422"])
        (should (ebox-update-apply operation values [0]))
        (let ((kinds (plist-get (ebox-buffer-update-report (current-buffer)) :dirty-kinds)))
          (should (memq 'paint kinds)) (should (memq 'span kinds)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 1 ["Value01"])
        (should (ebox-update-apply operation values [1]))
        (should (equal '(span) (plist-get (ebox-buffer-update-report (current-buffer)) :dirty-kinds)))
        (should (string-match-p "Value01" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        ;; Repeating the displayed values after a repaint stays fresh too.
        (should (ebox-update-apply operation values [0 1]))
        (should (equal '(geometry) (plist-get (ebox-buffer-update-report (current-buffer)) :dirty-kinds)))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-hides-and-shows-positioned-panel ()
  "A prepared visibility member removes and restores a panel's footprint."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 30) :height (lh 5)
           (text "Desk")
           (box :id "panel" :position absolute :left (ch 2) :top (lh 1)
                :width (ch 12) :height (lh 2) :z-index 1 :visibility visible
                :color "#224466"
             (text :id "label" "Value00")))))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:visibility :left]]]
               #'ignore #'ignore))
             (values [[hidden (ch 2)]])
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (should-not (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [visible (ch 6)])
        (should (ebox-update-apply operation values [0]))
        (should (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-toggles-visibility-over-deep-subtree ()
  "Hiding and showing a Host with a deep subtree keeps every descendant fresh.
Visibility is a paint boundary of the changed Host rather than an inherited
value, so descendants keep their computed styles; an inherited paint change
on the same Host still reaches descendants that inherit it while explicit
overrides stay untouched."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 40) :height (lh 8)
           (text "Desk")
           (box :id "panel" :position absolute :left (ch 2) :top (lh 1)
                :width (ch 30) :height (lh 5) :z-index 1 :visibility visible
                :color "#224466" :font-weight normal
             (column
              (row (text "Head") (text :color "#AA2222" "Own"))
              (column (row (text "Body01")) (row (text "Body02")))
              (row (text :font-weight bold "Foot")))))))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:visibility :color :font-weight]]]
               #'ignore #'ignore))
             (values [[hidden "#224466" normal]])
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (should-not (string-match-p "Body02" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [visible "#224466" normal])
        (should (ebox-update-apply operation values [0]))
        (should (string-match-p "Body02" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [visible "#116633" bold])
        (should (ebox-update-apply operation values [0]))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [hidden "#116633" bold])
        (should (ebox-update-apply operation values [0]))
        (aset values 0 [visible "#224466" normal])
        (should (ebox-update-apply operation values [0]))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-shows-initially-hidden-positioned-panel ()
  "A panel mounted hidden stays addressable: prepared moves park it and a
prepared visibility change paints it at its current placement."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 30) :height (lh 5)
           (text "Desk")
           (box :id "panel" :position absolute :left (ch 2) :top (lh 1)
                :width (ch 12) :height (lh 2) :z-index 1 :visibility hidden
                :color "#224466"
             (text :id "label" "Value00")))))
      (should-not (string-match-p "Value00" (buffer-string)))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:visibility :left :top]]]
               #'ignore #'ignore))
             (values [[hidden (ch 4) (lh 2)]]))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (should-not (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [visible (ch 4) (lh 2)])
        (should (ebox-update-apply operation values [0]))
        (should (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [hidden (ch 4) (lh 2)])
        (should (ebox-update-apply operation values [0]))
        (should-not (string-match-p "Value00" (buffer-string)))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-fits-variable-text-in-fixed-flex-allocation ()
  "A fixed status allocation accepts variable text and preserves adjacent controls."
  (let ((ebox-viewport-width 320) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(column :width (ch 40) :height (lh 6)
           (flex :width (ch 40) :height (lh 1) :flex-direction row :flex-wrap nowrap
             (box :flex-shrink 0 :min-width max-content "Left")
             (box :id "status-slot" :flex-grow 1 :flex-basis (px 0) :min-width (px 0)
                  :height (lh 1) :wrap-mode none :overflow hidden
               (text :id "status" "Ready"))
             (box :id "controls" :flex-shrink 0 :min-width max-content "Controls"))
           (box :id "panel" :position absolute :left (ch 0) :top (lh 3)
                :width (ch 8) :height (lh 1) :z-index 1 "Panel"))))
      (let* ((reject nil)
             (operation
              (ebox-update-prepare
               (current-buffer) [["status" [:content]]]
               (lambda () (when reject (error "Reject status"))) #'ignore))
             (values [["Window one"]]))
        (should operation)
        (dolist (text '("Window one" "Window three" "A very long status title that clips before Controls" "Ready"))
          (aset values 0 (vector text))
          (should (ebox-update-apply operation values [0]))
          (should (string-match-p "Controls" (buffer-string)))
          (ebox-prepared-update-test--assert-fresh))
        (let ((before (buffer-string)) (revision (ebox-surface-buffer-revision (current-buffer))))
          (setq reject t)
          (aset values 0 ["Rejected status"])
          (should-error (ebox-update-apply operation values [0]))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string))))))))

(defun ebox-prepared-update-test--status-slot (initial)
  "Render a fixed status slot holding INITIAL text over a positioned panel."
  (ebox-render-to-buffer
   (current-buffer)
   (ebox-build
    `(column :width (ch 20) :height (lh 4)
       (box :width (ch 8) :height (lh 1) :wrap-mode none :overflow hidden
         (text :id "status" ,initial))
       (box :id "panel" :position absolute :left (ch 0) :top (lh 2)
            :width (ch 8) :height (lh 1) :z-index 1 "Panel")))))

(ert-deftest ebox-prepared-update-fits-variable-text-in-clipped-or-full-slot ()
  "Initially clipped and exactly full fixed slots accept shorter and longer text."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 8))
    (dolist (initial '("1234567890123456" "12345678"))
      (with-temp-buffer
        (ebox-prepared-update-test--status-slot initial)
        (let ((operation (ebox-update-prepare
                          (current-buffer) [["status" [:content]]] #'ignore #'ignore))
              (values [["x"]]))
          (should operation)
          (dolist (text '("x" "1234567890123456" "12345678" "ab"))
            (aset values 0 (vector text))
            (should (ebox-update-apply operation values [0]))
            (should (string-match-p "Panel" (buffer-string)))
            (ebox-prepared-update-test--assert-fresh)))))))

(ert-deftest ebox-prepared-update-grows-initially-empty-slot-atomically ()
  "Existing empty Text can appear, disappear and reject a later transaction."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 8))
    (with-temp-buffer
      (ebox-prepared-update-test--status-slot "")
      (let* ((staged 0) reject
             (held (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
             (original (ebox-render held))
             (operation (ebox-update-prepare
                         (current-buffer) [["status" [:content]]]
                         (lambda () (when reject (error "Reject text growth")) (cl-incf staged)) #'ignore)))
        (should operation)
        (dolist (text '("x" "Subtitle ready" "" "Ready again"))
          (let ((revision (ebox-surface-buffer-revision (current-buffer))))
            (should (eq t (ebox-update-apply operation (vector (vector text)) [0])))
            (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
            (should (equal original (ebox-render held)))
            (ebox-prepared-update-test--assert-fresh)))
        (should (= staged 4))
        (let ((before (buffer-string)) (revision (ebox-surface-buffer-revision (current-buffer))))
          (setq reject t)
          (should-error (ebox-update-apply operation [["Rejected"]] [0]))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string)))
          (ebox-prepared-update-test--assert-fresh))))))

(ert-deftest ebox-prepared-update-explains-canvas-admission-without-publication ()
  "Cold admission reports bounded proof facts without publishing or staging."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 8))
    (dolist
        (case
         '(((box :width (ch 20) :height (lh 2) :overflow hidden
              (text "First\nSecond\nThird")
              (box :id "panel" :position absolute :left (ch 0) :top (lh 0)
                   :width (ch 5) :height (lh 1) :z-index 1 "Panel"))
            wrapper content-height)
           ((box :width (ch 20) :height (lh 5)
              (box :position relative :width (ch 20) :height (lh 5)
                (box :id "panel" :position absolute :layer root
                     :left (ch 0) :top (lh 0) :width (ch 5) :height (lh 1)
                     :z-index 1 "Panel")))
            route root-portals)
           ((box :width (ch 20) :height (lh 5)
              (box :id "panel" :width (ch 5) :height (lh 1) "Panel"))
            geometry positioned-host)))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) (ebox-build (car case)))
        (let ((before (buffer-string))
              (revision (ebox-surface-buffer-revision (current-buffer)))
              staged)
          (should-not
           (ebox-update-prepare (current-buffer) [["panel" [:left]]]
                                (lambda () (setq staged t)) #'ignore))
          (let* ((report (ebox-update-prepare-report (current-buffer)))
                 (detail (plist-get report :detail)))
            (should (eq (plist-get report :status) 'unsupported))
            (should (eq (plist-get report :reason) 'fixed-canvas))
            (should (eq (plist-get detail :phase) (nth 1 case)))
            (should (eq (plist-get detail :reason) (nth 2 case)))
            (should (<= (length detail) 20))
            (cl-loop for (_key value) on detail by #'cddr
                     do (should (or (symbolp value) (numberp value))))
            (when (eq (nth 2 case) 'content-height)
              (should (= (plist-get detail :plane-height) 3))
              (should (= (plist-get detail :content-height) 2)))
            (setcar (cdr detail) 'changed)
            (should (eq (plist-get (plist-get (ebox-update-prepare-report (current-buffer))
                                              :detail) :phase)
                        (nth 1 case))))
          (should-not staged)
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string))))
        ;; A new accepted canvas reports readiness, with no old rejection.
        (ebox-render-to-buffer (current-buffer) (ebox-prepared-update-test--input))
        (should (ebox-update-prepare (current-buffer) [["panel" [:left]]]))
        (let ((report (ebox-update-prepare-report (current-buffer))))
          (should (eq (plist-get report :status) 'ready))
          (should-not (plist-get report :detail)))))))

(ert-deftest ebox-prepared-update-retains-scrolling-through-move-paint-and-resize ()
  "Pane geometry, paint and resize preserve scroll authority and later input."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (px 100) :height (lh 10) :overflow hidden
           (box :id "panel" :position absolute :left (px 0) :top (lh 1)
                :width (px 40) :height (lh 2) :z-index 1 :overflow scroll
                :color "#224466"
             (text "A1\nA2\nA3\nA4\nA5")))))
      (let* ((region (plist-get (car (ebox-selector-query-buffer (current-buffer) "#panel")) :region-id))
             (scroll (lambda (down)
                       (goto-char (point-min))
                       (re-search-forward "A[1-5]")
                       (backward-char 2)
                       (if down (ebox-scroll-down 1) (ebox-scroll-up 1))))
             (specifications [["panel" [:left :top :z-index :color :width :height]]])
             (values [[(px 8) (lh 2) 2 "#224466" (px 40) (lh 2)]])
             operation)
        (should (= 2 (plist-get (ebox-scroll-state region) :content-height)))
        (funcall scroll t)
        (should (= 1 (plist-get (ebox-scroll-state region) :scroll-offset)))
        (setq operation (ebox-update-prepare (current-buffer) specifications))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (should (= 1 (plist-get (ebox-scroll-state region) :scroll-offset)))
        (should (string-match-p "A2" (buffer-substring-no-properties (point-min) (point-max))))
        (ebox-prepared-update-test--assert-fresh)
        (aset (aref values 0) 3 "#882244")
        (should (ebox-update-apply operation values [0]))
        (should (= 1 (plist-get (ebox-scroll-state region) :scroll-offset)))
        (ebox-prepared-update-test--assert-fresh)
        (funcall scroll t)
        (should (= 2 (plist-get (ebox-scroll-state region) :scroll-offset)))
        (should-not (ebox-update-valid-p operation))
        (setq operation (ebox-update-prepare (current-buffer) specifications))
        (should operation)
        (aset (aref values 0) 5 '(lh 4))
        (should (ebox-update-apply operation values [0]))
        (should (= 4 (plist-get (ebox-scroll-state region) :content-height)))
        (should (= 1 (plist-get (ebox-scroll-state region) :scroll-offset)))
        (ebox-prepared-update-test--assert-fresh)
        (funcall scroll nil)
        (should (= 0 (plist-get (ebox-scroll-state region) :scroll-offset)))
        (setq operation (ebox-update-prepare (current-buffer) specifications))
        (should operation)
        (aset (aref values 0) 5 '(lh 5))
        (should (ebox-update-apply operation values [0]))
        (should-not (ebox-scroll-state region))
        (ebox-prepared-update-test--assert-fresh)
        (aset (aref values 0) 5 '(lh 2))
        (should (ebox-update-apply operation values [0]))
        (should (= 2 (plist-get (ebox-scroll-state region) :content-height)))
        (funcall scroll t)
        (should (= 1 (plist-get (ebox-scroll-state region) :scroll-offset)))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-rolls-back-scroll-resize-and-retries ()
  "Rejected pane resizing restores scroll pixels, offset, focus and metadata."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 12))
    (with-temp-buffer
      (let ((pressed 0))
        (ebox-render-to-buffer
         (current-buffer)
         (ebox-build
          `(box :width (px 100) :height (lh 10) :overflow hidden
             (box :id "panel" :position absolute :left (px 0) :top (lh 1)
                  :width (px 40) :height (lh 2) :z-index 1 :overflow scroll
                  :tab-index 0 :keymap ,(ebox-keymap-create :activate (lambda () (setq pressed (1+ pressed))))
               (text "A1\nA2\nA3\nA4\nA5")))))
        (let* ((region (plist-get (car (ebox-selector-query-buffer (current-buffer) "#panel")) :region-id))
               (focus (ebox-focus-first))
               (reject t) staged-height
               (operation
                (ebox-update-prepare
                 (current-buffer) [["panel" [:left :height]]]
                 (lambda ()
                   (setq staged-height (plist-get (ebox-scroll-state region) :content-height))
                   (when reject (error "Reject prepared scroll resize")))
                 #'ignore))
               (values [[(px 8) (lh 4)]])
               (before (buffer-string))
               (revision (ebox-surface-buffer-revision (current-buffer))))
          (should operation)
          (should-error (ebox-update-apply operation values [0]))
          (should (= 4 staged-height))
          (should (= 2 (plist-get (ebox-scroll-state region) :content-height)))
          (should (= 0 (plist-get (ebox-scroll-state region) :scroll-offset)))
          (should (equal focus (ebox-focused-host-ref)))
          (should (equal-including-properties before (buffer-string)))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (ebox-update-valid-p operation))
          (setq reject nil)
          (should (ebox-update-apply operation values [0]))
          (should (= 4 (plist-get (ebox-scroll-state region) :content-height)))
          (should (equal focus (ebox-focused-host-ref)))
          (ebox-activate)
          (should (= pressed 1))
          (goto-char (point-min)) (search-forward "A1") (backward-char 2)
          (ebox-scroll-down 1)
          (should (= 1 (plist-get (ebox-scroll-state region) :scroll-offset)))
          (ebox-prepared-update-test--assert-fresh))))))

(ert-deftest ebox-prepared-update-declines-scroll-containing-plane ()
  "Scrolling ancestors still decline when their viewport has no compiled route."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 8))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (ch 20) :height (lh 2) :overflow scroll
           (text "First\nSecond\nThird")
           (box :id "panel" :position absolute :left (ch 0) :top (lh 0)
                :width (ch 5) :height (lh 1) :z-index 1 "Panel"))))
      (let ((before (buffer-string))
            (revision (ebox-surface-buffer-revision (current-buffer))))
        (should-not (ebox-update-prepare (current-buffer) [["panel" [:left]]]))
        (let ((detail (plist-get (ebox-update-prepare-report (current-buffer)) :detail)))
          (should (eq (plist-get detail :reason) 'scroll-containing-plane))
          (should (= 1 (plist-get detail :ancestor-scroll-count))))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))))))

(ert-deftest ebox-prepared-update-preserves-long-scroll-continuation-and-siblings ()
  "Moved and repainted long panes keep scroll continuation and sibling offsets."
  (let ((ebox-viewport-width 220) (ebox-viewport-height 12))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        `(box :width (px 200) :height (lh 10) :overflow hidden
           (box :id "panel" :position absolute :left (px 0) :top (lh 1)
                :width (px 80) :height (lh 5) :z-index 1 :color "#224466"
             (column :id "rows" :width stretch :height (lh 3) :overflow scroll
               ,@(cl-loop for row below 80 collect (format "Row%02d" row))))
           (box :id "peer" :position absolute :left (px 110) :top (lh 1)
                :width (px 60) :height (lh 2) :z-index 2 :overflow scroll
             "Peer0\nPeer1\nPeer2\nPeer3"))))
      (let* ((rows (plist-get (car (ebox-selector-query-buffer (current-buffer) "#rows")) :region-id))
             (peer (plist-get (car (ebox-selector-query-buffer (current-buffer) "#peer")) :region-id))
             (specifications [["panel" [:left :color :width]]])
             (values [[(px 8) "#882244" (px 80)]])
             (reject t) operation)
        (goto-char (point-min)) (search-forward "Peer0") (backward-char 5)
        (ebox-scroll-down 1)
        (should (= 1 (plist-get (ebox-scroll-state peer) :scroll-offset)))
        (setq operation (ebox-update-prepare
                         (current-buffer) specifications
                         (lambda () (when reject (error "Reject long scroll repaint"))) #'ignore))
        (should operation)
        (let ((before (buffer-string)))
          (should-error (ebox-update-apply operation values [0]))
          (should (equal-including-properties before (buffer-string)))
          (should (= 0 (plist-get (ebox-scroll-state rows) :scroll-offset)))
          (should (= 1 (plist-get (ebox-scroll-state peer) :scroll-offset))))
        (setq reject nil)
        (should (ebox-update-apply operation values [0]))
        (should (= 1 (plist-get (ebox-scroll-state peer) :scroll-offset)))
        (goto-char (point-min)) (search-forward "Row00") (backward-char 5)
        (ebox-scroll-down 25)
        (should (= 25 (plist-get (ebox-scroll-state rows) :scroll-offset)))
        (should (= 1 (plist-get (ebox-scroll-state peer) :scroll-offset)))
        (should (string-match-p "Row25" (buffer-substring-no-properties (point-min) (point-max))))
        (setq operation (ebox-update-prepare (current-buffer) specifications))
        (should operation)
        (aset (aref values 0) 2 '(px 72))
        (should (ebox-update-apply operation values [0]))
        (goto-char (point-min)) (search-forward "Row25") (backward-char 5)
        (ebox-scroll-down 35)
        (should (= 60 (plist-get (ebox-scroll-state rows) :scroll-offset)))
        (should (= 1 (plist-get (ebox-scroll-state peer) :scroll-offset)))
        (should (string-match-p "Row60" (buffer-substring-no-properties (point-min) (point-max))))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-creates-scroll-after-underfilled-resizes ()
  "An initially underfilled pane starts scrolling when a later resize clips it."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 10))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        '(box :width (px 100) :height (lh 8) :overflow hidden
           (box :id "panel" :position absolute :left (px 0) :top (lh 1)
                :width (px 40) :height (lh 4) :z-index 1 :overflow scroll
                :min-width (px 8) :min-height (lh 1)
             "A1\nA2\nA3"))))
      (let* ((region (plist-get (car (ebox-selector-query-buffer (current-buffer) "#panel")) :region-id))
             (operation (ebox-update-prepare (current-buffer) [["panel" [:width :height]]]))
             (values [[(px 48) (lh 4)]]))
        (should operation)
        (should-not (ebox-scroll-state region))
        (should (ebox-update-apply operation values [0]))
        (aset (aref values 0) 0 '(px 56))
        (should (ebox-update-apply operation values [0]))
        (should-not (ebox-scroll-state region))
        (aset (aref values 0) 1 '(lh 2))
        (should (ebox-update-apply operation values [0]))
        (should (= 2 (plist-get (ebox-scroll-state region) :content-height)))
        (goto-char (point-min)) (search-forward "A1") (backward-char 2)
        (ebox-scroll-down 1)
        (should (= 1 (plist-get (ebox-scroll-state region) :scroll-offset)))
        (should (string-match-p "A3" (buffer-substring-no-properties (point-min) (point-max))))
        (ebox-prepared-update-test--assert-fresh)))))

(ert-deftest ebox-prepared-update-scroll-rollback-does-not-revive-killed-buffer ()
  "Teardown restores paired caller state without reviving a scroll owner."
  (let ((ebox-viewport-width 160) (ebox-viewport-height 8)
        (caller 'before)
        (buffer (generate-new-buffer " *Ebox scroll teardown test*")))
    (unwind-protect
        (with-current-buffer buffer
          (ebox-render-to-buffer
           buffer
           (ebox-build
            '(box :width (px 100) :height (lh 6) :overflow hidden
               (box :id "panel" :position absolute :left (px 0) :top (lh 1)
                    :width (px 40) :height (lh 2) :z-index 1 :overflow scroll
                 "A1\nA2\nA3\nA4"))))
          (let* ((region (plist-get (car (ebox-selector-query-buffer buffer "#panel")) :region-id))
                 (operation (ebox-update-prepare buffer [["panel" [:height]]]
                                                 (lambda ()
                                                   (setq caller 'after)
                                                   (kill-buffer buffer))
                                                 (lambda () (setq caller 'before)))))
            (should operation)
            (should-error (ebox-update-apply operation [[(lh 3)]] [0]))
            (should-not (buffer-live-p buffer))
            (should (eq caller 'before))
            (should-not (ebox-scroll-state region))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-prepared-update-rejection-preserves-following-admission ()
  "Cold and reused-scene rejection preserve source, pixels and later updates."
  (let ((ebox-viewport-width 240) (ebox-viewport-height 10))
    (dolist (case '((["bad" [:left]] inline-winner nil)
                    (["flow" [:left]] geometry-target nil)
                    (["label" [:class]] class-variants :class)
                    (["label" [:class] [["off" "on"]]] selector-dependency :class)
                    (["canvas" [:width]] raster-boundary nil)))
      (with-temp-buffer
        (ebox-render-to-buffer
         (current-buffer)
         (ebox-build
          `(box :id "canvas" :width (ch 30) :height (lh 6)
                :ecss (("#bad" :left ,(ecss-important '(px 2)))
                       (".on" :color "#AA2233"))
             (box :id "flow" :position relative :left (ch 0) :top (lh 0)
                  :z-index 0 :width (ch 8) :height (lh 1) "Flow")
             (box :id "bad" :position absolute :left (px 0) :top (lh 3)
                  :z-index 1 :width (ch 8) :height (lh 1) "Bad")
             (box :id "panel" :position absolute :left (ch 0) :top (lh 1)
                  :z-index 1 :width (ch 12) :height (lh 1)
               (text :id "label" :class "off" "Value00")))))
        (let (operation staged)
          (dotimes (attempt 2)
            (let* ((before (buffer-string))
                   (snapshot (ebox-surface-buffer-snapshot (current-buffer)))
                   (revision (plist-get snapshot :revision))
                   (bounds (ebox-host-ref-bounds (current-buffer) "panel")))
              (should-not
               (ebox-update-prepare
                (current-buffer) (vector (car case) ["label" [:content]])
                (lambda () (setq staged t)) #'ignore))
              (let ((report (ebox-update-prepare-report (current-buffer))))
                (should (eq (plist-get report :status) 'unsupported))
                (should (eq (plist-get report :reason) (nth 1 case)))
                (should (= (plist-get report :member) 0))
                (should (eq (plist-get report :property) (nth 2 case))))
              (should-not staged)
              (should (equal-including-properties before (buffer-string)))
              (should (= revision (ebox-surface-buffer-revision (current-buffer))))
              (should (equal bounds (ebox-host-ref-bounds (current-buffer) "panel")))
              (should
               (ebox-canonical-input-equal-p
                (plist-get snapshot :input)
                (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input)))
              (if operation
                  (should (ebox-update-valid-p operation))
                (setq operation
                      (ebox-update-prepare
                       (current-buffer) [["panel" [:left]] ["label" [:content]]]))
                (should operation))
              (should (ebox-update-apply operation
                                         (vector (vector (list 'ch (+ 2 attempt)))
                                                 (vector (format "Value%02d" (1+ attempt))))
                                         [0 1]))
              (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
              (ebox-prepared-update-test--assert-fresh))))))))

(ert-deftest ebox-prepared-update-bounds-intervals-from-raster-beyond-anchor-height ()
  "A short anchored panel with many exposed runs keeps its prepared update.
One owner can run many disjoint intervals per row, so a retained mount must
size its per-owner pools from the composed raster instead of the anchored
plane's own program height.  The root plane is taller than the anchored panel,
and the panel's own background shows between sixty narrow children on every
one of its rows."
  (let ((ebox-viewport-width 480) (ebox-viewport-height 40))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        `(box :width (ch 120) :height (lh 30)
           (box :position 'relative :width (ch 120) :height (lh 6)
             (box :id "panel" :position 'absolute :left (ch 0) :top (lh 0)
                  :width (ch 120) :height (lh 6) :z-index 1 :visibility 'visible
                  :background-color "#555555"
               (flex :flex-direction 'row :width (ch 120) :height (lh 6)
                     :gap '((lh 0) (ch 1))
                ,@(cl-loop for cell from 0 below 60
                           collect `(box :width (ch 2) :height (lh 6)
                                         :background-color "#111111"
                                         (text ,(format "%02d" cell))))))))))
      (let* ((operation
              (ebox-update-prepare
               (current-buffer) [["panel" [:visibility]]] #'ignore #'ignore))
             (values [[hidden]])
             (revision (ebox-surface-buffer-revision (current-buffer))))
        (should operation)
        (should (ebox-update-apply operation values [0]))
        (should (= (1+ revision) (ebox-surface-buffer-revision (current-buffer))))
        (ebox-prepared-update-test--assert-fresh)
        (aset values 0 [visible])
        (should (ebox-update-apply operation values [0]))
        (ebox-prepared-update-test--assert-fresh)))))

(provide 'ebox-prepared-update-tests)
;;; ebox-prepared-update-tests.el ends here
