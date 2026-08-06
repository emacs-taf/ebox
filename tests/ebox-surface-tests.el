;;; ebox-surface-tests.el --- TP surface projection tests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(unless load-file-name
  (error "This test file must be loaded from disk, not eval'ed directly"))

(setq load-prefer-newer t)

(load-file (expand-file-name "../ebox.el"
                            (file-name-directory load-file-name)))
(require 'tp-surface)

(defun ebox-surface-test--reset-render-state ()
  "Reset render identities and side tables used by projection tests."
  (setq ebox--region-id-counter 0
        ebox--runtime-node-id-counter 0)
  (dolist (table (list ebox--region-box-table
                       ebox--scroll-global-state))
    (clrhash table)))

(defun ebox-surface-test--interactive-content ()
  "Return fresh interactive propertized content for projection tests."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'ignore)
    (propertize "Open" 'keymap map 'mouse-face 'highlight
                'help-echo "Open this item")))

(defun ebox-surface-test--fixtures ()
  "Return named fresh layout builders covering active Ebox layout kinds."
  (list
   (cons 'box
         (lambda ()
           (ebox-create :key 'box :content (ebox-surface-test--interactive-content)
                        :width '(120) :padding '(1 (4))
                        :border "#334155" :bgcolor "#E2E8F0"
                        :color "#0F172A")))
   (cons 'row-column
         (lambda ()
           (ebox-column
            (ebox-row
             (ebox-create :key 'left :content "Left" :width '(70)
                          :bgcolor "#DBEAFE" :color "#172554")
             (ebox-create :key 'right :content "Right\nDetail" :width '(90)
                          :bgcolor "#DCFCE7" :color "#14532D"))
            (ebox-create :key 'footer :content "Footer" :width '(160)
                         :bgcolor "#F1F5F9" :color "#0F172A"))))
   (cons 'flex
         (lambda ()
           (ebox-flex
            :width '(210) :flex-wrap 'wrap :column-gap '(10)
            (ebox-flex-item
             (ebox-create :key 'grow :content "Grow" :width '(80)
                          :bgcolor "#EDE9FE" :color "#2E1065")
             :flex-grow 1 :flex-basis '(80))
            (ebox-flex-item
             (ebox-create :key 'fixed :content "Fixed" :width '(120)
                          :bgcolor "#FFEDD5" :color "#7C2D12")))))
   (cons 'grid
         (lambda ()
           (ebox-grid
            :width '(220) :grid-template-columns '((70) 1fr)
            :grid-template-rows '(2) :gap '(1 (8))
            :border "#475569"
            (ebox-create :key 'grid-left :content "A\nAA"
                         :bgcolor "#E0F2FE" :color "#0C4A6E")
            (ebox-create :key 'grid-right :content "B\nBB"
                         :bgcolor "#FCE7F3" :color "#831843"))))
   (cons 'overflow-scroll
         (lambda ()
           (ebox-create :key 'scroll :content "zero\none\ntwo\nthree"
                        :width '(100) :height 2 :overflow 'scroll
                        :bgcolor "#1E293B" :color "#F8FAFC")))))

(defun ebox-surface-test--render-fresh (builder projector-p)
  "Render BUILDER after a reset, using the TP projector when PROJECTOR-P."
  (ebox-surface-test--reset-render-state)
  (let ((ebox-viewport-width 240)
        (ebox-viewport-height 12)
        (node (funcall builder)))
    (if projector-p
        (tp-surface-materialize-string
         (ebox-surface-producer node))
      (ebox-render node))))

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

(ert-deftest ebox-surface-projects-every-layout-with-exact-equivalence ()
  "TP projection should preserve every character and text property interval."
  (dolist (fixture (ebox-surface-test--fixtures))
    (let* ((builder (cdr fixture))
           (expected (ebox-surface-test--render-fresh builder nil))
           (actual (ebox-surface-test--render-fresh builder t)))
      (should (equal-including-properties actual expected))
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

(ert-deftest ebox-surface-plan-stays-free-of-runtime-state ()
  "The generic surface plan should not contain markers or runtime handles."
  (let ((original (symbol-function 'tp-surface-result-create))
        captured)
    (cl-letf (((symbol-function 'tp-surface-result-create)
               (lambda (plan &optional client-state)
                 (setq captured plan)
                 (funcall original plan client-state))))
      (ebox-surface-test--render-fresh
       (cdr (assq 'box (ebox-surface-test--fixtures))) t))
    (should (tp-surface-plan-p captured))
    (should (ebox-surface-test--plan-pure-p captured))))

(ert-deftest ebox-surface-projection-does-not-mutate-a-buffer ()
  "Pure projection should not call any final buffer mutation primitive."
  (cl-letf (((symbol-function 'insert)
             (lambda (&rest _) (error "Unexpected buffer insertion")))
            ((symbol-function 'erase-buffer)
             (lambda (&rest _) (error "Unexpected buffer erase")))
            ((symbol-function 'delete-region)
             (lambda (&rest _) (error "Unexpected buffer deletion")))
            ((symbol-function 'replace-region-contents)
             (lambda (&rest _) (error "Unexpected buffer replacement"))))
    (should
     (stringp
      (ebox-surface-test--render-fresh
       (cdr (assq 'row-column (ebox-surface-test--fixtures))) t)))))

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
                 (ebox-surface-producer
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
          (ebox-create :key 'shared :content "Shared" :width '(100)
                       :bgcolor "#E2E8F0" :color "#0F172A"))
         (first-buffer (generate-new-buffer " *ebox-surface-first*"))
         (second-buffer (generate-new-buffer " *ebox-surface-second*"))
         first second)
    (unwind-protect
        (progn
          (setq first
                (tp-surface-mount
                 first-buffer (ebox-surface-producer source)
                 '(:capability content)))
          (setq second
                (tp-surface-mount
                 second-buffer (ebox-surface-producer source)
                 '(:capability content)))
          (let* ((first-state (tp-surface-client-state first))
                 (second-state (tp-surface-client-state second))
                 (first-root (plist-get first-state :root-node))
                 (second-root (plist-get second-state :root-node)))
            (should-not (eq first-root second-root))
            (should-not (eq (plist-get first-root :surface-object)
                            (plist-get second-root :surface-object)))
            (should-not (plist-member source :node-id))
            (should-not (plist-member source :region-id))
            (should-not (plist-member source :surface-object))))
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
                (ebox-row
                 (ebox-create :key 'left :content "Left" :width '(60))
                 (ebox-create :key 'right :content "Right" :width '(60))))
               (_mount
                (setq surface
                      (tp-surface-mount
                       buffer (ebox-surface-producer first-source)
                       '(:capability content))))
               (first-state (tp-surface-client-state surface))
               (left (ebox-surface-test--object-by-key first-state 'left))
               (right (ebox-surface-test--object-by-key first-state 'right))
               (next-source
                (ebox-row
                 (ebox-create :key 'right :content "Right!" :width '(60))
                 (ebox-create :key 'left :content "Left!" :width '(60)))))
          (tp-surface-update
           surface (ebox-surface-producer next-source first-state))
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

(ert-deftest ebox-render-materializes-through-tp-surface ()
  "The public string renderer should materialize one ephemeral TP surface."
  (ebox-surface-test--reset-render-state)
  (let ((original (symbol-function 'tp-surface-materialize-string))
        (calls 0))
    (cl-letf (((symbol-function 'tp-surface-materialize-string)
               (lambda (producer)
                 (cl-incf calls)
                 (funcall original producer))))
      (should (stringp
               (ebox-render
                (ebox-create :content "Materialized" :width '(100))))))
    (should (= calls 1))))

(ert-deftest ebox-render-is-repeatable-without-consuming-runtime-identities ()
  "Ephemeral rendering should be exact and leave live identity counters alone."
  (ebox-surface-test--reset-render-state)
  (let* ((source (ebox-create :content "Repeatable" :width '(100)))
         (first (ebox-render source))
         (second (ebox-render source)))
    (should (equal-including-properties first second))
    (should (= ebox--region-id-counter 0))
    (should (= ebox--runtime-node-id-counter 0))
    (should-not (plist-member source :region-id))
    (should-not (plist-member source :node-id))))

(ert-deftest ebox-render-to-buffer-mounts-one-tp-surface ()
  "The public buffer renderer should expose TP's committed client state."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-public-surface*"))
        surface)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-create :content "Mounted" :width '(100)))
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
            (ebox-create :content "Viewport" :width '(viewport)))
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
            (ebox-create :content "zero\none\ntwo\nthree"
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
            (ebox-create :content "Static" :width '(100)))
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
            (ebox-create :content "Static" :width '(100)))
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
            (ebox-create :content "Theme" :width '(100)))
          (let* ((surface
                  (with-current-buffer buffer ebox-surface--buffer-surface))
                 (signals
                  (with-current-buffer buffer
                    ebox-surface--context-signals))
                 (revision (tp-surface-revision surface))
                 (next-signature '(ebox-test-theme dark)))
            (cl-letf (((symbol-function 'ebox--display-signature)
                       (lambda () next-signature)))
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

(ert-deftest ebox-render-to-buffer-reuses-one-source-across-buffers ()
  "The public mount path should never transfer ownership of its source tree."
  (ebox-surface-test--reset-render-state)
  (let* ((source
          (ebox-create :key 'shared :content "Shared" :width '(100)))
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
          (should-not (plist-member source :node-id))
          (should-not (plist-member source :region-id))
          (should-not (plist-member source :surface-object)))
      (dolist (buffer (list first second))
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
            (ebox-create :key 'root :content "Before" :width '(100)))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (revision (tp-surface-revision surface))
                 report)
            (setq report
                  (ebox-commit
                   buffer
                   (ebox-create :key 'root :content "After"
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
            (ebox-create :key 'root :content "Stable" :width '(100)))
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
              (ebox-create :key 'root :content "Rejected" :width '(100))
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
            (ebox-create :key 'root :content "Stable"
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
              (ebox-create :key 'root :content "Rejected"
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
            (ebox-create :key 'root :content "Stable" :width '(100)))
          (should (gethash buffer ebox--buffer-render-state-table))
          (should-error
           (ebox-commit
            buffer
            (ebox-create :key 'root :content "Rejected" :width '(100))
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
            (ebox-create :key 'root :host-ref 'root
                         :content "Before" :width '(100)))
          (let ((candidate (ebox-candidate-begin buffer)))
            (ebox-candidate-replace-host-ref
             candidate 'root
             (ebox-create :key 'root :host-ref 'root
                          :content "After" :width '(100)))
            (let ((report (ebox-commit buffer candidate)))
              (should (equal report (ebox-buffer-update-report buffer)))
              (should (eq (plist-get report :constraint-source)
                          'declarative))
              (should (string-match-p "After" (with-current-buffer
                                                  buffer (buffer-string)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-region-handles-are-surface-scoped ()
  "One logical id should resolve to distinct handles on independent surfaces."
  (ebox-surface-test--reset-render-state)
  (let* ((source
          (ebox-create :id "status" :content "Ready" :width '(100)))
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

(ert-deftest ebox-region-handle-update-uses-scoped-tp-publication ()
  "A handle update should publish a scoped TP plan."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-scoped-handle*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
              buffer
            (ebox-column
             (ebox-create :id "left" :content "Left" :width '(100))
             (ebox-create :id "right" :content "Right" :width '(100))))
          (let* ((surface (with-current-buffer
                            buffer ebox-surface--buffer-surface))
                 (revision (tp-surface-revision surface))
                 (handle (ebox-region-resolve buffer "left"))
                 report)
            (setq report
                  (ebox-region-update handle :content "Changed"))
            (should (= (tp-surface-revision surface) (1+ revision)))
            (should-not (plist-get (tp-surface-report surface) :full-root))
            (should (> (plist-get (tp-surface-report surface) :scope-count) 0))
            (should (eq (plist-get report :tp-render-scope) 'objects))
            (should (string-match-p
                     "Changed"
                     (with-current-buffer buffer (buffer-string))))))
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
            (ebox-create :id "target" :content "Before" :width '(100)))
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
            (ebox-create :id "action" :content "Closed" :width '(100)))
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
            (ebox-create :key 'old :id "old"
                         :content "Old" :width '(100)))
          (let ((handle (ebox-region-resolve buffer "old")))
            (ebox-commit
             buffer
             (ebox-create :key 'new :id "new"
                          :content "New" :width '(100)))
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
            (ebox-create :id "scroll" :content "zero\none\ntwo\nthree"
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

(ert-deftest ebox-scroll-update-rejects-a-runtime-replaced-by-its-hook ()
  "A stale scroll candidate must not overwrite a hook publication."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-scroll-hook-race*")))
    (unwind-protect
        (let ((ebox-viewport-width 240)
              (ebox-viewport-height 2))
          (ebox-render-to-buffer
              buffer
            (ebox-create :id "scroll" :content "zero\none\ntwo\nthree"
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

(provide 'ebox-surface-tests)

;;; ebox-surface-tests.el ends here
