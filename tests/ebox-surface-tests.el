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
                       ebox--scroll-global-state
                       ebox--rendered-root-metadata-table))
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
         (ebox-surface--producer node))
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
  (let ((original (symbol-function 'ebox-render))
        checked captured)
    (cl-letf (((symbol-function 'ebox-render)
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
                 (ebox-surface--producer
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
                 first-buffer (ebox-surface--producer source)
                 '(:capability content)))
          (setq second
                (tp-surface-mount
                 second-buffer (ebox-surface--producer source)
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
                       buffer (ebox-surface--producer first-source)
                       '(:capability content))))
               (first-state (tp-surface-client-state surface))
               (left (ebox-surface-test--object-by-key first-state 'left))
               (right (ebox-surface-test--object-by-key first-state 'right))
               (next-source
                (ebox-row
                 (ebox-create :key 'right :content "Right!" :width '(60))
                 (ebox-create :key 'left :content "Left!" :width '(60)))))
          (tp-surface-update
           surface (ebox-surface--producer next-source first-state))
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

(provide 'ebox-surface-tests)

;;; ebox-surface-tests.el ends here
