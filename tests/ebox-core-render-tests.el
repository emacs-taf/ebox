;;; ebox-core-render-tests.el --- Core render and update regression tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(unless load-file-name
  (error "This test file must be loaded from disk, not eval'ed directly"))

(setq load-prefer-newer t)

(load-file (expand-file-name "../ebox.el" (file-name-directory load-file-name)))

(defvar ebox--scroll-window-initial-lookahead-lines-override nil)

(defun ebox-test--reset-runtime-state ()
  "Reset global runtime state used by ebox rendering tests."
  (setq ebox--region-id-counter 0)
  (setq ebox--runtime-node-id-counter 0)
  (setq ebox--render-region-id nil)
  (setq ebox--scroll-allow-noninteractive-prefetch t)
  (ebox-cache-reset-default-registry)
  (dolist (table (list ebox--region-box-table
                       ebox--buffer-render-state-table
                       ebox--scroll-global-state
                       ebox--render-root-cache-table-table
                       ebox--render-cache-entry-side-effects-table
                       ebox--rendered-uniform-width-table
                       ebox--flex-sized-render-observation-table))
    (clrhash table))
  (maphash (lambda (_region-id timer)
             (when (timerp timer)
               (cancel-timer timer)))
           ebox--scroll-idle-prefetch-timers)
  (clrhash ebox--scroll-idle-prefetch-timers)
  (maphash (lambda (_buffer timer)
             (when (timerp timer)
               (cancel-timer timer)))
           ebox--runtime-prewarm-timers)
  (clrhash ebox--runtime-prewarm-timers)
  (clrhash ebox--runtime-prewarm-jobs)
  (maphash (lambda (_buffer timer)
             (when (timerp timer)
               (cancel-timer timer)))
           ebox--reflow-cache-prewarm-timers)
  (clrhash ebox--reflow-cache-prewarm-timers)
  (when (timerp ebox--deferred-render-gc-timer)
    (cancel-timer ebox--deferred-render-gc-timer))
  (setq ebox--deferred-render-gc-timer nil)
  (setq ebox--deferred-render-gc-state nil))

(defmacro ebox-test--with-rendered-buffer (layout &rest body)
  "Render LAYOUT into a temporary ebox buffer and run BODY there."
  (declare (indent 1))
  `(let* ((buffer-name (generate-new-buffer-name " *ebox-test*"))
          (buffer (ebox-render-to-buffer buffer-name ,layout)))
     (unwind-protect
         (with-current-buffer buffer
           ,@body)
       (when (buffer-live-p buffer)
         (kill-buffer buffer)))))

(defun ebox-test--set-buffer-update-report (buffer report)
  "Store REPORT in BUFFER's render state."
  (plist-put (ebox--buffer-render-state buffer) :last-update-report report))

(defun ebox-test--buffer-update-report (&optional buffer)
  "Return BUFFER's update report, defaulting to the active rendered buffer."
  (let ((target
         (or buffer
             (and (ebox--buffer-render-state (current-buffer))
                  (current-buffer))
             (let (candidate ambiguous)
               (maphash
                (lambda (render-buffer _state)
                  (when (buffer-live-p render-buffer)
                    (if candidate
                        (setq ambiguous t)
                      (setq candidate render-buffer))))
                ebox--buffer-render-state-table)
               (and (not ambiguous) candidate)))))
    (ebox-buffer-update-report target)))

(defun ebox-test--runtime-root (buffer)
  "Return BUFFER's surface-owned runtime root."
  (plist-get (ebox--buffer-render-state buffer) :root-node))

(defun ebox-test--selector-node (buffer selector)
  "Return the first runtime node matching SELECTOR in BUFFER."
  (plist-get (car (ebox-selector-query-buffer buffer selector)) :node))

(defun ebox-test--selector-node-id (buffer selector)
  "Return the first runtime node id matching SELECTOR in BUFFER."
  (plist-get (car (ebox-selector-query-buffer buffer selector)) :node-id))

(defun ebox-test--region-handle-for-id (region-id)
  "Return the unique live surface handle for test REGION-ID."
  (let (handle ambiguous)
    (maphash
     (lambda (buffer state)
       (when (and (buffer-live-p buffer)
                  (gethash region-id (plist-get state :region-id-set)))
         (let* ((object
                 (gethash region-id
                          (plist-get state :region-surface-object-table)))
                (candidate
                 (and object
                      (ebox-selector--live-region-handle buffer object))))
           (when candidate
             (if handle
                 (setq ambiguous t)
               (setq handle candidate))))))
     ebox--buffer-render-state-table)
    (when ambiguous
      (error "Test region id is ambiguous across mounted surfaces: %S"
             region-id))
    (or handle
        (error "Test region id has no mounted surface handle: %S" region-id))))

(defun ebox-test--region-update (target &rest props)
  "Update test TARGET through the public surface-scoped handle API."
  (apply #'ebox-region-update
         (if (ebox-region-handle-p target)
             target
           (ebox-test--region-handle-for-id target))
         props))

(ert-deftest ebox-scroll-window-lookahead-accepts-root-reflow-override ()
  "Root reflow should be able to defer all hidden lookahead work."
  (let ((ebox-scroll-lazy-prefix-lookahead-lines 8)
        (ebox-wheel-scroll-step 16)
        (ebox--scroll-window-initial-lookahead-lines-override 0))
    (should (= (ebox--scroll-window-initial-lookahead-lines) 0))))

(ert-deftest ebox-root-reflow-lookahead-keeps-flex-rows-demand-driven ()
  "Root reflow should not cross an explicit flex item's atomic row eagerly."
  (ebox-test--reset-runtime-state)
  (let (plain-buffer flex-buffer)
    (unwind-protect
        (progn
          (setq plain-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-plain-lookahead*")
                 (ebox-create :content "plain" :width 120)))
          (setq flex-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-flex-lookahead*")
                 (ebox-flex
                  :width '(120)
                  (ebox-flex-item
                   (ebox-create :content "item" :width '(40))))))
          (should
           (= (ebox--root-reflow-scroll-lookahead-lines-for-buffer
               plain-buffer)
              ebox--root-reflow-scroll-lookahead-lines))
          (should
           (= (ebox--root-reflow-scroll-lookahead-lines-for-buffer
               flex-buffer)
              0)))
      (dolist (buffer (list plain-buffer flex-buffer))
        (when (and buffer (buffer-live-p buffer))
          (kill-buffer buffer))))))

(ert-deftest ebox-root-reflow-lookahead-keeps-large-runtimes-demand-driven ()
  "Root reflow should not eagerly cross costly rows in a large runtime."
  (ebox-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-large-lookahead*"))
        (node-table (make-hash-table :test 'equal))
        (selector-type-table (make-hash-table :test 'eq)))
    (unwind-protect
        (progn
          (dotimes (index 512)
            (puthash index t node-table))
          (puthash buffer
                   (list :node-table node-table
                         :selector-type-table selector-type-table)
                   ebox--buffer-render-state-table)
          (should
           (= (ebox--root-reflow-scroll-lookahead-lines-for-buffer buffer)
              0)))
      (remhash buffer ebox--buffer-render-state-table)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-exact-scroll-prefix-skips-completion-sentinel ()
  "Interactive prefix extension should request only the visible line bound."
  (ebox-test--reset-runtime-state)
  (let* ((region-id 'exact-prefix)
         (all-lines '("zero" "one" "two" "three" "four"))
         requested-limits
         (render-prefix
          (lambda (_state _region-id limit)
            (push limit requested-limits)
            (list :content-lines (seq-take all-lines limit)
                  :rendered-content-lines (seq-take all-lines limit)
                  :content-height 2
                  :complete nil)))
         (state (list :content-lines (seq-take all-lines 3)
                      :rendered-content-lines (seq-take all-lines 3)
                      :content-height 2
                      :render-content-prefix render-prefix)))
    (let ((ebox-scroll-lazy-prefix-lookahead-lines 0))
      (ebox--scroll-state-ensure-prefix-lines region-id state 4 t))
    (should (equal requested-limits '(4)))
    (setq requested-limits nil
          state (list :content-lines (seq-take all-lines 3)
                      :rendered-content-lines (seq-take all-lines 3)
                      :content-height 2
                      :render-content-prefix render-prefix))
    (let ((ebox-scroll-lazy-prefix-lookahead-lines 0))
      (ebox--scroll-state-ensure-prefix-lines region-id state 4))
    (should (equal requested-limits '(5)))))

(ert-deftest ebox-scroll-lightweight-line-bounds-extend-incrementally ()
  "Lazy line bounds should extend without rebuilding prior prefix entries."
  (ebox-test--reset-runtime-state)
  (let* ((line-a (propertize "a" 'ebox-content 11))
         (line-b (propertize "b" 'ebox-content 12))
         (line-c (propertize "c" 'ebox-content 11))
         (ebox--defer-scroll-content-index t)
         (state (ebox--scroll-state-set-lines nil (list line-a line-b)))
         (index (plist-get state :region-line-bounds-index)))
    (should (equal (gethash 11 index) '(0 . 0)))
    (should (equal (gethash 12 index) '(1 . 1)))
    (setq state
          (ebox--scroll-state-set-lines
           state (list line-a line-b line-c)))
    (should (eq index (plist-get state :region-line-bounds-index)))
    (should (equal (gethash 11 index) '(0 . 2)))
    (should (equal (gethash 12 index) '(1 . 1)))
    (should (plist-get state :region-line-span-index-deferred))))

(ert-deftest ebox-scroll-prefix-publishes-private-line-with-suffix-paint ()
  "A cached hidden source line should not rebuild the rendered prefix."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "" :width 20 :height 2))
         (content-lines '("zero" "one" "two" "three"))
         (state (list :content-lines (seq-take content-lines 3)
                      :rendered-content-lines
                      (seq-take content-lines 3)
                      :content-height 2))
         (source-renders 0)
         rendered-requests
         (original-rendered-lines
          (symbol-function 'ebox--scroll-rendered-content-lines))
         (renderer
          (ebox--scroll-window-prefix-renderer
           box '(:stack ignored) 20 2 nil content-lines)))
    (cl-letf (((symbol-function 'ebox--render-scroll-window-source)
               (lambda (&rest _)
                 (cl-incf source-renders)
                 (error "Private cached line should satisfy the prefix")))
              ((symbol-function 'ebox--scroll-rendered-content-lines)
               (lambda (&rest args)
                 (push (list (length (cadr args)) (nth 3 args))
                       rendered-requests)
                 (apply original-rendered-lines args))))
      (let ((result (funcall renderer state 'private-prefix 4)))
        (should (= source-renders 0))
        (should (equal rendered-requests '((1 3))))
        (should (= (length (plist-get result :content-lines)) 4))
        (should (= (length (plist-get result :rendered-content-lines)) 4))))))

(defun ebox-test--face-has-key-value-p (face key value)
  "Return non-nil when FACE contains KEY with VALUE."
  (cond
   ((null face) nil)
   ((and (listp face) (keywordp (car face)))
    (equal (plist-get face key) value))
   ((listp face)
    (cl-some (lambda (item)
               (ebox-test--face-has-key-value-p item key value))
             face))
   (t nil)))

(defun ebox-test--face-has-key-p (face key)
  "Return non-nil when FACE contains KEY."
  (cond
   ((null face) nil)
   ((and (listp face) (keywordp (car face)))
    (plist-member face key))
   ((listp face)
    (cl-some (lambda (item)
               (ebox-test--face-has-key-p item key))
             face))
   (t nil)))

(defun ebox-test--face-visual-attributes (face)
  "Return FACE attributes normalized by Emacs anonymous-face precedence."
  (let ((entries (if (and (listp face) (not (keywordp (car-safe face))))
                     face
                   (list face)))
        attributes named)
    (dolist (entry entries)
      (cond
       ((null entry))
       ((and (listp entry) (keywordp (car-safe entry)))
        (cl-loop for (key value) on entry by #'cddr
                 unless (assq key attributes)
                 do (push (cons key value) attributes)))
       (t (setq named t))))
    (if named
        (list 'raw face)
      (list 'visual
            (sort attributes
                  (lambda (left right)
                    (string< (symbol-name (car left))
                             (symbol-name (car right)))))))))

(defun ebox-test--border-face-has-color-p (face role color)
  "Return non-nil when FACE paints border ROLE with COLOR."
  (pcase role
    ('bt
     (ebox-test--face-has-key-value-p face :overline color))
    ('bb
     (ebox-test--face-has-key-value-p
      face :underline (list :position t :color color)))
    ((or 'bl 'br)
     (ebox-test--face-has-key-value-p face :background color))))

(defun ebox-test--face-at-property (string property)
  "Return first face in STRING at PROPERTY."
  (let ((pos 0)
        (len (length string))
        face)
    (while (and (< pos len) (not face))
      (when (get-text-property pos property string)
        (setq face (get-text-property pos 'face string)))
      (setq pos (or (next-single-property-change pos property string)
                    (1+ pos))))
    face))

(defun ebox-test--first-content-face (string)
  "Return first content face in STRING."
  (ebox-test--face-at-property string 'ebox-content))

(defmacro ebox-test--count-full-surface-updates (&rest body)
  "Run BODY and return the number of full TP surface updates it triggered."
  (declare (indent 0))
  `(let ((full-updates 0)
         (original-full-update (symbol-function 'tp-surface-update)))
     (cl-letf (((symbol-function 'tp-surface-update)
                (lambda (&rest args)
                  (cl-incf full-updates)
                  (apply original-full-update args))))
       ,@body)
     full-updates))

(defconst ebox-test--region-update-paint-cases
  '((:color "#123456" "#123456")
    (:bgcolor "#FDE68A" "#FDE68A")
    (:border-left-color "#111111" "#111111")
    (:border-right-color "#222222" "#222222")
    (:border-top-color "#333333" "#333333")
    (:border-bottom-color "#444444" "#444444")
    (:border-top-p t t)
    (:border-bottom-p t t))
  "Paint-only box longhand update cases: (PROPERTY VALUE EXPECTED).")

(defconst ebox-test--region-update-geometry-cases
  '((:box-sizing content-box content-box owner-rerender)
    (:width (120) 120 owner-rerender)
    (:min-width (100) 100 owner-rerender)
    (:max-width (140) 140 owner-rerender)
    (:height 3 3 owner-rerender)
    (:min-height 3 3 owner-rerender)
    (:max-height 1 1 owner-rerender)
    (:padding-left-pixel 9 9 span-patch)
    (:padding-right-pixel 10 10 span-patch)
    (:padding-top-height 1 1 span-patch)
    (:padding-bottom-height 1 1 span-patch)
    (:margin-left-pixel 7 7 owner-rerender)
    (:margin-right-pixel 8 8 owner-rerender)
    (:margin-top-height 1 1 owner-rerender)
    (:margin-bottom-height 1 1 owner-rerender)
    (:border-left-pixel 5 5 span-patch)
    (:border-right-pixel 6 6 span-patch)
    (:text-align center center span-patch)
    (:vertical-align middle center span-patch)
    (:overflow hidden hidden owner-rerender)
    (:wrap-mode char char span-patch)
    (:scroll-offset 1 1 span-patch)
    (:visibility hidden hidden span-patch))
  "Geometry box longhand update cases: (PROPERTY VALUE EXPECTED STRATEGY).")

(defun ebox-test--region-update-case-properties (cases)
  "Return the update property names covered by CASES."
  (mapcar #'car cases))

(ert-deftest ebox-root-background-covers-transparent-layout-wrappers ()
  "A root canvas background should remain under transparent child wrappers."
  (ebox-test--reset-runtime-state)
  (let* ((ebox-viewport-width 240)
         (ebox-viewport-height 6)
         (layout
          (ebox-build
           '(box :width (viewport) :height (viewport-height)
             :bgcolor "#151A23"
             (column
              (box :width (viewport) :height 1 :bgcolor "#202938"
                   "surface")
              (box :width (viewport) :height 1 "transparent")
              (box :width (viewport) :height 1 :bgcolor "#29364A"
                   "surface-two")))))
         (lines (ebox-string-lines (ebox-render layout))))
    (should (= (length lines) 6))
    (dolist (line lines)
      (should (ebox-test--face-has-key-value-p
               (get-text-property 0 'face line)
               :background "#151A23")))
    (should (ebox-test--face-has-key-value-p
             (get-text-property 0 'face (nth 0 lines))
             :background "#202938"))
    (should (ebox-test--face-has-key-value-p
             (get-text-property 0 'face (nth 2 lines))
             :background "#29364A"))))

(ert-deftest ebox-region-ids-assigns-stable-ids-before-render ()
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "L" :width 40))
         (right (ebox-create :content "R" :width 50))
         (layout (ebox-concat left right))
         (ids-before (ebox-region-ids layout)))
    (should (equal ids-before '(1 2)))
    (should (equal (ebox-region-ids layout) ids-before))
    (should (equal (ebox-region-ids (ebox-render layout)) ids-before))))


(ert-deftest ebox-live-mount-uses-runtime-copy-and-leaves-source-stable ()
  "Live publication should update a surface copy without mutating SOURCE."
  (ebox-test--reset-runtime-state)
  (let* ((source (ebox-build
                  '(box :id "root" :content "before\nhidden" :width (120)
                        :color "#111111" :height 1 :overflow scroll)))
         (buffer (generate-new-buffer " *ebox-live-copy-source*")))
    (unwind-protect
        (progn
          (should-not (plist-member source :region-id))
          (ebox-render-to-buffer buffer source)
          (let* ((runtime-root (ebox-test--runtime-root buffer))
                 (handle (ebox-region-resolve buffer "root")))
            (should-not (eq runtime-root source))
            (ebox-test--region-update handle
                                :content "after\nhidden"
                                :color "#222222"
                                :width '(140))
            (setq runtime-root (ebox-test--runtime-root buffer))
            (should-not (plist-member source :region-id))
            (should-not (plist-member source :node-id))
            (should (equal (ebox-get source :content) "before\nhidden"))
            (should (equal (ebox-get source :color) "#111111"))
            (should (equal (ebox-get source :width) 120))
            (should (equal (ebox-get source :scroll-offset) 0))
            (should (equal (ebox-get runtime-root :content) "after\nhidden"))
            (should (equal (ebox-get runtime-root :color) "#222222"))
            (should (equal (ebox-get runtime-root :width) 140))
            (with-current-buffer buffer
              (should (string-match-p "after"
                                      (buffer-string))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-live-mount-allows-one-source-on-independent-surfaces ()
  "One immutable source should mount and update independently in two buffers."
  (ebox-test--reset-runtime-state)
  (let* ((source (ebox-build
                  '(box :id "root" :content "owned\nhidden" :width (120)
                        :height 1 :overflow scroll)))
         first-buffer second-buffer)
    (unwind-protect
        (progn
          (setq first-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-live-first*")
                 source))
          (setq second-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-live-second*")
                 source))
          (let ((first-handle (ebox-region-resolve first-buffer "root"))
                (second-handle (ebox-region-resolve second-buffer "root")))
            (should-not (eq first-handle second-handle))
            (ebox-test--region-update first-handle :content "first changed")
            (with-current-buffer first-buffer
              (should (string-match-p "first changed" (buffer-string))))
            (with-current-buffer second-buffer
              (should-not (string-match-p "first changed" (buffer-string))))
            (ebox-test--region-update second-handle :content "second changed")
            (with-current-buffer second-buffer
              (should (string-match-p "second changed" (buffer-string))))
            (should (equal (ebox-get source :content) "owned\nhidden"))
            (should-not (plist-member source :region-id))))
      (dolist (buffer (list first-buffer second-buffer))
        (when (and buffer (buffer-live-p buffer))
          (kill-buffer buffer))))))

(ert-deftest ebox-live-mount-kill-invalidates-handle ()
  "Killing a surface buffer should invalidate its region handles."
  (ebox-test--reset-runtime-state)
  (let* ((old-source (ebox-create :id "old" :content "old" :width 120))
         primary-buffer secondary-buffer)
    (unwind-protect
        (progn
          (setq primary-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-live-primary*")
                 old-source))
          (let ((old-handle (ebox-region-resolve primary-buffer "old")))
            (kill-buffer primary-buffer)
            (setq primary-buffer nil)
            (should-error (ebox-test--region-update old-handle :content "stale")
                          :type 'user-error))
          (setq secondary-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-live-secondary*")
                 old-source))
          (ebox-test--region-update (ebox-region-resolve secondary-buffer "old")
                              :content "reused")
          (with-current-buffer secondary-buffer
            (should (string-match-p "reused" (buffer-string))))
          (should (equal (ebox-get old-source :content) "old")))
      (dolist (buffer (list primary-buffer secondary-buffer))
        (when (and buffer (buffer-live-p buffer))
          (kill-buffer buffer))))))

(ert-deftest ebox-runtime-node-ids-cover-layout-and-box-nodes ()
  "Every runtime node should have a stable internal node id."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-stack
                  (ebox-create :content "Top" :width 60)
                  (ebox-concat
                   (ebox-create :content "Left" :width 40)
                   (ebox-create :content "Right" :width 40))))
         (ids-before (ebox--runtime-node-ids layout)))
    (should (= (length ids-before) 5))
    (should (= (length (delete-dups (copy-sequence ids-before))) 5))
    (ebox-render layout)
    (should (equal (ebox--runtime-node-ids layout) ids-before))))

(ert-deftest ebox-wrapper-child-nodes-are-in-runtime-index ()
  "A wrapper box's child layout should remain visible in runtime state."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :padding 1
                  (box :content "One")
                  (box :content "Two"))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 node))
          (let ((ids (ebox--runtime-node-ids
                      (ebox-test--runtime-root buffer))))
            (should (> (length ids) 1))
            (dolist (node-id ids)
              (should (ebox--buffer-runtime-node buffer node-id)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-region-render-owner-index-maps-boxes-and-flex-wrapper ()
  "Region lookup should map each box to its smallest renderable owner."
  (ebox-test--reset-runtime-state)
  (let* ((plain (ebox-create :id "plain" :content "Plain" :width '(80)))
         (flex-child (ebox-create :id "child" :content "Flex child"
                                  :width '(80)))
         (flex (ebox-flex :width '(120) :padding 1 flex-child))
         (layout (ebox-column plain flex)))
    (ebox-test--with-rendered-buffer layout
      (let* ((buffer (current-buffer))
             (runtime-root (ebox-test--runtime-root buffer))
             (runtime-plain (car (plist-get runtime-root :children)))
             (runtime-flex (cadr (plist-get runtime-root :children)))
             (runtime-wrapper (plist-get runtime-flex :box))
             (runtime-child (car (plist-get runtime-flex :children)))
             (table (ebox--buffer-region-node-table buffer))
             (plain-region-id (plist-get runtime-plain :region-id))
             (wrapper-region-id (plist-get runtime-wrapper :region-id))
             (child-region-id (plist-get runtime-child :region-id))
             (plain-node-id (plist-get runtime-plain :node-id))
             (flex-node-id (plist-get runtime-flex :node-id))
             (wrapper-node-id (plist-get runtime-wrapper :node-id))
             (child-node-id (plist-get runtime-child :node-id)))
        (should (hash-table-p table))
        (should (equal (gethash plain-region-id table) plain-node-id))
        (should (equal (gethash wrapper-region-id table) flex-node-id))
        (should-not (equal (gethash wrapper-region-id table)
                           wrapper-node-id))
        (should (equal (gethash child-region-id table) child-node-id))
        (should (eq (ebox--buffer-region-render-owner-node
                     buffer plain-region-id)
                    runtime-plain))
        (should (eq (ebox--buffer-region-render-owner-node
                     buffer wrapper-region-id)
                    runtime-flex))
        (should (eq (ebox--buffer-region-render-owner-node
                     buffer child-region-id)
                    runtime-child))))))

(ert-deftest ebox-region-render-owner-index-keeps-earlier-duplicate-box ()
  "A later flex wrapper should not replace an earlier duplicate region owner."
  (ebox-test--reset-runtime-state)
  (let* ((region-id 9001)
         (plain (ebox-create :content "First" :width '(80)))
         (flex (ebox-flex :width '(120)
                          (ebox-create :content "Later" :width '(80))))
         (wrapper (plist-get flex :box))
         (layout (ebox-column plain flex)))
    (ebox-put plain :region-id region-id)
    (ebox-put wrapper :region-id region-id)
    (let* ((index (ebox--runtime-index layout))
           (table (plist-get index :region-node-table))
           (expected (car (ebox--node-path-to-region layout region-id))))
      (should (eq expected plain))
      (should (equal (gethash region-id table)
                     (ebox--ensure-node-id expected))))))

(ert-deftest ebox-region-render-owner-index-keeps-outer-flex-duplicate ()
  "Nested duplicate flex wrappers should retain recursive first-match lookup."
  (ebox-test--reset-runtime-state)
  (let* ((region-id 9002)
         (inner (ebox-flex :width '(100) :padding 1
                           (ebox-create :content "Inner" :width '(80))))
         (outer (ebox-flex :width '(140) :padding 1 inner))
         (inner-wrapper (plist-get inner :box))
         (outer-wrapper (plist-get outer :box)))
    (ebox-put inner-wrapper :region-id region-id)
    (ebox-put outer-wrapper :region-id region-id)
    (let* ((index (ebox--runtime-index outer))
           (table (plist-get index :region-node-table))
           (expected (car (ebox--node-path-to-region outer region-id))))
      (should (eq expected outer))
      (should (equal (gethash region-id table)
                     (ebox--ensure-node-id expected))))))

(ert-deftest ebox-runtime-index-region-box-table-matches-complete-render ()
  "Runtime indexing should collect the box table with render overwrite order."
  (ebox-test--reset-runtime-state)
  (let* ((shared-region-id 9003)
         (inner (ebox-create :content "Inner" :width '(60)))
         (outer (ebox-create :content "" :width '(90)))
         (flex-child (ebox-create :content "Flex child" :width '(50)))
         (flex (ebox-flex :width '(120) :padding 1 flex-child))
         (layout (ebox-column outer flex))
         (render-table (make-hash-table :test 'equal)))
    (plist-put outer :ebox-content-node inner)
    ;; Complete rendering records parents after their child content.  A
    ;; duplicated legacy id therefore resolves to OUTER in the box table.
    (ebox-put inner :region-id shared-region-id)
    (ebox-put outer :region-id shared-region-id)
    (let* ((index (ebox--runtime-index layout t))
           (index-table (plist-get index :region-box-table))
           (ebox--region-box-table render-table)
           (ebox--surface-materialization-active t)
           (ebox--scroll-global-state (make-hash-table :test 'equal)))
      (ebox--render-layout layout)
      (should (= (hash-table-count index-table)
                 (hash-table-count render-table)))
      (maphash
       (lambda (region-id box)
         (should (eq (gethash region-id index-table) box)))
       render-table)
      (should (eq (gethash shared-region-id index-table) outer))
      (should
       (eq (gethash (ebox--ensure-region-id (plist-get flex :box))
                    index-table)
           (plist-get flex :box))))))

(ert-deftest ebox-declarative-candidate-reuses-indexed-region-box-table ()
  "Candidate preparation should not rewalk the tree to collect source boxes."
  (ebox-test--reset-runtime-state)
  (let ((root (ebox-column
               (ebox-create :key 'first :content "First" :width '(80))
               (ebox-create :key 'second :content "Second" :width '(80))))
        (next-root
         (ebox-column
          (ebox-create :key 'first :content "Changed" :width '(80))
          (ebox-create :key 'second :content "Second" :width '(80)))))
    (ebox-test--with-rendered-buffer root
      (let* ((buffer (current-buffer))
             (old-state (ebox--buffer-render-state buffer))
             (recache-calls 0)
             prepared
             candidate-state)
        (cl-letf (((symbol-function 'ebox--flex-recache-source-boxes)
                   (lambda (&rest _)
                     (cl-incf recache-calls))))
          (setq prepared
                (ebox-incremental--prepare-declarative-root
                 buffer old-state next-root))
          (setq candidate-state
                (ebox-incremental--candidate-state
                 old-state
                 (plist-get prepared :root)
                 (plist-get prepared :index)
                 prepared)))
        (should (= recache-calls 0))
        (should
         (eq (plist-get candidate-state :region-box-table)
             (plist-get (plist-get prepared :index) :region-box-table)))
        (should (= (hash-table-count
                    (plist-get candidate-state :region-box-table))
                   2))))))

(ert-deftest ebox-region-render-owner-index-falls-back-for-legacy-state ()
  "A runtime state without the new table should retain recursive lookup."
  (ebox-test--reset-runtime-state)
  (let* ((child (ebox-create :content "Flex child" :width '(80)))
         (flex (ebox-flex :width '(120) :padding 1 child))
         (wrapper (plist-get flex :box)))
    (ebox-test--with-rendered-buffer flex
      (let* ((buffer (current-buffer))
             (state (ebox--buffer-render-state buffer))
             (table (ebox--buffer-region-node-table buffer))
             (region-id (ebox--ensure-region-id wrapper))
             (expected-node-id
              (ebox--buffer-region-render-owner-node-id buffer region-id))
             (expected-node
              (ebox--buffer-region-render-owner-node buffer region-id))
             (original-path
              (symbol-function 'ebox--node-path-to-region))
             (recursive-calls 0))
        (unwind-protect
            (progn
              (plist-put state :region-node-table nil)
              (cl-letf (((symbol-function 'ebox--node-path-to-region)
                         (lambda (&rest args)
                           (cl-incf recursive-calls)
                           (apply original-path args))))
                (should (equal
                         (ebox--buffer-region-render-owner-node-id
                          buffer region-id)
                         expected-node-id))
                (should (eq (ebox--buffer-region-render-owner-node
                             buffer region-id)
                            expected-node)))
              (should (> recursive-calls 0)))
          (plist-put state :region-node-table table))))))

(ert-deftest ebox-runtime-node-id-survives-viewport-rerender ()
  "Viewport-only rerender should not assign new runtime node ids."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-flex
                  :flex-wrap 'wrap
                  (ebox-create :content "A" :width '(100))
                  (ebox-create :content "B" :width '(100))))
         (ids-before nil)
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 240))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (setq ids-before (ebox--runtime-node-ids layout))
          (let ((ebox-viewport-width 160))
            (ebox--rerender-buffer-preserving-runtime buffer))
          (should (equal (ebox--runtime-node-ids layout) ids-before)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-reconcile-preserves-keyed-child-id ()
  "Keyed children should keep runtime ids across structural rebuilds."
  (ebox-test--reset-runtime-state)
  (let* ((old (ebox--runtime-tree
               (ebox-column
                (ebox-create :key 'a :content "A" :width 40)
                (ebox-create :key 'b :content "B" :width 40))))
         (old-b-id (ebox--runtime-node-id-by-key old 'b))
         (new (ebox--reconcile-runtime-tree
               old
               (ebox-column
                (ebox-create :key 'x :content "X" :width 40)
                (ebox-create :key 'b :content "B2" :width 40)))))
    (should (equal (ebox--runtime-node-id-by-key new 'b) old-b-id))))

(ert-deftest ebox-tree-helpers-see-wrapper-child-nodes ()
  "Tree helpers should see wrapper children without rendering static content."
  (let* ((node (ebox-build
                '(column :padding 1
                  (box :content "Child" :width (120)))))
         (children (ebox-tree-children node)))
    (should children)
    (should (plist-get (car children) :node-id))))

(ert-deftest ebox-tree-shallow-copy-replaces-box-content-node ()
  "A box content-node replacement should leave other values shared."
  (let* ((old-content (list :ebox-type 'box :content "old"))
         (equal-content (copy-tree old-content))
         (new-content (list :ebox-type 'box :content "new"))
         (wrong-content (list :ebox-type 'box :content "wrong"))
         (metadata (list :owner 'host))
         (node (list :ebox-type 'box
                     :ebox-content-node old-content
                     :metadata metadata))
         (copy
          (ebox-tree-copy-with-direct-child-replacements
           node (list (cons equal-content wrong-content)
                      (cons old-content new-content)))))
    (should-not (eq copy node))
    (should (eq (plist-get copy :ebox-content-node) new-content))
    (should (eq (plist-get copy :metadata) metadata))
    (should (eq (plist-get node :ebox-content-node) old-content))))

(ert-deftest ebox-tree-shallow-copy-replaces-concat-children-and-aliases ()
  "A concat copy should update flat children and both legacy aliases."
  (let* ((left (list :ebox-type 'box :content "left"))
         (right (list :ebox-type 'box :content "right"))
         (new-left (list :ebox-type 'box :content "new-left"))
         (children (list left right))
         (node (list :ebox-type 'concat
                     :children children
                     :left left
                     :right right))
         (copy
          (ebox-tree-copy-with-direct-child-replacements
           node (list (cons left new-left))))
         (copy-children (plist-get copy :children)))
    (should-not (eq copy node))
    (should-not (eq copy-children children))
    (should (eq (car copy-children) new-left))
    (should (eq (cadr copy-children) right))
    (should (eq (plist-get copy :left) new-left))
    (should (eq (plist-get copy :right) right))))

(ert-deftest ebox-tree-shallow-copy-replaces-stack-children-and-aliases ()
  "A stack copy should update flat children and both legacy aliases."
  (let* ((top (list :ebox-type 'box :content "top"))
         (bottom (list :ebox-type 'box :content "bottom"))
         (new-bottom (list :ebox-type 'box :content "new-bottom"))
         (children (list top bottom))
         (node (list :ebox-type 'stack
                     :children children
                     :top top
                     :bottom bottom))
         (copy
          (ebox-tree-copy-with-direct-child-replacements
           node (list (cons bottom new-bottom))))
         (copy-children (plist-get copy :children)))
    (should-not (eq copy node))
    (should-not (eq copy-children children))
    (should (eq (car copy-children) top))
    (should (eq (cadr copy-children) new-bottom))
    (should (eq (plist-get copy :top) top))
    (should (eq (plist-get copy :bottom) new-bottom))))

(ert-deftest ebox-tree-shallow-copy-replaces-flex-box-and-children-once ()
  "One flex copy should apply multiple replacements and share one sibling."
  (let* ((box (list :ebox-type 'box :content "wrapper"))
         (first (list :ebox-type 'box :content "first"))
         (untouched (list :ebox-type 'box :content "untouched"))
         (last (list :ebox-type 'box :content "last"))
         (new-box (list :ebox-type 'box :content "new-wrapper"))
         (new-first (list :ebox-type 'box :content "new-first"))
         (new-last (list :ebox-type 'box :content "new-last"))
         (children (list first untouched last))
         (node (list :ebox-type 'flex :box box :children children))
         (copy
          (ebox-tree-copy-with-direct-child-replacements
           node (list (cons box new-box)
                      (cons first new-first)
                      (cons last new-last))))
         (copy-children (plist-get copy :children)))
    (should-not (eq copy node))
    (should (eq (plist-get copy :box) new-box))
    (should (eq (nth 0 copy-children) new-first))
    (should (eq (nth 1 copy-children) untouched))
    (should (eq (nth 2 copy-children) new-last))
    (should (eq (plist-get node :box) box))
    (should (eq (nth 0 children) first))
    (should (eq (nth 1 children) untouched))
    (should (eq (nth 2 children) last))))

(ert-deftest ebox-tree-shallow-copy-replaces-flex-item-node ()
  "A flex-item copy should replace its wrapped node by identity."
  (let* ((old-child (list :ebox-type 'box :content "old"))
         (new-child (list :ebox-type 'box :content "new"))
         (props (list :flex-grow 1))
         (node (list :ebox-type 'flex-item :node old-child :props props))
         (copy
          (ebox-tree-copy-with-direct-child-replacements
           node (list (cons old-child new-child)))))
    (should-not (eq copy node))
    (should (eq (plist-get copy :node) new-child))
    (should (eq (plist-get copy :props) props))))

(ert-deftest ebox-tree-shallow-copy-without-replacements-shares-values ()
  "A zero-replacement copy should share every nested value."
  (let* ((first (list :ebox-type 'box :content "first"))
         (second (list :ebox-type 'box :content "second"))
         (children (list first second))
         (node (list :ebox-type 'concat :children children))
         (copy (ebox-tree-copy-with-direct-child-replacements node nil)))
    (should-not (eq copy node))
    (should (eq (plist-get copy :children) children))
    (should (eq (car (plist-get copy :children)) first))
    (should (eq (cadr (plist-get copy :children)) second))))

(ert-deftest ebox-fragment-signature-excludes-backend-spans ()
  "Fragment signatures should describe layout facts, not backend markers."
  (let ((fragment (ebox-fragment-create
                   :node-id "n1"
                   :region-ids '("r1")
                   :size '(120 . 24)
                   :line-signature '(("Child"))
                   :buffer-span '(1 . 8))))
    (should (equal (ebox-fragment-layout-signature fragment)
                   '(:node-id "n1" :region-ids ("r1") :size (120 . 24)
                     :line-signature (("Child")))))))

(ert-deftest ebox-cache-registry-records-scope-deps-and-lifetime ()
  "Cache specs should make ownership, scope, dependencies, and lifetime explicit."
  (unwind-protect
      (let ((spec (ebox-cache-register
                   :name 'computed-style
                   :owner 'ebox-style
                   :scope 'node
                   :key-deps '(specified-style class-version theme-version)
                   :invalidates '(style class theme)
                   :lifetime 'buffer-runtime
                   :value-owner 'ebox-style)))
        (should (eq (ebox-cache-spec-name spec) 'computed-style))
        (should (eq (ebox-cache-spec-owner spec) 'ebox-style))
        (should (eq (ebox-cache-spec-scope spec) 'node))
        (should (equal (ebox-cache-spec-invalidates spec)
                       '(style class theme)))
        (should (eq (ebox-cache-spec-lifetime spec) 'buffer-runtime)))
    (ebox-cache-reset-default-registry)))

(ert-deftest ebox-cache-invalidates-by-dirty-kind ()
  "Dirty facts should map to the cache specs they invalidate."
  (unwind-protect
      (progn
        (ebox-cache-clear-registry)
        (ebox-cache-register
         :name 'render-body
         :owner 'ebox-buffer-backend
         :scope 'buffer
         :key-deps '(fragment-signature paint-signature backend-display-signature)
         :invalidates '(paint geometry structure backend-display)
         :lifetime 'buffer-runtime
         :value-owner 'ebox-buffer-backend)
        (ebox-cache-register
         :name 'layout-fragment
         :owner 'ebox-layout
         :scope 'formatting-context
         :key-deps '(node-id computed-style-signature child-signatures available-size)
         :invalidates '(geometry structure viewport)
         :lifetime 'buffer-runtime
         :value-owner 'ebox-layout)
        (should (equal (sort (ebox-cache-invalidated-spec-names '(paint))
                             #'string<)
                       '(render-body)))
        (should (equal (sort (ebox-cache-invalidated-spec-names '(geometry))
                             #'string<)
                       '(layout-fragment render-body))))
    (ebox-cache-reset-default-registry)))

(ert-deftest ebox-render-cache-retains-distinct-viewport-widths ()
  "Returning to a warm width should not evict its prior rendered value."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-cache-report-buffer nil)
        (width-a '(display-a 720 42 body))
        (width-b '(display-a 900 42 body)))
    (ebox--render-cache-store 'responsive width-a 'rendered-a)
    (ebox--render-cache-store 'responsive width-b 'rendered-b)
    (should (eq (ebox--render-cache-lookup 'responsive width-a)
                'rendered-a))
    (should (eq (ebox--render-cache-lookup 'responsive width-b)
                'rendered-b))))

(ert-deftest ebox-render-cache-retains-distinct-box-width-signatures ()
  "Ordinary box-width variants should coexist under one cache key."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-cache-report-buffer nil)
        (width-a '(display-a nil 42 (:width 720)))
        (width-b '(display-a nil 42 (:width 900))))
    (ebox--render-cache-store 'responsive width-a 'rendered-a)
    (ebox--render-cache-store 'responsive width-b 'rendered-b)
    (should (eq (ebox--render-cache-lookup 'responsive width-a)
                'rendered-a))
    (should (eq (ebox--render-cache-lookup 'responsive width-b)
                'rendered-b))))

(ert-deftest ebox-render-cache-distinguishes-content-text-properties ()
  "Equal characters with different properties must not share rendered output."
  (let* ((ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox-cache-report-buffer nil)
         (normal
          (list 'display-a nil 42
                (list :content
                      (propertize "Same" 'face 'default))))
         (selected
          (list 'display-a nil 42
                (list :content
                      (propertize "Same" 'face 'highlight)))))
    (ebox--render-cache-store 'cell normal 'rendered-normal)
    (should-not (ebox--render-cache-lookup 'cell selected))
    (ebox--render-cache-store 'cell selected 'rendered-selected)
    (should (eq (ebox--render-cache-lookup 'cell selected)
                'rendered-selected))))

(ert-deftest ebox-render-cache-evicts-oldest-entry-at-capacity ()
  "A full cache should retain newer width variants without unbounded growth."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-render-cache-max-entries 2)
        (ebox-cache-report-buffer nil))
    (ebox--render-cache-store 'responsive 'width-a 'rendered-a)
    (ebox--render-cache-store 'responsive 'width-b 'rendered-b)
    (ebox--render-cache-store 'responsive 'width-c 'rendered-c)
    (should (= (hash-table-count ebox--render-cache-table) 2))
    (should-not (ebox--render-cache-lookup 'responsive 'width-a))
    (should (eq (ebox--render-cache-lookup 'responsive 'width-b)
                'rendered-b))
    (should (eq (ebox--render-cache-lookup 'responsive 'width-c)
                'rendered-c))))

(ert-deftest ebox-render-cache-evicts-oldest-entry-at-byte-budget ()
  "Large rendered values should be bounded even below the entry limit."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-render-cache-max-entries 16)
        (ebox-render-cache-max-bytes 400)
        (ebox-cache-report-buffer nil))
    (ebox--render-cache-store 'responsive 'width-a "aa")
    (ebox--render-cache-store 'responsive 'width-b "bb")
    (should-not (ebox--render-cache-lookup 'responsive 'width-a))
    (should (equal (ebox--render-cache-lookup 'responsive 'width-b) "bb"))
    (should (= (hash-table-count ebox--render-cache-table) 1))))

(ert-deftest ebox-render-cache-does-not-retain-one-oversized-value ()
  "One value above the byte budget should be returned but not retained."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-render-cache-max-entries 16)
        (ebox-render-cache-max-bytes 128)
        (ebox-cache-report-buffer nil))
    (should (equal (ebox--render-cache-store
                    'responsive 'width-a "oversized")
                   "oversized"))
    (should (= (hash-table-count ebox--render-cache-table) 0))
    (should-not (ebox--render-cache-lookup 'responsive 'width-a))))

(ert-deftest ebox-render-cache-oversized-store-preserves-healthy-entries ()
  "One oversized store must not purge unrelated retained entries."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-render-cache-max-entries 16)
        (ebox-render-cache-max-bytes 1024)
        (ebox-cache-report-buffer nil))
    (ebox--render-cache-store 'responsive 'width-a "aa")
    (ebox--render-cache-store 'responsive 'width-b "bb")
    (should (equal (ebox--render-cache-store
                    'responsive 'width-oversized (make-string 64 ?x))
                   (make-string 64 ?x)))
    (should-not (ebox--render-cache-lookup 'responsive 'width-oversized))
    (should (equal (ebox--render-cache-lookup 'responsive 'width-a) "aa"))
    (should (equal (ebox--render-cache-lookup 'responsive 'width-b) "bb"))
    (should (= (hash-table-count ebox--render-cache-table) 2))))

(ert-deftest ebox-render-cache-oversized-update-releases-only-that-entry ()
  "Growing one entry above the budget must release only that entry."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-render-cache-max-entries 16)
        (ebox-render-cache-max-bytes 1024)
        (ebox-cache-report-buffer nil))
    (ebox--render-cache-store 'responsive 'width-a "aa")
    (ebox--render-cache-store 'responsive 'width-b "bb")
    (ebox--render-cache-store 'responsive 'width-b (make-string 64 ?x))
    (should-not (ebox--render-cache-lookup 'responsive 'width-b))
    (should (equal (ebox--render-cache-lookup 'responsive 'width-a) "aa"))
    (should (= (hash-table-count ebox--render-cache-table) 1))))

(ert-deftest ebox-render-cache-retains-distinct-sxhash-collisions ()
  "Distinct signatures with one bounded hash must retain separate entries."
  (let* ((ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox-render-cache-max-entries 16)
         (ebox-cache-report-buffer nil)
         (signature-a '(same (same (same (same "a")))))
         (signature-b '(same (same (same (same "b"))))))
    (should-not (equal signature-a signature-b))
    (should (= (sxhash-equal signature-a) (sxhash-equal signature-b)))
    (ebox--render-cache-store 'page signature-a 'rendered-a)
    (ebox--render-cache-store 'page signature-b 'rendered-b)
    (should (= (hash-table-count ebox--render-cache-table) 2))
    (should (eq (ebox--render-cache-lookup 'page signature-a) 'rendered-a))
    (should (eq (ebox--render-cache-lookup 'page signature-b) 'rendered-b))))

(ert-deftest ebox-render-cache-byte-budget-includes-scroll-side-effects ()
  "Scroll-state metadata must not bypass the retained-byte budget."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-render-cache-max-entries 16)
        (ebox-render-cache-max-bytes 1024)
        (ebox-cache-report-buffer nil)
        (side-effects
         (list :scroll-actions
               (list
                (list 'set 'scroll
                      (list :content-lines
                            (list (make-string 4096 ?x)))))
               :stateful-p t
               :restorable-p t)))
    (should (equal (ebox--render-cache-store
                    'responsive 'width-a "x" side-effects)
                   "x"))
    (should (= (hash-table-count ebox--render-cache-table) 0))
    (should-not (ebox--render-cache-lookup 'responsive 'width-a))))

(ert-deftest ebox-render-cache-reuses-portable-scroll-state-in-candidate-tree ()
  "Portable scroll templates rebind complete state to the candidate box."
  (ebox-test--reset-runtime-state)
  (let* ((buffer (generate-new-buffer " *ebox-portable-scroll-cache*"))
         (old-box (ebox-create :content "old" :scroll-offset 0))
         (node-id (ebox--ensure-node-id old-box))
         (candidate-box (ebox-create :content "candidate" :scroll-offset 0))
         (node-table (make-hash-table :test 'eql))
         (template
          (list :box old-box
                :content-lines '("alpha" "beta")
                :rendered-content-lines '("alpha")
                :content-height 1
                :scroll-offset 0))
         (actions (list (list 'set 'scroll template)))
         (entry (cons 'signature "rendered"))
         (metadata
          (list :scroll-actions actions
                :stateful-p t
                :portable-p t
                :restorable-p t))
         (ebox--render-cache-scroll-state-restorable-p nil))
    (plist-put candidate-box :node-id node-id)
    (puthash node-id candidate-box node-table)
    (puthash buffer (list :node-table node-table)
             ebox--buffer-render-state-table)
    (puthash entry metadata ebox--render-cache-entry-side-effects-table)
    (unwind-protect
        (with-current-buffer buffer
          (should (ebox--scroll-cache-actions-portable-p actions))
          (should (ebox--render-cache-entry-reusable-p entry))
          (ebox--render-cache-replay-entry-side-effects entry)
          (let ((state (ebox--scroll-get-state 'scroll)))
            (should (eq (plist-get state :box) candidate-box))
            (should (equal (plist-get state :content-lines)
                           '("alpha" "beta")))
            (should (equal (plist-get state :rendered-content-lines)
                           '("alpha")))))
      (ebox--scroll-clear-state 'scroll)
      (remhash entry ebox--render-cache-entry-side-effects-table)
      (remhash buffer ebox--buffer-render-state-table)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-render-cache-rejects-nonportable-candidate-scroll-state ()
  "Candidate publication must not replay closures owned by the old tree."
  (let* ((prefix-renderer (lambda (_count) '("deferred")))
         (materializer (lambda () '("materialized")))
         (actions
          (list
           (list 'set 'scroll
                 (list :box (ebox-create :content "old" :scroll-offset 0)
                       :content-lines '("alpha")
                       :render-content-prefix prefix-renderer
                       :materialize-content-lines materializer))))
         (ebox--render-cache-scroll-state-restorable-p nil)
         (entry (cons 'signature "rendered"))
         (metadata
          (list :scroll-actions actions
                :stateful-p t
                :portable-p nil
                :restorable-p t)))
    (puthash entry metadata ebox--render-cache-entry-side-effects-table)
    (unwind-protect
        (progn
          (should-not (ebox--scroll-cache-actions-portable-p actions))
          (should-not (ebox--render-cache-entry-reusable-p entry)))
      (remhash entry ebox--render-cache-entry-side-effects-table))))

(ert-deftest ebox-render-cache-ring-recovers-after-clrhash ()
  "An exceptional cache clear should not leave stale eviction metadata."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-render-cache-max-entries 2)
        (ebox-cache-report-buffer nil))
    (ebox--render-cache-store 'responsive 'width-a 'rendered-a)
    (ebox--render-cache-store 'responsive 'width-b 'rendered-b)
    (clrhash ebox--render-cache-table)
    (ebox--render-cache-store 'responsive 'width-c 'rendered-c)
    (ebox--render-cache-store 'responsive 'width-d 'rendered-d)
    (ebox--render-cache-store 'responsive 'width-e 'rendered-e)
    (should (= (hash-table-count ebox--render-cache-table) 2))
    (should-not (ebox--render-cache-lookup 'responsive 'width-c))
    (should (eq (ebox--render-cache-lookup 'responsive 'width-d)
                'rendered-d))
    (should (eq (ebox--render-cache-lookup 'responsive 'width-e)
                'rendered-e))))

(ert-deftest ebox-render-cache-ring-retains-newest-entries-when-limit-shrinks ()
  "Lowering the cache limit should retain the newest insertion-order entries."
  (let ((ebox--render-cache-table (make-hash-table :test 'equal))
        (ebox-render-cache-max-entries 3)
        (ebox-cache-report-buffer nil))
    (ebox--render-cache-store 'responsive 'width-a 'rendered-a)
    (ebox--render-cache-store 'responsive 'width-b 'rendered-b)
    (ebox--render-cache-store 'responsive 'width-c 'rendered-c)
    (setq ebox-render-cache-max-entries 2)
    (ebox--render-cache-store 'responsive 'width-d 'rendered-d)
    (should (= (hash-table-count ebox--render-cache-table) 2))
    (should-not (ebox--render-cache-lookup 'responsive 'width-a))
    (should-not (ebox--render-cache-lookup 'responsive 'width-b))
    (should (eq (ebox--render-cache-lookup 'responsive 'width-c)
                'rendered-c))
    (should (eq (ebox--render-cache-lookup 'responsive 'width-d)
                'rendered-d))))

(ert-deftest ebox-buffer-render-cache-stays-bounded-across-unique-widths ()
  "Continuous resize should not retain an unbounded set of rendered widths."
  (ebox-test--reset-runtime-state)
  (let* ((ebox-render-cache-max-entries 32)
         (ebox-runtime-idle-prewarm nil)
         (ebox-runtime-idle-reflow-cache-prewarm nil)
         (layout
          (ebox-build
           `(box :id "root" :width (viewport)
              (flex :width (viewport) :gap 1
                ,@(cl-loop for index below 8
                           collect
                           `(box :id ,(format "card-%d" index)
                                 :content ,(format "card %d" index)
                                 :width 72 :height 1))))))
         buffer)
    (unwind-protect
        (let ((ebox-viewport-width 240))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-cache-bound*") layout))
          (cl-loop for width from 241 to 280
                   do (ebox-rerender-buffer-with-context buffer width))
          (let ((cache (ebox--buffer-render-cache buffer)))
            (should (<= (hash-table-count cache)
                        ebox-render-cache-max-entries)))
          (with-current-buffer buffer
            (should (ebox-test--buffer-visually-matches-runtime-render-p))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-returning-width-cache-restores-lazy-scroll-context ()
  "A cached subtree must restore lazy scroll state for its render context."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(column :id "viewport" :width (viewport)
             (box :id "scroll" :width (viewport) :height 4
                  :overflow scroll
               (column :width (viewport)
                ,@(cl-loop for index below 32
                           collect
                           `(box :content ,(format "cached row %02d" index)
                                 :width (viewport) :height 1)))))))
         buffer
         scroll-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 6)
              ;; Evict the first complete root so the return leg renders the
              ;; root while retaining its generic cached scroll subtree.
              (ebox-render-root-cache-max-entries 1)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-scroll-cache-context*")
                 layout))
          (setq scroll-id
                (ebox-test--selector-region-id buffer "#scroll"))
          (ebox-rerender-buffer-with-context buffer 320 6)
          (ebox-rerender-buffer-with-context buffer 240 6)
          (let ((state (ebox--scroll-get-state scroll-id)))
            (should state)
            (should (= (ebox--string-pixel-width
                        (car (plist-get state :rendered-content-lines)))
                       240))
            (dotimes (_ 16)
              (setq state
                    (ebox--scroll-state-ensure-prefix-lines
                     scroll-id state
                     (1+ (length (plist-get state :content-lines)))
                     t))))
          (with-current-buffer buffer
            (dotimes (_ 6)
              (should (= (ebox--scroll-region-by scroll-id 1) 1)))
            (let ((scrolled (buffer-string)))
              (ebox-rerender-buffer-with-context buffer 240 6)
              (should (equal-including-properties
                       scrolled (buffer-string))))))
      (when scroll-id
        (ebox--scroll-cancel-idle-prefetch scroll-id))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))


(ert-deftest ebox-prepared-root-render-is-exact-one-shot-fast-path ()
  "An exact prepared root should bypass layout once and never affect children."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :width (240)
             (box :id "child" :content "prepared" :height 1))))
         buffer)
    (unwind-protect
        (let ((ebox-viewport-width 900)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prepared-root*") layout))
          (let* ((state (ebox--buffer-render-state buffer))
                 (root (plist-get state :root-node))
                 (child (ebox--buffer-region-render-owner-node
                         buffer
                         (ebox-test--selector-region-id buffer "#child")))
                 (rendered (propertize "prepared-root" 'face 'bold))
                 (prepared
                  (list :rendered rendered
                        :render-state state
                        :node-id (ebox--ensure-node-id root)
                        :runtime-revision 0
                        :display-signature
                        (with-current-buffer buffer
                          (ebox-display-signature))
                        :kind 'root-width
                        :region-id
                        (ebox-test--selector-region-id buffer "#root")
                        :root-width 240
                        :viewport-width 900
                        :viewport-height 4)))
            (with-current-buffer buffer
              (ebox--with-buffer-render-context buffer
                (let ((ebox--prepared-root-render prepared))
                  ;; A local subtree lookup must not inspect or consume the
                  ;; root-only handoff.
                  (ebox--render-with-cache child)
                  (should-not (plist-get prepared :consumed-p))
                  (cl-letf (((symbol-function 'ebox-render)
                             (lambda (&rest _)
                               (ert-fail "Exact prepared root reran layout"))))
                    (should (eq (ebox--render-with-cache root t) rendered)))
                  (should (plist-get prepared :consumed-p))
                  (should-not ebox--prepared-root-render))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-prepared-root-render-rejects-stale-runtime ()
  "A stale prepared root should fall back without entering later updates."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build '(box :id "root" :width (240) :content "old")))
         buffer
         (fallback-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 900)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-stale-prepared-root*")
                 layout))
          (let* ((state (ebox--buffer-render-state buffer))
                 (root (plist-get state :root-node))
                 (prepared
                  (list :rendered "stale"
                        :render-state state
                        :node-id (ebox--ensure-node-id root)
                        :runtime-revision 1
                        :display-signature
                        (with-current-buffer buffer
                          (ebox-display-signature))
                        :kind 'root-width
                        :region-id
                        (ebox-test--selector-region-id buffer "#root")
                        :root-width 240
                        :viewport-width 900
                        :viewport-height 4)))
            (with-current-buffer buffer
              (ebox--with-buffer-render-context buffer
                (let ((ebox--prepared-root-render prepared)
                      (ebox--render-cache-table
                       (make-hash-table :test 'equal)))
                  (cl-letf (((symbol-function 'ebox-render)
                             (lambda (&rest _)
                               (cl-incf fallback-count)
                               "fresh")))
                    (should (equal (ebox--render-with-cache root t) "fresh")))
                  (should (= fallback-count 1))
                  (should-not (plist-get prepared :consumed-p))
                  (should-not ebox--prepared-root-render))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-prewarm-reuses-live-isolated-scratch ()
  "Viewport predictions should reuse one nonmutating isolated live tree."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :width (viewport)
             (box :content "viewport scratch" :width (viewport) :height 1))))
         buffer)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-viewport-scratch*") layout))
          (let* ((state (ebox--buffer-render-state buffer))
                 (live-root (plist-get state :root-node))
                 scratch tree)
            (should
             (ebox--prewarm-buffer-render-cache-at-context
              buffer state 0 240 260 4))
            (setq scratch (plist-get state :reflow-prewarm-scratch)
                  tree (plist-get scratch :tree))
            (should scratch)
            (should-not (eq tree live-root))
            (should
             (ebox--prewarm-buffer-render-cache-at-context
              buffer state 0 240 280 4))
            (should (eq tree
                        (plist-get
                         (plist-get state :reflow-prewarm-scratch) :tree)))
            (should (eq live-root (plist-get state :root-node)))
            (should-not (plist-get scratch :predicted-revision))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-root-width-cache-prewarm-yields-to-user-input ()
  "Ordinary root prediction should run only after an idle interval."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :width (240)
             (box :content "scheduled ordinary root" :height 1))))
         buffer
         scheduled-delay
         scheduled-repeat
         scheduled-function
         scheduled-arguments)
    (unwind-protect
        (let ((ebox-viewport-width 900)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm t)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-root-schedule*")
                 layout))
          (let ((root-id (ebox-test--selector-region-id buffer "#root")))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (&rest _)
                         (ert-fail "Resize prediction must yield to input")))
                      ((symbol-function 'run-with-idle-timer)
                       (lambda (delay repeat function &rest arguments)
                         (setq scheduled-delay delay
                               scheduled-repeat repeat
                               scheduled-function function
                               scheduled-arguments arguments)
                         'scheduled-reflow-timer)))
              (ebox--schedule-buffer-root-width-cache-prewarm
               buffer root-id 240 260)))
          (should (= scheduled-delay
                     ebox-runtime-idle-reflow-cache-prewarm-delay))
          (should-not scheduled-repeat)
          (should (eq scheduled-function
                      #'ebox--run-root-width-cache-prewarm))
          (should (equal (car scheduled-arguments) buffer))
          (should (eq (gethash buffer ebox--reflow-cache-prewarm-timers)
                      'scheduled-reflow-timer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-scheduled-reflow-prewarms-use-offscreen-gc-pressure ()
  "Both predicted reflow paths should move GC pressure off visible frames."
  (let ((prewarm-count 0)
        (gc-count 0)
        observed)
    (cl-letf (((symbol-function
               'ebox--prewarm-buffer-render-cache-at-root-width)
              (lambda (&rest _)
                (cl-incf prewarm-count)
                (push (list gc-cons-threshold gc-cons-percentage
                            ebox-render-gc-cons-threshold
                            ebox-render-gc-cons-percentage)
                      observed)
                t))
             ((symbol-function
               'ebox--prewarm-buffer-render-cache-at-context)
              (lambda (&rest _)
                (cl-incf prewarm-count)
                (push (list gc-cons-threshold gc-cons-percentage
                            ebox-render-gc-cons-threshold
                            ebox-render-gc-cons-percentage)
                      observed)
                t))
             ((symbol-function 'garbage-collect)
              (lambda () (cl-incf gc-count))))
      (let ((ebox-reflow-cache-prewarm-gc-cons-threshold 123456)
            (ebox-reflow-cache-prewarm-gc-cons-percentage 0.2))
        (ebox--run-root-width-cache-prewarm
         nil nil 0 'root 300 315)
        (ebox--run-reflow-cache-prewarm
         nil nil 0 300 315 20)))
    (should (= prewarm-count 2))
    (should (= gc-count 0))
    (should (equal observed
                   '((123456 0.2 123456 0.2)
                     (123456 0.2 123456 0.2))))))

(ert-deftest ebox-reflow-prewarm-gc-adapts-to-measured-layout-cost ()
  "Automatic prewarm GC should follow measured allocation and layout time."
  (let ((ebox--physical-memory-bytes (* 16 1024 1024 1024))
        (ebox-reflow-cache-prewarm-gc-auto-frame-budget 0.2)
        (ebox-reflow-cache-prewarm-gc-auto-min-threshold (* 64 1024 1024))
        (ebox-reflow-cache-prewarm-gc-auto-max-threshold (* 1024 1024 1024))
        (ebox-reflow-cache-prewarm-gc-auto-target-layouts 24))
    (should (= (ebox--reflow-cache-prewarm-auto-threshold-for-allocation
                (* 28 1024 1024) 0.16)
               (* 672 1024 1024)))
    (should (= (ebox--reflow-cache-prewarm-auto-threshold-for-allocation
                (* 8 1024 1024) 0.08)
               (* 128 1024 1024)))
    (should (= (ebox--reflow-cache-prewarm-auto-threshold-for-allocation
                (* 2 1024 1024) 0.02)
               (* 64 1024 1024)))
    (should (= (ebox--reflow-cache-prewarm-auto-threshold-for-allocation
                (* 64 1024 1024) 0.21)
               (* 1024 1024 1024)))
    (should (= (ebox--memory-use-counts-estimated-bytes
                '(0 0 0 0 0 0 0) '(1 1 1 1 1 1 1))
               161))
    (let ((state (list :runtime-revision 0)))
      (ebox--record-reflow-cache-prewarm-cost
       state 0.16 0 (* 512 1024 1024) (* 28 1024 1024))
      (should (= (plist-get state :reflow-prewarm-gc-threshold)
                 (* 672 1024 1024)))
      (ebox--record-reflow-cache-prewarm-cost
       state 0.5 1 (* 672 1024 1024) (* 28 1024 1024))
      (should (= (plist-get state :reflow-prewarm-gc-threshold)
                 (* 672 1024 1024)))
      (should (= (plist-get state :reflow-prewarm-layout-seconds) 0.16)))))

(ert-deftest ebox-buffer-backend-maps-paint-style-to-text-properties ()
  "Paint mapping should be a backend operation, not a style-model operation."
  (let* ((style (ebox-style-compute
                 (list :color "#111111"
                       :background-color "#eeeeee"
                       :border-color "#333333")))
         (props (ebox-buffer-paint-text-properties style 'content)))
    (should props)
    (should (plist-member props 'face))))

(ert-deftest ebox-buffer-backend-does-not-map-layout-only-properties ()
  "Layout-only properties should not produce text properties directly."
  (let* ((style (ebox-style-compute
                 (list :width '(120)
                       :padding '(1 2))))
         (props (ebox-buffer-paint-text-properties style 'content)))
    (should-not (memq :width props))
    (should-not (memq :padding-inline-start props))))

(ert-deftest ebox-add-content-owner-ignores-paint-only-segment-changes ()
  "Owner stacking should segment only when owner metadata changes."
  (let ((line (copy-sequence "abcdefgh"))
        (stack-lookups 0)
        (original-stack-at (symbol-function 'ebox--content-owner-stack-at)))
    (add-text-properties 0 4 '(ebox-content-owner child-a) line)
    (add-text-properties 4 8 '(ebox-content-owner child-b) line)
    (add-text-properties 1 2 '(face (:foreground "#111111")) line)
    (add-text-properties 2 3 '(display (space :width (3))) line)
    (add-text-properties 5 6 '(face (:background "#eeeeee")) line)
    (cl-letf (((symbol-function 'ebox--content-owner-stack-at)
               (lambda (&rest args)
                 (cl-incf stack-lookups)
                 (apply original-stack-at args))))
      (let ((owned (ebox--add-content-owner line 'root)))
        (should (= stack-lookups 2))
        (should (equal '(child-a root)
                       (get-text-property 0 'ebox-content-owners owned)))
        (should (equal '(child-b root)
                       (get-text-property 4 'ebox-content-owners owned)))))))

(ert-deftest ebox-add-content-owner-scans-complete-owner-stacks-once ()
  "Complete owner stacks should not require a parallel owner-property scan."
  (let ((line (copy-sequence "abcdefgh"))
        (property-scans 0)
        (original-next (symbol-function 'next-single-property-change)))
    (add-text-properties
     0 4 '(ebox-content-owner child-a ebox-content-owners (child-a)) line)
    (add-text-properties
     4 8 '(ebox-content-owner child-b ebox-content-owners (child-b)) line)
    (cl-letf (((symbol-function 'next-single-property-change)
               (lambda (position property &rest args)
                 (when (memq property
                             '(ebox-content-owner ebox-content-owners))
                   (cl-incf property-scans))
                 (apply original-next position property args))))
      (let ((owned (ebox--add-content-owner line 'root)))
        (should (= property-scans 2))
        (should (equal '(child-a root)
                       (get-text-property 0 'ebox-content-owners owned)))
        (should (equal '(child-b root)
                       (get-text-property 4 'ebox-content-owners owned)))))))

(ert-deftest ebox-add-content-owners-merges-all-owners-in-one-scan ()
  "Adding several owners should scan each original owner run only once."
  (let ((line (copy-sequence "abcdefgh"))
        (property-scans 0)
        (original-next (symbol-function 'next-single-property-change)))
    (add-text-properties 0 4 '(ebox-content-owner child-a) line)
    (add-text-properties 4 8 '(ebox-content-owner child-b) line)
    (cl-letf (((symbol-function 'next-single-property-change)
               (lambda (position property &rest args)
                 (when (memq property
                             '(ebox-content-owner ebox-content-owners))
                   (cl-incf property-scans))
                 (apply original-next position property args))))
      (let ((owned (ebox--add-content-owners line '(middle root))))
        (should (= property-scans 4))
        (should (eq (get-text-property 0 'ebox-content-owner owned) 'root))
        (should (equal '(child-a middle root)
                       (get-text-property 0 'ebox-content-owners owned)))
        (should (equal '(child-b middle root)
                       (get-text-property 4 'ebox-content-owners owned)))))))

(ert-deftest ebox-propertize-content-line-can-own-private-line-in-place ()
  "A private split line should accept wrapper ownership without another copy."
  (let* ((source (propertize "content"
                            'ebox-content 'child
                            'ebox-content-owner 'child
                            'ebox-content-owners '(child)))
         (source-before (copy-sequence source))
         (private-line (copy-sequence source))
         (regular
          (ebox--propertize-content-line source 'wrapper 0 "fallback"))
         (owned
          (let ((ebox--propertize-private-content-line-p t))
            (ebox--propertize-content-line
             private-line 'wrapper 0 "fallback"))))
    (should-not (eq regular source))
    (should (equal-including-properties source source-before))
    (should (eq owned private-line))
    (should (eq (get-text-property 0 'ebox-content-owner owned) 'wrapper))
    (should (equal (get-text-property 0 'ebox-content-owners owned)
                   '(child wrapper)))))

(ert-deftest ebox-scroll-rendered-content-lines-own-color-copy-in-place ()
  "Colored scroll lines should add ownership to the color copy in place."
  (let* ((box (ebox-create :width 120
                           :color "#112233"
                           :bgcolor "#F4F5F6"))
         (region-id 901)
         (source (propertize "child" 'ebox-content 77
                            'ebox-content-owner 77
                            'ebox-content-owners '(77)))
         (source-before (copy-sequence source))
         (filler (ebox-pixel-space (ebox--content-pixel box)))
         (expected
          (ebox--propertize-colors
           (ebox--propertize-content-line source region-id 4 filler)
           (ebox-get box :color)
           (ebox-get box :bgcolor)))
         (copying-owner-count 0)
         (original-copying-owner
          (symbol-function 'ebox--add-content-owner))
         actual)
    (cl-letf (((symbol-function 'ebox--add-content-owner)
               (lambda (&rest args)
                 (cl-incf copying-owner-count)
                 (apply original-copying-owner args))))
      (setq actual
            (car (ebox--scroll-rendered-content-lines
                  box (list source) region-id 4))))
    (should (equal-including-properties source source-before))
    (should (equal-including-properties actual expected))
    (should (= copying-owner-count 0))))

(ert-deftest ebox-box-render-coalesces-foreground-background-pass ()
  "Foreground and background should not each copy the rendered box lines."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "paint"
                           :width 12 :height 1
                           :color "#112233"
                           :bgcolor "#ddeeff"))
         (reference (ebox-render box))
         (original-color (symbol-function 'ebox--propertize-color))
         (original-bgcolor (symbol-function 'ebox--propertize-bgcolor))
         (color-calls 0)
         (bgcolor-calls 0)
         actual)
    (cl-letf (((symbol-function 'ebox--propertize-color)
               (lambda (&rest args)
                 (cl-incf color-calls)
                 (apply original-color args)))
              ((symbol-function 'ebox--propertize-bgcolor)
               (lambda (&rest args)
                 (cl-incf bgcolor-calls)
                 (apply original-bgcolor args))))
      (setq actual (ebox-render box)))
    (should (= color-calls 0))
    (should (= bgcolor-calls 0))
    (should (equal-including-properties actual reference))))

(ert-deftest ebox-incremental-update-scheduler-batches-multiple-style-changes ()
  "Scheduler seed should coalesce multiple property changes into one flush."
  (let* ((node (ebox-create :content "Batch" :border-color "#111111"))
         (id (car (ebox-region-ids node))))
    (ebox-test--with-rendered-buffer node
      (ebox-incremental-begin-batch (current-buffer))
      (ebox-test--region-update id :border-color "#222222")
      (ebox-test--region-update id :background-color "#eeeeee")
      (should (= (ebox-incremental-pending-count (current-buffer)) 2))
      (ebox-incremental-flush (current-buffer))
      (let ((report (ebox-test--buffer-update-report)))
        (should (= (plist-get report :flush-count) 1))
        (should (= (plist-get report :patch-count) 1))
        (should (member 'paint (plist-get report :dirty-kinds)))))))

(ert-deftest ebox-explicit-batch-keeps-stronger-same-owner-operation ()
  "Same-owner paint and geometry must preserve the stronger operation."
  (dolist (order '((paint geometry) (geometry paint)))
    (ebox-test--reset-runtime-state)
    (let* ((box (ebox-create :content "Batch width" :width '(160)
                             :color "black"))
           (id (car (ebox-region-ids box))))
      (ebox-test--with-rendered-buffer box
        (let ((buffer (current-buffer)))
          (ebox-incremental-begin-batch buffer)
          (dolist (operation order)
            (pcase operation
              ('paint (ebox-test--region-update id :color "red"))
              ('geometry (ebox-test--region-update id :width '(80)))))
          (ebox-incremental-flush buffer))
        (let ((report (ebox-test--buffer-update-report)))
          (let ((runtime-box
                 (gethash id (ebox--buffer-region-box-table
                              (current-buffer)))))
            (should (equal (ebox-get box :width) 160))
            (should (= (ebox-get runtime-box :width) 80)))
          (should (ebox-test--buffer-visually-matches-runtime-render-p))
          (should-not (eq (plist-get report :strategy) 'paint-patch)))))))

(ert-deftest ebox-explicit-batch-keeps-descendant-paint-after-ancestor-paint ()
  "Ancestor and child paint must execute general-to-specific in any input order."
  (dolist (order '((parent child) (child parent)))
    (ebox-test--reset-runtime-state)
    (let ((layout
           (ebox-build
            '(box :id parent :width (120) :color "black"
              (box :id child :content "Child" :width (120)
                   :color "black")))))
      (ebox-test--with-rendered-buffer layout
        (let* ((buffer (current-buffer))
               (parent-id (ebox-test--selector-region-id buffer "#parent"))
               (child-id (ebox-test--selector-region-id buffer "#child")))
          (ebox-incremental-begin-batch buffer)
          (dolist (operation order)
            (pcase operation
              ('parent (ebox-test--region-update parent-id :color "red"))
              ('child (ebox-test--region-update child-id :color "blue"))))
          (ebox-incremental-flush buffer))
        (goto-char (point-min))
        (search-forward "Child")
        (let ((face (get-text-property (- (point) (length "Child")) 'face)))
          (should (ebox-test--face-has-key-value-p
                   face :foreground "blue")))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-explicit-batch-paints-before-descendant-text-change ()
  "Ancestor paint must run before a descendant text-changing operation."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id parent :width (160) :color "black"
            (box :id child :content "Child" :width (120)
                 :color "blue")))))
    (ebox-test--with-rendered-buffer layout
      (let* ((buffer (current-buffer))
             (parent-id (ebox-test--selector-region-id buffer "#parent"))
             (child-id (ebox-test--selector-region-id buffer "#child")))
        (ebox-incremental-begin-batch buffer)
        (ebox-test--region-update parent-id :color "red")
        (ebox-test--region-update child-id :width '(80))
        (ebox-incremental-flush buffer))
      (goto-char (point-min))
      (search-forward "Child")
      (let ((face (get-text-property (- (point) (length "Child")) 'face)))
        (should (ebox-test--face-has-key-value-p
                 face :foreground "blue")))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(defun ebox-test--multi-row-batch-flex-layout ()
  "Return a wrapped flex fixture with targets on separate rows."
  (ebox-build
   '(flex :id matrix :width (500) :flex-flow (row wrap)
     :column-gap (12) :row-gap 1 :padding (0 (12))
     :border "#999999"
     (column :width (210) :border "#999999"
      (box :content "Title A" :width (190))
      (box :id target-a :content "Target A" :width (160)
           :height 3 :padding (0 (8)) :border "#999999"
           :text-align right)
      (box :content "Metric A" :width (190) :height 2))
     (column :width (210) :border "#999999"
      (box :content "Peer A" :width (190))
      (box :content "Same first row" :width (190) :height 3)
      (box :content "Metric B" :width (190) :height 2))
     (column :width (210) :border "#999999"
      (box :content "Title B" :width (190))
      (box :id target-b :content "Target B" :width (160)
           :height 3 :padding (0 (8)) :border "#999999"
           :text-align right)
      (box :content "Metric C" :width (190) :height 2))
     (column :width (210) :border "#999999"
      (box :content "Peer B" :width (190))
      (box :content "Same second row" :width (190) :height 3)
      (box :content "Metric D" :width (190) :height 2)))))

(ert-deftest ebox-explicit-batch-multiple-flex-rows-skip-line-fast-path ()
  "Dirty descendants on separate flex rows must rerender in either order."
  (dolist (order '((target-a target-b) (target-b target-a)))
    (ebox-test--reset-runtime-state)
    (let ((layout (ebox-test--multi-row-batch-flex-layout)))
      (ebox-test--with-rendered-buffer layout
        (let* ((buffer (current-buffer))
               (target-a-id
                (ebox-test--selector-region-id buffer "#target-a"))
               (target-b-id
                (ebox-test--selector-region-id buffer "#target-b")))
          (ebox-incremental-begin-batch buffer)
          (dolist (target order)
            (ebox-test--region-update
             (if (eq target 'target-a) target-a-id target-b-id)
             :width '(210) :min-width '(150) :max-width '(260)))
          (ebox-incremental-flush buffer))
        (let ((report (ebox-test--buffer-update-report)))
          (should (ebox-test--buffer-visually-matches-runtime-render-p))
          (should-not (plist-get report :flex-line-rerender)))))))

(ert-deftest ebox-explicit-batch-absorbed-flex-descendant-keeps-provenance ()
  "An absorbed descendant update must disable a partial flex owner rerender."
  (dolist (order '((geometry paint) (paint geometry)))
    (ebox-test--reset-runtime-state)
    (let ((layout (ebox-test--multi-row-batch-flex-layout)))
      (ebox-test--with-rendered-buffer layout
        (let* ((buffer (current-buffer))
               (target-a-id
                (ebox-test--selector-region-id buffer "#target-a"))
               (target-b-id
                (ebox-test--selector-region-id buffer "#target-b")))
          (ebox-incremental-begin-batch buffer)
          (dolist (operation order)
            (pcase operation
              ('geometry
               (ebox-test--region-update target-a-id
                                   :width '(210)
                                   :min-width '(150)
                                   :max-width '(260)))
              ('paint
               (ebox-test--region-update target-b-id :color "blue"))))
          (ebox-incremental-flush buffer))
        (goto-char (point-min))
        (search-forward "Target B")
        (let* ((start (- (point) (length "Target B")))
               (face (get-text-property start 'face))
               (report (ebox-test--buffer-update-report)))
          (should (ebox-test--face-has-key-value-p
                   face :foreground "blue"))
          (should (ebox-test--buffer-visually-matches-runtime-render-p))
          (should-not (plist-get report :flex-line-rerender)))))))

(ert-deftest ebox-layout-module-renders-row-and-column-through-facade ()
  "Facade rendering should still use extracted layout owners."
  (let ((rendered (ebox-render
                   (ebox-build
                    '(column
                      (row
                       (box :content "A" :width (40))
                       (box :content "B" :width (40))))))))
    (should (string-match-p "A" rendered))
    (should (string-match-p "B" rendered))))

(ert-deftest ebox-layout-snapshot-details-are-computed-lazily ()
  "Initial render should store cheap snapshots and complete spans on demand."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "L" :width 40 :border t))
         (right (ebox-create :content "R" :width 40 :border t))
         (layout (ebox-concat left right))
         buffer)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (let* ((root-id (plist-get (ebox-test--runtime-root buffer)
                                     :node-id))
                 (snapshot (ebox--layout-snapshot buffer root-id)))
            (should snapshot)
            (should (eq (plist-get snapshot :type) 'concat))
            (should-not (plist-member snapshot :line-signature))
            (should-not (plist-member snapshot :buffer-spans))
            (let ((detailed
                   (ebox--ensure-layout-snapshot-details buffer root-id)))
              (should (plist-get detailed :line-signature))
              (should (plist-get detailed :buffer-spans))
              (should (plist-member
                       (ebox--layout-snapshot buffer root-id)
                       :line-signature)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-layout-snapshot-details-include-footprint-signatures ()
  "Detailed snapshots should expose explicit L2 footprint signatures."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Footprint" :width '(120)
                           :height 1 :border t))
         (node-id (ebox--ensure-node-id box)))
    (ebox-test--with-rendered-buffer box
      (let* ((snapshot (ebox--ensure-layout-snapshot-details
                        (current-buffer) node-id))
             (span-footprint
              (plist-get snapshot :span-footprint-signature))
             (external-footprint
              (plist-get snapshot :external-footprint-signature))
             (parent-slot
              (plist-get snapshot :parent-slot-signature))
             (role-topology
              (plist-get snapshot :role-topology-signature))
             (overflow
              (plist-get snapshot :overflow-signature)))
        (should span-footprint)
        (should external-footprint)
        (should parent-slot)
        (should role-topology)
        (should overflow)
        (should (= (plist-get span-footprint :span-count) 1))
        (should (equal (plist-get span-footprint :line-pixel-widths)
                       (plist-get snapshot :line-signature)))
        (should (= (plist-get external-footprint :block-lines) 1))
        (should (= (plist-get external-footprint :max-line-pixel-width)
                   (car (plist-get snapshot :line-signature))))
        (should (= (plist-get parent-slot :slot-count) 1))
        (should (memq 'content (plist-get role-topology :roles)))
        (should-not (plist-get overflow :visible))))))

(ert-deftest ebox-role-topology-signature-uses-published-span-index ()
  "Role topology should reflect the published TP mount index."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Indexed" :width '(120) :border t))
         (region-id (ebox--ensure-region-id box)))
    (ebox-test--with-rendered-buffer box
      (let ((roles (plist-get (ebox--role-topology-signature
                              (list region-id))
                             :roles)))
        (should (ebox-surface-region-mounts (current-buffer) region-id))
        (should (memq 'content roles))
        (should (memq 'content-owner roles))))))





(ert-deftest ebox-layout-snapshot-capture-skips-line-ownership-scan ()
  "Initial snapshot capture should not scan line ownership for every node."
  (ebox-test--reset-runtime-state)
  (let* ((layout (apply
                  #'ebox-column
                  (cl-loop for index below 8
                           collect
                           (ebox-flex
                            :border "#64748B" :bgcolor "#F8FAFC"
                            :flex-flow '(row wrap)
                            (ebox-create
                             :content (format "A%d" index)
                             :width 60 :bgcolor "#DBEAFE")
                            (ebox-create
                             :content (format "B%d" index)
                             :width 60 :bgcolor "#DCFCE7")
                            (ebox-create
                             :content (format "C%d" index)
                             :width 60 :bgcolor "#FEF3C7")))))
         (calls 0)
         (original (symbol-function 'ebox--pos-region-ids))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 900))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (ebox--clear-layout-snapshots buffer)
          (cl-letf (((symbol-function 'ebox--pos-region-ids)
                     (lambda (&rest args)
                       (cl-incf calls)
                       (apply original args))))
            (ebox--refresh-buffer-layout-snapshots buffer))
          (should (= calls 0)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-stack-render-flattens-before-width-measurement ()
  "Column rendering should not repeatedly measure already stacked strings."
  (ebox-test--reset-runtime-state)
  (let* ((layout (apply
                  #'ebox-column
                  (cl-loop for index below 12
                           collect
                           (ebox-create
                            :content (format "Row %02d" index)
                            :width (+ 40 (* index 2))))))
         (multiline-width-calls 0)
         (original (symbol-function 'ebox--string-pixel-width)))
    (cl-letf (((symbol-function 'ebox--string-pixel-width)
               (lambda (string)
                 (when (and (stringp string)
                            (string-match-p "\n" string))
                   (cl-incf multiline-width-calls))
                 (funcall original string))))
      (ebox-render layout))
    (should (= multiline-width-calls 0))))

(ert-deftest ebox-lines-concat-horizontal-splits-each-input-once ()
  "Horizontal line concatenation should avoid split-pad-resplit work."
  (ebox-test--reset-runtime-state)
  (let ((split-count 0)
        (original (symbol-function 'ebox-string-lines))
        result)
    (cl-letf (((symbol-function 'ebox-string-lines)
               (lambda (&rest args)
                 (cl-incf split-count)
                 (apply original args))))
      (setq result
            (ebox--lines-concat-horizontal
             "A\nB\nC"
             "1\n2"
             "x")))
    (should (string= (substring-no-properties result)
                     "A1x\nB2 \nC  "))
    (should (= split-count 3))))

(ert-deftest ebox-layout-snapshot-table-is-created-when-missing ()
  "Snapshot storage should tolerate render states created before snapshots."
  (ebox-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-test*"))
        (node-id "legacy-node"))
    (unwind-protect
        (progn
          (puthash buffer
                   (list :root-node nil
                         :viewport-width 80)
                   ebox--buffer-render-state-table)
          (ebox--put-layout-snapshot buffer node-id (list :node-id node-id))
          (should (equal (plist-get (ebox--layout-snapshot buffer node-id)
                                    :node-id)
                         node-id)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-layout-snapshot-records-display-style-and-wrapper-children ()
  "Snapshots should describe display, style, and child ids for wrapper boxes."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :padding 1 :bgcolor "linen"
                  (box :content "Child A" :width (120))
                  (box :content "Child B" :width (120)))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 node))
          (let* ((snapshot (ebox--layout-snapshot
                            buffer
                            (plist-get (ebox-test--runtime-root buffer)
                                       :node-id)))
                 (child-ids (plist-get snapshot :child-ids))
                 (child-snapshot (ebox--layout-snapshot buffer (car child-ids))))
            (should (equal (plist-get snapshot :display) '(block flow)))
            (should (equal (plist-get child-snapshot :display)
                           '(block column)))
            (should (plist-get snapshot :style-signature))
            (should child-ids)
            (should (= (length child-ids) 1))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-dirty-set-classifies-paint-only-change ()
  "A color-only change should produce paint dirty, not geometry dirty."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Paint" :width 80
                           :border t :border-color "red"))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (let ((old (ebox--current-layout-snapshots (current-buffer))))
        (ebox-test--region-update region-id :border-color "blue")
        (let ((dirty (ebox--diff-layout-snapshots
                      old
                      (ebox--current-layout-snapshots (current-buffer)))))
          (should dirty)
          (should (eq (plist-get (car dirty) :dirty-kind) 'paint)))))))

(ert-deftest ebox-dirty-set-classifies-viewport-wrap-change ()
  "Viewport wrapping should produce geometry or placement dirty."
  (ebox-test--reset-runtime-state)
  (let ((ebox-viewport-width 240)
        buffer
        layout)
    (setq layout
          (ebox-flex :flex-wrap 'wrap
            (ebox-create :content "A" :width '(120))
            (ebox-create :content "B" :width '(120))))
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (let ((old (ebox--current-layout-snapshots buffer t)))
            (ebox-rerender-buffer-with-context buffer 130)
            (let ((dirty (ebox--diff-layout-snapshots
                          old
                          (ebox--current-layout-snapshots buffer t))))
              (should (cl-some
                       (lambda (entry)
                         (memq (plist-get entry :dirty-kind)
                               '(geometry placement structure)))
                       dirty)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-dirty-set-classifies-wrapper-child-viewport-geometry ()
  "Viewport reflow under a wrapper should produce geometry dirty, not no-op."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :padding 1
                  (box :content "Text that wraps differently when narrow"
                       :wrap-mode word))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer
                (let ((ebox-viewport-width 520))
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   node)))
          (ebox-rerender-buffer-with-context buffer 36)
          (let ((report (ebox-test--buffer-update-report)))
            (should (eq (plist-get report :constraint-source) 'viewport))
            (should (member 'geometry (plist-get report :dirty-kinds)))
            (should-not (eq (plist-get report :strategy) 'no-op))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-patch-set-paints-without-rendered-text-replace ()
  "Paint-only dirty entries should produce paint-patch ops."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Paint" :width 80
                           :border t :border-color "red"))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (let ((full-rerenders
             (ebox-test--count-full-surface-updates
               (ebox-test--region-update region-id :border-color "blue"))))
        (should (= full-rerenders 0)))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'paint-patch))
        (should (eq (plist-get report :full-rerender) nil))))))

(ert-deftest ebox-flex-wrapper-style-update-uses-paint-patch ()
  "Flex wrapper style updates should patch faces without replacing spans."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-flex
                  :border "#5E7F6A" :bgcolor "#F8FCF8"
                  (ebox-create :content "A" :width 60
                               :bgcolor "#DCEBDD")))
         (region-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update region-id :bgcolor "#FDE68A")
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'paint-patch))
        (should-not (plist-get report :full-rerender))
        (should (equal (plist-get report :patch-ops)
                       '(paint-patch)))))))

(ert-deftest ebox-patch-set-promotes-interleaved-row-child-to-row-owner ()
  "Interleaved row children should promote to their common render owner."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "Left" :width 60))
         (right (ebox-create :content "Right" :width 60))
         (layout (ebox-row left right))
         (left-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update left-id :width '(120))
      (let ((report (ebox-test--buffer-update-report)))
        (should (memq (plist-get report :owner-type) '(concat row)))
        (should-not (eq (plist-get report :owner-type) 'box))))))

(ert-deftest ebox-viewport-resize-patches-single-dependent-box ()
  "Viewport resize should patch the smallest dependent owner when possible."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-column
                  (ebox-create :content "Fixed" :width '(120) :border t)
                  (ebox-create :content "Fluid" :width 'stretch :border t)))
         buffer
         ids-before)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 240))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (setq ids-before (ebox-region-ids layout))
          (let ((returned
                 (ebox-rerender-buffer-with-context buffer 260)))
            (should (equal returned
                           (ebox-buffer-update-report buffer))))
          (should (equal (ebox-region-ids layout) ids-before))
          (let ((report (ebox-test--buffer-update-report)))
            (should (memq (plist-get report :strategy)
                          '(span-patch owner-rerender root-rerender)))
            (should (plist-get report :dirty-count))
            (should (= (plist-get report :dirty-count) 1))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-rerender-report-describes-constraint-change ()
  "Viewport resize reports should use the shared constraint-change model."
  (ebox-test--reset-runtime-state)
  (let ((ebox-viewport-width 240)
        buffer
        layout)
    (setq layout
          (ebox-flex :flex-wrap 'wrap
            (ebox-create :content "A" :width '(120))
            (ebox-create :content "B" :width '(120))))
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (ebox-rerender-buffer-with-context buffer 160)
          (let ((report (ebox-test--buffer-update-report)))
            (should (eq (plist-get report :constraint-source) 'viewport))
            (should (eq (plist-get report :constraint-owner-type)
                        'viewport))
            (should (equal (plist-get report :constraint-owner-id)
                           'viewport))
            (should (equal (plist-get report :constraint-root-node-id)
                           (plist-get (ebox-test--runtime-root buffer)
                                      :node-id)))
            (should (equal (plist-get report :dirty-kinds)
                           '(geometry)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-rerender-patches-column-children-independently ()
  "Viewport resize should publish the correct column scope through TP."
  (ebox-test--reset-runtime-state)
  (let* ((top (ebox-create
               :content "Top text should wrap into more lines when narrow."
               :wrap-mode 'word))
         (bottom (ebox-create
                  :content "Bottom text should also survive after top grows."
                  :wrap-mode 'word))
         (layout (ebox-column top bottom))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 260))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (ebox-rerender-buffer-with-context buffer 90)
          (let ((report (ebox-test--buffer-update-report))
                (plain (with-current-buffer buffer
                         (buffer-substring-no-properties
                          (point-min) (point-max)))))
            (should-not (plist-get report :tp-full-root))
            (should (> (plist-get report :tp-scope-count) 0))
            (should-not (plist-get report :tp-scope-fallback))
            (should (string-match-p "Top text" plain))
            (should (string-match-p "Bottom text" plain))
            (should
             (with-current-buffer buffer
               (ebox-test--buffer-propertized-matches-runtime-render-p)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-rerender-noops-without-viewport-deps ()
  "Viewport resize should not rerender when no node depends on viewport width."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-create :content "Fixed" :width 80))
        buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 240))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (ebox-rerender-buffer-with-context buffer 160)
          (let ((report (ebox-test--buffer-update-report)))
            (should (eq (plist-get report :strategy) 'no-op))
            (should (= (plist-get report :dirty-count) 0))
            (should (= (plist-get report :patch-count) 0))
            (should-not (plist-get report :full-rerender))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-region-width-update-report-describes-constraint-change ()
  "Ordinary box geometry updates should use the shared constraint-change model."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "Left" :width 60))
         (right (ebox-create :content "Right" :width 60))
         (layout (ebox-row left right))
         (left-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update left-id :width '(120))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :constraint-source) 'region))
        (should (eq (plist-get report :constraint-owner-type) 'box))
        (should
         (equal (plist-get report :constraint-owner-id)
                (gethash left-id
                         (ebox--buffer-region-node-table
                          (current-buffer)))))
        (should (equal (plist-get report :dirty-kinds)
                       '(geometry)))))))

(ert-deftest ebox-root-region-width-reflow-rebinds-lazy-content-viewport ()
  "A root width update should constrain lazy descendants like viewport resize."
  (ebox-test--reset-runtime-state)
  (let* ((ebox-viewport-width 240)
         (ebox-viewport-height 2)
         (layout
          (ebox-build
           '(box :id "root" :width (240) :height (viewport-height)
                 :overflow scroll
             (column
              (box :content "first" :width (viewport))
              (box :content "second" :width (viewport))
              (box :content "third" :width (viewport))))))
         (root-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update root-id :width '(160))
      (let ((widths
             (mapcar #'ebox--string-pixel-width
                     (ebox-string-lines (buffer-string)))))
        (should widths)
        (should (= (apply #'max widths) 160))))))

(ert-deftest ebox-region-width-update-promotes-parent-layout-owner ()
  "Child geometry changes should patch the parent layout that reflows siblings."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "Left" :width 60))
         (right (ebox-create :content "Right" :width 60))
         (layout (ebox-row left right))
         (left-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update left-id :width '(120))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :constraint-owner-type) 'box))
        (should (eq (plist-get report :owner-type) 'concat))
        (should (equal (plist-get report :patch-ops)
                       '(owner-rerender))))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Left" plain))
        (should (string-match-p "Right" plain))))))

(ert-deftest ebox-wrapper-child-width-update-promotes-to-wrapper-context ()
  "Child geometry inside a wrapper should promote to the wrapper formatting context."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :padding 1
                  (row
                   (box :content "Left" :width (60))
                   (box :content "Right" :width (60))))))
         (ids (ebox-region-ids node))
         (left-id (nth 1 ids)))
    (ebox-test--with-rendered-buffer node
      (let ((root-node-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox-test--region-update left-id :width '(120))
        (let ((report (ebox-test--buffer-update-report)))
          (should (equal (plist-get report :owner-ids)
                         (list root-node-id)))
          (should (= (plist-get report :tp-scope-count) 1))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :constraint-source) 'region))
        (should (memq 'owner-rerender (plist-get report :patch-ops))))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Left" plain))
        (should (string-match-p "Right" plain))))))

(ert-deftest ebox-patch-set-uses-wrapper-owner-for-contained-layout-change ()
  "Contained layout changes should patch a real owner instead of vanishing."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column
                  (box :content "Stable header" :width (180))
                  (column :padding 1
                   (box :content "Child text wraps under the wrapper viewport"
                        :wrap-mode word)))))
         buffer)
    (unwind-protect
        (progn
          (setq buffer
                (let ((ebox-viewport-width 520))
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   node)))
          (ebox-rerender-buffer-with-context buffer 36)
          (let ((report (ebox-test--buffer-update-report)))
            (should (memq (plist-get report :strategy)
                          '(owner-rerender root-rerender)))
            (should (plist-get report :owner-ids))
            (should-not (equal (plist-get report :patch-ops)
                               '(paint-patch)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-patch-set-skips-dirty-nodes-covered-by-owner ()
  "Viewport patch planning should not repeatedly inspect covered dirty nodes."
  (ebox-test--reset-runtime-state)
  (let* ((layout (apply
                  #'ebox-row
                  (cl-loop for index below 24
                           collect
                           (ebox-create
                            :content (format "Fluid %02d" index)
                            :border t))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 640))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (let* ((root (ebox--buffer-root-node buffer))
                 (dirty (ebox--viewport-dirty-set root))
                 (detail-calls 0)
                 (original
                  (symbol-function 'ebox--ensure-layout-snapshot-details))
                 patches)
            (should (> (length dirty) 10))
            (cl-letf (((symbol-function
                        'ebox--ensure-layout-snapshot-details)
                       (lambda (&rest args)
                         (cl-incf detail-calls)
                         (apply original args))))
              (setq patches
                    (ebox-incremental--declarative-tentative-patch-set
                     buffer dirty)))
            (should (= (length patches) 1))
            (should (eq (plist-get (car patches) :op)
                        'owner-rerender))
            (should (<= detail-calls 4))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-patch-set-coalesces-large-column-coverage ()
  "Large local owner sets should coalesce when they cover most root lines."
  (ebox-test--reset-runtime-state)
  (let* ((layout (apply
                  #'ebox-column
                  (cl-loop for index below 12
                           collect
                           (ebox-create
                            :content (format "Fluid section %02d" index)
                            :border t))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 640))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (let* ((root (ebox--buffer-root-node buffer))
                 (dirty (ebox--viewport-dirty-set root))
                 (patches
                  (ebox-incremental--declarative-tentative-patch-set
                   buffer dirty))
                 (source-ids
                  (ebox--dirty-provenance-node-ids
                   (plist-get (car patches) :dirty))))
            (should (> (length dirty) 8))
            (should (= (length patches) 1))
            (should (equal (plist-get (car patches) :owner-id)
                           (plist-get root :node-id)))
            (should (= (length source-ids) (length dirty)))
            (dolist (entry dirty)
              (should (member (plist-get entry :node-id) source-ids)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-rerender-root-owner-allows-line-count-change ()
  "Root owner rerender should patch even when viewport wrapping changes height."
  (ebox-test--reset-runtime-state)
  (let* ((content
          "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu")
         (layout (apply
                  #'ebox-column
                  (cl-loop for _index below 12
                           collect
                           (ebox-create
                            :content content
                            :width 'viewport
                            :wrap-mode 'word
                            :border t))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 120))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (let ((wide-height (with-current-buffer buffer
                               (count-lines (point-min) (point-max)))))
            (ebox-rerender-buffer-with-context buffer 20)
            (let ((report (ebox-test--buffer-update-report))
                  (narrow-height (with-current-buffer buffer
                                   (count-lines (point-min) (point-max)))))
              (should (> narrow-height wide-height))
              (should (eq (plist-get report :strategy) 'owner-rerender))
              (should-not (plist-get report :root-rerender)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-root-owner-rerender-skips-partial-slot-probe ()
  "Whole-line root owner rerenders should not run partial-slot probing."
  (ebox-test--reset-runtime-state)
  (let* ((content
          "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu")
         (layout (apply
                  #'ebox-column
                  (cl-loop for _index below 12
                           collect
                           (ebox-create
                            :content content
                            :width 'viewport
                            :wrap-mode 'word
                            :border t))))
         (slot-probe-count 0)
         (original (symbol-function 'ebox-buffer--rendered-in-existing-slots))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 120))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (cl-letf (((symbol-function 'ebox-buffer--rendered-in-existing-slots)
                     (lambda (&rest args)
                       (cl-incf slot-probe-count)
                       (apply original args))))
            (ebox-rerender-buffer-with-context buffer 20))
          (let ((report (ebox-test--buffer-update-report)))
            (should (eq (plist-get report :strategy) 'owner-rerender))
            (should (equal (plist-get report :owner-ids)
                           (list (plist-get
                                  (ebox-test--runtime-root buffer)
                                  :node-id)))))
          (should (= slot-probe-count 0)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-buffer-render-context-selects-target-buffer ()
  "Buffer render contexts should evaluate render-sensitive work in target buffers."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-create :content "context target"))
         (buffer nil)
         (other nil)
         seen-buffer)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 node))
          (setq other (generate-new-buffer " *ebox-other*"))
          (with-current-buffer other
            (ebox--with-buffer-render-context buffer
              (setq seen-buffer (current-buffer))))
          (should (eq seen-buffer buffer)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer))
      (when (and other (buffer-live-p other))
        (kill-buffer other)))))

(ert-deftest ebox-buffer-render-context-preserves-caller-state-binding ()
  "Render context internals should not capture a caller's STATE variable."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-create :content "context state"))
         (buffer nil)
         (state 'caller-scroll-state)
         seen-state)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*") node))
          (ebox--with-buffer-render-context buffer
            (setq seen-state state))
          (should (eq seen-state 'caller-scroll-state)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-deferred-render-gc-uses-interactive-burst-threshold ()
  "Interactive render bursts should stay bounded and collect when settled."
  (let ((gc-cons-threshold 1000)
        (gc-cons-percentage 0.1)
        (ebox-deferred-render-gc-cons-threshold 2000)
        (ebox-render-gc-cons-percentage 0.6)
        (ebox--deferred-render-gc-state nil)
        (ebox--deferred-render-gc-timer nil)
        (gc-count 0))
    (unwind-protect
        (cl-letf (((symbol-function 'garbage-collect)
                   (lambda () (cl-incf gc-count))))
          (ebox--deferred-render-gc-enter)
          (should (= gc-cons-threshold 2000))
          (should (= gc-cons-percentage 0.6))
          (ebox--deferred-render-gc-restore)
          (should (= gc-cons-threshold 1000))
          (should (= gc-cons-percentage 0.1))
          (should (= gc-count 1))
          (ebox--deferred-render-gc-restore)
          (should (= gc-count 1)))
      (when (timerp ebox--deferred-render-gc-timer)
        (cancel-timer ebox--deferred-render-gc-timer)))))

(ert-deftest ebox-deferred-render-gc-keeps-overlapping-burst-owned ()
  "A nested idle slice must not restore GC during an active animation."
  (let ((gc-cons-threshold 1000)
        (gc-cons-percentage 0.1)
        (ebox-deferred-render-gc-cons-threshold 4000)
        (ebox--deferred-render-gc-state nil)
        (ebox--deferred-render-gc-timer nil)
        (ebox--deferred-render-gc-depth 0)
        scheduled)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _)
                 (setq scheduled 'restore-timer)))
              ((symbol-function 'timerp)
               (lambda (value) (eq value 'restore-timer))))
      (ebox--deferred-render-gc-enter)
      (ebox--deferred-render-gc-enter)
      (should (= ebox--deferred-render-gc-depth 2))
      (ebox--deferred-render-gc-schedule-restore)
      (should (= ebox--deferred-render-gc-depth 1))
      (should-not scheduled)
      (should (= gc-cons-threshold 4000))
      (ebox--deferred-render-gc-schedule-restore)
      (should (eq scheduled 'restore-timer))
      (should (= ebox--deferred-render-gc-depth 0))
      (should (= gc-cons-threshold 4000)))))

(ert-deftest ebox-deferred-render-gc-default-is-memory-bounded ()
  "The interactive burst default should scale within finite memory bounds."
  (should (eq ebox-deferred-render-gc-cons-threshold 'auto))
  (let ((gc-cons-threshold (* 512 1024 1024))
        (gc-cons-percentage 0.1)
        (ebox--physical-memory-bytes (* 16 1024 1024 1024))
        (ebox--deferred-render-gc-state nil)
        (ebox--deferred-render-gc-timer nil))
    (unwind-protect
        (progn
          (ebox--deferred-render-gc-enter)
          (should (= gc-cons-threshold (* 512 1024 1024))))
      (ebox--deferred-render-gc-restore))))

(ert-deftest ebox-deferred-render-gc-can-raise-an-active-burst-budget ()
  "Measured layout pressure should only raise an active burst budget."
  (let ((gc-cons-threshold 1000)
        (ebox--deferred-render-gc-state nil))
    (ebox--deferred-render-gc-raise-threshold 4000)
    (should (= gc-cons-threshold 1000))
    (setq ebox--deferred-render-gc-state
          '(:gc-cons-threshold 1000 :gc-cons-percentage 0.1))
    (ebox--deferred-render-gc-raise-threshold 4000)
    (should (= gc-cons-threshold 4000))
    (ebox--deferred-render-gc-raise-threshold 2000)
    (should (= gc-cons-threshold 4000))
    (ebox--deferred-render-gc-raise-threshold nil)
    (should (= gc-cons-threshold 4000))))

(ert-deftest ebox-deferred-render-gc-can-bound-an-active-burst-budget ()
  "A specialized burst may lower its raised budget but not the saved setting."
  (let ((gc-cons-threshold 5000)
        (ebox--deferred-render-gc-state nil))
    (ebox--deferred-render-gc-set-threshold 3000)
    (should (= gc-cons-threshold 5000))
    (setq ebox--deferred-render-gc-state
          '(:gc-cons-threshold 1000 :gc-cons-percentage 0.1))
    (ebox--deferred-render-gc-set-threshold 3000)
    (should (= gc-cons-threshold 3000))
    (ebox--deferred-render-gc-set-threshold 500)
    (should (= gc-cons-threshold 1000))
    (ebox--deferred-render-gc-set-threshold nil)
    (should (= gc-cons-threshold 1000))))

(ert-deftest ebox-viewport-patch-planning-skips-line-signatures ()
  "Owner rerender planning should not compute expensive line signatures."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (apply
           #'ebox-column
           (cl-loop for section below 8
                    collect
                    (apply
                     #'ebox-flex
                     :flex-flow '(row wrap)
                     :row-gap 1
                     :column-gap '(8)
                     (cl-loop for index below 4
                              collect
                              (ebox-create
                               :content (format "S%d-%d" section index)
                               :width 80
                               :height 1))))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 360))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (let* ((root (ebox--buffer-root-node buffer))
                 (dirty (ebox--viewport-dirty-set root))
                 (line-signature-count 0)
                 (original (symbol-function 'ebox--spans-line-signature)))
            (should dirty)
            (cl-letf (((symbol-function 'ebox--spans-line-signature)
                       (lambda (&rest args)
                         (cl-incf line-signature-count)
                         (apply original args))))
              (ebox-incremental--declarative-tentative-patch-set
               buffer dirty))
            (should (= line-signature-count 0))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-patch-planning-coalesces-before-line-index ()
  "Broad viewport dirtiness should coalesce before building a line index."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (apply
           #'ebox-column
           (cl-loop for section below 8
                    collect
                    (apply
                     #'ebox-flex
                     :flex-flow '(row wrap)
                     :row-gap 1
                     :column-gap '(8)
                     (cl-loop for index below 4
                              collect
                              (ebox-create
                               :content (format "S%d-%d" section index)
                               :width 80
                               :height 1))))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 360))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (let* ((root (ebox--buffer-root-node buffer))
                 (dirty (ebox--viewport-dirty-set root))
                 (index-build-count 0)
                 (original (symbol-function 'ebox--build-region-line-index))
                 patches)
            (should dirty)
            (cl-letf (((symbol-function 'ebox--build-region-line-index)
                       (lambda (&rest args)
                         (cl-incf index-build-count)
                         (apply original args))))
              (setq patches
                    (ebox-incremental--declarative-tentative-patch-set
                     buffer dirty)))
            (should (= index-build-count 0))
            (should (= (length patches) 1))
            (should (eq (plist-get (car patches) :op) 'owner-rerender))
            (should (equal (plist-get (car patches) :owner-id)
                           (plist-get root :node-id)))
            (should (= (length
                        (ebox--dirty-provenance-node-ids
                         (plist-get (car patches) :dirty)))
                       (length dirty)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-block-padding-planning-promotes-without-full-line-index ()
  "Block padding should publish through its parent without rebuilding line indexes."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id "root" :width (480)
            (box :id "target" :content "mixed padding"
                 :width (220) :height 3 :box-sizing border-box
                 :padding (0 (8)) :border "#999999")
            (box :content "peer" :width (220) :height 3
                 :border "#999999"))))
        (index-build-count 0))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#target"))
            (root-id (ebox--buffer-root-node-id (current-buffer)))
            (original (symbol-function 'ebox--build-region-line-index)))
        (cl-letf (((symbol-function 'ebox--build-region-line-index)
                   (lambda (&rest args)
                     (cl-incf index-build-count)
                     (apply original args))))
          (ebox-test--region-update region-id :padding (list 1 '(18) 1 '(18))))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (equal (plist-get report :owner-ids) (list root-id)))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))
          (should (= index-build-count 0))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))










(ert-deftest ebox-region-role-ranges-come-from-tp-mounts ()
  "Published role ranges should be numeric snapshots of TP-owned mounts."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id "root" :width (480)
            (box :id "target" :content "target" :width (220)
                 :height 1 :border "#999999")
            (box :id "peer" :content "peer" :width (220)
                 :height 1 :border "#999999")))))
    (ebox-test--with-rendered-buffer layout
      (let* ((target-id (ebox-test--selector-region-id (current-buffer)
                                                       "#target"))
             (peer-id (ebox-test--selector-region-id (current-buffer)
                                                     "#peer"))
             (target-mounts
              (ebox-surface-region-mounts
               (current-buffer) target-id '(content)))
             (peer-mounts
              (ebox-surface-region-mounts
               (current-buffer) peer-id '(content))))
        (dolist (mount (append target-mounts peer-mounts))
          (should (integerp (plist-get mount :start)))
          (should (integerp (plist-get mount :end)))
          (should-not (markerp (plist-get mount :start)))
          (should-not (markerp (plist-get mount :end))))
        (should target-mounts)
        (should peer-mounts)
        (should (ebox-surface-region-bounds
                 (current-buffer) target-id '(content)))))))




(ert-deftest ebox-viewport-root-owner-spans-skip-region-scan ()
  "Root owner spans should use full buffer lines, not region-property scans."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (apply
           #'ebox-row
           (cl-loop for section below 8
                    collect
                    (apply
                     #'ebox-flex
                     :flex-flow '(row wrap)
                     :row-gap 1
                     :column-gap '(8)
                     (cl-loop for index below 4
                              collect
                              (ebox-create
                               :content (format "S%d-%d" section index)
                               :width 80
                               :height 1))))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 360))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (let* ((root (ebox--buffer-root-node buffer))
                 (dirty (ebox--viewport-dirty-set root))
                 (region-scan-count 0)
                 (original (symbol-function 'ebox--region-set-line-spans)))
            (should dirty)
            (cl-letf (((symbol-function 'ebox--region-set-line-spans)
                       (lambda (&rest args)
                         (cl-incf region-scan-count)
                         (apply original args))))
              (ebox-incremental--declarative-tentative-patch-set
               buffer dirty))
            (should (= region-scan-count 0))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-rerender-reuses-static-flex-item-renders ()
  "Static flex item renders should be reused across viewport rerenders."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (apply
           #'ebox-flex
           :flex-wrap 'wrap
           (cl-loop for index below 12
                    collect
                    (ebox-create
                     :content (format "Item %02d" index)
                     :width 80
                     :height 1))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 420))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (ebox-rerender-buffer-with-context buffer 360)
          (let ((box-render-count 0)
                (original (symbol-function 'ebox--render-box)))
            (cl-letf (((symbol-function 'ebox--render-box)
                       (lambda (&rest args)
                         (cl-incf box-render-count)
                         (apply original args))))
              (ebox-rerender-buffer-with-context buffer 500))
            (should (<= box-render-count 3))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-rerender-reuses-sized-flex-item-renders ()
  "Flex item renders with stable computed sizes should be reused."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (apply
           #'ebox-flex
           :flex-wrap 'wrap
           :height 4
           :align-items 'stretch
           (cl-loop for index below 10
                    collect
                    (ebox-create
                     :content (format "Stretch %02d" index)
                     :width 80))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 420))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (ebox-rerender-buffer-with-context buffer 360)
          (let ((box-render-count 0)
                (original (symbol-function 'ebox--render-box)))
            (cl-letf (((symbol-function 'ebox--render-box)
                       (lambda (&rest args)
                         (cl-incf box-render-count)
                         (apply original args))))
              (ebox-rerender-buffer-with-context buffer 500))
            (should (<= box-render-count 6))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-rerender-reuses-flex-item-measurements ()
  "Stable flex item intrinsic measurements should be reused across resizes."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (apply
           #'ebox-flex
           :flex-wrap 'wrap
           (cl-loop for index below 12
                    collect
                    (ebox-create
                     :content (format "Measured %02d" index)
                     :width 80
                     :height 1))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 420))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (ebox-rerender-buffer-with-context buffer 360)
          (let ((main-count 0)
                (min-count 0)
                (original-main (symbol-function 'ebox--flex-string-main))
                (original-min (symbol-function 'ebox--content-min-pixel)))
            (cl-letf (((symbol-function 'ebox--flex-string-main)
                       (lambda (&rest args)
                         (cl-incf main-count)
                         (apply original-main args)))
                      ((symbol-function 'ebox--content-min-pixel)
                       (lambda (&rest args)
                         (cl-incf min-count)
                         (apply original-min args))))
              (ebox-rerender-buffer-with-context buffer 500))
            (should (<= main-count 3))
            (should (<= min-count 3))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-rerender-reuses-static-composite-subtrees ()
  "Viewport-dependent flex sections should reuse static composite item sources."
  (ebox-test--reset-runtime-state)
  (let* ((inner-flexes
          (cl-loop for index below 6
                   collect
                   (ebox-flex
                    :width 180 :height 3
                    :flex-flow '(row wrap)
                    :column-gap '(8)
                    (ebox-create
                     :content (format "A%d" index)
                     :width 48 :height 1)
                    (ebox-create
                     :content (format "B%d" index)
                     :width 48 :height 1))))
         (layout
          (apply
           #'ebox-flex
           :flex-flow '(row wrap)
           :row-gap 1
           :column-gap '(8)
           (mapcar (lambda (inner)
                     (ebox-column
                      (ebox-create :content "Static card"
                                   :width 180
                                   :height 1)
                      inner))
                   inner-flexes)))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 320))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (ebox-rerender-buffer-with-context buffer 360)
          (let ((static-flex-renders 0)
                (original (symbol-function 'ebox--render-flex)))
            (cl-letf (((symbol-function 'ebox--render-flex)
                       (lambda (node)
                         (when (memq node inner-flexes)
                           (cl-incf static-flex-renders))
                         (funcall original node))))
              (ebox-rerender-buffer-with-context buffer 420))
            (should (= static-flex-renders 0))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-window-reuses-cached-composite-measurements ()
  "Flex prefix layout should reuse warm measurements for fixed composites."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (apply
           #'ebox-flex
           :flex-flow '(row wrap)
           :column-gap '(8)
           (cl-loop for index below 6
                    collect
                    (ebox-column
                     (ebox-create :content (format "Card %d" index)
                                  :width 96 :height 1)
                     (ebox-create :content "Body" :width 96 :height 2)))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 320))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*") layout)))
          (let* ((root (ebox--buffer-root-node buffer))
                 (child (car (plist-get root :children))))
            (ebox--with-buffer-render-context buffer
              (should (ebox--flex-window-cheap-item child 'row 0)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-render-cacheability-uses-boolean-viewport-dependency-cache ()
  "Render cacheability should not enumerate viewport-dependent node ids."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-column
           (ebox-create :content "Static" :width 120)
           (ebox-create :content "Also static" :width 120)))
         (calls 0)
         (original (symbol-function 'ebox--viewport-dependent-node-ids)))
    (let ((ebox--render-cache-table (make-hash-table :test 'equal))
          (ebox--viewport-dependent-subtree-cache
           (make-hash-table :test 'eq)))
      (cl-letf (((symbol-function 'ebox--viewport-dependent-node-ids)
                 (lambda (&rest args)
                   (cl-incf calls)
                   (apply original args))))
        (should (ebox--render-cacheable-node-p layout))
        (should (ebox--render-cacheable-node-p layout)))
      (should (= calls 0)))))

(ert-deftest ebox-render-cacheability-rejects-viewport-dependent-wrapper-child ()
  "Wrapper boxes with viewport-dependent child layout should not reuse static render cache."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :padding 1
                  (box :content "Auto child follows viewport"
                       :wrap-mode word)))))
    (let ((ebox--render-cache-table (make-hash-table :test 'equal))
          (ebox--viewport-dependent-subtree-cache
           (make-hash-table :test 'eq)))
      (should-not (ebox--render-cacheable-node-p node)))))

(ert-deftest ebox-render-cacheability-allows-definite-width-wrapper-child ()
  "Definite-width boxes bound descendant viewport-dependent layout."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :width (210) :padding 1
                  (box :content "Child wraps inside the card"
                       :wrap-mode word)))))
    (let ((ebox--render-cache-table (make-hash-table :test 'equal))
          (ebox--viewport-dependent-subtree-cache
           (make-hash-table :test 'eq)))
      (should (ebox--viewport-dependent-subtree-p node))
      (should (ebox--render-cacheable-node-p node)))))

(ert-deftest ebox-region-width-update-invalidates-viewport-dependencies ()
  "Width updates can change which boxes participate in viewport resize."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Resizable" :width 80))
         (box-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-rerender-buffer-with-context (current-buffer) 260)
      (ebox-test--region-update box-id :width '(viewport))
      (ebox-rerender-buffer-with-context (current-buffer) 200)
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :constraint-source) 'viewport))
        (should (= (plist-get report :dirty-count) 1))))))

(ert-deftest ebox-viewport-dependencies-include-wrapper-child-layout ()
  "Viewport dependency discovery should see lazy child layout under wrapper boxes."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :padding 1
                  (box :content "Auto child follows the preview width"
                       :wrap-mode word))))
         (child (car (ebox--node-children node)))
         (ids (let ((ebox-viewport-width 360))
                (ebox--runtime-node-ids node)
                (ebox--viewport-dependent-node-ids node))))
    (should ids)
    (should (member (plist-get node :node-id) ids))
    (should (member (plist-get child :node-id) ids))))

(ert-deftest ebox-viewport-dependencies-stop-at-definite-width-wrapper ()
  "Definite wrappers should contain descendant viewport dependencies."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-build
                '(column :width (210) :padding 1
                  (box :content "Auto child wraps inside the fixed card"
                       :wrap-mode word))))
         (child (car (ebox--node-children node)))
         (ids (let ((ebox-viewport-width 360))
                (ebox--runtime-node-ids node)
                (ebox--viewport-dependent-node-ids node))))
    (should-not (member (plist-get node :node-id) ids))
    (should-not (member (plist-get child :node-id) ids))))

(ert-deftest ebox-viewport-height-dependency-crosses-definite-width-wrapper ()
  "Definite width should not contain a descendant viewport-height dependency."
  (ebox-test--reset-runtime-state)
  (let* ((viewport-width 120)
         (node (let ((ebox-viewport-width viewport-width)
                     (ebox-viewport-height 2))
                 (ebox-build
                  '(column :width (120)
                    (box :id child
                     :content "One\nTwo\nThree\nFour"
                     :height (viewport-height)
                     :overflow scroll)))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width viewport-width)
                (ebox-viewport-height 2))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   node)))
          (with-current-buffer buffer
            (should (= (length (ebox-string-lines
                                (buffer-substring-no-properties
                                 (point-min) (point-max))))
                       2)))
          (let ((report
                 (ebox-rerender-buffer-with-context
                  buffer viewport-width 4)))
            (should-not (eq (plist-get report :strategy) 'no-op)))
          (with-current-buffer buffer
            (should (= (length (ebox-string-lines
                                (buffer-substring-no-properties
                                 (point-min) (point-max))))
                       4))
            (should (ebox-test--buffer-visually-matches-runtime-render-p))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-dependency-axes-classify-both-dimensions ()
  "A node may depend on width, height, or both viewport axes."
  (ebox-test--reset-runtime-state)
  (let* ((width-only (ebox-create :content "Width" :width '(viewport)))
         (height-only (ebox-create :content "Height"
                                   :width '(120)
                                   :height '(viewport-height)))
         (both (ebox-create :content "Both"
                            :width '(viewport)
                            :height '(viewport-height)))
         (layout (ebox-column width-only height-only both)))
    (let ((ebox-viewport-width 360)
          (ebox-viewport-height 12)
          (ebox--viewport-dependent-node-ids-cache
           (make-hash-table :test 'eq))
          (ebox--viewport-height-dependent-subtree-cache
           (make-hash-table :test 'eq)))
      (ebox--runtime-node-ids layout)
      (pcase-let ((`(,width-ids . ,height-ids)
                   (ebox--viewport-dependent-node-id-axes layout)))
        (should (member (plist-get width-only :node-id) width-ids))
        (should-not (member (plist-get width-only :node-id) height-ids))
        (should-not (member (plist-get height-only :node-id) width-ids))
        (should (member (plist-get height-only :node-id) height-ids))
        (should (member (plist-get both :node-id) width-ids))
        (should (member (plist-get both :node-id) height-ids))))))

(ert-deftest ebox-viewport-width-rerender-skips-height-only-root ()
  "Width-only viewport rerender should not dirty height-only roots."
  (ebox-test--reset-runtime-state)
  (let* ((node (let ((ebox-viewport-height 4))
                 (ebox-build
                  '(column :width (120) :height (viewport-height)
                    (box :content "Static" :width (120))))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 240)
                (ebox-viewport-height 4))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   node)))
          (let ((report (ebox-rerender-buffer-with-context buffer 300)))
            (should (eq (plist-get report :strategy) 'no-op))
            (should (= (plist-get report :dirty-count) 0))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-dependencies-keep-only-vertical-axis-under-fixed-width ()
  "Fixed width should retain vertical dependencies without exposing width-only ones."
  (ebox-test--reset-runtime-state)
  (let* ((width-only
          (ebox-create :content "Width" :width '(viewport)))
         (ordinary-height-nodes
          (cl-loop for (property value)
                   in '((:height (viewport-height))
                        (:min-height (- (viewport-height) 1))
                        (:max-height (+ (viewport-height) 1)))
                   collect
                   (apply #'ebox-create
                          :content "Ordinary"
                          (list property value))))
         (flex-height-nodes
          (cl-loop for (property value)
                   in '((:height (viewport-height))
                        (:min-height (- (viewport-height) 1))
                        (:max-height (+ (viewport-height) 1)))
                   collect
                   (apply #'ebox-flex
                          (append
                           (list property value)
                           (list (ebox-create :content "Flex"))))))
         (layout
          (apply #'ebox-column
                 (append (list width-only)
                         ordinary-height-nodes
                         flex-height-nodes)))
         (node (ebox-create :width '(210)
                            :wrap-mode nil
                            :ebox-content-node layout))
         (ids (let ((ebox-viewport-width 360)
                    (ebox-viewport-height 12))
                (ebox--runtime-node-ids node)
                (ebox--viewport-dependent-node-ids node))))
    (should-not (member (plist-get width-only :node-id) ids))
    (dolist (vertical-node (append ordinary-height-nodes flex-height-nodes))
      (should (member (plist-get vertical-node :node-id) ids)))))

(ert-deftest ebox-viewport-dependencies-include-direct-flex-basis ()
  "Viewport dependency discovery should include direct child flex-basis props."
  (ebox-test--reset-runtime-state)
  (let* ((child (ebox-create :content "A" :width 80
                             :flex-basis '(viewport)))
         (node (ebox-flex :width 300
                 child
                 (ebox-create :content "B" :width 80)))
         (ids (let ((ebox-viewport-width 360))
                (ebox--runtime-node-ids node)
                (ebox--viewport-dependent-node-ids node))))
    (should (member (plist-get child :node-id) ids))))

(ert-deftest ebox-viewport-dependencies-ignore-flex-item-wrapper-auto-width ()
  "Flex item wrappers should not be dirty only because their own width is auto."
  (ebox-test--reset-runtime-state)
  (let* ((child (ebox-create :content "A" :width 80))
         (item (ebox-flex-item child))
         (node (ebox-flex :width 240 item))
         (ids (let ((ebox-viewport-width 360))
                (ebox--runtime-node-ids node)
                (ebox--viewport-dependent-node-ids node))))
    (should-not (member (plist-get item :node-id) ids))
    (should-not (member (plist-get child :node-id) ids))))

(ert-deftest ebox-viewport-dependencies-include-flex-item-viewport-basis ()
  "Flex item wrappers should stay dirty when their flex-basis uses viewport."
  (ebox-test--reset-runtime-state)
  (let* ((child (ebox-create :content "A" :width 80))
         (item (ebox-flex-item child :flex-basis '(viewport)))
         (node (ebox-flex :width 240 item))
         (ids (let ((ebox-viewport-width 360))
                (ebox--runtime-node-ids node)
                (ebox--viewport-dependent-node-ids node))))
    (should (member (plist-get item :node-id) ids))))

(ert-deftest ebox-buffer-viewport-dependency-cache-recomputes-after-style-change ()
  "Changing responsive style should publish its exact viewport dependency."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Resizable" :width 80))
         (box-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-rerender-buffer-with-context (current-buffer) 320)
      (ebox-test--region-update box-id :width '(viewport))
      (let* ((state (ebox--buffer-render-state (current-buffer)))
             (axes (plist-get state :viewport-dependent-node-id-axes))
             (owner-id
              (ebox--buffer-region-render-owner-node-id
               (current-buffer) box-id)))
        (should (plist-get state :viewport-dependent-node-ids-ready))
        (should (member owner-id (car axes))))
      (ebox-rerender-buffer-with-context (current-buffer) 240)
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :constraint-source) 'viewport))
        (should (= (plist-get report :dirty-count) 1))))))

(ert-deftest ebox-initial-render-primes-static-composite-subtree-cache ()
  "The first viewport resize should reuse cache populated by initial render."
  (ebox-test--reset-runtime-state)
  (let* ((inner-flexes
          (cl-loop for index below 6
                   collect
                   (ebox-flex
                    :width 180 :height 3
                    :flex-flow '(row wrap)
                    :column-gap '(8)
                    (ebox-create
                     :content (format "A%d" index)
                     :width 48 :height 1)
                    (ebox-create
                     :content (format "B%d" index)
                     :width 48 :height 1))))
         (layout
          (apply
           #'ebox-flex
           :flex-flow '(row wrap)
           :row-gap 1
           :column-gap '(8)
           (mapcar (lambda (inner)
                     (ebox-column
                      (ebox-create :content "Static card"
                                   :width 180
                                   :height 1)
                      inner))
                   inner-flexes)))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 320))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (let ((static-flex-renders 0)
                (original (symbol-function 'ebox--render-flex)))
            (cl-letf (((symbol-function 'ebox--render-flex)
                       (lambda (node)
                         (when (memq node inner-flexes)
                           (cl-incf static-flex-renders))
                         (funcall original node))))
              (ebox-rerender-buffer-with-context buffer 420))
            (should (= static-flex-renders 0))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-resize-invalidates-snapshot-details-lazily ()
  "Viewport resize should not recapture every lightweight snapshot eagerly."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(column :width (viewport)
             ,@(cl-loop for idx below 24
                        collect
                        `(box :id ,(format "resize-snapshot-%02d" idx)
                              :content ,(format "row %02d" idx)
                              :width (viewport)
                              :height 1)))))
         (node-count (length (ebox--runtime-node-ids layout)))
         buffer
         (snapshot-count 0)
         (original (symbol-function 'ebox--node-layout-snapshot)))
    (unwind-protect
        (let ((ebox-viewport-width 240))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (cl-letf (((symbol-function 'ebox--node-layout-snapshot)
                     (lambda (&rest args)
                       (cl-incf snapshot-count)
                       (apply original args))))
            (ebox-rerender-buffer-with-context buffer 320))
          (should (< snapshot-count node-count)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-resize-preserves-tp-mount-index ()
  "Viewport resize should republish region ranges through TP mounts."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(column :width (viewport)
             ,@(cl-loop for idx below 24
                        collect
                        `(box :id ,(format "resize-mount-%02d" idx)
                              :content ,(format "row %02d" idx)
                              :width (viewport)
                              :height 1)))))
         buffer
         target-id)
    (unwind-protect
        (let ((ebox-viewport-width 240))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq target-id
                (ebox-test--selector-region-id
                 buffer "#resize-mount-12"))
          (ebox-rerender-buffer-with-context buffer 320)
          (with-current-buffer buffer
            (should (ebox-surface-region-mounts buffer target-id))
            (ebox-test--region-update target-id :content "updated after resize")
            (should (ebox-surface-region-mounts buffer target-id))
            (should (string-match-p "updated after resize"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-dependent-node-ids-are-render-pass-memoized ()
  "Viewport dependency discovery should not recurse twice for the same node."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-flex
           :width 240
           (ebox-column
            (ebox-create :content "A" :width 80)
            (ebox-create :content "B" :width 80))))
         (node-count (length (ebox--runtime-node-ids layout)))
         (width-check-count 0)
         (height-check-count 0)
         (original-width
          (symbol-function 'ebox--node-direct-viewport-width-dependent-p))
         (original-height
          (symbol-function 'ebox--node-direct-viewport-height-dependent-p))
         (ebox--viewport-dependent-node-ids-cache
          (make-hash-table :test 'eq)))
    (cl-letf (((symbol-function
                'ebox--node-direct-viewport-width-dependent-p)
               (lambda (&rest args)
                 (cl-incf width-check-count)
                 (apply original-width args)))
              ((symbol-function
                'ebox--node-direct-viewport-height-dependent-p)
               (lambda (&rest args)
                 (cl-incf height-check-count)
                 (apply original-height args))))
      (ebox--viewport-dependent-node-ids layout)
      (ebox--viewport-dependent-node-ids layout))
    (should (= width-check-count node-count))
    (should (= height-check-count node-count))))

(ert-deftest ebox-render-cache-node-signature-is-render-pass-memoized ()
  "Render cache signatures should not recurse twice for the same node."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-flex
           :width 240
           (ebox-column
            (ebox-create :content "A" :width 80)
            (ebox-create :content "B" :width 80))))
         (node-count (length (ebox--runtime-node-ids layout)))
         (signature-count 0)
         (original (symbol-function 'ebox--render-cache-plist-signature))
         (ebox--render-cache-signature-cache
          (make-hash-table :test 'eq)))
    (cl-letf (((symbol-function 'ebox--render-cache-plist-signature)
               (lambda (&rest args)
                 (cl-incf signature-count)
                 (apply original args))))
      (ebox--render-cache-node-signature layout)
      (ebox--render-cache-node-signature layout))
    (should (= signature-count node-count))))

(ert-deftest ebox-render-cache-value-signature-preserves-dotted-pairs ()
  "Native values such as sparse keymaps may contain dotted pairs."
  (let ((value '(keymap (mouse-1 . ebox-test-activate)
                        (13 . ebox-test-activate))))
    (should
     (equal (ebox--render-cache-value-signature value)
            value))))

(ert-deftest ebox-render-cache-signature-includes-rendered-region-identity ()
  "Cached render strings should never cross distinct region identities."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "Stable" :width 80))
         (right (copy-tree left)))
    (plist-put left :node-id 1)
    (plist-put right :node-id 1)
    (plist-put left :region-id 11)
    (plist-put right :region-id 12)
    (should-not
     (equal (ebox--render-cache-node-signature left)
            (ebox--render-cache-node-signature right)))))

(ert-deftest ebox-render-transaction-snapshots-display-signature ()
  "One render transaction should sample its display signature once."
  (ebox-test--reset-runtime-state)
  (let ((node (ebox-create :content "A" :width 80))
        (calls 0))
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda ()
                 (list 'display (cl-incf calls)))))
      (ebox--with-validated-display-cache
        (ebox--render-cache-node-signature node)
        (ebox--render-cache-node-signature node)))
    (should (= calls 1))))

(ert-deftest ebox-render-transaction-nesting-reuses-display-signature ()
  "A nested render transaction should reuse the outer display snapshot."
  (ebox-test--reset-runtime-state)
  (let ((node (ebox-create :content "A" :width 80))
        (calls 0))
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda ()
                 (list 'display (cl-incf calls)))))
      (ebox--with-validated-display-cache
        (ebox--with-validated-display-cache
          (ebox--render-cache-node-signature node))))
    (should (= calls 1))))

(ert-deftest ebox-render-transactions-refresh-display-signature ()
  "Separate render transactions should sample display state independently."
  (ebox-test--reset-runtime-state)
  (let ((node (ebox-create :content "A" :width 80))
        (calls 0)
        signatures)
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda ()
                 (list 'display (cl-incf calls)))))
      (dotimes (_ 2)
        (push
         (ebox--with-validated-display-cache
           (car (ebox--render-cache-node-signature node)))
         signatures)))
    (should (= calls 2))
    (should-not (equal (car signatures) (cadr signatures)))))

(ert-deftest ebox-current-display-signature-is-live-outside-transaction ()
  "The internal accessor should sample live state outside a transaction."
  (ebox-test--reset-runtime-state)
  (let ((calls 0)
        signatures)
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda ()
                 (list 'display (cl-incf calls)))))
      (setq signatures
            (list (ebox--current-display-signature)
                  (ebox--current-display-signature))))
    (should (= calls 2))
    (should-not (equal (car signatures) (cadr signatures)))))

(ert-deftest ebox-public-display-signature-stays-live-in-render-transaction ()
  "The public display signature should bypass a render transaction snapshot."
  (ebox-test--reset-runtime-state)
  (let ((calls 0)
        signatures)
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda ()
                 (list 'display (cl-incf calls)))))
      (setq signatures
            (ebox--with-validated-display-cache
              (list (ebox-display-signature)
                    (ebox-display-signature)))))
    (should (= calls 3))
    (should-not (equal (car signatures) (cadr signatures)))))

(ert-deftest ebox-clear-cache-samples-live-display-in-render-transaction ()
  "Clearing caches should store live display state inside a transaction."
  (ebox-test--reset-runtime-state)
  (let ((calls 0))
    (puthash '(stale) 1 ebox--string-pixel-width-cache)
    (aset ebox--string-pixel-width-cache-ring 0 '(stale))
    (setq ebox--string-pixel-width-cache-ring-index 1)
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda ()
                 (list 'display (cl-incf calls)))))
      (ebox--with-validated-display-cache
        (ebox-clear-cache)))
    (should (= calls 2))
    (should (= (hash-table-count ebox--string-pixel-width-cache) 0))
    (should (= ebox--string-pixel-width-cache-ring-index 0))
    (should (equal ebox--display-signature-cache '(display 2)))))

(ert-deftest ebox-render-cache-signature-keeps-viewport-axes-with-snapshot ()
  "Display snapshots should not collapse width or height cache dimensions."
  (ebox-test--reset-runtime-state)
  (let ((node (ebox-create :content "A"
                           :width '(viewport)
                           :height '(viewport-height)))
        signatures)
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda () '(display stable))))
      (ebox--with-validated-display-cache
        (dolist (viewport '((80 10) (90 10) (90 11)))
          (let ((ebox-viewport-width (car viewport))
                (ebox-viewport-height (cadr viewport)))
            (push (ebox--render-cache-node-signature node)
                  signatures)))))
    (setq signatures (nreverse signatures))
    (should (equal (mapcar #'car signatures)
                   '((display stable) (display stable) (display stable))))
    (should-not (equal (nth 0 signatures) (nth 1 signatures)))
    (should-not (equal (nth 1 signatures) (nth 2 signatures)))))

(ert-deftest ebox-render-cache-signature-ignores-unrelated-viewport-height ()
  "Width-only subtree signatures should survive unrelated height changes."
  (ebox-test--reset-runtime-state)
  (let* ((node (ebox-column
                (ebox-create :content "A" :width '(viewport))
                (ebox-create :content "B" :width 80)))
         (left (let ((ebox-viewport-width 320)
                     (ebox-viewport-height 10))
                 (ebox--render-cache-node-signature node)))
         (right (let ((ebox-viewport-width 320)
                      (ebox-viewport-height 11))
                  (ebox--render-cache-node-signature node))))
    (should (equal left right))))

(ert-deftest ebox-buffer-render-signatures-persist-across-transactions ()
  "Unchanged runtime body signatures should survive buffer render transactions."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-flex
           :width 240
           (ebox-column
            (ebox-create :content "A" :width 80)
            (ebox-create :content "B" :width 80))))
         (node-count (length (ebox--runtime-node-ids layout)))
         (signature-count 0)
         (original (symbol-function 'ebox--render-cache-plist-signature))
         buffer)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (when-let ((cache
                      (plist-get (ebox--buffer-render-state buffer)
                                 :render-signature-cache)))
            (clrhash cache))
          (cl-letf (((symbol-function 'ebox--render-cache-plist-signature)
                     (lambda (&rest args)
                       (cl-incf signature-count)
                       (apply original args))))
            (ebox--with-buffer-render-context buffer
              (ebox--render-cache-node-body-signature layout))
            (ebox--with-buffer-render-context buffer
              (ebox--render-cache-node-body-signature layout)))
          (should (= signature-count node-count)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-buffer-render-signature-invalidates-mutated-path ()
  "Runtime mutation should not reuse a stale ancestor body signature."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "Before" :width 80))
         (right (ebox-create :content "Stable" :width 80))
         (layout (ebox-column left right))
         (left-region-id (car (ebox-region-ids left)))
         old-root-signature
         new-root-signature
         buffer)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (let ((runtime-root (ebox--buffer-root-node buffer)))
            (setq old-root-signature
                  (ebox--with-buffer-render-context buffer
                    (ebox--render-cache-node-body-signature runtime-root))))
          (with-current-buffer buffer
            (ebox-test--region-update left-region-id :content "After")
            (should (equal (ebox-get left :content) "Before"))
            (setq new-root-signature
                  (ebox--with-buffer-render-context buffer
                    (ebox--render-cache-node-body-signature
                     (ebox--buffer-root-node buffer))))
            (should-not (equal old-root-signature new-root-signature))
            (should
             (string-match-p
              "After"
              (buffer-substring-no-properties (point-min) (point-max))))
            (should (ebox-test--buffer-visually-matches-runtime-render-p))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-render-cache-signature-ignores-viewport-for-static-column ()
  "Static column signatures should not churn only because outer viewport changed."
  (ebox-test--reset-runtime-state)
  (let ((node (ebox-column
               (ebox-create :content "A" :width 80)
               (ebox-create :content "B" :width 80))))
    (ebox--runtime-node-ids node)
    (let ((left (let ((ebox-viewport-width 320))
                  (ebox--render-cache-node-signature node)))
          (right (let ((ebox-viewport-width 640))
                   (ebox--render-cache-node-signature node))))
      (should (equal left right)))))

(ert-deftest ebox-render-cache-plist-signature-avoids-append-churn ()
  "Render cache plist signatures should be built linearly."
  (ebox-test--reset-runtime-state)
  (let ((node (ebox-create :content "Signature" :width 80 :border t))
        (original-append (symbol-function 'append))
        (append-calls 0))
    (cl-letf (((symbol-function 'append)
               (lambda (&rest args)
                 (cl-incf append-calls)
                 (apply original-append args))))
      (ebox--render-cache-plist-signature node))
    (should (= append-calls 0))))

(ert-deftest ebox-preformatted-exact-content-skips-justify-measurement ()
  "Exact-width preformatted content should not be remeasured for left justify."
  (ebox-test--reset-runtime-state)
  (let* ((content (ebox-lines-join
                   (list (ebox-pixel-space 80)
                         (ebox-pixel-space 80))))
         (box (ebox-create :content content :width 80 :wrap-mode nil))
         (measure-count 0)
         (original (symbol-function 'ebox--string-pixel-width)))
    (plist-put box :ebox-content-width-exact-p t)
    (cl-letf (((symbol-function 'ebox--string-pixel-width)
               (lambda (&rest args)
                 (cl-incf measure-count)
                 (apply original args))))
      (ebox--format-content box))
    (should (= measure-count 0))))

(ert-deftest ebox-uniform-stack-content-skips-parent-justify-measurement ()
  "A target-width stack should not be measured again by its parent box."
  (ebox-test--reset-runtime-state)
  (let* ((child (ebox-column
                 (ebox-create :content "A" :width '(viewport))
                 (ebox-create :content "B" :width '(viewport))))
         (parent (ebox-create :width '(viewport) :wrap-mode nil
                              :ebox-content-node child))
         (justify-count 0)
         (original (symbol-function 'ebox--lines-justify)))
    (let ((ebox-viewport-width 120))
      (cl-letf (((symbol-function 'ebox--lines-justify)
                 (lambda (&rest args)
                   (cl-incf justify-count)
                   (apply original args))))
        (ebox-render parent)))
    ;; The two leaf boxes still justify their own text.  The parent does not
    ;; add a third full-stack pass.
    (should (= justify-count 2))))

(ert-deftest ebox-uniform-content-skips-noop-word-and-char-formatting ()
  "Exact uniform lines should bypass proven no-op word/char formatting."
  (ebox-test--reset-runtime-state)
  (dolist (wrap-mode '(word char))
    (let* ((box (ebox-create :content "" :width '(120)
                             :wrap-mode wrap-mode :text-align 'left))
           (pixel-width (ebox--content-pixel box))
           (line (propertize (ebox-pixel-space pixel-width)
                             'face '(:foreground "#123456")))
           (content (concat line "\n" line))
           (wrap-count 0)
           (justify-count 0)
           (original-wrap (symbol-function 'ebox--wrap-text))
           (original-justify (symbol-function 'ebox--lines-justify)))
      (ebox--record-rendered-uniform-width content pixel-width)
      (cl-letf (((symbol-function 'ebox--wrap-text)
                 (lambda (&rest arguments)
                   (cl-incf wrap-count)
                   (apply original-wrap arguments)))
                ((symbol-function 'ebox--lines-justify)
                 (lambda (&rest arguments)
                   (cl-incf justify-count)
                   (apply original-justify arguments))))
        (should (eq (ebox--format-content-string box content) content)))
      (should (= wrap-count 0))
      (should (= justify-count 0)))))

(ert-deftest ebox-uniform-content-keeps-semantic-formatting-paths ()
  "KP, non-left alignment and width mismatch must retain formatting."
  (ebox-test--reset-runtime-state)
  (dolist (case '((kp left 120)
                  (word center 120)
                  (char left 119)))
    (let* ((box (ebox-create :content "" :width '(120)
                             :wrap-mode (nth 0 case)
                             :text-align (nth 1 case)))
           (content (ebox-pixel-space 120))
           (wrap-count 0)
           (original-wrap (symbol-function 'ebox--wrap-text)))
      (ebox--record-rendered-uniform-width content (nth 2 case))
      (cl-letf (((symbol-function 'ebox--wrap-text)
                 (lambda (&rest arguments)
                   (cl-incf wrap-count)
                   (apply original-wrap arguments))))
        (ebox--format-content-string box content))
      (should (> wrap-count 0)))))

(ert-deftest ebox-transparent-preformatted-box-fast-path-is-exact ()
  "Transparent exact-width wrappers should match the generic box pipeline."
  (ebox-test--reset-runtime-state)
  (let* ((child-a (ebox-create :content "A" :width '(viewport) :border t
                               :region-id 'child-a))
         (child-b (ebox-create :content "B" :width '(viewport) :border t
                               :region-id 'child-b))
         (parent (ebox-create :width '(viewport) :wrap-mode nil
                              :region-id 'parent
                              :ebox-content-node
                              (ebox-column child-a child-b)))
         generic fast)
    (let ((ebox-viewport-width 120)
          (ebox--transparent-preformatted-box-fast-path-disabled t))
      (setq generic (ebox-render parent)))
    (clrhash ebox--rendered-uniform-width-table)
    (let ((ebox-viewport-width 120))
      (setq fast (ebox-render parent)))
    (should (equal-including-properties fast generic))))

(ert-deftest ebox-flat-preformatted-box-fast-path-is-exact ()
  "One-pass exact wrappers should preserve generic chrome and ownership."
  (ebox-test--reset-runtime-state)
  (let* ((box
          (ebox-create
           :content "" :width '(140) :wrap-mode nil :region-id 'wrapper
           :padding-left-pixel 7 :padding-right-pixel 5
           :padding-top-height 1 :padding-bottom-height 2
           :border-left-pixel 2 :border-left-color "#AA0000"
           :border-right-pixel 3 :border-right-color "#00AA00"
           :border-top-p t :border-top-color "#0000AA"
           :border-bottom-p t :border-bottom-color "#AA00AA"
           :color "#111111" :bgcolor "#EEEEEE"))
         (content-width (ebox--content-pixel box))
         (full-line (ebox-pixel-space content-width))
         (content (concat full-line "\n\n" full-line))
         (fast-path-calls 0)
         (original
          (symbol-function 'ebox--window-render-flat-wrapper-chunk-lines))
         generic fast)
    (plist-put box :content content)
    (plist-put box :ebox-content-width-exact-p t)
    (let ((ebox--flat-preformatted-box-fast-path-disabled t))
      (setq generic (ebox-render box)))
    (clrhash ebox--region-box-table)
    (clrhash ebox--scroll-global-state)
    (cl-letf (((symbol-function 'ebox--window-render-flat-wrapper-chunk-lines)
               (lambda (&rest args)
                 (cl-incf fast-path-calls)
                 (apply original args))))
      (setq fast (ebox-render box)))
    (should (= fast-path-calls 1))
    (should (equal-including-properties fast generic))))

(ert-deftest ebox-flat-preformatted-fixed-hidden-box-fast-path-is-exact ()
  "Exact fixed-height hidden wrappers should preserve generic output."
  (ebox-test--reset-runtime-state)
  (let* ((box
          (ebox-create
           :content "" :width '(140) :height 6 :box-sizing 'border-box
           :overflow 'hidden :wrap-mode nil :region-id 'fixed-wrapper
           :padding-left-pixel 7 :padding-right-pixel 5
           :padding-top-height 1 :padding-bottom-height 2
           :border-left-pixel 2 :border-left-color "#AA0000"
           :border-right-pixel 3 :border-right-color "#00AA00"
           :border-top-p t :border-top-color "#0000AA"
           :border-bottom-p t :border-bottom-color "#AA00AA"
           :color "#111111" :bgcolor "#EEEEEE"))
         (content-width (ebox--content-pixel box))
         (full-line (ebox-pixel-space content-width))
         (content (concat full-line "\n\n" full-line))
         (fast-path-calls 0)
         (original
          (symbol-function 'ebox--window-render-flat-wrapper-chunk-lines))
         generic fast)
    (plist-put box :content content)
    (plist-put box :ebox-content-width-exact-p t)
    (let ((ebox--flat-preformatted-box-fast-path-disabled t))
      (setq generic (ebox-render box)))
    (clrhash ebox--region-box-table)
    (clrhash ebox--scroll-global-state)
    (cl-letf (((symbol-function 'ebox--window-render-flat-wrapper-chunk-lines)
               (lambda (&rest arguments)
                 (cl-incf fast-path-calls)
                 (apply original arguments))))
      (setq fast (ebox-render box)))
    (should (= fast-path-calls 1))
    (should-not (gethash 'fixed-wrapper ebox--region-box-table))
    (should-not (gethash 'fixed-wrapper ebox--scroll-global-state))
    (should (equal-including-properties fast generic))))

(ert-deftest ebox-flat-preformatted-fixed-box-rejects-layout-work ()
  "Fixed wrappers should stay generic when clipping or alignment is required."
  (ebox-test--reset-runtime-state)
  (dolist (case '(("two\nlines" hidden top)
                  ("one\ntwo\nthree\nfour" hidden top)
                  ("one\ntwo\nthree" scroll top)
                  ("one\ntwo\nthree" hidden center)))
    (let* ((box
            (ebox-create
             :content (nth 0 case) :width '(120) :height 5
             :box-sizing 'border-box :overflow (nth 1 case)
             :vertical-align (nth 2 case) :wrap-mode nil))
           (calls 0)
           (original
            (symbol-function 'ebox--window-render-flat-wrapper-chunk-lines)))
      (plist-put box :ebox-content-width-exact-p t)
      (cl-letf (((symbol-function 'ebox--window-render-flat-wrapper-chunk-lines)
                 (lambda (&rest arguments)
                   (cl-incf calls)
                   (apply original arguments))))
        (ebox-render box))
      (should (= calls 0)))))


(ert-deftest ebox-overflowing-stack-content-still-uses-parent-formatting ()
  "An overflowing child stack must not publish uniform parent-width metadata."
  (ebox-test--reset-runtime-state)
  (let* ((child (ebox-column
                 (ebox-create :content "A" :width 140)
                 (ebox-create :content "B" :width 140)))
         (parent (ebox-create :width 120 :wrap-mode nil
                              :ebox-content-node child))
         (justify-count 0)
         (original (symbol-function 'ebox--lines-justify))
         rendered)
    (let ((ebox-viewport-width 120))
      (cl-letf (((symbol-function 'ebox--lines-justify)
                 (lambda (&rest args)
                   (cl-incf justify-count)
                   (apply original args))))
        (setq rendered (ebox-render parent))))
    (should (= justify-count 3))
    (should (= (ebox--string-max-pixel-width rendered) 140))))

(ert-deftest ebox-render-caches-lazy-box-content-within-render-pass ()
  "A lazy child layout should be rendered once per box/context in one pass."
  (ebox-test--reset-runtime-state)
  (let* ((child (ebox-column
                 (ebox-create :content "A" :width 80)
                 (ebox-create :content "B" :width 80)))
         (parent (ebox-create :width 'max-content :padding 2))
         (render-count 0)
         (original (symbol-function 'ebox--render-node-as-box-content)))
    (plist-put parent :ebox-content-node child)
    (cl-letf (((symbol-function 'ebox--render-node-as-box-content)
               (lambda (&rest args)
                 (cl-incf render-count)
                 (apply original args))))
      (ebox-render parent))
    (should (= render-count 1))))

(ert-deftest ebox-buffer-update-report-includes-dirty-and-patch-summary ()
  "Update reports should show dirty and patch-set summaries."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Report" :width 80
                           :border t :border-color "red"))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id :border-color "blue")
      (let ((report (ebox-test--buffer-update-report)))
        (should (plist-member report :dirty-count))
        (should (plist-member report :patch-count))
        (should (plist-member report :patch-ops))
        (should (equal (plist-get report :dirty-keys)
                       '(:border-top-color :border-right-color
                         :border-bottom-color :border-left-color)))))))

(ert-deftest ebox-buffer-update-report-is-buffer-local ()
  "Updating one rendered buffer should not replace another buffer's report."
  (ebox-test--reset-runtime-state)
  (let* ((first-box (ebox-create :content "First" :width '(80)))
         (second-box (ebox-create :content "Second" :width '(80)))
         (first-id (car (ebox-region-ids first-box)))
         first-buffer second-buffer)
    (unwind-protect
        (progn
          (setq first-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-report-first*")
                 first-box))
          (setq second-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-report-second*")
                 second-box))
          (ebox-test--set-buffer-update-report
           second-buffer '(:strategy second-prior :owner-ids (second)))
          (with-current-buffer first-buffer
            (let ((report (ebox-test--region-update first-id :content "First!")))
              (should (equal report
                             (ebox-buffer-update-report first-buffer)))
              (should-not (equal report
                                 (ebox-buffer-update-report
                                  second-buffer)))
              (should (equal (ebox-buffer-update-report second-buffer)
                             '(:strategy second-prior
                               :owner-ids (second)))))))
      (dolist (buffer (list first-buffer second-buffer))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ebox-buffer-update-report-returns-defensive-copy ()
  "The public accessor should not return mutable render-state storage."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Copy" :width '(80)))
         buffer)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-report-copy*")
                 box))
          (ebox-test--set-buffer-update-report
           buffer '(:strategy paint-patch :owner-ids (1 2)))
          (let ((report (ebox-buffer-update-report buffer)))
            (should (equal report '(:strategy paint-patch :owner-ids (1 2))))
            (plist-put report :strategy 'mutated)
            (setcar (plist-get report :owner-ids) 99))
          (should (equal (ebox-buffer-update-report buffer)
                         '(:strategy paint-patch :owner-ids (1 2)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-buffer-update-report-user-errors-without-rendered-buffer ()
  "The public accessor should reject missing, dead, and unrendered buffers."
  (ebox-test--reset-runtime-state)
  (let ((dead (generate-new-buffer " *ebox-report-dead*"))
        (unrendered (generate-new-buffer " *ebox-report-unrendered*")))
    (unwind-protect
        (progn
          (kill-buffer dead)
          (should-error (ebox-buffer-update-report nil) :type 'user-error)
          (should-error (ebox-buffer-update-report dead) :type 'user-error)
          (should-error (ebox-buffer-update-report unrendered)
                        :type 'user-error))
      (when (buffer-live-p unrendered)
        (kill-buffer unrendered)))))

(ert-deftest ebox-region-update-return-matches-buffer-update-report ()
  "A direct region update should return the report stored on its buffer."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Return" :width '(80)
                           :color "#111111"))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (let ((report (ebox-test--region-update region-id :color "#222222")))
        (should (equal report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'paint-patch))))))

(ert-deftest ebox-region-update-no-op-replaces-stale-buffer-report ()
  "A direct unchanged update should publish its own no-op report."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "No-op" :width '(80)
                           :color "#111111"))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (let ((prior '(:strategy paint-patch :owner-ids (prior))))
        (ebox-test--set-buffer-update-report (current-buffer) prior)
        (let ((report
               (ebox-test--region-update region-id :color "#111111")))
          (should (eq (plist-get report :strategy) 'no-op))
          (should (= (plist-get report :dirty-count) 0))
          (should (= (plist-get report :patch-count) 0))
          (should (equal report (ebox-test--buffer-update-report)))
          (should-not (equal report prior)))))))

(ert-deftest ebox-batched-region-update-keeps-prior-report-until-flush ()
  "Batched region updates should return nil and publish only on flush."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Batch" :width '(80)
                           :color "#111111"))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (let ((buffer (current-buffer))
            (prior '(:strategy prior :owner-ids (prior))))
        (ebox-test--set-buffer-update-report buffer prior)
        (ebox-incremental-begin-batch buffer)
        (should-not (ebox-test--region-update region-id :color "#333333"))
        (should (equal (ebox-buffer-update-report buffer) prior))
        (let ((flush-report (ebox-incremental-flush buffer)))
          (should flush-report)
          (should (equal flush-report
                         (ebox-buffer-update-report buffer)))
          (should (eq (plist-get flush-report :strategy)
                      'paint-patch)))))))

(ert-deftest ebox-batch-flush-stores-report-on-flushed-buffer-only ()
  "Empty and non-empty flushes should update only the target buffer report."
  (ebox-test--reset-runtime-state)
  (let* ((first-box (ebox-create :content "First" :width '(80)
                                 :color "#111111"))
         (second-box (ebox-create :content "Second" :width '(80)
                                  :color "#111111"))
         (second-id (car (ebox-region-ids second-box)))
         first-buffer second-buffer)
    (unwind-protect
        (progn
          (setq first-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-flush-first*")
                 first-box))
          (setq second-buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-flush-second*")
                 second-box))
          (ebox-test--set-buffer-update-report
           first-buffer '(:strategy first-prior))
          (ebox-test--set-buffer-update-report
           second-buffer '(:strategy second-prior))
          (ebox-incremental-begin-batch first-buffer)
          (let ((first-report (ebox-incremental-flush first-buffer)))
            (should (eq (plist-get first-report :strategy) 'no-op))
            (should (equal (ebox-buffer-update-report first-buffer)
                           first-report))
            (should (equal (ebox-buffer-update-report second-buffer)
                           '(:strategy second-prior)))
            (with-current-buffer second-buffer
              (ebox-incremental-begin-batch second-buffer)
              (should-not
               (ebox-test--region-update second-id :color "#444444")))
            (let ((second-report (ebox-incremental-flush second-buffer)))
              (should (eq (plist-get second-report :strategy) 'paint-patch))
              (should (equal (ebox-buffer-update-report second-buffer)
                             second-report))
              (should (equal (ebox-buffer-update-report first-buffer)
                             first-report)))))
      (dolist (buffer (list first-buffer second-buffer))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ebox-render-to-buffer-does-not-switch-current-buffer ()
  (ebox-test--reset-runtime-state)
  (let ((origin (current-buffer))
        buffer)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 (ebox-create :content "Hello" :width 40)))
          (should (eq (current-buffer) origin))
          (should (buffer-live-p buffer))
          (with-current-buffer buffer
            (should ebox-buffer-mode)
            (should buffer-read-only)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-render-to-buffer-keeps-existing-local-map-as-parent ()
  (ebox-test--reset-runtime-state)
  (let* ((buffer-name (generate-new-buffer-name " *ebox-test*"))
         (buffer (get-buffer-create buffer-name))
         (parent-map (make-sparse-keymap)))
    (define-key parent-map (kbd "x") #'ignore)
    (unwind-protect
        (with-current-buffer buffer
          (use-local-map parent-map)
          (ebox-render-to-buffer buffer-name
            (ebox-create :content "Hello" :width 40))
          (should (eq (current-local-map) parent-map))
          (should (eq (lookup-key (current-local-map) (kbd "x")) #'ignore)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))



(ert-deftest ebox-buffer-kill-clears-region-runtime-caches ()
  "Killing an ebox buffer should clear region-scoped runtime cache entries."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC" :width 80 :height 1
                           :overflow 'scroll))
         (region-id (car (ebox-region-ids box)))
         (buffer (ebox-render-to-buffer
                  (generate-new-buffer-name " *ebox-test*")
                  box)))
    (should (gethash region-id ebox--region-box-table))
    (should (ebox--scroll-get-state region-id))
    (kill-buffer buffer)
    (should-not (gethash region-id ebox--region-box-table))
    (should-not (ebox--scroll-get-state region-id))))

(ert-deftest ebox-buffer-kill-discards-buffer-owned-runtime-state ()
  "Killing an Ebox buffer should discard every buffer-keyed runtime entry."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Lifecycle" :color "#111111"))
         (region-id (car (ebox-region-ids box)))
         buffer surface handle)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*") box))
          (setq surface
                (with-current-buffer buffer ebox-surface--buffer-surface)
                handle (ebox-test--region-handle-for-id region-id))

          (ebox-test--region-update region-id :color "#222222")

          ;; A later update remains pending in the explicit batch.
          (ebox-incremental-begin-batch buffer)
          (ebox-test--region-update region-id :background-color "#eeeeee")

          (should (gethash buffer ebox--buffer-render-state-table))
          (should (gethash buffer ebox-incremental--batch-table))
          (should (tp-surface-live-p surface))
          (should (ebox-buffer-update-report buffer))
          (should (= (ebox-incremental-pending-count buffer) 1))

          (kill-buffer buffer)
          (should-not (gethash buffer ebox--buffer-render-state-table))
          (should-not (gethash buffer ebox-cache--buffer-report-table))
          (should-not (gethash buffer ebox-incremental--batch-table))
          (should-not (tp-surface-live-p surface))
          (should-error (ebox-region-update handle :content "stale")
                        :type 'user-error)
          (should-error (ebox-buffer-update-report buffer)
                        :type 'user-error))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer))
      (when buffer
        (remhash buffer ebox--buffer-render-state-table)
        (remhash buffer ebox-cache--buffer-report-table)
        (remhash buffer ebox-incremental--batch-table)))))

(ert-deftest ebox-concat-content-update-preserves-neighbor-box ()
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "A\nB" :width 60))
         (right (ebox-create :content "R1\nR2\nR3" :width 80))
         (layout (ebox-concat left right))
         (ids (ebox-region-ids layout))
         (left-id (nth 0 ids))
         (right-id (nth 1 ids)))
    (ebox-test--with-rendered-buffer layout
      (should (ebox-surface-region-mounts (current-buffer) left-id))
      (ebox-test--region-update left-id :content "AA\nBB\nCC")
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "CC" plain))
        (should (string-match-p "R3" plain)))
      (should (equal (ebox-region-ids layout) ids))
      (should (gethash right-id ebox--region-box-table)))))

(ert-deftest ebox-geometry-update-rerenders-root-once-safely ()
  (ebox-test--reset-runtime-state)
  (let* ((top (ebox-create :content "Top" :width 60))
         (left (ebox-create :content "L" :width 40))
         (right (ebox-create :content "R" :width 40))
         (layout (ebox-stack top (ebox-concat left right)))
         (ids (ebox-region-ids layout))
         (left-id (nth 1 ids)))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update left-id :width '(120))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Top" plain))
        (should (string-match-p "L" plain))
        (should (string-match-p "R" plain)))
      (should (equal (ebox-region-ids layout) ids)))))

(ert-deftest ebox-border-color-update-patches-without-full-root-rerender ()
  "A pure border color change should patch owned spans, not rebuild the root."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "L" :width 40
                            :border t :border-color "red"))
         (right (ebox-create :content "R" :width 40
                             :border t :border-color "green"))
         (layout (ebox-concat left right))
         (left-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (let ((full-rerenders
             (ebox-test--count-full-surface-updates
               (ebox-test--region-update left-id :border-color "blue"))))
        (should (= full-rerenders 0)))
      (let ((border-face (get-text-property (point-min) 'face)))
        (should (ebox-test--face-has-key-value-p border-face
                                                 :overline "blue")))
      (should (string-match-p
               "R"
               (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest ebox-flex-row-border-color-update-patches-region-role ()
  "Paint-only updates inside flex rows should not fall back to root rerender."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(flex :flex-flow (row wrap) :column-gap (12)
                    :padding (0 (12)) :border "#D97757" :bgcolor "#FFF8F2"
                    (column
                     (box :id left :content "Left" :width (120)
                          :padding (0 (8)) :border "#D97757")
                     (box :content "Body" :width (120)
                          :padding (0 (8)) :border "#D97757"
                          :border-top-p nil))
                    (column
                     (box :id right :content "Right" :width (120)
                          :padding (0 (8)) :border "#5E7F6A")
                     (box :content "Body" :width (120)
                          :padding (0 (8)) :border "#5E7F6A"
                          :border-top-p nil)))))
         (left-id (plist-get
                   (car (ebox-selector-query-all layout "#left"))
                   :region-id)))
    (ebox-test--with-rendered-buffer layout
      (let ((full-rerenders
             (ebox-test--count-full-surface-updates
               (ebox-test--region-update left-id :border-bottom-color "blue"))))
        (should (= full-rerenders 0)))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'paint-patch))
        (should-not (plist-get report :root-rerender)))
      (let (bottom-face)
        (save-excursion
          (goto-char (point-min))
          (while (and (not bottom-face) (< (point) (point-max)))
            (when (equal (get-text-property (point) 'ebox-bb) left-id)
              (setq bottom-face (get-text-property (point) 'face)))
            (forward-char 1)))
        (should (ebox-test--face-has-key-value-p
                 bottom-face :underline '(:position t :color "blue")))))))

(ert-deftest ebox-paint-update-synthesizes-missing-horizontal-border-surface ()
  "Adding a missing top/bottom paint surface should patch from region anchors."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(flex :flex-flow (row wrap) :column-gap (12)
                    :padding (0 (12)) :border "#D97757" :bgcolor "#FFF8F2"
                    (column
                     (box :id left :content "Left" :width (120)
                          :padding (0 (8)) :border "#D97757"
                          :border-bottom-p nil)
                     (box :content "Body" :width (120)
                          :padding (0 (8)) :border "#D97757"
                          :border-top-p nil))
                    (column
                     (box :content "Right" :width (120)
                          :padding (0 (8)) :border "#5E7F6A"
                          :border-bottom-p nil)
                     (box :content "Body" :width (120)
                          :padding (0 (8)) :border "#5E7F6A"
                          :border-top-p nil)))))
         (left-id (plist-get
                   (car (ebox-selector-query-all layout "#left"))
                   :region-id)))
    (ebox-test--with-rendered-buffer layout
      (should-not (text-property-search-forward 'ebox-bb left-id t))
      (let ((full-rerenders
             (ebox-test--count-full-surface-updates
               (ebox-test--region-update left-id
                                   :border-bottom-p t
                                   :border-bottom-color "blue"))))
        (should (= full-rerenders 0)))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'paint-patch))
        (should-not (plist-get report :root-rerender)))
      (let (bottom-face)
        (save-excursion
          (goto-char (point-min))
          (while (and (not bottom-face) (< (point) (point-max)))
            (when (equal (get-text-property (point) 'ebox-bb) left-id)
              (setq bottom-face (get-text-property (point) 'face)))
            (forward-char 1)))
        (should (ebox-test--face-has-key-value-p
                 bottom-face :underline '(:position t :color "blue")))))))

(ert-deftest ebox-horizontal-border-removal-preserves-other-border-colors ()
  "Removing top/bottom border surfaces must not corrupt other border faces."
  (ebox-test--reset-runtime-state)
  (dolist (case '((:border-top-p bt (bb bl br))
                  (:border-bottom-p bb (bt bl br))))
    (let* ((property (nth 0 case))
           (removed-role (nth 1 case))
           (kept-roles (nth 2 case))
           (layout (ebox-create :content "Border"
                                :width 80
                                :padding '(0 (8))
                                :border "#D97757"))
           (region-id (car (ebox-region-ids layout))))
      (ebox-test--with-rendered-buffer layout
        (cl-labels ((face-at-role
                     (role)
                     (let ((prop (alist-get role ebox-region-types))
                           face)
                       (save-excursion
                         (goto-char (point-min))
                         (while (and (not face) (< (point) (point-max)))
                           (when (equal (get-text-property (point) prop)
                                        region-id)
                             (setq face (get-text-property (point) 'face)))
                           (forward-char 1)))
                       face)))
          (ebox-test--region-update region-id property nil)
          (should-not (face-at-role removed-role))
          (dolist (role kept-roles)
            (should
             (ebox-test--border-face-has-color-p
              (face-at-role role) role "#D97757"))))))))

(ert-deftest ebox-side-border-color-patch-toggles-default-paint-exactly ()
  "Side color patches should match default and explicit full-render paint."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-create
           :content "Border" :width 80
           :border-left-pixel 2 :border-left-color "#AA0000"
           :border-right-pixel 2 :border-right-color "#AA0000"))
         (region-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update region-id
                          :border-left-color nil
                          :border-right-color nil)
      (dolist (role '(bl br))
        (let ((face
               (ebox-test--face-at-property
                (buffer-string) (alist-get role ebox-region-types))))
          (should
           (ebox-test--face-has-key-value-p face :inverse-video t))
          (should-not (ebox-test--face-has-key-p face :background))))
      (should (ebox-test--buffer-visually-matches-runtime-render-p))
      (ebox-test--region-update region-id
                          :border-left-color "#00AA00"
                          :border-right-color "#00AA00")
      (dolist (role '(bl br))
        (let ((face
               (ebox-test--face-at-property
                (buffer-string) (alist-get role ebox-region-types))))
          (should-not (ebox-test--face-has-key-p face :inverse-video))
          (should
           (ebox-test--face-has-key-value-p
            face :background "#00AA00"))))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-region-update-reuses-buffer-render-viewport-context ()
  "Incremental rerender should use the viewport from the original buffer render."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-flex :padding '(0 4) :border "#64748B"
                   (ebox-create :content "Flex Child" :width '(120)
                                :border t)))
         (region-id (car (ebox--node-all-region-ids layout)))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 240))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (with-current-buffer buffer
            (let ((full-rerenders
                   (ebox-test--count-full-surface-updates
                     (ebox-test--region-update region-id
                                         :border-color "#2563EB"))))
              (should (= full-rerenders 0)))
            (let ((report (ebox-test--buffer-update-report)))
              (should (eq (plist-get report :strategy) 'paint-patch))
              (should (eq (plist-get report :constraint-owner-type) 'flex))
              (should (eq (plist-get report :tp-render-scope) 'objects))
              (should-not (plist-get report :tp-full-root))
              (should (equal (plist-get report :patch-ops)
                             '(paint-patch))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-rerender-buffer-with-context-resolves-runtime-viewport ()
  "Runtime rerender should resolve viewport-sized boxes with the new context."
  (ebox-test--reset-runtime-state)
  (let* ((node (let ((ebox-viewport-width 240))
                 (ebox-build
                  '(box :content "Viewport" :width (viewport) :border t))))
         buffer)
    (unwind-protect
        (progn
          (should (eq (plist-get node :width) 'viewport))
          (let ((ebox-viewport-width 240))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   node)))
          (with-current-buffer buffer
            (should (= (ebox--string-pixel-width
                        (buffer-substring (point-min) (line-end-position)))
                       240)))
          (ebox-rerender-buffer-with-context buffer 160)
          (with-current-buffer buffer
            (should (= (ebox--string-pixel-width
                        (buffer-substring (point-min) (line-end-position)))
                       160))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-rerender-buffer-with-context-resolves-runtime-viewport-height ()
  "Runtime rerender should resolve viewport-height boxes with the new context."
  (ebox-test--reset-runtime-state)
  (let* ((node (let ((ebox-viewport-height 2))
                 (ebox-build
                  '(box :content "One\nTwo\nThree\nFour"
                    :width (120)
                    :height (viewport-height)
                    :overflow scroll))))
         buffer)
    (unwind-protect
        (progn
          (let ((ebox-viewport-height 2))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   node)))
          (with-current-buffer buffer
            (should (= (length (ebox-string-lines
                                (buffer-substring-no-properties
                                 (point-min) (point-max))))
                       2)))
          (ebox-rerender-buffer-with-context buffer 120 3)
          (with-current-buffer buffer
            (should (= (length (ebox-string-lines
                                (buffer-substring-no-properties
                                 (point-min) (point-max))))
                       3))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))


(ert-deftest ebox-stable-content-update-patches-without-full-root-rerender ()
  "A content update with unchanged rendered geometry should stay local."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "Alpha" :width 80 :height 1))
         (right (ebox-create :content "Right" :width 80 :height 1))
         (layout (ebox-concat left right))
         (left-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (let ((full-rerenders
             (ebox-test--count-full-surface-updates
               (ebox-test--region-update left-id :content "Beta"))))
        (should (= full-rerenders 0)))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Beta" plain))
        (should-not (string-match-p "Alpha" plain))
        (should (string-match-p "Right" plain))))))

(ert-deftest ebox-nested-stable-content-update-patches-leaf-owner ()
  "Stable content updates inside nested layouts should not patch the root."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(flex :flex-flow (row wrap) :column-gap (12)
             :padding (0 (12)) :border "#999999"
             (column :width (210) :border "#999999"
              (box :content "Title" :width (190))
              (box :id target :content "before\nsame"
                   :width (190) :height 3
                   :padding (0 (8)) :border "#999999")
              (box :content "Metric" :width (190)))
             (column :width (210) :border "#999999"
              (box :content "Other" :width (190))
              (box :content "Still here" :width (190))))))
         (target (car (ebox-selector-query-all layout "#target")))
         (target-id (plist-get target :region-id))
         (target-node-id (plist-get target :node-id)))
    (ebox-test--with-rendered-buffer layout
      (let ((snapshot (ebox--ensure-layout-snapshot-spans
                       (current-buffer) target-node-id)))
        (should snapshot)
        (should (plist-get snapshot :buffer-spans)))
      (ebox-test--region-update target-id :content "after\nsame")
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (equal (plist-get report :owner-ids) (list target-node-id)))
        (should (< (plist-get report :span-count) 10))
        (should-not (plist-get report :full-rerender)))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "after" plain))
        (should-not (string-match-p "before" plain))
        (should (string-match-p "Still here" plain))))))

(ert-deftest ebox-flex-contained-geometry-update-does-not-promote-to-root ()
  "Stable flex-contained geometry changes should stop before root."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(column :id root :width (520) :padding (1 (18))
             (flex :id matrix :flex-flow (row wrap)
              :column-gap (12) :row-gap 1 :padding (0 (12))
              :border "#999999"
              (column :width (210) :border "#999999"
               (box :content "Title" :width (190))
               (box :id target :content "width target\nsame height"
                    :width (160) :height 3
                    :padding (0 (8)) :border "#999999")
               (box :content "Metric" :width (190)))
              (column :width (210) :border "#999999"
               (box :content "Other" :width (190))
               (box :content "Still here" :width (190)))))))
         (target (car (ebox-selector-query-all layout "#target")))
         (target-id (plist-get target :region-id)))
    (ebox-test--with-rendered-buffer layout
      (let ((root-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox-test--region-update target-id :width '(190))
        (let ((report (ebox-test--buffer-update-report)))
          (should-not (plist-get report :full-rerender))
          (should-not (member root-id (plist-get report :owner-ids)))
          (should (memq (plist-get report :strategy)
                        '(span-patch owner-rerender)))
          (should (< (plist-get report :span-count) 40)))))))

(defun ebox-test--nested-width-containment-layout (&optional height)
  "Return a nested flex width-update fixture with optional fixed HEIGHT."
  (let* ((target
          (ebox-create :content "width target\nready to grow"
                       :width '(190) :height 3 :padding '(0 (10))
                       :border "#999999"))
         (owner
          (apply #'ebox-flex
                 (append
                  (list :width '(300) :padding '(0 (10))
                        :border "#999999" :justify-content 'center
                        :align-items 'center)
                  (when height (list :height height))
                  (list target))))
         (card
          (ebox-column
           (ebox-create :content "Width" :width '(300) :height 2)
           owner
           (ebox-create :content "The target stays in this card"
                        :width '(300) :height 3)
           (ebox-create :content "Metric" :width '(300) :height 4)))
         (peer
          (ebox-column
           (ebox-create :content "Peer" :width '(300) :height 2)
           (ebox-create :content "Stable peer" :width '(300) :height 5)
           (ebox-create :content "Footer" :width '(300) :height 7)))
         (layout
          (ebox-flex :width '(720) :flex-flow '(row wrap)
                     :column-gap '(12) card peer)))
    (list :layout layout :target target :owner owner)))

(ert-deftest ebox-fixed-flex-context-contains-child-width-update ()
  "Fixed flex contexts should patch their five lines, not the whole card."
  (ebox-test--reset-runtime-state)
  (let* ((fixture (ebox-test--nested-width-containment-layout 5))
         (layout (plist-get fixture :layout))
         (target (plist-get fixture :target))
         (owner (plist-get fixture :owner))
         (target-region-id (car (ebox-region-ids target)))
         (owner-node-id (ebox--ensure-node-id owner)))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update target-region-id :width '(280))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (equal (plist-get report :owner-ids)
                       (list owner-node-id)))
        (should (eq (plist-get report :owner-type) 'flex))
        (should (> (plist-get report :span-count) 0))
        (should-not (plist-get report :root-rerender))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-contained-partial-flex-content-change-preserves-fixed-slot ()
  "A fixed partial flex should update without disturbing adjacent siblings."
  (ebox-test--reset-runtime-state)
  (let* ((mark (ebox-create :key 'mark :host-ref 'mark
                            :content "○ OFF" :width 'max-content
                            :overflow 'hidden))
         (label (ebox-create :key 'label :content " Power off"
                             :host-ref 'label :width 'max-content
                             :overflow 'hidden))
         (switch (ebox-create :key 'switch :host-ref 'switch
                              :width 'max-content :wrap-mode nil
                              :overflow 'hidden
                              :ebox-content-node (ebox-row mark label)))
         (owner (ebox-flex :width '(496) :min-width '(496)
                           :max-width '(496) :height 1 :min-height 1
                           :max-height 1 :overflow 'hidden
                           :bgcolor "#F7F8FA" :wrap-mode nil
                           :flex-flow '(column nowrap) switch))
         (caption (ebox-create :content "switch" :width '(170)
                               :min-width '(170) :max-width '(170)
                               :height 1 :min-height 1 :max-height 1))
         (outer (ebox-flex :width '(680) :min-width '(680)
                           :max-width '(680) :height 1 :min-height 1
                           :max-height 1 :overflow 'hidden
                           :bgcolor "#F7F8FA" :wrap-mode nil
                           :column-gap '(14) :flex-flow '(row nowrap)
                           caption owner))
         (footer (ebox-create :content "FOOTER" :width '(680) :height 1))
         (layout (ebox-column outer footer))
         (mark-node-id (ebox--ensure-node-id mark))
         (label-node-id (ebox--ensure-node-id label))
         (owner-node-id (ebox--ensure-node-id owner)))
    (plist-put owner :key 'owner)
    (plist-put owner :host-ref 'owner)
    (plist-put outer :key 'outer)
    (plist-put outer :host-ref 'outer)
    (ebox-test--with-rendered-buffer layout
      (should (ebox--contained-partial-flex-owner-p
               (current-buffer) owner-node-id))
      (let ((candidate (ebox-candidate-begin (current-buffer))))
        (ebox-candidate-replace
         candidate mark-node-id
         (ebox-create :key 'mark :host-ref 'mark
                      :content " ON ● " :width 'max-content
                      :overflow 'hidden))
        (ebox-candidate-replace
         candidate label-node-id
         (ebox-create :key 'label :host-ref 'label
                      :content " Much longer power on state"
                      :width 'max-content
                      :overflow 'hidden))
        (ebox-commit (current-buffer) candidate))
      (let ((report (ebox-test--buffer-update-report)))
        (should (memq (plist-get report :strategy)
                      '(span-patch owner-rerender)))
        (should (equal (plist-get report :owner-ids) (list owner-node-id)))
        (should (eq (plist-get report :owner-type) 'flex))
        (should (= (plist-get report :span-count) 1))
        (should-not (plist-get report :tp-full-root))
        (should-not (plist-get report :tp-scope-fallback))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))
        (should
         (ebox-test--buffer-propertized-matches-runtime-render-p))))))

(ert-deftest ebox-contained-partial-flex-structure-change-preserves-fixed-slot ()
  "A fixed partial flex should own bounded descendant structure changes."
  (ebox-test--reset-runtime-state)
  (let* ((input (ebox-create :key 'input :content "query"
                             :overflow 'hidden))
         (content
          (ebox-create :key 'content :host-ref 'content
                       :width 'max-content :overflow 'hidden
                       :ebox-content-node (ebox-column input)))
         (owner (ebox-flex :width '(180) :height 2 :overflow 'hidden
                           :flex-flow '(column nowrap) content))
         (caption (ebox-create :content "search" :width '(80) :height 2))
         (outer (ebox-row caption owner))
         (footer (ebox-create :content "FOOTER" :width '(260) :height 1))
         (layout (ebox-column outer footer))
         (content-node-id (ebox--ensure-node-id content))
         (owner-node-id (ebox--ensure-node-id owner)))
    (plist-put owner :key 'owner)
    (plist-put owner :host-ref 'owner)
    (ebox-test--with-rendered-buffer layout
      (let ((candidate (ebox-candidate-begin (current-buffer))))
        (ebox-candidate-replace
         candidate content-node-id
         (ebox-create
          :key 'content :host-ref 'content
          :width 'max-content :overflow 'hidden
          :ebox-content-node
          (ebox-column
           (ebox-create :key 'input :content "query" :overflow 'hidden)
           (ebox-create :key 'option :content "Apple" :overflow 'hidden))))
        (ebox-commit (current-buffer) candidate))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should (equal (plist-get report :owner-ids) (list owner-node-id)))
        (should (eq (plist-get report :owner-type) 'flex))
        (should (= (plist-get report :span-count) 2))
        (should-not (plist-get report :tp-full-root))
        (should-not (plist-get report :tp-scope-fallback))
        (should
         (ebox-test--buffer-propertized-matches-runtime-render-p))))))


(ert-deftest ebox-auto-height-flex-context-keeps-ancestor-width-fallback ()
  "Auto-height flex contexts must not contain descendant width reflow."
  (ebox-test--reset-runtime-state)
  (let* ((fixture (ebox-test--nested-width-containment-layout))
         (layout (plist-get fixture :layout))
         (target (plist-get fixture :target))
         (owner (plist-get fixture :owner))
         (target-region-id (car (ebox-region-ids target)))
         (owner-node-id (ebox--ensure-node-id owner)))
    (ebox-test--with-rendered-buffer layout
      (should-not (ebox--definite-containment-formatting-context-p
                   (current-buffer) owner-node-id))
      (ebox-test--region-update target-region-id :width '(280))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should-not (equal (plist-get report :owner-ids)
                           (list owner-node-id)))
        (should (eq (plist-get report :owner-type) 'flex))
        (should-not (plist-get report :root-rerender))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-intrinsic-constrained-flex-context-keeps-ancestor-fallback ()
  "Intrinsic min/max constraints must disable definite containment."
  (dolist (max-width '(min-content (fit-content 260)))
    (ebox-test--reset-runtime-state)
    (let* ((fixture (ebox-test--nested-width-containment-layout 5))
           (layout (plist-get fixture :layout))
           (target (plist-get fixture :target))
           (owner (plist-get fixture :owner))
           (owner-box (plist-get owner :box))
           (target-region-id (car (ebox-region-ids target)))
           (owner-node-id (ebox--ensure-node-id owner)))
      (ebox-put owner-box :max-width max-width)
      (ebox-test--with-rendered-buffer layout
        (should-not (ebox--definite-containment-formatting-context-p
                     (current-buffer) owner-node-id))
        (ebox-test--region-update target-region-id :width '(280))
        (let ((report (ebox-test--buffer-update-report)))
          (should-not (equal (plist-get report :owner-ids)
                             (list owner-node-id)))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-visible-overflow-flex-context-keeps-ancestor-fallback ()
  "A fixed context must not contain an unowned visible-overflow suffix."
  (ebox-test--reset-runtime-state)
  (let* ((fixture (ebox-test--nested-width-containment-layout 5))
         (layout (plist-get fixture :layout))
         (target (plist-get fixture :target))
         (owner (plist-get fixture :owner))
         (target-region-id (car (ebox-region-ids target)))
         (owner-node-id (ebox--ensure-node-id owner)))
    (ebox-put target :content "line 1\nline 2\nline 3\nline 4")
    (ebox-put target :height 2)
    (ebox-put target :overflow 'visible)
    (ebox-test--with-rendered-buffer layout
      (should-not (ebox--definite-containment-formatting-context-p
                   (current-buffer) owner-node-id))
      (ebox-test--region-update target-region-id :width '(280))
      (let ((report (ebox-test--buffer-update-report)))
        (should-not (equal (plist-get report :owner-ids)
                           (list owner-node-id)))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-visible-overflow-flex-wrapper-disables-width-containment ()
  "A visible-overflow flex wrapper must not contain child width changes."
  (ebox-test--reset-runtime-state)
  (let* ((target
          (ebox-create :content "child" :width '(190)
                       :height 5 :min-height 5))
         (owner
          (ebox-flex :width '(300) :height 2 :overflow 'visible
                     :align-items 'flex-start target))
         (layout
          (ebox-stack owner
                      (ebox-create :content "footer" :width '(300)
                                   :height 2)))
         (owner-node-id (ebox--ensure-node-id owner)))
    (ebox-test--with-rendered-buffer layout
      (should (= (ebox-string-height (ebox-render owner)) 5))
      (should-not (ebox--definite-containment-formatting-context-p
                   (current-buffer) owner-node-id)))))

(ert-deftest ebox-fixed-flex-context-contains-child-block-size-update ()
  "A fixed flex should contain a child block-size change in its five lines."
  (ebox-test--reset-runtime-state)
  (let* ((fixture (ebox-test--nested-width-containment-layout 5))
         (layout (plist-get fixture :layout))
         (target (plist-get fixture :target))
         (target-region-id (car (ebox-region-ids target)))
         (owner-node-id
          (ebox--ensure-node-id (plist-get fixture :owner))))
    (ebox-test--with-rendered-buffer layout
      (let ((root-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox-test--region-update target-region-id :height 4)
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'span-patch))
          (should (equal (plist-get report :owner-ids)
                         (list owner-node-id)))
          (should (eq (plist-get report :owner-type) 'flex))
          (should (> (plist-get report :span-count) 0))
          (should-not (member root-id (plist-get report :owner-ids))))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-fixed-flex-own-width-change-promotes-outside-containment ()
  "A fixed flex must not contain a change to its own outer width."
  (ebox-test--reset-runtime-state)
  (let* ((fixture (ebox-test--nested-width-containment-layout 5))
         (layout (plist-get fixture :layout))
         (owner (plist-get fixture :owner))
         (owner-region-id (car (ebox-region-ids owner))))
    (ebox-test--with-rendered-buffer layout
      (let ((root-node-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox-test--region-update owner-region-id :width '(320))
        (let ((report (ebox-test--buffer-update-report)))
          (should (equal (plist-get report :owner-ids)
                         (list root-node-id)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-flex-main-footprint-change-skips-flex-span-probe ()
  "Flex main footprint changes should not render a large flex owner twice."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(column :id root :width (520) :padding (1 (18))
             (flex :id matrix :flex-flow (row wrap)
              :column-gap (12) :row-gap 1 :padding (0 (12))
              :border "#999999"
              (column :width (210) :border "#999999"
               (box :content "Title" :width (190))
               (box :id target :content "width target\nsame height"
                    :width (160) :height 3
                    :padding (0 (8)) :border "#999999")
               (box :content "Metric" :width (190)))
              (column :width (210) :border "#999999"
               (box :content "Other" :width (190))
               (box :content "Still here" :width (190)))))))
         (target (car (ebox-selector-query-all layout "#target")))
         (target-id (plist-get target :region-id)))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update target-id
                                :width '(210)
                                :min-width '(150)
                                :max-width '(260))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should-not (plist-get report :root-rerender))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(defun ebox-test--flex-line-width-owner-layout (&optional count width)
  "Return a wide flex layout whose first row has a nested width target."
  (let* ((count (or count 12))
         (resolved-width (if (eq width :auto)
                             nil
                           (or width '(2600))))
         (target
          (ebox-create :id "target" :content "width target\nmoves sibling layout"
                       :width '(160) :height 3 :padding '(0 (8))
                       :border "#999999"))
         (first
          (ebox-column
           (ebox-create :content "Title" :width '(190))
           target
           (ebox-create :content "Metric" :width '(190) :height 4))))
    (apply #'ebox-flex
           (append (list :flex-flow '(row wrap)
                         :column-gap '(12)
                         :row-gap 1
                         :padding '(0 (12))
                         :border "#999999")
                   (when resolved-width
                     (list :width resolved-width))
                   (list first)
                   (cl-loop for index from 1 below count
                            collect
                            (ebox-column
                             (ebox-create
                              :content (format "Title %02d" index)
                              :width '(190))
                             (ebox-create :content "Peer\nsame row"
                                          :width '(190) :height 3
                                          :padding '(0 (8))
                                          :border "#999999")
                             (ebox-create :content "Metric"
                                          :width '(190) :height 4)))))))

(ert-deftest ebox-flex-owner-update-reports-scoped-tp-publication ()
  "A contained flex owner update should publish through a scoped TP commit."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--flex-line-width-owner-layout)))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer) "#target")))
        (ebox-test--region-update region-id
                            :width '(210)
                            :min-width '(150)
                            :max-width '(260))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (eq (plist-get report :owner-type) 'flex))
          (should-not (plist-get report :tp-full-root))
          (should (> (plist-get report :tp-scope-count) 0))
          (should-not (plist-get report :tp-scope-fallback))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-flex-line-rerender-skips-auto-width-owner ()
  "Auto-width flex owners should fall back instead of slicing a moving suffix."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--flex-line-width-owner-layout 12 :auto)))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer) "#target")))
        (ebox-test--region-update region-id
                            :width '(210)
                            :min-width '(150)
                            :max-width '(260))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (eq (plist-get report :owner-type) 'flex))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-flex-owner-update-keeps-unrelated-snapshots-current ()
  "A scoped flex update should leave unrelated snapshots valid."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--flex-line-width-owner-layout 16)))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer) "#target"))
            (unrelated-child-id
             (plist-get
              (car (last (ebox--node-children
                          (ebox-test--runtime-root (current-buffer)))))
              :node-id)))
        (ebox-test--region-update region-id
                            :width '(210)
                            :min-width '(150)
                            :max-width '(260))
        (let ((report (ebox-test--buffer-update-report)))
          (should-not (plist-get report :tp-full-root))
          (should (> (plist-get report :tp-scope-count) 0))
          (should-not (plist-get report :tp-scope-fallback))
          (should
           (plist-get
            (ebox--ensure-layout-snapshot-spans
             (current-buffer) unrelated-child-id)
            :buffer-spans))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(defun ebox-test--dynamic-update-row-layout ()
  "Return a small flex-row layout shaped like the dynamic update matrix."
  (ebox-build
   '(column :id root :width (1200) :padding (1 (18))
     (flex :id matrix :flex-flow (row wrap)
      :column-gap (12) :row-gap 1 :padding (0 (12))
      :border "#999999"
      (column :width (210) :border "#999999"
       (box :content "Reference\nshort" :width (190))
       (box :id scroll :content "line 1\nline 2\nline 3\nline 4"
            :width (190) :height 2 :padding (0 (8))
            :border "#999999" :overflow scroll)
       (box :content "Metric" :width (190) :height 4))
      (column :width (210) :border "#999999"
       (box :content "Height\nowner" :width (190))
       (box :id height :content "height target\nexpands block"
            :width (190) :height 2 :padding (0 (8))
            :border "#999999")
       (box :content "Metric" :width (190) :height 4))
      (column :width (210) :border "#999999"
       (box :content "Margin\nslot stable" :width (190))
       (box :id margin :content "margin target\nparent placement"
            :width (170) :height 3 :padding (0 (8))
            :border "#999999")
       (box :content "Metric" :width (190) :height 4))
      (column :width (210) :border "#999999"
       (box :content "Overflow\nowner" :width (190))
       (box :id overflow :content "overflow target\nextra line\nanother line"
            :width (190) :height 2 :padding (0 (8))
            :border "#999999" :overflow scroll)
       (box :content "Metric" :width (190) :height 4))
      (column :width (210) :border "#999999"
       (box :content "Tall peer\nkeeps row slot" :width (190))
       (box :content "tall\npeer\nsets\nline\ncross" :width (190)
            :height 5 :padding (0 (8)) :border "#999999")
       (box :content "Metric" :width (190) :height 4))))))

(defun ebox-test--dynamic-update-tight-row-layout ()
  "Return a flex-row layout whose target growth exceeds its old item slot."
  (ebox-build
   '(column :id root :width (720)
     (box :content "Header" :width (720))
     (column :id panel :width (720) :border "#999999"
      (flex :id matrix :flex-flow (row wrap)
       :column-gap (12) :row-gap 1 :padding (0 (12))
      :border "#999999"
      (column :width (210) :border "#999999"
       (box :content "Height\nowner" :width (190))
       (box :id height :content "height target\nexpands block"
            :width (190) :height 2 :padding (0 (8))
            :border "#999999")
       (box :content "Metric" :width (190) :height 2))
      (column :width (210) :border "#999999"
       (box :content "Peer" :width (190))
       (box :content "peer\nsame row" :width (190)
            :height 2 :padding (0 (8)) :border "#999999")
       (box :content "Metric" :width (190) :height 2)))))))

(defun ebox-test--selector-region-id (buffer selector)
  "Return the first editable region id matching SELECTOR in BUFFER."
  (plist-get (car (ebox-selector-query-buffer buffer selector)) :region-id))

(defun ebox-test--visual-line-signature (line)
  "Return LINE's visible glyph positions and total pixel width."
  (let ((pixel 0)
        glyphs)
    (cl-loop for index below (length line)
             for next = (1+ index)
             for char = (aref line index)
             for width = (ebox--substring-pixel-width line index next)
             do (progn
                  (unless (eq char ?\s)
                    (push (cons pixel char) glyphs))
                  (setq pixel (+ pixel width))))
    (list :width pixel :glyphs (nreverse glyphs))))

(defun ebox-test--rendered-visually-equal-p (actual expected)
  "Return non-nil when ACTUAL and EXPECTED have the same visible layout."
  (let ((actual-lines (ebox-string-lines actual))
        (expected-lines (ebox-string-lines expected))
        (ok t))
    (setq ok (= (length actual-lines) (length expected-lines)))
    (while (and ok actual-lines expected-lines)
      (setq ok (equal (ebox-test--visual-line-signature (car actual-lines))
                      (ebox-test--visual-line-signature (car expected-lines)))
            actual-lines (cdr actual-lines)
            expected-lines (cdr expected-lines)))
    ok))

(defun ebox-test--buffer-visually-matches-runtime-render-p ()
  "Return non-nil when current buffer visually equals its runtime root render."
  (let* ((ebox--scroll-global-state (make-hash-table :test 'equal))
         (ebox--region-box-table (make-hash-table :test 'equal))
         (expected
          (ebox--with-buffer-render-context (current-buffer)
            (ebox-render (ebox--buffer-root-node (current-buffer))))))
    (ebox-test--rendered-visually-equal-p
     (buffer-substring (point-min) (point-max))
     expected)))

(defun ebox-test--buffer-propertized-matches-runtime-render-p ()
  "Return non-nil when the current buffer exactly matches a runtime render."
  (let* ((ebox--scroll-global-state (make-hash-table :test 'equal))
         (ebox--region-box-table (make-hash-table :test 'equal))
         (expected
          (ebox--with-buffer-render-context (current-buffer)
            (ebox-render (ebox--buffer-root-node (current-buffer))))))
    (equal-including-properties
     (buffer-substring (point-min) (point-max)) expected)))

(defun ebox-test--assert-scoped-tp-publication (&optional report)
  "Assert REPORT describes a scoped TP publication without root fallback."
  (let ((report (or report (ebox-test--buffer-update-report))))
    (should (plist-get report :runtime-published))
    (should-not (plist-get report :tp-full-root))
    (should (> (or (plist-get report :tp-scope-count) 0) 0))
    (should-not (plist-get report :tp-scope-fallback))))

(defun ebox-test--assert-buffer-runtime-current (&optional report)
  "Assert REPORT published a current buffer matching its Ebox runtime."
  (ebox-test--assert-scoped-tp-publication report)
  (should (ebox-test--buffer-visually-matches-runtime-render-p))
  (should (ebox-test--buffer-propertized-matches-runtime-render-p)))

(ert-deftest ebox-scroll-offset-fast-path-preserves-line-display-properties ()
  "TP scroll publication must preserve per-character display properties."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id scroll
            :content "第 1 行\n第 2 行\n第 3 行\n第 4 行"
            :width (230) :height 2 :padding (0 (10))
            :border "#9CA3AF" :bgcolor "#F8FAFC"
            :color "#3D3A35" :text-align center
            :overflow scroll :scroll-offset 0))))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#scroll"))
            (surface ebox-surface--buffer-surface))
        (let ((revision (tp-surface-revision surface)))
          (ebox-test--region-update region-id :scroll-offset 2)
          (should (= (tp-surface-revision surface) (1+ revision))))
        (let ((report (ebox-test--buffer-update-report)))
          (should-not (plist-get report :tp-full-root))
          (should (> (plist-get report :tp-scope-count) 0))
          (should-not (plist-get report :tp-scope-fallback)))
        (should-not
         (cl-loop for pos from (point-min) below (point-max)
                  thereis (and (not (eq (char-after pos) ?\s))
                               (get-text-property pos 'display))))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-scroll-offset-fast-path-requires-stable-marker-lengths ()
  "Scroll marker patches should not shift later buffer positions."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id scroll :content
            "x\nsubstantially longer visible line"
            :width (180) :height 1 :overflow scroll
            :scroll-offset 0))))
    (ebox-test--with-rendered-buffer layout
      (let* ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#scroll"))
             (state (ebox--scroll-get-state region-id))
             (lines (plist-get state :content-lines)))
        (should (not (= (length (nth 0 lines))
                        (length (nth 1 lines)))))
        (ebox-test--region-update region-id :scroll-offset 1)
        (let ((report (ebox-test--buffer-update-report)))
          (should-not (plist-get report :scroll-fast-path))
          (let ((state (ebox-scroll-state region-id)))
            (should (= (plist-get state :scroll-offset) 1))
            (should-not (plist-get state :lazy-scroll-prefix-dirty))
            (should-not
             (plist-get state :lazy-scroll-window-refresh-required)))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-nested-scroll-offset-transaction-replays-outer-cache ()
  "Nested scroll updates should atomically survive outer cache replay."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id root :width (180) :height 2 :overflow scroll
                (column
                 (box :id inner :width (180) :height 2 :overflow scroll
                      :content "inner 0\ninner 1\ninner 2\ninner 3")
                 (box :content "outer 0\nouter 1" :height 2)))))
        root-id inner-id)
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id (current-buffer) "#root")
            inner-id (ebox-test--selector-region-id (current-buffer) "#inner"))
      (ebox-test--region-update inner-id :scroll-offset 1)
      (let ((report (ebox-test--buffer-update-report))
            (state (ebox-scroll-state inner-id))
            (plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (= (plist-get state :scroll-offset) 1))
        (should (string-match-p "inner 1" plain))
        (should (string-match-p "inner 2" plain))
        (should-not (string-match-p "inner 0" plain)))
      (should (ebox--scroll-region-by root-id 2 48))
      (should (string-match-p
               "outer 0"
               (buffer-substring-no-properties (point-min) (point-max))))
      (should (ebox--scroll-region-by root-id -2 48))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "inner 1" plain))
        (should (string-match-p "inner 2" plain))
        (should-not (string-match-p "inner 0" plain)))
      (should (= (plist-get (ebox-scroll-state inner-id) :scroll-offset) 1))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))


(ert-deftest ebox-scroll-child-layout-window-publishes-through-tp ()
  "Child-layout scroll boxes should publish one retained viewport update."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :height 2 :overflow scroll
             (column
              (box :id "a" :content "A" :height 1)
              (box :id "b" :content "B" :height 1)
              (box :id "c" :content "C" :height 1)
              (box :id "d" :content "D" :height 1)))))
         (root-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (let* ((state (ebox--scroll-get-state root-id))
             (surface ebox-surface--buffer-surface)
             (revision (tp-surface-revision surface)))
        (should (= (plist-get state :content-height) 2))
        (should (ebox-surface-region-mounts (current-buffer) root-id))
        (should (= (ebox--scroll-region-by root-id 1) 1))
        (should (= (tp-surface-revision surface) (1+ revision))))
      (should (= (plist-get (ebox--scroll-get-state root-id)
                            :scroll-offset)
                 1))
      (let ((plain (buffer-substring-no-properties
                    (point-min) (point-max))))
        (should (= (length (ebox-string-lines plain)) 2))
        (should (string-match-p "B" plain))
        (should (string-match-p "C" plain))
        (should-not (string-match-p "A" plain)))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-scroll-child-layout-window-keeps-viewport-padding-and-border ()
  "Fast scroll window patches should keep scroll box padding and border."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :height 4 :box-sizing border-box
             :overflow scroll
             :padding-top 1 :padding-bottom 1
             :border-top-p t :border-top-color "red"
             :border-bottom-p t :border-bottom-color "blue"
             (column
              (box :id "a" :content "A" :height 1)
              (box :id "b" :content "B" :height 1)
              (box :id "c" :content "C" :height 1)
              (box :id "d" :content "D" :height 1)))))
         (root-id (car (ebox-region-ids layout)))
         )
    (ebox-test--with-rendered-buffer layout
      (should (plist-get (ebox--scroll-get-state root-id)
                         :rendered-content-lines))
      (should (ebox--scroll-region-by root-id 1))
      (should (equal (get-text-property (point-min) 'ebox-bt)
                     root-id))
      (save-excursion
        (goto-char (point-min))
        (forward-line 3)
        (should (equal (get-text-property (point) 'ebox-bb)
                       root-id)))
      (should (equal (get-text-property (point-min) 'ebox-pt)
                     root-id))
      (save-excursion
        (goto-char (point-min))
        (forward-line 3)
        (should (equal (get-text-property (point) 'ebox-pb)
                       root-id)))
      (let ((plain (buffer-substring-no-properties
                    (point-min) (point-max))))
        (should (= (length (ebox-string-lines plain)) 4))
        (should (string-match-p "B" plain))
        (should (string-match-p "C" plain))
        (should-not (string-match-p "A" plain))))))

(ert-deftest ebox-flex-row-height-update-rerenders-slot-owner-not-root ()
  "Flex row item height changes should patch the old row slot, not the root."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--dynamic-update-row-layout)))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#height"))
            (root-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox-test--region-update region-id
                            :height 4 :min-height 3 :max-height 6
                            :padding-top 1 :padding-bottom 1)
        (let ((report (ebox-test--buffer-update-report)))
          (should (memq (plist-get report :strategy)
                        '(span-patch owner-rerender)))
          (should-not (plist-get report :root-rerender))
          (should-not (member root-id (plist-get report :owner-ids)))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-flex-row-height-growth-rerenders-flex-ancestor-not-root ()
  "Flex row item growth beyond its old slot should use a flex ancestor fallback."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--dynamic-update-tight-row-layout)))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#height"))
            (root-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox-test--region-update region-id
                            :height 4 :min-height 3 :max-height 6
                            :padding-top 1 :padding-bottom 1)
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (equal (plist-get report :owner-ids) (list root-id)))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-flex-row-inline-margin-update-uses-slot-span-patch ()
  "Inline margin changes inside a stable flex row slot should stay span-local."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--dynamic-update-row-layout)))
    (ebox-test--with-rendered-buffer layout
      (let ((height-id (ebox-test--selector-region-id (current-buffer)
                                                       "#height"))
            (region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#margin"))
            (root-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox-test--region-update height-id
                            :height 4 :min-height 3 :max-height 6
                            :padding-top 1 :padding-bottom 1)
        (ebox-test--region-update region-id
                            :margin (list 0 '(8) 0 '(8))
                            :margin-inline '((8) (8))
                            :margin-block '(0 0)
                            :margin-top 0 :margin-right '(8)
                            :margin-bottom 0 :margin-left '(8))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'span-patch))
          (should (eq (plist-get report :owner-type) 'box))
          (should-not (plist-get report :root-rerender))
          (should-not (member root-id (plist-get report :owner-ids)))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-border-box-padding-impact-stays-internal-fragment ()
  "Fixed border-box padding changes should remain an internal fragment impact."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id root :width (480)
            (flex :id row :flex-flow (row nowrap) :column-gap (12)
             (box :id padding :content "padding target"
                  :width (190) :height 3 :box-sizing border-box
                  :padding (0 (8)) :border "#999999")
             (box :content "peer" :width (190) :height 3
                  :border "#999999"))))))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#padding")))
        (ebox-test--region-update region-id :padding-left (list 24))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'span-patch))
          (should (member 'internal-fragment
                          (plist-get report :impact-vector)))
          (should-not (member 'parent-layout
                              (plist-get report :impact-vector)))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-border-box-padding-shorthand-uses-one-local-span-patch ()
  "Mixed block/inline padding shorthand should not promote to a root rerender."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id root :width (480)
            (flex :id row :flex-flow (row nowrap) :column-gap (12)
             (box :id padding :content "padding target"
                  :width (190) :height 4 :box-sizing border-box
                  :padding (0 (8)) :border "#999999")
             (box :content "peer" :width (190) :height 4
                  :border "#999999"))))))
    (ebox-test--with-rendered-buffer layout
      (let* ((match (car (ebox-selector-query-buffer
                          (current-buffer) "#padding")))
             (node-id (ebox--ensure-node-id (plist-get match :node)))
             (region-id (plist-get match :region-id))
             (mixed-entry
              (list :node-id node-id :dirty-kind 'geometry
                    :changed-keys
                    '(:padding-top-height :padding-right-pixel
                      :padding-bottom-height :padding-left-pixel))))
        (should
         (ebox--dirty-entry-border-box-internal-span-p
          (current-buffer) mixed-entry))
        (ebox-test--region-update region-id :padding '(2 (20) 0 (8)))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'span-patch))
          (should (equal (plist-get report :patch-ops) '(span-patch)))
          (should-not (plist-get report :root-rerender))
          (should (member 'internal-fragment
                          (plist-get report :impact-vector)))
          (should (member 'external-footprint-proof
                          (plist-get report :impact-vector)))
          (should-not (member 'parent-layout
                              (plist-get report :impact-vector)))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-border-box-padding-span-proof-rejects-overfull-height ()
  "Border-box padding cannot claim a fixed footprint without a content line."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id padding :content "padding target"
                :width (190) :height 4 :box-sizing border-box
                :padding 2 :border "#999999"))))
    (ebox-test--with-rendered-buffer layout
      (let* ((match (car (ebox-selector-query-buffer
                          (current-buffer) "#padding")))
             (node-id (ebox--ensure-node-id (plist-get match :node))))
        (let ((entry
               (list :node-id node-id :dirty-kind 'geometry
                     :changed-keys
                     '(:padding-top-height :padding-right-pixel
                       :padding-bottom-height :padding-left-pixel))))
          (should-not
           (ebox--dirty-entry-border-box-internal-span-p
            (current-buffer) entry)))))))

(ert-deftest ebox-overflow-impact-keeps-conservative-owner-rerender ()
  "Overflow changes should stay conservative until clipping proof exists."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--dynamic-update-row-layout)))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#overflow")))
        (ebox-test--region-update region-id :overflow 'hidden)
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (member 'clipping (plist-get report :impact-vector)))
          (should (member 'external-footprint
                          (plist-get report :impact-vector)))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-owner-rerender-preserves-missing-wrapper-context ()
  "Nested owner rerenders should retain outer paint and surface metadata."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--dynamic-update-row-layout)))
    (ebox-put layout :color "#1F2328")
    (ebox-put layout :bgcolor "#FAF7F0")
    (ebox-put layout :surface-properties
              '(ebox-test-role outer-wrapper))
    (ebox-put (plist-get (car (ebox--node-children layout)) :box)
              :bgcolor "#FBF9FF")
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id
                        (current-buffer) "#overflow")))
        (ebox-test--region-update region-id :overflow 'visible)
        (should (eq (plist-get (ebox-test--buffer-update-report) :strategy)
                    'owner-rerender))
        (goto-char (point-min))
        (search-forward "overflow target")
        (let ((face (get-text-property (match-beginning 0) 'face)))
          (should (ebox-test--face-has-key-value-p
                   face :foreground "#1F2328"))
          (should (ebox-test--face-has-key-value-p
                   face :background "#FBF9FF"))
          (should
           (eq (get-text-property
                (match-beginning 0) 'ebox-test-role)
               'outer-wrapper)))))))


(ert-deftest ebox-visible-scroll-content-update-preserves-wrapper-paint ()
  "Visible cached content patches should preserve nested wrapper paint."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id "root" :height 1 :overflow scroll
            (column
             (box :id "wrapper" :height 1 :overflow scroll
                  :bgcolor "#E2E8F0"
              (column
               (box :id "target" :content "old" :width (80) :height 1
                    :border "#64748B" :bgcolor "#1D4ED8")
               (box :content "inner tail" :height 1)))
             (box :content "outer tail" :height 1))))))
    (ebox-test--with-rendered-buffer layout
      (let ((root-id (ebox-test--selector-region-id
                      (current-buffer) "#root"))
            (wrapper-id (ebox-test--selector-region-id
                         (current-buffer) "#wrapper"))
            (target-id (ebox-test--selector-region-id
                        (current-buffer) "#target")))
        (should (plist-get (ebox-scroll-state root-id)
                           :rendered-content-lines))
        (should (plist-get (ebox-scroll-state wrapper-id)
                           :rendered-content-lines))
        (ebox-test--region-update target-id :content "new")
        (let* ((report (ebox-test--buffer-update-report))
               (border-pos (text-property-any
                            (point-min) (point-max) 'ebox-bl target-id))
               (content-pos (text-property-any
                             (point-min) (point-max)
                             'ebox-content target-id))
               (border-face (and border-pos
                                 (get-text-property border-pos 'face)))
               (content-face (and content-pos
                                  (get-text-property content-pos 'face)))
               (content-face-specs
                (if (and (listp content-face)
                         (keywordp (car content-face)))
                    (list content-face)
                  content-face))
               (effective-content-background
                (cl-loop for spec in content-face-specs
                         when (and (listp spec)
                                   (plist-member spec :background))
                         return (plist-get spec :background))))
          (should (eq (plist-get report :strategy) 'span-patch))
          (should (plist-get report :scroll-state-patch))
          (should (plist-get report :runtime-published))
          (should (eq (plist-get report :tp-render-scope) 'objects))
          (should-not (plist-get report :tp-full-root))
          (should (= (plist-get report :tp-scope-range-count) 1))
          (should border-pos)
          (should content-pos)
          (should (ebox-test--face-has-key-value-p
                   border-face :background "#E2E8F0"))
          (should (member wrapper-id
                          (get-text-property
                           border-pos 'ebox-content-owners)))
          (should (ebox-test--face-has-key-value-p
                   content-face :background "#E2E8F0"))
          (should (equal effective-content-background "#1D4ED8"))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))






(ert-deftest ebox-overflow-impact-skips-span-patch-owner-probe ()
  "Clipping changes should not spend time proving impossible span patches."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--dynamic-update-row-layout)))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#overflow"))
            (span-probe-count 0)
            (original (symbol-function 'ebox--span-patchable-owner-p)))
        (cl-letf (((symbol-function 'ebox--span-patchable-owner-p)
                   (lambda (&rest args)
                     (cl-incf span-probe-count)
                     (apply original args))))
          (ebox-test--region-update region-id :overflow 'hidden))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (member 'clipping (plist-get report :impact-vector)))
          (should (= span-probe-count 0))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-overflow-impact-skips-patchable-owner-promotion ()
  "Clipping changes should not pre-prove conservative owner candidates."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--dynamic-update-row-layout)))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#overflow"))
            (promote-count 0)
            (original (symbol-function 'ebox--promote-to-patchable-owner)))
        (cl-letf (((symbol-function 'ebox--promote-to-patchable-owner)
                   (lambda (&rest args)
                     (cl-incf promote-count)
                     (apply original args))))
          (ebox-test--region-update region-id :overflow 'visible))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (member 'clipping (plist-get report :impact-vector)))
          (should (= promote-count 0))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-flex-row-visible-overflow-update-rerenders-slot-owner-not-root ()
  "Visible overflow that fits the existing flex row slot should not rerender root."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--dynamic-update-row-layout)))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#overflow"))
            (root-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox-test--region-update region-id :overflow 'visible)
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should-not (plist-get report :root-rerender))
          (should-not (member root-id (plist-get report :owner-ids)))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))
          (let* ((node (ebox--buffer-region-render-owner-node
                        (current-buffer) region-id))
                 (snapshot (ebox--ensure-layout-snapshot-spans
                            (current-buffer) (ebox--ensure-node-id node))))
            (should (ebox--layout-snapshot-spans-p snapshot))
            (should (eq (plist-get (plist-get snapshot :style-signature)
                                   :overflow)
                        'visible)))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-overflow-reversal-removes-visible-suffix ()
  "Clipping a visible target should replace the ancestor-owned old suffix."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id root :width (760)
            (flex :id matrix :width (600) :height 5
                  :flex-flow (row nowrap)
              (box :id card :width (300)
                (box :id overflow
                     :content "overflow target\nextra line\nanother line"
                     :width (280) :height 2 :overflow scroll))
              (box :id peer :content "P\nQ\nR\nS\nT"
                   :width (300) :height 5))))))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#overflow"))
            (root-id (ebox--buffer-root-node-id (current-buffer)))
            coverage-owner-id)
        (let ((full-rerenders
               (ebox-test--count-full-surface-updates
                 (ebox-test--region-update region-id :overflow 'visible)
                 (let ((report (ebox-test--buffer-update-report)))
                   (setq coverage-owner-id
                         (car (plist-get report :owner-ids)))
                   (should (eq (plist-get report :strategy) 'owner-rerender))
                   (should coverage-owner-id)
                   (should-not (equal coverage-owner-id root-id))
                   (should (eq (plist-get report :owner-type) 'flex))
                   (should (= (plist-get report :span-count) 5))
                   (should-not (plist-get report :root-rerender))
                   (should (ebox-test--buffer-visually-matches-runtime-render-p)))
                 (ebox--clear-layout-snapshots (current-buffer))
                 (ebox-test--region-update region-id :overflow 'hidden)
                 (let ((report (ebox-test--buffer-update-report))
                       (plain (buffer-substring-no-properties
                               (point-min) (point-max))))
                   (should (eq (plist-get report :strategy) 'owner-rerender))
                   (should (equal (plist-get report :owner-ids)
                                  (list coverage-owner-id)))
                   (should (= (plist-get report :span-count) 5))
                   (should-not (plist-get report :root-rerender))
                   (should-not (string-match-p "another line" plain))
                   (should (ebox-test--buffer-visually-matches-runtime-render-p))))))
          (should (= full-rerenders 0)))))))

(ert-deftest ebox-overflow-reversal-skips-layout-only-ancestor ()
  "Old visible suffix coverage should skip ancestors without wrapper ownership."
  (ebox-test--reset-runtime-state)
  (let* ((target (ebox-create :content "A\nB\nC" :height 1
                              :overflow 'visible))
         (region-id (car (ebox-region-ids target)))
         (inner (ebox-stack target (ebox-create :content "TAIL")))
         (layout (ebox-stack inner (ebox-create :content "ROOT TAIL")))
         (inner-id (ebox--ensure-node-id inner))
         (root-id (ebox--ensure-node-id layout)))
    (ebox-test--with-rendered-buffer layout
      (ebox--clear-layout-snapshots (current-buffer))
      (ebox-test--region-update region-id :overflow 'hidden)
      (let ((report (ebox-test--buffer-update-report))
            (plain (buffer-substring-no-properties
                    (point-min) (point-max))))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should-not (member inner-id (plist-get report :owner-ids)))
        (should (equal (plist-get report :owner-ids) (list root-id)))
        (should-not (string-match-p "[BC]" plain))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-overflow-reversal-skips-visible-wrapper-ancestor ()
  "A visible wrapper cannot cover its own old unowned overflow suffix."
  (ebox-test--reset-runtime-state)
  (let* ((target (ebox-create :content "A\nB\nC" :height 1
                              :overflow 'visible))
         (region-id (car (ebox-region-ids target)))
         (wrapper (ebox-create :ebox-content-node target :width '(100)
                               :height 1 :overflow 'visible))
         (layout (ebox-stack wrapper (ebox-create :content "TAIL")))
         (wrapper-id (ebox--ensure-node-id wrapper))
         (root-id (ebox--ensure-node-id layout)))
    (ebox-test--with-rendered-buffer layout
      (ebox--clear-layout-snapshots (current-buffer))
      (ebox-test--region-update region-id :overflow 'hidden)
      (let ((report (ebox-test--buffer-update-report))
            (plain (buffer-substring-no-properties
                    (point-min) (point-max))))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should-not (member wrapper-id (plist-get report :owner-ids)))
        (should (equal (plist-get report :owner-ids) (list root-id)))
        (should-not (string-match-p "[BC]" plain))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-overflow-coverage-crosses-enclosing-visible-wrapper ()
  "Coverage should climb above an enclosing visible wrapper's old footprint."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id root :width (100)
            (box :id outer :width (100) :height 2 :overflow visible
              (box :id inner :width (100)
                (box :id target :content "A\nB\nC" :height 1
                     :overflow visible)))
            (box :content "TAIL")))))
    (ebox-test--with-rendered-buffer layout
      (let* ((region-id (ebox-test--selector-region-id
                         (current-buffer) "#target"))
             (root-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox--clear-layout-snapshots (current-buffer))
        (ebox-test--region-update region-id :overflow 'hidden)
        (let ((report (ebox-test--buffer-update-report))
              (target-node
               (ebox--buffer-region-render-owner-node
                (current-buffer) region-id))
              (outer-node
               (plist-get (car (ebox-selector-query-buffer
                                (current-buffer) "#outer"))
                          :node)))
          (should (eq (ebox-get (ebox-fragment-style-source-node target-node)
                                :overflow)
                      'hidden))
          (should (eq (ebox-get (ebox-fragment-style-source-node outer-node)
                                :overflow)
                      'visible))
          (should (equal (plist-get report :owner-ids) (list root-id)))
          (should-not (plist-get report :flex-line-rerender))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-overflow-coverage-root-flex-replaces-whole-footprint ()
  "Root flex fallback should bypass line rerender for visible overflow changes."
  (dolist (transition '((scroll visible) (visible hidden)))
    (ebox-test--reset-runtime-state)
    (let* ((old-overflow (car transition))
           (new-overflow (cadr transition))
           (layout
            (ebox-build
             `(flex :id root :width (200)
               (box :id target :content "A\nB\nC" :width (80) :height 1
                    :overflow ,old-overflow)
               (box :id peer :content "P" :width (80) :height 1)))))
      (ebox-test--with-rendered-buffer layout
        (let* ((region-id (ebox-test--selector-region-id
                           (current-buffer) "#target"))
               (root-id (ebox--buffer-root-node-id (current-buffer))))
          (ebox--clear-layout-snapshots (current-buffer))
          (ebox-test--region-update region-id :overflow new-overflow)
          (let ((report (ebox-test--buffer-update-report))
                (target-node
                 (ebox--buffer-region-render-owner-node
                  (current-buffer) region-id)))
            (should (eq (ebox-get (ebox-fragment-style-source-node target-node)
                                  :overflow)
                        new-overflow))
            (should (eq (plist-get report :strategy) 'owner-rerender))
            (should (equal (plist-get report :owner-ids) (list root-id)))
            (should (ebox-test--buffer-visually-matches-runtime-render-p))))))))

(ert-deftest ebox-overflow-coverage-promotes-partial-flex-item ()
  "Visible overflow changes should not preserve a flex item's stale cross size."
  (dolist (transition '((scroll visible) (visible hidden)))
    (ebox-test--reset-runtime-state)
    (let* ((old-overflow (car transition))
           (new-overflow (cadr transition))
           (layout
            (ebox-build
             `(flex :id root :width (220)
               (box :id card :width (100)
                 (box :id target :content "A\nB\nC" :width (80) :height 1
                      :overflow ,old-overflow))
               (box :id peer :content "P" :width (80) :height 1)))))
      (ebox-test--with-rendered-buffer layout
        (let* ((region-id (ebox-test--selector-region-id
                           (current-buffer) "#target"))
               (card-id (plist-get (car (ebox-selector-query-buffer
                                         (current-buffer) "#card"))
                                   :node-id))
               (root-id (ebox--buffer-root-node-id (current-buffer))))
          (ebox--clear-layout-snapshots (current-buffer))
          (ebox-test--region-update region-id :overflow new-overflow)
          (let ((report (ebox-test--buffer-update-report))
                (target-node
                 (ebox--buffer-region-render-owner-node
                  (current-buffer) region-id)))
            (should (eq (ebox-get (ebox-fragment-style-source-node target-node)
                                  :overflow)
                        new-overflow))
            (should (eq (plist-get report :strategy) 'owner-rerender))
            (should-not (member card-id (plist-get report :owner-ids)))
            (should (equal (plist-get report :owner-ids) (list root-id)))
            (should (ebox-test--buffer-visually-matches-runtime-render-p))))))))

(ert-deftest ebox-overflow-coverage-batch-preserves-old-style ()
  "A batch should carry pre-mutation overflow into coverage planning."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id root :width (100)
            (box :id wrapper :width (100)
              (column
               (box :id target :content "A\nB\nC" :height 1
                    :overflow visible)
               (box :content "TAIL")))
            (box :content "ROOT TAIL")))))
    (ebox-test--with-rendered-buffer layout
      (let* ((region-id (ebox-test--selector-region-id
                         (current-buffer) "#target"))
             (root-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox--clear-layout-snapshots (current-buffer))
        (ebox-incremental-begin-batch (current-buffer))
        (ebox-test--region-update region-id :overflow 'hidden)
        (let* ((state (ebox-incremental--batch-state (current-buffer)))
               (pending (car (plist-get state :pending))))
          (should (equal (plist-get pending :old-style-values)
                         '(:overflow visible))))
        (ebox-incremental-flush (current-buffer))
        (let ((report (ebox-test--buffer-update-report))
              (target-node
               (ebox--buffer-region-render-owner-node
                (current-buffer) region-id)))
          (should (eq (ebox-get (ebox-fragment-style-source-node target-node)
                                :overflow)
                      'hidden))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (equal (plist-get report :owner-ids) (list root-id)))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-overflow-coverage-multi-owner-batch-normalizes-scoped-snapshots ()
  "Multiple owner replacements normalize shifted spans before scoped refresh."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id root :width (760)
            (flex :id top-matrix :width (600) :height 5
                  :flex-flow (row nowrap)
              (box :id top-card :width (300)
                (box :id top-target
                     :content "top A\nsubstantially longer top overflow\ntop C"
                     :width (280) :height 2 :overflow scroll))
              (box :content "top P\ntop Q\ntop R\ntop S\ntop T"
                   :width (300) :height 5))
            (flex :id bottom-matrix :width (600) :height 5
                  :flex-flow (row nowrap)
              (box :id bottom-card :width (300)
                (box :id bottom-target
                     :content "bottom A\nbottom overflow\nbottom C"
                     :width (280) :height 2 :overflow scroll))
              (box :content "bottom P\nbottom Q\nbottom R\nbottom S\nbottom T"
                   :width (300) :height 5))))))
    (ebox-test--with-rendered-buffer layout
      (let ((top-region-id
             (ebox-test--selector-region-id (current-buffer) "#top-target"))
            (bottom-region-id
             (ebox-test--selector-region-id
              (current-buffer) "#bottom-target")))
        (ebox-incremental-begin-batch (current-buffer))
        (ebox-test--region-update top-region-id :overflow 'visible)
        (ebox-test--region-update bottom-region-id :overflow 'visible)
        (ebox-incremental-flush (current-buffer))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (= (plist-get report :patch-count) 2))
          (should-not (plist-get report :tp-full-root))
          (should (> (plist-get report :tp-scope-count) 0))
          (should-not (plist-get report :tp-scope-fallback))
          (dolist (owner-id (plist-get report :owner-ids))
            (let* ((node (ebox--buffer-runtime-node
                          (current-buffer) owner-id))
                   (snapshot-spans
                    (plist-get (ebox--ensure-layout-snapshot-spans
                                (current-buffer) owner-id)
                               :buffer-spans))
                   (actual-spans
                    (ebox--region-set-line-spans
                     (ebox--node-all-region-ids node))))
              (should (equal snapshot-spans actual-spans))))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))
        (ebox-test--region-update bottom-region-id :overflow 'hidden)
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-span-patch-keeps-descendant-mount-snapshots-current ()
  "Ancestor updates should keep descendant snapshots aligned with TP mounts."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--dynamic-update-row-layout)))
    (ebox-test--with-rendered-buffer layout
      (let* ((handle (car (ebox-selector-query-buffer
                           (current-buffer) "#margin")))
             (region-id (plist-get handle :region-id))
             (node-id (plist-get handle :node-id)))
        (ebox-test--region-update region-id
                                  :margin (list 0 '(8) 0 '(8))
                                  :margin-inline '((8) (8))
                                  :margin-block '(0 0)
                                  :margin-top 0 :margin-right '(8)
                                  :margin-bottom 0 :margin-left '(8))
        (let* ((report (ebox-test--buffer-update-report))
               (snapshot (ebox--ensure-layout-snapshot-spans
                          (current-buffer) node-id))
               (snapshot-spans (plist-get snapshot :buffer-spans))
               (actual-spans (ebox--region-set-line-spans
                              (list region-id))))
          (should (eq (plist-get report :strategy) 'span-patch))
          (should (equal snapshot-spans actual-spans))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-sequential-sibling-span-patches-invalidate-stale-coordinates ()
  "Text-changing sibling patches should not reuse translated snapshot spans."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id root :width (120)
            (box :id a :content "A" :width (120) :height 1)
            (box :id b :content "B" :width (120) :height 1)))))
    (ebox-test--with-rendered-buffer layout
      (let* ((a-handle (car (ebox-selector-query-buffer
                             (current-buffer) "#a")))
             (b-handle (car (ebox-selector-query-buffer
                             (current-buffer) "#b")))
             (a-region-id (plist-get a-handle :region-id))
             (b-region-id (plist-get b-handle :region-id))
             (b-node-id (plist-get b-handle :node-id))
             sibling-snapshot-current-p
             reports)
        (ebox-test--region-update b-region-id :content "BB")
        (push (ebox-test--buffer-update-report) reports)
        (ebox-test--region-update a-region-id :content "AAAA")
        (push (ebox-test--buffer-update-report) reports)
        (let* ((snapshot (ebox--layout-snapshot
                          (current-buffer) b-node-id))
               (snapshot-spans (plist-get snapshot :buffer-spans))
               (actual-spans (ebox--region-set-line-spans
                              (list b-region-id))))
          (setq sibling-snapshot-current-p
                (or (not (plist-member snapshot :buffer-spans))
                    (equal snapshot-spans actual-spans))))
        (ebox-test--region-update b-region-id :content "CCC")
        (push (ebox-test--buffer-update-report) reports)
        (dolist (report reports)
          (should (eq (plist-get report :strategy) 'span-patch)))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))
        (should sibling-snapshot-current-p)))))

(ert-deftest ebox-flex-direct-item-inline-margin-rerenders-flex-owner ()
  "Direct flex item margin changes should patch the flex line owner."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(flex :id matrix :width (260) :flex-flow (row nowrap)
            :column-gap (0)
            (box :id target :content "A" :width (80) :height 1
                 :border "#999999")
            (box :id peer :content "B" :width (80) :height 1
                 :border "#999999")))))
    (ebox-test--with-rendered-buffer layout
      (let ((region-id (ebox-test--selector-region-id (current-buffer)
                                                       "#target")))
        (ebox-test--region-update region-id
                            :margin-left '(30)
                            :margin-right '(30))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (eq (plist-get report :owner-type) 'flex))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-flex-child-width-expansion-reflows-ancestor-after-span-fallback ()
  "Failed promoted span patches must fall back to a layout-safe ancestor."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(flex :id matrix :width (680) :flex-flow (row wrap)
            :column-gap (12) :row-gap 1
            (column :width (210) :border "#999999"
             (box :content "Title A" :width (190))
             (box :id target :content "width target\nmoves sibling layout"
                  :width (160) :height 3
                  :padding (0 (8)) :border "#999999"))
            (column :width (210) :border "#999999"
             (box :content "Title B" :width (190))
             (box :content "Still here" :width (190)))
            (column :width (210) :border "#999999"
             (box :content "Title C" :width (190))
             (box :content "Third card" :width (190)))))))
    (ebox-test--with-rendered-buffer layout
      (let* ((match (car (ebox-selector-query-buffer
                          (current-buffer) "#target")))
             (region-id (plist-get match :region-id)))
        (ebox-test--region-update region-id :width '(250))
        (let* ((patched (buffer-string))
               (full (ebox--with-buffer-render-context (current-buffer)
                       (ebox-render
                        (ebox--buffer-root-node (current-buffer))))))
          (should (string= (substring-no-properties patched)
                           (substring-no-properties full))))))))

(ert-deftest ebox-flex-shrunk-definite-item-content-update-keeps-current-slot ()
  "A definite 520x4 item may update inside its published shrunk slot."
  (ebox-test--reset-runtime-state)
  (let ((ebox-viewport-width 500)
        (layout
         (ebox-build
          '(flex :id root :width (500) :height 4
                 :flex-flow (row nowrap) :align-items flex-start
            (box :id fixed :content "peer" :width (320) :height 4
                 :flex-grow 0 :flex-shrink 0)
            (box :id target :content "READY" :width (520) :height 4
                 :overflow hidden :wrap-mode word)))))
    (ebox-test--with-rendered-buffer layout
      (let* ((match (car (ebox-selector-query-buffer
                          (current-buffer) "#target")))
             (region-id (plist-get match :region-id))
             (node-id (plist-get match :node-id))
             (node (ebox--buffer-runtime-node (current-buffer) node-id))
             (snapshot (ebox--ensure-layout-snapshot-details
                        (current-buffer) node-id))
             (old-widths
              (plist-get (plist-get snapshot :span-footprint-signature)
                         :line-pixel-widths)))
        (should (= (length old-widths) 4))
        (should (< (apply #'max old-widths) 520))
        ;; Flex measurement may have rendered a temporary sized copy.  Keep
        ;; this regression focused on the current-slot update contract.
        (puthash region-id node ebox--region-box-table)
        (ebox-test--region-update region-id :content "DONE")
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'span-patch))
          (should (equal (plist-get report :owner-ids) (list node-id)))
          (should-not (plist-get report :full-rerender)))
        (should (string-match-p
                 "DONE"
                 (buffer-substring-no-properties (point-min) (point-max))))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-flex-auto-size-content-update-refuses-current-slot ()
  "Auto-sized content must reflow instead of being forced into its old slot."
  (ebox-test--reset-runtime-state)
  (let ((ebox-viewport-width 300)
        (layout
         (ebox-build
          '(flex :id root :width (300) :height 1
                 :flex-flow (row nowrap) :align-items flex-start
            (box :id target :content "A" :width auto :height 1
                 :overflow hidden :wrap-mode word)
            (box :id peer :content "P" :width (40) :height 1
                 :flex-grow 0 :flex-shrink 0)))))
    (ebox-test--with-rendered-buffer layout
      (let* ((match (car (ebox-selector-query-buffer
                          (current-buffer) "#target")))
             (region-id (plist-get match :region-id))
             (node-id (plist-get match :node-id))
             (node (ebox--buffer-runtime-node (current-buffer) node-id))
             (snapshot (ebox--ensure-layout-snapshot-details
                        (current-buffer) node-id)))
        (puthash region-id node ebox--region-box-table)
        (should-not
         (ebox--render-node-in-current-flex-slot
          (current-buffer) node-id snapshot '(:content)))
        (ebox-test--region-update region-id :content "HELLO")
        (let ((report (ebox-test--buffer-update-report)))
          (should-not
           (and (eq (plist-get report :strategy) 'span-patch)
                (equal (plist-get report :owner-ids) (list node-id)))))
        (should (string-match-p
                 "HELLO"
                 (buffer-substring-no-properties (point-min) (point-max))))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-buffer-update-report-describes-span-patch ()
  "The update report should expose the actual minimal patch strategy."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Trace" :width 80 :height 1))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id :content "Patch")
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (eq (plist-get report :owner-type) 'box))
        (should-not (plist-get report :tp-full-root))
        (should (> (plist-get report :tp-scope-count) 0))
        (should (> (plist-get report :tp-operation-count) 0))
        (should (> (plist-get report :span-count) 0))
        (should (ebox-test--buffer-propertized-matches-runtime-render-p))))))

(ert-deftest ebox-buffer-update-report-describes-owner-rerender-fallback ()
  "The update report should expose geometry owner rerender fallback."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "L" :width 40))
         (right (ebox-create :content "R" :width 40))
         (layout (ebox-concat left right))
         (region-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update region-id :width '(120))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should (eq (plist-get report :owner-type) 'concat))
        (should-not (plist-get report :tp-full-root))
        (should (> (plist-get report :tp-scope-count) 0))
        (should (ebox-test--buffer-propertized-matches-runtime-render-p))))))

(ert-deftest ebox-region-update-stable-geometry-uses-span-patch ()
  "Geometry updates with stable span footprint should use the L2 planner path."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Align" :width '(120) :height 1
                           :text-align 'left))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id :text-align 'center)
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (equal (plist-get report :patch-ops) '(span-patch)))
        (should (equal (plist-get report :dirty-kinds) '(geometry)))
        (should (eq (plist-get report :owner-type) 'box))
        (should-not (plist-get report :full-rerender))))))

(ert-deftest ebox-region-update-parent-layout-change-keeps-owner-rerender ()
  "Geometry updates that move siblings should not be forced into span-patch."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "L" :width '(40)))
         (right (ebox-create :content "R" :width '(40)))
         (layout (ebox-concat left right))
         (region-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update region-id :width '(120))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should (equal (plist-get report :patch-ops) '(owner-rerender)))
        (should (eq (plist-get report :owner-type) 'concat))
        (should-not (plist-get report :full-rerender))))))

(ert-deftest ebox-region-update-inline-child-stable-geometry-uses-span-patch ()
  "Stable internal changes inside an inline child should not rerender siblings."
  (ebox-test--reset-runtime-state)
  (let* ((left (ebox-create :content "Left" :width '(80) :height 1
                            :text-align 'left))
         (right (ebox-create :content "Right" :width '(80) :height 1))
         (layout (ebox-concat left right))
         (left-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (ebox-test--region-update left-id :text-align 'center)
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (equal (plist-get report :patch-ops) '(span-patch)))
        (should (eq (plist-get report :owner-type) 'box))
        (should-not (plist-get report :tp-full-root))
        (should (> (plist-get report :tp-scope-count) 0)))
      (should (string-match-p
               "Right"
               (buffer-substring-no-properties (point-min) (point-max))))
      (should (ebox-test--buffer-propertized-matches-runtime-render-p)))))

(ert-deftest ebox-region-update-border-box-inline-change-uses-span-patch ()
  "Border-box left/right spacing can be internal when outer width is fixed."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Pad" :width '(120) :height 1
                           :box-sizing 'border-box))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id :padding-left-pixel 8)
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (equal (plist-get report :patch-ops) '(span-patch)))
        (should-not (plist-get report :full-rerender))))))

(ert-deftest ebox-region-update-content-box-inline-change-rerenders-owner ()
  "Content-box left/right spacing changes the parent-facing outer width."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Pad" :width '(120) :height 1
                           :box-sizing 'content-box))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id :padding-left-pixel 8)
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should (equal (plist-get report :patch-ops) '(owner-rerender)))
        (should-not (plist-get report :full-rerender))))))

(ert-deftest ebox-flex-item-box-sizing-update-rerenders-contained-flex ()
  "Changing a flex item's box model should rerun its parent's placement."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id root :width (760)
            (flex :id outer :width (600) :height 5 :flex-flow (row nowrap)
              (box :id card :width (300)
                (flex :id inner :width (300) :height 5
                      :padding (0 (10)) :border "#6F6A95"
                      :justify-content center :align-items center
                  (box :id target :content "A\nB"
                       :width (230) :height 3 :padding (0 (10))
                       :border "#999999" :box-sizing content-box)))
              (box :id peer :content "P\nQ\nR\nS\nT"
                   :width (300) :height 5))))))
    (ebox-test--with-rendered-buffer layout
      (let* ((region-id
              (ebox-test--selector-region-id (current-buffer) "#target"))
             (target-node
              (ebox--buffer-region-render-owner-node
               (current-buffer) region-id))
             (flex-id
              (ebox--runtime-parent-id
               (current-buffer) (ebox--ensure-node-id target-node)))
             (root-id (ebox--buffer-root-node-id (current-buffer))))
        (ebox-test--region-update region-id :box-sizing 'border-box)
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'owner-rerender))
          (should (equal (plist-get report :owner-ids) (list flex-id)))
          (should (eq (plist-get report :owner-type) 'flex))
          (should (= (plist-get report :span-count) 5))
          (should-not (member root-id (plist-get report :owner-ids)))
          (should-not (plist-get report :tp-full-root))
          (should-not (plist-get report :tp-scope-fallback))
          (should (ebox-test--buffer-visually-matches-runtime-render-p)))))))

(ert-deftest ebox-flex-item-block-size-updates-use-fixed-containment-owner ()
  "Block-size updates should skip flex-slot proof below fixed containment."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(column :id root :width (760)
            (flex :id outer :width (600) :height 5 :flex-flow (row nowrap)
              (box :id card :width (300)
                (flex :id inner :width (300) :height 5
                      :padding (0 (10)) :border "#6F6A95"
                      :justify-content center :align-items center
                  (box :id target :content "A\nB\nC\nD"
                       :width (230) :height 2 :overflow scroll
                       :padding (0 (10)) :border "#999999")))
              (box :id peer :content "P\nQ\nR\nS\nT"
                   :width (300) :height 5))))))
    (ebox-test--with-rendered-buffer layout
      (let* ((region-id
              (ebox-test--selector-region-id (current-buffer) "#target"))
             (target-node
              (ebox--buffer-region-render-owner-node
               (current-buffer) region-id))
             (flex-id
              (ebox--runtime-parent-id
               (current-buffer) (ebox--ensure-node-id target-node)))
             (root-id (ebox--buffer-root-node-id (current-buffer)))
             (slot-proof-count 0)
             (original-slot-proof
              (symbol-function 'ebox--flex-item-slot-footprint-safe-p)))
        (cl-letf (((symbol-function 'ebox--flex-item-slot-footprint-safe-p)
                   (lambda (&rest args)
                     (cl-incf slot-proof-count)
                     (apply original-slot-proof args))))
          (dolist (change '((:height 4) (:min-height 3) (:max-height 1)))
            (ebox-test--region-update region-id (car change) (cadr change))
            (let ((report (ebox-test--buffer-update-report)))
              (should (memq (plist-get report :strategy)
                            '(span-patch owner-rerender)))
              (should (equal (plist-get report :owner-ids) (list flex-id)))
              (should (eq (plist-get report :owner-type) 'flex))
              (should (= (plist-get report :span-count) 5))
              (should-not (member root-id (plist-get report :owner-ids)))
              (should (ebox-test--buffer-visually-matches-runtime-render-p)))))
        (should (= slot-proof-count 0))))))

(ert-deftest ebox-region-update-span-candidate-falls-back-on-wrap-change ()
  "A wrap-changing update should publish a correct scoped TP plan."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "abcdefghijklmnopqrstuvwxyz"
                           :width '(120)
                           :box-sizing 'border-box
                           :wrap-mode 'char))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id :padding-left-pixel 100)
      (let ((report (ebox-test--buffer-update-report)))
        (should (memq (plist-get report :strategy)
                      '(span-patch owner-rerender)))
        (should-not (plist-get report :tp-full-root))
        (should (> (plist-get report :tp-scope-count) 0))
        (should-not (plist-get report :tp-scope-fallback))
        (should (ebox-test--buffer-propertized-matches-runtime-render-p))))))

(ert-deftest ebox-region-update-matrix-covers-all-box-longhands ()
  "The update tests should classify every non-content box longhand."
  (let ((covered (append (ebox-test--region-update-case-properties
                          ebox-test--region-update-paint-cases)
                         (ebox-test--region-update-case-properties
                          ebox-test--region-update-geometry-cases))))
    (should-not (cl-set-difference ebox--region-update-longhand-props
                                   covered
                                   :test #'eq))
    (should-not (cl-set-difference covered
                                   ebox--region-update-longhand-props
                                   :test #'eq))
    (should-not (cl-set-difference ebox--paint-style-signature-keys
                                   (ebox-test--region-update-case-properties
                                    ebox-test--region-update-paint-cases)
                                   :test #'eq))))

(ert-deftest ebox-region-update-all-paint-longhands-use-paint-patch ()
  "Every paint longhand should patch text properties without replacing spans."
  (dolist (case ebox-test--region-update-paint-cases)
    (pcase-let ((`(,property ,value ,expected) case))
      (ert-info ((format "property %S" property))
        (ebox-test--reset-runtime-state)
        (let* ((box (ebox-create :content "Paint" :width '(120)
                                 :height 1))
               (region-id (car (ebox-region-ids box))))
          (ebox-test--with-rendered-buffer box
            (let ((full-rerenders
                   (ebox-test--count-full-surface-updates
                     (ebox-test--region-update region-id property value))))
              (should (= full-rerenders 0)))
            (let ((runtime-box
                   (gethash region-id (ebox--buffer-region-box-table
                                       (current-buffer)))))
              (should (eq (gethash region-id ebox--region-box-table)
                          runtime-box))
              (should-not (eq runtime-box box))
              (should (equal (ebox-get runtime-box property) expected)))
            (let ((report (ebox-test--buffer-update-report)))
              (should (eq (plist-get report :strategy) 'paint-patch))
              (should (equal (plist-get report :patch-ops)
                             '(paint-patch)))
              (should (equal (plist-get report :dirty-kinds) '(paint)))
              (should-not (plist-get report :full-rerender)))))))))

(ert-deftest ebox-region-update-all-geometry-longhands-use-minimal-strategy ()
  "Every geometry longhand should use a correct scoped non-root strategy."
  (dolist (case ebox-test--region-update-geometry-cases)
    (pcase-let ((`(,property ,value ,expected ,_strategy) case))
      (ert-info ((format "property %S" property))
        (ebox-test--reset-runtime-state)
        (let* ((box (ebox-create :content "Alpha\nBeta\nGamma\nDelta"
                                 :width '(160)
                                 :height 2
                                 :overflow 'scroll
                                 :wrap-mode 'word))
               (region-id (car (ebox-region-ids box))))
          (ebox-test--with-rendered-buffer box
            (let ((full-rerenders
                   (ebox-test--count-full-surface-updates
                     (ebox-test--region-update region-id property value))))
              (should (= full-rerenders 0)))
            (let ((runtime-box
                   (gethash region-id (ebox--buffer-region-box-table
                                       (current-buffer)))))
              (should (eq (gethash region-id ebox--region-box-table)
                          runtime-box))
              (should-not (eq runtime-box box))
              (should (equal (ebox-get runtime-box property) expected)))
            (let ((report (ebox-test--buffer-update-report)))
              (should (memq (plist-get report :strategy)
                            '(span-patch owner-rerender)))
              (should (equal (plist-get report :dirty-kinds) '(geometry)))
              (should (eq (plist-get report :owner-type) 'box))
              (should-not (plist-get report :tp-full-root))
              (should (> (plist-get report :tp-scope-count) 0))
              (should-not (plist-get report :tp-scope-fallback))
              (should (ebox-test--buffer-propertized-matches-runtime-render-p)))))))))

(ert-deftest ebox-bgcolor-update-mutates-box-and-keeps-content ()
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Color" :width 60 :bgcolor "#111111"))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id :bgcolor "#222222")
      (should (equal (ebox-get box :bgcolor) "#111111"))
      (should (equal (ebox-get (gethash region-id
                                        (ebox--buffer-region-box-table
                                         (current-buffer)))
                               :bgcolor)
                     "#222222"))
      (should (string-match-p
               "Color"
               (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest ebox-background-color-creation-matches-bgcolor-updates ()
  "Background color spellings should share one engine longhand and paint path."
  (ebox-test--reset-runtime-state)
  (let* ((background-box
          (ebox-create :content "Color" :width 60
                       :background-color "#111111"))
         (bgcolor-box
          (ebox-create :content "Color" :width 60 :bgcolor "#111111"))
         (background-face
          (ebox-test--first-content-face (ebox-render background-box)))
         (bgcolor-face
          (ebox-test--first-content-face (ebox-render bgcolor-box))))
    (should (equal (ebox-get background-box :bgcolor) "#111111"))
    (should (equal (ebox-get bgcolor-box :bgcolor) "#111111"))
    (should-not (plist-member background-box :background-color))
    (should (equal background-face bgcolor-face))
    (should (ebox-test--face-has-key-value-p
             background-face :background "#111111"))
    (let ((region-id (car (ebox-region-ids background-box))))
      (ebox-test--with-rendered-buffer background-box
        (ebox-test--region-update region-id :background-color "#222222")
        (let ((runtime-box
               (gethash region-id (ebox--buffer-region-box-table
                                   (current-buffer)))))
          (should (equal (ebox-get background-box :bgcolor) "#111111"))
          (should (equal (ebox-get runtime-box :bgcolor) "#222222"))
          (should-not (plist-member runtime-box :background-color)))
        (should-not (plist-member background-box :background-color))
        (should (ebox-test--face-has-key-value-p
                 (ebox-test--first-content-face (buffer-string))
                 :background "#222222"))
        (let ((report (ebox-test--buffer-update-report)))
          (should (eq (plist-get report :strategy) 'paint-patch))
          (should (equal (plist-get report :patch-ops) '(paint-patch)))
          (should (equal (plist-get report :dirty-kinds) '(paint)))
          (should-not (plist-get report :full-rerender)))))))

(ert-deftest ebox-vertical-align-middle-alias-matches-center ()
  "Creation and updates should normalize middle to center before rendering."
  (ebox-test--reset-runtime-state)
  (let ((middle (ebox-create :content "X" :height 3
                             :vertical-align 'middle)))
    (should (equal (ebox--expand-property :vertical-align 'middle)
                   '(:vertical-align center)))
    (should (eq (ebox-get middle :vertical-align) 'center))
    (should (= (cl-position-if
                (lambda (line)
                  (string-match-p "X" (substring-no-properties line)))
                (ebox-string-lines (ebox-render middle)))
               1))
    (let* ((updated (ebox-create :content "X" :height 3
                                 :vertical-align 'top))
           (region-id (car (ebox-region-ids updated))))
      (ebox-test--with-rendered-buffer updated
        (goto-char (point-min))
        (search-forward "X")
        (should (= (line-number-at-pos (match-beginning 0)) 1))
        (ebox-test--region-update region-id :vertical-align 'middle)
        (should (eq (ebox-get updated :vertical-align) 'top))
        (should (eq (ebox-get (gethash region-id
                                       (ebox--buffer-region-box-table
                                        (current-buffer)))
                              :vertical-align)
                    'center))
        (goto-char (point-min))
        (search-forward "X")
        (should (= (line-number-at-pos (match-beginning 0)) 2))
        (should (eq (plist-get (ebox-test--buffer-update-report) :strategy)
                    'span-patch))
        (should (ebox-test--buffer-visually-matches-runtime-render-p))))))

(ert-deftest ebox-update-reuses-shorthand-property-expansion ()
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Box" :width 60))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id
                          :padding '(1 2)
                          :border '(2 "#abcdef")
                          :margin-inline 3)
      (let ((runtime-box
             (gethash region-id (ebox--buffer-region-box-table
                                 (current-buffer)))))
        (should (= (ebox-get box :padding-top-height) 0))
        (should (= (ebox-get runtime-box :padding-top-height) 1))
        (should (= (ebox-get runtime-box :padding-right-pixel)
                   (* 2 (ebox--space-pixel-width))))
        (should (= (ebox-get runtime-box :border-left-pixel)
                   (* 2 (ebox--space-pixel-width))))
        (should (equal (ebox-get runtime-box :border-right-color) "#abcdef"))
        (should (= (ebox-get runtime-box :margin-left-pixel)
                   (* 3 (ebox--space-pixel-width))))))))

(ert-deftest ebox-region-update-adds-absent-shorthand-properties-incrementally ()
  "Shorthand updates should locate the same box and patch without root rebuilds."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Absent properties" :width '(160)))
         (region-id (car (ebox-region-ids box)))
         (ids-before (ebox-region-ids box)))
    (ebox-test--with-rendered-buffer box
      (let ((full-rerenders
             (ebox-test--count-full-surface-updates
               (ebox-test--region-update region-id
                                   :padding '(1 2)
                                   :border '(1 "#abcdef")
                                   :margin-inline 3))))
        (should (= full-rerenders 0)))
      (let ((runtime-box
             (gethash region-id (ebox--buffer-region-box-table
                                 (current-buffer)))))
        (should (eq (gethash region-id ebox--region-box-table)
                    runtime-box))
        (should-not (eq runtime-box box))
        (should (equal (ebox-region-ids box) ids-before))
        (should (= (ebox-get box :padding-top-height) 0))
        (should (= (ebox-get box :padding-right-pixel) 0))
        (should (= (ebox-get box :border-left-pixel) 0))
        (should (null (ebox-get box :border-right-color)))
        (should (= (ebox-get box :margin-left-pixel) 0))
        (should (= (ebox-get runtime-box :padding-top-height) 1))
        (should (= (ebox-get runtime-box :padding-right-pixel)
                   (* 2 (ebox--space-pixel-width))))
        (should (= (ebox-get runtime-box :border-left-pixel)
                   (ebox--space-pixel-width)))
        (should (equal (ebox-get runtime-box :border-right-color) "#abcdef"))
        (should (= (ebox-get runtime-box :margin-left-pixel)
                   (* 3 (ebox--space-pixel-width)))))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should (equal (plist-get report :patch-ops)
                       '(owner-rerender)))
        (should-not (plist-get report :full-rerender)))
      (let ((full-rerenders
             (ebox-test--count-full-surface-updates
               (ebox-test--region-update region-id
                                   :background-color "#fed7aa"))))
        (should (= full-rerenders 0)))
      (should (null (ebox-get box :bgcolor)))
      (should (equal (ebox-get (gethash region-id
                                        (ebox--buffer-region-box-table
                                         (current-buffer)))
                               :bgcolor)
                     "#fed7aa"))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'paint-patch))
        (should (equal (plist-get report :patch-ops)
                       '(paint-patch)))
        (should-not (plist-get report :full-rerender))))))

(ert-deftest ebox-color-and-visibility-are-real-and-display-is-ignored ()
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Paint"
                           :color "#eeeeee"
                           :display 'none
                           :visibility 'hidden))
         (region-id (car (ebox-region-ids box))))
    (should (equal (ebox-get box :color) "#eeeeee"))
    (should (equal (ebox--computed-display box) '(block flow)))
    (should (eq (ebox-get box :visibility) 'hidden))
    (ebox-test--with-rendered-buffer box
      ;; Hidden at mount: the text is present but carries no face ink.
      (let ((position (string-match
                       "Paint"
                       (buffer-substring-no-properties (point-min)
                                                       (point-max)))))
        (should position)
        (should-not (get-text-property (+ (point-min) position) 'face)))
      (ebox-test--region-update region-id
                          :color "#123456"
                          :display 'block
                          :visibility 'visible)
      (let ((runtime-box
             (gethash region-id (ebox--buffer-region-box-table
                                 (current-buffer)))))
        (should (equal (ebox-get box :color) "#eeeeee"))
        (should (equal (ebox-get runtime-box :color) "#123456"))
        (should (eq (ebox-get runtime-box :visibility) 'visible)))
      (should (equal (ebox--computed-display box) '(block flow)))
      (should (eq (ebox-get box :visibility) 'hidden))
      (let ((position (string-match
                       "Paint"
                       (buffer-substring-no-properties (point-min)
                                                       (point-max)))))
        (should position)
        (should (get-text-property (+ (point-min) position) 'face))))))

(ert-deftest ebox-row-column-and-spacer-compose-layouts ()
  (ebox-test--reset-runtime-state)
  (let* ((a (ebox-create :content "A" :width 40))
         (b (ebox-create :content "B" :width 40))
         (c (ebox-create :content "C" :width 40))
         (row (ebox-row a nil b c))
         (column (ebox-column a b nil c))
         (spacer (ebox-spacer :width 20 :height 2)))
    (should (equal (ebox-region-ids row) '(1 2 3)))
    (should (equal (ebox-region-ids column) '(1 2 3)))
    (should (eq (plist-get spacer :ebox-type) 'box))
    (should (string-match-p "A.*B.*C"
                            (substring-no-properties (ebox-render row))))
    (should (string-match-p "A[^\n]*\nB[^\n]*\nC"
                            (substring-no-properties (ebox-render column))))))

(ert-deftest ebox-row-and-column-store-children-as-flat-containers ()
  "Row and column should be one container node with direct children."
  (ebox-test--reset-runtime-state)
  (let* ((children (cl-loop for label in '("A" "B" "C" "D")
                            collect (ebox-create :content label :width 40)))
         (row (apply #'ebox-row children))
         (column (apply #'ebox-column children)))
    (should (= (length (ebox--node-children row)) 4))
    (should (= (length (ebox--node-children column)) 4))
    (should (= (length (ebox--runtime-node-ids row)) 5))
    (should (= (length (ebox--runtime-node-ids column)) 5))))

(ert-deftest ebox-overflow-hidden-clips-extra-content-lines ()
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC"
                           :height 1
                           :overflow 'hidden))
         (plain (substring-no-properties (ebox-render box))))
    (should (string-match-p "A" plain))
    (should-not (string-match-p "B" plain))
    (should-not (string-match-p "C" plain))
    (should (= (ebox-string-height plain) 1))))

(ert-deftest ebox-overflow-visible-appends-extra-content-lines ()
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC"
                           :height 1
                           :overflow 'visible))
         (plain (substring-no-properties (ebox-render box))))
    (should (string-match-p "A" plain))
    (should (string-match-p "B" plain))
    (should (string-match-p "C" plain))
    (should (= (ebox-string-height plain) 3))))

(defun ebox-test--assert-visible-overflow-paint
    (rendered foreground background)
  "Assert RENDERED keeps visible overflow painted but unowned."
  (let* ((lines (ebox-string-lines rendered))
         (body (car lines))
         (overflow-lines (cdr lines))
         (ownership-properties
          (append '(ebox-content-idx ebox-content-owners)
                  (mapcar #'cdr ebox-region-types)))
         (body-pos (cl-position ?A body)))
    (should (= (length lines) 3))
    (should (integerp body-pos))
    (let ((body-face (get-text-property body-pos 'face body)))
      (should (ebox-test--face-has-key-value-p
               body-face :foreground foreground))
      (should (ebox-test--face-has-key-value-p
               body-face :background background)))
    (cl-loop for line in overflow-lines
             for glyph in '(?B ?C)
             do
             (let ((glyph-pos (cl-position glyph line)))
               (should (integerp glyph-pos))
               (should (ebox-test--face-has-key-value-p
                        (get-text-property glyph-pos 'face line)
                        :foreground foreground)))
             (dolist (offset-pos (list 0 (1- (length line))))
               (should (get-text-property offset-pos 'display line))
               (should-not
                (ebox-test--face-has-key-p
                 (get-text-property offset-pos 'face line)
                 :foreground)))
             (dotimes (pos (length line))
               (should-not
                (ebox-test--face-has-key-p
                 (get-text-property pos 'face line)
                 :background))
               (dolist (property ownership-properties)
                 (should-not (get-text-property pos property line)))))))

(ert-deftest ebox-overflow-visible-paints-foreground-without-ownership ()
  "Visible overflow should inherit only the outer box foreground."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC"
                           :width '(40)
                           :height 1
                           :overflow 'visible
                           :color "#abcdef"
                           :bgcolor "#123456"
                           :padding-inline '(6)
                           :margin-inline '(4))))
    (ebox-test--assert-visible-overflow-paint
     (ebox-render box) "#abcdef" "#123456")))

(ert-deftest ebox-region-update-refreshes-visible-overflow-foreground ()
  "Color updates should refresh visible overflow without owning its suffix."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC"
                           :width '(40)
                           :height 1
                           :overflow 'visible
                           :color "#abcdef"
                           :bgcolor "#123456"
                           :padding-inline '(6)
                           :margin-inline '(4)))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id :color "#fedcba")
      (ebox-test--assert-visible-overflow-paint
       (buffer-string) "#fedcba" "#123456"))))

(ert-deftest ebox-owner-rerender-keeps-visible-overflow-unowned ()
  "Owner rerenders should not restore box ownership to visible overflow."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC"
                           :width '(40)
                           :height 1
                           :overflow 'scroll
                           :color "#abcdef"
                           :bgcolor "#123456"))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (ebox-test--region-update region-id :overflow 'visible)
      (should (eq (plist-get (ebox-test--buffer-update-report) :strategy)
                  'owner-rerender))
      (goto-char (point-min))
      (search-forward "C")
      (let* ((pos (match-beginning 0))
             (face (get-text-property pos 'face)))
        (should (ebox-test--face-has-key-value-p
                 face :foreground "#abcdef"))
        (should-not (ebox-test--face-has-key-value-p
                     face :background "#123456"))
        (should-not (get-text-property pos 'ebox-content-owner))
        (should-not (get-text-property pos 'ebox-content-owners))))))

(ert-deftest ebox-overflow-scroll-keeps-window-height-and-state ()
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC"
                           :height 1
                           :overflow 'scroll))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "A" plain))
        (should-not (string-match-p "B" plain))
        (should (= (ebox-string-height plain) 1)))
      (should (equal (plist-get (ebox--scroll-get-state region-id)
                                :content-height)
                     1))
      (goto-char (point-min))
      (ebox-scroll-down 1)
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "B" plain))
        (should-not (string-match-p "A" plain))
        (should (= (ebox-string-height plain) 1))))))

(ert-deftest ebox-scroll-falls-back-when-region-cannot-scroll ()
  "Scroll commands should let the buffer move when the box has no scroll work."
  (ebox-test--reset-runtime-state)
  (with-temp-buffer
    (insert (ebox-render (ebox-create :content "short" :height 1)))
    (insert "\n")
    (dotimes (index 40)
      (insert (format "tail-%02d\n" index)))
    (goto-char (point-min))
    (should (get-text-property (point) 'ebox-content))
    (let (fallback-called)
      (cl-letf (((symbol-function 'scroll-up)
                 (lambda (&optional _arg)
                   (setq fallback-called t))))
        (ebox-scroll-down 1))
      (should fallback-called))))

(ert-deftest ebox-scroll-bubbles-from-child-to-scrollable-ancestor ()
  "Key scrolling over a child box should scroll the nearest scrollable ancestor."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height 2 :overflow scroll
                        (column
                         (box :id "child" :content "A" :height 1)
                         (box :content "B" :height 1)
                         (box :content "C" :height 1)))))
         (ids (ebox-region-ids layout))
         (root-id (car ids)))
    (ebox-test--with-rendered-buffer layout
      (goto-char (point-min))
      (search-forward "A")
      (backward-char)
      (should-not (equal (get-text-property (point) 'ebox-content)
                         root-id))
      (let (fallback-called)
        (cl-letf (((symbol-function 'scroll-up)
                   (lambda (&optional _arg)
                     (setq fallback-called t))))
          (ebox-scroll-down 1))
        (should-not fallback-called))
      (should (= (plist-get (ebox--scroll-get-state root-id)
                            :scroll-offset)
                 1))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "B" plain))
        (should (string-match-p "C" plain))))))

(ert-deftest ebox-wheel-scroll-falls-back-to-default-mwheel ()
  "Mouse wheel fallback should preserve Emacs' normal scroll behavior."
  (ebox-test--reset-runtime-state)
  (let (mwheel-args scroll-up-called)
    (cl-letf (((symbol-function 'mwheel-scroll)
               (lambda (&rest args)
                 (setq mwheel-args args)))
              ((symbol-function 'scroll-up)
               (lambda (&optional _arg)
                 (setq scroll-up-called t))))
      (ebox--wheel-scroll 'fake-wheel-event 1 'fake-arg))
    (should (equal mwheel-args '(fake-wheel-event fake-arg)))
    (should-not scroll-up-called)))

(ert-deftest ebox-wheel-scroll-falls-back-for-non-scrollable-region ()
  "Mouse wheel over a normal box should keep default buffer scrolling."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "short" :height 1))
         (region-id (car (ebox-region-ids box)))
         mwheel-args)
    (ebox-test--with-rendered-buffer box
      (cl-letf (((symbol-function 'ebox--wheel-region-ids)
                 (lambda (_event) (list region-id)))
                ((symbol-function 'mwheel-scroll)
                 (lambda (&rest args)
                   (setq mwheel-args args))))
        (ebox--wheel-scroll 'fake-wheel-event 1 'fake-arg))
      (should (equal mwheel-args '(fake-wheel-event fake-arg))))))

(ert-deftest ebox-wheel-scroll-consumes-scrollable-region ()
  "Mouse wheel should still scroll an overflow='scroll box when it can."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC"
                           :height 1
                           :overflow 'scroll))
         (region-id (car (ebox-region-ids box)))
         mwheel-called)
    (ebox-test--with-rendered-buffer box
      (cl-letf (((symbol-function 'ebox--wheel-region-ids)
                 (lambda (_event) (list region-id)))
                ((symbol-function 'mwheel-scroll)
                 (lambda (&rest _args)
                   (setq mwheel-called t))))
        (ebox--wheel-scroll 'fake-wheel-event 1))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "B" plain))
        (should-not (string-match-p "A" plain)))
      (should-not mwheel-called))))

(ert-deftest ebox-wheel-scroll-bubbles-from-child-to-scrollable-ancestor ()
  "Mouse wheel scrolling over a child box should scroll its scrollable ancestor."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height 2 :overflow scroll
                        (column
                         (box :id "child" :content "A" :height 1)
                         (box :content "B" :height 1)
                         (box :content "C" :height 1)))))
         (ids (ebox-region-ids layout))
         (root-id (car ids))
         (child-id (cadr ids))
         mwheel-called)
    (ebox-test--with-rendered-buffer layout
      (cl-letf (((symbol-function 'ebox--wheel-region-ids)
                 (lambda (_event) (list child-id root-id)))
                ((symbol-function 'mwheel-scroll)
                 (lambda (&rest _args)
                   (setq mwheel-called t))))
        (ebox--wheel-scroll 'fake-wheel-event 1))
      (should-not mwheel-called)
      (should (= (plist-get (ebox--scroll-get-state root-id)
                            :scroll-offset)
                 1))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "B" plain))
        (should (string-match-p "C" plain))))))

(ert-deftest ebox-scroll-state-is-created-only-for-scrollable-boxes ()
  "Non-overflowing boxes should not inflate the global scroll hit-test table."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(column
                    (box :id "short-a" :content "A" :height 1)
                    (box :id "short-b" :content "B" :height 1)
                    (box :id "root" :height 1 :overflow scroll
                         (column
                          (box :content "C" :height 1)
                          (box :content "D" :height 1))))))
         root-id short-a-id short-b-id)
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id (current-buffer) "#root"))
      (setq short-a-id (ebox-test--selector-region-id (current-buffer)
                                                      "#short-a"))
      (setq short-b-id (ebox-test--selector-region-id (current-buffer)
                                                      "#short-b"))
      (should-not (ebox--scroll-get-state short-a-id))
      (should-not (ebox--scroll-get-state short-b-id))
      (should (ebox--scroll-get-state root-id)))))

(ert-deftest ebox-scroll-hit-test-uses-owner-stack-before-mount-lookup ()
  "Wheel hit testing should avoid TP mount lookup when owners suffice."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height 1 :overflow scroll
                        (column
                         (box :id "child" :content "A" :height 1)
                         (box :content "B" :height 1)))))
         (root-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (goto-char (point-min))
      (cl-letf (((symbol-function 'ebox--scroll-region-ids-in-mounts-at-pos)
                 (lambda (&rest _args)
                   (error "unexpected mount lookup"))))
        (should (member root-id
                        (ebox--scroll-region-ids-at-pos (point))))))))

(ert-deftest ebox-chrome-free-scroll-render-reuses-propertized-prefix-lines ()
  "A chrome-free scroll box should not propertize its visible prefix twice."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "row-1\nrow-2\nrow-3"
                           :width 120
                           :height 2
                           :overflow 'scroll
                           :color "#112233"
                           :bgcolor "#ddeeff"))
         (region-id (ebox--ensure-region-id box))
         (reference (ebox-create :content "row-1\nrow-2\nrow-3"
                                 :width 120
                                 :height 2
                                 :overflow 'hidden
                                 :color "#112233"
                                 :bgcolor "#ddeeff"))
         (original (symbol-function 'ebox--propertize-content-line))
         (root-propertize-count 0)
         actual)
    (plist-put reference :region-id region-id)
    (cl-letf (((symbol-function 'ebox--propertize-content-line)
               (lambda (line owner idx fallback)
                 (when (equal owner region-id)
                   (cl-incf root-propertize-count))
                 (funcall original line owner idx fallback))))
      (setq actual (ebox-render box)))
    (should (= root-propertize-count 3))
    (should-not
     (text-property-not-all 0 (length actual)
                            'ebox-scroll-window region-id actual))
    (let ((actual-without-window-tag (copy-sequence actual)))
      (remove-text-properties
       0 (length actual-without-window-tag)
       '(ebox-scroll-window nil)
       actual-without-window-tag)
      (should (equal-including-properties
               actual-without-window-tag
               (ebox-render reference))))))

(ert-deftest ebox-underfilled-chrome-free-scroll-fuses-line-finishing-passes ()
  "A complete top-aligned underfill should keep exact output in one line pass."
  (ebox-test--reset-runtime-state)
  (let* ((content
          (concat (propertize "alpha" 'face '(:weight bold)
                              'help-echo "rich")
                  "\n \nomega"))
         (box (ebox-create :content content
                           :width 140
                           :height 5
                           :overflow 'scroll
                           :vertical-align 'top
                           :color "#112233"
                           :bgcolor "#ddeeff"))
         (region-id (ebox--ensure-region-id box))
         (reference (ebox-create :content content
                                 :width 140
                                 :height 5
                                 :overflow 'hidden
                                 :vertical-align 'top
                                 :color "#112233"
                                 :bgcolor "#ddeeff"))
         (expected (progn
                     (plist-put reference :region-id region-id)
                     (ebox-render reference)))
         (original-align (symbol-function 'ebox--lines-align-vertical))
         (original-maplines (symbol-function 'ebox--maplines))
         (align-calls 0)
         (mapline-calls 0)
         actual)
    (cl-letf (((symbol-function 'ebox--lines-align-vertical)
               (lambda (&rest args)
                 (cl-incf align-calls)
                 (apply original-align args)))
              ((symbol-function 'ebox--maplines)
               (lambda (&rest args)
                 (cl-incf mapline-calls)
                 (apply original-maplines args))))
      (setq actual (ebox-render box)))
    (should (= align-calls 0))
    ;; Formatting may still justify the source once; finishing must not add
    ;; the former blank-normalization and color map passes.
    (should (<= mapline-calls 1))
    (should (equal-including-properties actual expected))
    (should-not (ebox--scroll-get-state region-id))))



(ert-deftest ebox-lazy-scroll-rendered-window-uses-preformatted-lines ()
  "Lazy scroll windows should not rebuild visible content lines per tick."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (let ((state (ebox--scroll-get-state root-id)))
              (should (plist-get state :rendered-content-lines))
              (should (plist-get state :render-content-prefix)))
            (let* ((surface ebox-surface--buffer-surface)
                   (revision (tp-surface-revision surface)))
              (should (ebox--scroll-region-by root-id 8))
              (should (= (tp-surface-revision surface) (1+ revision))))
            (let ((state (ebox--scroll-get-state root-id)))
              (should (= (plist-get state :scroll-offset) 8))
              (should (plist-get state :rendered-content-lines)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-after-viewport-resize-keeps-window-range ()
  "Viewport resize must preserve lazy scroll's fixed viewport fast path."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(column :id "viewport" :width (viewport)
                    :height (viewport-height)
             (box :content "" :width (viewport) :height 1)
             (box :id "root" :width (viewport)
                  :height (- (viewport-height) 2)
                  :overflow scroll
              (column :width (viewport) :padding (1 (8))
               ,@(cl-loop for idx below 80
                          collect
                          `(box :content ,(format "row %02d" idx)
                                :width (viewport)
                                :height 1)))
             (box :content "" :width (viewport) :height 1)))))
         buffer
         root-id
         mount-bounds
         mount-line-count
         (materialize-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 12)
              (ebox-wheel-smooth-scroll-lines-per-tick 4)
              (ebox-wheel-smooth-scroll-interval 60.0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (ebox-rerender-buffer-with-context buffer 320 14)
          (with-current-buffer buffer
            (let ((state (ebox--scroll-get-state root-id)))
              (setq mount-bounds
                    (ebox-surface-region-bounds buffer root-id))
              (should mount-bounds)
              (setq mount-line-count
                    (count-lines (car mount-bounds) (cdr mount-bounds)))
              (ert-info ((format "state=%S"
                                 (list :content-height
                                       (plist-get state :content-height)
                                       :content-lines
                                       (length (plist-get state
                                                          :content-lines))
                                       :rendered-lines
                                       (length (plist-get state
                                                          :rendered-content-lines)))))
                (should (= (plist-get state :content-height) 12)))
              (when-let ((materialize
                          (plist-get state :materialize-content-lines)))
                (plist-put
                 state :materialize-content-lines
                 (lambda (&rest args)
                   (cl-incf materialize-count)
                   (apply materialize args)))
                (puthash root-id state ebox--scroll-global-state)))
            (should (ebox--smooth-scroll-region-by root-id 16))
            (while (gethash root-id ebox--smooth-scroll-state-table)
              (ebox--smooth-scroll-tick root-id))
            (let ((current-bounds
                   (ebox-surface-region-bounds buffer root-id)))
              (should current-bounds)
              (should (= mount-line-count
                         (count-lines (car current-bounds)
                                      (cdr current-bounds)))))
            (should (= materialize-count 0))))
      (when root-id
        (ebox--smooth-scroll-stop root-id))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-offset-viewport-resize-stays-lazy ()
  "Viewport resize after scrolling should not materialize all hidden content."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(column :id "viewport" :width (viewport)
                    :height (viewport-height)
             (box :content "" :width (viewport) :height 1)
             (box :id "root" :width (viewport)
                  :height (- (viewport-height) 2)
                  :overflow scroll
              (column :width (viewport) :padding (1 (8))
               ,@(cl-loop for idx below 80
                          collect
                          `(box :content ,(format "offset row %02d" idx)
                                :width (viewport)
                                :height 1)))
             (box :content "" :width (viewport) :height 1)))))
         buffer
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 12)
              (ebox-scroll-lazy-idle-prefetch-lines 0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (with-current-buffer buffer
            (should (ebox--scroll-region-by root-id 16)))
          (ebox-rerender-buffer-with-context buffer 320 14)
          (let ((state (ebox--scroll-get-state root-id)))
            (should (= (plist-get state :scroll-offset) 16))
            (should (plist-get state :render-content-prefix))
            (should (plist-get state :materialize-content-lines))
            (should (< (length (plist-get state :content-lines)) 80))
            (should (>= (length (plist-get state :content-lines))
                        (+ (plist-get state :scroll-offset)
                           (plist-get state :content-height))))))
      (when root-id
        (ebox--smooth-scroll-stop root-id))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-intrinsic-measurement-skips-window-source ()
  "Flex intrinsic measurement should not render lazy scroll window content."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport)
                 :height (- (viewport-height) 2)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :content ,(format "measurement row %02d" idx)
                               :width (viewport)
                               :height 1))))))
         (calls 0)
         rendered)
    (cl-letf (((symbol-function 'ebox--render-scroll-window-source)
               (lambda (&rest _args)
                 (cl-incf calls)
                 (list :lines nil :complete nil :cache nil))))
      (let ((ebox-viewport-width 240)
            (ebox-viewport-height 12)
            (ebox--intrinsic-layout-measurement t))
        (setq rendered (ebox-render layout)))
      (should (= calls 0))
      (should (= (ebox-string-height rendered) 10))
      (let ((ebox-viewport-width 240)
            (ebox-viewport-height 12)
            (ebox--intrinsic-layout-measurement nil))
        (ebox-render layout))
      (should (= calls 1)))))

(ert-deftest ebox-lazy-scroll-sync-prefix-does-not-require-idle-prefetch ()
  "Interactive scrolling should extend a lazy prefix even with idle prefetch off."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport)
                 :height (- (viewport-height) 10)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :content ,(format "sync row %02d" idx)
                               :width (viewport)
                               :height 1))))))
         buffer
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 20)
              (ebox-scroll-step 4)
              (ebox-scroll-lazy-idle-prefetch-lines 0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((before (ebox--scroll-get-state root-id))
                 (initial-lines (length (plist-get before :content-lines)))
                 (content-height (plist-get before :content-height))
                 (boundary-offset (- initial-lines content-height)))
            (should (> boundary-offset 0))
            (with-current-buffer buffer
              (should (= boundary-offset
                         (ebox--scroll-region-by root-id
                                                 boundary-offset)))))
          (with-current-buffer buffer
            (should (= 4 (ebox--scroll-region-by root-id 4))))
          (let ((after (ebox--scroll-get-state root-id)))
            (should (> (plist-get after :scroll-offset) 4))
            (should (>= (length (plist-get after :content-lines))
                        (+ (plist-get after :scroll-offset)
                           (plist-get after :content-height))))
            (should-not (plist-get after :content-lines-complete-p))))
      (when root-id
        (ebox--smooth-scroll-stop root-id))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-gui-cache-miss-returns-pending ()
  "GUI scroll cache misses should not synchronously render missing content."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport)
                 :height (- (viewport-height) 10)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :content ,(format "gui row %02d" idx)
                               :width (viewport)
                               :height 1))))))
         buffer
         root-id
         (prefix-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 20)
              (ebox-scroll-step 4)
              (ebox-scroll-lazy-idle-prefetch-lines 0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (noninteractive nil))
          (cl-letf (((symbol-function 'display-graphic-p)
                     (lambda (&optional _display) t)))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout))
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (let* ((state (ebox--scroll-get-state root-id))
                   (render-prefix (plist-get state :render-content-prefix))
                   (initial-lines (length (plist-get state :content-lines)))
                   (content-height (plist-get state :content-height))
                   (boundary-offset (- initial-lines content-height)))
              (plist-put
               state :render-content-prefix
               (lambda (&rest args)
                 (cl-incf prefix-count)
                 (apply render-prefix args)))
              (puthash root-id state ebox--scroll-global-state)
              (with-current-buffer buffer
                (should (= boundary-offset
                           (ebox--scroll-region-by root-id
                                                   boundary-offset)))
                (should (eq 'pending
                            (ebox--scroll-region-by root-id 4)))))
            (should (= prefix-count 0))))
      (when root-id
        (ebox--smooth-scroll-stop root-id))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-explicit-budget-syncs-prefix-in-gui ()
  "A caller-provided prefix budget should synchronously extend GUI lazy scrolls."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport)
                 :height (- (viewport-height) 10)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :content ,(format "budget row %02d" idx)
                               :width (viewport)
                               :height 1))))))
         buffer
         root-id
         (prefix-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 20)
              (ebox-scroll-step 4)
              (ebox-scroll-lazy-idle-prefetch-lines 0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (noninteractive nil))
          (cl-letf (((symbol-function 'display-graphic-p)
                     (lambda (&optional _display) t)))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout))
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (let* ((state (ebox--scroll-get-state root-id))
                   (render-prefix (plist-get state :render-content-prefix))
                   (initial-lines (length (plist-get state :content-lines)))
                   (content-height (plist-get state :content-height))
                   (boundary-offset (- initial-lines content-height)))
              (plist-put
               state :render-content-prefix
               (lambda (&rest args)
                 (cl-incf prefix-count)
                 (apply render-prefix args)))
              (puthash root-id state ebox--scroll-global-state)
              (with-current-buffer buffer
                (should (= boundary-offset
                           (ebox--scroll-region-by root-id
                                                   boundary-offset)))
                (should (= 4 (ebox--scroll-region-by root-id 4 4)))))
            (should (= prefix-count 1))))
      (when root-id
        (ebox--smooth-scroll-stop root-id))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))


(ert-deftest ebox-lazy-scroll-prefix-reuses-viewport-dependent-flex-leaves ()
  "Lazy prefix extension should not rerender prior viewport flex leaves."
  (ebox-test--reset-runtime-state)
  (let* ((flex-section
          (lambda (label)
            `(flex :width (viewport) :flex-flow (row wrap)
                   ,@(cl-loop for idx below 4
                              collect
                              `(box :content ,(format "%s-%d" label idx)
                                    :width (110)
                                    :height 1)))))
         (layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,(funcall flex-section "a")
              (spacer :height 1)
              ,(funcall flex-section "b")))))
         (buffer nil)
         root-id
         (flex-render-count 0)
         (original-render-flex (symbol-function 'ebox--render-flex)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-wheel-scroll-step 0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (let ((state (ebox--scroll-get-state root-id)))
              (should (= (length (plist-get state :content-lines)) 3))
              (should (plist-get state :render-content-prefix)))
            (cl-letf (((symbol-function 'ebox--render-flex)
                       (lambda (&rest args)
                         (cl-incf flex-render-count)
                         (apply original-render-flex args))))
              (should (ebox--scroll-region-by root-id 3)))
            (should (<= flex-render-count 1))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-flex-prefix-renders-only-needed-rows ()
  "Lazy scroll prefixes should not render hidden row-wrap flex rows."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              (box :id "head" :content "head" :width (viewport) :height 1)
              (flex :width (viewport) :flex-flow (row wrap)
                    :row-gap 0 :column-gap 0
                    ,@(cl-loop for idx below 12
                               collect
                               `(box :id ,(format "item-%02d" idx)
                                     :content ,(format "item %02d" idx)
                                     :width (100) :height 2)))))))
         (buffer nil)
         (hidden-render-count 0)
         (original-render-box (symbol-function 'ebox--render-box)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 1)
              (ebox-wheel-scroll-step 0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (cl-letf (((symbol-function 'ebox--render-box)
                     (lambda (box)
                       (when-let ((id (and (listp box) (ebox-get box :id))))
                         (when (and (string-prefix-p "item-" id)
                                    (>= (string-to-number
                                         (substring id (length "item-")))
                                        4))
                           (cl-incf hidden-render-count)))
                       (funcall original-render-box box))))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout)))
          (should (= hidden-render-count 0)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-flex-window-lines-match-full-render-prefix ()
  "Partial flex window rendering should match the full render prefix."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :width (240) :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  :padding (0 (8)) :border "#D97757"
                  :border-top-p nil :bgcolor "#FFF8F2"
                  ,@(cl-loop for idx below 6
                             collect
                             `(box :id ,(format "prefix-item-%02d" idx)
                                   :content ,(format "prefix %02d" idx)
                                   :width (100) :height 2)))))
         (limit 4)
         (_index (ebox--runtime-index node t))
         (full-lines
          (let ((ebox--surface-materialization-active t))
            (ebox-string-lines (ebox--render-layout node))))
         (window (ebox--render-flex-window-lines node limit)))
    (should-not (plist-get window :complete))
    (should (equal (mapcar #'substring-no-properties
                           (seq-take full-lines limit))
                   (mapcar #'substring-no-properties
                           (plist-get window :lines))))))

(ert-deftest ebox-flex-window-shrinks-definite-wrapping-items ()
  "Window prefix rendering must not freeze shrinkable definite widths."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :width (160) :flex-flow (row wrap)
             (box :id "shrink-a" :content "alpha beta gamma delta"
                  :width (200) :height 2)
             (box :id "shrink-b" :content "second row content"
                  :width (160) :height 2))))
         (limit 2)
         (full-lines (ebox-string-lines (ebox-render node)))
         (window (ebox--render-flex-window-lines node limit)))
    ;; A nil window means the full-render fallback takes over, which is
    ;; also correct.  Produced window lines must match the full
    ;; renderer's prefix geometry instead of freezing the declared
    ;; 200px width inside the 160px container.
    (when window
      (should (equal (mapcar #'ebox--string-pixel-width
                             (seq-take full-lines limit))
                     (mapcar #'ebox--string-pixel-width
                             (plist-get window :lines)))))))

(ert-deftest ebox-flex-window-char-wrapper-falls-back-to-full-prefix ()
  "Char-wrapped flex prefixes should use the full-render fallback."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :width (100) :wrap-mode char :flex-flow (row wrap)
                  :row-gap 0 :column-gap 0
                  ,@(cl-loop for char across "ABCD"
                             collect
                             `(box :content ,(char-to-string char)
                                   :width (150) :height 1)))))
         (full-lines (ebox-string-lines (ebox-render node)))
         (expected-signatures
          (mapcar #'ebox-test--visual-line-signature
                  (seq-take full-lines 3)))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (first (ebox--render-stack-window-lines node 1))
         (extended
          (ebox--render-stack-window-lines
           node 3 (plist-get first :cache)))
         (producer (ebox--render-node-window-lines node 3))
         (actual-signatures
          (mapcar #'ebox-test--visual-line-signature
                  (plist-get extended :lines))))
    (should (equal expected-signatures actual-signatures))
    (should-not producer)))

(ert-deftest ebox-flex-window-aligned-wrapper-falls-back-to-full-prefix ()
  "Non-left-aligned flex prefixes should use the full-render fallback."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :width (100) :text-align center :flex-flow (row wrap)
                  :row-gap 0 :column-gap 0
                  ,@(cl-loop for char across "ABCDEF"
                             collect
                             `(box :content ,(char-to-string char)
                                   :width (50) :height 1)))))
         (full-lines (ebox-string-lines (ebox-render node)))
         (expected-signatures
          (mapcar #'ebox-test--visual-line-signature
                  (seq-take full-lines 3)))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (first (ebox--render-stack-window-lines node 1))
         (extended
          (ebox--render-stack-window-lines
           node 3 (plist-get first :cache)))
         (producer (ebox--render-node-window-lines node 3))
         (actual-signatures
          (mapcar #'ebox-test--visual-line-signature
                  (plist-get extended :lines))))
    (should (equal expected-signatures actual-signatures))
    (should-not producer)))

(ert-deftest ebox-flex-window-lines-use-chunk-wrapper-for-first-prefix ()
  "A seedless flex prefix should avoid the generic full wrapper renderer."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :id "flex-window-wrapper" :width (240)
                  :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  :padding (0 (8)) :border "#D97757"
                  :border-top-p nil :bgcolor "#FFF8F2"
                  ,@(cl-loop for idx below 8
                             collect
                             `(box :content ,(format "wrapper %02d" idx)
                                   :width (100) :height 2)))))
         (full-lines (ebox-string-lines (ebox-render node)))
         (full-wrapper-count 0)
         (chunk-wrapper-count 0)
         (multiline-horizontal-concat-count 0)
         (original-full-wrapper
          (symbol-function 'ebox--flex-window-render-box-lines))
         (original-chunk-wrapper
          (symbol-function 'ebox--flex-window-render-wrapper-chunk-lines))
         (original-horizontal-concat
          (symbol-function 'ebox--lines-concat-horizontal)))
    (cl-letf (((symbol-function 'ebox--flex-window-render-box-lines)
               (lambda (&rest args)
                 (cl-incf full-wrapper-count)
                 (apply original-full-wrapper args)))
              ((symbol-function 'ebox--flex-window-render-wrapper-chunk-lines)
               (lambda (&rest args)
                 (cl-incf chunk-wrapper-count)
                 (apply original-chunk-wrapper args)))
              ((symbol-function 'ebox--lines-concat-horizontal)
               (lambda (&rest args)
                 (cl-incf multiline-horizontal-concat-count)
                 (apply original-horizontal-concat args))))
      (let* ((ebox--surface-materialization-active t)
             (window (ebox--render-flex-window-lines node 4)))
        (should window)
        (should-not (plist-get window :complete))
        (should (= (length (plist-get window :lines)) 4))
        (should
         (ebox-test--rendered-visually-equal-p
          (ebox-lines-join (seq-take full-lines 4))
          (ebox-lines-join (plist-get window :lines))))))
    (should (= full-wrapper-count 0))
    (should (= chunk-wrapper-count 1))
    (should (= multiline-horizontal-concat-count 0))))

(ert-deftest ebox-flex-window-lines-use-chunk-wrapper-for-first-completion ()
  "A compatible seedless completion should avoid the generic full wrapper."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :id "flex-window-complete-wrapper" :width (240)
                  :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  :padding (0 (8)) :border "#D97757"
                  :border-top-p nil :bgcolor "#FFF8F2"
                  ,@(cl-loop for idx below 4
                             collect
                             `(box :content ,(format "complete %02d" idx)
                                   :width (100) :height 2)))))
         (_index (ebox--runtime-index node t))
         (full
          (let ((ebox--surface-materialization-active t))
            (ebox--render-layout node)))
         (full-wrapper-count 0)
         (chunk-wrapper-count 0)
         (original-full-wrapper
          (symbol-function 'ebox--flex-window-render-box-lines))
         (original-chunk-wrapper
          (symbol-function 'ebox--flex-window-render-wrapper-chunk-lines)))
    (cl-letf (((symbol-function 'ebox--flex-window-render-box-lines)
               (lambda (&rest args)
                 (cl-incf full-wrapper-count)
                 (apply original-full-wrapper args)))
              ((symbol-function 'ebox--flex-window-render-wrapper-chunk-lines)
               (lambda (&rest args)
                 (cl-incf chunk-wrapper-count)
                 (apply original-chunk-wrapper args))))
      (let* ((ebox--surface-materialization-active t)
             (window (ebox--render-flex-window-lines node 8)))
        (should window)
        (should (plist-get window :complete))
        (should
         (equal-including-properties
          full
          (ebox-lines-join (plist-get window :lines))))))
    (should (= full-wrapper-count 0))
    (should (= chunk-wrapper-count 1))))

(ert-deftest ebox-flex-flat-wrapper-owns-color-copy-in-place ()
  "Flat flex wrappers should decorate one private line copy per source line."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :width 120
                           :padding-left 8
                           :padding-right 8
                           :border-left 1
                           :border-right 1
                           :border-color "#D97757"
                           :bgcolor "#FFF8F2"))
         (source (propertize "child" 'ebox-content 77
                            'ebox-content-owner 77
                            'ebox-content-owners '(77)))
         (source-before (copy-sequence source))
         (expected
          (ebox--flex-window-render-wrapper-chunk-lines
           box (list source) 0 t))
         (copying-owner-count 0)
         (original-copying-owner
          (symbol-function 'ebox--add-content-owner))
         actual)
    (cl-letf (((symbol-function 'ebox--add-content-owner)
               (lambda (&rest args)
                 (cl-incf copying-owner-count)
                 (apply original-copying-owner args))))
      (setq actual
            (ebox--flex-window-render-wrapper-chunk-lines
             box (list source) 0 t)))
    (should (equal-including-properties source source-before))
    (should
     (equal-including-properties
      (ebox-lines-join actual)
      (ebox-lines-join expected)))
    (should (= copying-owner-count 0))))

(ert-deftest ebox-flex-window-lines-reuses-render-cache ()
  "Repeated flex window renders should reuse the render cache."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
         `(flex :width (240) :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  ,@(cl-loop for idx below 8
                             collect
                             `(box :id ,(format "cache-item-%02d" idx)
                                   :content ,(format "cache %02d" idx)
                                   :width (100) :height 2)))))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (row-render-count 0)
         (original-render-row-line
          (symbol-function 'ebox--flex-render-row-line)))
    (cl-letf (((symbol-function 'ebox--flex-render-row-line)
               (lambda (&rest args)
                 (cl-incf row-render-count)
                 (apply original-render-row-line args))))
      (should (ebox--render-flex-window-lines node 4))
      (let ((after-first row-render-count))
        (should (> after-first 0))
        (should (ebox--render-flex-window-lines node 4))
        (should (= row-render-count after-first))))))

(ert-deftest ebox-flex-window-lines-reuses-node-cache-signature ()
  "One flex window render should not repeatedly compute the node signature."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :width (240) :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  ,@(cl-loop for idx below 8
                             collect
                             `(box :id ,(format "sig-item-%02d" idx)
                                   :content ,(format "sig %02d" idx)
                                   :width (100) :height 2)))))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
         (signature-count 0)
         (original-signature
          (symbol-function 'ebox--render-cache-node-signature)))
    (cl-letf (((symbol-function 'ebox--render-cache-node-signature)
               (lambda (&rest args)
                 (when (eq (car args) node)
                   (cl-incf signature-count))
                 (apply original-signature args))))
      (should (ebox--render-flex-window-lines node 4)))
    (should (<= signature-count 2))))

(ert-deftest ebox-flex-window-prefix-extension-reuses-wrapper-lines ()
  "Extending a flex prefix should not rerender prior wrapper lines."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :id "flex-prefix-wrapper" :width (240)
                  :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  :padding (0 (8)) :border "#D97757"
                  :border-top-p nil :bgcolor "#FFF8F2"
                  ,@(cl-loop for idx below 8
                             collect
                             `(box :content ,(format "extend %02d" idx)
                                   :width (100) :height 2)))))
         (full-lines (mapcar #'substring-no-properties
                             (ebox-string-lines (ebox-render node))))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (generic-wrapper-render-count 0)
         (original-render-box (symbol-function 'ebox--render-box)))
    (cl-letf (((symbol-function 'ebox--render-box)
               (lambda (box)
                 (when (equal (and (listp box) (ebox-get box :id))
                              "flex-prefix-wrapper")
                   (cl-incf generic-wrapper-render-count))
                 (funcall original-render-box box))))
      (should (ebox--render-flex-window-lines node 4))
      (should (= generic-wrapper-render-count 0))
      (let ((window (ebox--render-flex-window-lines node 8)))
        (should window)
        (should (= generic-wrapper-render-count 0))
        (should (equal (seq-take full-lines 8)
                       (mapcar #'substring-no-properties
                               (plist-get window :lines))))))))

(ert-deftest ebox-flex-window-prefix-extension-joins-only-new-pieces ()
  "Extending a flex prefix should not rejoin the whole cached prefix."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :width (240) :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  :padding (0 (8)) :border "#D97757"
                  :border-top-p nil :bgcolor "#FFF8F2"
                  ,@(cl-loop for idx below 16
                             collect
                             `(box :content ,(format "piece %02d" idx)
                                   :width (100) :height 2)))))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         join-piece-counts
         (original-join-pieces
          (symbol-function 'ebox--flex-window-lines-from-pieces)))
    (cl-letf (((symbol-function 'ebox--flex-window-lines-from-pieces)
               (lambda (pieces)
                 (push (length pieces) join-piece-counts)
                 (funcall original-join-pieces pieces))))
      (should (ebox--render-flex-window-lines node 4))
      (setq join-piece-counts nil)
      (should (ebox--render-flex-window-lines node 8)))
    (should join-piece-counts)
    (should-not (cl-some (lambda (count) (> count 4))
                         join-piece-counts))))

(ert-deftest ebox-flex-window-complete-prefix-defers-bottom-wrapper ()
  "A complete flex source should not full-render bottom chrome before LIMIT."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :id "flex-complete-prefix" :width (240)
                  :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  :padding (0 (8) 2 (8))
                  :margin-bottom 2
                  :border "#D97757"
                  :border-top-p nil
                  :bgcolor "#FFF8F2"
                  ,@(cl-loop for idx below 2
                             collect
                             `(box :content ,(format "complete %02d" idx)
                                   :width (100) :height 8)))))
         (limit 4)
         (full-lines (mapcar #'substring-no-properties
                             (ebox-string-lines (ebox-render node))))
         (complete-wrapper-count 0)
         (original-render-box-lines
          (symbol-function 'ebox--flex-window-render-box-lines)))
    (cl-letf (((symbol-function 'ebox--flex-window-render-box-lines)
               (lambda (node content complete limit)
                 (when complete
                   (cl-incf complete-wrapper-count))
                 (funcall original-render-box-lines
                          node content complete limit))))
      (let ((window (ebox--render-flex-window-lines node limit)))
        (should window)
        (should-not (plist-get window :complete))
        (should (= complete-wrapper-count 0))
        (should (equal (seq-take full-lines limit)
                       (mapcar #'substring-no-properties
                               (plist-get window :lines))))))))

(ert-deftest ebox-flex-window-complete-extension-appends-bottom-border ()
  "Completing a cached flex prefix should append bottom border without full render."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :id "flex-complete-border" :width (240)
                  :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  :padding (0 (8))
                  :border "#D97757"
                  :border-top-p nil
                  :bgcolor "#FFF8F2"
                  ,@(cl-loop for idx below 4
                             collect
                             `(box :content ,(format "border %02d" idx)
                                   :width (100) :height 2)))))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (full-lines (mapcar #'substring-no-properties
                             (ebox-string-lines (ebox-render node))))
         (complete-wrapper-count 0)
         (original-render-box-lines
          (symbol-function 'ebox--flex-window-render-box-lines)))
    (should (ebox--render-flex-window-lines node 4))
    (cl-letf (((symbol-function 'ebox--flex-window-render-box-lines)
               (lambda (node content complete limit)
                 (when complete
                   (cl-incf complete-wrapper-count))
                 (funcall original-render-box-lines
                          node content complete limit))))
      (let ((window (ebox--render-flex-window-lines node 8)))
        (should window)
        (should (plist-get window :complete))
        (should (= complete-wrapper-count 0))
        (should (equal (seq-take full-lines 8)
                       (mapcar #'substring-no-properties
                               (plist-get window :lines))))))))

(ert-deftest ebox-flex-window-failed-completion-keeps-prefix-cache-atomic ()
  "A failed flex completion should not publish half-appended cache lists."
  (ebox-test--reset-runtime-state)
  (let* ((node
          (ebox-build
           `(flex :id "flex-atomic-prefix" :width (240)
                  :flex-flow (row wrap)
                  :row-gap 1 :column-gap 0
                  :padding (0 (8))
                  :border "#D97757"
                  :border-top-p nil
                  ,@(cl-loop for idx below 4
                             collect
                             `(box :content ,(format "atomic %02d" idx)
                                   :width (100) :height 2)))))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (context (ebox--flex-window-cache-context node)))
    (should (ebox--render-flex-window-lines node 4))
    (let* ((before (ebox--flex-window-prefix-cache-lookup node context))
           (before-lines (plist-get before :lines))
           (before-content-lines (plist-get before :content-lines))
           (before-line-count (plist-get before :line-count))
           (before-content-count (plist-get before :content-line-count)))
      (cl-letf (((symbol-function 'ebox--flex-window-complete-tail-line)
                 (lambda (&rest _)
                   (error "injected flex completion failure"))))
        (should-error (ebox--render-flex-window-lines node 8)))
      (let ((after (ebox--flex-window-prefix-cache-lookup node context)))
        (should (eq before-lines (plist-get after :lines)))
        (should (eq before-content-lines
                    (plist-get after :content-lines)))
        (should (= before-line-count (length before-lines)))
        (should (= before-content-count (length before-content-lines)))
        (should (= (plist-get after :line-count)
                   (length (plist-get after :lines))))
        (should (= (plist-get after :content-line-count)
                   (length (plist-get after :content-lines)))))
      (should (plist-get (ebox--render-flex-window-lines node 8)
                         :complete)))))

(ert-deftest ebox-stack-window-completion-reconciles-declared-prefix-tail ()
  "A completed leaf should refresh declared chrome on its cached tail."
  (ebox-test--reset-runtime-state)
  (let* ((type 'ebox-test-completing-window)
         (leaf (list :ebox-type type))
         (stack (list :ebox-type 'stack :children (list leaf)))
         (plain-tail (propertize "tail" 'face '(:foreground "red")))
         (complete-tail
          (ebox--propertize-underline
           (copy-sequence plain-tail) "blue")))
    (unwind-protect
        (progn
          (ebox--register-window-line-renderer
           type
           (lambda (_node limit)
             (if (< limit 3)
                 (list :lines (list "head" plain-tail)
                       :complete nil)
               (list :lines (list "head" complete-tail)
                     :complete t
                     :completion-prefix-tail-rewrite-count 1))))
          (let* ((prefix (ebox--render-stack-window-lines stack 2))
                 (completed
                  (ebox--render-stack-window-lines
                   stack 3 (plist-get prefix :cache)))
                 (tail (cadr (plist-get completed :lines)))
                 (face (get-text-property 0 'face tail))
                 (delta (plist-get completed :prefix-delta)))
            (should (plist-get completed :complete))
            (should (= (length (plist-get completed :lines)) 2))
            (should (plist-get delta :exact-p))
            (should (= (plist-get delta :base-count) 2))
            (should (equal (plist-get delta :rewrite-range) '(1 . 2)))
            (should
             (ebox-test--face-has-key-value-p
              face :underline '(:position t :color "blue")))))
      (remhash type ebox--window-line-renderer-table))))

(ert-deftest ebox-stack-window-invalid-completion-rewrite-rebuilds-prefix ()
  "Invalid completion metadata should discard a potentially stale prefix."
  (ebox-test--reset-runtime-state)
  (dolist (metadata '(3 -1 invalid missing))
    (let* ((type 'ebox-test-invalid-completing-window)
           (leaf (list :ebox-type type))
           (stack (list :ebox-type 'stack :children (list leaf)))
           (plain-tail "tail")
           (complete-tail
            (ebox--propertize-underline "tail" "blue"))
           (calls 0))
      (unwind-protect
          (progn
            (ebox--register-window-line-renderer
             type
             (lambda (_node limit)
               (cl-incf calls)
               (if (< limit 3)
                   (list :lines (list "head" plain-tail)
                         :complete nil)
                 (append
                  (list :lines (list "head" complete-tail)
                        :complete t)
                  (unless (eq metadata 'missing)
                    (list :completion-prefix-tail-rewrite-count
                          metadata))))))
            (let* ((prefix (ebox--render-stack-window-lines stack 2))
                   (completed
                    (ebox--render-stack-window-lines
                     stack 3 (plist-get prefix :cache)))
                   (tail (cadr (plist-get completed :lines)))
                   (face (get-text-property 0 'face tail))
                   (delta (plist-get completed :prefix-delta)))
              (should (= calls 3))
              (should-not (plist-get delta :exact-p))
              (should
               (ebox-test--face-has-key-value-p
                face :underline '(:position t :color "blue")))))
        (remhash type ebox--window-line-renderer-table)))))

(ert-deftest ebox-flex-window-completion-tail-metadata-is-border-specific ()
  "Only an existing bottom-border line should request a prefix rewrite."
  (ebox-test--reset-runtime-state)
  (should
   (= 1
      (ebox--flex-window-completion-prefix-tail-rewrite-count
       (list :box (ebox-create :border-bottom-p t
                               :padding-bottom 0)))))
  (should
   (= 1
      (ebox--flex-window-completion-prefix-tail-rewrite-count
       (list :box (ebox-create :border-bottom-p t
                               :padding-bottom 0
                               :margin-bottom 2)))))
  (should
   (= 0
      (ebox--flex-window-completion-prefix-tail-rewrite-count
       (list :box (ebox-create :border-bottom-p t
                               :padding-bottom 2)))))
  (should
   (= 0
      (ebox--flex-window-completion-prefix-tail-rewrite-count
       (list :box (ebox-create :border-bottom-p nil
                               :padding-bottom 0))))))

(ert-deftest ebox-flex-window-cache-rejects-short-incomplete-exact-hit ()
  "An underfilled exact-limit cache must resume from its prefix seed."
  (ebox-test--reset-runtime-state)
  (let* ((lines (cl-loop repeat 112 collect "line"))
         (entry (list :lines lines
                      :line-count 112
                      :line-tail (last lines)
                      :complete nil))
         looked-up-keys)
    (cl-letf (((symbol-function 'ebox--render-cache-lookup)
               (lambda (key _signature)
                 (push key looked-up-keys)
                 (cond
                  ((equal key '(7 flex-window prefix)) entry)
                  ((equal key '(7 flex-window 118)) entry)))))
      (should-not
       (ebox--flex-window-cache-lookup
        :test-node 118 '(:node-id 7 :signature test-signature))))
    (should (member '(7 flex-window 118) looked-up-keys))))

(ert-deftest ebox-byte-compiled-scroll-window-binds-wrapper-viewport ()
  "Compiled lazy rendering must dynamically bind the wrapper content width."
  (ebox-test--reset-runtime-state)
  (let* ((wrapper (ebox-create :content "" :width '(278) :wrap-mode nil))
         (source (list :stack :test-stack :wrapper wrapper))
         observed-viewport)
    (cl-letf (((symbol-function 'ebox--render-stack-window-lines)
               (lambda (&rest _args)
                 (setq observed-viewport ebox-viewport-width)
                 (throw 'viewport-observed nil))))
      (let ((ebox-viewport-width 900))
        (catch 'viewport-observed
          (ebox--render-scroll-window-source source 1))))
    (should (= observed-viewport 278))))

(ert-deftest ebox-scroll-window-wrapper-applies-declared-prefix-rewrite ()
  "Wrapper prefix reuse should rerender only a declared changed range."
  (ebox-test--reset-runtime-state)
  (let* ((wrapper (ebox-create :content "" :width 20 :wrap-mode nil))
         (source (list :stack :test-stack :wrapper wrapper))
         (plain-tail "tail")
         (complete-tail
          (ebox--propertize-underline "tail" "blue"))
         (stack-lines (list plain-tail))
         (calls 0)
         (second-call-line-count 0)
         (original-chunk-renderer
          (symbol-function
           'ebox--scroll-window-render-wrapper-chunk-lines)))
    (cl-letf (((symbol-function 'ebox--render-stack-window-lines)
               (lambda (&rest _args)
                 (cl-incf calls)
                 (if (= calls 1)
                     (list :lines stack-lines
                           :line-count 1
                           :line-tail stack-lines
                           :complete nil
                           :cache :first
                           :prefix-delta
                           '(:exact-p nil :base-count 0
                             :rewrite-range nil
                             :rewrite-lines nil
                             :append-lines nil))
                   (setcar stack-lines complete-tail)
                   (list :lines stack-lines
                         :line-count 1
                         :line-tail stack-lines
                         :complete nil
                         :cache :second
                         :prefix-delta
                         (list :exact-p t :base-count 1
                               :rewrite-range '(0 . 1)
                               :rewrite-lines (list complete-tail)
                               :append-lines nil)))))
              ((symbol-function
                'ebox--scroll-window-render-wrapper-chunk-lines)
               (lambda (&rest args)
                 (when (= calls 2)
                   (cl-incf second-call-line-count
                            (length (cadr args))))
                 (apply original-chunk-renderer args)))
              ((symbol-function 'equal-including-properties)
               (lambda (&rest _)
                 (ert-fail "wrapper reuse scanned the whole prefix"))))
      (let* ((prefix (ebox--render-scroll-window-source source 1))
             (extended
              (ebox--render-scroll-window-source
               source 2 (plist-get prefix :cache)))
             (line (car (plist-get extended :lines)))
             (face (get-text-property 0 'face line))
             (delta (plist-get extended :prefix-delta)))
        (should (= calls 2))
        (should (= second-call-line-count 1))
        (should (plist-get delta :exact-p))
        (should (= (plist-get delta :base-count) 1))
        (should (equal (plist-get delta :rewrite-range) '(0 . 1)))
        (should
         (ebox-test--face-has-key-value-p
          face :underline '(:position t :color "blue")))))))

(ert-deftest ebox-scroll-window-wrapper-maps-top-chrome-rewrite-ranges ()
  "Wrapper reuse should include top chrome only when source line zero changes."
  (ebox-test--reset-runtime-state)
  (let ((wrapper (ebox-create :content "" :width 20 :wrap-mode nil
                              :margin-top 1 :padding-top 2)))
    (cl-labels
        ((mapped-range (source-range)
           (let* ((source
                   (list :stack :test-stack :wrapper wrapper))
                  (source-lines (list "head" "body"))
                  (calls 0))
             (cl-letf
                 (((symbol-function 'ebox--render-stack-window-lines)
                   (lambda (&rest _)
                     (cl-incf calls)
                     (when (= calls 2)
                       (setcar (nthcdr (car source-range) source-lines)
                               "changed"))
                     (list
                      :lines source-lines
                      :line-count 2
                      :line-tail (last source-lines)
                      :complete nil
                      :cache calls
                      :prefix-delta
                      (if (= calls 1)
                          '(:exact-p nil :base-count 0
                            :rewrite-range nil :rewrite-lines nil
                            :append-lines nil)
                        (list :exact-p t :base-count 2
                              :rewrite-range source-range
                              :rewrite-lines (list "changed")
                              :append-lines nil))))))
               (let* ((prefix
                       (ebox--render-scroll-window-source source 2))
                      (extended
                       (ebox--render-scroll-window-source
                        source 3 (plist-get prefix :cache))))
                 (plist-get (plist-get extended :prefix-delta)
                            :rewrite-range))))))
      (should (equal (mapped-range '(0 . 1)) '(0 . 4)))
      (should (equal (mapped-range '(1 . 2)) '(4 . 5))))))

(ert-deftest ebox-scroll-prefix-renderer-applies-equal-length-prefix-rewrite ()
  "Equal-length completion should rerender only its declared changed line."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "" :width 20 :height 1
                           :wrap-mode nil))
         (plain-lines '("head" "body" "tail"))
         (source-lines (copy-sequence plain-lines))
         (complete-tail
          (ebox--propertize-underline "tail" "blue"))
         (renderer
          (ebox--scroll-window-prefix-renderer box :test-source 20 4))
         (rendered-line-count 0)
         (original-renderer
          (symbol-function 'ebox--scroll-rendered-content-lines)))
    (cl-letf (((symbol-function 'ebox--render-scroll-window-source)
               (lambda (_source limit &optional _cache)
                 (when (> limit 3)
                   (setcar (nthcdr 2 source-lines) complete-tail))
                 (list :lines source-lines
                       :line-count 3
                       :line-tail (last source-lines)
                       :cache nil
                       :complete (> limit 3)
                       :content-width-exact-p t
                       :rendered-lines nil
                       :prefix-delta
                       (if (= limit 3)
                           '(:exact-p nil :base-count 0
                             :rewrite-range nil
                             :rewrite-lines nil
                             :append-lines nil)
                         (list :exact-p t :base-count 3
                               :rewrite-range '(2 . 3)
                               :rewrite-lines (list complete-tail)
                               :append-lines nil)))))
              ((symbol-function 'ebox--scroll-window-formatted-lines)
               (lambda (_box window) (plist-get window :lines)))
              ((symbol-function 'ebox--scroll-window-source-lines-exact-p)
               (lambda (&rest _) t))
              ((symbol-function 'ebox--scroll-rendered-content-lines)
               (lambda (&rest args)
                 (cl-incf rendered-line-count (length (cadr args)))
                 (apply original-renderer args)))
              ((symbol-function 'equal-including-properties)
               (lambda (&rest _)
                 (ert-fail "rendered prefix reuse scanned all old lines"))))
      (let* ((prefix (funcall renderer nil 1 3))
             (_ (setq rendered-line-count 0))
             (completed (funcall renderer prefix 1 4))
             (lines (plist-get completed :rendered-content-lines))
             (line (nth 2 lines))
             (face (get-text-property 0 'face line)))
        (should (plist-get completed :complete))
        (should (= (length lines) 3))
        (should (= rendered-line-count 1))
        (should
         (ebox-test--face-has-key-value-p
          face :underline '(:position t :color "blue")))))))

(ert-deftest ebox-scroll-prefix-projects-wrapper-top-chrome-delta ()
  "A published prefix should reuse a source cache with hidden top chrome."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "" :width 20 :height 1
                           :wrap-mode nil))
         (wrapper (ebox-create :content "" :width 20 :wrap-mode nil
                               :padding-top 2 :margin-top 1))
         (source (list :stack :test-stack :wrapper wrapper))
         stack-lines
         stack-tail
         (stack-count 0)
         (calls 0)
         (rendered-line-count 0)
         (original-renderer
          (symbol-function 'ebox--scroll-rendered-content-lines))
         (renderer
          (ebox--scroll-window-prefix-renderer box source 20 4)))
    (cl-letf (((symbol-function 'ebox--render-stack-window-lines)
               (lambda (_stack limit &optional _cache)
                 (cl-incf calls)
                 (let ((base stack-count)
                       appended-lines)
                   (while (< stack-count limit)
                     (let ((cell (list (format "row-%d" stack-count))))
                       (if stack-tail
                           (setcdr stack-tail cell)
                         (setq stack-lines cell))
                       (setq stack-tail cell)
                       (push (car cell) appended-lines)
                       (cl-incf stack-count)))
                   (setq appended-lines (nreverse appended-lines))
                   (list :lines stack-lines
                       :line-count stack-count
                       :line-tail stack-tail
                       :complete nil
                       :cache (list :call calls)
                       :prefix-delta
                       (if (= calls 1)
                           '(:exact-p nil :base-count 0
                             :rewrite-range nil
                             :rewrite-lines nil
                             :append-lines nil)
                         (list :exact-p t
                               :base-count base
                               :rewrite-range nil
                               :rewrite-lines nil
                               :append-lines appended-lines))))))
              ((symbol-function 'ebox--scroll-window-formatted-lines)
               (lambda (_box window) (plist-get window :lines)))
              ((symbol-function 'ebox--scroll-window-source-lines-exact-p)
               (lambda (&rest _) t))
              ((symbol-function 'ebox--scroll-rendered-content-lines)
               (lambda (&rest args)
                 (cl-incf rendered-line-count (length (cadr args)))
                 (apply original-renderer args)))
              ((symbol-function 'equal-including-properties)
               (lambda (&rest _)
                 (ert-fail "top-chrome reuse scanned the whole prefix"))))
      (let* ((prefix (funcall renderer nil 1 6))
             (prefix-count
              (length (plist-get prefix :content-lines)))
             (_ (setq rendered-line-count 0))
             (extended (funcall renderer prefix 1 7)))
        (should (= calls 2))
        (should (= prefix-count 6))
        (should (= (length (plist-get extended :content-lines)) 7))
        (should (= rendered-line-count 1))))))

(ert-deftest ebox-scroll-prefix-exact-extension-scans-only-appended-lines ()
  "A long exact prefix should retain its cons cells and scan only its delta."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "" :width 20 :height 1
                           :wrap-mode nil))
         (source-lines
          (cl-loop for idx below 1000 collect (format "line-%d" idx)))
         (source-tail (last source-lines))
         (source-count 1000)
         (calls 0)
         scan-sizes
         record-scans
         (original-seq-take (symbol-function 'seq-take))
         (renderer
          (ebox--scroll-window-prefix-renderer box :test-source 20 4)))
    (cl-letf (((symbol-function 'ebox--render-scroll-window-source)
               (lambda (_source limit &optional _cache)
                 (cl-incf calls)
                 (let ((base source-count)
                       appended-lines)
                   (while (< source-count limit)
                     (let ((cell (list (format "line-%d" source-count))))
                       (setcdr source-tail cell)
                       (setq source-tail cell)
                       (push (car cell) appended-lines)
                       (cl-incf source-count)))
                   (setq appended-lines (nreverse appended-lines))
                   (list :lines source-lines
                         :line-count source-count
                         :line-tail source-tail
                         :cache :same
                         :complete nil
                         :content-width-exact-p t
                         :rendered-lines nil
                         :prefix-delta
                         (if (= calls 1)
                             '(:exact-p nil :base-count 0
                               :rewrite-range nil
                               :rewrite-lines nil
                               :append-lines nil)
                           (list :exact-p t :base-count base
                                 :rewrite-range nil
                                 :rewrite-lines nil
                                 :append-lines appended-lines))))))
              ((symbol-function 'ebox--scroll-window-formatted-lines)
               (lambda (_box window) (plist-get window :lines)))
              ((symbol-function 'ebox--scroll-window-source-lines-exact-p)
               (lambda (&rest _) t))
              ((symbol-function 'ebox--scroll-rendered-content-lines)
               (lambda (_box lines _region-id _start-index) lines))
              ((symbol-function 'seq-take)
               (lambda (sequence count)
                 (when record-scans
                   (push (length sequence) scan-sizes))
                 (funcall original-seq-take sequence count))))
      (let* ((prefix (funcall renderer nil 1 1000))
             (content-head (plist-get prefix :content-lines)))
        (setq record-scans t)
        (let ((extended (funcall renderer prefix 1 1001)))
          (should (eq content-head
                      (plist-get extended :content-lines)))
          (should (= (length (plist-get extended :content-lines)) 1001))
          (should scan-sizes)
          (should (<= (apply #'max scan-sizes) 1)))))))

(ert-deftest ebox-stack-window-completion-rewrite-uses-delta-payload ()
  "A long leaf completion should not scan its full prefix for one rewrite."
  (ebox-test--reset-runtime-state)
  (let* ((type 'ebox-test-long-completing-window)
         (leaf (list :ebox-type type))
         (stack (list :ebox-type 'stack :children (list leaf)))
         (leaf-lines
          (cl-loop for idx below 1000 collect (format "line-%d" idx)))
         (leaf-tail (last leaf-lines))
         (complete-tail
          (ebox--propertize-underline "line-999" "blue"))
         (original-length (symbol-function 'length))
         (original-nthcdr (symbol-function 'nthcdr))
         (original-seq-subseq (symbol-function 'seq-subseq))
         record-scans
         (full-length-count 0)
         (full-nthcdr-count 0)
         (full-subseq-count 0))
    (unwind-protect
        (progn
          (ebox--register-window-line-renderer
           type
           (lambda (_node limit)
             (if (<= limit 1000)
                 (list :lines leaf-lines
                       :line-count 1000
                       :line-tail leaf-tail
                       :complete nil)
               (setcar leaf-tail complete-tail)
               (list :lines leaf-lines
                     :line-count 1000
                     :line-tail leaf-tail
                     :complete t
                     :completion-prefix-tail-rewrite-count 1
                     :prefix-delta
                     (list :exact-p t :base-count 1000
                           :rewrite-range '(999 . 1000)
                           :rewrite-lines (list complete-tail)
                           :append-lines nil)))))
          (let ((prefix (ebox--render-stack-window-lines stack 1000)))
            (cl-letf (((symbol-function 'length)
                       (lambda (sequence)
                         (when (and record-scans (eq sequence leaf-lines))
                           (cl-incf full-length-count))
                         (funcall original-length sequence)))
                      ((symbol-function 'nthcdr)
                       (lambda (count sequence)
                         (when (and record-scans (eq sequence leaf-lines))
                           (cl-incf full-nthcdr-count))
                         (funcall original-nthcdr count sequence)))
                      ((symbol-function 'seq-subseq)
                       (lambda (sequence start &optional end)
                         (when (and record-scans (eq sequence leaf-lines))
                           (cl-incf full-subseq-count))
                         (funcall original-seq-subseq sequence start end))))
              (setq record-scans t)
              (let ((completed
                     (ebox--render-stack-window-lines
                      stack 1001 (plist-get prefix :cache))))
                (setq record-scans nil)
                (should (plist-get completed :complete))
                (should (eq (car (plist-get completed :line-tail))
                            complete-tail)))))
          (should (= full-length-count 0))
          (should (= full-nthcdr-count 0))
          (should (= full-subseq-count 0)))
      (remhash type ebox--window-line-renderer-table))))

(ert-deftest ebox-scroll-prefix-renderer-failure-keeps-published-pair-atomic ()
  "A failed rendered delta should preserve both published prefix lists."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "" :width 20 :height 1
                           :wrap-mode nil))
         (source-lines (list "line-0" "line-1" "line-2"))
         (source-tail (last source-lines))
         (calls 0)
         cache-arguments
         fail-render
         (original-renderer
          (symbol-function 'ebox--scroll-rendered-content-lines))
         (ebox--render-cache-table (make-hash-table :test 'equal))
         (renderer
          (ebox--scroll-window-prefix-renderer
           box :test-source 20 4)))
    (cl-letf
        (((symbol-function 'ebox--render-scroll-window-source)
          (lambda (_source _limit &optional cache)
            (push cache cache-arguments)
            (cl-incf calls)
            (cond
             ((= calls 1)
              (list :lines source-lines
                    :line-count 3
                    :line-tail source-tail
                    :cache :first
                    :complete nil
                    :content-width-exact-p t
                    :rendered-lines source-lines
                    :prefix-delta
                    '(:exact-p nil :base-count 0
                      :rewrite-range nil :rewrite-lines nil
                      :append-lines nil)))
             ((= calls 2)
              (let ((cell (list "line-3")))
                (setcdr source-tail cell)
                (setq source-tail cell))
              (list :lines source-lines
                    :line-count 4
                    :line-tail source-tail
                    :cache :second
                    :complete nil
                    :content-width-exact-p t
                    :rendered-lines source-lines
                    :prefix-delta
                    '(:exact-p t :base-count 3
                      :rewrite-range nil :rewrite-lines nil
                      :append-lines ("line-3"))))
             (t
              (let ((fresh (list "line-0" "line-1" "line-2" "line-3")))
                (list :lines fresh
                      :line-count 4
                      :line-tail (last fresh)
                      :cache :recovered
                      :complete nil
                      :content-width-exact-p t
                      :rendered-lines fresh
                      :prefix-delta
                      '(:exact-p nil :base-count 0
                        :rewrite-range nil :rewrite-lines nil
                        :append-lines nil)))))))
         ((symbol-function 'ebox--scroll-window-formatted-lines)
          (lambda (_box window) (plist-get window :lines)))
         ((symbol-function 'ebox--scroll-window-source-lines-exact-p)
          (lambda (&rest _) t))
         ((symbol-function 'ebox--scroll-rendered-content-lines)
          (lambda (&rest args)
            (if (and fail-render (= (nth 3 args) 3))
                (error "injected rendered-prefix failure")
              (apply original-renderer args)))))
      (let* ((prefix (funcall renderer nil 1 3))
             (content-lines (plist-get prefix :content-lines))
             (rendered-lines (plist-get prefix :rendered-content-lines)))
        (puthash :poison t ebox--render-cache-table)
        (setq fail-render t)
        (should-error (funcall renderer prefix 1 4))
        (should (= (length content-lines) 3))
        (should (= (length rendered-lines) 3))
        (should-not (cdr (last content-lines)))
        (should-not (cdr (last rendered-lines)))
        (should (= (hash-table-count ebox--render-cache-table) 0))
        (setq fail-render nil)
        (let ((recovered (funcall renderer prefix 1 4)))
          (should (= (length (plist-get recovered :content-lines)) 4))
          (should (= (length (plist-get recovered
                                        :rendered-content-lines))
                     4))))
      (setq cache-arguments (nreverse cache-arguments))
      (should (equal cache-arguments '(nil :first nil))))))

(ert-deftest ebox-stack-window-leaf-lines-uses-registered-producer ()
  "Lazy stack scrolling should use generic window-line producers."
  (ebox-test--reset-runtime-state)
  (let ((node (list :ebox-type 'test-window-producer))
        (call-count 0)
        result)
    (unwind-protect
        (progn
          (ebox--register-window-line-renderer
           'test-window-producer
           (lambda (_node limit)
             (cl-incf call-count)
             (list :lines (seq-take '("aa" "bb" "cc") limit)
                   :complete nil)))
          (setq result
                (ebox--render-stack-window-leaf-lines node 2 0))
          (should (= call-count 1))
          (should-not (plist-get result :complete))
          (should (equal '("aa" "bb")
                         (mapcar #'substring-no-properties
                                 (plist-get result :lines)))))
      (remhash 'test-window-producer
               ebox--window-line-renderer-table))))

(ert-deftest ebox-scroll-prefix-yielding-prewarm-converges-after-zero-line-slice ()
  "A prewarm-only prefix slice should yield once, then publish exact content."
  (ebox-test--reset-runtime-state)
  (let* ((node (list :ebox-type 'test-yielding-prewarm))
         (box (ebox-create :content "" :width 20 :height 1
                           :wrap-mode nil :overflow 'scroll))
         (renderer
          (ebox--scroll-window-prefix-renderer
           box (list :stack node) 20 1))
         (prewarm-count 0)
         (render-count 0))
    (unwind-protect
        (progn
          (ebox--register-window-line-prewarmer
           'test-yielding-prewarm
           (lambda (_node _target-width)
             (cl-incf prewarm-count)
             (= prewarm-count 1)))
          (ebox--register-window-line-renderer
           'test-yielding-prewarm
           (lambda (_node _limit)
             (cl-incf render-count)
             (list :lines '("ready") :line-count 1
                   :line-tail '("ready") :complete t)))
          (let* ((ebox--scroll-window-yielding-prewarm-p t)
                 (ebox--render-cache-table (make-hash-table :test 'equal))
                 (first (funcall renderer nil "yield-region" 1))
                 (second (funcall renderer first "yield-region" 1))
                 (complete (funcall renderer second "yield-region" 2)))
            (should (= prewarm-count 2))
            (should (= render-count 1))
            (should-not (plist-get first :content-lines))
            (should-not (plist-get first :complete))
            (should
             (equal '("ready")
                    (mapcar #'substring-no-properties
                            (plist-get second :content-lines))))
            (should-not (plist-get second :complete))
            (should (plist-get complete :complete))
            (should
             (equal '("ready")
                    (mapcar #'substring-no-properties
                            (plist-get complete :content-lines))))))
      (remhash 'test-yielding-prewarm
               ebox--window-line-prewarmer-table)
      (remhash 'test-yielding-prewarm
               ebox--window-line-renderer-table))))

(ert-deftest ebox-scroll-stack-window-defers-hidden-leaf-render ()
  "Large stack-backed scroll boxes should render hidden rows only on demand."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport) :padding (1 0)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (hidden-render-count 0)
         (original-render-box (symbol-function 'ebox--render-box)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (cl-letf (((symbol-function 'ebox--render-box)
                     (lambda (box)
                       (when (equal (ebox-tree-node-id box) "row-30")
                         (cl-incf hidden-render-count))
                       (funcall original-render-box box))))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout))
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (should (= hidden-render-count 0))
            (with-current-buffer buffer
              (should (string-match-p "row 00"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max))))
              (should-not (string-match-p "row 30"
                                          (buffer-substring-no-properties
                                           (point-min) (point-max))))
              (should (ebox--scroll-region-by root-id 31))
              (should (= hidden-render-count 0))
              (should (gethash root-id ebox--scroll-idle-prefetch-timers))
              (ebox--scroll-idle-prefetch root-id)
              (should (> hidden-render-count 0))
              (let* ((state (ebox--scroll-get-state root-id))
                     (delta (- 30 (or (plist-get state :scroll-offset)
                                      0))))
                (when (> delta 0)
                  (should (ebox--scroll-region-by root-id delta))))
              (should (string-match-p "row 30"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-incremental-render-covers-wheel-drain ()
  "Incremental lazy scroll renders should cover one smooth wheel drain."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "budget-row-%02d" idx)
                               :content ,(format "budget row %02d" idx)
                               :height 1))))))
         (limits nil)
         (original-render-source
          (symbol-function 'ebox--render-scroll-window-source)))
    (let ((ebox-viewport-width 240)
          (ebox-viewport-height 6)
          (ebox--defer-scroll-content-index t)
          (ebox-wheel-smooth-scroll t)
          (ebox-wheel-scroll-step 16)
          (ebox-wheel-smooth-scroll-lines-per-tick 4)
          (ebox-scroll-lazy-prefix-lookahead-lines 8))
      (cl-letf (((symbol-function 'ebox--render-scroll-window-source)
                 (lambda (source limit &optional cache)
                   (push limit limits)
                   (funcall original-render-source source limit cache))))
        (ebox-render layout)))
    (should (equal (nreverse limits) '(23)))))

(ert-deftest ebox-lazy-scroll-small-step-extends-prefix-only ()
  "Small lazy scroll steps should not materialize the whole source."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (hidden-render-count 0)
         (original-render-box (symbol-function 'ebox--render-box)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (cl-letf (((symbol-function 'ebox--render-box)
                     (lambda (box)
                       (when (equal (ebox-tree-node-id box) "row-30")
                         (cl-incf hidden-render-count))
                       (funcall original-render-box box))))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout))
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (should (= hidden-render-count 0))
            (with-current-buffer buffer
              (should (ebox--scroll-region-by root-id 1))
              (should (= hidden-render-count 0))
              (let ((state (ebox--scroll-get-state root-id)))
                (should (= (plist-get state :scroll-offset) 1))
                (should (< (length (plist-get state :content-lines)) 40))
                (should (plist-get state :materialize-content-lines)))
              (should (string-match-p "row 01"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max))))
              (should-not (string-match-p "row 30"
                                          (buffer-substring-no-properties
                                           (point-min) (point-max)))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-large-cache-miss-schedules-prefetch ()
  "Large lazy scroll misses should schedule prefetch without inline render."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "cache-row-%02d" idx)
                               :content ,(format "cache row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0)
         (materialize-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-wheel-scroll-step 0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (render-prefix (plist-get state :render-content-prefix))
                 (materialize (plist-get state :materialize-content-lines)))
            (should (= (length (plist-get state :content-lines)) 3))
            (plist-put
             state :render-content-prefix
             (lambda (&rest args)
               (cl-incf prefix-count)
               (apply render-prefix args)))
            (plist-put
             state :materialize-content-lines
             (lambda (&rest args)
               (cl-incf materialize-count)
               (apply materialize args)))
            (puthash root-id state ebox--scroll-global-state))
          (with-current-buffer buffer
            (should (ebox--scroll-region-by root-id 30))
            (should (= prefix-count 0))
            (should (= materialize-count 0))
            (should (= (plist-get (ebox--scroll-get-state root-id)
                                  :scroll-offset)
                       1))
            (should (< (length (plist-get (ebox--scroll-get-state root-id)
                                          :content-lines))
                       40))
            (should (gethash root-id ebox--scroll-idle-prefetch-timers))
            (should-not (string-match-p "cache row 30"
                                        (buffer-substring-no-properties
                                         (point-min) (point-max))))))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-smooth-scroll-cache-miss-renders-bounded-prefix ()
  "Smooth scroll cache misses should keep moving with bounded prefix render."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "smooth-cache-row-%02d" idx)
                               :content ,(format "smooth cache row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0)
         (materialize-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-wheel-scroll-step 0)
              (ebox-wheel-smooth-scroll-lines-per-tick 4)
              (ebox-wheel-smooth-scroll-interval 60.0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (render-prefix (plist-get state :render-content-prefix))
                 (materialize (plist-get state :materialize-content-lines)))
            (should (= (length (plist-get state :content-lines)) 3))
            (plist-put
             state :render-content-prefix
             (lambda (&rest args)
               (cl-incf prefix-count)
               (apply render-prefix args)))
            (plist-put
             state :materialize-content-lines
             (lambda (&rest args)
               (cl-incf materialize-count)
               (apply materialize args)))
            (puthash root-id state ebox--scroll-global-state))
          (with-current-buffer buffer
            (should (ebox--smooth-scroll-region-by root-id 16)))
          (should (= prefix-count 1))
          (should (= materialize-count 0))
          (should (> (plist-get (ebox--scroll-get-state root-id)
                                :scroll-offset)
                     1))
          (let ((entry (gethash root-id ebox--smooth-scroll-state-table)))
            (should entry)
            (should (> (or (plist-get entry :pending) 0) 0))
            (should-not (plist-get entry :waiting-prefetch))))
      (ebox--smooth-scroll-stop root-id)
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-smooth-scroll-cache-miss-continues-with-bounded-prefix ()
  "Smooth scroll cache misses should extend a bounded prefix without stalling."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "smooth-inline-row-%02d" idx)
                               :content ,(format "smooth inline row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0)
         (materialize-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-wheel-scroll-step 0)
              (ebox-wheel-smooth-scroll-lines-per-tick 4)
              (ebox-wheel-smooth-scroll-interval 60.0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (render-prefix (plist-get state :render-content-prefix))
                 (materialize (plist-get state :materialize-content-lines)))
            (should (= (length (plist-get state :content-lines)) 3))
            (plist-put
             state :render-content-prefix
             (lambda (&rest args)
               (cl-incf prefix-count)
               (apply render-prefix args)))
            (plist-put
             state :materialize-content-lines
             (lambda (&rest args)
               (cl-incf materialize-count)
               (apply materialize args)))
            (puthash root-id state ebox--scroll-global-state))
          (with-current-buffer buffer
            (should (ebox--smooth-scroll-region-by root-id 16))
            (ebox--smooth-scroll-tick root-id))
          (should (> prefix-count 0))
          (should (= materialize-count 0))
          (should (> (plist-get (ebox--scroll-get-state root-id)
                                :scroll-offset)
                     1))
          (let ((entry (gethash root-id ebox--smooth-scroll-state-table)))
            (should entry)
            (should-not (plist-get entry :waiting-prefetch))))
      (ebox--smooth-scroll-stop root-id)
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-smooth-scroll-large-pending-uses-base-tick-at-prefix-boundary ()
  "Large smooth pending input should not render a large lazy prefix at once."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 200
                         collect
                         `(box :id ,(format "smooth-large-row-%03d" idx)
                               :content ,(format "smooth large row %03d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0)
         requested-lines)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-wheel-scroll-step 0)
              (ebox-wheel-smooth-scroll-lines-per-tick 4)
              (ebox-wheel-smooth-scroll-target-ticks 8)
              (ebox-wheel-smooth-scroll-interval 60.0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (render-prefix (plist-get state :render-content-prefix)))
            (should (= (length (plist-get state :content-lines)) 3))
            (plist-put
             state :render-content-prefix
             (lambda (state region-id required-lines)
               (cl-incf prefix-count)
               (setq requested-lines required-lines)
               (funcall render-prefix state region-id required-lines)))
            (puthash root-id state ebox--scroll-global-state))
          (with-current-buffer buffer
            (should (ebox--smooth-scroll-region-by root-id 1000)))
          (should (= prefix-count 1))
          (should (<= requested-lines 8))
          (should (<= (plist-get (ebox--scroll-get-state root-id)
                                 :scroll-offset)
                      ebox-wheel-smooth-scroll-lines-per-tick))
          (let ((entry (gethash root-id ebox--smooth-scroll-state-table)))
            (should entry)
            (should-not (plist-get entry :waiting-prefetch))))
      (ebox--smooth-scroll-stop root-id)
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-smooth-scroll-cache-miss-defers-prefetch-while-active ()
  "Idle prefetch should not compete with an active smooth scroll timer."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "smooth-defer-row-%02d" idx)
                               :content ,(format "smooth defer row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-wheel-scroll-step 0)
              (ebox-wheel-smooth-scroll-lines-per-tick 4)
              (ebox-wheel-smooth-scroll-interval 60.0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (render-prefix (plist-get state :render-content-prefix)))
            (plist-put
             state :render-content-prefix
             (lambda (&rest args)
               (cl-incf prefix-count)
               (apply render-prefix args)))
            (puthash root-id state ebox--scroll-global-state))
          (with-current-buffer buffer
            (should (ebox--smooth-scroll-region-by root-id 16)))
          (should (gethash root-id ebox--smooth-scroll-state-table))
          (let ((prefix-after-start prefix-count))
            (should (> prefix-after-start 0))
            (ebox--scroll-idle-prefetch root-id)
            (should (= prefix-count prefix-after-start))
            (should (gethash root-id ebox--scroll-idle-prefetch-timers))
            (ebox--smooth-scroll-stop root-id)
            (ebox--scroll-idle-prefetch root-id)
            (should (> prefix-count prefix-after-start))))
      (ebox--smooth-scroll-stop root-id)
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-smooth-scroll-cache-miss-never-enters-prefetch-wait ()
  "Smooth scroll should not pause at a lazy prefix boundary."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "smooth-resume-row-%02d" idx)
                               :content ,(format "smooth resume row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-wheel-scroll-step 0)
              (ebox-wheel-smooth-scroll-lines-per-tick 4)
              (ebox-wheel-smooth-scroll-interval 60.0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (render-prefix (plist-get state :render-content-prefix)))
            (plist-put
             state :render-content-prefix
             (lambda (&rest args)
               (cl-incf prefix-count)
               (apply render-prefix args)))
            (puthash root-id state ebox--scroll-global-state))
          (with-current-buffer buffer
            (should (ebox--smooth-scroll-region-by root-id 16)))
          (should (> prefix-count 0))
          (let ((offset-before (plist-get (ebox--scroll-get-state root-id)
                                          :scroll-offset)))
            (ebox--smooth-scroll-tick root-id)
            (should (> (plist-get (ebox--scroll-get-state root-id)
                                  :scroll-offset)
                       offset-before)))
          (let ((entry (gethash root-id ebox--smooth-scroll-state-table)))
            (should entry)
            (should-not (plist-get entry :waiting-prefetch))
            (should (timerp (plist-get entry :timer)))))
      (ebox--smooth-scroll-stop root-id)
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-repeated-small-steps-keep-tp-mounts ()
  "Repeated lazy scroll steps should keep TP mounts valid."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (hidden-render-count 0)
         (materialize-count 0)
         (original-render-box (symbol-function 'ebox--render-box)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (cl-letf (((symbol-function 'ebox--render-box)
                     (lambda (box)
                       (when (equal (ebox-tree-node-id box) "row-30")
                         (cl-incf hidden-render-count))
                       (funcall original-render-box box))))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout))
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (let* ((state (ebox--scroll-get-state root-id))
                   (materialize (plist-get state :materialize-content-lines)))
              (plist-put
               state :materialize-content-lines
               (lambda (&rest args)
                 (cl-incf materialize-count)
                 (apply materialize args)))
              (puthash root-id state ebox--scroll-global-state))
            (with-current-buffer buffer
              (cl-loop repeat 8
                       do (should (ebox--scroll-region-by root-id 1)))
              (should (= hidden-render-count 0))
              (should (= materialize-count 0))
              (let ((state (ebox--scroll-get-state root-id)))
                (should (= (plist-get state :scroll-offset) 8))
                (should (< (length (plist-get state :content-lines)) 40))
                (should (plist-get state :materialize-content-lines)))
              (should (ebox-surface-region-mounts buffer root-id))
              (should (string-match-p "row 08"
                                      (buffer-substring-no-properties
                                       (point-min) (point-max))))
              (should-not (string-match-p "row 30"
                                          (buffer-substring-no-properties
                                           (point-min) (point-max)))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-repeated-small-steps-prefetch-prefix ()
  "Repeated lazy scroll steps should reuse a prefetched lazy prefix."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (render-prefix (plist-get state :render-content-prefix)))
            (plist-put
             state :render-content-prefix
             (lambda (&rest args)
               (cl-incf prefix-count)
               (apply render-prefix args)))
            (puthash root-id state ebox--scroll-global-state))
          (with-current-buffer buffer
            (cl-loop repeat 8
                     do (should (ebox--scroll-region-by root-id 1)))
            (should (= prefix-count 0))
            (let ((state (ebox--scroll-get-state root-id)))
              (should (= (plist-get state :scroll-offset) 8))
              (should (plist-get state :render-content-prefix))
              (should (<= (+ (plist-get state :scroll-offset)
                             (plist-get state :content-height)
                             1)
                          (length (plist-get state :content-lines)))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-idle-prefetch-extends-prefix-cache ()
  "Idle prefetch should fill lazy scroll lines before wheel ticks need them."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-scroll-lazy-idle-prefetch-lines 16))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (before-lines (length (plist-get state :content-lines)))
                 (render-prefix (plist-get state :render-content-prefix)))
            (plist-put
             state :render-content-prefix
             (lambda (&rest args)
               (cl-incf prefix-count)
               (apply render-prefix args)))
            (puthash root-id state ebox--scroll-global-state)
            (ebox--scroll-idle-prefetch root-id)
            (let ((prefetched (ebox--scroll-get-state root-id)))
              (should (> (length (plist-get prefetched :content-lines))
                         before-lines))
              (should (< (length (plist-get prefetched :content-lines))
                         80))
              (should (= prefix-count 1))))
          (with-current-buffer buffer
            (cl-loop repeat 8
                     do (should (ebox--scroll-region-by root-id 1))))
          (should (= prefix-count 1)))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-prefix-reuses-display-measurement-cache ()
  "Lazy prefix slices should retain the initial render's display cache."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :content ,(format "repeated row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         caches)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (original
               (symbol-function 'ebox--render-scroll-window-source)))
          (cl-letf (((symbol-function 'ebox--render-scroll-window-source)
                     (lambda (&rest arguments)
                       (push ebox--render-string-pixel-width-cache caches)
                       (apply original arguments))))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-prefix-cache*")
                   layout))
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (let* ((state (ebox--scroll-get-state root-id))
                   (before (length (plist-get state :content-lines))))
              (ebox--scroll-state-ensure-prefix-lines
               root-id state (1+ before) t)))
          (should (>= (length caches) 2))
          (should (car caches))
          (should (cl-every (lambda (cache) (eq cache (car caches)))
                            caches)))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-idle-prefetch-covers-visible-window ()
  "Idle prefetch should warm beyond the current visible scroll window."
  (ebox-test--reset-runtime-state)
  (let ((region-id "scroll")
        requested-lines)
    (puthash
     region-id
     (list :scroll-offset 0
           :content-height 10
           :content-lines (make-list 3 "")
           :render-content-prefix
           (lambda (_state _region-id target-lines)
             (setq requested-lines target-lines)
             (list :content-lines (make-list target-lines "")
                   :content-height 10
                   :complete nil)))
     ebox--scroll-global-state)
    (let ((ebox-scroll-lazy-idle-prefetch-lines 5)
          (ebox-scroll-lazy-prefix-lookahead-lines 0))
      (ebox--scroll-idle-prefetch region-id))
    (should requested-lines)
    (should (>= requested-lines 15))))

(ert-deftest ebox-lazy-scroll-idle-prefetch-is-sliced ()
  "Idle prefetch should extend lazy prefixes in bounded foreground slices."
  (ebox-test--reset-runtime-state)
  (let ((region-id "scroll")
        requested-lines)
    (puthash
     region-id
     (list :scroll-offset 0
           :content-height 10
           :content-lines (make-list 3 "")
           :render-content-prefix
           (lambda (_state _region-id target-lines)
             (setq requested-lines target-lines)
             (list :content-lines (make-list target-lines "")
                   :content-height 10
                   :complete nil)))
     ebox--scroll-global-state)
    (let ((ebox-scroll-lazy-idle-prefetch-lines 64)
          (ebox-scroll-lazy-idle-prefetch-slice-lines 4)
          (ebox-scroll-lazy-prefix-lookahead-lines 0)
          (ebox--scroll-allow-noninteractive-prefetch t))
      (ebox--scroll-idle-prefetch region-id))
    ;; Three cached lines plus the configured four-line slice.  Completion is
    ;; probed on a later turn instead of exceeding this callback's budget.
    (should (= requested-lines 7))
    (should (gethash region-id ebox--scroll-idle-prefetch-timers))
    (ebox--scroll-cancel-idle-prefetch region-id)))

(ert-deftest ebox-lazy-scroll-idle-prefetch-bounds-atomic-item-work ()
  "Item-heavy buffers should request only one new line per idle render turn."
  (ebox-test--reset-runtime-state)
  (let ((region-id "scroll")
        buffer
        requested-lines)
    (unwind-protect
        (progn
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-item-prefetch*")
                 (ebox-build
                  '(flex :width (240)
                         (item (box :content "atomic" :width (120)))))))
          (puthash
           region-id
           (list :buffer buffer
                 :scroll-offset 0
                 :content-height 10
                 :content-lines (make-list 3 "")
                 :render-content-prefix
                 (lambda (_state _region-id target-lines)
                   (setq requested-lines target-lines)
                   (list :content-lines (make-list target-lines "")
                         :content-height 10
                         :complete nil)))
           ebox--scroll-global-state)
          (let ((ebox-scroll-lazy-idle-prefetch-lines 64)
                (ebox-scroll-lazy-idle-prefetch-slice-lines 16)
                (ebox-scroll-lazy-prefix-lookahead-lines 13)
                (ebox--scroll-allow-noninteractive-prefetch t))
            (ebox--scroll-idle-prefetch region-id))
          ;; Three cached lines + one atomic requested line.  The completion
          ;; probe must not silently double a latency-sensitive slice.
          (should (= requested-lines 4)))
      (ebox--scroll-cancel-idle-prefetch region-id)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-idle-prefetch-bounds-large-runtime-work ()
  "Large runtimes should request only one new line per idle render turn."
  (ebox-test--reset-runtime-state)
  (let ((region-id "scroll")
        (buffer (generate-new-buffer " *ebox-large-prefetch*"))
        (node-table (make-hash-table :test 'equal))
        (selector-type-table (make-hash-table :test 'eq))
        requested-lines)
    (unwind-protect
        (progn
          (dotimes (index 512)
            (puthash index t node-table))
          (puthash buffer
                   (list :node-table node-table
                         :selector-type-table selector-type-table)
                   ebox--buffer-render-state-table)
          (puthash
           region-id
           (list :buffer buffer
                 :scroll-offset 0
                 :content-height 10
                 :content-lines (make-list 3 "")
                 :render-content-prefix
                 (lambda (_state _region-id target-lines)
                   (setq requested-lines target-lines)
                   (list :content-lines (make-list target-lines "")
                         :content-height 10
                         :complete nil)))
           ebox--scroll-global-state)
          (let ((ebox-scroll-lazy-idle-prefetch-lines 64)
                (ebox-scroll-lazy-idle-prefetch-slice-lines 16)
                (ebox-scroll-lazy-prefix-lookahead-lines 13)
                (ebox--scroll-allow-noninteractive-prefetch t))
            (ebox--scroll-idle-prefetch region-id))
          ;; Three cached lines + one atomic requested line.  The completion
          ;; probe must not silently double a latency-sensitive slice.
          (should (= requested-lines 4)))
      (ebox--scroll-cancel-idle-prefetch region-id)
      (remhash buffer ebox--buffer-render-state-table)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-idle-prefetch-defers-visible-render-gc ()
  "Visible idle prefix slices should not combine atomic rendering with GC."
  (ebox-test--reset-runtime-state)
  (let* ((region-id "visible-prefix-gc")
         (buffer (generate-new-buffer " *ebox-visible-prefix-gc*"))
         (state
          (list :buffer buffer
                :scroll-offset 0
                :content-height 1
                :content-lines '("row 0")
                :render-content-prefix
                (lambda (input-state _region-id target-lines &optional _exact)
                  (setq input-state
                        (plist-put input-state :content-lines
                                   (make-list target-lines "row")))
                  (plist-put input-state :content-lines-complete-p t))))
         (gc-enters 0)
         (gc-restores 0))
    (unwind-protect
        (let ((ebox-scroll-lazy-idle-prefetch-lines 1)
              (ebox-scroll-lazy-idle-prefetch-slice-lines 1)
              (ebox--scroll-allow-noninteractive-prefetch t))
          (puthash region-id state ebox--scroll-global-state)
          (cl-letf (((symbol-function 'get-buffer-window-list)
                     (lambda (&rest _) (list (selected-window))))
                    ((symbol-function 'display-graphic-p)
                     (lambda (&rest _) t))
                    ((symbol-function 'ebox--deferred-render-gc-enter)
                     (lambda () (cl-incf gc-enters)))
                    ((symbol-function
                      'ebox--deferred-render-gc-schedule-restore)
                     (lambda () (cl-incf gc-restores)))
                    ((symbol-function 'ebox--schedule-buffer-runtime-prewarm)
                     (lambda (&rest _) nil)))
            (ebox--scroll-idle-prefetch region-id))
          (should (= gc-enters 1))
          (should (= gc-restores 1)))
      (ebox--scroll-cancel-idle-prefetch region-id)
      (remhash region-id ebox--scroll-global-state)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-prefetch-yields-to-input-between-slices ()
  "Background prefix work should use idle time and rearm beyond current idle."
  (ebox-test--reset-runtime-state)
  (let ((region-id "scroll")
        scheduled-delay
        scheduled-function)
    (puthash
     region-id
     (list :content-height 2
           :content-lines '("row 0")
           :render-content-prefix
           (lambda (_state _region-id target-lines)
             (list :content-lines (make-list target-lines "row")
                   :content-height 2
                   :complete nil)))
     ebox--scroll-global-state)
    (let ((ebox-scroll-lazy-idle-prefetch-lines 8)
          (ebox-scroll-lazy-idle-prefetch-slice-lines 1)
          (ebox-scroll-lazy-idle-prefetch-delay 0.15)
          (ebox--scroll-allow-noninteractive-prefetch t))
      (cl-letf (((symbol-function 'current-idle-time)
                 (lambda () (seconds-to-time 0.4)))
                ((symbol-function 'run-at-time)
                 (lambda (&rest _)
                   (ert-fail "Background scroll work must yield to input")))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (delay _repeat function &rest _arguments)
                   (setq scheduled-delay delay
                         scheduled-function function)
                   'scheduled-scroll-timer)))
        (ebox--scroll-idle-prefetch region-id)))
    (should (< (abs (- scheduled-delay 0.55)) 0.000001))
    (should (eq scheduled-function #'ebox--scroll-idle-prefetch))
    (should (eq (gethash region-id ebox--scroll-idle-prefetch-timers)
                'scheduled-scroll-timer))
    (remhash region-id ebox--scroll-idle-prefetch-timers)))

(ert-deftest ebox-lazy-scroll-idle-prefetch-rearms-after-scroll ()
  "Successful lazy scroll steps should schedule the next generic prefetch."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (ebox--scroll-cancel-idle-prefetch root-id)
          (with-current-buffer buffer
            (should (ebox--scroll-region-by root-id 1)))
          (should (gethash root-id ebox--scroll-idle-prefetch-timers)))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-idle-prefetch-pauses-during-smooth-scroll ()
  "Smooth scroll should prefetch only after the active animation stops."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-scroll-lazy-idle-prefetch-delay 999)
              (ebox-wheel-smooth-scroll-lines-per-tick 4)
              (ebox-wheel-smooth-scroll-target-ticks 4)
              (ebox-wheel-smooth-scroll-interval 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (should (gethash root-id ebox--scroll-idle-prefetch-timers))
          (with-current-buffer buffer
            (should (ebox--smooth-scroll-region-by root-id 16)))
          (should (gethash root-id ebox--smooth-scroll-state-table))
          (should-not (gethash root-id ebox--scroll-idle-prefetch-timers))
          (ebox--smooth-scroll-stop root-id)
          (should (gethash root-id ebox--scroll-idle-prefetch-timers)))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (ebox--smooth-scroll-stop root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-idle-prefetch-pauses-for-resize-animation ()
  "A resize animation should own idle time until its final frame settles."
  (ebox-test--reset-runtime-state)
  (let* ((buffer (generate-new-buffer " *ebox-resize-prefetch*"))
         (region-id "scroll")
         scheduled)
    (unwind-protect
        (progn
          (puthash
           region-id
           (list :buffer buffer
                 :content-height 2
                 :content-lines '("row 0")
                 :render-content-prefix #'ignore
                 :content-lines-complete-p nil)
           ebox--scroll-global-state)
          (cl-letf (((symbol-function 'run-with-idle-timer)
                     (lambda (&rest _)
                       (setq scheduled 'scroll-timer))))
            (ebox--scroll-inhibit-idle-prefetch-for-buffer buffer)
            (ebox--scroll-schedule-idle-prefetch region-id 0)
            (should-not scheduled)
            (ebox--scroll-resume-idle-prefetch-for-buffer buffer)
            (should (eq scheduled 'scroll-timer))))
      (remhash region-id ebox--scroll-global-state)
      (remhash buffer ebox--scroll-idle-prefetch-inhibited-buffers)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-prefix-reuses-exact-source-lines ()
  "Exact-width lazy scroll source lines should not be reformatted."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 20
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (format-count 0)
         (original-format (symbol-function 'ebox--format-content-string)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 1)
              (ebox-wheel-scroll-step 0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (cl-letf (((symbol-function 'ebox--format-content-string)
                     (lambda (&rest args)
                       (when (equal (and (listp (car args))
                                         (ebox-get (car args) :id))
                                    "root")
                         (cl-incf format-count))
                       (apply original-format args))))
            (with-current-buffer buffer
              (should (ebox--scroll-region-by root-id 2))))
          (should (= format-count 0)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(defun ebox-test--complete-lazy-scroll-batch-layout ()
  "Return a complete five-row lazy scroll cache fixture."
  (ebox-build
   '(box :id "root" :width (viewport) :height (viewport-height)
         :overflow scroll
     (column :width (viewport)
      (box :content "row 00" :height 1)
      (box :id "target" :content "target row" :height 1
           :color "#111111")
      (box :id "second-target" :content "second target row" :height 1
           :color "#111111")
      (box :content "row 03" :height 1)
      (box :content "row 04" :height 1)))))

(defun ebox-test--text-has-foreground-p (string text color)
  "Return non-nil when TEXT in STRING has foreground COLOR."
  (let ((pos (string-match (regexp-quote text)
                           (substring-no-properties string))))
    (and pos
         (ebox-test--face-has-key-value-p
          (get-text-property pos 'face string)
          :foreground color))))

(defun ebox-test--lines-have-text-foreground-p (lines text color)
  "Return non-nil when one of LINES paints TEXT with foreground COLOR."
  (cl-some (lambda (line)
             (ebox-test--text-has-foreground-p line text color))
           lines))

(defun ebox-test--lines-have-text-p (lines text)
  "Return non-nil when one of LINES contains TEXT."
  (and (cl-some (lambda (line)
                  (string-match-p (regexp-quote text)
                                  (substring-no-properties line)))
                lines)
       t))

(ert-deftest ebox-lazy-scroll-prefix-extension-keeps-runtime-updates ()
  "Extending a lazy prefix should not replay producer caches from before an update."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 12
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (ebox-viewport-width 240)
         (ebox-viewport-height 2)
         (ebox-scroll-lazy-prefix-lookahead-lines 0)
         (ebox-wheel-scroll-step 0)
         (ebox-wheel-smooth-scroll nil))
    (ebox-test--with-rendered-buffer layout
      (let* ((buffer (current-buffer))
             (root-id (ebox-test--selector-region-id buffer "#root"))
             (target-id (ebox-test--selector-region-id buffer "#row-01"))
             (state (ebox-scroll-state root-id)))
        (should-not (plist-get state :content-lines-complete-p))
        (ebox-test--region-update target-id :content "updated row 01")
        (setq state (ebox-scroll-state root-id))
        (should (ebox-test--lines-have-text-p
                 (plist-get state :content-lines) "updated row 01"))
        (setq state
              (ebox--scroll-state-ensure-prefix-lines root-id state 8))
        (should (ebox-test--lines-have-text-p
                 (plist-get state :content-lines) "updated row 01"))))))

(ert-deftest ebox-lazy-scroll-prefix-does-not-publish-unflushed-batch ()
  "Extending a lazy prefix should preserve committed content until batch flush."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 12
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (ebox-viewport-width 240)
         (ebox-viewport-height 2)
         (ebox-scroll-lazy-prefix-lookahead-lines 0)
         (ebox-wheel-scroll-step 0)
         (ebox-wheel-smooth-scroll nil))
    (ebox-test--with-rendered-buffer layout
      (let* ((buffer (current-buffer))
             (root-id (ebox-test--selector-region-id buffer "#root"))
             (target-id (ebox-test--selector-region-id buffer "#row-01"))
             (initial-revision
              (plist-get (ebox--buffer-render-state buffer)
                         :runtime-revision)))
        (ebox-test--set-buffer-update-report
         buffer '(:strategy span-patch))
        (ebox-incremental-begin-batch buffer)
        (ebox-test--region-update target-id :content "unflushed row 01")
        (should (= (plist-get (ebox--buffer-render-state buffer)
                              :runtime-revision)
                   initial-revision))
        (let ((state
               (ebox--scroll-state-ensure-prefix-lines
                root-id (ebox-scroll-state root-id) 8)))
          (should (ebox-test--lines-have-text-p
                   (plist-get state :content-lines) "row 01"))
          (should-not (ebox-test--lines-have-text-p
                       (plist-get state :content-lines)
                       "unflushed row 01")))
        (should (= 2 (ebox--scroll-region-by root-id 2)))
        (should (= (plist-get (ebox--buffer-render-state buffer)
                              :runtime-revision)
                   (+ initial-revision 1)))
        (should (= -2 (ebox--scroll-region-by root-id -2)))
        (should (= (plist-get (ebox--buffer-render-state buffer)
                              :runtime-revision)
                   (+ initial-revision 2)))
        (should (string-match-p "row 01"
                                (substring-no-properties (buffer-string))))
        (should-not (string-match-p
                     "unflushed row 01"
                     (substring-no-properties (buffer-string))))
        (ebox-incremental-flush buffer)
        (should (= (plist-get (ebox--buffer-render-state buffer)
                              :runtime-revision)
                   (+ initial-revision 3)))
        (should (ebox-test--lines-have-text-p
                 (plist-get (ebox-scroll-state root-id) :content-lines)
                 "unflushed row 01"))
        (should (string-match-p
                 "unflushed row 01"
                 (substring-no-properties (buffer-string))))))))

(ert-deftest ebox-explicit-batch-synchronizes-complete-scroll-paint-cache ()
  "A paint-only batch should not replay stale complete scroll cache faces."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--complete-lazy-scroll-batch-layout))
        (ebox-viewport-width 240)
        (ebox-viewport-height 2)
        (ebox-scroll-lazy-prefix-lookahead-lines 0)
        (ebox-wheel-scroll-step 16)
        (ebox-scroll-lazy-idle-prefetch-lines 0))
    (ebox-test--with-rendered-buffer layout
      (let* ((buffer (current-buffer))
             (root-id (ebox-test--selector-region-id buffer "#root"))
             (target-id (ebox-test--selector-region-id buffer "#target")))
        (should (plist-get (ebox-scroll-state root-id)
                           :content-lines-complete-p))
        (ebox-incremental-begin-batch buffer)
        (ebox-test--region-update target-id :color "#DC2626")
        (ebox-incremental-flush buffer)
        (let* ((runtime (gethash target-id ebox--region-box-table))
               (visible-before
                (ebox-test--text-has-foreground-p
                 (buffer-string) "target row" "#DC2626"))
               (state (ebox-scroll-state root-id))
               (content-cache
                (ebox-test--lines-have-text-foreground-p
                 (plist-get state :content-lines)
                 "target row" "#DC2626"))
               (rendered-cache
                (ebox-test--lines-have-text-foreground-p
                 (plist-get state :rendered-content-lines)
                 "target row" "#DC2626")))
          (should (= 2 (ebox--scroll-region-by root-id 2)))
          (should (= -2 (ebox--scroll-region-by root-id -2)))
          (should
           (equal
            (list (ebox-get runtime :color)
                  visible-before
                  content-cache
                  rendered-cache
                  (ebox-test--text-has-foreground-p
                   (buffer-string) "target row" "#DC2626"))
            '("#DC2626" t t t t))))))))

(ert-deftest ebox-explicit-batch-synchronizes-mixed-scroll-cache-sources ()
  "A mixed batch should publish coherent visible and cached scroll content."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--complete-lazy-scroll-batch-layout))
        (ebox-viewport-width 240)
        (ebox-viewport-height 2)
        (ebox-scroll-lazy-prefix-lookahead-lines 0)
        (ebox-wheel-scroll-step 16)
        (ebox-scroll-lazy-idle-prefetch-lines 0))
    (ebox-test--with-rendered-buffer layout
      (let* ((buffer (current-buffer))
             (root-id (ebox-test--selector-region-id buffer "#root"))
             (target-id (ebox-test--selector-region-id buffer "#target")))
        (should (plist-get (ebox-scroll-state root-id)
                           :content-lines-complete-p))
        (ebox-incremental-begin-batch buffer)
        (ebox-test--region-update target-id :content "batched target row")
        (ebox-test--region-update target-id :color "#2563EB")
        (ebox-incremental-flush buffer)
        (let* ((runtime (gethash target-id ebox--region-box-table))
               (visible-before (buffer-string))
               (state (ebox-scroll-state root-id))
               (content-lines (plist-get state :content-lines))
               (rendered-lines (plist-get state :rendered-content-lines)))
          (should (= 2 (ebox--scroll-region-by root-id 2)))
          (should (= -2 (ebox--scroll-region-by root-id -2)))
          (let ((visible-after (buffer-string)))
            (should
             (equal
              (list (ebox-get runtime :content)
                    (ebox-get runtime :color)
                    (and (string-match-p
                          "batched target row"
                          (substring-no-properties visible-before))
                         t)
                    (ebox-test--text-has-foreground-p
                     visible-before "batched target row" "#2563EB")
                    (ebox-test--lines-have-text-p
                     content-lines "batched target row")
                    (ebox-test--lines-have-text-foreground-p
                     content-lines "batched target row" "#2563EB")
                    (ebox-test--lines-have-text-p
                     rendered-lines "batched target row")
                    (ebox-test--lines-have-text-foreground-p
                     rendered-lines "batched target row" "#2563EB")
                    (and (string-match-p
                          "batched target row"
                          (substring-no-properties visible-after))
                         t)
                    (ebox-test--text-has-foreground-p
                     visible-after "batched target row" "#2563EB"))
              '("batched target row" "#2563EB"
                t t t t t t t t)))))))))

(ert-deftest ebox-explicit-batch-synchronizes-distinct-scroll-cache-nodes ()
  "A batch flush should update every affected cached scroll node."
  (ebox-test--reset-runtime-state)
  (let ((layout (ebox-test--complete-lazy-scroll-batch-layout))
        (ebox-viewport-width 240)
        (ebox-viewport-height 2)
        (ebox-scroll-lazy-prefix-lookahead-lines 0)
        (ebox-wheel-scroll-step 16)
        (ebox-scroll-lazy-idle-prefetch-lines 0))
    (ebox-test--with-rendered-buffer layout
      (let* ((buffer (current-buffer))
             (root-id (ebox-test--selector-region-id buffer "#root"))
             (target-id (ebox-test--selector-region-id buffer "#target"))
             (second-id
              (ebox-test--selector-region-id buffer "#second-target")))
        (should (plist-get (ebox-scroll-state root-id)
                           :content-lines-complete-p))
        (ebox-incremental-begin-batch buffer)
        (with-temp-buffer
          (ebox-test--region-update target-id :color "#DC2626")
          (ebox-test--region-update second-id :color "#2563EB")
          (ebox-incremental-flush buffer))
        (let* ((state (ebox-scroll-state root-id))
               (content-lines (plist-get state :content-lines))
               (rendered-lines (plist-get state :rendered-content-lines)))
          (should (ebox-test--lines-have-text-foreground-p
                   content-lines "target row" "#DC2626"))
          (should (ebox-test--lines-have-text-foreground-p
                   rendered-lines "target row" "#DC2626"))
          (should (ebox-test--lines-have-text-foreground-p
                   content-lines "second target row" "#2563EB"))
          (should (ebox-test--lines-have-text-foreground-p
                   rendered-lines "second target row" "#2563EB")))))))

(ert-deftest ebox-explicit-batch-flush-retries-after-quit ()
  "A quit during a batch flush must keep the recorded changes retryable."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Batch retry" :color "black"))
         (id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (let ((buffer (current-buffer)))
        (ebox-incremental-begin-batch buffer)
        (ebox-test--region-update id :color "red")
        (should (= (ebox-incremental-pending-count buffer) 1))
        (cl-letf (((symbol-function 'ebox--publish-surface-region-batch)
                   (lambda (&rest _) (signal 'quit nil))))
          (condition-case nil
              (ebox-incremental-flush buffer)
            (quit nil)))
        ;; The interrupted flush published nothing, so the batch must
        ;; still be active with the recorded change pending.
        (should (ebox-incremental-batching-p buffer))
        (should (= (ebox-incremental-pending-count buffer) 1))
        ;; The retry must execute the preserved change instead of no-op.
        (let ((report (ebox-incremental-flush buffer)))
          (should report)
          (should-not (eq (plist-get report :strategy) 'no-op)))
        (should-not (ebox-incremental-batching-p buffer))
        (should (= (ebox-incremental-pending-count buffer) 0)))
      (goto-char (point-min))
      (search-forward "Batch retry")
      (let ((face (get-text-property (- (point) (length "Batch retry"))
                                     'face)))
        (should (ebox-test--face-has-key-value-p
                 face :foreground "red")))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-lazy-scroll-prefix-appends-rendered-content-lines ()
  "Lazy prefix extension should render only newly appended visible lines."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :id ,(format "rendered-tail-row-%02d" idx)
                               :content ,(format "rendered tail row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         rendered-line-counts
         (original-rendered-lines
          (symbol-function 'ebox--scroll-rendered-content-lines)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-wheel-scroll-step 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (cl-letf (((symbol-function 'ebox--scroll-rendered-content-lines)
                     (lambda (&rest args)
                       (push (list (length (cadr args))
                                   (nth 3 args))
                             rendered-line-counts)
                       (apply original-rendered-lines args))))
            (dotimes (_ 2)
              (let* ((state (ebox--scroll-get-state root-id))
                     (current-lines (length (plist-get state
                                                       :content-lines))))
                (ebox--scroll-state-ensure-prefix-lines
                 root-id state (+ current-lines 4)))))
          (should
           (cl-some (lambda (entry)
                      (and (<= (car entry) 5)
                           (integerp (cadr entry))
                           (> (cadr entry) 0)))
                    rendered-line-counts))
          (dolist (entry rendered-line-counts)
            (should (<= (car entry) 8))))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-prefix-avoids-full-prefix-joins ()
  "Lazy prefix extension should not join the full cached prefix string."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :id ,(format "join-row-%02d" idx)
                               :content ,(format "join row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         join-sizes
         (original-join (symbol-function 'ebox-lines-join)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-wheel-scroll-step 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (cl-letf (((symbol-function 'ebox-lines-join)
                     (lambda (&rest args)
                       (push (length (car args)) join-sizes)
                       (apply original-join args))))
            (let* ((state (ebox--scroll-get-state root-id))
                   (current-lines (length (plist-get state
                                                     :content-lines))))
              (ebox--scroll-state-ensure-prefix-lines
               root-id state (+ current-lines 4))))
          (should-not (cl-some (lambda (size) (> size 5)) join-sizes)))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-prefix-reuses-signature-cache ()
  "Lazy prefix extension should not recompute node signatures each slice."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll)))
         (source-node
          (ebox-build
           `(column :width (viewport)
             (flex :id "signature-flex" :width (viewport)
                   :flex-flow (row wrap)
                   :row-gap 1 :column-gap (8)
                   :padding (0 (12)) :border "#D97757"
                   :border-top-p nil
                   ,@(cl-loop for idx below 24
                              collect
                              `(box :content ,(format "signature %02d" idx)
                                    :width (100) :height 2))))))
         (source (list :stack source-node))
         (renderer (ebox--scroll-window-prefix-renderer
                    layout source 240 2 nil nil))
         signature-caches
         (original-node-signature
          (symbol-function 'ebox--render-cache-node-signature)))
    (let ((ebox-viewport-width 240)
          (ebox-viewport-height 2)
          (ebox--render-cache-table (make-hash-table :test 'equal))
          (ebox--render-cache-signature-cache nil))
      (cl-letf (((symbol-function 'ebox--render-cache-node-signature)
                 (lambda (node)
                   (when (and (listp node)
                              ebox--render-cache-signature-cache)
                     (push ebox--render-cache-signature-cache
                           signature-caches))
                   (funcall original-node-signature node))))
        (funcall renderer (list :rendered-content-lines nil)
                 "signature-region" 4)
        (funcall renderer (list :rendered-content-lines nil)
                 "signature-region" 8))
      (should (> (length signature-caches) 1))
      (let ((first-cache (car signature-caches)))
        (dolist (cache (cdr signature-caches))
          (should (eq cache first-cache)))))))

(ert-deftest ebox-lazy-scroll-prefix-appends-generic-wrapper-lines ()
  "Lazy prefix extension should append wrapper chrome without rerendering it."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport) :box-sizing border-box
                     :padding (1 (8)) :border "#555555"
                     :bgcolor "#FAFAFA" :color "#111111"
              ,@(cl-loop for idx below 20
                         collect
                         `(box :id ,(format "wrapped-row-%02d" idx)
                               :content ,(format "wrapped row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (wrapper-render-count 0)
         (original-render (symbol-function 'ebox-render)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 1)
              (ebox-wheel-scroll-step 0)
              (ebox-scroll-lazy-prefix-lookahead-lines 0)
              (ebox-scroll-lazy-idle-prefetch-lines 3)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (with-current-buffer buffer
            (let ((state (ebox--scroll-get-state root-id)))
              (should (= (length (plist-get state :content-lines)) 2))
              (should (plist-get state :render-content-prefix)))
            (cl-letf (((symbol-function 'ebox-render)
                       (lambda (node)
                         (when (and (listp node)
                                    (eq (plist-get node :ebox-type) 'box)
                                    (plist-get node
                                               :ebox-content-width-exact-p)
                                    (null (plist-get node
                                                     :ebox-content-node)))
                           (cl-incf wrapper-render-count))
                         (funcall original-render node))))
              (ebox--scroll-idle-prefetch root-id))
            (should (= wrapper-render-count 0))
            (should (> (length (plist-get (ebox--scroll-get-state root-id)
                                          :content-lines))
                       2))))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-first-smooth-wheel-uses-prefetched-prefix ()
  "The first smooth wheel input should only replace visible lines."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-wheel-smooth-scroll-lines-per-tick 4)
              (ebox-wheel-smooth-scroll-interval 60.0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (render-prefix (plist-get state :render-content-prefix)))
            (should (<= (+ (plist-get state :content-height)
                           ebox-wheel-scroll-step)
                        (length (plist-get state :content-lines))))
            (plist-put
             state :render-content-prefix
             (lambda (&rest args)
               (cl-incf prefix-count)
               (apply render-prefix args)))
            (puthash root-id state ebox--scroll-global-state))
          (with-current-buffer buffer
            (should (ebox--smooth-scroll-region-by root-id 16))
            (while (gethash root-id ebox--smooth-scroll-state-table)
              (ebox--smooth-scroll-tick root-id))
            (should (string-match-p "row 16"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))))
          (should (= prefix-count 0))
          (should (= (plist-get (ebox--scroll-get-state root-id)
                                :scroll-offset)
                     16)))
      (ebox--smooth-scroll-stop root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer))))

(ert-deftest ebox-lazy-scroll-incremental-smooth-wheel-uses-prefetched-prefix ()
  "Post-resize lazy scroll should not extend prefixes inside smooth ticks."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "resize-row-%02d" idx)
                               :content ,(format "resize row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (prefix-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 6)
              (ebox--defer-scroll-content-index t)
              (ebox-wheel-smooth-scroll t)
              (ebox-wheel-scroll-step 16)
              (ebox-wheel-smooth-scroll-lines-per-tick 4)
              (ebox-wheel-smooth-scroll-interval 60.0)
              (ebox-scroll-lazy-idle-prefetch-lines 0)
              (ebox--scroll-allow-noninteractive-prefetch nil)
              (ebox-scroll-lazy-prefix-lookahead-lines 8))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox--scroll-get-state root-id))
                 (render-prefix (plist-get state :render-content-prefix)))
            (plist-put
             state :render-content-prefix
             (lambda (&rest args)
               (cl-incf prefix-count)
               (apply render-prefix args)))
            (puthash root-id state ebox--scroll-global-state))
          (with-current-buffer buffer
            (should (ebox--smooth-scroll-region-by root-id 16))
            (while (gethash root-id ebox--smooth-scroll-state-table)
              (ebox--smooth-scroll-tick root-id))
            (should (string-match-p "resize row 16"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))))
          (should (= prefix-count 0))
          (should (= (plist-get (ebox--scroll-get-state root-id)
                                :scroll-offset)
                     16)))
      (ebox--smooth-scroll-stop root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer))))

(ert-deftest ebox-viewport-rerender-schedules-urgent-scroll-prefetch ()
  "Viewport rerender should warm lazy scroll prefixes before fast scrolling."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 80
                         collect
                         `(box :id ,(format "urgent-row-%02d" idx)
                               :content ,(format "urgent row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         delays
         (original-schedule
          (symbol-function 'ebox--scroll-schedule-idle-prefetch)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 4)
              (ebox-scroll-lazy-idle-prefetch-delay 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (ebox--scroll-cancel-idle-prefetch root-id)
          (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                     (lambda (region-id &optional delay)
                       (push delay delays)
                       (funcall original-schedule region-id delay))))
            (ebox-rerender-buffer-with-context buffer 300 4))
          (should (member 0 delays)))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-smooth-scroll-defers-gc-during-animation ()
  "Smooth scrolling should keep render GC settings until the animation stops."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (old-threshold gc-cons-threshold)
         (old-percentage gc-cons-percentage)
         (target-threshold 2000))
    (unwind-protect
        (let ((gc-cons-threshold 1000)
              (ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-render-gc-cons-threshold target-threshold)
              (ebox-deferred-render-gc-cons-threshold target-threshold)
              (ebox-render-gc-cons-percentage 0.9)
              (ebox-wheel-smooth-scroll-lines-per-tick 1)
              (ebox-wheel-smooth-scroll-interval 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (with-current-buffer buffer
            (should (ebox--smooth-scroll-region-by root-id 4)))
          (should (>= gc-cons-threshold target-threshold))
          (should (>= gc-cons-percentage 0.9))
          (should ebox--deferred-render-gc-state)
          (ebox--smooth-scroll-stop root-id)
          (should (timerp ebox--deferred-render-gc-timer)))
      (ebox--smooth-scroll-stop root-id)
      (when (timerp ebox--deferred-render-gc-timer)
        (cancel-timer ebox--deferred-render-gc-timer))
      (setq ebox--deferred-render-gc-timer nil)
      (setq ebox--deferred-render-gc-state nil)
      (setq gc-cons-threshold old-threshold)
      (setq gc-cons-percentage old-percentage)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(defun ebox-test--visible-foreground (face)
  "Return the highest-priority :foreground carried by FACE."
  (cond
   ((null face) nil)
   ((and (listp face) (keywordp (car face)))
    (plist-get face :foreground))
   ((listp face)
    (cl-some #'ebox-test--visible-foreground face))
   (t nil)))

(ert-deftest ebox-ancestor-paint-patch-preserves-descendant-own-paint ()
  "A parent paint-patch must not clobber a child's own declared paint."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id parent :width (120) :color "black"
            (column :width (120)
              (box :id child :content "Child" :width (120)
                   :color "blue")
              (box :id plain :content "Plain" :width (120)))))))
    (ebox-test--with-rendered-buffer layout
      (let* ((buffer (current-buffer))
             (parent-id (ebox-test--selector-region-id buffer "#parent")))
        (ebox-test--region-update parent-id :color "red")
        (should (eq (plist-get (ebox-test--buffer-update-report) :strategy)
                    'paint-patch))
        (goto-char (point-min))
        (search-forward "Child")
        ;; The child's own declaration stays the highest-priority paint.
        (should (equal (ebox-test--visible-foreground
                        (get-text-property (match-beginning 0) 'face))
                       "blue"))
        (goto-char (point-min))
        (search-forward "Plain")
        ;; A non-declaring sibling inherits the new parent paint.
        (should (equal (ebox-test--visible-foreground
                        (get-text-property (match-beginning 0) 'face))
                       "red"))))))

(ert-deftest ebox-intrinsic-measurement-preserves-scroll-state ()
  "Intrinsic measurement must not reset live scroll offsets or state."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 20
                         collect
                         `(box :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 4))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (with-current-buffer buffer
            (should (ebox--scroll-region-by root-id 5 48)))
          (should (= (plist-get (ebox--scroll-get-state root-id)
                                :scroll-offset)
                     5))
          (let ((box (gethash root-id ebox--region-box-table)))
            (should box)
            ;; Flex ancestors measure live subtrees with the intrinsic
            ;; flag bound; the measurement render must be side-effect
            ;; free for the published runtime.
            (let ((ebox--intrinsic-layout-measurement t))
              (ebox-render box))
            (should (equal (ebox-get box :scroll-offset) 5)))
          (let ((state (ebox--scroll-get-state root-id)))
            (should state)
            (should (= (plist-get state :scroll-offset) 5))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-rerender-retries-after-quit ()
  "A quit during viewport reflow must not wedge later same-size reflows."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :width (viewport)
                 :content "viewport reflow retry")))
         (buffer nil))
    (unwind-protect
        (let ((ebox-viewport-width 240))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (cl-letf (((symbol-function 'tp-surface-update-scoped)
                     (lambda (&rest _) (signal 'quit nil))))
            (condition-case nil
                (ebox-rerender-buffer-with-context buffer 320)
              (quit nil)))
          ;; The interrupted reflow published nothing, so the stored
          ;; dimensions must still match the published render.
          (should (equal (plist-get (ebox--buffer-render-state buffer)
                                    :viewport-width)
                         240))
          ;; The same-size retry must reflow instead of no-op.
          (let ((report (ebox-rerender-buffer-with-context buffer 320)))
            (should report)
            (should-not (eq (plist-get report :strategy) 'no-op)))
          (should (equal (plist-get (ebox--buffer-render-state buffer)
                                    :viewport-width)
                         320)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-smooth-scroll-multi-event-restores-gc-depth ()
  "Coalesced wheel events must not leak the deferred GC lease depth."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (old-threshold gc-cons-threshold)
         (old-percentage gc-cons-percentage))
    (unwind-protect
        (let ((gc-cons-threshold 1000)
              (ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-deferred-render-gc-cons-threshold 2000)
              (ebox-render-gc-cons-percentage 0.9)
              (ebox-wheel-smooth-scroll-lines-per-tick 1)
              (ebox-wheel-smooth-scroll-interval 999))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (with-current-buffer buffer
            ;; One trackpad flick delivers many wheel events that
            ;; coalesce into a single running animation.
            (dotimes (_ 5)
              (should (ebox--smooth-scroll-region-by root-id 4))))
          (should (= ebox--deferred-render-gc-depth 1))
          (ebox--smooth-scroll-stop root-id)
          (should (= ebox--deferred-render-gc-depth 0))
          (should (timerp ebox--deferred-render-gc-timer)))
      (when root-id
        (ebox--smooth-scroll-stop root-id))
      (when (timerp ebox--deferred-render-gc-timer)
        (cancel-timer ebox--deferred-render-gc-timer))
      (setq ebox--deferred-render-gc-timer nil)
      (setq ebox--deferred-render-gc-state nil)
      (setq ebox--deferred-render-gc-depth 0)
      (setq gc-cons-threshold old-threshold)
      (setq gc-cons-percentage old-percentage)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-smooth-scroll-clamps-without-full-materialize ()
  "Smooth wheel clamp should extend lazy scroll prefixes without full render."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id
         (hidden-render-count 0)
         (original-render-box (symbol-function 'ebox--render-box)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (cl-letf (((symbol-function 'ebox--render-box)
                     (lambda (box)
                       (when (equal (ebox-tree-node-id box) "row-30")
                         (cl-incf hidden-render-count))
                       (funcall original-render-box box))))
            (setq buffer
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-test*")
                   layout))
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (let ((ebox-wheel-smooth-scroll-lines-per-tick 1)
                  (ebox-wheel-smooth-scroll-interval 60.0))
              (should (ebox--smooth-scroll-region-by root-id 2))
              (should (= hidden-render-count 0))
              (let ((state (ebox--scroll-get-state root-id)))
                (should (= (plist-get state :scroll-offset) 1))
                (should (< (length (plist-get state :content-lines)) 40))
                (should (plist-get state :materialize-content-lines))))))
      (ebox--smooth-scroll-stop root-id)
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-hidden-child-update-does-not-materialize ()
  "Hidden updates inside lazy scroll windows should stay deferred."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 32
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         (buffer nil)
         root-id target-id next-target-id
         (materialize-count 0)
         (line-span-scans 0)
         (membership-builds 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (setq target-id (ebox-test--selector-region-id buffer "#row-30"))
            (setq next-target-id
                  (ebox-test--selector-region-id buffer "#row-31"))
            (should target-id)
            (should next-target-id)
            (let ((state (ebox--scroll-get-state root-id)))
              (should (plist-get state :materialize-content-lines))
              (let ((materialize (plist-get state
                                            :materialize-content-lines)))
                (plist-put
                 state :materialize-content-lines
                 (lambda (&rest args)
                   (cl-incf materialize-count)
                   (apply materialize args)))
                (puthash root-id state ebox--scroll-global-state)))
            (let ((original-line-span-scan
                   (symbol-function 'ebox--scroll-state-region-line-spans))
                  (original-membership-build
                   (symbol-function
                    'ebox--scroll-build-content-region-id-set)))
              (cl-letf (((symbol-function 'ebox--scroll-state-region-line-spans)
                         (lambda (&rest args)
                           (cl-incf line-span-scans)
                           (apply original-line-span-scan args)))
                        ((symbol-function
                          'ebox--scroll-build-content-region-id-set)
                         (lambda (&rest args)
                           (cl-incf membership-builds)
                           (apply original-membership-build args))))
                (ebox-selector-update-buffer buffer "#row-30"
                                             :content "new row 30")
                (ebox-selector-update-buffer buffer "#row-31"
                                             :content "new row 31")))
            (let ((report (ebox-test--buffer-update-report)))
              (should (= materialize-count 0))
              (should (= line-span-scans 0))
              (should (= membership-builds 1))
              (should (plist-get (ebox--scroll-get-state root-id)
                                 :content-region-id-set))
              (should (eq (plist-get report :strategy) 'span-patch))
              (should (plist-get report :lazy-scroll-deferred-patch)))
            (should-not (string-match-p "new row 30"
                                        (buffer-substring-no-properties
                                         (point-min) (point-max))))
            (should (ebox--scroll-region-by root-id 30))
            (should (= materialize-count 0))
            (let ((state (ebox--scroll-get-state root-id)))
              (should-not (plist-get state :content-lines-complete-p))
              (should (gethash root-id ebox--scroll-idle-prefetch-timers)))
            (ebox--scroll-idle-prefetch root-id)
            (let* ((state (ebox--scroll-get-state root-id))
                   (delta (- 30 (or (plist-get state :scroll-offset)
                                    0))))
              (when (> delta 0)
                (should (ebox--scroll-region-by root-id delta))))
            (let ((state (ebox--scroll-get-state root-id)))
              (should (plist-get state :content-lines-complete-p))
              (should-not (plist-get state :materialize-content-lines)))
            (should (string-match-p "new row 30"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-prefix-extension-keeps-live-window-settled ()
  "A clean offscreen prefix extension should not stall the live window."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for index below 40
                         collect
                         `(box :content ,(format "row %02d" index)
                               :width (300) :height 1))))))
         root-id
         (ebox-viewport-width 300)
         (ebox-viewport-height 2)
         (ebox-scroll-lazy-prefix-lookahead-lines 0))
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id
                     (current-buffer) "#root"))
      (let* ((state (ebox-scroll-state root-id))
             (required-lines
              (+ 5 (length (plist-get state :content-lines)))))
        (should-not (plist-get state :content-lines-complete-p))
        (setq state
              (ebox--scroll-state-ensure-prefix-lines
               root-id state required-lines t))
        (should-not
         (plist-get state :lazy-scroll-window-refresh-required)))
      (should (= (ebox--scroll-region-by root-id 1 1) 1))
      (should-not (plist-get (ebox-scroll-state root-id)
                             :lazy-scroll-window-refresh-required))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-lazy-scroll-prefix-refreshes-without-offset-motion ()
  "A visibly changed prefix should publish atomically without offset motion."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
              (column :width (viewport)
                ,@(cl-loop for index below 40
                           collect
                           `(box :content ,(format "row %02d" index)
                                 :width (300) :height 1))))))
         root-id
         (ebox-viewport-width 300)
         (ebox-viewport-height 2)
         (ebox-scroll-lazy-prefix-lookahead-lines 0))
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id
                     (current-buffer) "#root"))
      (let* ((state (ebox-scroll-state root-id))
             (render-prefix (plist-get state :render-content-prefix))
             (required-lines
              (+ 5 (length (plist-get state :content-lines)))))
        (plist-put
         state :render-content-prefix
         (lambda (source-state region-id limit)
           (let* ((rendered
                   (funcall render-prefix source-state region-id limit))
                  (lines
                   (copy-sequence
                    (plist-get rendered :rendered-content-lines)))
                  (first (copy-sequence (car lines))))
             (when (> (length first) 0)
               (put-text-property 0 1 'ebox-test-generation t first))
             (setf (car lines) first)
             (plist-put rendered :rendered-content-lines lines)
             rendered)))
        (ebox--scroll-state-ensure-prefix-lines
         root-id state required-lines t)
        (should (plist-get (ebox-scroll-state root-id)
                           :lazy-scroll-window-refresh-required)))
      (should (eq (ebox--scroll-region-by root-id 0) 'refreshed))
      (should (= (plist-get (ebox-scroll-state root-id) :scroll-offset) 0))
      (should-not (plist-get (ebox-scroll-state root-id)
                             :lazy-scroll-window-refresh-required))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-visible-geometry-slot-miss-refreshes-lazy-window-atomically ()
  "A visible slot miss should publish rebuilt lazy lines before returning."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              (flex :width (300) :height 5 :padding (0 (10))
                    :border "#6F6A95" :justify-content center
                    :align-items center
                (box :id "target" :content "width target\nexpands"
                     :width (190) :height 3 :padding (0 (10))
                     :border "#9CA3AF" :text-align center))
              ,@(cl-loop for index below 40
                         collect
                         `(box :content ,(format "row %02d" index)
                               :width (300) :height 1))))))
         root-id target-id
         (ebox-viewport-width 300)
         (ebox-viewport-height 5)
         (ebox-scroll-lazy-prefix-lookahead-lines 12))
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id
                     (current-buffer) "#root"))
      (setq target-id (ebox-test--selector-region-id
                       (current-buffer) "#target"))
      (let ((state (ebox-scroll-state root-id)))
        (should (plist-get state :render-content-prefix))
        (should-not (plist-get state :content-lines-complete-p))
        ;; Cache enough untouched lines that the next one-line scroll does not
        ;; cross the old prefix boundary.  Dirty-state refresh must not depend
        ;; on reaching that boundary.
        (setq state
              (ebox--scroll-state-ensure-prefix-lines
               root-id state 12 t))
        (should (> (- (length (plist-get state :content-lines))
                      (plist-get state :content-height))
                   1)))
      (ebox-test--region-update target-id :width '(280))
      (let ((report (ebox-test--buffer-update-report))
            (state (ebox-scroll-state root-id)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (plist-get report :scroll-state-sync-refreshed))
        (should (= (plist-get report :scroll-state-sync-refreshed-count) 1))
        (should-not (plist-get report :scroll-state-sync-deferred))
        (should-not (plist-get state :lazy-scroll-prefix-dirty))
        (should-not (plist-get state
                               :lazy-scroll-window-refresh-required))
        (should (ebox-test--buffer-visually-matches-runtime-render-p)))
      ;; Later movement must start from the already-published cache generation.
      (should (= (ebox--scroll-region-by root-id 1 1) 1))
      (should-not (plist-get (ebox-scroll-state root-id)
                             :lazy-scroll-prefix-dirty))
      (should-not (plist-get (ebox-scroll-state root-id)
                             :lazy-scroll-window-refresh-required))
      (should (= (ebox--scroll-region-by root-id -1 1) -1))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-lazy-scroll-cached-hidden-child-update-patches-prefix ()
  "Hidden updates should patch cached lazy prefix lines before deferring."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         buffer
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (should (ebox--scroll-region-by root-id 30 32))
            (should (string-match-p "row 30"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))
            (should (ebox--scroll-region-by root-id -30))
            (should-not (string-match-p "new row 30"
                                        (buffer-substring-no-properties
                                         (point-min) (point-max))))
            (ebox-selector-update-buffer buffer "#row-30"
                                         :content "new row 30")
            (let ((report (ebox-test--buffer-update-report)))
              (should (eq (plist-get report :strategy) 'span-patch))
              (should-not (plist-get report :lazy-scroll-deferred-patch))
              (should (plist-get report :scroll-state-patch)))
            (should (ebox--scroll-region-by root-id 30))
            (let ((plain (buffer-substring-no-properties
                          (point-min) (point-max))))
              (should (string-match-p "new row 30" plain))
              (should-not (string-match-p "^row 30$" plain)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-deferred-update-dirties-future-prefix ()
  "Deferred hidden updates should be visible when lazy prefix reaches them."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 40
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         buffer
         root-id
         (materialize-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (let* ((state (ebox--scroll-get-state root-id))
                   (materialize (plist-get state :materialize-content-lines)))
              (plist-put
               state :materialize-content-lines
               (lambda (&rest args)
                 (cl-incf materialize-count)
                 (apply materialize args)))
              (puthash root-id state ebox--scroll-global-state))
            (ebox-selector-update-buffer buffer "#row-30"
                                         :content "new row 30")
            (let ((report (ebox-test--buffer-update-report)))
              (should (plist-get report :lazy-scroll-deferred-patch)))
            (should (= materialize-count 0))
            (cl-loop repeat 30
                     do (should (ebox--scroll-region-by root-id 1 1)))
            (should (= materialize-count 0))
            (let ((plain (buffer-substring-no-properties
                          (point-min) (point-max))))
              (should (string-match-p "new row 30" plain))
              (should-not (string-match-p "^row 30$" plain)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-dirty-prefix-rebinds-signature-cache ()
  "Dirty lazy prefixes should rebind the render signature cache before rendering."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "" :width 10))
         (renderer (ebox--scroll-window-prefix-renderer
                    box :test-source 120 4))
         first-cache
         second-cache
         (render-count 0))
    (cl-letf (((symbol-function 'ebox--render-scroll-window-source)
               (lambda (&rest _args)
                 (cl-incf render-count)
                 (if first-cache
                     (setq second-cache ebox--render-cache-signature-cache)
                   (setq first-cache ebox--render-cache-signature-cache))
                 (list :lines (list (format "line %d" render-count))
                       :cache nil
                       :complete nil
                       :content-width-exact-p t
                       :rendered-lines
                       (list (format "line %d" render-count)))))
              ((symbol-function 'ebox--scroll-window-formatted-lines)
               (lambda (_box window)
                 (plist-get window :lines)))
              ((symbol-function 'ebox--scroll-rendered-content-lines)
               (lambda (_box lines _region-id _start-index)
                 lines)))
      (funcall renderer nil 1 1)
      (puthash :stale t first-cache)
      (funcall renderer '(:lazy-scroll-prefix-dirty t) 1 1)
      (should (= render-count 2))
      (should-not (eq first-cache second-cache))
      (should-not (gethash :stale second-cache)))))

(ert-deftest ebox-visible-scroll-child-content-paint-patches-scroll-lines ()
  "Visible content plus paint updates should patch scroll lines directly."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 8
                         collect
                         `(box :id ,(format "metric-%02d" idx)
                               :content "待运行"
                               :width (120)
                               :height 2))))))
         buffer
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 260)
              (ebox-viewport-height 4)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (ebox-selector-update-buffer buffer "#metric-01"
                                         :content "结果:通过"
                                         :color "#B91C1C")
            (let* ((report (ebox-test--buffer-update-report))
                   (state (ebox--scroll-get-state root-id))
                   (plain (mapconcat #'substring-no-properties
                                     (plist-get state :content-lines)
                                     "\n")))
              (should (plist-get report :scroll-state-patch))
              (should (string-match-p "结果:通过" plain))
              (should-not (string-match-p "metric-01.*待运行" plain)))
            (should (ebox--scroll-region-by root-id 1 1))
            (let ((plain (buffer-substring-no-properties
                          (point-min) (point-max))))
              (should (string-match-p "结果:通过" plain)))
            (should (ebox-test--buffer-visually-matches-runtime-render-p))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))


(ert-deftest ebox-visible-scroll-child-sync-retains-tp-mounts ()
  "Post-patch scroll line sync should retain TP-owned viewport ranges."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 8
                         collect
                         `(box :id ,(format "metric-%02d" idx)
                               :content "待运行"
                               :width (120)
                               :height 2))))))
         buffer
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 260)
              (ebox-viewport-height 4)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (ebox-selector-update-buffer buffer "#metric-01"
                                         :padding-left (list 8)
                                         :color "#B91C1C")
            (let* ((report (ebox-test--buffer-update-report))
                   (state (ebox--scroll-get-state root-id)))
              (should (plist-get report :scroll-state-sync))
              (ebox-test--assert-scoped-tp-publication report)
              (should (eq (plist-get state :buffer) buffer))
              (should (ebox-surface-region-mounts buffer root-id)))
            (should (ebox--scroll-region-by root-id 1 1))
            (should (ebox-test--buffer-visually-matches-runtime-render-p))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-scroll-retains-tp-mounts-after-paint-update ()
  "Paint updates and later scrolling should retain TP-owned ranges."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 24
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :height 1))))))
         buffer
         root-id)
    (unwind-protect
        (let ((ebox-viewport-width 260)
              (ebox-viewport-height 4)
              (ebox-scroll-lazy-prefix-lookahead-lines 0))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq root-id (ebox-test--selector-region-id buffer "#root"))
            (let* ((surface ebox-surface--buffer-surface)
                   (revision (tp-surface-revision surface)))
              (should (ebox-surface-region-mounts buffer root-id))
              (ebox-selector-update-buffer buffer "#row-01"
                                           :color "#B91C1C")
              (should (= (tp-surface-revision surface) (1+ revision)))
              (setq revision (tp-surface-revision surface))
              (let ((report (ebox-test--buffer-update-report)))
                (should (plist-get report :scroll-state-paint-sync))
                (ebox-test--assert-scoped-tp-publication report))
              (cl-loop repeat 6
                       do
                       (should (ebox--scroll-region-by root-id 1 1))
                       (should (= (tp-surface-revision surface)
                                  (1+ revision)))
                       (setq revision (tp-surface-revision surface))
                       (should (ebox-surface-region-mounts buffer root-id))
                       (should
                        (ebox-test--buffer-visually-matches-runtime-render-p))))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-owner-rerender-without-scroll-skips-scroll-state-lookup ()
  "A scroll-free root reflow should not inspect scroll containment."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(column :width (viewport)
              (box :content "resize" :width (viewport)))))
         buffer
         (containment-count 0)
         (original-containment
          (symbol-function
           'ebox--scroll-state-region-ids-containing-node-ids)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-no-scroll-publication*")
                 layout))
          (cl-letf
              (((symbol-function
                 'ebox--scroll-state-region-ids-containing-node-ids)
                (lambda (&rest arguments)
                  (cl-incf containment-count)
                  (apply original-containment arguments))))
            (ebox-rerender-buffer-with-context buffer 260 4))
          (should (= containment-count 0))
          (with-current-buffer buffer
            (should (ebox-test--buffer-visually-matches-runtime-render-p))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-hidden-geometry-update-defers-rerender ()
  "Hidden geometry changes in lazy scroll windows should not rerender roots."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 32
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :width (120)
                               :height 1))))))
         (buffer nil)
         target-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq target-id (ebox-test--selector-region-id buffer "#row-30"))
            (should target-id)
            (ebox-selector-update-buffer buffer "#row-30" :width '(180))
            (let ((report (ebox-test--buffer-update-report)))
              (should (eq (plist-get report :strategy) 'span-patch))
              (should (plist-get report :lazy-scroll-deferred-patch)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-lazy-scroll-hidden-paint-update-keeps-paint-path ()
  "Paint-only updates should not pay lazy scroll geometry deferral costs."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (column :width (viewport)
              ,@(cl-loop for idx below 32
                         collect
                         `(box :id ,(format "row-%02d" idx)
                               :content ,(format "row %02d" idx)
                               :color "#111111"
                               :height 1))))))
         (buffer nil)
         target-id)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*")
                 layout))
          (with-current-buffer buffer
            (setq target-id (ebox-test--selector-region-id buffer "#row-30"))
            (should target-id)
            (ebox-selector-update-buffer buffer "#row-30" :color "#cc0000")
            (let ((report (ebox-test--buffer-update-report)))
              (should (eq (plist-get report :strategy) 'paint-patch))
              (should-not (plist-get report :lazy-scroll-deferred-patch)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-scroll-state-set-lines-defers-line-indexes-when-bound ()
  "Deferred scroll state setup should avoid building full line indexes."
  (ebox-test--reset-runtime-state)
  (let ((content-lines (list (propertize "a" 'ebox-content 1)
                             (propertize "b" 'ebox-content 2)))
        (rendered-lines (list (propertize "a" 'ebox-content 1)))
        (build-count 0)
        (original (symbol-function 'ebox--scroll-build-region-line-span-index))
        (ebox--defer-scroll-content-index t))
    (cl-letf (((symbol-function 'ebox--scroll-build-region-line-span-index)
               (lambda (&rest args)
                 (cl-incf build-count)
                 (apply original args))))
      (let ((state (ebox--scroll-state-set-lines nil content-lines
                                                 rendered-lines)))
        (should (= build-count 0))
        (should-not (plist-get state :region-line-span-index))
        (should (plist-get state :region-line-span-index-deferred))
        (should-not (plist-get state :rendered-region-line-span-index))
        (should (plist-get state
                           :rendered-region-line-span-index-deferred))))))

(ert-deftest ebox-lazy-scroll-set-state-defers-line-indexes ()
  "Lazy scroll setup should not build hidden content indexes on first render."
  (ebox-test--reset-runtime-state)
  (let ((content-lines (list (propertize "a" 'ebox-content 1)
                             (propertize "b" 'ebox-content 2)))
        (rendered-lines (list (propertize "a" 'ebox-content 1)))
        (build-count 0)
        (original (symbol-function 'ebox--scroll-build-region-line-span-index))
        (ebox-scroll-lazy-idle-prefetch-lines 0))
    (cl-letf (((symbol-function 'ebox--scroll-build-region-line-span-index)
               (lambda (&rest args)
                 (cl-incf build-count)
                 (apply original args))))
      (ebox--scroll-set-state
       42
       (list :scroll-offset 0
             :content-height 1
             :content-lines content-lines
             :rendered-content-lines rendered-lines
             :render-content-prefix (lambda (&rest _args) nil)
             :materialize-content-lines (lambda (&rest _args) nil)))
      (let ((state (ebox--scroll-get-state 42)))
        (should (= build-count 0))
        (should-not (plist-get state :region-line-span-index))
        (should (plist-get state :region-line-span-index-deferred))
        (should-not (plist-get state :rendered-region-line-span-index))
        (should (plist-get state
                           :rendered-region-line-span-index-deferred))))))

(ert-deftest ebox-reflow-cache-prewarm-uses-first-valid-width-delta ()
  "Predictive warming should start from the first valid resize velocity."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :width (viewport) :height 2
             (box :content "steady" :width (viewport) :height 1))))
         buffer
         scheduled-delay
         scheduled-repeat
         scheduled-function
         scheduled-arguments)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm t)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*") layout))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (&rest _)
                       (ert-fail "Resize prediction must yield to input")))
                    ((symbol-function 'run-with-idle-timer)
                     (lambda (delay repeat function &rest arguments)
                       (setq scheduled-delay delay
                             scheduled-repeat repeat
                             scheduled-function function
                             scheduled-arguments arguments)
                       'scheduled-reflow-timer)))
            (ebox-rerender-buffer-with-context buffer 260 4))
          (should (= scheduled-delay
                     ebox-runtime-idle-reflow-cache-prewarm-delay))
          (should-not scheduled-repeat)
          (should (eq scheduled-function #'ebox--run-reflow-cache-prewarm))
          (should (equal (car scheduled-arguments) buffer))
          (should (eq (gethash buffer ebox--reflow-cache-prewarm-timers)
                      'scheduled-reflow-timer))
          (should (= (plist-get (ebox--buffer-render-state buffer)
                                :last-viewport-width-delta)
                     20)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-reflow-cache-prewarm-isolates-published-runtime-state ()
  "Predicted renders should publish only persistent render-cache entries."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
             (flex :width (viewport) :gap 1
               ,@(cl-loop for index below 8
                          collect
                          `(box :id ,(format "card-%d" index)
                                :content ,(format "card %d" index)
                                :width 72 :height 1))))))
         buffer)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*") layout))
          (ebox--cancel-buffer-runtime-prewarm buffer)
          (let* ((state (ebox--buffer-render-state buffer))
                 (root (plist-get state :root-node))
                 (root-before (copy-tree root))
                 (text-before
                  (with-current-buffer buffer (buffer-string)))
                 (cache (plist-get state :render-cache))
                 (cache-count (hash-table-count cache))
                 (signature-count
                  (hash-table-count
                   (plist-get state :render-signature-cache)))
                 (root-id (ebox-test--selector-region-id buffer "#root"))
                 (scroll-before
                  (copy-tree (ebox--scroll-get-state root-id)))
                 (region-table-count (hash-table-count ebox--region-box-table)))
            (ebox-test--set-buffer-update-report
             buffer 'keep-this-report)
            (should
             (ebox--prewarm-buffer-render-cache-at-context
              buffer state 0 240 280 4))
            (should (> (hash-table-count cache) cache-count))
            (should (= (hash-table-count
                        (plist-get state :render-signature-cache))
                       signature-count))
            (should (equal root root-before))
            (should (equal-including-properties
                     (with-current-buffer buffer (buffer-string))
                     text-before))
            (should (= (plist-get state :viewport-width) 240))
            (should (equal (ebox--scroll-get-state root-id) scroll-before))
            (should (= (hash-table-count ebox--region-box-table)
                       region-table-count))
            (should (eq (ebox-buffer-update-report buffer)
                        'keep-this-report))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-reflow-cache-prewarm-rejects-stale-runtime-revision ()
  "A stale predicted render should exit before touching render caches."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :width (viewport) :content "stale")))
         buffer
         (render-count 0)
         (original-render (symbol-function 'ebox-render)))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*") layout))
          (ebox--cancel-buffer-runtime-prewarm buffer)
          (let* ((state (ebox--buffer-render-state buffer))
                 (cache (plist-get state :render-cache))
                 (cache-count (hash-table-count cache)))
            (cl-letf (((symbol-function 'ebox-render)
                       (lambda (&rest args)
                         (cl-incf render-count)
                         (apply original-render args))))
              (should-not
               (ebox--prewarm-buffer-render-cache-at-context
                buffer state 1 240 280 4)))
            (should (= render-count 0))
            (should (= (hash-table-count cache) cache-count))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-local-update-cancels-without-scheduling-reflow-prewarm ()
  "Single-property updates should cancel stale predictions and schedule none."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :width (viewport)
             (box :id "target" :content "old" :width 80))))
         buffer)
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 4)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm t)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-test*") layout))
          (ebox-rerender-buffer-with-context buffer 260 4)
          (ebox-rerender-buffer-with-context buffer 280 4)
          (should (gethash buffer ebox--reflow-cache-prewarm-timers))
          (ebox-selector-update-buffer buffer "#target" :content "new")
          (should-not (gethash buffer ebox--reflow-cache-prewarm-timers))
          (should (eq (plist-get (ebox-test--buffer-update-report) :strategy)
                      'span-patch)))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-prepares-shared-update-state ()
  "Idle prewarm should prepare shared update state without materializing scrolls."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height 2 :overflow scroll
                 (column
                  ,@(cl-loop for idx below 40
                             collect
                             `(box :id ,(format "row-%02d" idx)
                                   :content ,(format "row %02d" idx)
                                   :height 1))))))
         (buffer nil)
         root-id
         expected-viewport-ids
         (materialize-count 0))
    (unwind-protect
        (let ((ebox-viewport-width 900)
              (ebox-scroll-lazy-idle-prefetch-lines 0)
              (ebox-runtime-idle-prewarm-slice-size 10000)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*") layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (setq expected-viewport-ids
                (ebox--viewport-dependent-node-ids
                 (ebox-test--runtime-root buffer)))
          (let* ((state (ebox-scroll-state root-id))
                 (before-lines (length (plist-get state :content-lines)))
                 (materialize (plist-get state :materialize-content-lines)))
            (when materialize
              (plist-put state :materialize-content-lines
                         (lambda (&rest args)
                           (cl-incf materialize-count)
                           (apply materialize args))))
            (ebox--runtime-prewarm-drain buffer)
            (let ((render-state (ebox--buffer-render-state buffer))
                  (warmed (ebox-scroll-state root-id)))
              (should
               (plist-get render-state :layout-snapshots-complete-p))
              (should
               (plist-get render-state :viewport-dependent-node-ids-ready))
              (should
               (equal (plist-get render-state :viewport-dependent-node-ids)
                      expected-viewport-ids))
              (should (plist-get warmed :region-line-span-index))
              (should (plist-get warmed :rendered-region-line-span-index))
              (should (= (length (plist-get warmed :content-lines))
                         before-lines))
              (should (= materialize-count 0)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-does-not-wait-for-prefix-prefetch ()
  "Prewarm should index current scroll lines while lazy prefix work is active."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           '(box :id "root" :height 2 :overflow scroll
                 (column
                  (box :id "target" :content "target" :height 1)
                  (box :id "row-1" :content "row 1" :height 1)
                  (box :id "row-2" :content "row 2" :height 1)))))
         (buffer nil)
         root-id)
    (unwind-protect
        (let ((ebox-runtime-idle-prewarm-slice-size 10000)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*") layout))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (puthash root-id t ebox--scroll-idle-prefetch-timers)
          (ebox--runtime-prewarm-drain buffer)
          (let ((state (ebox-scroll-state root-id)))
            (should (plist-get state :region-line-span-index))
            (should (plist-get state :rendered-region-line-span-index))))
      (remhash root-id ebox--scroll-idle-prefetch-timers)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-takes-priority-over-prefix-prefetch ()
  "Lazy prefix warming should yield while shared runtime prewarming is active."
  (ebox-test--reset-runtime-state)
  (let ((buffer nil)
        root-id
        (prefix-render-count 0)
        exact-prefix
        scheduled-delay)
    (unwind-protect
        (let ((ebox-scroll-lazy-idle-prefetch-lines 8)
              (ebox--scroll-allow-noninteractive-prefetch t)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*")
                 (ebox-build
                  '(box :id "root" :height 2 :overflow scroll
                        (column
                         (box :content "row 0" :height 1)
                         (box :content "row 1" :height 1))))))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let* ((state (ebox-scroll-state root-id))
                 (job (gethash buffer ebox--runtime-prewarm-jobs)))
            (setq state (plist-put state :render-content-prefix t))
            (setq state (plist-put state :content-lines-complete-p nil))
            (setq state (plist-put state :buffer buffer))
            (puthash root-id state ebox--scroll-global-state)
            (cl-letf (((symbol-function 'ebox--scroll-state-ensure-prefix-lines)
                       (lambda (&rest _args)
                         (cl-incf prefix-render-count)
                         state))
                      ((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                       (lambda (_region-id &optional delay)
                         (setq scheduled-delay delay))))
              (ebox--scroll-idle-prefetch root-id))
            (should (= prefix-render-count 0))
            (should (eq (gethash buffer ebox--runtime-prewarm-jobs) job))
            (should (equal scheduled-delay
                           ebox-runtime-idle-prewarm-prefix-resume-delay))))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-does-not-delay-cache-miss-prefetch ()
  "Urgent cache-miss prefetch should bypass shared prewarm priority."
  (ebox-test--reset-runtime-state)
  (let ((buffer nil)
        root-id
        (prefix-render-count 0)
        scheduled-delay)
    (unwind-protect
        (let ((ebox-scroll-lazy-idle-prefetch-lines 8)
              (ebox--scroll-allow-noninteractive-prefetch t)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*")
                 (ebox-build
                  '(box :id "root" :height 2 :overflow scroll
                        (column
                         (box :content "row 0" :height 1)
                         (box :content "row 1" :height 1))))))
          (setq root-id (ebox-test--selector-region-id buffer "#root"))
          (let ((state (ebox-scroll-state root-id)))
            (setq state (plist-put state :render-content-prefix t))
            (setq state (plist-put state :content-lines-complete-p nil))
            (setq state (plist-put state :cache-miss-prefetch-target-lines 8))
            (setq state (plist-put state :buffer buffer))
            (puthash root-id state ebox--scroll-global-state)
            (cl-letf (((symbol-function 'ebox--scroll-state-ensure-prefix-lines)
                       (lambda (_region-id input-state target-lines
                                           &optional exact)
                         (cl-incf prefix-render-count)
                         (setq exact-prefix exact)
                         (setq input-state
                               (plist-put input-state :content-lines
                                          (make-list target-lines
                                                     (ebox-pixel-space 1))))
                         (plist-put input-state :content-lines-complete-p t)))
                      ((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                       (lambda (_region-id &optional delay)
                         (setq scheduled-delay delay)))
                      ((symbol-function 'ebox--schedule-buffer-runtime-prewarm)
                       (lambda (&rest _args) nil)))
              (ebox--scroll-idle-prefetch root-id)))
          (should (= prefix-render-count 1))
          (should exact-prefix)
          (should-not (equal scheduled-delay
                             ebox-runtime-idle-prewarm-prefix-resume-delay)))
      (ebox--scroll-cancel-idle-prefetch root-id)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-idle-prefix-slices-do-not-restart-runtime-prewarm ()
  "Consecutive prefix slices should not starve behind repeated tree prewarms."
  (ebox-test--reset-runtime-state)
  (let* ((buffer (generate-new-buffer " *ebox-prefix-slice-test*"))
         (region-id "prefix-slice-scroll")
         (state (list :buffer buffer
                      :scroll-offset 0
                      :content-height 2
                      :content-lines '("row 0" "row 1")
                      :render-content-prefix t
                      :content-lines-complete-p nil))
         (runtime-prewarm-count 0)
         (prefix-reschedule-count 0))
    (unwind-protect
        (let ((ebox-scroll-lazy-idle-prefetch-lines 8)
              (ebox-scroll-lazy-idle-prefetch-slice-lines 1))
          (puthash region-id state ebox--scroll-global-state)
          (cl-letf (((symbol-function 'ebox--scroll-state-ensure-prefix-lines)
                     (lambda (_region-id input-state _target-lines
                                         &optional _exact)
                       (plist-put input-state :content-lines
                                  (append (plist-get input-state :content-lines)
                                          '("row 2")))
                       (puthash region-id input-state
                                ebox--scroll-global-state)
                       input-state))
                    ((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                     (lambda (&rest _args)
                       (cl-incf prefix-reschedule-count)))
                    ((symbol-function 'ebox--schedule-buffer-runtime-prewarm)
                     (lambda (&rest _args)
                       (cl-incf runtime-prewarm-count))))
            (ebox--scroll-idle-prefetch region-id))
          (should (= prefix-reschedule-count 1))
          (should (= runtime-prewarm-count 0)))
      (remhash region-id ebox--scroll-global-state)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-yields-between-slices ()
  "Each prewarm slice should leave an idle interval for redisplay."
  (ebox-test--reset-runtime-state)
  (let ((buffer nil)
        scheduled-delay)
    (unwind-protect
        (let ((ebox-runtime-idle-prewarm-delay 0.1)
              (ebox-runtime-idle-prewarm-slice-size 1)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*")
                 (ebox-build
                  '(box :height 2 :overflow scroll
                        (column
                         (box :content "row 0" :height 1)
                         (box :content "row 1" :height 1)
                         (box :content "row 2" :height 1))))))
          (cl-letf (((symbol-function 'current-idle-time)
                     (lambda () (seconds-to-time 0.4)))
                    ((symbol-function 'ebox--runtime-prewarm-schedule-timer)
                     (lambda (_buffer &optional delay)
                       (setq scheduled-delay delay))))
            (ebox--runtime-prewarm-timer buffer))
          (should (equal scheduled-delay 0.5)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-discards-stale-runtime-revisions ()
  "A runtime mutation should invalidate an older sliced prewarm job."
  (ebox-test--reset-runtime-state)
  (let ((buffer nil))
    (unwind-protect
        (let ((ebox-runtime-idle-prewarm-slice-size 1)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*")
                 (ebox-build
                  '(column
                    (box :id "a" :content "A")
                    (box :id "b" :content "B")))))
          (should (gethash buffer ebox--runtime-prewarm-jobs))
          (ebox--bump-buffer-runtime-revision buffer)
          (should-not (ebox--runtime-prewarm-step buffer))
          (should-not (gethash buffer ebox--runtime-prewarm-jobs)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-reschedules-after-batched-updates ()
  "A successful explicit batch should schedule shared-state prewarming."
  (ebox-test--reset-runtime-state)
  (let ((buffer nil))
    (unwind-protect
        (let ((ebox-runtime-idle-prewarm-slice-size 10000)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*")
                 (ebox-build
                  '(column
                    (box :id "target" :content "old")
                    (box :id "sibling" :content "same")))))
          (ebox--runtime-prewarm-drain buffer)
          (should-not (gethash buffer ebox--runtime-prewarm-jobs))
          (let ((target-id
                 (ebox-test--selector-region-id buffer "#target")))
            (ebox-incremental-begin-batch buffer)
            (with-current-buffer buffer
              (ebox-test--region-update target-id :color "#DC2626")
              (ebox-incremental-flush buffer)))
          (let ((job (gethash buffer ebox--runtime-prewarm-jobs))
                (state (ebox--buffer-render-state buffer)))
            (should job)
            (should (= (plist-get job :runtime-revision)
                       (plist-get state :runtime-revision)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-cancels-during-open-batch ()
  "An unflushed batch mutation should cancel stale shared-state prewarming."
  (ebox-test--reset-runtime-state)
  (let ((buffer nil))
    (unwind-protect
        (let ((ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*")
                 (ebox-build '(box :id "target" :content "old"))))
          (should (gethash buffer ebox--runtime-prewarm-jobs))
          (let ((target-id
                 (ebox-test--selector-region-id buffer "#target")))
            (ebox-incremental-begin-batch buffer)
            (with-current-buffer buffer
              (ebox-test--region-update target-id :padding-left 9)))
          (should (= (ebox-incremental-pending-count buffer) 1))
          (should-not (gethash buffer ebox--runtime-prewarm-jobs))
          (should-not (gethash buffer ebox--runtime-prewarm-timers)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-avoids-unbounded-tree-scans ()
  "Scheduling and draining prewarm should not scan all nodes in one callback."
  (ebox-test--reset-runtime-state)
  (let ((buffer nil)
        (node-table-scan-count 0)
        (viewport-scan-count 0))
    (unwind-protect
        (let ((ebox--runtime-prewarm-allow-noninteractive t)
              (ebox-runtime-idle-prewarm-slice-size 1))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*")
                 (ebox-build
                  '(column
                    (box :content "row 0")
                    (box :content "row 1")
                    (box :content "row 2")))))
          (ebox--cancel-buffer-runtime-prewarm buffer)
          (let ((node-table (ebox--buffer-node-table buffer))
                (original-maphash (symbol-function 'maphash)))
            (cl-letf (((symbol-function 'maphash)
                       (lambda (function table)
                         (when (eq table node-table)
                           (cl-incf node-table-scan-count))
                         (funcall original-maphash function table))))
              (ebox--schedule-buffer-runtime-prewarm buffer)))
          (let ((original-viewport
                 (symbol-function
                  'ebox--buffer-viewport-dependent-node-ids)))
            (cl-letf
                (((symbol-function 'ebox--buffer-viewport-dependent-node-ids)
                  (lambda (&rest args)
                    (cl-incf viewport-scan-count)
                    (apply original-viewport args))))
              (ebox--runtime-prewarm-drain buffer)))
          (should (= node-table-scan-count 0))
          (should (= viewport-scan-count 0)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-preserves-viewport-dependency-semantics ()
  "Sliced dependency discovery should match the canonical tree algorithm."
  (ebox-test--reset-runtime-state)
  (let ((buffer nil))
    (unwind-protect
        (let ((ebox-viewport-width 360)
              (ebox-viewport-height 12)
              (ebox-runtime-idle-prewarm-slice-size 1)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*")
                 (ebox-build
                  '(box :width (210)
                        (column
                         (box :id "width-only" :width (viewport))
                         (box :id "height-only"
                              :height (viewport-height))
                         (flex :id "flex-height"
                               :min-height (- (viewport-height) 1)
                               (box :content "Flex")))))))
          (let* ((state (ebox--buffer-render-state buffer))
                 (root (plist-get state :root-node))
                 (expected-axes
                  (let ((ebox--viewport-dependent-node-ids-cache
                         (make-hash-table :test 'eq))
                        (ebox--viewport-height-dependent-subtree-cache
                         (make-hash-table :test 'eq)))
                    (ebox--viewport-dependent-node-id-axes root)))
                 (expected
                  (delete-dups
                   (copy-sequence
                    (append (car expected-axes) (cdr expected-axes)))))
                 (width-only-node-id
                  (plist-get
                   (car (ebox-selector-query-buffer buffer "#width-only"))
                   :node-id))
                 (height-only-node-id
                  (plist-get
                   (car (ebox-selector-query-buffer buffer "#height-only"))
                   :node-id)))
            (ebox--runtime-prewarm-drain buffer)
            (should (equal (plist-get state :viewport-dependent-node-id-axes)
                           expected-axes))
            (should (equal (plist-get state :viewport-dependent-node-ids)
                           expected))
            (pcase-let ((`(,width-ids . ,height-ids)
                         (plist-get state
                                    :viewport-dependent-node-id-axes)))
              (should-not (member width-only-node-id width-ids))
              (should-not (member width-only-node-id height-ids))
              (should-not (member height-only-node-id width-ids))
              (should (member height-only-node-id height-ids)))
            (should (plist-get state :viewport-dependent-node-ids-ready))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-runtime-idle-prewarm-scroll-slices-use-list-cursors ()
  "Late cached-line slices should not restart traversal from the list head."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :height 2 :overflow scroll
                 (column
                  ,@(cl-loop for idx below 40
                             collect
                             `(box :content ,(format "row %02d" idx)
                                   :height 1))))))
         (buffer nil)
         (nth-count 0)
         (original-nth (symbol-function 'nth)))
    (unwind-protect
        (let ((ebox-scroll-lazy-idle-prefetch-lines 0)
              (ebox-runtime-idle-prewarm-slice-size 3)
              (ebox--runtime-prewarm-allow-noninteractive t))
          (setq buffer
                (ebox-render-to-buffer
                 (generate-new-buffer-name " *ebox-prewarm-test*") layout))
          (cl-letf (((symbol-function 'nth)
                     (lambda (&rest args)
                       (cl-incf nth-count)
                       (apply original-nth args))))
            (ebox--runtime-prewarm-drain buffer))
          (should (= nth-count 0)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))


(ert-deftest ebox-hidden-scroll-child-content-update-patches-scroll-state ()
  "Hidden scroll children should update cached scroll lines without rerendering."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height 1 :overflow scroll
                        (column
                         (box :content "visible" :height 1)
                         (box :id "target" :content "old" :height 1)
                         (box :content "tail" :height 1)))))
         root-id target-id)
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id (current-buffer) "#root"))
      (setq target-id (ebox-test--selector-region-id (current-buffer)
                                                     "#target"))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "visible" plain))
        (should-not (string-match-p "old" plain)))
      (ebox-test--region-update target-id :content "new")
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (plist-get report :scroll-state-patch))
        (should-not (plist-get report :full-rerender)))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "visible" plain))
        (should-not (string-match-p "new" plain)))
      (should (ebox--scroll-region-by root-id 1))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "new" plain))
        (should-not (string-match-p "old" plain))))))

(ert-deftest ebox-visible-lazy-scroll-child-update-does-not-defer ()
  "Lazy scroll children in the current visible range should patch immediately."
  (ebox-test--reset-runtime-state)
  (let* ((children (cl-loop for idx below 40
                            collect `(box :id ,(format "row-%02d" idx)
                                          :content ,(format "row %02d" idx)
                                          :height 1)))
         (layout (ebox-build
                  `(box :id "root" :height 2 :overflow scroll
                        (column ,@children))))
         root-id target-id)
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id (current-buffer) "#root"))
      (should (ebox--scroll-region-by root-id 30))
      (setq target-id (ebox-test--selector-region-id (current-buffer)
                                                     "#row-30"))
      (should target-id)
      (should (string-match-p "row 30"
                              (buffer-substring-no-properties
                               (point-min) (point-max))))
      (cl-letf (((symbol-function 'ebox--region-ids-visible-in-buffer-p)
                 (lambda (&rest _args) nil)))
        (ebox-test--region-update target-id :content "new row 30"))
      (let ((report (ebox-test--buffer-update-report)))
        (should (memq (plist-get report :strategy)
                      '(span-patch owner-rerender root-rerender)))
        (should-not (plist-get report :lazy-scroll-deferred-patch)))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "new row 30" plain))))))

(ert-deftest ebox-visible-empty-scroll-child-content-update-settles-window ()
  "An empty fixed box in a visible scene must not be mistaken for hidden."
  (ebox-test--reset-runtime-state)
  (let* ((layout
          (ebox-build
           `(box :id "root" :width (viewport) :height (viewport-height)
                 :overflow scroll
              (column :width (viewport)
                (flex :id "scene" :width (viewport) :height 4
                      :align-items center :justify-content center
                  (box :id "target" :content "SEED" :width (180) :height 3
                       :overflow hidden :bgcolor "#DDEAE4"))
                ,@(cl-loop for index below 40
                           collect
                           `(box :content ,(format "row %02d" index)
                                 :height 1))))))
         (ebox-viewport-width 300)
         (ebox-viewport-height 4)
         (ebox-scroll-lazy-prefix-lookahead-lines 12)
         root-id target-id)
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id (current-buffer) "#root")
            target-id (ebox-test--selector-region-id
                       (current-buffer) "#target"))
      (should (plist-get (ebox-scroll-state root-id)
                         :render-content-prefix))
      (ebox-test--region-update target-id :content "")
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (plist-get report :scroll-state-patch))
        (should-not
         (member (ebox--buffer-root-node-id (current-buffer))
                 (plist-get report :owner-ids))))
      (ebox-test--region-update target-id :content "NOW VISIBLE")
      (let ((report (ebox-test--buffer-update-report))
            (state (ebox-scroll-state root-id)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (plist-get report :scroll-state-patch))
        (should-not
         (member (ebox--buffer-root-node-id (current-buffer))
                 (plist-get report :owner-ids)))
        (should-not (plist-get report :lazy-scroll-deferred-patch))
        (should-not (plist-get state :lazy-scroll-prefix-dirty))
        (should-not (plist-get state
                               :lazy-scroll-window-refresh-required)))
      (should (string-match-p
               "NOW VISIBLE"
               (buffer-substring-no-properties (point-min) (point-max))))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-lazy-scroll-ignores-updates-to-sibling-status-box ()
  "A sibling update must not materialize an unrelated lazy scroll state."
  (ebox-test--reset-runtime-state)
  (let* ((rows (cl-loop for index below 40
                        collect `(box :id ,(format "row-%02d" index)
                                      :content ,(format "row %02d" index)
                                      :height 1)))
         (layout
          (ebox-build
           `(column :width (viewport)
              (box :id "rail" :content "ready" :width (viewport)
                   :height 1)
              (box :id "root" :width (viewport)
                   :height (viewport-height) :overflow scroll
                (column ,@rows)))))
         (ebox-viewport-width 240)
         (ebox-viewport-height 3)
         (ebox-scroll-lazy-prefix-lookahead-lines 0)
         rail-id root-id materialize-count)
    (ebox-test--with-rendered-buffer layout
      (setq rail-id (ebox-test--selector-region-id
                     (current-buffer) "#rail")
            root-id (ebox-test--selector-region-id
                     (current-buffer) "#root"))
      (let* ((state (ebox-scroll-state root-id))
             (materialize (plist-get state :materialize-content-lines)))
        (should materialize)
        (should-not (plist-get state :content-lines-complete-p))
        (should (plist-get state :rendered-content-lines))
        (plist-put
         state :materialize-content-lines
         (lambda (&rest arguments)
           (cl-incf materialize-count)
           (apply materialize arguments)))
        (puthash root-id state ebox--scroll-global-state))
      (ebox-test--region-update rail-id :content "updated")
      (should (= (or materialize-count 0) 0))
      (let ((state (ebox-scroll-state root-id)))
        (should-not (plist-get state :content-lines-complete-p))
        (should (plist-get state :rendered-content-lines)))
      (should (string-match-p
               "updated"
               (buffer-substring-no-properties (point-min) (point-max)))))))


(ert-deftest ebox-scroll-reveal-keeps-visible-geometry-indexed ()
  "Geometry updates on a revealed child should use a scoped TP plan."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id "root" :width (180) :height 2 :overflow scroll
                (column
                 (box :content "row 0" :height 1)
                 (box :content "row 1" :height 1)
                 (box :content "row 2" :height 1)
                 (box :id "target" :content "target" :width (120) :height 1
                      :box-sizing border-box :padding-left (2))))))
        root-id target-id)
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id (current-buffer) "#root"))
      (setq target-id
            (ebox-test--selector-region-id (current-buffer) "#target"))
      (should (ebox--scroll-region-by root-id 2 48))
      (ebox-test--region-update target-id :padding-left (list 12))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'span-patch))
        (should (eq (plist-get report :tp-render-scope) 'objects))
        (should-not (plist-get report :tp-scope-fallback)))
      (should (ebox-surface-region-mounts (current-buffer) target-id))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-scroll-hidden-update-keeps-the-visible-window ()
  "Updating a scrolled-away node should not reuse its stale buffer spans."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id "root" :width (180) :height 2 :overflow scroll
                (column
                 (box :id "target" :content "target" :width (120) :height 1
                      :box-sizing border-box :padding-left (2))
                 (box :content "row 1" :height 1)
                 (box :content "row 2" :height 1)
                 (box :content "row 3" :height 1)
                 (box :content "row 4" :height 1)))))
        root-id target-id)
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id (current-buffer) "#root"))
      (setq target-id
            (ebox-test--selector-region-id (current-buffer) "#target"))
      (should (ebox--scroll-region-by root-id 3 48))
      (let ((visible-before
             (buffer-substring-no-properties (point-min) (point-max))))
        (ebox-test--region-update target-id :padding-left (list 12))
        (should (equal visible-before
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should (plist-get report :scroll-state-patch))
        (should-not (plist-get report :tp-full-root))
        (should (= (plist-get report :tp-operation-count) 0)))
      (should-not
       (text-property-any
        (point-min) (point-max) 'ebox-content target-id))
      (should (ebox-test--buffer-visually-matches-runtime-render-p))
      (let ((visible-before
             (buffer-substring-no-properties (point-min) (point-max))))
        (ebox-test--region-update target-id :width (list 400))
        (should (equal visible-before
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should-not (plist-get report :root-rerender))
        (should (plist-get report :scroll-state-patch))
        (should (= (plist-get report :tp-operation-count) 0)))
      (should (ebox-test--buffer-visually-matches-runtime-render-p))
      (should (ebox--scroll-region-by root-id -3 48))
      (should
       (text-property-any
        (point-min) (point-max) 'ebox-content target-id))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-nested-scroll-hidden-geometry-replays-both-caches ()
  "A hidden inner-scroll update should survive inner and outer replay."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id "root" :width (180) :height 1 :overflow scroll
                (column
                 (box :id "wrapper" :width (180) :height 1 :overflow scroll
                       (column
                        (box :id "target" :content "target" :width (120)
                             :height 1 :box-sizing border-box
                             :padding-left (2))
                        (box :content "inner tail" :height 1)))
                 (box :content "outer tail" :height 1)))))
        root-id wrapper-id target-id)
    (ebox-test--with-rendered-buffer layout
      (setq root-id (ebox-test--selector-region-id (current-buffer) "#root"))
      (setq wrapper-id
            (ebox-test--selector-region-id (current-buffer) "#wrapper"))
      (setq target-id
            (ebox-test--selector-region-id (current-buffer) "#target"))
      (should (ebox--scroll-region-by wrapper-id 1 48))
      (should-not
       (text-property-any
        (point-min) (point-max) 'ebox-content target-id))
      (let ((visible-before
             (buffer-substring-no-properties (point-min) (point-max))))
        (ebox-test--region-update target-id :padding-left (list 12))
        (should (equal visible-before
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))
      (let ((report (ebox-test--buffer-update-report)))
        (should (eq (plist-get report :strategy) 'owner-rerender))
        (should-not (plist-get report :root-rerender))
        (should (plist-get report :scroll-state-patch))
        (should (= (plist-get report :scroll-state-sync-count) 2))
        (should (= (plist-get report :tp-operation-count) 0)))
      (should (ebox-test--buffer-visually-matches-runtime-render-p))
      (should (ebox--scroll-region-by root-id 1 48))
      (should (ebox--scroll-region-by root-id -1 48))
      (should-not
       (text-property-any
        (point-min) (point-max) 'ebox-content target-id))
      (should (ebox-test--buffer-visually-matches-runtime-render-p))
      (should (ebox--scroll-region-by wrapper-id -1 48))
      (should
       (text-property-any
        (point-min) (point-max) 'ebox-content target-id))
      (should (ebox-test--buffer-visually-matches-runtime-render-p)))))

(ert-deftest ebox-wheel-scroll-uses-buffer-scroll-region-without-point ()
  "Wheel events from fringe-like areas should still scroll the ebox page."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height 2 :overflow scroll
                        (column
                         (box :content "A" :height 1)
                         (box :content "B" :height 1)
                         (box :content "C" :height 1)))))
         (root-id (car (ebox-region-ids layout)))
         mwheel-called)
    (ebox-test--with-rendered-buffer layout
      (switch-to-buffer (current-buffer))
      (cl-letf (((symbol-function 'event-start)
                 (lambda (_event)
                   (list (selected-window) 'mode-line '(0 . 0)
                         0 nil nil nil nil nil nil)))
                ((symbol-function 'mwheel-scroll)
                 (lambda (&rest _args)
                   (setq mwheel-called t))))
        (ebox--wheel-scroll 'fake-wheel-event 1))
      (should-not mwheel-called)
      (should (= (plist-get (ebox--scroll-get-state root-id)
                            :scroll-offset)
                 1))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "B" plain))
        (should (string-match-p "C" plain))))))

(ert-deftest ebox-scroll-first-region-ignores-zero-consumption ()
  "A zero-line scroll result should not consume the scroll event."
  (let (visited)
    (cl-letf (((symbol-function 'ebox--scroll-region-by)
               (lambda (region-id _delta &optional _prefix-budget-lines)
                 (push region-id visited)
                 (if (eq region-id 'stalled) 0 1))))
      (should (ebox--scroll-first-region-by '(stalled active) 1)))
    (should (equal (nreverse visited) '(stalled active)))))

(ert-deftest ebox-scroll-progress-requires-real-delta-or-pending ()
  "Scroll progress is either a non-zero consumed line count or lazy pending."
  (should (ebox--scroll-progress-p 1))
  (should (ebox--scroll-progress-p -1))
  (should (ebox--scroll-progress-p 'pending))
  (should-not (ebox--scroll-progress-p 0))
  (should-not (ebox--scroll-progress-p nil)))

(ert-deftest ebox-smooth-wheel-scroll-moves-immediately-then-drains ()
  "Smooth wheel scrolling should respond immediately and drain pending lines."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height 1 :overflow scroll
                        (column
                         (box :content "A" :height 1)
                         (box :content "B" :height 1)
                         (box :content "C" :height 1)))))
         (root-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (let ((ebox-wheel-smooth-scroll-lines-per-tick 1)
            (ebox-wheel-smooth-scroll-interval 60.0))
        (should (ebox--smooth-scroll-region-by root-id 2))
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :scroll-offset)
                   1))
        (ebox--smooth-scroll-tick root-id)
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :scroll-offset)
                   2))
        (should-not (gethash root-id ebox--smooth-scroll-state-table))))))

(ert-deftest ebox-smooth-wheel-scroll-coalesces-while-timer-active ()
  "Further wheel input should queue behind the active timer, not edit at once."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height 1 :overflow scroll
                        (column
                         (box :content "A" :height 1)
                         (box :content "B" :height 1)
                         (box :content "C" :height 1)
                         (box :content "D" :height 1)))))
         (root-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (let ((ebox-wheel-smooth-scroll-lines-per-tick 1)
            (ebox-wheel-smooth-scroll-interval 60.0))
        (should (ebox--smooth-scroll-region-by root-id 2))
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :scroll-offset)
                   1))
        (should (gethash root-id ebox--smooth-scroll-state-table))
        (should (ebox--smooth-scroll-region-by root-id 2))
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :scroll-offset)
                   1))
        (while (gethash root-id ebox--smooth-scroll-state-table)
          (ebox--smooth-scroll-tick root-id))
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :scroll-offset)
                   3))))))

(ert-deftest ebox-smooth-wheel-scroll-clamps-pending-to-range ()
  "Large smooth wheel input should not leave an oversized timer backlog."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height 1 :overflow scroll
                        (column
                         (box :content "A" :height 1)
                         (box :content "B" :height 1)
                         (box :content "C" :height 1)
                         (box :content "D" :height 1)))))
         (root-id (car (ebox-region-ids layout))))
    (ebox-test--with-rendered-buffer layout
      (let ((ebox-wheel-smooth-scroll-lines-per-tick 1)
            (ebox-wheel-smooth-scroll-interval 60.0))
        (should (ebox--smooth-scroll-region-by root-id 1000))
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :scroll-offset)
                   1))
        (should (<= (plist-get
                     (gethash root-id ebox--smooth-scroll-state-table)
                     :pending)
                    2))
        (while (gethash root-id ebox--smooth-scroll-state-table)
          (ebox--smooth-scroll-tick root-id))
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :scroll-offset)
                   3))))))

(ert-deftest ebox-page-scroll-bubbles-from-child-to-scrollable-ancestor ()
  "Page scrolling over a child box should scroll the nearest scrollable ancestor."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height 3 :overflow scroll
                        (column
                         (box :id "child" :content "A" :height 1)
                         (box :content "B" :height 1)
                         (box :content "C" :height 1)
                         (box :content "D" :height 1)
                         (box :content "E" :height 1)
                         (box :content "F" :height 1)))))
         (root-id (car (ebox-region-ids layout)))
         fallback-called)
    (ebox-test--with-rendered-buffer layout
      (goto-char (point-min))
      (search-forward "A")
      (backward-char)
      (cl-letf (((symbol-function 'window-body-height)
                 (lambda (&optional _window _pixelwise) 5))
                ((symbol-function 'scroll-up-command)
                 (lambda (&optional _arg)
                   (setq fallback-called t))))
        (ebox-scroll-page-down))
      (should-not fallback-called)
      (should (= (plist-get (ebox--scroll-get-state root-id)
                            :scroll-offset)
                 3))
      (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "D" plain))
        (should (string-match-p "F" plain))
        (should-not (string-match-p "A" plain))))))

(ert-deftest ebox-scroll-rerender-preserves-viewport-height-context ()
  "Scroll rerender fallback should keep viewport-height boxes clipped."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "root" :height (viewport-height) :overflow scroll
                        (column
                         (box :id "child" :content "A" :height 1)
                         (box :content "B" :height 1)
                         (box :content "C" :height 1)
                         (box :content "D" :height 1)))))
         (root-id (car (ebox-region-ids layout))))
    (let ((ebox-viewport-height 2))
      (ebox-test--with-rendered-buffer layout
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :content-height)
                   2))
        (goto-char (point-min))
        (search-forward "A")
        (backward-char)
        (ebox-scroll-down 1)
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :content-height)
                   2))
        (should (= (plist-get (ebox--scroll-get-state root-id)
                              :scroll-offset)
                   1))
        (let ((plain (buffer-substring-no-properties
                      (point-min) (point-max))))
          (should (string-match-p "B" plain))
          (should (string-match-p "C" plain))
          (should-not (string-match-p "A" plain)))))))

(ert-deftest ebox-wheel-scroll-falls-back-at-scroll-boundary ()
  "Mouse wheel should bubble to the buffer when inner scroll is at its edge."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC"
                           :height 1
                           :overflow 'scroll))
         (region-id (car (ebox-region-ids box)))
         mwheel-args)
    (ebox-test--with-rendered-buffer box
      (should (ebox--scroll-region-by region-id 3))
      (cl-letf (((symbol-function 'ebox--wheel-region-ids)
                 (lambda (_event) (list region-id)))
                ((symbol-function 'mwheel-scroll)
                 (lambda (&rest args)
                   (setq mwheel-args args))))
        (ebox--wheel-scroll 'fake-wheel-event 1 'fake-arg))
      (should (equal mwheel-args '(fake-wheel-event fake-arg))))))

(ert-deftest ebox-scroll-map-keeps-wheel-on-event-aware-handler ()
  "Mouse wheel bindings should use event-aware handlers, not line fallbacks."
  (should (eq (lookup-key ebox-scroll-map [wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [mouse-5])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [mouse-4])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [right-fringe wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [right-fringe wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [mode-line wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [mode-line wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [vertical-scroll-bar wheel-down])
              #'ebox-wheel-scroll-down))
  (should (eq (lookup-key ebox-scroll-map [vertical-scroll-bar wheel-up])
              #'ebox-wheel-scroll-up))
  (should (eq (lookup-key ebox-scroll-map [remap scroll-up-command])
              #'ebox-scroll-page-down))
  (should (eq (lookup-key ebox-scroll-map [remap scroll-down-command])
              #'ebox-scroll-page-up))
  (should (eq (lookup-key ebox-scroll-map (kbd "C-v"))
              #'ebox-scroll-page-down))
  (should (eq (lookup-key ebox-scroll-map (kbd "<next>"))
              #'ebox-scroll-page-down))
  (should (eq (lookup-key ebox-scroll-map (kbd "M-v"))
              #'ebox-scroll-page-up))
  (should (eq (lookup-key ebox-scroll-map (kbd "<prior>"))
              #'ebox-scroll-page-up))
  (should (eq (lookup-key ebox-scroll-map (kbd "n"))
              #'ebox-scroll-down))
  (should (eq (lookup-key ebox-scroll-map (kbd "p"))
              #'ebox-scroll-up)))

(ert-deftest ebox-buffer-mode-overrides-pixel-scroll-bindings ()
  "Ebox buffers should keep their own scroll bindings under pixel scrolling."
  (unless (fboundp 'pixel-scroll-precision-mode)
    (ert-skip "pixel-scroll-precision-mode is unavailable"))
  (let ((was-enabled pixel-scroll-precision-mode))
    (unwind-protect
        (with-temp-buffer
          (pixel-scroll-precision-mode 1)
          (ebox-buffer-mode 1)
          (should (eq (key-binding [wheel-down])
                      #'ebox-wheel-scroll-down))
          (should (eq (key-binding [wheel-up])
                      #'ebox-wheel-scroll-up))
          (should (eq (key-binding [right-fringe wheel-down])
                      #'ebox-wheel-scroll-down))
          (should (eq (key-binding [mode-line wheel-down])
                      #'ebox-wheel-scroll-down))
          (should (eq (key-binding [vertical-scroll-bar wheel-down])
                      #'ebox-wheel-scroll-down))
          (should (eq (key-binding (kbd "<next>"))
                      #'ebox-scroll-page-down))
          (should (eq (key-binding (kbd "<prior>"))
                      #'ebox-scroll-page-up)))
      (unless was-enabled
        (pixel-scroll-precision-mode -1)))))

(ert-deftest ebox-border-box-max-height-includes-vertical-padding ()
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A\nB\nC\nD"
                           :box-sizing 'border-box
                           :max-height 3
                           :padding '(1 0)
                           :overflow 'hidden))
         (plain (substring-no-properties (ebox-render box))))
    (should (= (ebox-string-height plain) 3))
    (should-not (string-match-p "C" plain))
    (should-not (string-match-p "D" plain))))

(ert-deftest ebox-content-box-min-height-wins-when-min-exceeds-max ()
  "Content-box height conflicts should use the minimum as the used height."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A"
                           :box-sizing 'content-box
                           :min-height 5
                           :max-height 3
                           :padding '(1 0)
                           :overflow 'hidden))
         (rendered (ebox-render box)))
    (should (= (ebox--content-height box 1) 5))
    (should (= (ebox-string-height rendered) 7))))

(ert-deftest ebox-border-box-min-height-wins-when-min-exceeds-max ()
  "Border-box height conflicts should use the minimum as the outer height."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "A"
                           :box-sizing 'border-box
                           :min-height 5
                           :max-height 3
                           :padding '(1 0)
                           :overflow 'hidden))
         (rendered (ebox-render box)))
    (should (= (ebox--content-height box 1) 3))
    (should (= (ebox-string-height rendered) 5))))

(ert-deftest ebox-border-box-max-width-includes-horizontal-padding-and-border ()
  (ebox-test--reset-runtime-state)
  (let ((box (ebox-create :content "abc abc abc abc abc abc abc abc abc abc"
                          :box-sizing 'border-box
                          :max-width '(100)
                          :padding-inline '(20)
                          :border-left '(10)
                          :border-right '(10)
                          :overflow 'hidden)))
    (should (<= (ebox--total-pixel box) 100))))

(ert-deftest ebox-auto-width-without-viewport-uses-max-content-across-all-lines ()
  "Omitted :width should fall back to the widest unwrapped content line."
  (ebox-test--reset-runtime-state)
  (let* ((content "short\nmuch wider line")
         (expected (apply #'max
                          (mapcar #'ebox--string-pixel-width
                                  (ebox-string-lines content))))
         (box (ebox-create :content content))
         (rendered (ebox-render box))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines rendered))))
    (should (= (ebox--content-pixel box) expected))
    (should (cl-every (lambda (width) (= width expected)) widths))))

(ert-deftest ebox-auto-width-stretches-to-viewport-when-available ()
  "Omitted :width and :width auto should fill the viewport margin box."
  (ebox-test--reset-runtime-state)
  (let ((ebox-viewport-width 240))
    (dolist (width-value '(nil auto))
      (let ((box (apply #'ebox-create
                        (append (list :content "short line wraps into viewport"
                                      :padding-inline '(20)
                                      :border-left '(10)
                                      :border-right '(10)
                                      :margin-inline '(5))
                                (when width-value
                                  (list :width width-value))))))
        (should (= (ebox--total-pixel box) 240))))))

(ert-deftest ebox-explicit-width-can-overflow-containing-block ()
  "A definite width remains definite even when the containing block is narrower."
  (ebox-test--reset-runtime-state)
  (let* ((ebox-viewport-width 120)
         (content "alpha beta gamma delta")
         (box (ebox-create :content content :width '(220) :wrap-mode 'word))
         (rendered (ebox-render box))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines rendered))))
    (should (cl-some (lambda (width) (> width ebox-viewport-width))
                     widths))
    (should (cl-every (lambda (width) (= width 220)) widths))))

(ert-deftest ebox-column-wrapper-width-reflows-auto-child-layout ()
  "A column wrapper width should contain auto-sized children."
  (ebox-test--reset-runtime-state)
  (let* ((ebox-viewport-width 1000)
         (node (ebox-build
                '(column :width (120)
                  (box :content "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega"
                       :wrap-mode word))))
         (rendered (ebox-render node))
         (plain (substring-no-properties rendered))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines rendered))))
    (should (cl-every (lambda (width) (<= width 120)) widths))
    (dolist (word '("alpha" "beta" "gamma" "delta" "epsilon" "theta"
                    "omega"))
      (should (string-match-p word plain)))
    (should (> (ebox-string-height rendered) 1))))

(ert-deftest ebox-wrapper-child-layout-keeps-pixel-width-with-wide-font ()
  "Engine pixel widths must not be reparsed as public character widths."
  (ebox-test--reset-runtime-state)
  (let ((ebox-viewport-width 1000))
    (cl-letf (((symbol-function 'ebox--space-pixel-width) (lambda () 7)))
      (let* ((node (ebox-build
                    '(column :width (400)
                      (box :content "X"))))
             (widths (mapcar #'ebox--string-pixel-width
                             (ebox-string-lines (ebox-render node)))))
        (should (equal widths '(400)))))))

(ert-deftest ebox-column-wrapper-width-reflows-auto-flex-layout ()
  "A column wrapper width should become the viewport for nested auto flex."
  (ebox-test--reset-runtime-state)
  (let* ((ebox-viewport-width 1000)
         (node (ebox-build
                '(column :width (240)
                  (flex :flex-wrap wrap :column-gap (10)
                        (box :content "A" :width (100))
                        (box :content "B" :width (100))
                        (box :content "C" :width (100))))))
         (rendered (ebox-render node))
         (plain-lines (ebox-string-lines
                       (substring-no-properties rendered)))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines rendered))))
    (should (cl-every (lambda (width) (<= width 240)) widths))
    (should (string-match-p "A.*B" (car plain-lines)))
    (should (cl-some (lambda (line) (string-match-p "C" line))
                     (cdr plain-lines)))))

(ert-deftest ebox-column-containing-block-does-not-expand-to-overflow-child ()
  "An overflowing definite child should not widen unrelated column rows."
  (ebox-test--reset-runtime-state)
  (let* ((ebox-viewport-width 200)
         (node (ebox-column
                (ebox-create :content "Auto row")
                (ebox-create :content "Fixed row" :width '(300))))
         (widths (mapcar #'ebox--string-pixel-width
                         (ebox-string-lines (ebox-render node)))))
    (should (equal widths '(200 300)))))

(ert-deftest ebox-width-keywords-resolve-intrinsic-content-sizes ()
  "auto, min-content, max-content, and none should keep CSS-like meanings."
  (ebox-test--reset-runtime-state)
  (let* ((content "aa bbbb")
         (max-content (ebox--string-pixel-width content))
         (min-content (ebox--string-pixel-width "bbbb")))
    (should (= (ebox--content-pixel
                (ebox-create :content content :width 'auto))
               max-content))
    (should (= (ebox--content-pixel
                (ebox-create :content content :width 'max-content))
               max-content))
    (should (= (ebox--content-pixel
                (ebox-create :content content :width 'min-content))
               min-content))
    (should (= (ebox--content-pixel
                (ebox-create :content content
                             :width '(80)
                             :max-width 'none))
               80))
    (should-error (ebox-create :content content :width 'none)
                  :type 'error)))

(ert-deftest ebox-max-content-wrapper-measures-composite-child-intrinsically ()
  "A max-content wrapper should not stretch its composite child to the viewport."
  (ebox-test--reset-runtime-state)
  (let* ((ebox-viewport-width 480)
         (lines '("Compact" "Natural width"))
         (expected
          (apply #'max (mapcar #'ebox--string-pixel-width lines)))
         (node
          (ebox-create
           :width 'max-content
           :ebox-content-node
           (apply #'ebox-column
                  (mapcar (lambda (line)
                            (ebox-create :content line))
                          lines))))
         (widths
          (mapcar #'ebox--string-pixel-width
                  (ebox-string-lines (ebox-render node)))))
    (should (equal widths (make-list (length lines) expected)))))

(ert-deftest ebox-definite-width-skips-unused-max-content-measurement ()
  "A definite preferred width should not evaluate its unused auto fallback."
  (ebox-test--reset-runtime-state)
  (let ((box (ebox-create :content "measurement must stay cold"
                          :width '(80)))
        (measurements 0)
        (original (symbol-function 'ebox--content-max-pixel)))
    (cl-letf (((symbol-function 'ebox--content-max-pixel)
               (lambda (candidate)
                 (cl-incf measurements)
                 (funcall original candidate))))
      (should (= (ebox--content-pixel box) 80))
      (should (= measurements 0)))))

(ert-deftest ebox-definite-width-still-resolves-intrinsic-constraints ()
  "Intrinsic min/max constraints must still measure definite-width content."
  (ebox-test--reset-runtime-state)
  (let* ((content "intrinsic constraint")
         (expected (ebox--string-pixel-width content))
         (box (ebox-create :content content
                           :width '(20)
                           :min-width 'max-content))
         (measurements 0)
         (original (symbol-function 'ebox--content-max-pixel)))
    (cl-letf (((symbol-function 'ebox--content-max-pixel)
               (lambda (candidate)
                 (cl-incf measurements)
                 (funcall original candidate))))
      (should (= (ebox--content-pixel box) expected))
      (should (= measurements 1)))))

(ert-deftest ebox-auto-width-keeps-max-content-fallback-without-viewport ()
  "An unresolved auto width should retain its intrinsic max-content fallback."
  (ebox-test--reset-runtime-state)
  (let ((box (ebox-create :content "auto fallback"))
        (measurements 0)
        (original (symbol-function 'ebox--content-max-pixel)))
    (cl-letf (((symbol-function 'ebox--content-max-pixel)
               (lambda (candidate)
                 (cl-incf measurements)
                 (funcall original candidate))))
      (should (> (ebox--content-pixel box) 0))
      (should (= measurements 1)))))

(ert-deftest ebox-fit-content-width-clamps-between-min-and-max-content ()
  "fit-content() should clamp by min-content and max-content."
  (ebox-test--reset-runtime-state)
  (let* ((content "aa widest")
         (min-content (ebox--string-pixel-width "widest"))
         (max-content (ebox--string-pixel-width content))
         (between (+ min-content (/ (- max-content min-content) 2))))
    (should (< min-content between))
    (should (< between max-content))
    (should (= (ebox--content-pixel
                (ebox-create :content content
                             :width (list 'fit-content (list between))))
               between))
    (should (= (ebox--content-pixel
                (ebox-create :content content
                             :width (list 'fit-content (list 1))))
               min-content))
    (should (= (ebox--content-pixel
                (ebox-create :content content
                             :width (list 'fit-content
                                          (list (+ max-content 50)))))
               max-content))))

(ert-deftest ebox-fit-content-keyword-uses-stretch-when-viewport-is-definite ()
  "The fit-content keyword should clamp stretch between intrinsic sizes."
  (ebox-test--reset-runtime-state)
  (let* ((content "aa widest")
         (min-content (ebox--string-pixel-width "widest"))
         (max-content (ebox--string-pixel-width content))
         (stretch (+ min-content (/ (- max-content min-content) 2)))
         (ebox-viewport-width stretch))
    (should (= (ebox--content-pixel
                (ebox-create :content content :width 'fit-content))
               stretch))))

(ert-deftest ebox-min-and-max-width-keywords-constrain-preferred-width ()
  "Intrinsic keywords should work on min-width and max-width too."
  (ebox-test--reset-runtime-state)
  (let* ((content "aa widest")
         (min-content (ebox--string-pixel-width "widest"))
         (max-content (ebox--string-pixel-width content))
         (between (+ min-content (/ (- max-content min-content) 2))))
    (should (= (ebox--content-pixel
                (ebox-create :content content
                             :width '(1)
                             :min-width 'max-content))
               max-content))
    (should (= (ebox--content-pixel
                (ebox-create :content content
                             :width (list (+ max-content 50))
                             :max-width 'min-content))
               min-content))
    (should (= (ebox--content-pixel
                (ebox-create :content content
                             :width '(1)
                             :min-width (list 'fit-content
                                              (list between))))
               between))
    (should (= (ebox--content-pixel
                (ebox-create :content content
                             :width (list (+ max-content 50))
                             :max-width (list 'fit-content
                                              (list between))))
               between))))

(ert-deftest ebox-stretch-and-contain-width-fill-viewport-margin-box ()
  "stretch and contain should resolve against the current viewport."
  (ebox-test--reset-runtime-state)
  (let ((ebox-viewport-width 240))
    (dolist (keyword '(stretch contain))
      (let ((box (ebox-create :content "x"
                              :width keyword
                              :padding-inline '(20)
                              :border-left '(10)
                              :border-right '(10)
                              :margin-inline '(5))))
        (should (= (ebox--total-pixel box) 240))))))

(ert-deftest ebox-max-width-clamps-used-width-before-content-minimum ()
  "A max-width smaller than one glyph should constrain used width."
  (ebox-test--reset-runtime-state)
  (cl-letf (((symbol-function 'ebox--string-pixel-width)
             (lambda (_string) 60))
            ((symbol-function 'ebox--max-char-pixel)
             (lambda (_string) 60)))
    (let ((box (ebox-create :content "W"
                            :max-width '(20)
                            :wrap-mode 'char)))
      (should (= (ebox--content-pixel box) 20))
      (should (= (ebox--total-pixel box) 20)))))

(ert-deftest ebox-min-width-wins-when-min-width-exceeds-max-width ()
  "CSS width constraints make min-width override max-width conflicts."
  (ebox-test--reset-runtime-state)
  (let ((box (ebox-create :content "short"
                          :width '(40)
                          :min-width '(120)
                          :max-width '(80))))
    (should (= (ebox--content-pixel box) 120))
    (should (= (ebox--total-pixel box) 120))))

(ert-deftest ebox-width-properties-reject-negative-values ()
  "Width, min-width, and max-width should reject negative lengths."
  (ebox-test--reset-runtime-state)
  (should-error (ebox-create :content "bad" :width '(-1)) :type 'error)
  (should-error (ebox-create :content "bad" :min-width '(-1)) :type 'error)
  (should-error (ebox-create :content "bad" :max-width '(-1)) :type 'error))

(ert-deftest ebox-edge-properties-reject-negative-values ()
  "Public edge properties and engine longhands should reject negatives."
  (ebox-test--reset-runtime-state)
  (dolist (props '((:padding -1)
                   (:padding-left-pixel -1)
                   (:margin -1)
                   (:margin-top-height -1)
                   (:border-width -1)
                   (:border-top-width -1)
                   (:border-left-pixel -1)))
    (should-error
     (apply #'ebox-create (append '(:content "bad") props))
     :type 'error)))

(ert-deftest ebox-line-min-content-skips-discarded-space-measurements ()
  "Literal spaces split runs and plain ASCII reuses exact character widths."
  (let ((line (copy-sequence "fi x"))
        (ebox--display-cache-validated t)
        (ebox--char-width-cache (make-hash-table :test 'eql))
        measured)
    (puthash ?i 4 ebox--char-width-cache)
    (add-text-properties 0 1 '(face (:height 1.2)) line)
    (add-text-properties 3 4 '(display (raise 0.1)) line)
    (cl-letf (((symbol-function 'ebox--string-pixel-width)
               (lambda (string)
                 (push (substring-no-properties string) measured)
                 (pcase (substring-no-properties string)
                   ("f" 3)
                   ("x" 2)
                   (" " 99)
                   (_ 99)))))
      ;; Per-grapheme addition remains intentional: measuring the whole "fi"
      ;; could produce a non-additive ligature width and change the contract.
      (should (= (ebox--line-min-content-pixel line) 7))
      (should (equal (nreverse measured) '("f" "x"))))))

(ert-deftest ebox-region-update-valid-paint-and-invalid-edge-is-atomic ()
  "Invalid geometry should fail before a valid sibling property mutates."
  (ebox-test--reset-runtime-state)
  (let* ((box (ebox-create :content "Atomic"
                           :width '(120)
                           :bgcolor "#111111"
                           :padding-left-pixel 2))
         (region-id (car (ebox-region-ids box))))
    (ebox-test--with-rendered-buffer box
      (should-error
       (ebox-test--region-update region-id
                           :bgcolor "#222222"
                           :padding-left-pixel -1)
       :type 'error)
      (should (equal (ebox-get box :bgcolor) "#111111"))
      (should (= (ebox-get box :padding-left-pixel) 2)))))

(ert-deftest ebox-region-update-no-op-skips-rollback-snapshot ()
  "A legal no-op should return before discovering rollback scope."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id "root" :width (240) :height 1 :overflow scroll
             (box :id "target" :content "same" :width (120))))))
    (ebox-test--with-rendered-buffer layout
      (let ((target-id
             (ebox-test--selector-region-id (current-buffer) "#target")))
        (cl-letf
            (((symbol-function 'ebox--node-all-region-ids)
              (lambda (&rest _)
                (ert-fail "no-op discovered subtree rollback scope")))
             ((symbol-function
               'ebox--scroll-state-region-ids-containing-node-ids)
              (lambda (&rest _)
                (ert-fail "no-op discovered containing scroll scope"))))
          (let ((report
                 (ebox-test--region-update target-id :content "same")))
            (should (eq (plist-get report :strategy) 'no-op))
            (should (= (plist-get report :dirty-count) 0))))))))

(ert-deftest ebox-region-update-rollback-snapshot-keeps-scroll-owner-box-by-identity ()
  "A child rollback snapshot should retain its scroll owner's box identity."
  (ebox-test--reset-runtime-state)
  (let ((layout
         (ebox-build
          '(box :id "root" :width (viewport) :height (viewport-height)
                :overflow scroll
             (column :width (viewport)
               (box :id "target" :content "paint" :width (120)
                    :color "#111111")
               (box :content "tail" :width (120)))))))
    (let ((ebox-viewport-width 240)
          (ebox-viewport-height 1))
      (ebox-test--with-rendered-buffer layout
        (let* ((root-id
                (ebox-test--selector-region-id (current-buffer) "#root"))
               (target-id
                (ebox-test--selector-region-id (current-buffer) "#target"))
               (scroll-box
                (plist-get (ebox--scroll-get-state root-id) :box))
               (original-copy-tree (symbol-function 'copy-tree)))
          (should scroll-box)
          (cl-letf
              (((symbol-function 'copy-tree)
                (lambda (tree &optional vectors-and-records)
                  (when (eq tree scroll-box)
                    (ert-fail "deep-copied containing scroll owner box"))
                  (funcall original-copy-tree tree vectors-and-records))))
            (ebox-test--region-update target-id :color "#222222"))
          (should (equal
                   (ebox-get
                    (gethash target-id ebox--region-box-table) :color)
                   "#222222")))))))

(ert-deftest ebox-region-update-rolls-back-when-rerender-fails ()
  "A failed local rerender must leave model, buffer, and report unchanged."
  (ebox-test--reset-runtime-state)
  (let* ((layout (ebox-build
                  '(box :id "target" :content "before" :width (120))))
         (report-before 'keep-report))
    (ebox-test--with-rendered-buffer layout
      (let* ((buffer (current-buffer))
             (region-id (ebox-test--selector-region-id buffer "#target"))
             (box (gethash region-id ebox--region-box-table))
             (box-before (copy-tree box))
             (text-before (buffer-string)))
        (ebox-test--set-buffer-update-report buffer report-before)
        (cl-letf (((symbol-function 'ebox-surface--render-candidate)
                   (lambda (&rest _)
                     (error "Injected rerender failure"))))
          (should-error
           (ebox-test--region-update region-id :content "after")
           :type 'error))
        (should (equal box box-before))
        (should (equal-including-properties (buffer-string) text-before))
        (should (eq (ebox-buffer-update-report buffer) report-before))))))

(ert-deftest ebox-cjk-wraps-by-character-width-in-word-mode ()
  (ebox-test--reset-runtime-state)
  (let* ((content "你好世界")
         (width (* 2 (ebox--string-pixel-width "你")))
         (lines (ebox-string-lines
                 (substring-no-properties
                  (ebox-render
                   (ebox-create :content content
                                :width (list width)
                                :wrap-mode 'word))))))
    (should (= (length lines) 2))
    (should (string-prefix-p "你好" (nth 0 lines)))
    (should (string-prefix-p "世界" (nth 1 lines)))
    (dolist (line lines)
      (should (<= (ebox--string-pixel-width line) width)))))

(ert-deftest ebox-wrap-keeps-combining-mark-with-base-character ()
  (ebox-test--reset-runtime-state)
  (let* ((cluster "é")
         (text (concat cluster cluster))
         (width (ebox--string-pixel-width cluster)))
    (should (equal (mapcar #'substring-no-properties
                           (ebox--wrap-line text width 'char))
                   (list cluster cluster)))))

(ert-deftest ebox-word-wrap-skips-overflowing-separator-at-line-break ()
  (ebox-test--reset-runtime-state)
  (let* ((text "normal behaves stretch-like for auto cross size in this DSL.")
         (width (ebox--string-pixel-width "stretch-like for"))
         (lines (ebox--wrap-line text width 'word)))
    (dolist (line lines)
      (should (<= (ebox--string-pixel-width line) width)))
    (should-not (cl-some (lambda (line)
                           (string-prefix-p " " line))
                         lines))))

(ert-deftest ebox-wrap-keeps-emoji-zwj-and-regional-indicator-clusters ()
  (ebox-test--reset-runtime-state)
  (let ((family "👨‍👩‍👧‍👦")
        (china "🇨🇳")
        (usa "🇺🇸"))
    (should (equal (mapcar #'substring-no-properties
                           (ebox--wrap-line (concat family family)
                                            (ebox--string-pixel-width family)
                                            'char))
                   (list family family)))
    (should (equal (mapcar #'substring-no-properties
                           (ebox--wrap-line (concat china usa)
                                            (ebox--string-pixel-width china)
                                            'char))
                   (list china usa)))))

(ert-deftest ebox-kp-wrap-mode-invokes-ekp-justification ()
  (ebox-test--reset-runtime-state)
  (let (require-called justify-args)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (when (eq feature 'ekp)
                   (setq require-called t))
                 t))
              ((symbol-function 'ekp-pixel-justify)
               (lambda (text width)
                 (setq justify-args (list text width))
                 text)))
      (ebox-render (ebox-create :content "abc"
                                :width '(100)
                                :wrap-mode 'kp)))
    (should require-called)
    (should (equal justify-args (list "abc" 100)))))

(ert-deftest ebox-kp-wrap-mode-respects-text-align ()
  "KP-wrapped lines should honor the box's horizontal text alignment."
  (ebox-test--reset-runtime-state)
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'ekp) t)))
            ((symbol-function 'ekp-pixel-justify)
             (lambda (&rest _)
               "abc\nx")))
    (dolist (align '(center right))
      (let* ((box (ebox-create :content "ignored"
                               :width '(100)
                               :wrap-mode 'kp
                               :text-align align))
             (width (ebox--content-pixel box))
             (rendered (ebox-render box))
             (line (car (ebox-string-lines rendered)))
             (expected (ebox--pixel-reach "abc" width align)))
        (should (equal (get-text-property 0 'display line)
                       (get-text-property 0 'display expected)))))))

(ert-deftest ebox-kp-wrap-preserves-content-width-for-ragged-lines ()
  (ebox-test--reset-runtime-state)
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'ekp) t)))
            ((symbol-function 'ekp-pixel-justify)
             (lambda (_text width)
               (concat (ebox-pixel-space width) "\nshort"))))
    (let* ((rendered (ebox-render
                      (ebox-create :content "ignored"
                                   :width '(100)
                                   :wrap-mode 'kp)))
           (widths (mapcar #'ebox-string-pixel-width
                           (ebox-string-lines rendered))))
      (should (equal widths '(100 100))))))

(ert-deftest ebox-content-face-keeps-foreground-and-background ()
  (ebox-test--reset-runtime-state)
  (let* ((rendered (ebox-render
                    (ebox-create :content "Face"
                                 :width 40
                                 :color "#abcdef"
                                 :bgcolor "#123456")))
         (face (ebox-test--first-content-face rendered)))
    (should (ebox-test--face-has-key-value-p face :foreground "#abcdef"))
    (should (ebox-test--face-has-key-value-p face :background "#123456"))))

(ert-deftest ebox-border-faces-keep-side-specific-properties ()
  (ebox-test--reset-runtime-state)
  (let* ((rendered (ebox-render
                    (ebox-create :content "Border"
                                 :width 60
                                 :padding '(1 1)
                                 :border '(1 "#ff0000"))))
         (left-face (ebox-test--face-at-property rendered 'ebox-bl))
         (right-face (ebox-test--face-at-property rendered 'ebox-br))
         (top-face (ebox-test--face-at-property rendered 'ebox-bt))
         (bottom-face (ebox-test--face-at-property rendered 'ebox-bb)))
    (should-not (ebox-test--face-has-key-p left-face :inverse-video))
    (should (ebox-test--face-has-key-value-p left-face :background "#ff0000"))
    (should-not (ebox-test--face-has-key-p right-face :inverse-video))
    (should (ebox-test--face-has-key-value-p right-face :background "#ff0000"))
    (should (ebox-test--face-has-key-value-p top-face :overline "#ff0000"))
    (should (ebox-test--face-has-key-value-p
             bottom-face
             :underline
             '(:position t :color "#ff0000")))))

(ert-deftest ebox-border-faces-omit-unspecified-frame-colors ()
  (ebox-test--reset-runtime-state)
  (let ((original-frame-parameter (symbol-function 'frame-parameter)))
    (dolist (sentinel '(unspecified unspecified-fg unspecified-bg
                       "unspecified" "unspecified-fg" "unspecified-bg"))
      (cl-letf (((symbol-function 'frame-parameter)
                 (lambda (frame parameter)
                   (if (eq parameter 'foreground-color)
                       sentinel
                     (funcall original-frame-parameter frame parameter)))))
        (let* ((rendered (ebox-render
                          (ebox-create :content "Border"
                                       :width 60
                                       :padding '(1 1)
                                       :border t)))
               (left-face (ebox-test--face-at-property rendered 'ebox-bl))
               (right-face (ebox-test--face-at-property rendered 'ebox-br))
               (top-face (ebox-test--face-at-property rendered 'ebox-bt))
               (bottom-face (ebox-test--face-at-property rendered 'ebox-bb)))
          (should (ebox-test--face-has-key-value-p
                   left-face :inverse-video t))
          (should (ebox-test--face-has-key-value-p
                   right-face :inverse-video t))
          (should (ebox-test--face-has-key-value-p top-face :overline t))
          (should (ebox-test--face-has-key-value-p
                   bottom-face :underline '(:position t))))))))

(ert-deftest ebox-horizontal-borders-cover-side-border-corners ()
  (ebox-test--reset-runtime-state)
  (require 'face-remap)
  (let* ((text-scale-mode-amount 2)
         (rendered (ebox-render
                    (ebox-create :content "Border"
                                 :width 120
                                 :padding '(0 (8))
                                 :border '(1 "#ff0000"))))
         (lines (ebox-string-lines rendered))
         (top (car lines))
         (bottom (car (last lines)))
         (top-left (get-text-property 0 'face top))
         (top-right (get-text-property (1- (length top)) 'face top))
         (bottom-left (get-text-property 0 'face bottom))
         (bottom-right (get-text-property (1- (length bottom)) 'face bottom)))
    (dolist (face (list top-left top-right))
      (should (ebox-test--face-has-key-value-p
               face :background "#ff0000"))
      (should (ebox-test--face-has-key-value-p face :overline "#ff0000")))
    (dolist (face (list bottom-left bottom-right))
      (should (ebox-test--face-has-key-value-p
               face :background "#ff0000"))
      (should (ebox-test--face-has-key-value-p
               face :underline '(:position t :color "#ff0000"))))))

(ert-deftest ebox-horizontal-borders-cover-side-border-corners-when-shrunk ()
  (ebox-test--reset-runtime-state)
  (require 'face-remap)
  (let* ((text-scale-mode-amount -2)
         (rendered (ebox-render
                    (ebox-create :content "Border"
                                 :width 120
                                 :padding '(0 (8))
                                 :border '(1 "#ff0000"))))
         (lines (ebox-string-lines rendered))
         (top (car lines))
         (bottom (car (last lines)))
         (top-left (get-text-property 0 'face top))
         (top-right (get-text-property (1- (length top)) 'face top))
         (bottom-left (get-text-property 0 'face bottom))
         (bottom-right (get-text-property (1- (length bottom)) 'face bottom)))
    (dolist (face (list top-left top-right))
      (should (ebox-test--face-has-key-value-p
               face :background "#ff0000"))
      (should (ebox-test--face-has-key-value-p face :overline "#ff0000")))
    (dolist (face (list bottom-left bottom-right))
      (should (ebox-test--face-has-key-value-p
               face :background "#ff0000"))
      (should (ebox-test--face-has-key-value-p
               face :underline '(:position t :color "#ff0000"))))))

(ert-deftest ebox-horizontal-borders-do-not-cover-horizontal-margins ()
  (ebox-test--reset-runtime-state)
  (let* ((rendered (ebox-render
                    (ebox-create :content "Border"
                                 :width 80
                                 :margin '(0 (8) 0 (8))
                                 :border '(1 "#ff0000"))))
         (lines (ebox-string-lines rendered))
         (top (car lines))
         (bottom (car (last lines)))
         (top-left-margin (get-text-property 0 'face top))
         (top-left-border (get-text-property 1 'face top))
         (top-right-border (get-text-property (- (length top) 2) 'face top))
         (top-right-margin (get-text-property (1- (length top)) 'face top))
         (bottom-left-margin (get-text-property 0 'face bottom))
         (bottom-left-border (get-text-property 1 'face bottom))
         (bottom-right-border (get-text-property (- (length bottom) 2) 'face bottom))
         (bottom-right-margin (get-text-property (1- (length bottom)) 'face bottom)))
    (dolist (face (list top-left-border top-right-border))
      (should (ebox-test--face-has-key-value-p
               face :background "#ff0000"))
      (should (ebox-test--face-has-key-value-p face :overline "#ff0000")))
    (dolist (face (list bottom-left-border bottom-right-border))
      (should (ebox-test--face-has-key-value-p
               face :background "#ff0000"))
      (should (ebox-test--face-has-key-value-p
               face :underline '(:position t :color "#ff0000"))))
    (dolist (face (list top-left-margin top-right-margin))
      (should-not (ebox-test--face-has-key-p face :overline)))
    (dolist (face (list bottom-left-margin bottom-right-margin))
      (should-not (ebox-test--face-has-key-p face :underline)))))

(ert-deftest ebox-pixel-cache-invalidates-when-display-signature-changes ()
  (ebox-test--reset-runtime-state)
  (cl-letf (((symbol-function 'ebox--display-signature)
             (let ((signature 'first))
               (lambda () signature))))
    (clrhash ebox--char-width-cache)
    (ebox--clear-string-pixel-width-cache)
    (setq ebox--space-pixel-cache nil)
    (setq ebox--display-signature-cache nil)
    (ebox--char-pixel-width ?A)
    (should (= (hash-table-count ebox--char-width-cache) 1))
    (should (> (hash-table-count ebox--string-pixel-width-cache) 0))
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda () 'second)))
      (ebox--ensure-display-cache-current)
      (should (= (hash-table-count ebox--char-width-cache) 0))
      (should (= (hash-table-count ebox--string-pixel-width-cache) 0))
      (should-not ebox--space-pixel-cache)
      (should (equal ebox--display-signature-cache 'second)))))

(ert-deftest ebox-display-signature-includes-face-remapping ()
  (ebox-test--reset-runtime-state)
  (let ((plain (ebox--display-signature))
        (face-remapping-alist '((default (:height 1.4)))))
    (should-not (equal plain (ebox--display-signature)))))

(ert-deftest ebox-pixel-width-respects-text-scale-with-fixed-spaces ()
  (ebox-test--reset-runtime-state)
  (require 'face-remap)
  (let* ((plain (ebox--string-pixel-width "AAAA"))
         (fixed (ebox-pixel-space 30))
         (text-scale-mode-amount 2)
         (scaled (ebox--string-pixel-width "AAAA"))
         (scaled-with-fixed (ebox--string-pixel-width
                             (concat "AAAA" fixed))))
    (should (> scaled plain))
    (should (= scaled-with-fixed (+ scaled 30)))))

(ert-deftest ebox-pixel-width-caches-plain-lines-during-render-context ()
  "Repeated plain text width checks should share the render-local cache."
  (ebox-test--reset-runtime-state)
  (let ((ebox--display-cache-validated t)
        (ebox--render-string-pixel-width-cache (make-hash-table :test 'equal))
        (ebox--string-pixel-width-cache (make-hash-table :test 'equal))
        (ebox--string-pixel-width-cache-ring
         (make-vector ebox--string-pixel-width-cache-max-entries nil))
        (ebox--string-pixel-width-cache-ring-index 0)
        (calls 0))
    (cl-letf (((symbol-function 'string-pixel-width)
               (lambda (string)
                 (cl-incf calls)
                 (length string))))
      (should (= (ebox--string-pixel-width "cached") 6))
      (should (= (ebox--string-pixel-width "cached") 6))
      (should (= calls 1)))))

(ert-deftest ebox-pixel-width-reuses-plain-lines-across-render-transactions ()
  "Stable display transactions should share plain string measurements."
  (ebox-test--reset-runtime-state)
  (let ((ebox--display-signature-cache 'stable)
        (probe (format "cross-render-%S" (make-symbol "probe")))
        (calls 0))
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda () 'stable))
              ((symbol-function 'string-pixel-width)
               (lambda (string)
                 (cl-incf calls)
                 (length string))))
      (dotimes (_ 2)
        (ebox--with-validated-display-cache
          (ebox--string-pixel-width probe)))
      (should (= calls 1)))))

(ert-deftest ebox-pixel-width-reuses-face-only-lines-with-face-isolation ()
  "Display-scoped measurements should reuse equal faces without collisions."
  (ebox-test--reset-runtime-state)
  (let ((ebox--display-signature-cache 'stable)
        (bold (propertize "face-cache" 'face 'bold))
        (italic (propertize "face-cache" 'face 'italic))
        (calls 0))
    (cl-letf (((symbol-function 'ebox--display-signature)
               (lambda () 'stable))
              ((symbol-function 'string-pixel-width)
               (lambda (string)
                 (cl-incf calls)
                 (if (eq (get-text-property 0 'face string) 'bold)
                     10
                   20))))
      (should
       (= (ebox--with-validated-display-cache
            (ebox--string-pixel-width bold))
          10))
      (should
       (= (ebox--with-validated-display-cache
            (ebox--string-pixel-width bold))
          10))
      (should
       (= (ebox--with-validated-display-cache
            (ebox--string-pixel-width italic))
          20))
      (should (= calls 2)))))

(ert-deftest ebox-persistent-pixel-width-cache-stays-bounded ()
  "Display-scoped reusable string widths should evict at their entry cap."
  (ebox-test--reset-runtime-state)
  (let ((ebox--display-cache-validated t)
        (ebox--render-string-pixel-width-cache nil)
        (ebox--string-pixel-width-cache (make-hash-table :test 'equal))
        (ebox--string-pixel-width-cache-ring
         (make-vector ebox--string-pixel-width-cache-max-entries nil))
        (ebox--string-pixel-width-cache-ring-index 0))
    (cl-letf (((symbol-function 'string-pixel-width)
               (lambda (string) (length string))))
      (dotimes (index (+ ebox--string-pixel-width-cache-max-entries 17))
        (ebox--string-pixel-width (format "measurement-%d" index))))
    (should
     (= (hash-table-count ebox--string-pixel-width-cache)
        ebox--string-pixel-width-cache-max-entries))))

(ert-deftest ebox-string-max-pixel-width-works-without-render-cache ()
  "Multiline max-width measurement should not require a render-local cache."
  (ebox-test--reset-runtime-state)
  (let ((ebox--display-cache-validated t)
        (ebox--render-string-max-pixel-width-cache nil))
    (cl-letf (((symbol-function 'ebox--string-pixel-width)
               (lambda (line)
                 (length (substring-no-properties line)))))
      (should (= (ebox--string-max-pixel-width "wide\nn") 4)))))

(ert-deftest ebox-flex-string-width-caches-rendered-strings ()
  "Repeated flex width checks should reuse render-local rendered string widths."
  (ebox-test--reset-runtime-state)
  (let ((ebox--display-cache-validated t)
        (ebox--render-string-pixel-width-cache (make-hash-table :test 'equal))
        (ebox--render-string-max-pixel-width-cache (make-hash-table :test 'eq))
        (rendered (concat (propertize "wide" 'face 'bold)
                          "\n"
                          (propertize "narrow" 'display '(space :width (2)))))
        (calls 0))
    (cl-letf (((symbol-function 'ebox--string-pixel-width)
               (lambda (line)
                 (cl-incf calls)
                 (length (substring-no-properties line)))))
      (should (= (ebox--flex-string-width rendered) 6))
      (should (= (ebox--flex-string-width rendered) 6))
      (should (= calls 2)))))

(ert-deftest ebox-flex-recache-skips-visited-source-subtrees ()
  "Repeated source recache calls should not walk the same subtree twice."
  (ebox-test--reset-runtime-state)
  (let* ((source (ebox-column
                  (ebox-create :content "A")
                  (ebox-create :content "B")))
         (ebox--render-recached-source-node-cache
          (make-hash-table :test 'eq))
         (original-puthash (symbol-function 'puthash))
         (region-table-writes 0))
    (ebox-region-ids source)
    (cl-letf (((symbol-function 'puthash)
               (lambda (key value table)
                 (when (eq table ebox--region-box-table)
                   (cl-incf region-table-writes))
                 (funcall original-puthash key value table))))
      (ebox--flex-recache-source-boxes source)
      (ebox--flex-recache-source-boxes source))
    (should (= region-table-writes 2))))

(ert-deftest ebox-face-height-width-detection-handles-shrinking-text ()
  (ebox-test--reset-runtime-state)
  (let ((ebox--face-height-width-cache nil)
        (factor 0.7))
    (cl-letf (((symbol-function 'string-pixel-width)
               (lambda (string)
                 (if (get-text-property 0 'face string)
                     70
                   101))))
      (should (ebox--face-height-affects-width-p factor))
      (should (= (ebox--scaled-string-pixel-width "probe" factor)
                 70)))))








(ert-deftest ebox-visibility-hidden-suppresses-ink-and-keeps-footprint ()
  "A hidden box renders blank with identical text, lengths, and metadata."
  (let* ((make-box
          (lambda (visibility)
            (ebox-create :content "Hello" :width (list 90) :border t
                         :border-color "#AA3311" :bgcolor "#223344"
                         :color "#FFFFFF" :padding '(0 1)
                         :visibility visibility)))
         (visible (ebox-render (funcall make-box 'visible)))
         (hidden (ebox-render (funcall make-box 'hidden))))
    (should (equal (substring-no-properties visible)
                   (substring-no-properties hidden)))
    (should (equal (mapcar #'length (ebox-string-lines visible))
                   (mapcar #'length (ebox-string-lines hidden))))
    ;; No character carries a face, every character renders under a
    ;; display spec, and each line's blank cover is measured to the
    ;; visible line's exact pixel width.
    (dotimes (index (length hidden))
      (unless (eq (aref hidden index) ?\n)
        (should-not (get-text-property index 'face hidden))
        (should (get-text-property index 'display hidden))))
    (cl-loop for visible-line in (ebox-string-lines visible)
             for hidden-line in (ebox-string-lines hidden)
             do (should (= (ebox-string-pixel-width visible-line)
                           (ebox-string-pixel-width hidden-line))))
    ;; Region metadata still identifies the same owner surfaces at the
    ;; content characters.
    (let ((position (string-match "Hello"
                                  (substring-no-properties visible))))
      (should position)
      (should (get-text-property position 'ebox-content-owner visible))
      (should (get-text-property position 'ebox-content-owner hidden)))))

(ert-deftest ebox-visibility-toggle-is-local-and-restores-exactly ()
  "Hiding and showing one region never widens beyond its owner.
The buffer text never changes; showing again restores the visible
publication with properties intact."
  (let* ((buffer (generate-new-buffer " *ebox-visibility*"))
         (root (ebox-create
                :width (list 300)
                :ebox-content-node
                (ebox-column
                 (ebox-create :content "Header line" :id 'header
                              :width (list 300))
                 (ebox-create :content "Secret content" :id 'secret
                              :width (list 300) :border t
                              :bgcolor "#224466" :color "#FFFFFF")
                 (ebox-create :content "Footer line" :id 'footer
                              :width (list 300))))))
    (unwind-protect
        (progn
          (ebox-render-to-buffer buffer root)
          (let ((before (with-current-buffer buffer (buffer-string))))
            (ebox-selector-update-buffer buffer "#secret"
                                         :visibility 'hidden)
            (let ((report (ebox-test--buffer-update-report)))
              (should (memq (plist-get report :strategy)
                            '(span-patch owner-rerender paint-patch)))
              (should (= (plist-get report :patch-count) 1)))
            (should (equal (with-current-buffer buffer
                             (substring-no-properties (buffer-string)))
                           (substring-no-properties before)))
            (ebox-selector-update-buffer buffer "#secret"
                                         :visibility 'visible)
            (let ((report (ebox-test--buffer-update-report)))
              (should (memq (plist-get report :strategy)
                            '(span-patch owner-rerender paint-patch)))
              (should (= (plist-get report :patch-count) 1)))
            (should (equal-including-properties
                     (with-current-buffer buffer (buffer-string))
                     before))))
      (kill-buffer buffer))))

(ert-deftest ebox-parent-border-color-patch-never-recolors-descendants ()
  "A parent border-color paint patch touches only the owner's chrome.
Border surfaces belong to each box: a full render never propagates an
ancestor border color into a descendant's border runs, so the cheap
face patch must match that exactly (issue014)."
  (ebox-test--reset-runtime-state)
  (let* ((make-tree
          (lambda (parent-color)
            (ebox-create
             :id 'parent :width (list 400)
             :border (list '(4) 'solid parent-color)
             :padding '(1 (12))
             :ebox-content-node
             (ebox-column
              (ebox-create :id 'child :content "CHILD" :width (list 200)
                           :border '((4) solid "#00AA00"))))))
         (visual-runs
          (lambda (buffer role)
            (with-current-buffer buffer
              (let (runs (position (point-min)))
                (while (< position (point-max))
                  (when (get-text-property position role)
                    (push (list (line-number-at-pos position)
                                (get-text-property position role)
                                (ebox-test--face-visual-attributes
                                 (get-text-property position 'face)))
                          runs))
                  (setq position
                        (or (next-single-property-change position role)
                            (point-max))))
                (nreverse runs)))))
         (patched (generate-new-buffer " *i14-patched*"))
         (reference (generate-new-buffer " *i14-reference*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer patched (funcall make-tree "#AA0000"))
          (ebox-selector-update-buffer patched "#parent"
                                       :border-color "#0000AA")
          (should (eq (plist-get (ebox-test--buffer-update-report) :strategy)
                      'paint-patch))
          (ebox-test--reset-runtime-state)
          (ebox-render-to-buffer reference (funcall make-tree "#0000AA"))
          (dolist (role '(ebox-bl ebox-br ebox-bt ebox-bb))
            (ert-info ((format "border role %S" role))
              (should (equal
                       (mapcar (lambda (run) (cons (car run) (caddr run)))
                               (funcall visual-runs patched role))
                       (mapcar (lambda (run) (cons (car run) (caddr run)))
                               (funcall visual-runs reference role)))))))
      (kill-buffer patched)
      (kill-buffer reference))))

;;; ebox-core-render-tests.el ends here
