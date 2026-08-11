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

(defun ebox-surface-test--hash-fingerprint (table)
  "Return a stable content fingerprint for hash TABLE.
The fingerprint checks entries rather than only table identity, so a failed
candidate cannot hide mutations by restoring the old hash-table pointer."
  (let (entries)
    (when (hash-table-p table)
      (maphash
       (lambda (key value)
         (push (list (prin1-to-string key)
                     (sxhash-equal value))
               entries))
       table))
    (list (length entries)
          (sort entries (lambda (left right)
                          (string< (car left) (car right)))))))

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

(ert-deftest ebox-surface-static-projection-skips-empty-cascade ()
  "Inline-only static projection should not compute per-node ECSS styles."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create))
        (calls 0)
        (original (symbol-function 'ebox-style-compute-subject)))
    (cl-letf (((symbol-function 'ebox-style-compute-subject)
               (lambda (&rest args)
                 (cl-incf calls)
                 (apply original args))))
      (let ((rendered
             (ebox-surface-test--render-fresh
              (cdr (assq 'box (ebox-surface-test--fixtures))) t)))
        (should (= calls 0))
        (should (string-match-p "Open" (substring-no-properties rendered)))))))

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
         (ebox-create
          :font-height 1.25
          :ebox-content-node
          (ebox-create :content "Inherited")))
       t))
    (should (> calls 0))))

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
         (child
          (ebox-column
           (ebox-create :key 'responsive-child
                        :content "fixed local viewport"
                        :width '(viewport)
                        :height 1)))
         (wrapper (ebox-create :width '(160)))
         (renders 0)
         (original (symbol-function
                    'ebox--render-cache-render-with-scroll-actions)))
    (cl-letf (((symbol-function 'ebox--render-cache-render-with-scroll-actions)
               (lambda (node)
                 (cl-incf renders)
                 (funcall original node))))
      (let ((first (ebox--render-node-as-box-content child wrapper))
            (second (ebox--render-node-as-box-content child wrapper)))
        (should (= renders 1))
        (should (equal-including-properties first second))))))

(ert-deftest ebox-surface-plan-stays-free-of-runtime-state ()
  "The surface plan should not contain markers or runtime handles."
  (let ((original (symbol-function 'tp-surface-result-create))
        (original-owned (symbol-function 'tp-surface-result-create-owned))
        captured client-state)
    (cl-letf (((symbol-function 'tp-surface-result-create)
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
           (state-fragments (plist-get client-state :surface-fragments))
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

(ert-deftest ebox-surface-scoped-update-reuses-copy-on-write-candidate ()
  "A fixed-footprint region update should hand a path candidate to the surface."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-isolated-candidate*"))
        (copy-count 0)
        (validation-count 0)
        (reconcile-count 0)
        (runtime-index-count 0)
        (original-copy (symbol-function 'ebox-tree-copy-node-structure))
        (original-validate (symbol-function 'ebox-tree-validate-declarative-root))
        (original-reconcile (symbol-function 'ebox-tree-reconcile-runtime))
        (original-runtime-index (symbol-function 'ebox--runtime-index)))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-column
            (ebox-create :key 'target :id 'target :content "Before"
                         :width '(100))
            (ebox-create :key 'sibling :content "Sibling" :width '(100))))
          (let ((handle (ebox-region-resolve buffer "target")))
            (cl-letf (((symbol-function 'ebox-tree-copy-node-structure)
                       (lambda (&rest args)
                         (cl-incf copy-count)
                         (apply original-copy args)))
                      ((symbol-function 'ebox-tree-validate-declarative-root)
                       (lambda (&rest args)
                         (cl-incf validation-count)
                         (apply original-validate args)))
                      ((symbol-function 'ebox-tree-reconcile-runtime)
                      (lambda (&rest args)
                         (cl-incf reconcile-count)
                         (apply original-reconcile args)))
                      ((symbol-function 'ebox--runtime-index)
                       (lambda (&rest args)
                         (cl-incf runtime-index-count)
                         (apply original-runtime-index args))))
              (ebox-region-update handle :content "After")))
        (should (= copy-count 0))
        (should (= validation-count 0))
        (should (= reconcile-count 0))
        (should (= runtime-index-count 0)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-surface-span-update-renders-only-the-owner ()
  "A fixed-footprint span update should render its owner, not the root tree."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-local-span*"))
        (rendered-node-ids nil)
        (ensured-node-count 0))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-column
            (ebox-create :key 'target :id 'target :content "Before"
                         :width '(100))
            (ebox-create :key 'sibling :content "Sibling" :width '(100))))
          (let* ((state (ebox--buffer-render-state buffer))
                 (target
                  (cl-loop for node being the hash-values
                           of (plist-get state :node-table)
                           when (equal (plist-get node :key) 'target)
                           return node))
                 (target-id (plist-get target :node-id))
                 (handle (ebox-region-resolve buffer "target"))
                 (original-render (symbol-function 'ebox--render-layout))
                 (original-ensure (symbol-function
                                   'ebox-surface--ensure-node-tree)))
            (cl-letf (((symbol-function 'ebox--render-layout)
                       (lambda (node)
                         (push (plist-get node :node-id) rendered-node-ids)
                         (funcall original-render node)))
                      ((symbol-function 'ebox-surface--ensure-node-tree)
                       (lambda (&rest args)
                         (cl-incf ensured-node-count)
                         (apply original-ensure args))))
              (ebox-region-update handle :content "After"))
            (should (equal (nreverse rendered-node-ids) (list target-id)))
            (should (= ensured-node-count 0))
            (let ((expected (ebox-render (ebox--buffer-root-node buffer))))
              (should
               (equal-including-properties
                expected
                (with-current-buffer buffer (buffer-string)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-surface-partial-row-span-update-renders-only-the-owner ()
  "A partial row owner should patch disjoint slots without full projection."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-surface-partial-row*"))
        (rendered-node-ids nil)
        (ensured-node-count 0))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer
           (ebox-row
            (ebox-create :key 'left :content "Left\ndetail" :width '(52))
            (ebox-create :key 'target :id 'target
                         :content "Before\ndetail" :width '(52))
            (ebox-create :key 'right :content "Right\ndetail" :width '(52))))
          (let* ((state (ebox--buffer-render-state buffer))
                 (target
                  (cl-loop for node being the hash-values
                           of (plist-get state :node-table)
                           when (equal (plist-get node :key) 'target)
                           return node))
                 (target-id (plist-get target :node-id))
                 (snapshot
                  (ebox--ensure-layout-snapshot-details buffer target-id))
                 (spans (plist-get snapshot :buffer-spans))
                 (handle (ebox-region-resolve buffer "target"))
                 (original-render (symbol-function 'ebox--render-layout))
                 (original-ensure
                  (symbol-function 'ebox-surface--ensure-node-tree)))
            (with-current-buffer buffer
              (should (ebox-buffer--partial-line-slots-p spans))
              (should-not (ebox--spans-contiguous-lines-p spans)))
            (cl-letf (((symbol-function 'ebox--render-layout)
                       (lambda (node)
                         (push (plist-get node :node-id) rendered-node-ids)
                         (funcall original-render node)))
                      ((symbol-function 'ebox-surface--ensure-node-tree)
                       (lambda (&rest args)
                         (cl-incf ensured-node-count)
                         (apply original-ensure args))))
              (ebox-region-update handle :content "UPDATED\ndetail"))
            (should (equal (nreverse rendered-node-ids) (list target-id)))
            (should (= ensured-node-count 0))
            (should (eq (plist-get (ebox-buffer-update-report buffer)
                                   :strategy)
                        'span-patch))
            (let* ((surface (with-current-buffer
                                buffer ebox-surface--buffer-surface))
                   (report (tp-surface-report surface))
                   (object-count
                    (plist-get (tp-surface-inspect surface) :object-count)))
              (should (< (plist-get report :reconciled-objects)
                         object-count)))
            (let ((expected (ebox-render (ebox--buffer-root-node buffer))))
              (should
               (equal-including-properties
                expected
                (with-current-buffer buffer (buffer-string)))))))
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
           (ebox-column
            (ebox-create :key 'target :id 'target :content "Before"
                         :width '(100))
            (ebox-create :key 'sibling :content "Sibling" :width '(100))))
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
            (should (equal (ebox-get
                            (ebox--root-region-box
                             (plist-get state :root-node)
                             region-id)
                            :content)
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
                (ebox-create :content "Materialized" :width '(100))))))
    (should (= calls 0))))

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

(ert-deftest ebox-viewport-reflow-reuses-retained-node-subtree ()
  "A safe viewport reflow should reuse the retained TP node topology."
  (ebox-surface-test--reset-render-state)
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
            #'ebox-flex
            :key 'viewport-reflow-root
            :width '(viewport)
            :flex-wrap 'wrap
            :column-gap '(6)
            :row-gap 1
            (cl-loop for index below 12
                     collect
                     (ebox-flex-item
                      (ebox-create
                       :key (list 'viewport-reflow-item index)
                       :content (format "item-%02d" index)
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
                      (ebox-render (plist-get state :root-node))))
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
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-reflow-retains-final-sized-flex-child-fragments ()
  "Viewport reflow should reuse final-sized Flex child fragments exactly."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-flex-fragment-retention*"))
        (stable-renders 0)
        (growing-renders 0)
        stable-source growing-source)
    (unwind-protect
        (let ((ebox-viewport-width 300)
              (ebox-viewport-height 6)
              (ebox-runtime-idle-prewarm nil)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (setq stable-source
                (let ((node
                       (ebox-column
                       (ebox-create :key 'stable-leaf
                                     :content "zero\none\ntwo"
                                     :width '(100)
                                     :height 1
                                     :overflow 'hidden
                                     :surface-properties
                                     '(help-echo "stable")))))
                  (plist-put node :key 'stable-source)
                  node))
          (setq growing-source
                (let ((node
                       (ebox-column
                        (ebox-create :key 'growing-leaf
                                     :content "growing"
                                     :width '(viewport)
                                     :height 1
                                     :color "#0F172A"
                                     :bgcolor "#DBEAFE"))))
                  (plist-put node :key 'growing-source)
                  node))
          (let ((original-render (symbol-function 'ebox-render)))
            (cl-letf (((symbol-function 'ebox-render)
                       (lambda (node)
                         (cond
                          ((equal (plist-get node :key) 'stable-source)
                           (cl-incf stable-renders))
                          ((equal (plist-get node :key) 'growing-source)
                           (cl-incf growing-renders)))
                         (funcall original-render node))))
              (let* ((layout
                      (ebox-flex
                       :key 'fragment-root
                       :width '(viewport)
                       :height 2
                       :flex-wrap 'nowrap
                       (ebox-flex-item stable-source
                                       :flex-grow 0 :flex-basis '(120))
                       (ebox-flex-item growing-source
                                       :flex-grow 1 :flex-basis '(80))))
                     (items (plist-get layout :children)))
                (setq stable-source
                      (plist-get (car items) :node)
                      growing-source
                      (plist-get (cadr items) :node))
                (ebox-render-to-buffer buffer layout))
              (let* ((old-state (ebox--buffer-render-state buffer))
                     (old-root-object
                      (plist-get (plist-get old-state :root-node)
                                 :surface-object))
                     (old-stable-object
                      (ebox-surface-test--object-by-key old-state
                                                        'stable-source))
                     (initial-stable-renders stable-renders)
                     (initial-growing-renders growing-renders)
                     report state expected actual
                     candidate-stable-renders candidate-growing-renders)
                ;; Exercise the fragment boundary independently of the
                ;; broader render cache; the published fragment table remains
                ;; the only retained final-sized output for this reflow.
                (clrhash (plist-get old-state :render-cache))
                (setq ebox-fragment-flex-retention-hit-count 0
                      ebox-fragment-flex-retention-rerender-count 0)
                (setq report
                      (ebox-rerender-buffer-with-context buffer 360 6))
                (setq state (ebox--buffer-render-state buffer)
                      candidate-stable-renders stable-renders
                      candidate-growing-renders growing-renders
                      expected
                      (let ((ebox-viewport-width 360)
                            (ebox-viewport-height 6))
                        (ebox-render (plist-get state :root-node)))
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
                (should (= candidate-stable-renders initial-stable-renders))
                (should (> candidate-growing-renders initial-growing-renders))
                (should (> ebox-fragment-flex-retention-hit-count 0))
                (should (> ebox-fragment-flex-retention-rerender-count 0))
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (should (text-property-search-forward
                           'help-echo "stable" t)))))))
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
  (let ((ebox--layout-fragments-table (make-hash-table :test 'equal))
        (node (ebox-create :content "stable" :width '(80))))
    (cl-labels
        ((key-at (height dependency)
           (let ((ebox-viewport-height height))
             (ebox-fragment-flex-allocation-key
              node 'column 1 80 'stretch 80
              (list :viewport-height-dependent dependency)))))
      (should (equal (key-at nil nil) (key-at 36 nil)))
      (should-not (equal (key-at nil t) (key-at 36 t)))
      (should-not (equal (key-at nil :unknown) (key-at 36 :unknown))))))

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

(ert-deftest ebox-viewport-reflow-falls-back-for-active-stylesheet ()
  "A stylesheet-dependent viewport change must rebuild styled node objects."
  (ebox-surface-test--reset-render-state)
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
           (ebox-create :class 'viewport-cascade
                        :content "Cascade"
                        :width '(viewport)))
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
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-reflow-falls-back-for-inline-inheritance ()
  "An inherited inline value must keep the full styled projection path."
  (ebox-surface-test--reset-render-state)
  (let ((buffer (generate-new-buffer " *ebox-viewport-inheritance*"))
        (ensured-node-count 0)
        (original-ensure (symbol-function 'ebox-surface--ensure-node-tree)))
    (unwind-protect
        (let ((ebox-viewport-width 160)
              (ebox-viewport-height 6)
              (ebox-runtime-idle-reflow-cache-prewarm nil))
          (ebox-render-to-buffer
           buffer
           (ebox-create
            :font-height 1.25
            :width '(viewport)
            :ebox-content-node
            (ebox-create :content "Inherited")))
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
        (kill-buffer buffer)))))

(ert-deftest ebox-viewport-reflow-falls-back-for-scroll-and-visible-overflow ()
  "Scroll state and visible overflow must not enter retained reflow."
  (dolist (fixture
           (list
            (cons 'scroll
                  (lambda ()
                    (ebox-create :content "zero\none\ntwo"
                                 :width '(viewport)
                                 :height 2
                                 :overflow 'scroll)))
            (cons 'visible-overflow
                  (lambda ()
                    (ebox-create :content "one\ntwo"
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
          (kill-buffer buffer))))))

(ert-deftest ebox-viewport-reflow-supports-height-and-both-axis-resize ()
  "Retained viewport reflow should cover height-only and two-axis changes."
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
               (ebox-create :key name :content "One\nTwo"
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
            (kill-buffer buffer)))))))

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
           (ebox-create :key 'rollback
                        :content "zero\none\ntwo\nthree"
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

(ert-deftest ebox-mounted-render-uses-target-display-context ()
  "A mounted candidate must measure in its target buffer's display context."
  (ebox-surface-test--reset-render-state)
  (let* ((source (generate-new-buffer " *ebox-context-source*"))
         (target (generate-new-buffer " *ebox-context-target*"))
         (node (ebox-create :content "MMMM" :width '(100)))
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
