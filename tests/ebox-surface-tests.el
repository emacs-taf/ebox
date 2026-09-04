;;; ebox-surface-tests.el --- TP surface projection tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(unless load-file-name
  (error "This test file must be loaded from disk, not eval'ed directly"))

(defvar ebox-native-reflow-module-path)
(setq load-prefer-newer t)
(setq ebox-native-reflow-module-path
      (getenv "EBOX_NATIVE_REFLOW_MODULE_PATH"))

(load-file (expand-file-name "../ebox.el"
                            (file-name-directory load-file-name)))
(require 'tp-surface)
(require 'ebox-native-reflow)

(defmacro ebox-surface-test--with-elisp-backend (&rest body)
  "Run BODY with the explicit Elisp rendering backend."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
              (lambda () nil)))
     ,@body))

(defun ebox-surface-test--reset-render-state ()
  "Reset render identities and side tables used by projection tests."
  (setq ebox--region-id-counter 0
        ebox--runtime-node-id-counter 0)
  (dolist (table (list ebox--region-box-table
                       ebox--scroll-global-state))
    (clrhash table)))

(defun ebox-surface-test--producer (input &optional previous-state)
  "Return an internal surface producer for canonical INPUT."
  (ebox-surface-producer
   (ebox-test-root input) previous-state nil
   (list :source-base-index (ebox-test-source-index input))))

(defun ebox-surface-test--render-runtime (state)
  "Render retained runtime STATE through Ebox's private node boundary."
  (ebox--render-node
   (plist-get state :root-node) (plist-get state :source-index)))

(defun ebox-surface-test--interactive-content ()
  "Return fresh interactive propertized content for projection tests."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'ignore)
    (propertize "Open" 'keymap map 'mouse-face 'highlight
                'help-echo "Open this item")))

(ert-deftest ebox-range-ref-present-p-is-a-read-only-boundary-query ()
  "Expose mounted Range anchor presence without leaking runtime tables."
  (let ((buffer (generate-new-buffer " *ebox-range-anchor-query*"))
        (table (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (puthash 'probe 'record table)
          (cl-letf (((symbol-function 'ebox--buffer-render-state)
                     (lambda (_buffer)
                       (list :range-ref-table table))))
            (should (equal 'record
                           (ebox-range-ref-present-p buffer 'probe)))
            (should-not (ebox-range-ref-present-p buffer 'missing))))
      (kill-buffer buffer))))

(ert-deftest ebox-surface-context-initializes-from-live-window ()
  "Use live window dimensions only when no explicit viewport is bound."
  (let ((buffer (generate-new-buffer " *ebox-live-viewport-test*"))
        (noninteractive nil)
        (ebox-viewport-width nil) (ebox-viewport-height nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (&rest _) nil))
                  ((symbol-function 'window-body-width)
                   (lambda (_window pixelwise)
                     (should pixelwise)
                     777))
                  ((symbol-function 'window-pixel-width)
                   (lambda (_window)
                     (error "Window outer width must not be sampled")))
                  ((symbol-function 'window-body-height)
                   (lambda (_window &optional _pixelwise) 31)))
          (let ((values (ebox-surface--context-values buffer nil nil)))
            (should (= 775 (plist-get values :viewport-width)))
            (should (= 31 (plist-get values :viewport-height)))))
      (kill-buffer buffer))))

(ert-deftest ebox-surface-context-keeps-headless-viewport-nil ()
  "Keep viewport dimensions nil when BUFFER has no live window."
  (let ((buffer (generate-new-buffer " *ebox-headless-viewport-test*"))
        (ebox-viewport-width nil) (ebox-viewport-height nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (&rest _) nil)))
          (let ((values (ebox-surface--context-values buffer nil nil)))
            (should-not (plist-get values :viewport-width))
            (should-not (plist-get values :viewport-height))))
      (kill-buffer buffer))))

(ert-deftest ebox-surface-context-rejects-half-width-pixelwise-report ()
  "Use the outer pixel width when a GUI body query returns a half-width."
  (let ((buffer (generate-new-buffer " *ebox-half-width-viewport-test*"))
        (noninteractive nil)
        (ebox-viewport-width nil) (ebox-viewport-height nil))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (&rest _) nil))
                  ((symbol-function 'window-body-width)
                   (lambda (_window pixelwise)
                     (should pixelwise)
                     715))
                  ((symbol-function 'window-pixel-width)
                   (lambda (_window) 1430))
                  ((symbol-function 'window-body-height)
                   (lambda (_window &optional _pixelwise) 62)))
          (let ((values (ebox-surface--context-values buffer nil nil)))
            (should (= 1428 (plist-get values :viewport-width)))
            (should (= 62 (plist-get values :viewport-height)))))
      (kill-buffer buffer))))

(ert-deftest ebox-surface-window-width-reserves-two-display-columns ()
  "Reserve both continuation columns from a live GUI content width."
  (cl-letf (((symbol-function 'window-body-width)
             (lambda (_window pixelwise)
               (should pixelwise)
               987))
            ((symbol-function 'window-pixel-width)
             (lambda (_window) 987))
            ((symbol-function 'window-frame)
             (lambda (_window) nil))
            ((symbol-function 'frame-char-width)
             (lambda (&optional _frame) 8)))
    (should (= (ebox-surface--window-content-width (selected-window)) 971))))

(ert-deftest ebox-surface-context-prefers-selected-target-window ()
  "Ignore stale cross-frame lookup when selected window shows BUFFER."
  (let* ((buffer (generate-new-buffer " *ebox-selected-viewport-test*"))
         (window (selected-window))
         (old-buffer (window-buffer window))
         (ebox-viewport-width nil) (ebox-viewport-height nil))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (cl-letf (((symbol-function 'get-buffer-window)
                     (lambda (&rest _)
                       (error "Stale cross-frame lookup must not run")))
                    ((symbol-function 'window-body-width)
                     (lambda (candidate pixelwise)
                       (should (eq candidate window))
                       (should pixelwise)
                       1400))
                    ((symbol-function 'window-body-height)
                     (lambda (candidate &optional _pixelwise)
                       (should (eq candidate window))
                       60)))
            (let ((values (ebox-surface--context-values buffer nil nil)))
              (should (= 1398 (plist-get values :viewport-width)))
              (should (= 60 (plist-get values :viewport-height))))))
      (when (window-live-p window) (set-window-buffer window old-buffer))
      (kill-buffer buffer))))

(ert-deftest ebox-surface-context-prefers-current-frame-over-stale-frame ()
  "Do not resize a live surface from an older client frame's window."
  (let ((buffer (generate-new-buffer " *ebox-current-frame-viewport-test*"))
        (noninteractive nil)
        (ebox-viewport-width nil) (ebox-viewport-height nil))
    (unwind-protect
        (cl-letf (((symbol-function 'selected-window)
                   (lambda () 'selected-window))
                  ((symbol-function 'window-live-p)
                   (lambda (_window) t))
                  ((symbol-function 'window-buffer)
                   (lambda (_window) (get-buffer-create " *other-window*")))
                  ((symbol-function 'selected-frame)
                   (lambda () 'current-frame))
                  ((symbol-function 'get-buffer-window)
                   (lambda (_buffer frame)
                     (if (eq frame 'current-frame)
                         'current-frame-window
                       'stale-frame-window)))
                  ((symbol-function 'window-body-width)
                   (lambda (window pixelwise)
                     (should pixelwise)
                     (if (eq window 'current-frame-window) 901 333)))
                  ((symbol-function 'window-body-height)
                   (lambda (_window &optional _pixelwise) 31))
                  ((symbol-function 'ebox--display-signature-for-window)
                   (lambda (window)
                     (should (eq window 'current-frame-window))
                     'current-frame-capability)))
          (let ((values (ebox-surface--context-values buffer nil nil)))
            (should (= 899 (plist-get values :viewport-width)))
            (should (= 31 (plist-get values :viewport-height)))))
      (kill-buffer buffer)
      (when (get-buffer " *other-window*")
        (kill-buffer " *other-window*")))))

(ert-deftest ebox-window-size-change-publishes-every-visible-viewport ()
  "Continuous frame changes publish each sampled viewport immediately."
  (let* ((buffer (generate-new-buffer " *ebox-window-size-change*"))
         (window (selected-window))
         (old-buffer (window-buffer window))
         (sampled-height (window-body-height window))
         (sampled-widths (number-sequence 240 430 10))
         calls)
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (cl-letf (((symbol-function 'ebox--buffer-render-state)
                     (lambda (_buffer)
                       '(:viewport-width 100 :viewport-height 10)))
                    ((symbol-function 'ebox-surface-buffer-mounted-p)
                     (lambda (_buffer) t))
                    ((symbol-function 'ebox-surface--window-content-width)
                     (lambda (_window) (pop sampled-widths)))
                    ((symbol-function 'ebox-rerender-buffer-with-context)
                     (lambda (target width height)
                       (push (list target width height) calls)))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest _)
                       (ert-fail "viewport delivery must not schedule a timer")))
                    (noninteractive nil))
            (dotimes (_index 20)
              (ebox--window-size-change (selected-frame)))
            (should (= (length calls) 20))
            (should
             (equal (mapcar #'cadr (nreverse (copy-sequence calls)))
                    (number-sequence 240 430 10)))
            (should (cl-every (lambda (call)
                                (and (eq (car call) buffer)
                                     (= (nth 2 call) sampled-height)))
                              calls))))
      (set-window-buffer window old-buffer)
      (kill-buffer buffer))))

(ert-deftest ebox-window-size-change-rejects-reentrant-publication ()
  "A viewport commit cannot recursively enter the global size hook."
  (let* ((buffer (generate-new-buffer " *ebox-reentrant-window-size*"))
         (window (selected-window))
         (old-buffer (window-buffer window))
         (sampled-widths '(420 440))
         calls)
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (cl-letf (((symbol-function 'ebox--buffer-render-state)
                     (lambda (_buffer)
                       '(:viewport-width 100 :viewport-height 10)))
                    ((symbol-function 'ebox-surface-buffer-mounted-p)
                     (lambda (_buffer) t))
                    ((symbol-function 'ebox-surface--window-content-width)
                     (lambda (_window) (pop sampled-widths)))
                    ((symbol-function 'window-body-height)
                     (lambda (&rest _) 20))
                    ((symbol-function 'ebox-rerender-buffer-with-context)
                     (lambda (&rest arguments)
                       (push arguments calls)
                       (ebox--window-size-change (selected-frame))))
                    (noninteractive nil))
            (ebox--window-size-change (selected-frame)))
          (should (= (length calls) 1))
          (should (equal sampled-widths '(440))))
      (set-window-buffer window old-buffer)
      (kill-buffer buffer))))

(ert-deftest ebox-window-size-change-restores-guard-after-error ()
  "A failed viewport update cannot leave future window events suppressed."
  (let* ((buffer (generate-new-buffer " *ebox-window-size-error*"))
         (window (selected-window))
         (old-buffer (window-buffer window))
         (fail t)
         calls)
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (cl-letf (((symbol-function 'ebox--buffer-render-state)
                     (lambda (_buffer)
                       '(:viewport-width 100 :viewport-height 10)))
                    ((symbol-function 'ebox-surface-buffer-mounted-p)
                     (lambda (_buffer) t))
                    ((symbol-function 'ebox-surface--window-content-width)
                     (lambda (_window) 420))
                    ((symbol-function 'window-body-height)
                     (lambda (&rest _) 20))
                    ((symbol-function 'ebox-rerender-buffer-with-context)
                     (lambda (&rest arguments)
                       (push arguments calls)
                       (when fail (error "viewport update failed"))))
                    (noninteractive nil))
            (should-error (ebox--window-size-change (selected-frame)))
            (should-not ebox--window-size-change-in-progress)
            (setq fail nil)
            (ebox--window-size-change (selected-frame)))
          (should (= (length calls) 2)))
      (set-window-buffer window old-buffer)
      (kill-buffer buffer))))

(ert-deftest ebox-window-size-change-follows-canonical-display-frame ()
  "A stale frame cannot overwrite a surface owned by another live frame."
  (let ((buffer (generate-new-buffer " *ebox-canonical-frame*"))
        calls)
    (unwind-protect
        (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) t))
                  ((symbol-function 'window-list)
                   (lambda (&rest _) '(event-window)))
                  ((symbol-function 'window-live-p) (lambda (_window) t))
                  ((symbol-function 'window-buffer) (lambda (_window) buffer))
                  ((symbol-function 'window-frame)
                   (lambda (_window) 'canonical-frame))
                  ((symbol-function 'ebox-surface--buffer-display-window)
                   (lambda (_buffer) 'canonical-window))
                  ((symbol-function 'ebox-surface-buffer-mounted-p)
                   (lambda (_buffer) t))
                  ((symbol-function 'ebox--buffer-render-state)
                   (lambda (_buffer)
                     '(:viewport-width 100 :viewport-height 10)))
                  ((symbol-function 'ebox-surface--window-content-width)
                   (lambda (_window) 420))
                  ((symbol-function 'window-body-height)
                   (lambda (&rest _) 20))
                  ((symbol-function 'ebox-rerender-buffer-with-context)
                   (lambda (&rest arguments) (push arguments calls)))
                  (noninteractive nil))
          (ebox--window-size-change 'stale-frame)
          (should-not calls)
          (ebox--window-size-change 'canonical-frame)
          (should (equal calls (list (list buffer 420 20)))))
      (kill-buffer buffer))))

(defun ebox-surface-test--hash-fingerprint (table)
  "Return a stable content fingerprint for hash TABLE.
The fingerprint checks entries rather than only table identity, so a failed
candidate cannot hide mutations by restoring the old hash-table pointer."
  (let ((test (and (hash-table-p table) (hash-table-test table))) entries)
    (when (hash-table-p table)
      (maphash
       (lambda (key value)
         (push (list (if (eq test 'eq)
                         (sxhash-eq key)
                       (sxhash-equal key))
                     (sxhash-equal value))
               entries))
       table))
    (list (length entries)
          (sort entries (lambda (left right)
                          (if (= (car left) (car right))
                            (< (cadr left) (cadr right))
                          (< (car left) (car right))))))))

(ert-deftest ebox-surface-hash-fingerprint-follows-table-key-test ()
  "Fingerprint keys by each table's identity or structural contract."
  (let* ((weak (make-hash-table :test #'eq :weakness 'key))
         (key (list :node 1 :weak weak))
         (eq-table (make-hash-table :test #'eq))
         (equal-table (make-hash-table :test #'equal)))
    (puthash key 'value eq-table)
    (let ((fingerprint (ebox-surface-test--hash-fingerprint eq-table)))
      (puthash (list 'space :width 160) t weak)
      (should (equal fingerprint
                     (ebox-surface-test--hash-fingerprint eq-table))))
    (clrhash eq-table)
    (puthash (make-symbol "replacement") 'value eq-table)
    (let ((fingerprint (ebox-surface-test--hash-fingerprint eq-table)))
      (clrhash eq-table)
      (puthash (make-symbol "replacement") 'value eq-table)
      (should-not
       (equal fingerprint (ebox-surface-test--hash-fingerprint eq-table))))
    (puthash (list :node 1) 'value equal-table)
    (let ((fingerprint (ebox-surface-test--hash-fingerprint equal-table)))
      (clrhash equal-table)
      (puthash (list :node 1) 'value equal-table)
      (should (equal fingerprint
                     (ebox-surface-test--hash-fingerprint equal-table))))))

(defun ebox-surface-test--fixtures ()
  "Return named fresh layout builders covering active Ebox layout kinds."
  (list
   (cons 'box
         (lambda ()
           (ebox-test-box :key 'box (ebox-test-text (ebox-surface-test--interactive-content))
                        :width '(120) :padding '(1 (4))
                        :border "#334155" :bgcolor "#E2E8F0"
                        :color "#0F172A")))
   (cons 'row-column
         (lambda ()
           (ebox-test-column
            (ebox-test-row
             (ebox-test-box :key 'left (ebox-test-text "Left") :width '(70)
                          :bgcolor "#DBEAFE" :color "#172554")
             (ebox-test-box :key 'right (ebox-test-text "Right\nDetail") :width '(90)
                          :bgcolor "#DCFCE7" :color "#14532D"))
            (ebox-test-box :key 'footer (ebox-test-text "Footer") :width '(160)
                         :bgcolor "#F1F5F9" :color "#0F172A"))))
   (cons 'flex
         (lambda ()
           (ebox-test-flex
            :width '(210) :flex-wrap 'wrap :column-gap '(10)
            (ebox-test-flex-item
             (ebox-test-box :key 'grow (ebox-test-text "Grow") :width '(80)
                          :bgcolor "#EDE9FE" :color "#2E1065")
             :flex-grow 1 :flex-basis '(80))
            (ebox-test-flex-item
             (ebox-test-box :key 'fixed (ebox-test-text "Fixed") :width '(120)
                          :bgcolor "#FFEDD5" :color "#7C2D12")))))
   (cons 'grid
         (lambda ()
           (ebox-test-grid
            :width '(220) :grid-template-columns '((70) (fr 1))
            :grid-template-rows '(2) :gap '(1 (8))
            :border "#475569"
            (ebox-test-box :key 'grid-left (ebox-test-text "A\nAA")
                         :bgcolor "#E0F2FE" :color "#0C4A6E")
            (ebox-test-box :key 'grid-right (ebox-test-text "B\nBB")
                         :bgcolor "#FCE7F3" :color "#831843"))))
   (cons 'overflow-scroll
         (lambda ()
           (ebox-test-box :key 'scroll (ebox-test-text "zero\none\ntwo\nthree")
                        :width '(100) :height 2 :overflow 'scroll
                        :bgcolor "#1E293B" :color "#F8FAFC")))))

(defun ebox-surface-test--render-fresh (builder projector-p)
  "Render BUILDER after a reset, using the TP projector when PROJECTOR-P."
  (ebox-surface-test--reset-render-state)
  (let ((ebox-viewport-width 240)
        (ebox-viewport-height 12)
        (input (funcall builder)))
    (if projector-p
        (tp-surface-materialize-string
         (ebox-surface-test--producer input))
      (ebox-render input))))

(defun ebox-surface-test--project-row-column ()
  "Project the row/column fixture through the pure TP materializer."
  (ebox-surface-test--render-fresh
   (cdr (assq 'row-column (ebox-surface-test--fixtures))) t))

(defun ebox-surface-test--canonical-region-properties (rendered)
  "Return RENDERED with opaque region ids renamed by semantic occurrence."
  (let ((copy (copy-sequence rendered))
        (ids (make-hash-table :test #'eql))
        (next-id 0)
        (properties
         (delete-dups
          (append (mapcar #'cdr ebox-region-types)
                  '(ebox-content ebox-content-owner ebox-scroll-window
                    ebox-overflow-foreground-source)))))
    (cl-labels ((canonical
                 (id)
                 (or (gethash id ids)
                     (let ((canonical (cl-incf next-id)))
                       (puthash id canonical ids)
                       canonical))))
      (let ((position 0))
        (while (< position (length copy))
          (let* ((end (or (next-property-change position copy) (length copy)))
                 (props (text-properties-at position copy)))
            (dolist (property properties)
              (when-let* ((id (plist-get props property)))
                (setq props (plist-put props property (canonical id)))))
            (when-let* ((owners (plist-get props 'ebox-content-owners)))
              (setq props
                    (plist-put props 'ebox-content-owners
                               (mapcar #'canonical owners))))
            (set-text-properties position end props copy)
            (setq position end)))))
    copy))

(defun ebox-surface-test--walk-runtime (node function)
  "Call FUNCTION for every runtime NODE in preorder."
  (funcall function node)
  (dolist (child (ebox-tree-node-children node))
    (ebox-surface-test--walk-runtime child function)))

(defun ebox-surface-test--plan-runtime-value-p (value)
  "Return non-nil when VALUE is forbidden runtime state in a pure plan."
  (cond
   ((or (markerp value) (bufferp value) (tp-object-p value)
        (tp-binding-p value) (tp-surface-p value))
    t)
   ((consp value)
    (or (ebox-surface-test--plan-runtime-value-p (car value))
        (ebox-surface-test--plan-runtime-value-p (cdr value))))
   ((vectorp value)
    (cl-some #'ebox-surface-test--plan-runtime-value-p value))
   (t nil)))

(defun ebox-surface-test--plan-pure-p (plan)
  "Return non-nil when PLAN contains only pure projection data."
  (and
   (not (cl-some
         #'ebox-surface-test--plan-runtime-value-p
         (list (tp-surface-plan-key plan)
               (tp-surface-plan-kind plan)
               (tp-surface-plan-text plan)
               (tp-surface-plan-props plan)
               (tp-surface-plan-tags plan))))
   (cl-every #'ebox-surface-test--plan-pure-p
             (tp-surface-plan-children plan))))

(defun ebox-surface-test--object-by-key (state key)
  "Return the candidate surface object for Ebox node KEY in STATE."
  (let (object)
    (maphash
     (lambda (_node-id node)
       (when (equal (plist-get node :key) key)
        (setq object (plist-get node :surface-object))))
     (plist-get state :node-table))
    object))

(defun ebox-surface-test--node-by-key (state key)
  "Return the runtime Ebox node for KEY in STATE."
  (let (match)
    (maphash
     (lambda (_node-id node)
       (when (equal (plist-get node :key) key)
         (setq match node)))
     (plist-get state :node-table))
    match))

(ert-deftest ebox-surface-role-ids-read-one-property-snapshot ()
  "Role extraction preserves the ordered Ebox role mapping."
  (let ((rendered (copy-sequence "x")))
    (add-text-properties
     0 1
     '(ebox-overflow-foreground-source 9
       ebox-content-owners (20 21)
       ebox-content 30
       ebox-content-owner 31
       ebox-pt 32
       ignored-property ignored)
     rendered)
    (should (equal
             (ebox-surface--role-ids-at rendered 0)
             '((overflow-foreground . 9)
               (content-owner . 20)
               (content-owner . 21)
               (content . 30)
               (content-owner . 31)
               (pt . 32))))))

(ert-deftest ebox-surface-role-gap-does-not-mutate-next-run ()
  "A role gap must not destructively change the following run's roles."
  (let* ((rendered
          (concat (propertize "A" 'ebox-pt 1)
                  "gap"
                  (propertize "B" 'ebox-content 2 'ebox-pt 1)))
         (fragments (ebox-surface--rendered-fragments rendered))
         (gap (nth 1 fragments))
         (next (nth 2 fragments)))
    (should (equal (plist-get gap :role-ids)
                   '((pt . 1) (content . 2))))
    (should (equal (plist-get next :paint-role-ids)
                   '((content . 2) (pt . 1))))
    (should (equal (plist-get next :role-ids)
                   '((content . 2) (pt . 1))))))

(ert-deftest ebox-surface-face-provenance-is-string-scoped ()
  "Face provenance replays only for the exact rendered string identity."
  (let* ((rendered (propertize "x" 'face '(:foreground "owned")))
         (registry (make-hash-table :test #'eq))
         (faces (make-hash-table :test #'eq :weakness 'key))
         (ebox--render-owned-text-values registry)
         (ebox--render-output-provenance-table
          (make-hash-table :test #'eq :weakness 'key)))
    (puthash 'face faces registry)
    (puthash (get-text-property 0 'face rendered) t faces)
    (ebox--record-render-output-provenance rendered)
    (let ((ebox--render-owned-text-values (make-hash-table :test #'eq)))
      (ebox--replay-render-output-provenance rendered)
      (should
       (ebox--render-owned-text-value-p
        'face (get-text-property 0 'face rendered))))
    (let ((ebox--render-owned-text-values (make-hash-table :test #'eq)))
      (ebox--replay-render-output-provenance (copy-sequence rendered))
      (should-not
       (ebox--render-owned-text-value-p
        'face (get-text-property 0 'face rendered))))))

(ert-deftest ebox-surface-face-provenance-rejects-caller-face ()
  "Caller-provided face values are never promoted to Ebox-owned values."
  (let* ((caller-face (list :foreground "caller"))
         (source (propertize "x" 'face caller-face))
         (rendered (copy-sequence source))
         (ebox--render-owned-text-values (make-hash-table :test #'eq)))
    (add-face-text-property 0 1 '(:weight bold) t rendered)
    (ebox--register-render-owned-face-values source rendered)
    (should-not
     (ebox--render-owned-text-value-p
      'face (get-text-property 0 'face rendered)))))

(ert-deftest ebox-surface-paint-origin-captures-before-composition ()
  "Capture caller face once before Ebox adds a paint contribution."
  (let* ((caller-face '(:weight bold))
         (rendered (propertize "x" 'face caller-face))
         (ebox--paint-origin-capture-p t))
    (ebox--add-render-face! rendered 0 1 '(:foreground "red") t)
    (let ((origin (get-text-property 0 ebox--paint-origin-property rendered)))
      (should (ebox--paint-origin-p origin))
      (should (equal caller-face
                     (ebox--paint-origin-baseline origin)))
      (should (equal (list caller-face '(:foreground "red"))
                     (get-text-property 0 'face rendered))))
    ;; A nested contribution must not replace the original caller baseline.
    (ebox--add-render-face! rendered 0 1 '(:background "blue") t)
    (should (equal caller-face
                   (ebox--paint-origin-baseline
                   (get-text-property 0 ebox--paint-origin-property
                                      rendered))))))

(ert-deftest ebox-surface-paint-address-is-semantic-and-ordered ()
  "Paint ledger addresses use owner facts, content index, and local order."
  (let ((rendered (copy-sequence "ab")))
    (put-text-property 0 1 'ebox-content-owner 7 rendered)
    (put-text-property 0 1 'ebox-content-idx 3 rendered)
    (put-text-property 0 1 'ebox-content-owners '(7 2) rendered)
    (put-text-property 0 1 'face 'bold rendered)
    (put-text-property 1 2 'ebox-content-owner 7 rendered)
    (put-text-property 1 2 'ebox-content-idx 3 rendered)
    (put-text-property 1 2 'ebox-content-owners '(7 2) rendered)
    (put-text-property 1 2 'face 'italic rendered)
    (let* ((origin (ebox--paint-origin-create :baseline '(:weight bold)))
           (_ (put-text-property 0 2 ebox--paint-origin-property
                                 origin rendered))
           (fragments (ebox-surface--rendered-fragments rendered))
           (first (car fragments))
           (second (cadr fragments))
           (address (plist-get first :paint-address)))
      (should (= (length fragments) 2))
      (should (equal (plist-get address :content-owner) 7))
      (should (= (plist-get address :content-index) 3))
      (should (= (plist-get address :ordinal) 0))
      (should (= (plist-get (plist-get second :paint-address) :ordinal) 1))
      (should (equal (plist-get first :face-baseline) '(:weight bold)))
      (should (plist-get first :face-baseline-known-p))
      (should-not (get-text-property 0 ebox--paint-origin-property rendered)))))

(ert-deftest ebox-native-layout-ir-preserves-default-foreground-face ()
  "Serialize and optionally render the Ebox default foreground reset."
  (let* ((ebox-viewport-width 80)
         (ebox-viewport-height 20)
         (input
          (ebox-test-box
           :width 20
           (ebox-test-text "native")))
         (node (ebox-test-root input))
         (text-node (car (ebox-box-node-children node)))
         (_ (plist-put text-node :color 'ebox/default-foreground))
         (package (ebox-native-reflow--compile-layout-package node))
         (document (plist-get package :document))
         (styles (plist-get document :styles))
         (control
          (ebox-native-reflow--layout-control-json
           document
           '((:key 1 :viewport-width 80 :viewport-height 20
                   :root-width 20 :runtime-revision 0
                   :context-hash 0 :complete t)))))
    (should (stringp control))
    (should
     (cl-find "(:inherit default)" styles
              :key (lambda (style)
                     (plist-get (plist-get style :face) :lisp))
              :test #'equal))
    (when (ebox-native-reflow-layout-ready-p)
      (let ((frame
             (ebox-native-reflow-execute-sync
              node
              '(:key 1 :viewport-width 80 :viewport-height 20
                     :root-width 20 :runtime-revision 0
                     :context-hash 0 :complete t)
              package)))
        (should (plist-get frame :native-frame))
        (should (vectorp
                 (plist-get (plist-get frame :effect-tape)
                            :fragment-span-template)))
        (should (equal-including-properties
                 (plist-get frame :rendered)
                 (ebox-render input)))))))

(ert-deftest ebox-native-canonical-text-matches-elisp-render ()
  "Canonical Text IR must preserve Text output and paint properties exactly."
  (let* ((ebox-viewport-width 80)
         (ebox-viewport-height 20)
         (text-input (ebox-test-text "native" :font-weight 'bold))
         (text (ebox-test-root text-input))
         (input (ebox-test-box text-input))
         (node (ebox-test-root input))
         (package (ebox-native-reflow--compile-layout-package node))
         (root (plist-get (plist-get package :document) :root)))
    (should (eq (plist-get (plist-get package :document) :version) 2))
    (should (equal (plist-get root :type) "box"))
    (should (equal (plist-get root :content-region-id)
                   (ebox--ensure-region-id text)))
    (should (eq (plist-get root :child) :null))
    (when (ebox-native-reflow-layout-ready-p)
      (let ((frame
             (ebox-native-reflow-execute-sync
              node
              '(:key 1 :viewport-width 80 :viewport-height 20
                     :root-width 80 :runtime-revision 0
                     :context-hash 0 :complete t)
              package))
            (normal
             (let ((ebox--surface-materialization-active t)
                   (ebox--paint-origin-capture-p t))
               (ebox--render-layout node))))
        ;; Surface consumes the paint-origin marker into its fragment ledger;
        ;; native tape already carries that baseline out of band.
        (ebox-surface--rendered-fragments normal)
        (should (plist-get frame :native-frame))
        (should (equal-including-properties
                 (plist-get frame :rendered)
                 normal))))))

(ert-deftest ebox-native-layout-effect-fragments-match-render-scan ()
  "Decode native paint fragments without scanning rendered properties."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (let* ((ebox-viewport-width 80)
         (ebox-viewport-height 20)
         (content (propertize "native" 'face 'italic 'help-echo "source"))
         (node (ebox-test-root
                (ebox-test-box (ebox-test-text content) :width 20
                               :color "#f0f0f0" :bgcolor "#101010")))
         (package (ebox-native-reflow--compile-layout-package node))
         (normal
          (let ((ebox--surface-materialization-active t)
                (ebox--paint-origin-capture-p t))
            (ebox--render-layout node)))
         (normal-fragments (ebox-surface--rendered-fragments normal))
         (frame
          (ebox-native-reflow-execute-sync
           node
           '(:key 1 :viewport-width 80 :viewport-height 20
                  :root-width 20 :runtime-revision 0
                  :context-hash 0 :complete t)
           package))
         (native-fragments (ebox-native-reflow-frame-fragments frame)))
    (should (equal-including-properties normal (plist-get frame :rendered)))
    (should (= (length normal-fragments) (length native-fragments)))
    (cl-mapc
     (lambda (normal-fragment native-fragment)
       (dolist (key '(:start :end :line :paint-role-ids :role-ids
                      :paint-address :paint-token :face-baseline
                      :face-baseline-known-p :key))
         (should (equal (plist-get normal-fragment key)
                        (plist-get native-fragment key)))))
     normal-fragments native-fragments)))

(ert-deftest ebox-native-layout-effect-fragments-reject-coordinate-gaps ()
  "Effect templates must cover the rendered frame exactly once."
  (should-error
   (ebox-native-reflow--validate-root-fragment-template
    [[0 1 0 nil nil nil nil nil]
     [2 3 0 nil nil nil nil nil]]
    3 0 0)))

(ert-deftest ebox-surface-fragment-index-rebases-aligned-text-patch ()
  "Scan only an aligned replacement and retain surrounding paint addresses."
  (let ((old (copy-sequence "abcXYZdef"))
        (output (copy-sequence "abcQdef")))
    (cl-mapc
     (lambda (range owner text)
       (put-text-property (car range) (cdr range)
                          'ebox-content-owner owner text))
     '((0 . 3) (3 . 6) (6 . 9)) '(1 2 3) (make-list 3 old))
    (cl-mapc
     (lambda (range owner text)
       (put-text-property (car range) (cdr range)
                          'ebox-content-owner owner text))
     '((0 . 3) (3 . 4) (4 . 7)) '(1 2 3) (make-list 3 output))
    (let* ((old-fragments (ebox-surface--rendered-fragments old))
           (rebased
            (ebox-surface--incremental-patched-fragments
             output old-fragments
             '((:old-start 3 :old-end 6 :new-start 3 :new-end 4)))))
      (should rebased)
      (should (equal (mapcar (lambda (fragment)
                               (cons (plist-get fragment :start)
                                     (plist-get fragment :end)))
                             rebased)
                     '((0 . 3) (3 . 4) (4 . 7))))
      (should (equal (mapcar (lambda (fragment)
                               (plist-get
                                (plist-get fragment :paint-address)
                                :content-owner))
                             rebased)
                     '(1 2 3)))
      (should (cl-every (lambda (fragment)
                          (eq (plist-get fragment :text) output))
                        rebased)))))

(ert-deftest ebox-surface-candidate-plan-copies-face-property-values ()
  "Candidate plans isolate mutable face values despite provenance hints."
  (let* ((color (copy-sequence "#192233"))
         (font (list :family (copy-sequence "caller-font")))
         (face (list :foreground color :font font))
         (display (list 'space :width 2))
         (rendered (copy-sequence "ab"))
         (owned-values (make-hash-table :test #'eq))
         (face-values (make-hash-table :test #'eq))
         (display-values (make-hash-table :test #'eq)))
    (put-text-property 0 1 'face face rendered)
    (put-text-property 1 2 'display display rendered)
    (puthash face t face-values)
    (puthash display t display-values)
    (puthash 'face face-values owned-values)
    (puthash 'display display-values owned-values)
    (let* ((snapshot
            (ebox-surface--candidate-plan-text rendered owned-values))
           (snapshot-face (get-text-property 0 'face snapshot)))
      (should-not (eq snapshot-face face))
      (should-not (eq (plist-get snapshot-face :foreground) color))
      (should-not (eq (plist-get snapshot-face :font) font))
      (should (eq (get-text-property 1 'display snapshot) display)))))

(ert-deftest ebox-surface-projects-every-layout-with-exact-equivalence ()
  "TP projection should preserve every character and text property interval."
  (dolist (fixture (ebox-surface-test--fixtures))
    (let* ((builder (cdr fixture))
           (expected (ebox-surface-test--render-fresh builder nil))
           (actual (ebox-surface-test--render-fresh builder t)))
      (should
       (equal-including-properties
        (ebox-surface-test--canonical-region-properties actual)
        (ebox-surface-test--canonical-region-properties expected)))
      (should (equal (mapcar #'ebox--string-pixel-width
                             (ebox-string-lines actual))
                     (mapcar #'ebox--string-pixel-width
                             (ebox-string-lines expected)))))))

(ert-deftest ebox-surface-assigns-object-identity-before-layout ()
  "Every candidate runtime node should own a TP object before layout starts."
  (let ((original (symbol-function 'ebox--render-layout))
        checked captured)
    (cl-letf (((symbol-function 'ebox--render-layout)
               (lambda (node)
                 (unless checked
                   (setq checked t)
                   (ebox-surface-test--walk-runtime
                    node
                    (lambda (runtime-node)
                      (let ((object (plist-get runtime-node :surface-object)))
                        (should (tp-object-p object))
                        (push object captured)))))
                 (funcall original node))))
      (ebox-surface-test--render-fresh
       (cdr (assq 'grid (ebox-surface-test--fixtures))) t))
    (should checked)
    (should captured)
    (dolist (object captured)
      (should-not (tp-object-live-p object)))))

(ert-deftest ebox-surface-inline-inheritance-keeps-empty-cascade ()
  "Inline inherited values should still compute without stylesheet rules."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create))
        (calls 0)
        (original (symbol-function 'ebox-style-compute-subject)))
    (cl-letf (((symbol-function 'ebox-style-compute-subject)
               (lambda (&rest args)
                 (cl-incf calls)
                 (apply original args))))
      (ebox-surface-test--render-fresh
       (lambda ()
         (ebox-test-box
          :font-size 16
          (ebox-test-box (ebox-test-text "Inherited"))))
       t))
    (should (> calls 0))))

(ert-deftest ebox-surface-inline-inheritance-crosses-transparent-layout ()
  "Transparent layout nodes do not consume inherited paint themselves."
  (let* ((closed-input
         (ebox-test-box
          :color "red"
          (ebox-test-column
           (ebox-test-box
            (ebox-test-text "child" :color "blue")))))
         (closed (ebox-test-root closed-input))
         (open-input
         (ebox-test-box
          :color "red"
          (ebox-test-column (ebox-test-box (ebox-test-text "child")))))
         (open (ebox-test-root open-input)))
    (should-not
     (ebox-surface--inline-inheritance-required-p
      closed
      (ebox-tree-source-index
       closed nil nil (ebox-test-source-index closed-input))))
    (should
     (ebox-surface--inline-inheritance-required-p
      open
      (ebox-tree-source-index
       open nil nil (ebox-test-source-index open-input))))))

(ert-deftest ebox-box-content-cache-reuses-fixed-viewport-subtree ()
  "A fixed box content viewport should reuse its exact composite layout."
  (let* ((ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (ebox--viewport-dependent-node-ids-cache (make-hash-table :test 'eq))
         (ebox--viewport-dependent-subtree-cache (make-hash-table :test 'eq))
         (ebox--viewport-height-dependent-subtree-cache
          (make-hash-table :test 'eq))
         (ebox--render-owned-text-values (make-hash-table :test 'eq))
         (ebox--region-box-table (make-hash-table :test 'equal))
         (ebox--scroll-global-state (make-hash-table :test 'equal))
         (ebox-viewport-width 240)
         (ebox-viewport-height 8)
         (child-input
          (ebox-test-column
           (ebox-test-box :key 'responsive-child
                        (ebox-test-text "fixed local viewport")
                        :width '(viewport)
                        :height 1)))
         (child (ebox-test-root child-input))
         (wrapper-input (ebox-test-box :width '(160)))
         (wrapper (ebox-test-root wrapper-input))
         (ebox--surface-materialization-active t)
         (renders 0)
         (original (symbol-function
                    'ebox--render-cache-render-with-scroll-actions)))
    (cl-letf (((symbol-function 'ebox--render-cache-render-with-scroll-actions)
               (lambda (node)
                 (cl-incf renders)
                 (funcall original node))))
      (let* ((first (ebox--render-node-as-box-content child wrapper))
             (first-render-count renders)
             (second (ebox--render-node-as-box-content child wrapper)))
        (should (> first-render-count 0))
        (should (= renders first-render-count))
        (should (equal-including-properties first second))))))

(ert-deftest ebox-surface-plan-stays-free-of-runtime-state ()
  "The surface plan should not contain markers or runtime handles."
  (require 'ebox-native-commit)
  (let ((original (symbol-function 'tp-surface-result-create))
        (original-owned (symbol-function 'tp-surface-result-create-owned))
        captured client-state)
    (cl-letf (((symbol-function 'ebox-native-commit-render)
               (lambda (&rest _) nil))
              ((symbol-function 'tp-surface-result-create)
               (lambda (plan &optional state)
                 (setq captured plan
                       client-state state)
                 (funcall original plan state)))
              ((symbol-function 'tp-surface-result-create-owned)
               (lambda (context plan &optional state)
                 (setq captured plan
                       client-state state)
                 (funcall original-owned context plan state))))
      (ebox-surface-test--render-fresh
       (cdr (assq 'box (ebox-surface-test--fixtures))) t))
    (should (tp-surface-plan-p captured))
    (should (ebox-surface-test--plan-pure-p captured))
    (should (listp client-state))
    (let* ((fragments-plan (car (tp-surface-plan-children captured)))
           (text-plan (car (tp-surface-plan-children fragments-plan)))
           (plan-text (tp-surface-plan-text text-plan))
           (state-fragments
            (ebox-surface--materialized-fragment-ledger client-state))
           (owner-position
            (cl-loop for position from 0 below (length plan-text)
                     when (get-text-property position
                                              'ebox-content-owners plan-text)
                     return position))
           (plan-owners (and owner-position
                             (get-text-property owner-position
                                                'ebox-content-owners plan-text))))
      (should (cl-every (lambda (fragment)
                          (and (memq :text-source-p fragment)
                               (not (memq :text fragment))
                               (integerp (plist-get fragment :start))
                               (integerp (plist-get fragment :end))))
                        state-fragments))
      (should (integerp owner-position))
      (should (listp plan-owners))
      (setcar plan-owners 'plan-mutated)
      (should (cl-every (lambda (fragment)
                          (not (memq :ebox-content-owners fragment)))
                        state-fragments)))))

(ert-deftest ebox-surface-ancestor-tags-are-candidate-local ()
  "Each projection candidate receives fresh ancestor ownership tags."
  (let* ((region-id 'region)
         (ancestor-id 'ancestor)
         (region-object (make-symbol "region-object"))
         (ancestor-object (make-symbol "ancestor-object"))
         (region-node-table (make-hash-table :test #'equal))
         (parent-table (make-hash-table :test #'equal))
         (node-objects (make-hash-table :test #'equal))
         (region-objects (make-hash-table :test #'equal))
         (role-ids '((content . region))))
    (puthash region-id 'region-node region-node-table)
    (puthash 'region-node ancestor-id parent-table)
    (puthash ancestor-id ancestor-object node-objects)
    (puthash region-id region-object region-objects)
    (let* ((first (ebox-surface--fragment-owners
                   role-ids (list :region-node-table region-node-table
                                  :parent-table parent-table)
                   node-objects region-objects))
           (second (ebox-surface--fragment-owners
                    role-ids (list :region-node-table region-node-table
                                   :parent-table parent-table)
                    node-objects region-objects))
           (first-tags
            (cadr (cl-find ancestor-object first :key #'car :test #'eq)))
           (second-tags
            (cadr (cl-find ancestor-object second :key #'car :test #'eq))))
      (should (equal first-tags '(:ebox/descendant-output t)))
      (should (equal second-tags '(:ebox/descendant-output t)))
      (should-not (eq first-tags second-tags)))))

(ert-deftest ebox-surface-projection-does-not-mutate-a-buffer ()
  "Pure projection should not call any final buffer mutation primitive."
  (let ((probe (generate-new-buffer " *ebox-projection-probe*"))
        (original-insert (symbol-function 'insert))
        (original-erase (symbol-function 'erase-buffer))
        (original-delete (symbol-function 'delete-region))
        (original-replace (symbol-function 'replace-region-contents)))
    (unwind-protect
        (with-current-buffer probe
          (cl-labels ((guarded
                       (label original arguments)
                       (when (eq (current-buffer) probe)
                         (error "Unexpected probe buffer %s" label))
                       (apply original arguments)))
            (cl-letf (((symbol-function 'insert)
                       (lambda (&rest arguments)
                         (guarded 'insert original-insert arguments)))
                      ((symbol-function 'erase-buffer)
                       (lambda (&rest arguments)
                         (guarded 'erase original-erase arguments)))
                      ((symbol-function 'delete-region)
                       (lambda (&rest arguments)
                         (guarded 'delete original-delete arguments)))
                      ((symbol-function 'replace-region-contents)
                       (lambda (&rest arguments)
                         (guarded 'replace original-replace arguments))))
              (should (stringp (ebox-surface-test--project-row-column)))
              (should (equal (buffer-string) "")))))
      (when (buffer-live-p probe) (kill-buffer probe)))))

(ert-deftest ebox-surface-logical-box-owns-disjoint-render-fragments ()
  "One logical Ebox box should resolve all of its separated painted regions."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-fragments*"))
        surface)
    (unwind-protect
        (progn
          (setq surface
                (tp-surface-mount
                 buffer
                 (ebox-surface-test--producer
                  (funcall (cdr (assq 'box (ebox-surface-test--fixtures)))))
                 '(:capability content)))
          (let* ((state (tp-surface-client-state surface))
                 (objects (plist-get state :region-surface-object-table))
                 logical)
            (maphash (lambda (_region-id object)
                       (unless logical (setq logical object)))
                     objects)
            (should (tp-object-live-p logical))
            (should (> (length (tp-object-mounts logical)) 1))))
      (when (and surface (tp-surface-live-p surface))
        (tp-surface-unmount surface))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-surface-reuses-one-source-with-isolated-runtime-state ()
  "One source description should mount into two independent TP surfaces."
  (ebox-surface-test--reset-render-state)
  (let* ((source
          (ebox-test-box :key 'shared (ebox-test-text "Shared") :width '(100)
                       :bgcolor "#E2E8F0" :color "#0F172A"))
         (source-node (ebox-test-root source))
         (first-buffer (generate-new-buffer " *ebox-surface-first*"))
         (second-buffer (generate-new-buffer " *ebox-surface-second*"))
         first second)
    (unwind-protect
        (progn
          (setq first
                (tp-surface-mount
                 first-buffer (ebox-surface-test--producer source)
                 '(:capability content)))
          (setq second
                (tp-surface-mount
                 second-buffer (ebox-surface-test--producer source)
                 '(:capability content)))
          (let* ((first-state (tp-surface-client-state first))
                 (second-state (tp-surface-client-state second))
                 (first-root (plist-get first-state :root-node))
                 (second-root (plist-get second-state :root-node)))
            (should-not (eq first-root second-root))
            (should-not (eq (plist-get first-root :surface-object)
                            (plist-get second-root :surface-object)))
            (should-not (plist-member source-node :node-id))
            (should-not (plist-member source-node :region-id))
            (should-not (plist-member source-node :surface-object))))
      (dolist (surface (list first second))
        (when (and surface (tp-surface-live-p surface))
          (tp-surface-unmount surface)))
      (dolist (buffer (list first-buffer second-buffer))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ebox-surface-keyed-reorder-retains-logical-objects ()
  "A keyed child reorder should retain TP objects through a new Ebox runtime."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-reorder*"))
        surface)
    (unwind-protect
        (let* ((first-source
                (ebox-test-row
                 (ebox-test-box :key 'left (ebox-test-text "Left") :width '(60))
                 (ebox-test-box :key 'right (ebox-test-text "Right") :width '(60))))
               (_mount
                (setq surface
                      (tp-surface-mount
                       buffer (ebox-surface-test--producer first-source)
                       '(:capability content))))
               (first-state (tp-surface-client-state surface))
               (left (ebox-surface-test--object-by-key first-state 'left))
               (right (ebox-surface-test--object-by-key first-state 'right))
               (next-source
                (ebox-test-row
                 (ebox-test-box :key 'right (ebox-test-text "Right!") :width '(60))
                 (ebox-test-box :key 'left (ebox-test-text "Left!") :width '(60)))))
          (tp-surface-update
           surface (ebox-surface-test--producer next-source first-state))
          (let ((next-state (tp-surface-client-state surface)))
            (should (eq left
                        (ebox-surface-test--object-by-key next-state 'left)))
            (should (eq right
                        (ebox-surface-test--object-by-key next-state 'right)))
            (should (string-match-p
                     "Right!.*Left!"
                     (substring-no-properties
                      (with-current-buffer buffer (buffer-string)))))))
      (when (and surface (tp-surface-live-p surface))
        (tp-surface-unmount surface))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-surface-cow-fallback-preserves-published-tree-on-failure ()
  "A widened path candidate must not mutate the published tree before rollback."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-cow-fallback*"))
        (copy-count 0)
        (original-copy (symbol-function 'ebox-tree-copy-node-structure)))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-test-column
            (ebox-test-box :key 'target :id 'target (ebox-test-text "Before")
                         :width '(100))
            (ebox-test-box :key 'sibling (ebox-test-text "Sibling") :width '(100))))
          (let* ((state (ebox--buffer-render-state buffer))
                 (contents
                  (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max))))
                 (handle (ebox-region-resolve buffer "target"))
                 (region-id (cdr (ebox-selector--region-target handle)))
                 (tp--surface-publication-step-function
                  (lambda (step _surface)
                    (when (eq step 'client-state)
                      (error "Reject widened candidate")))))
            (cl-letf (((symbol-function 'ebox-tree-copy-node-structure)
                       (lambda (&rest args)
                         (cl-incf copy-count)
                         (apply original-copy args))))
              (should-error
               (ebox-region-update handle :content "A\nB\nC")))
            (should (> copy-count 0))
            (should (eq (ebox--buffer-render-state buffer) state))
            (should (equal-including-properties
                     (with-current-buffer buffer
                       (buffer-substring (point-min) (point-max)))
                     contents))
            (should (equal (ebox--region-update-content-value
                            (ebox--root-region-box
                             (plist-get state :root-node)
                             region-id))
                           "Before"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-render-uses-isolated-layout-for-static-content ()
  "Static public string rendering should avoid a retained TP object tree."
  (ebox-surface-test--reset-render-state)
  (let ((calls 0)
        (original (symbol-function 'tp-surface-materialize-string)))
    (cl-letf (((symbol-function 'tp-surface-materialize-string)
               (lambda (producer)
                 (cl-incf calls)
                 (funcall original producer))))
      (should (stringp
               (ebox-render
                (ebox-test-box (ebox-test-text "Materialized") :width '(100))))))
    (should (= calls 0))))

(ert-deftest ebox-render-is-repeatable-without-consuming-runtime-identities ()
  "Ephemeral rendering should be exact and leave live identity counters alone."
  (ebox-surface-test--reset-render-state)
  (let* ((source (ebox-test-box (ebox-test-text "Repeatable") :width '(100)))
         (source-node (ebox-test-root source))
         (first (ebox-render source))
         (second (ebox-render source)))
    (should (equal-including-properties first second))
    (should (= ebox--region-id-counter 0))
    (should (= ebox--runtime-node-id-counter 0))
    (should-not (plist-member source-node :region-id))
    (should-not (plist-member source-node :node-id))))

(ert-deftest ebox-render-to-buffer-mounts-one-tp-surface ()
  "The public buffer renderer should expose TP's committed client state."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-public-surface*"))
        surface)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-box (ebox-test-text "Mounted") :width '(100)))
          (setq surface
                (with-current-buffer buffer ebox-surface--buffer-surface))
          (should (tp-surface-live-p surface))
          (should (eq (ebox--buffer-render-state buffer)
                      (tp-surface-client-state surface))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (should-not (tp-surface-live-p surface))))

(ert-deftest ebox-viewport-rerender-publishes-only-through-tp ()
  "A mounted viewport update should advance its TP surface."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-viewport*")))
    (unwind-protect
        (let ((ebox-viewport-width 120)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
              buffer
            (ebox-test-box (ebox-test-text "Viewport") :width '(viewport)))
          (let* ((surface
                  (with-current-buffer buffer ebox-surface--buffer-surface))
                 (signals
                  (with-current-buffer buffer
                    ebox-surface--context-signals))
                 (revision (tp-surface-revision surface)))
            (should (= (tp-signal-peek
                        (ebox-surface--signals-viewport-width signals))
                       120))
            (ebox-rerender-buffer-with-context buffer 180 4)
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should (= (tp-signal-peek
                        (ebox-surface--signals-viewport-width signals))
                       180))
            (should (eq (ebox--buffer-render-state buffer)
                        (tp-surface-client-state surface)))
            (should (= (with-current-buffer buffer
                         (ebox--string-pixel-width
                          (buffer-substring (line-beginning-position)
                                            (line-end-position))))
                       180))
            (let ((report (ebox-buffer-update-report buffer)))
              (should (eq (plist-get report :constraint-source) 'viewport))
              (should (plist-get report :runtime-published)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-reflow-reuses-retained-node-subtree ()
  "A safe viewport reflow should reuse the retained TP node topology."
  (ebox-surface-test--reset-render-state)
  (ebox-surface-test--with-elisp-backend
    (let ((buffer (generate-new-buffer " *ebox-surface-viewport-reflow*"))
        (ensured-node-count 0)
        (runtime-index-count 0)
        (original-ensure (symbol-function 'ebox-surface--ensure-node-tree))
        (original-runtime-index (symbol-function 'ebox--runtime-index)))
    (unwind-protect
        (let ((ebox-viewport-width 180)
              (ebox-viewport-height 6)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
           buffer
           (apply
            #'ebox-test-flex
            :key 'viewport-reflow-root
            :width '(viewport)
            :flex-wrap 'wrap
            :column-gap '(6)
            :row-gap 1
            (cl-loop for index below 12
                     collect
                     (ebox-test-flex-item
                      (ebox-test-box
                       :key (format "viewport-reflow-item-%d" index)
                       (ebox-test-text (format "item-%02d" index))
                       :width '(70)
                       :padding '(0 1)
                       :color "#172554"
                       :bgcolor "#DBEAFE")))))
          (let ((old-root-object
                 (plist-get (plist-get (ebox--buffer-render-state buffer)
                                       :root-node)
                             :surface-object)))
            (cl-letf (((symbol-function 'ebox-surface--ensure-node-tree)
                       (lambda (&rest args)
                         (cl-incf ensured-node-count)
                         (apply original-ensure args))))
              (cl-letf (((symbol-function 'ebox--runtime-index)
                         (lambda (&rest args)
                           (cl-incf runtime-index-count)
                           (apply original-runtime-index args))))
                (ebox-rerender-buffer-with-context buffer 320 6)))
            (let* ((state (ebox--buffer-render-state buffer))
                   (surface (plist-get state :surface))
                   (tp-report (tp-surface-report surface))
                   (expected
                    (let ((ebox-viewport-width 320)
                          (ebox-viewport-height 6))
                      (ebox-surface-test--render-runtime state)))
                   (actual
                    (with-current-buffer buffer
                      (buffer-substring (point-min) (point-max))))
                   (object-count
                    (plist-get (tp-surface-inspect surface) :object-count)))
              (should (= ensured-node-count 0))
              ;; The candidate owns a copied Ebox root, so its node indexes
              ;; must be rebuilt even though TP's retained object topology is
              ;; reused.  This is the COW boundary that keeps rollback pure.
              (should (= runtime-index-count 1))
              (should (<= (plist-get tp-report :reconciled-objects) 4))
              (should (< (plist-get tp-report :reconciled-objects)
                         object-count))
              (should (eq old-root-object
                          (plist-get (plist-get state :root-node)
                                     :surface-object)))
              (should (equal-including-properties actual expected)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))))

(ert-deftest ebox-viewport-resize-retains-native-frame-continuity ()
  "A topology-stable resize should keep the committed native frame session."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-native-viewport-continuity*")))
    (unwind-protect
        (let ((ebox-viewport-width 180)
              (ebox-viewport-height 6)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
           buffer
           (ebox-test-box :key 'native-viewport-root
                          (ebox-test-text "Viewport")
                          :width '(viewport)))
          (let* ((state (ebox--buffer-render-state buffer))
                 (session (list 'native-session))
                 (candidate-session (list 'candidate-native-session))
                 (rendered
                  (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max))))
                 (fragment-template [[0 1 0 nil nil nil nil nil]])
                 (owned-ranges (list (list :start 0 :end 1)))
                 (postorder (vector (plist-get state :root-node))))
            (plist-put state :projection-kind 'native-frame)
            (plist-put state :native-sync-session session)
            (plist-put state :native-sync-pending nil)
            (plist-put state :native-sync-confirmed-p t)
            (plist-put state :native-committed-rendered rendered)
            (plist-put state :native-committed-fragment-template
                       fragment-template)
            (plist-put state :native-committed-owned-ranges owned-ranges)
            (plist-put state :native-node-postorder postorder)
            (cl-letf (((symbol-function
                        'ebox-native-commit-projection-eligible-p)
                       (lambda (&rest _) t))
                      ((symbol-function 'ebox-native-reflow-fork-session)
                       (lambda (_session &rest _) candidate-session)))
              (let* ((display-signature
                      (with-current-buffer buffer
                        (ebox--current-display-signature)))
                     (commit
                      (ebox-incremental-prepare-viewport-commit
                       buffer 320 6 'width display-signature t))
                     (report (plist-get commit :report-base))
                     (overrides (plist-get commit :state-overrides)))
                (should (eq (plist-get commit :projection-kind)
                            'native-frame))
                (should (= (plist-get report :target-viewport-width) 320))
                (should (= (plist-get report :target-viewport-height) 6))
                (should (eq (plist-get overrides :native-sync-session)
                            candidate-session))
                (should-not (eq (plist-get overrides :native-sync-session)
                                session))
                (should-not (plist-get overrides :native-sync-pending))
                (should (plist-get overrides :native-sync-confirmed-p))
                (should (eq (plist-get overrides
                                       :native-committed-rendered)
                            rendered))
                (should (eq (plist-get overrides
                                       :native-committed-fragment-template)
                            fragment-template))
                (should (eq (plist-get overrides
                                       :native-committed-owned-ranges)
                            owned-ranges))
                (should (eq (plist-get overrides :native-node-postorder)
                            postorder))
                (should (plist-get overrides :native-topology-stable-p))
                (should (plist-member overrides :native-touched-node-ids))
                (should-not (plist-get overrides :native-touched-node-ids))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-native-viewport-resize-owns-private-session-lifecycle ()
  "Native resize forks, rolls back, commits, and releases sessions exactly."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-native-viewport-rollback*"))
        candidate-session confirmation-rejected-session committed-session)
    (unwind-protect
        (let ((ebox-viewport-width 180)
              (ebox-viewport-height 6)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
           buffer
           (ebox-test-box :key 'native-viewport-rollback
                          (ebox-test-text "Viewport")
                          :width '(viewport)))
          (let* ((surface
                  (with-current-buffer buffer ebox-surface--buffer-surface))
                 (state (tp-surface-client-state surface))
                 (root (plist-get state :root-node))
                 (root-object (plist-get root :surface-object))
                 (session (plist-get state :native-sync-session))
                 (generation
                  (ebox-native-reflow-session-generation session))
                 (revision (tp-surface-revision surface))
                 (contents
                  (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max))))
                 (original-fork
                  (symbol-function 'ebox-native-reflow-fork-session)))
            (should (eq (plist-get state :projection-kind) 'native-frame))
            (cl-letf
                (((symbol-function 'ebox-native-reflow-fork-session)
                  (lambda (&rest arguments)
                    (setq candidate-session
                          (apply original-fork arguments))))
                 (tp--surface-publication-step-function
                  (lambda (step _surface)
                    (when (eq step 'client-state)
                      (error "Reject native viewport publication")))))
              (should-error
               (ebox-rerender-buffer-with-context buffer 320 6)))
            (should candidate-session)
            (should (ebox-native-reflow-session-released-p
                     candidate-session))
            (should-not (ebox-native-reflow-session-released-p session))
            (should (= (ebox-native-reflow-session-generation session)
                       generation))
            (should (= (tp-surface-revision surface) revision))
            (should (eq (tp-surface-client-state surface) state))
            (should (eq (plist-get (plist-get state :root-node)
                                   :surface-object)
                        root-object))
            (with-current-buffer buffer
              (should (equal-including-properties
                       (buffer-substring (point-min) (point-max))
                       contents)))
            (cl-letf
                (((symbol-function 'ebox-native-reflow-fork-session)
                  (lambda (&rest arguments)
                    (setq confirmation-rejected-session
                          (apply original-fork arguments))))
                 ((symbol-function
                   'ebox-native-reflow-confirm-native-frame)
                  (lambda (&rest _)
                    (error "Reject native confirmation"))))
              (should-error
               (ebox-rerender-buffer-with-context buffer 320 6)))
            (should confirmation-rejected-session)
            (should (ebox-native-reflow-session-released-p
                     confirmation-rejected-session))
            (should-not (ebox-native-reflow-session-released-p session))
            (should (= (tp-surface-revision surface) revision))
            (should (eq (tp-surface-client-state surface) state))
            (let ((report
                   (ebox-rerender-buffer-with-context buffer 320 6)))
              (setq committed-session
                    (plist-get (ebox--buffer-render-state buffer)
                               :native-sync-session))
              (should (eq (plist-get report :projection-kind) 'native-frame))
              (should (eq (plist-get report :native-frame-kind) 'patch))
              (should committed-session)
              (should-not (eq committed-session session))
              (should (ebox-native-reflow-session-released-p session))
              (should-not (ebox-native-reflow-session-released-p
                           committed-session))
              (let ((stats
                     (ebox-native-reflow-stats committed-session)))
                (should (= (plist-get stats :document-parses) 0))
                (should (= (plist-get stats :document-validations) 0))
                (should (= (plist-get stats :document-reuses) 1)))
              (should (plist-get (ebox--buffer-render-state buffer)
                                 :native-sync-confirmed-p))
              (should-not (plist-get (ebox--buffer-render-state buffer)
                                     :native-sync-pending))
              (should (eq (plist-get
                           (plist-get (ebox--buffer-render-state buffer)
                                      :root-node)
                           :surface-object)
                          root-object)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when committed-session
        (should (ebox-native-reflow-session-released-p
                 committed-session))))))

(ert-deftest ebox-native-full-frame-bootstraps-from-ordinary-surface ()
  "Native bootstrap falls back truthfully and remains retryable."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-native-bootstrap*"))
        rejected-session winning-session next-session)
    (unwind-protect
        (let* ((ebox-viewport-width 240)
               (ebox-viewport-height 8)
               (ebox-runtime-idle-prewarm nil)
               (ebox-runtime-idle-reflow-cache-prewarm nil)
               (initial
                (ebox-test-column
                 (ebox-test-box :key 'a (ebox-test-text "A"))
                 (ebox-test-box :key 'b (ebox-test-text "B"))))
               (expanded
                (ebox-test-column
                 (ebox-test-box :key 'a (ebox-test-text "A"))
                 (ebox-test-box :key 'b (ebox-test-text "B"))
                 (ebox-test-box :key 'c (ebox-test-text "C"))))
               (native-source
                (ebox-test-column
                 (ebox-test-box :key 'a (ebox-test-text "A"))
                 (ebox-test-box :key 'b (ebox-test-text "B"))
                 (ebox-test-box :key 'c (ebox-test-text "C"))
                 (ebox-test-box :key 'd (ebox-test-text "D"))))
               (updated
                (ebox-test-column
                 (ebox-test-box :key 'a (ebox-test-text "A"))
                 (ebox-test-box :key 'b (ebox-test-text "B"))
                 (ebox-test-box :key 'c (ebox-test-text "C"))
                 (ebox-test-box :key 'd (ebox-test-text "D"))
                 :bgcolor "#222222")))
          ;; Exercise the normal non-native mount contract; only the later
          ;; structural commit is allowed to bootstrap a private session.
          (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
                     (lambda () nil)))
            (ebox-render-to-buffer buffer initial))
          (let* ((surface
                  (with-current-buffer buffer ebox-surface--buffer-surface))
                 (ordinary-state (tp-surface-client-state surface))
                 (ordinary-root-id
                  (plist-get (plist-get ordinary-state :root-node) :node-id))
                 (ordinary-root-object
                  (gethash ordinary-root-id
                           (plist-get ordinary-state
                                      :surface-node-object-table)))
                 (original-create
                  (symbol-function 'ebox-native-reflow-create-session))
                 (original-render
                  (symbol-function 'ebox-surface--render-candidate-node))
                 (original-project
                  (symbol-function 'ebox-surface--projection-start))
                 (render-count 0)
                 (projection-count 0))
            (should-not (plist-get ordinary-state :native-sync-session))
            (should-not (eq (plist-get ordinary-state :projection-kind)
                            'native-frame))
            (cl-letf
                (((symbol-function 'ebox-native-reflow-create-session)
                  (lambda (&rest arguments)
                    (setq rejected-session
                          (apply original-create arguments))))
                 ((symbol-function 'ebox-native-reflow-execute-session-sync)
                  (lambda (&rest _) (error "Reject native execution")))
                 ((symbol-function 'ebox-surface--render-candidate-node)
                  (lambda (&rest arguments)
                    (cl-incf render-count)
                    (apply original-render arguments)))
                 ((symbol-function 'ebox-surface--projection-start)
                  (lambda (&rest arguments)
                    (cl-incf projection-count)
                    (apply original-project arguments))))
              (let* ((report (ebox-commit buffer expanded))
                     (state (tp-surface-client-state surface))
                     (expected
                      (let ((ebox-viewport-width 240)
                            (ebox-viewport-height 8))
                        (ebox-surface-test--render-runtime state))))
                (should-not (plist-get report :projection-kind))
                (should-not (plist-get report :native-frame-kind))
                (should (eq (plist-get report :strategy)
                            'ordinary-fallback))
                (should (equal (plist-get report :patch-ops)
                               '(tp-surface)))
                (should (eq (plist-get report :render-scope) 'surface))
                (should-not (plist-member report :owner-ids))
                (should-not (plist-member report :owner-type))
                (should (eq (plist-get report :native-attempt) 'failed))
                (should (equal (plist-get report :native-fallback-reason)
                               "Reject native execution"))
                (should (= render-count 1))
                (should (= projection-count 1))
                (should-not (plist-get state :projection-kind))
                (dolist (key ebox-native-commit--failed-render-state-keys)
                  (should-not (plist-member state key)))
                (should-not (plist-member state :native-render-fallback))
                (should (= (plist-get (plist-get state :root-node) :node-id)
                           ordinary-root-id))
                (should (eq (gethash ordinary-root-id
                                     (plist-get state
                                                :surface-node-object-table))
                            ordinary-root-object))
                (with-current-buffer buffer
                  (should (equal-including-properties
                           (buffer-substring (point-min) (point-max))
                           expected)))))
            (should rejected-session)
            (should (ebox-native-reflow-session-released-p rejected-session))
            (let ((report (ebox-commit buffer native-source)))
              (setq winning-session
                    (plist-get (tp-surface-client-state surface)
                               :native-sync-session))
              (should (eq (plist-get report :projection-kind) 'native-frame))
              ;; A bootstrap begins with a full frame; session/compiler
              ;; continuity does not claim a cross-handle Rust patch.
              (should (eq (plist-get report :native-frame-kind) 'full))
              (should winning-session)
              (should-not (plist-get (tp-surface-client-state surface)
                                     :native-sync-pending))
              (should (plist-get (tp-surface-client-state surface)
                                 :native-sync-confirmed-p))
              (should (stringp
                       (plist-get (tp-surface-client-state surface)
                                  :native-committed-rendered)))
              (let ((stats (ebox-native-reflow-stats winning-session)))
                (should (= (plist-get stats :document-parses) 1))
                (should (= (plist-get stats :document-validations) 1))
                (should (= (plist-get stats :document-reuses) 0)))
              (should-not (ebox-native-reflow-session-released-p
                           winning-session)))
            (let ((report (ebox-commit buffer updated)))
              (setq next-session
                    (plist-get (tp-surface-client-state surface)
                               :native-sync-session))
              (should (eq (plist-get report :projection-kind) 'native-frame))
              ;; A style-table change cannot consume the prior confirmed
              ;; document and therefore remains a truthful full frame.
              (should (eq (plist-get report :native-frame-kind) 'full))
              (should next-session)
              (should-not (eq next-session winning-session))
              (should (ebox-native-reflow-session-released-p winning-session))
              (should-not (ebox-native-reflow-session-released-p
                           next-session))
              (let ((stats (ebox-native-reflow-stats next-session)))
                (should (= (plist-get stats :document-parses) 1))
                (should (= (plist-get stats :document-validations) 1))
                (should (= (plist-get stats :document-reuses) 0))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when next-session
        (should (ebox-native-reflow-session-released-p next-session))))))

(ert-deftest ebox-native-appended-style-keeps-a-local-property-patch ()
  "An appended style preserves native and TP locality with exact output."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-native-appended-style*")))
    (unwind-protect
        (cl-labels
            ((source
              (background)
              (apply
               #'ebox-test-column
               (cl-loop
                for index below 32
                collect
                (apply
                 #'ebox-test-box
                 (append
                  (list :key index :source-identity index
                        (ebox-test-text (char-to-string (+ ?A index))))
                  (and (= index 16) background
                       (list :bgcolor background)))))))
             (node-ids
              (state)
              (let (ids)
                (ebox-surface-test--walk-runtime
                 (plist-get state :root-node)
                 (lambda (node) (push (plist-get node :node-id) ids)))
                (nreverse ids))))
          (let ((ebox-viewport-width 240)
                (ebox-viewport-height 40)
                (ebox-runtime-idle-prewarm nil)
                (ebox-runtime-idle-reflow-cache-prewarm nil))
            (ebox-render-to-buffer buffer (source nil))
            (let* ((surface
                    (with-current-buffer buffer ebox-surface--buffer-surface))
                   (old-state (tp-surface-client-state surface))
                   (old-node-ids (node-ids old-state))
                   (report (ebox-commit buffer (source "#224466")))
                   (state (tp-surface-client-state surface))
                   (tp-report (tp-surface-report surface))
                   (expected (ebox-surface-test--render-runtime state))
                   (actual
                    (with-current-buffer buffer
                      (buffer-substring (point-min) (point-max)))))
              (should (eq (plist-get report :projection-kind) 'native-frame))
              (should (eq (plist-get report :native-frame-kind) 'patch))
              (should (= (plist-get tp-report :touched-characters) 2))
              (should (equal (node-ids state) old-node-ids))
              (should (equal-including-properties actual expected)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-reflow-retains-final-sized-flex-child-fragments ()
  "Viewport reflow should reuse final-sized Flex child fragments exactly."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-flex-fragment-retention*"))
        stable-source growing-source)
    (unwind-protect
        (let ((ebox-viewport-width 300)
              (ebox-viewport-height 6)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (setq stable-source
                (ebox-test-column
                 :key 'stable-source
                 (ebox-test-box :key 'stable-leaf
                                (ebox-test-text "zero\none\ntwo")
                                :width '(100)
                                :height 1
                                :overflow 'hidden
                                :surface-properties
                                '(help-echo "stable"))))
          (setq growing-source
                (ebox-test-column
                 :key 'growing-source
                 (ebox-test-box :key 'growing-leaf
                                (ebox-test-text "growing")
                                :width '(viewport)
                                :height 1
                                :color "#0F172A"
                                :bgcolor "#DBEAFE")))
          (cl-letf (((symbol-function 'ebox-native-commit-render)
                     (lambda (&rest _) nil)))
              (let* ((layout
                      (ebox-test-flex
                       :key 'fragment-root
                       :width '(viewport)
                       :height 2
                       :flex-wrap 'nowrap
                       (ebox-test-flex-item stable-source
                                       :flex-grow 0 :flex-basis '(120))
                       (ebox-test-flex-item growing-source
                                           :flex-grow 1 :flex-basis '(80)))))
                (ebox-render-to-buffer buffer layout))
              (let* ((old-state (ebox--buffer-render-state buffer))
                     (old-root-object
                      (plist-get (plist-get old-state :root-node)
                                 :surface-object))
                     (old-stable-object
                      (ebox-surface-test--object-by-key old-state
                                                        'stable-source))
                     report state expected actual)
                ;; Exercise the fragment boundary independently of the
                ;; broader render cache; the published fragment table remains
                ;; the only retained final-sized output for this reflow.
                (clrhash (plist-get old-state :render-cache))
                (setq ebox-fragment-flex-retention-hit-count 0
                      ebox-fragment-flex-retention-rerender-count 0)
                (setq report
                      (ebox-rerender-buffer-with-context buffer 360 6))
                (setq state (ebox--buffer-render-state buffer)
                      expected
                      (let ((ebox-viewport-width 360)
                            (ebox-viewport-height 6))
                        (ebox-surface-test--render-runtime state))
                      actual
                      (with-current-buffer buffer
                        (buffer-substring (point-min) (point-max))))
                (should (eq (plist-get report :projection-kind)
                            'viewport-reflow))
                (should (eq old-root-object
                            (plist-get (plist-get state :root-node)
                                       :surface-object)))
                (should (eq old-stable-object
                            (ebox-surface-test--object-by-key
                             state 'stable-source)))
                (should (equal-including-properties actual expected))
                (should (> ebox-fragment-flex-retention-hit-count 0))
                (should (> ebox-fragment-flex-retention-rerender-count 0))
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (should (text-property-search-forward
                           'help-echo "stable" t))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-fragment-retention-rejects-scroll-installations ()
  "Fragment retention must reject cached scroll state installations."
  (let ((ebox--layout-fragments-table (make-hash-table :test 'equal))
        (ebox--layout-fragments-reuse-p t)
        (ebox-fragment-flex-retention-store-count 0)
        (set-effects
         '(:scroll-actions ((set 9 (:scroll-offset 0 :box old-box)))))
        (clear-effects '(:scroll-actions ((clear 9))))
        (pure-effects '(:scroll-actions nil))
        (entry '(:rendered "stable" :main 20 :cross 1)))
    (should-not
     (ebox-fragment-flex-retained-side-effects-reusable-p set-effects))
    (should-not
     (ebox-fragment-flex-retained-side-effects-reusable-p clear-effects))
    (should
     (ebox-fragment-flex-retained-side-effects-reusable-p pure-effects))
    (should-not
     (ebox-fragment-flex-retained-side-effects-reusable-p nil))
    (ebox-fragment-flex-retention-store 'stable entry set-effects)
    (should (= (hash-table-count ebox--layout-fragments-table) 0))
    (ebox-fragment-flex-retention-store 'stable entry clear-effects)
    (should (= (hash-table-count ebox--layout-fragments-table) 0))
    (ebox-fragment-flex-retention-store 'stable entry pure-effects)
    (should (= (hash-table-count ebox--layout-fragments-table) 1))
    (should (= ebox-fragment-flex-retention-store-count 1))
    (should (ebox-fragment-flex-retention-lookup 'stable))))

(ert-deftest ebox-flex-fragment-key-normalizes-only-height-independent-contexts ()
  "Retained Flex keys ignore height only after an explicit dependency proof."
  (let* ((ebox--layout-fragments-table (make-hash-table :test 'equal))
         (input (ebox-test-box (ebox-test-text "stable") :width '(80)))
         (node (ebox-test-root input)))
    (cl-labels
        ((key-at (height dependency)
           (let ((ebox-viewport-height height))
             (ebox-fragment-flex-allocation-key
              node 'column 1 80 'stretch 80
              (list :viewport-height-dependent dependency)))))
      (should (equal (key-at nil nil) (key-at 36 nil)))
      (should-not (equal (key-at nil t) (key-at 36 t)))
      (should-not (equal (key-at nil :unknown) (key-at 36 :unknown))))))

(ert-deftest ebox-flex-fragment-key-includes-rendered-region-ownership ()
  "Retained Flex output must not replay stale region text properties."
  (let* ((ebox--layout-fragments-table (make-hash-table :test 'equal))
         (source-input (ebox-test-box (ebox-test-text "stable") :width '(80)))
         (source (ebox-test-root source-input))
         (first-key
          (ebox-fragment-flex-allocation-key
           source 'row 80 1 'stretch 80
           '(:viewport-height-dependent nil)))
         (candidate (copy-tree source)))
    ;; Candidate reconciliation can preserve a source node id while replacing
    ;; one generated box region.  The cached string embeds that region in its
    ;; ownership properties, so node identity and geometry alone are unsafe.
    (plist-put candidate :region-id nil)
    (should (= (plist-get source :node-id)
               (plist-get candidate :node-id)))
    (should-not
     (equal first-key
            (ebox-fragment-flex-allocation-key
             candidate 'row 80 1 'stretch 80
             '(:viewport-height-dependent nil))))))

(ert-deftest ebox-flex-fragment-retention-evicts-one-entry-at-capacity ()
  "Fragment retention capacity must evict one old entry, not clear the table."
  (let ((ebox--layout-fragments-table (make-hash-table :test 'equal))
        (ebox-fragment-flex-retention-max-entries 2)
        (effects '(:scroll-actions nil))
        (entry '(:rendered "stable" :main 20 :cross 1)))
    (ebox-fragment-flex-retention-store 'one entry effects)
    (ebox-fragment-flex-retention-store 'two entry effects)
    (ebox-fragment-flex-retention-store 'three entry effects)
    (should (= (hash-table-count ebox--layout-fragments-table) 2))))

(ert-deftest ebox-viewport-reflow-reuses-stable-active-stylesheet ()
  "A viewport change should retain styles only while their signature is stable."
  (ebox-surface-test--reset-render-state)
  (ebox-surface-test--with-elisp-backend
    (let ((ebox-style-stylesheet (ecss-stylesheet-create))
        (buffer (generate-new-buffer " *ebox-viewport-cascade*"))
        (ensured-node-count 0)
        (original-ensure (symbol-function 'ebox-surface--ensure-node-tree)))
    (unwind-protect
        (let ((ebox-viewport-width 160)
              (ebox-viewport-height 6)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-style-add-rule ".viewport-cascade"
                               '(:color "#1D4ED8")
                               :layer 'base)
          (ebox-render-to-buffer
           buffer
           (ebox-test-box :class 'viewport-cascade
                        (ebox-test-text "Cascade")
                        :width '(viewport)))
          (cl-letf (((symbol-function 'ebox-surface--ensure-node-tree)
                     (lambda (&rest args)
                       (cl-incf ensured-node-count)
                       (apply original-ensure args))))
            (ebox-rerender-buffer-with-context buffer 240 6))
          (let ((report (ebox-buffer-update-report buffer)))
            (should (zerop ensured-node-count))
            (should (eq (plist-get report :projection-kind)
                        'viewport-reflow))
            (should (plist-get report :viewport-style-context-stable-p))
            (should (plist-get report :runtime-published)))
          (ebox-style-add-rule ".viewport-cascade"
                               '(:background-color "#DBEAFE")
                               :layer 'base)
          (setq ensured-node-count 0)
          (cl-letf (((symbol-function 'ebox-surface--ensure-node-tree)
                     (lambda (&rest args)
                       (cl-incf ensured-node-count)
                       (apply original-ensure args))))
            (ebox-rerender-buffer-with-context buffer 260 6))
          (let ((report (ebox-buffer-update-report buffer)))
            (should (> ensured-node-count 0))
            (should-not (plist-get report :projection-kind))
            (should (plist-get report :runtime-published))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))))

(ert-deftest ebox-viewport-reflow-retains-stable-inline-inheritance ()
  "Stable inherited Text style should retain its viewport projection exactly."
  (ebox-surface-test--reset-render-state)
  (ebox-surface-test--with-elisp-backend
    (let ((buffer (generate-new-buffer " *ebox-viewport-inheritance*"))
        (ensured-node-count 0)
        (original-ensure (symbol-function 'ebox-surface--ensure-node-tree)))
    (unwind-protect
        (let ((ebox-viewport-width 160)
              (ebox-viewport-height 6)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
           buffer
           (ebox-test-box
            :font-size 16
            :width '(viewport)
            (ebox-test-box (ebox-test-text "Inherited"))))
          (cl-letf (((symbol-function 'ebox-surface--ensure-node-tree)
                     (lambda (&rest args)
                       (cl-incf ensured-node-count)
                       (apply original-ensure args))))
            (ebox-rerender-buffer-with-context buffer 240 6))
          (let* ((state (ebox--buffer-render-state buffer))
                 (report (ebox-buffer-update-report buffer))
                 (expected
                  (let ((ebox-viewport-width 240)
                        (ebox-viewport-height 6))
                    (ebox-surface-test--render-runtime state)))
                 (actual
                  (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max)))))
            (should (= ensured-node-count 0))
            (should (eq (plist-get report :projection-kind)
                        'viewport-reflow))
            (should (plist-get report :viewport-style-context-stable-p))
            (should (plist-get state :cascade-required-p))
            (should (equal-including-properties actual expected))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))))

(ert-deftest ebox-text-style-owns-local-cascade-state ()
  "Persist an independent style owner state for canonical Text."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-shared-text-style-state*")))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 6))
          (ebox-render-to-buffer
           buffer
           (ebox-test-box
            :color "#334155" :width '(viewport)
            (ebox-test-box (ebox-test-text "Inherited"))))
          (let* ((state (ebox--buffer-render-state buffer))
                 (nodes (plist-get state :node-table))
                 (objects (plist-get state :surface-node-object-table))
                 (style-states (plist-get state :style-binding-states))
                 (source-index (plist-get state :source-index))
                 text-id text-node)
            (maphash
             (lambda (node-id node)
               (when (and (eq (plist-get node :ebox-kind) 'text)
                          (equal (plist-get node :content) "Inherited"))
                 (setq text-id node-id text-node node)))
             nodes)
            (should text-id)
            (let* ((parent-id
                    (gethash text-id (plist-get state :parent-table)))
                   (object (gethash text-id objects))
                   (parent-object (gethash parent-id objects))
                   (style-state (gethash object style-states))
                   (parent-state (gethash parent-object style-states))
                   (candidate-node (copy-sequence text-node))
                   (candidate-nodes (copy-hash-table nodes))
                   (candidate-state (copy-sequence state)))
              (should style-state)
              (should parent-state)
              (should-not (eq (plist-get style-state :binding)
                              (plist-get parent-state :binding)))
              (should (eq (plist-get style-state :parent-style-state)
                          parent-state))
              (should
               (equal (ebox-tree-node-id source-index text-node)
                      (ecss-subject-id (plist-get style-state :subject))))
              (should (ebox-surface--static-style-state-p style-state))
              (plist-put candidate-node :ebox-candidate-computed-style-p t)
              (puthash text-id candidate-node candidate-nodes)
              (plist-put candidate-state :node-table candidate-nodes)
              (let ((ebox-incremental--allocated-slot-proof-cache
                     (make-hash-table :test 'equal)))
                (should
                 (ebox-surface--cascade-local-owner-proof-p
                  state candidate-state
                  (list (list :node-id text-id :dirty-kind 'geometry
                              :changed-keys '(:content)))))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-reflow-falls-back-for-scroll-and-visible-overflow ()
  "Nested scroll state and visible overflow must not enter retained reflow."
  (ebox-surface-test--with-elisp-backend
    (dolist (fixture
           (list
            (cons 'nested-scroll
                  (lambda ()
                    (ebox-test-box (ebox-test-text "outer")
                                 :width '(viewport)
                                 :height 2
                                 :overflow 'scroll
                                 (ebox-test-box (ebox-test-text "zero\none\ntwo")
                                              :height 2
                                              :overflow 'scroll))))
            (cons 'visible-overflow
                  (lambda ()
                    (ebox-test-box (ebox-test-text "one\ntwo")
                                 :width '(viewport)
                                 :height 1
                                 :overflow 'visible)))))
    (ebox-surface-test--reset-render-state)
    (let ((buffer (generate-new-buffer
                   (format " *ebox-viewport-%s*" (car fixture))))
          (ensured-node-count 0)
          (original-ensure (symbol-function 'ebox-surface--ensure-node-tree)))
      (unwind-protect
          (let ((ebox-viewport-width 160)
                (ebox-viewport-height 6)
                (ebox-runtime-idle-reflow-cache-prewarm nil))
            (ebox-render-to-buffer buffer (funcall (cdr fixture)))
            (cl-letf (((symbol-function 'ebox-surface--ensure-node-tree)
                       (lambda (&rest args)
                         (cl-incf ensured-node-count)
                         (apply original-ensure args))))
              (ebox-rerender-buffer-with-context buffer 240 6))
            (let ((report (ebox-buffer-update-report buffer)))
              (should (> ensured-node-count 0))
              (should-not (plist-get report :projection-kind))
              (should (plist-get report :runtime-published))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))))))

(ert-deftest ebox-viewport-reflow-retains-viewport-dependent-root-scroll ()
  "A sole root scroll owner may reflow its own viewport-dependent content."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-viewport-root-scroll*"))
        (ensured-node-count 0)
        (original-ensure (symbol-function 'ebox-surface--ensure-node-tree)))
    (unwind-protect
        (let ((ebox-viewport-width 160)
              (ebox-viewport-height 2)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
           buffer
           (ebox-test-box :key 'root-scroll
                        (ebox-test-text "zero\none\ntwo\nthree")
                        :width '(viewport)
                        :height '(viewport-height)
                        :overflow 'scroll))
          (cl-letf (((symbol-function 'ebox-surface--ensure-node-tree)
                     (lambda (&rest args)
                       (cl-incf ensured-node-count)
                       (apply original-ensure args))))
            (ebox-rerender-buffer-with-context buffer 240 2))
          (let* ((state (ebox--buffer-render-state buffer))
                 (report (ebox-buffer-update-report buffer))
                 (expected
                  (let ((ebox-viewport-width 240)
                        (ebox-viewport-height 2))
                    (ebox-surface-test--render-runtime state)))
                 (actual
                  (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max)))))
            (should (= ensured-node-count 0))
            (should (eq (plist-get report :projection-kind)
                        'viewport-reflow))
            (should-not (plist-get report :tp-full-root))
            (should-not (plist-get report :tp-scope-fallback))
            (should (equal-including-properties actual expected))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-reflow-supports-height-and-both-axis-resize ()
  "Retained viewport reflow should cover height-only and two-axis changes."
  (ebox-surface-test--with-elisp-backend
    (dolist (case
           '((height 120 3 120 5 height)
             (both 160 3 240 5 both)))
    (pcase-let ((`(,name ,old-width ,old-height ,new-width ,new-height ,axes)
                 case))
      (ebox-surface-test--reset-render-state)
      (let ((buffer (generate-new-buffer
                     (format " *ebox-viewport-%s*" name)))
            (ensured-node-count 0)
            (original-ensure (symbol-function 'ebox-surface--ensure-node-tree)))
        (unwind-protect
            (let ((ebox-viewport-width old-width)
                  (ebox-viewport-height old-height)
                  (ebox-runtime-idle-reflow-cache-prewarm nil))
              (ebox-render-to-buffer
               buffer
               (ebox-test-box :key name (ebox-test-text "One\nTwo")
                            :width (if (eq axes 'height)
                                       '(120)
                                     '(viewport))
                            :height '(viewport-height)
                            :overflow 'hidden))
              (cl-letf (((symbol-function 'ebox-surface--ensure-node-tree)
                         (lambda (&rest args)
                           (cl-incf ensured-node-count)
                           (apply original-ensure args))))
                (ebox-rerender-buffer-with-context
                 buffer new-width new-height))
              (let ((report (ebox-buffer-update-report buffer)))
                (should (= ensured-node-count 0))
                (should (eq (plist-get report :projection-kind)
                            'viewport-reflow))
                (should (eq (plist-get report :viewport-axes) axes))
                (should (plist-get report :runtime-published))
                (with-current-buffer buffer
                  (should (= (ebox--string-pixel-width
                              (buffer-substring (line-beginning-position)
                                                (line-end-position)))
                             new-width)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))))

(ert-deftest ebox-viewport-reflow-rolls-back-after-publication-failure ()
  "A failed retained viewport publication must restore its old generation."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-viewport-rollback*")))
    (unwind-protect
        (let ((ebox-viewport-width 160)
              (ebox-viewport-height 3)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
           buffer
           (ebox-test-box :key 'rollback
                        (ebox-test-text "zero\none\ntwo\nthree")
                        :width '(viewport)
                        :height '(viewport-height)
                        :overflow 'scroll))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (signals (with-current-buffer
                            buffer ebox-surface--context-signals))
                 (state (tp-surface-client-state surface))
                 (old-root (plist-get state :root-node))
                 (old-root-object (plist-get old-root :surface-object))
                 (old-root-cache (plist-get old-root :render-cache))
                 (old-render-cache (plist-get state :render-cache))
                 (cache-fingerprints
                  (mapcar
                   (lambda (key)
                     (ebox-surface-test--hash-fingerprint
                      (plist-get state key)))
                   '(:render-cache :render-signature-cache
                     :flex-content-min-widths
                     :viewport-height-dependent-subtree-cache
                     :layout-fragments)))
                 (revision (tp-surface-revision surface))
                 (contents (with-current-buffer
                             buffer
                             (buffer-substring (point-min) (point-max)))))
            (let ((tp--surface-publication-step-function
                   (lambda (step _surface)
                     (when (eq step 'client-state)
                       (error "Reject viewport publication")))))
              (should-error
               (ebox-rerender-buffer-with-context buffer 240 5)))
            (should (= (tp-surface-revision surface) revision))
            (should (eq (tp-surface-client-state surface) state))
            (should (= (tp-signal-peek
                        (ebox-surface--signals-viewport-width signals))
                       160))
            (should (= (tp-signal-peek
                        (ebox-surface--signals-viewport-height signals))
                       3))
            (should (eq (ebox--buffer-render-state buffer) state))
            (should (eq (plist-get state :root-node) old-root))
            (should (eq (plist-get old-root :surface-object)
                        old-root-object))
            (should (eq (plist-get old-root :render-cache)
                        old-root-cache))
            (should (eq (plist-get state :render-cache)
                        old-render-cache))
            (should (equal cache-fingerprints
                           (mapcar
                            (lambda (key)
                              (ebox-surface-test--hash-fingerprint
                               (plist-get state key)))
                            '(:render-cache :render-signature-cache
                              :flex-content-min-widths
                              :viewport-height-dependent-subtree-cache
                              :layout-fragments))))
            (should (equal-including-properties
                     (with-current-buffer buffer
                       (buffer-substring (point-min) (point-max)))
                     contents))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-surface-context-signals-track-exact-layout-dependencies ()
  "A mounted producer should subscribe only to context it can consume."
  (ebox-surface-test--reset-render-state)
  (let ((responsive (generate-new-buffer " *ebox-responsive-signals*"))
        (static (generate-new-buffer " *ebox-static-signals*"))
        responsive-signals static-signals)
    (unwind-protect
        (let ((ebox-viewport-width 160)
              (ebox-viewport-height 2))
          (ebox-render-to-buffer
              responsive
            (ebox-test-box (ebox-test-text "zero\none\ntwo\nthree")
                         :width '(viewport)
                         :height '(viewport-height)
                         :overflow 'scroll))
          (setq responsive-signals
                (with-current-buffer responsive
                  ebox-surface--context-signals))
          (dolist (signal
                   (list
                    (ebox-surface--signals-viewport-width
                     responsive-signals)
                    (ebox-surface--signals-viewport-height
                     responsive-signals)
                    (ebox-surface--signals-display responsive-signals)
                    (ebox-surface--signals-scroll responsive-signals)))
            (should (tp-signal-live-p signal))
            (should (= (tp-signal-subscriber-count signal) 1)))
          (ebox-render-to-buffer
              static
            (ebox-test-box (ebox-test-text "Static") :width '(100)))
          (setq static-signals
                (with-current-buffer static ebox-surface--context-signals))
          (should (= (tp-signal-subscriber-count
                      (ebox-surface--signals-viewport-width static-signals))
                     0))
          (should (= (tp-signal-subscriber-count
                      (ebox-surface--signals-viewport-height static-signals))
                     0))
          (should (= (tp-signal-subscriber-count
                      (ebox-surface--signals-display static-signals))
                     1))
          (should (= (tp-signal-subscriber-count
                      (ebox-surface--signals-scroll static-signals))
                     0)))
      (dolist (buffer (list responsive static))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))
    (dolist (signals (list responsive-signals static-signals))
      (when signals
        (dolist (signal
                 (list (ebox-surface--signals-viewport-width signals)
                       (ebox-surface--signals-viewport-height signals)
                       (ebox-surface--signals-display signals)
                       (ebox-surface--signals-scroll signals)))
          (should-not (tp-signal-live-p signal)))))))

(ert-deftest ebox-static-viewport-change-updates-context-without-rendering ()
  "Unused viewport state should change without publishing the surface."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-static-viewport*")))
    (unwind-protect
        (let ((ebox-viewport-width 120)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
              buffer
            (ebox-test-box (ebox-test-text "Static") :width '(100)))
          (let* ((surface
                  (with-current-buffer buffer ebox-surface--buffer-surface))
                 (signals
                  (with-current-buffer buffer
                    ebox-surface--context-signals))
                 (revision (tp-surface-revision surface))
                 (renders 0)
                 (original
                  (symbol-function 'ebox-surface--render-candidate)))
            (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                       (lambda (state)
                         (cl-incf renders)
                         (funcall original state))))
              (ebox-rerender-buffer-with-context buffer 180 4))
            (should (= renders 0))
            (should (= (tp-surface-revision surface) revision))
            (should (= (plist-get (tp-surface-client-state surface)
                                  :viewport-width)
                       180))
            (should (= (tp-signal-peek
                        (ebox-surface--signals-viewport-width signals))
                       180))
            (should (eq (plist-get (ebox-buffer-update-report buffer)
                                   :strategy)
                        'no-op))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-theme-change-rerenders-with-an-unchanged-viewport ()
  "A changed display signature should invalidate a fixed-width surface."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-theme-context*")))
    (unwind-protect
        (let ((ebox-viewport-width 120)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
              buffer
            (ebox-test-box (ebox-test-text "Theme") :width '(100)))
          (let* ((surface
                  (with-current-buffer buffer ebox-surface--buffer-surface))
                 (signals
                  (with-current-buffer buffer
                    ebox-surface--context-signals))
                 (revision (tp-surface-revision surface))
                 (next-signature '(ebox-test-theme dark)))
            (cl-letf (((symbol-function 'ebox--display-signature-for-window)
                       (lambda (_window) next-signature)))
              (ebox-rerender-buffer-with-context buffer 120 4))
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should (equal
                     (tp-signal-peek
                      (ebox-surface--signals-display signals))
                     next-signature))
            (should (equal (plist-get (tp-surface-client-state surface)
                                      :display-signature)
                           next-signature))
            (let ((report (ebox-buffer-update-report buffer)))
              (should (plist-get report :host-context-changed))
              (should (memq :display-signature
                            (plist-get report :dirty-keys))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-inline-style-reuse-projects-onto-fresh-text-node ()
  "A reused computed style must still materialize a fresh Text projection."
  (let* ((foreground "#0F172A")
         (background "#F8FAFC")
         (builder (ebox-source-builder-create))
         (parent-declarations
          (list 'ebox/color foreground
                'ebox/background-color background))
         (parent-handle
          (ebox-source-builder-bind
           builder :identity 'parent :declarations parent-declarations))
         (child-handle
          (ebox-source-builder-bind builder :identity 'child))
         (child-facts (ebox-canonical-facts-from-declarations 'text nil))
         (old-child
          (ebox-text-create
           :value "Old" :source-handle child-handle
           :owned-facts child-facts))
         (new-child
          (ebox-text-create
           :value "New" :source-handle child-handle
           :owned-facts child-facts))
         (parent
          (ebox-box-create
           :layout (ebox-normal-layout-create)
           :children (list old-child)
           :source-handle parent-handle
           :owned-facts
           (ebox-canonical-facts-from-declarations
            'box parent-declarations)))
         (input
          (ebox-canonical-input-create
           (list parent) (ebox-source-builder-finish builder)))
         (source-index
          (ebox-tree-source-index
           parent nil nil (ebox-canonical-input--source-index input)))
         (parent-subject (ebox-tree-node-subject source-index parent))
         (child-subject (ebox-tree-node-subject source-index old-child))
         (parent-style
          (ebox-style-compute-subject
           parent-subject parent-declarations))
         (child-style
          (progn
            (setf (ecss-subject-parent child-subject) parent-subject)
            (ebox-style-compute-subject child-subject nil parent-style)))
         (old-nodes (make-hash-table :test #'eql))
         (new-nodes (make-hash-table :test #'eql))
         (parents (make-hash-table :test #'eql))
         (old-state
          (list :node-table old-nodes :parent-table parents
                :source-index source-index))
         (candidate
          (list :node-table new-nodes :parent-table parents
                :source-index source-index)))
    (ebox-style-apply-computed parent parent-style)
    (ebox-style-apply-computed old-child child-style)
    (plist-put parent :node-id 1)
    (plist-put old-child :node-id 2)
    (plist-put new-child :node-id 2)
    (puthash 1 parent old-nodes)
    (puthash 2 old-child old-nodes)
    (puthash 1 parent new-nodes)
    (puthash 2 new-child new-nodes)
    (puthash 2 1 parents)
    (should-not (plist-get new-child :color))
    (ebox-surface-prepare-inline-candidate-styles
     old-state candidate '(1 2))
    (should (eq child-style (plist-get new-child :ebox-computed-style)))
    (should (equal foreground (plist-get new-child :color)))
    (should (equal "New" (ebox-text-node-value new-child)))
    (should (eq child-handle (ebox-node-source-handle new-child)))
    (dolist (property ebox-tree--participation-keys)
      (should-not (plist-member new-child property)))
    (should (equal background (plist-get parent :bgcolor)))))

(ert-deftest ebox-style-theme-delta-reuses-cascade-facts ()
  "Copy a paint-only Theme delta without rerunning ECSS cascade computation."
  (let* ((subject (ecss-subject-create :type "box"))
         (old-declarations
          '(ebox/width (100) ebox/color "#252A2E"
            ebox/background-color "#F8F5EE"))
         (new-declarations
          '(ebox/width (100) ebox/color "#F2EEE4"
            ebox/background-color "#1B1F20"))
         (old-style
          (ebox-style-compute-subject subject old-declarations))
         (delta
          (ebox-style--theme-delta-computed
           old-style old-declarations new-declarations)))
    (should (ecss-computed-style-p delta))
    (should-not (eq old-style delta))
    (should (equal "#F2EEE4"
                   (ecss-computed-style-value delta 'ebox/color)))
    (should (equal "#1B1F20"
                   (ecss-computed-style-value
                    delta 'ebox/background-color)))
    (should (equal (ecss-computed-style-value old-style 'ebox/width)
                   (ecss-computed-style-value delta 'ebox/width)))
    (should-not
     (ebox-style--theme-delta-computed
      old-style old-declarations
      (plist-put (copy-sequence new-declarations) 'ebox/width '(120))))))

(ert-deftest ebox-style-theme-delta-propagates-inherited-color ()
  "Copy a proven inherited Theme color without rerunning ECSS.
The child has no explicit color declaration; only its static parent color
changes.  Geometry and non-inherited computed values must remain identical."
  (let* ((parent (ecss-subject-create :type "box"))
         (child (ecss-subject-create :type "box" :parent parent))
         (parent-old
          (ebox-style-compute-subject parent '(ebox/color "#111111")))
         (parent-new
          (ebox-style-compute-subject parent '(ebox/color "#222222")))
         (declarations '(ebox/width (100) ebox/background-color "#eeeeee"))
         (style
          (ebox-style-compute-subject child declarations parent-old))
         (delta
          (ebox-style--theme-inherited-delta-computed
           style declarations parent-old parent-new)))
    (should (ecss-computed-style-p delta))
    (should (equal "#222222"
                   (ecss-computed-style-value delta 'ebox/color)))
    (should (equal (ecss-computed-style-value style 'ebox/width)
                   (ecss-computed-style-value delta 'ebox/width)))
    (should (equal (ecss-computed-style-value style 'ebox/background-color)
                   (ecss-computed-style-value
                    delta 'ebox/background-color)))))

(ert-deftest ebox-style-theme-parent-delta-reuses-explicit-child-style ()
  "Reuse an explicit child style when only its static parent Theme changes."
  (let* ((parent (ecss-subject-create :type "box"))
         (child (ecss-subject-create :type "box" :parent parent))
         (parent-old
          (ebox-style-compute-subject parent '(ebox/color "#111111")))
         (parent-new
          (ebox-style-compute-subject parent '(ebox/color "#222222")))
         (declarations '(ebox/color "#ffffff" ebox/width (100)))
         (style
          (ebox-style-compute-subject child declarations parent-old))
         (delta
          (ebox-style--theme-parent-delta-computed
           style declarations parent-old parent-new)))
    (should (ecss-computed-style-p delta))
    (should (equal (ecss-computed-style-values style)
                   (ecss-computed-style-values delta)))
    (let ((parent-font-new
           (ebox-style-compute-subject
            parent '(ebox/color "#222222" ebox/font-size 20))))
      (should-not
       (ebox-style--theme-parent-delta-computed
        style declarations parent-old parent-font-new)))))

(ert-deftest ebox-tree-source-signature-ignores-derived-width-proof ()
  "A layout-derived exact-width flag must not dirty declarative content."
  (let* ((input (ebox-test-box (ebox-test-text "Stable") :width '(100)))
         (old (ebox-test-root input))
         (new (copy-tree old)))
    (plist-put old :ebox-content-width-exact-p nil)
    (plist-put new :ebox-content-width-exact-p t)
    (should (equal (ebox-tree-node-local-source-signature old)
                   (ebox-tree-node-local-source-signature new)))
    (should-not (memq :ebox-content-width-exact-p
                      (ebox-tree-node-local-changed-keys old new)))))

(ert-deftest ebox-tree-grid-source-signature-canonicalizes-gap-shorthand ()
  "Equivalent Grid gap forms must not become geometry dirtiness."
  (let ((old (list :ebox-type 'grid
                   :raw-props '(:width stretch
                                :grid-template-columns ((fr 1) (fr 1))
                                :row-gap 1 :column-gap (12)
                                :color "#252A2E" :background-color "#F8F5EE")))
        (new (list :ebox-type 'grid
                   :raw-props '(:width stretch
                                :grid-template-columns ((fr 1) (fr 1))
                                :gap (1 (12))
                                :color "#F2EEE4" :bgcolor "#1B1F20"))))
    (should-not (memq :props (ebox-tree-node-local-changed-keys old new)))
    (should-not (memq :raw-props (ebox-tree-node-local-changed-keys old new)))))

(ert-deftest ebox-tree-flex-source-signature-canonicalizes-layout-aliases ()
  "Equivalent Flex gap aliases must not become geometry dirtiness."
  (let ((old (list :ebox-type 'flex
                   :raw-props '(:width stretch
                                :row-gap 1 :column-gap (12)
                                :padding-block-start 0
                                :padding-inline-end 2
                                :padding-block-end 0
                                :padding-inline-start 2
                                :border-top-width 1
                                :border-right-width 1
                                :border-bottom-width 1
                                :border-left-width 1
                                :border-top-style solid
                                :border-right-style solid
                                :border-bottom-style solid
                                :border-left-style solid
                                :border-top-color "#687386"
                                :border-right-color "#687386"
                                :border-bottom-color "#687386"
                                :border-left-color "#687386"
                                :align-items center
                                :color "#252A2E"
                                :background-color "#F8F5EE")))
        (new (list :ebox-type 'flex
                   :raw-props '(:width stretch
                                :gap (1 (12))
                                :padding (0 2)
                                :border (1 solid "#687386")
                                :align-items center
                                :color "#F2EEE4"
                                :bgcolor "#1B1F20"))))
    (should-not (memq :props (ebox-tree-node-local-changed-keys old new)))
    (should-not (memq :raw-props (ebox-tree-node-local-changed-keys old new)))))

(ert-deftest ebox-style-theme-delta-rejects-inherited-parent-change ()
  "Do not reuse a child style when its inherited parent fingerprint changes."
  (let* ((parent (ecss-subject-create :type "box"))
         (child (ecss-subject-create :type "box" :parent parent))
         (parent-old
         (ebox-style-compute-subject
           parent '(ebox/font-size 16)))
         (parent-new
         (ebox-style-compute-subject
           parent '(ebox/font-size 20)))
         (declarations '(ebox/color "#ffffff"))
         (style
          (ebox-style-compute-subject child declarations parent-old)))
    (should-not
     (ebox-style--theme-delta-computed
      style declarations declarations parent-old parent-new))))

(ert-deftest ebox-style-theme-delta-rejects-parent-custom-property-change ()
  "Do not reuse a Theme delta when a parent custom property changes."
  (let* ((parent (ecss-subject-create :type "box"))
         (child (ecss-subject-create :type "box" :parent parent))
         (parent-old
          (ebox-style-compute-subject parent '(--theme "#ffffff")))
         (parent-new
          (ebox-style-compute-subject parent '(--theme "#000000")))
         (old-declarations
          '(ebox/color "#ffffff" ebox/background-color "#ffffff"))
         (new-declarations
          '(ebox/color "#eeeeee" ebox/background-color "#eeeeee"))
         (style
          (ebox-style-compute-subject child old-declarations parent-old)))
    (should-not
      (ebox-style--theme-delta-computed
       style old-declarations new-declarations parent-old parent-new))))

(ert-deftest ebox-style-paint-declarations-equivalent-includes-border-colors ()
  "Pressed/hover paint changes must not invalidate layout style closure."
  (should
   (ebox-style--paint-declarations-equivalent-p
    '(ebox/color "#ffffff"
      ebox/background-color "#2f6b43"
      ebox/border-top-color "#2f6b43"
      ebox/border-right-color "#2f6b43"
      ebox/border-bottom-color "#2f6b43"
      ebox/border-left-color "#2f6b43")
    '(ebox/color "#ffffff"
      ebox/background-color "#1e5a56"
      ebox/border-top-color "#174a47"
      ebox/border-right-color "#174a47"
      ebox/border-bottom-color "#174a47"
      ebox/border-left-color "#174a47")))
  (should-not
   (ebox-style--paint-declarations-equivalent-p
    '(ebox/color "#ffffff" ebox/width max-content)
    '(ebox/color "#ffffff" ebox/width stretch))))

(ert-deftest ebox-render-to-buffer-reuses-one-source-across-buffers ()
  "The public mount path should never transfer ownership of its source tree."
  (ebox-surface-test--reset-render-state)
  (let* ((source
          (ebox-test-box :key 'shared (ebox-test-text "Shared") :width '(100)))
         (first (generate-new-buffer " *ebox-public-first*"))
         (second (generate-new-buffer " *ebox-public-second*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer first source)
          (ebox-render-to-buffer second source)
          (should (equal
                   (with-current-buffer first
                     (substring-no-properties (buffer-string)))
                   (with-current-buffer second
                     (substring-no-properties (buffer-string)))))
          (should-not
           (equal (ebox-region-ids (ebox--buffer-root-node first))
                  (ebox-region-ids (ebox--buffer-root-node second))))
          (should-not
           (eq (plist-get (ebox--buffer-root-node first) :surface-object)
               (plist-get (ebox--buffer-root-node second) :surface-object)))
          (let ((source-node (ebox-test-root source)))
            (should-not (plist-member source-node :node-id))
            (should-not (plist-member source-node :region-id))
            (should-not (plist-member source-node :surface-object))))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ebox-mounted-render-uses-target-display-context ()
  "A mounted candidate must measure in its target buffer's display context."
  (ebox-surface-test--reset-render-state)
  (let* ((source (generate-new-buffer " *ebox-context-source*"))
         (target (generate-new-buffer " *ebox-context-target*"))
         (node (ebox-test-box (ebox-test-text "MMMM") :width '(100)))
         (seen-buffers nil)
         (original (symbol-function 'ebox--render-layout)))
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local text-scale-mode-amount 3))
          (with-current-buffer target
            (setq-local text-scale-mode-amount 0))
          (cl-letf (((symbol-function 'ebox--render-layout)
                     (lambda (candidate)
                       (push (current-buffer) seen-buffers)
                       (funcall original candidate))))
            (with-current-buffer source
              (ebox-render-to-buffer target node)))
          (should seen-buffers)
          (should (cl-every (lambda (buffer) (eq buffer target))
                            seen-buffers)))
      (dolist (buffer (list source target))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ebox-commit-publishes-through-the-mounted-tp-surface ()
  "Declarative commits should publish through the mounted TP surface."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-commit*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :key 'root (ebox-test-text "Before") :width '(100)))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (revision (tp-surface-revision surface))
                 report)
            (setq report
                  (ebox-commit
                   buffer
                   (ebox-test-box :key 'root (ebox-test-text "After")
                                :width '(100))))
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should (plist-get report :runtime-published))
            (should (equal report (ebox-buffer-update-report buffer)))
            (should (string-match-p "After" (with-current-buffer
                                                buffer (buffer-string))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-callback-failure-rolls-back-tp-and-ebox-state ()
  "A failed publication callback should restore one shared old generation."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-rollback*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :key 'root (ebox-test-text "Stable") :width '(100)))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (state (tp-surface-client-state surface))
                 (revision (tp-surface-revision surface))
                 (contents (with-current-buffer
                             buffer
                             (buffer-substring (point-min) (point-max)))))
            (should-error
             (ebox-commit
              buffer
              (ebox-test-box :key 'root (ebox-test-text "Rejected") :width '(100))
              (lambda (_report) (error "Reject publication"))))
            (should (= (tp-surface-revision surface) revision))
            (should (eq (tp-surface-client-state surface) state))
            (should (equal-including-properties
                     (with-current-buffer
                       buffer
                       (buffer-substring (point-min) (point-max)))
                     contents))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-context-signal-rolls-back-with-failed-publication ()
  "A failed Ebox publication should restore its TP context source."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-context-rollback*")))
    (unwind-protect
        (let ((ebox-viewport-width 120)
              (ebox-viewport-height 4))
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :key 'root (ebox-test-text "Stable")
                         :width '(viewport)))
          (let* ((surface
                  (with-current-buffer buffer ebox-surface--buffer-surface))
                 (signals
                  (with-current-buffer buffer
                    ebox-surface--context-signals))
                 (width-signal
                  (ebox-surface--signals-viewport-width signals))
                 (state (tp-surface-client-state surface))
                 (revision (tp-surface-revision surface))
                 (contents
                  (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max)))))
            (should-error
             (ebox-surface-mount-buffer
              buffer
              (ebox-test-box :key 'root (ebox-test-text "Rejected")
                           :width '(viewport))
              (ebox--update-report nil 'root-rerender)
              (lambda (_report) (error "Reject context publication"))
              nil
              '(:viewport-width 180 :viewport-height 4)))
            (should (= (tp-signal-peek width-signal) 120))
            (should (= (tp-surface-revision surface) revision))
            (should (eq (tp-surface-client-state surface) state))
            (should (equal-including-properties
                     (with-current-buffer buffer
                       (buffer-substring (point-min) (point-max)))
                     contents))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-commit-killed-buffer-rollback-does-not-revive-runtime ()
  "A failed commit must not restore runtime state for a killed buffer."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-killed-rollback*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :key 'root (ebox-test-text "Stable") :width '(100)))
          (should (gethash buffer ebox--buffer-render-state-table))
          (should-error
           (ebox-commit
            buffer
            (ebox-test-box :key 'root (ebox-test-text "Rejected") :width '(100))
            (lambda (_report)
              (kill-buffer buffer)
              (error "Reject publication after teardown"))))
          (should-not (buffer-live-p buffer))
          (should-not (gethash buffer ebox--buffer-render-state-table)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-logical-candidate-report-is-the-published-client-report ()
  "Logical candidates should publish one report through TP client state."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-candidate*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :key 'root :source-identity 'root
                         (ebox-test-text "Before") :width '(100)))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'root
             (ebox-test-box :key 'root :source-identity 'root
                          (ebox-test-text "After") :width '(100)))
            (let ((report (ebox-commit buffer candidate)))
              (should (equal report (ebox-buffer-update-report buffer)))
              (should (eq (plist-get report :constraint-source)
                          'declarative))
              (should (string-match-p "After" (with-current-buffer
                                                  buffer (buffer-string)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-scroll-finalization-contains-each-error-and-quit ()
  "Post-TP scroll actions report failures without skipping later actions."
  (let ((ebox--scroll-global-state (make-hash-table :test 'equal))
        (ebox--smooth-scroll-state-table (make-hash-table :test 'equal))
        trace diagnostics)
    (cl-letf (((symbol-function 'ebox--scroll-cancel-idle-prefetch)
               (lambda (region-id)
                 (push (list 'cancel region-id) trace)
                 (error "cancel failure")))
              ((symbol-function 'ebox--smooth-scroll-stop)
               (lambda (region-id)
                 (push (list 'stop region-id) trace)
                 (signal 'quit nil))))
      (setq diagnostics
            (ebox-incremental--finalize-declarative-scroll-publication
             '(one two))))
    (should (equal (nreverse trace)
                   '((cancel one) (stop one) (cancel two) (stop two))))
    (should (= (length diagnostics) 4))
    (should (equal (mapcar (lambda (entry) (plist-get entry :action))
                           diagnostics)
                   '(cancel-prefetch stop-smooth-scroll
                     cancel-prefetch stop-smooth-scroll)))))

(ert-deftest ebox-region-handles-are-surface-scoped ()
  "One logical id should resolve to distinct handles on independent surfaces."
  (ebox-surface-test--reset-render-state)
  (let* ((source
          (ebox-test-box :id "status" (ebox-test-text "Ready") :width '(100)))
         (first (generate-new-buffer " *ebox-handle-first*"))
         (second (generate-new-buffer " *ebox-handle-second*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer first source)
          (ebox-render-to-buffer second source)
          (let ((first-handle (ebox-region-resolve first "status"))
                (second-handle (ebox-region-resolve second 'status)))
            (should (ebox-region-handle-p first-handle))
            (should (ebox-region-handle-p second-handle))
            (should-not (eq first-handle second-handle))
            (ebox-region-update first-handle :content "Changed")
            (should (string-match-p "Changed"
                                    (with-current-buffer first
                                      (buffer-string))))
            (should (string-match-p "Ready"
                                    (with-current-buffer second
                                      (buffer-string))))))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ebox-region-handle-update-publishes-through-tp ()
  "A canonical Text content update should publish once through TP."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-scoped-handle*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-column
             (ebox-test-box :id "left" (ebox-test-text "Left") :width '(100))
             (ebox-test-box :id "right" (ebox-test-text "Right") :width '(100))))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (revision (tp-surface-revision surface))
                 (handle (ebox-region-resolve buffer "left"))
                 report)
            (setq report
                  (ebox-region-update handle :content "Changed"))
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should (plist-get report :runtime-published))
            (should (> (plist-get (tp-surface-report surface)
                                  :text-operations)
                       0))
            (should (string-match-p
                     "Changed"
                     (with-current-buffer buffer (buffer-string))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-region-update-preserves-point-after-incremental-publication ()
  "An incremental Ebox content update must not leave point at its patch."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-point-preservation*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-test-box :id "target" (ebox-test-text "before target after")
                        :width '(200)))
          (with-current-buffer buffer (goto-char 4))
          (let ((point-before (with-current-buffer buffer (point))))
            (ebox-region-update (ebox-region-resolve buffer "target")
                                :content "before changed-target after")
            (should (= point-before
                       (with-current-buffer buffer (point))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-region-update-rejects-process-global-region-ids ()
  "Direct updates should require a surface-scoped region handle."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-handle-only-update*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :id "target" (ebox-test-text "Before") :width '(100)))
          (let* ((match (car (ebox-selector-query-buffer buffer "#target")))
                 (region-id (plist-get match :region-id)))
            (should-error (ebox-region-update region-id :content "Wrong")
                          :type 'wrong-type-argument)
            (ebox-region-update (plist-get match :region-handle)
                                :content "After")
            (should (string-match-p
                     "After"
                     (with-current-buffer buffer (buffer-string))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-selector-query-returns-an-editable-region-handle ()
  "A live selector match should carry the same handle accepted by updates."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-selector-handle*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :id "action" (ebox-test-text "Closed") :width '(100)))
          (let* ((match (car (ebox-selector-query-buffer buffer "#action")))
                 (handle (plist-get match :region-handle)))
            (should (ebox-region-handle-p handle))
            (ebox-region-update handle :content "Open")
            (should (string-match-p "Open"
                                    (with-current-buffer buffer
                                      (buffer-string))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-region-handle-becomes-stale-with-its-object ()
  "A handle should fail after a commit removes its retained object."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-stale-handle*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :key 'old :id "old"
                         (ebox-test-text "Old") :width '(100)))
          (let ((handle (ebox-region-resolve buffer "old")))
            (ebox-commit
             buffer
             (ebox-test-box :key 'new :id "new"
                          (ebox-test-text "New") :width '(100)))
            (should-error (ebox-region-update handle :content "Invalid")
                          :type 'user-error)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-scroll-update-publishes-only-through-tp ()
  "A mounted scroll update should advance one TP surface revision."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-scroll*")))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :id "scroll" (ebox-test-text "zero\none\ntwo\nthree")
                         :width '(120) :height 2 :overflow 'scroll))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (signals
                  (with-current-buffer buffer
                    ebox-surface--context-signals))
                 (revision (tp-surface-revision surface))
                 (region-id
                  (plist-get
                   (car (ebox-selector-query-buffer buffer "#scroll"))
                   :region-id)))
            (should (= (ebox--scroll-region-by region-id 1 1) 1))
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should (= (alist-get
                        region-id
                        (tp-signal-peek
                         (ebox-surface--signals-scroll signals)))
                       1))
            (let* ((state (tp-surface-client-state surface))
                   (root (plist-get state :root-node))
                   (text (with-current-buffer buffer
                           (buffer-substring-no-properties
                            (point-min) (point-max)))))
              (should (= (ebox-get (ebox--root-region-box root region-id)
                                   :scroll-offset)
                         1))
              (should (= (plist-get (ebox-scroll-state region-id)
                                    :scroll-offset)
                         1))
              (should (string-match-p "one" text))
              (should (string-match-p "two" text))
              (should-not (string-match-p "zero" text)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-scroll-patch-reuses-visible-lines-and-retains-region-index ()
  "A chrome-free root scroll patch must avoid layout and keep all regions indexed."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-scroll-visible-window*")))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (full-renders 0))
          (ebox-render-to-buffer
           buffer
           (ebox-test-box :id "scroll" (ebox-test-text (mapconcat #'number-to-string (number-sequence 0 31) "\n"))
                        :width '(120) :height 2 :overflow 'scroll))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (region-id
                 (plist-get
                   (car (ebox-selector-query-buffer buffer "#scroll"))
                   :region-id))
                 (old-state (tp-surface-client-state surface)))
            ;; Materialize this tiny fixture so the direct visible-window
            ;; proof is exercised rather than the lazy-prefix fallback.
            (let ((scroll-state
                   (ebox--scroll-state-materialize-lines
                    region-id (ebox--scroll-get-state region-id))))
              (puthash region-id scroll-state ebox--scroll-global-state))
              (let ((owner-plan-calls 0)
                    (original-owner-plan
                     (symbol-function
                      'ebox-incremental--layout-owner-plan)))
                (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                           (lambda (&rest _)
                             (cl-incf full-renders)
                             (error "full root render used by scroll patch")))
                          ((symbol-function
                            'ebox-incremental--layout-owner-plan)
                           (lambda (&rest args)
                             (cl-incf owner-plan-calls)
                             (apply original-owner-plan args))))
                  (should (= (ebox--scroll-region-by region-id 1 1) 1)))
                (should (= owner-plan-calls 0)))
            (let* ((report (ebox-buffer-update-report buffer))
                   (state (tp-surface-client-state surface))
                   (region-table (plist-get state :region-box-table))
                   (region-set (plist-get state :region-id-set))
                   (text (with-current-buffer buffer
                           (buffer-substring-no-properties
                            (point-min) (point-max)))))
              (should (= full-renders 0))
              (should (eq (plist-get report :projection-kind) 'scroll-patch))
              (should-not (plist-get report :tp-full-root))
              (should-not (plist-get report :tp-scope-fallback))
              (should (= (hash-table-count region-table)
                         (hash-table-count region-set)))
              (maphash
               (lambda (id node)
                 (should (eq node
                             (gethash (gethash id
                                               (plist-get state
                                                          :region-node-table))
                                      (plist-get state :node-table)))))
               region-table)
              (should (string-match-p "1" text))
              (should-not (string-match-p "^0$" text))
              (should (equal (plist-get (plist-get old-state :root-node)
                                        :node-id)
                             (plist-get (plist-get state :root-node)
                                        :node-id)))
              (should (eq (gethash (plist-get (plist-get state :root-node)
                                               :node-id)
                                     (plist-get state
                                                :surface-node-object-table))
                          (gethash (plist-get (plist-get old-state :root-node)
                                               :node-id)
                                   (plist-get old-state
                                              :surface-node-object-table))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))))

(ert-deftest ebox-scroll-patch-rolls-back-at-tp-client-state-publication ()
  "A scroll patch failure after TP client-state must restore the old generation."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-scroll-patch-rollback*")))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (ebox-render-to-buffer
           buffer
           (ebox-test-box :id "scroll" (ebox-test-text "zero\none\ntwo\nthree")
                        :width '(120) :height 2 :overflow 'scroll))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (region-id
                  (plist-get
                   (car (ebox-selector-query-buffer buffer "#scroll"))
                   :region-id))
                 (state (tp-surface-client-state surface))
                 (revision (tp-surface-revision surface))
                 (contents (with-current-buffer buffer
                             (buffer-substring (point-min) (point-max))))
                 (old-region-table (plist-get state :region-box-table)))
            (let ((tp--surface-publication-step-function
                   (lambda (step _surface)
                     (when (eq step 'client-state)
                       (error "reject scroll client-state publication")))))
              (should-error (ebox--scroll-region-by region-id 1 1)))
            (should (= (tp-surface-revision surface) revision))
            (should (eq (tp-surface-client-state surface) state))
            (should (eq (plist-get state :region-box-table)
                        old-region-table))
            (should (= (plist-get (ebox-scroll-state region-id)
                                  :scroll-offset)
                       0))
            (should (equal-including-properties
                     (with-current-buffer buffer
                       (buffer-substring (point-min) (point-max)))
                     contents))
            (should (= (ebox--scroll-region-by region-id 1 1) 1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-scroll-patch-reuses-incomplete-flex-visible-window ()
  "A lazy Flex prefix may use retained output when its visible slice is ready.
The prefix need not be fully materialized; a scroll step that remains inside
the staged rendered window must not rerun the Flex wrapper layout."
  (let* ((children
          (cl-loop for index below 80
                   collect
                   (ebox-test-box :key (intern (format "flex-cell-%03d" index))
                                (ebox-test-text (format "Cell %03d" index))
                                :width '(80) :height 1)))
         (flex (apply #'ebox-test-flex :flex-flow '(row wrap)
                      :width '(180) :column-gap '(8) :row-gap 1
                      children))
         (root (ebox-test-box :key 'scroll-root :width '(180) :height 6
                            :overflow 'scroll flex))
         (buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-incomplete-flex-scroll*")
                  root))
         (state (ebox--buffer-render-state buffer))
         (region-id (car (plist-get state :scroll-region-ids)))
         (scroll-state (gethash region-id
                                (plist-get state :scroll-state-table))))
    (unwind-protect
        (progn
          (should region-id)
          (should scroll-state)
          (should-not (plist-get scroll-state :content-lines-complete-p))
          (should (ebox--scroll-state-rendered-visible-window scroll-state))
          (should (ebox--scroll-state-retained-window-ready-p scroll-state))
          (with-current-buffer buffer
            (ebox--scroll-region-by region-id 1 1))
          (let ((report (ebox-buffer-update-report buffer))
                (current (ebox--buffer-render-state buffer)))
            (should (eq (plist-get report :projection-kind) 'scroll-patch))
            (should (plist-get report :scroll-patch-fast-p))
            (should-not (plist-get report :tp-full-root))
            (should-not (plist-get report :tp-scope-fallback))
            (should (= (hash-table-count
                        (plist-get current :region-id-set))
                       (hash-table-count
                        (plist-get current :region-box-table)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))))

(ert-deftest ebox-scroll-update-rejects-a-runtime-replaced-by-its-hook ()
  "A stale scroll candidate must not overwrite a hook publication."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-scroll-hook-race*")))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (ebox-render-to-buffer
              buffer
            (ebox-test-box :id "scroll" (ebox-test-text "zero\none\ntwo\nthree")
                         :width '(120) :height 2 :overflow 'scroll))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (revision (tp-surface-revision surface))
                 (handle (ebox-region-resolve buffer "scroll"))
                 (region-id
                  (plist-get
                   (car (ebox-selector-query-buffer buffer "#scroll"))
                   :region-id))
                 (ebox-incremental-before-runtime-mutation-hook
                  (list
                   (lambda (target kind)
                     (when (and (eq target buffer) (eq kind 'scroll))
                       (let ((ebox-incremental--runtime-mutation-hooks-inhibited-p
                              t))
                         (ebox-region-update handle :color "#2563EB")))))))
            (should-error (ebox--scroll-region-by region-id 1 1))
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should (= (plist-get (ebox-scroll-state region-id) :scroll-offset)
                       0))
            (should (equal
                     (ebox-get
                      (ebox--root-region-box
                       (plist-get (tp-surface-client-state surface) :root-node)
                       region-id)
                      :color)
                     "#2563EB"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-native-buffer-scroll-is-transactional-and-line-oriented ()
  "An eligible root scroll uses the window one line at a time.
The test stubs the GUI window boundary so batch ERT can exercise the same
participant and rollback contract without creating a real frame."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-native-scroll*")))
    (unwind-protect
        (let ((ebox-viewport-width 120)
              (ebox-viewport-height 2)
              (noninteractive nil)
              (ebox-runtime-idle-prewarm nil)
              (window-start 1)
              (window-point 1))
          (ebox-render-to-buffer
           buffer
           (ebox-test-box :id "native-scroll" (ebox-test-text "zero\none\ntwo\nthree")
                        :width '(120) :height 2 :overflow 'scroll))
          (let* ((state (ebox--buffer-render-state buffer))
                 (region-id (car (plist-get state :scroll-region-ids)))
                 (scroll-state
                  (gethash region-id (plist-get state :scroll-state-table))))
            (plist-put state :native-buffer-scroll-p t)
            (plist-put scroll-state :content-lines-complete-p t)
            (plist-put scroll-state :rendered-content-lines
                       '("zero" "one" "two" "three"))
            (plist-put scroll-state :content-height 2)
            (puthash region-id scroll-state ebox--scroll-global-state)
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _) 'ebox-test-window))
                      ((symbol-function 'window-live-p)
                       (lambda (&rest _) t))
                      ((symbol-function 'window-start)
                       (lambda (&rest _) window-start))
                      ((symbol-function 'window-point)
                       (lambda (&rest _) window-point))
                      ((symbol-function 'set-window-start)
                       (lambda (_window position &rest _)
                         (setq window-start position)))
                      ((symbol-function 'set-window-point)
                       (lambda (_window position)
                         (setq window-point position)))
                      ((symbol-function
                        'ebox--native-buffer-scroll-root-proof-p)
                       (lambda (&rest _) t)))
              (should (= (ebox--native-buffer-scroll-by buffer region-id 1)
                         1))
              (should (= (plist-get scroll-state :scroll-offset) 1))
              (should (> window-start 1))
              (should (equal (plist-get state :last-update-report)
                             (ebox-buffer-update-report buffer)))
              (should (eq (plist-get (ebox-buffer-update-report buffer)
                                    :projection-kind)
                          'native-buffer-scroll))
              ;; The native path is a presentation-only transaction, but it
              ;; must still restore both window and Ebox state if a window
              ;; primitive fails halfway through the move.
              (setq window-start 1
                    window-point 1)
              (plist-put scroll-state :scroll-offset 0)
              (ebox-put (plist-get scroll-state :box) :scroll-offset 0)
              (plist-put state :last-update-report nil)
              (let ((fail-once t))
                (cl-letf (((symbol-function 'set-window-point)
                           (lambda (_window position)
                             (if fail-once
                                 (progn
                                   (setq fail-once nil)
                                   (error "native window point failure"))
                               (setq window-point position)))))
                  (should-error
                   (ebox--native-buffer-scroll-by buffer region-id 1))))
              (should (= window-start 1))
              (should (= window-point 1))
              (should (= (plist-get scroll-state :scroll-offset) 0))
              (should-not (plist-get state :last-update-report))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))

(ert-deftest ebox-surface-native-patch-fast-path-requires-stable-topology ()
  "Only a topology-stable native patch may bypass ordinary TP planning."
  (let ((projection (list :surface-root 'surface
                          :objects-by-node (make-hash-table :test 'eq)))
        (calls nil))
    (cl-letf (((symbol-function 'ebox-surface--node-object-table)
               (lambda (_) (make-hash-table :test 'equal)))
              ((symbol-function 'ebox-surface--region-object-table)
               (lambda (&rest _) (make-hash-table :test 'equal)))
              ((symbol-function 'ebox-surface--object-region-table)
               (lambda (_) (make-hash-table :test 'eq)))
              ((symbol-function 'ebox-surface--logical-id-region-table)
               (lambda (&rest _) (make-hash-table :test 'equal)))
              ((symbol-function 'tp-object-ensure)
               (lambda (_context _parent key _kind)
                 (push 'native-object calls)
                 key))
              ((symbol-function 'ebox-surface--native-owned-ranges)
               (lambda (&rest _)
                 (push 'native-ownership calls)
                 '((:start 0 :end 3))))
              ((symbol-function 'tp-commit-batch-create)
               (lambda (&rest _)
                 (push 'native-batch calls)
                 'native-batch))
              ((symbol-function 'tp-commit-batch-result-create)
               (lambda (&rest _)
                 (push 'native-result calls)
                 'native-fast-path))
              ((symbol-function 'ebox-surface--surface-plan)
               (lambda (&rest _)
                 (push 'ordinary-plan calls)
                 '(ordinary-plan "new" ((:start 0 :end 3)) nil)))
              ((symbol-function 'tp-surface-result-create-owned)
               (lambda (&rest _)
                 (push 'ordinary-result calls)
                 'ordinary-owned-path))
              ((symbol-function 'tp-surface-retained-content-result-create)
               (lambda (&rest _)
                 (push 'retained-result calls)
                 'retained-path)))
      (let ((unstable
             '(:root-node nil
               :runtime-revision 4
               :native-topology-stable-p nil
               :native-render-fragment-template [[0 3 0 nil nil nil nil nil]]
               :native-render-frame
               (:native-frame t :native-patch t
                :base-character-count 3 :target-character-count 3
                :patches nil :coordinate-patches nil))))
        (should
         (eq (ebox-surface--projection-result
              'context projection unstable "new" 'native-frame)
             'ordinary-owned-path))
        (should (equal calls '(ordinary-result ordinary-plan)))
        (should-not (plist-member unstable :native-committed-rendered)))
      (setq calls nil)
      (let ((stable
             '(:root-node nil
               :runtime-revision 4
               :native-topology-stable-p t
               :native-render-fragment-template [[0 3 0 nil nil nil nil nil]]
               :native-render-frame
               (:native-frame t :native-patch t
                :base-character-count 3 :target-character-count 3
                :patches nil :coordinate-patches nil))))
        (should
         (eq (ebox-surface--projection-result
              'context projection stable "new" 'native-frame)
             'native-fast-path))
        (should (equal calls
                       '(native-result native-batch native-ownership
                         native-object native-object)))
        (should (equal (plist-get stable :native-committed-rendered) "new"))
        (should-not (memq 'ordinary-plan calls))
        (should-not (memq 'retained-result calls))))))

(ert-deftest ebox-surface-native-full-frame-owns-full-publication-scope ()
  "A complete native frame is authoritative for the whole TP surface."
  (should
   (ebox-surface--native-full-frame-p
    '(:native-topology-stable-p t
      :native-render-frame (:native-frame t :native-patch nil))
    'native-frame))
  (should-not
   (ebox-surface--native-full-frame-p
    '(:native-topology-stable-p t
      :native-render-frame (:native-frame t :native-patch t))
    'native-frame))
  (should-not
   (ebox-surface--native-full-frame-p
    '(:native-topology-stable-p t
      :native-render-frame (:native-frame t :native-patch nil))
    'paint)))

(provide 'ebox-surface-tests)

;;; ebox-surface-tests.el ends here
