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

(defun ebox-layer-publication-test--mount-signature (buffer)
  "Return BUFFER's complete mounted ranges normalized to runtime tree paths."
  (let* ((state (ebox--buffer-render-state buffer))
         (objects (plist-get state :surface-node-object-table))
         result)
    (cl-labels
        ((walk (node path)
           (let ((object (gethash (plist-get node :node-id) objects)))
             (should object)
             (push
              (cons path
                    (sort
                     (mapcar (lambda (mount)
                               (cons (plist-get mount :start)
                                     (plist-get mount :end)))
                             (tp-object-mounts object))
                     (lambda (left right)
                       (if (= (car left) (car right))
                           (< (cdr left) (cdr right))
                         (< (car left) (car right))))))
              result))
           (cl-loop for child in (ebox-tree-node-children node)
                    for index from 0
                    do (walk child (append path (list index))))))
      (walk (plist-get state :root-node) '(root)))
    (nreverse result)))

(defun ebox-layer-publication-test--assert-fresh-mounts ()
  "Compare current mounts and paint with an independent committed-input render."
  (let ((buffer (current-buffer))
        (input (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input)))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) input)
            (should (equal
                     (ebox-layer-publication-test--mount-signature buffer)
                     (ebox-layer-publication-test--mount-signature (current-buffer))))
            (let ((actual (with-current-buffer buffer (buffer-string)))
                  (expected (buffer-string)))
              (should (equal (substring-no-properties actual)
                             (substring-no-properties expected)))
              (dotimes (position (length actual))
                (should (equal (get-text-property position 'face actual)
                               (get-text-property position 'face expected))))))
        (when (ebox-surface-buffer-mounted-p (current-buffer))
          (ebox-unmount-buffer (current-buffer)))))))

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

(ert-deftest ebox-layer-publication-drag-recomposes-only-damaged-rows ()
  "Moving an overlay recomposes its old and new rows and reuses the rest.

This is the focused regression for retained composition during a drag: the
overlay moves from row one to row two while three underlying rows stay
unchanged.  Count calls to `ebox-composite-line' to prove that only the two
damaged rows are recomposed, then compare the result with a cold composition
including all text properties."
  (let* ((base-0 (list :node-id "base-0" :ebox-kind 'box))
         (base-1 (list :node-id "base-1" :ebox-kind 'box))
         (base-2 (list :node-id "base-2" :ebox-kind 'box))
         (overlay (list :node-id "overlay" :ebox-kind 'box
                        :position 'absolute :z-index 1))
         (host (list :node-id "drag-host" :ebox-kind 'box
                     :children (list base-0 base-1 base-2 overlay)))
         (face-base '(foreground-color "white"))
         (face-overlay '(foreground-color "red" :weight bold))
         (base-records
          (list (list :node base-0 :x 0 :y 0
                      :text (propertize "BASE-0" 'face face-base
                                        'help-echo "base-0"))
                (list :node base-1 :x 0 :y 1
                      :text (propertize "BASE-1" 'face face-base
                                        'help-echo "base-1"))
                (list :node base-2 :x 0 :y 2
                      :text (propertize "BASE-2" 'face face-base
                                        'help-echo "base-2"))))
         (first-records
          (append base-records
                  (list (list :node overlay :x 2 :y 1
                              :text (propertize "DRAG" 'face face-overlay
                                                'keymap '(keymap (13 . ignore)))))))
         (moved-records
          (append base-records
                  (list (list :node overlay :x 2 :y 2
                              :text (propertize "DRAG" 'face face-overlay
                                                'keymap '(keymap (13 . ignore)))))))
         (context '(drag-test 12 3))
         (ebox-layer--composition-context context)
         (first-cache (make-hash-table :test #'equal))
         (moved-cache (make-hash-table :test #'equal))
         (first-calls 0)
         (moved-calls 0)
         (first-lines nil)
         (moved-lines nil)
         first moved cold)
    ;; Cold render seeds the retained ledger for the initial drag position.
    (let ((ebox-layer--previous-composition-cache nil)
          (ebox-layer--composition-cache first-cache)
          (original (symbol-function 'ebox-composite-line)))
      (cl-letf (((symbol-function 'ebox-composite-line)
                 (lambda (&rest args)
                   (cl-incf first-calls)
                   (push (plist-get (car (cadr args)) :y) first-lines)
                   (funcall original (car args) (cadr args) (caddr args)))))
        (setq first (ebox-layer--compose-rows host first-records 12 3))))
    ;; The moved candidate reuses row zero and recomposes exactly old/new rows.
    (let ((ebox-layer--previous-composition-cache first-cache)
          (ebox-layer--composition-cache moved-cache)
          (original (symbol-function 'ebox-composite-line)))
      (cl-letf (((symbol-function 'ebox-composite-line)
                 (lambda (&rest args)
                   (cl-incf moved-calls)
                   (push (plist-get (car (cadr args)) :y) moved-lines)
                   (funcall original (car args) (cadr args) (caddr args)))))
        (setq moved (ebox-layer--compose-rows host moved-records 12 3))))
    (should (= first-calls 3))
    (should (= moved-calls 2))
    (should (equal (nreverse first-lines) '(0 1 2)))
    (should (equal (sort moved-lines #'<) '(1 2)))
    ;; A cold render at the moved position is the oracle for text properties.
    (let ((ebox-layer--previous-composition-cache nil)
          (ebox-layer--composition-cache nil))
      (setq cold (ebox-layer--compose-rows host moved-records 12 3)))
    (should (equal-including-properties moved cold))
    ;; The retained row is the same object, proving ledger reuse rather than
    ;; merely an equivalent recomposition.
    (should (eq (nth 0 moved) (nth 0 first)))
    (should-not (eq (nth 1 moved) (nth 1 first)))
    (should-not (eq (nth 2 moved) (nth 2 first)))))

(ert-deftest ebox-layer-publication-drag-publishes-only-damaged-rows ()
  "A distant layer move publishes two disjoint row patches.

The retained compositor already limits recomposition to the old and new rows.
This regression checks the next boundary too: TP must receive two disjoint
content patches, so the untouched rows between them never enter a buffer
delete/insert operation."
  (ebox-layer-publication-test--with-buffer
    (let ((input
           (ebox-build
            '(column :id "root" :width (ch 12) :height (lh 8)
               (box :id "before" "Before")
               (box :id "host" :width (ch 8) :height (lh 5)
                 (box :id "base0" :width (ch 8) :height (lh 1) "BASE0000")
                 (box :id "base1" :width (ch 8) :height (lh 1) "BASE1111")
                 (box :id "base2" :width (ch 8) :height (lh 1) "BASE2222")
                 (box :id "base3" :width (ch 8) :height (lh 1) "BASE3333")
                 (box :id "base4" :width (ch 8) :height (lh 1) "BASE4444")
                 (box :id "upper" :position absolute :left (px 0)
                   :top (lh 0) :width (ch 8) :height (lh 1)
                   :z-index 1 "UPPER001"))
               (box :id "after" "After")))))
      (ebox-render-to-buffer (current-buffer) input)
      (let* ((before (buffer-string))
             (old-start (+ (point-min) (string-match "UPPER001" before)))
             (new-start (+ (point-min) (string-match "BASE4444" before)))
             (batch-patches nil)
             (changes nil)
             (apply-patches (symbol-function 'tp--commit-batch-apply-patches))
             (ranges (list (cons old-start (+ old-start 8))
                          (cons new-start (+ new-start 8)))))
        (add-hook 'before-change-functions
                  (lambda (beg end) (push (cons beg end) changes)) nil t)
        (cl-letf (((symbol-function 'tp--commit-batch-apply-patches)
                   (lambda (surface batch)
                     (setq batch-patches (tp-commit-batch-patches batch))
                     (funcall apply-patches surface batch))))
          (ebox-region-update "upper" :top '(lh 4)))
        (should (equal
                 '((8 . 16) (48 . 56))
                 (mapcar (lambda (patch)
                           (cons (plist-get patch :old-start)
                                 (plist-get patch :old-end)))
                         batch-patches)))
        (should changes)
        (should
         (cl-every
          (lambda (change)
            (cl-some (lambda (range)
                       (and (<= (car range) (car change))
                            (<= (cdr change) (cdr range))))
                     ranges))
          changes))
        (ebox-layer-publication-test--assert-fresh-render)))))

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

(ert-deftest ebox-layer-publication-visible-mounts-follow-occlusion-and-rollback ()
  "Hide/reveal remounts visible owners and rolls back both TP failure stages."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      '(column :id "root" :width (ch 12) :height (lh 2)
               :padding-inline (ch 2) :background-color "#101117" :color "#DCE0EC"
               :border-top-width (px 1) :border-top-style solid
               :border-top-color "#ABCDEF"
               :border-bottom-width (px 1) :border-bottom-style solid
               :border-bottom-color "#FEDCBA"
        (box :id "host" :width (ch 8) :height (lh 2)
          (box :id "lower" :width (ch 8) :height (lh 2)
               :background-color "#234567" :help-echo "lower"
               "LOWER001\nLOWER002")
          (box :id "upper" :position absolute :width (ch 8) :height (lh 1)
               :background-color "#AABBCC" :help-echo "upper" "UPPER001")))))
    (ebox-region-update "lower" :keymap '(keymap (13 . backward-char)))
    (ebox-region-update "upper" :keymap '(keymap (13 . forward-char)))
    (dolist (failure-step '(text client-state))
      (let ((before (buffer-string))
            (state (ebox--buffer-render-state (current-buffer)))
            (revision (ebox-surface-buffer-revision (current-buffer)))
            (mounts (ebox-layer-publication-test--mount-signature (current-buffer))))
        (let ((tp--surface-publication-step-function
               (lambda (step _surface)
                 (when (eq step failure-step) (error "Reject layer mounts")))))
          (should-error (ebox-region-update "upper" :visibility 'hidden)))
        (should (eq state (ebox--buffer-render-state (current-buffer))))
        (should (= revision (ebox-surface-buffer-revision (current-buffer))))
        (should (equal-including-properties before (buffer-string)))
        (should (equal mounts
                       (ebox-layer-publication-test--mount-signature (current-buffer)))))
      (dolist (visibility '(hidden visible))
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest _) (ert-fail "Layer remount rendered the root"))))
          (ebox-region-update "upper" :visibility visibility))
        (let* ((state (ebox--buffer-render-state (current-buffer)))
               (upper (car (ebox-selector-query-buffer (current-buffer) "#upper")))
               (object (gethash (plist-get upper :node-id)
                                (plist-get state :surface-node-object-table))))
          (should (eq (null (tp-object-mounts object)) (eq visibility 'hidden)))
          (should (eq (null (ebox-surface-region-bounds
                            (current-buffer) (plist-get upper :region-id)))
                      (eq visibility 'hidden)))
          (goto-char (point-min))
          (search-forward (if (eq visibility 'hidden) "LOWER001" "UPPER001"))
          (should (equal (get-text-property (1- (point)) 'help-echo)
                         (if (eq visibility 'hidden) "lower" "upper")))
          (should (eq (lookup-key (get-text-property (1- (point)) 'keymap) (kbd "RET"))
                      (if (eq visibility 'hidden) #'backward-char #'forward-char))))
        (ebox-layer-publication-test--assert-fresh-mounts)))))

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

(ert-deftest ebox-layer-publication-hidden-portals-keep-unrelated-host-local ()
  "Hidden portals cannot widen unrelated local updates, even after a reveal."
  (dolist (hidden-owner '(nil t))
    (ebox-layer-publication-test--with-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build
        `(column :id "root" :width (ch 12) :height (lh 5)
           (box :id "host" :width (ch 8) :height (lh 2)
             (box :id "lower" :width (ch 8) :height (lh 1) "LOWER001")
             (box :id "upper" :position absolute :width (ch 8)
                  :height (lh 1) :z-index 1 "UPPER001"))
           (box :id "portal-owner" :height (lh 1)
                :visibility ,(if hidden-owner 'hidden 'visible)
             (box :id "portal" :position absolute :layer root
                  :width (ch 8) :height (lh 1) :z-index 2
                  :visibility ,(if hidden-owner 'visible 'hidden) "PORTAL01")))))
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (&rest _)
                   (ert-fail "Hidden portal caused an unrelated root render"))))
        (ebox-region-update "lower" :content "LOWER002")
        (ebox-region-update "upper" :visibility 'hidden))
      (should (string-match-p "LOWER002" (buffer-string)))
      (ebox-layer-publication-test--assert-fresh-render)
      (ebox-region-update (if hidden-owner "portal-owner" "portal")
                          :visibility 'visible)
      (should (string-match-p "PORTAL01" (buffer-string)))
      (ebox-region-update "lower" :content "LOWER003")
      (should-not (string-match-p "LOWER003" (buffer-string)))
      (ebox-layer-publication-test--assert-fresh-render)
      (ebox-region-update (if hidden-owner "portal-owner" "portal")
                          :visibility 'hidden)
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (&rest _)
                   (ert-fail "Closed portal retained a stale root dependency"))))
        (ebox-region-update "lower" :content "LOWER004"))
      (should (string-match-p "LOWER004" (buffer-string)))
      (ebox-layer-publication-test--assert-fresh-render))))

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

(defun ebox-layer-publication-test--allocated-input (&rest host-style)
  "Build a host with HOST-STYLE inside a padded parent allocation."
  (ebox-build
   `(column :id "root" :width (ch 24) :height (lh 7)
            :padding ((lh 1) (ch 2))
      (box :id "before" "Before")
      (box :id "host" :height (lh 2) :background-color "#004488"
           ,@host-style
        (box :id "lower" :width (ch 8) :height (lh 1) "LOWER001")
        (box :id "upper" :position absolute :left (px 0) :top (lh 0)
             :width (ch 4) :height (lh 1) :background-color "#884400"
             :help-echo "Upper layer" :pointer hand
             :keymap (keymap (13 . ignore)) "UP01"))
      (box :id "after" "After"))))

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

(ert-deftest ebox-layer-publication-auto-host-keeps-padded-parent-allocation ()
  "An auto-width host keeps its parent's content width during local updates."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-publication-test--allocated-input))
    (cl-letf (((symbol-function 'ebox-surface--render-candidate)
               (lambda (&rest _)
                 (ert-fail "Auto-width layer host rendered the root"))))
      (dolist (left '((ch 1) (ch 0)))
        (ebox-region-update "upper" :left left)
        (ebox-layer-publication-test--assert-fresh-properties)))))

(ert-deftest ebox-layer-publication-allocation-respects-host-box-model ()
  "A local allocation includes margins and content-box padding exactly once."
  (dolist (style '((:width (ch 8) :margin-inline (ch 1))
                   (:width (ch 8) :box-sizing content-box
                    :padding-inline (ch 1))))
    (ert-info ((format "Host style %S" style))
      (ebox-layer-publication-test--with-buffer
        (ebox-render-to-buffer
         (current-buffer)
         (apply #'ebox-layer-publication-test--allocated-input style))
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest _)
                     (ert-fail "Stable host box model rendered the root"))))
          (dolist (left '((ch 1) (ch 0)))
            (ebox-region-update "upper" :left left)
            (ebox-layer-publication-test--assert-fresh-properties)))))))

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

(ert-deftest ebox-layer-publication-owner-geometry-does-not-reuse-allocation ()
  "Owner width, sizing model and margin changes retain the geometry fallback."
  (dolist (case '(((:width (ch 8)) (:width (ch 10)))
                  ((:width (ch 8) :padding-inline (ch 1))
                   (:box-sizing content-box))
                  ((:width (ch 8) :margin-inline (ch 1))
                   (:margin-inline (ch 2)))))
    (ert-info ((format "Host geometry change %S" case))
      (ebox-layer-publication-test--with-buffer
        (ebox-render-to-buffer
         (current-buffer)
         (apply #'ebox-layer-publication-test--allocated-input (car case)))
        (let ((render (symbol-function 'ebox-surface--render-candidate))
              (full-renders 0))
          (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                     (lambda (&rest arguments)
                       (cl-incf full-renders)
                       (apply render arguments))))
            (apply #'ebox-region-update "host" (cadr case)))
          (should (> full-renders 0)))
        (ebox-layer-publication-test--assert-fresh-properties)))))

(ert-deftest ebox-layer-publication-allocated-host-failure-rolls-back ()
  "Failed local text and client-state publication preserve the old allocation."
  (ebox-layer-publication-test--with-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-layer-publication-test--allocated-input))
    (let ((before (buffer-string))
          (revision (ebox-surface-buffer-revision (current-buffer))))
      (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                 (lambda (&rest _)
                   (ert-fail "Allocated layer rollback rendered the root"))))
        (dolist (failure-step '(text client-state))
          (let* ((failed-step nil)
                 (tp--surface-publication-step-function
                  (lambda (step _surface)
                    (when (eq step failure-step)
                      (setq failed-step step)
                      (error "Reject allocated layer %S" step)))))
            (should-error (ebox-region-update "upper" :left '(ch 1)))
            (should (eq failed-step failure-step)))
          (should (= revision (ebox-surface-buffer-revision (current-buffer))))
          (should (equal-including-properties before (buffer-string)))
          (ebox-layer-publication-test--assert-fresh-properties))
        (ebox-region-update "upper" :left '(ch 1))
        (should (= (1+ revision)
                   (ebox-surface-buffer-revision (current-buffer))))
        (should-not (equal-including-properties before (buffer-string)))
        (ebox-layer-publication-test--assert-fresh-properties)))))

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
