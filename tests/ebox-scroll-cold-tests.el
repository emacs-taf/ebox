;;; ebox-scroll-cold-tests.el --- Lazy scroll continuation boundaries -*- lexical-binding: t; -*-

;;; Commentary:
;; A real lazy-prefix miss must stage both continuation data and source-node
;; geometry before TP publishes text or client state.  Rejected candidates
;; leave every published scroll owner ready to retry the same miss.
;; A published cache hit must also keep later prefix and materializer work
;; attached to the current owner instead of reviving its retired predecessor.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defmacro ebox-scroll-cold-test--with-buffer (&rest body)
  "Run BODY in an isolated mounted Elisp surface with no idle prefix work."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
              (lambda () nil)))
     (let ((ebox-viewport-width 80) (ebox-viewport-height 8)
           (ebox-native-buffer-scroll nil)
           (ebox-runtime-idle-prewarm nil)
           (ebox-runtime-idle-reflow-cache-prewarm nil)
           (ebox-scroll-lazy-prefix-lookahead-lines 0)
           (ebox-scroll-lazy-idle-prefetch-lines 0)
           (ebox-scroll-lazy-idle-prefetch-delay 999)
           (ebox--scroll-window-initial-lookahead-lines-override 0))
       (with-temp-buffer
         (unwind-protect (progn ,@body)
           (when (ebox-surface-buffer-mounted-p (current-buffer))
             (ebox-unmount-buffer (current-buffer))))))))

(defun ebox-scroll-cold-test--input (boundary)
  "Build a lazy owner at root, nested, or enclosing-scroll BOUNDARY."
  (let ((target
         `(column :id "target" :width (px 80) :height (vh 25) :overflow scroll
                  ,@(cl-loop for index below 40
                             collect `(box :id ,(format "row-%d" index)
                                           :height (lh 1)
                                           :color "#204060"
                                           :help-echo ,(format "Action %d" index)
                                           :pointer hand
                                           :keymap (keymap (13 . ignore))
                                           ,(format "row %02d" index))))))
    (ebox-build
     (if (eq boundary 'root) target
       `(column :id "container" :width (px 80)
                ,@(when (eq boundary 'enclosing-scroll)
                    '(:height (vh 50) :overflow scroll))
                (box :id "head" "head")
                ,target
                (box :id "tail" :height (lh 8) "tail"))))))

(defun ebox-scroll-cold-test--assert-eq (label expected actual)
  "Require identity of EXPECTED and ACTUAL, reporting only bounded LABEL."
  (ert-info ((format "%s retains identity" label))
    (let ((unchanged (eq expected actual))) (should unchanged))))

(defun ebox-scroll-cold-test--assert-equal (label expected actual)
  "Compare EXPECTED and ACTUAL without printing runtime objects on failure."
  (ert-info (label)
    (let ((unchanged (equal expected actual))) (should unchanged))))

(defun ebox-scroll-cold-test--index-facts (state)
  "Copy STATE's bounded region-index values and cache validity flags."
  (cl-loop for key in '(:region-line-bounds-index :region-line-span-index
                        :rendered-region-line-span-index :content-region-id-set
                        :region-line-span-hints :region-line-span-index-deferred
                        :rendered-region-line-span-index-deferred
                        :content-lines-complete-p :lazy-scroll-prefix-dirty
                        :lazy-scroll-window-refresh-required :scroll-offset)
           for value = (plist-get state key)
           collect
           (cons key
                 (if (hash-table-p value)
                     (let (entries)
                       (maphash (lambda (region spans)
                                  (push (cons region (copy-tree spans)) entries))
                                value)
                       (sort entries
                             (lambda (left right)
                               (string< (prin1-to-string (car left))
                                        (prin1-to-string (car right))))))
                   (copy-tree value)))))

(defun ebox-scroll-cold-test--node-facts (node)
  "Copy NODE's source geometry and lazy-layout completion facts."
  (cl-loop for key in '(:width :height :min-width :max-width :min-height :max-height
                        :padding-left-pixel :padding-right-pixel
                        :padding-top-height :padding-bottom-height
                        :margin-left-pixel :margin-right-pixel
                        :margin-top-height :margin-bottom-height
                        :border-left-pixel :border-right-pixel
                        :scroll-offset :ebox-scroll-offset-controlled-p
                        :ebox-content-layout-complete-p :ebox-content-width-exact-p)
           collect (list key (and (plist-member node key) t)
                         (copy-tree (plist-get node key)))))

(defun ebox-scroll-cold-test--snapshot ()
  "Snapshot published identities plus bounded line, index, and node facts."
  (let* ((runtime (ebox--buffer-render-state (current-buffer)))
         (table (plist-get runtime :scroll-state-table))
         scrolls nodes)
    (maphash
     (lambda (region state)
       (push (list :region region :state state :box (plist-get state :box)
                   :producer (plist-get state :render-content-prefix)
                   :materializer (plist-get state :materialize-content-lines)
                   :content-head (plist-get state :content-lines)
                   :rendered-head (plist-get state :rendered-content-lines)
                   :content (mapcar #'tp-text-snapshot (plist-get state :content-lines))
                   :rendered (mapcar #'tp-text-snapshot (plist-get state :rendered-content-lines))
                   :index-facts (ebox-scroll-cold-test--index-facts state))
             scrolls))
     table)
    (ebox-runtime-index-map
     (lambda (node-id node)
       (push (list node-id node (ebox-scroll-cold-test--node-facts node)) nodes))
     (plist-get runtime :node-table))
    (list :runtime runtime :root (plist-get runtime :root-node)
          :source-index (plist-get runtime :source-index)
          :region-box-registry ebox--region-box-table
          :region-box-entries (copy-hash-table ebox--region-box-table)
          :scrolls scrolls :nodes nodes :text (tp-text-snapshot (buffer-string))
          :revision (ebox-surface-buffer-revision (current-buffer)))))

(defun ebox-scroll-cold-test--assert-lines (label expected actual)
  "Require unchanged cached line counts and full properties for LABEL."
  (ert-info ((format "%s line count" label))
    (should (= (length expected) (length actual))))
  (cl-loop for before in expected for after in actual for row from 0
           do (ert-info ((format "%s row %d properties" label row))
                (let ((unchanged (equal-including-properties before after)))
                  (should unchanged)))))

(defun ebox-scroll-cold-test--assert-snapshot (snapshot)
  "Verify SNAPSHOT's complete published boundary after a rejected scroll."
  (let ((runtime (ebox--buffer-render-state (current-buffer))))
    (ebox-scroll-cold-test--assert-eq "Runtime" (plist-get snapshot :runtime) runtime)
    (ebox-scroll-cold-test--assert-eq
     "Root" (plist-get snapshot :root) (plist-get runtime :root-node))
    (ebox-scroll-cold-test--assert-eq
     "Source index" (plist-get snapshot :source-index) (plist-get runtime :source-index))
    (ebox-scroll-cold-test--assert-eq
     "Global region registry" (plist-get snapshot :region-box-registry) ebox--region-box-table)
    (let ((entries (plist-get snapshot :region-box-entries)))
      (should (= (hash-table-count entries) (hash-table-count ebox--region-box-table)))
      (maphash (lambda (region box)
                 (ebox-scroll-cold-test--assert-eq
                  (format "Global region %s" region) box (gethash region ebox--region-box-table)))
               entries))
    (should (= (plist-get snapshot :revision)
               (ebox-surface-buffer-revision (current-buffer))))
    (let ((unchanged (equal-including-properties (plist-get snapshot :text) (buffer-string))))
      (should unchanged))
    (dolist (entry (plist-get snapshot :scrolls))
      (let* ((region (plist-get entry :region))
             (state (gethash region (plist-get runtime :scroll-state-table))))
        (ebox-scroll-cold-test--assert-eq "Scroll owner" (plist-get entry :state) state)
        (dolist (pair '((:box . :box) (:producer . :render-content-prefix)
                        (:materializer . :materialize-content-lines)
                        (:content-head . :content-lines) (:rendered-head . :rendered-content-lines)))
          (ebox-scroll-cold-test--assert-eq
           (format "Region %s %s" region (car pair))
           (plist-get entry (car pair)) (plist-get state (cdr pair))))
        (ebox-scroll-cold-test--assert-lines
         (format "Region %s content" region)
         (plist-get entry :content) (plist-get state :content-lines))
        (ebox-scroll-cold-test--assert-lines
         (format "Region %s rendered" region)
         (plist-get entry :rendered) (plist-get state :rendered-content-lines))
        (ebox-scroll-cold-test--assert-equal
         (format "Region %s indexes and offset" region)
         (plist-get entry :index-facts) (ebox-scroll-cold-test--index-facts state))))
    (dolist (entry (plist-get snapshot :nodes))
      (let ((node (ebox-runtime-index-get (car entry) (plist-get runtime :node-table))))
        (ebox-scroll-cold-test--assert-eq "Published source child" (cadr entry) node)
        (ebox-scroll-cold-test--assert-equal
         (format "Source node %s geometry and completion" (car entry))
         (nth 2 entry) (ebox-scroll-cold-test--node-facts node))))))

(defun ebox-scroll-cold-test--assert-fresh ()
  "Compare committed text and interactions with independent source rendering."
  (let* ((runtime (ebox--buffer-render-state (current-buffer)))
         (input (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input))
         (actual (buffer-string))
         (ebox-viewport-width (plist-get runtime :viewport-width))
         (ebox-viewport-height (plist-get runtime :viewport-height))
         (render (symbol-function 'ebox--render-layout))
         offsets first fresh)
    (maphash
     (lambda (_region state)
       (push (cons (ebox-tree-node-id (plist-get runtime :source-index) (plist-get state :box))
                   (plist-get state :scroll-offset)) offsets))
     (plist-get runtime :scroll-state-table))
    (cl-letf (((symbol-function 'ebox--render-layout)
               (lambda (root)
                 (unless first
                   (setq first t)
                   (cl-labels ((visit (node)
                                 (when-let* ((entry (assoc (ebox-tree-node-id ebox--render-source-index node)
                                                          offsets)))
                                   (ebox-put node :scroll-offset (cdr entry))
                                   (ebox-put node :ebox-scroll-offset-controlled-p t))
                                 (mapc #'visit (ebox-tree-node-children node))))
                     (visit root)))
                 (funcall render root))))
      (setq fresh (ebox-render input)))
    (should (equal (substring-no-properties actual) (substring-no-properties fresh)))
    (should (= (length actual) (length fresh)))
    (dotimes (position (length actual))
      (dolist (property '(face font-lock-face display help-echo keymap mouse-face pointer))
        (ebox-scroll-cold-test--assert-equal
         (format "Fresh property %S at %d" property position)
         (get-text-property position property actual)
         (get-text-property position property fresh))))))

(defun ebox-scroll-cold-test--rollback (boundary failure-step)
  "Reject a true lazy-prefix miss at BOUNDARY during FAILURE-STEP, then retry."
  (ebox-scroll-cold-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-scroll-cold-test--input boundary))
    (let* ((region (cdr (ebox-selector--region-target (ebox-region-resolve (current-buffer) "target"))))
           (state (ebox--scroll-get-state region))
           (count (length (plist-get state :content-lines)))
           (height (plist-get state :content-height))
           (delta (1+ (max 0 (- count height))))
           (snapshot (ebox-scroll-cold-test--snapshot))
           (ensure (symbol-function 'ebox--scroll-state-ensure-prefix-lines))
           prefix-extended rejected)
      (should (functionp (plist-get state :render-content-prefix)))
      (should-not (plist-get state :content-lines-complete-p))
      (should (= count 4))
      (should (= (length (plist-get state :rendered-content-lines)) count))
      (should (> (+ delta height) count))
      (cl-letf (((symbol-function 'ebox--scroll-state-ensure-prefix-lines)
                 (lambda (owner candidate required &rest options)
                   (let ((result (apply ensure owner candidate required options)))
                     (when (and (equal owner region)
                                (> (length (plist-get result :content-lines)) count))
                       (setq prefix-extended t))
                     result))))
        (let ((tp--surface-publication-step-function
               (lambda (step _surface)
                 (when (eq step failure-step)
                   (setq rejected t)
                   (error "Reject cold scroll publication")))))
          (should-error (ebox--surface-scroll-region-by (current-buffer) region delta 1))))
      (should rejected)
      (should prefix-extended)
      (ebox-scroll-cold-test--assert-snapshot snapshot)
      ;; The mounted state still has its original producer; retrying the same
      ;; miss must produce the requested rows instead of skipping leaked work.
      (should (= delta (ebox--surface-scroll-region-by (current-buffer) region delta 1)))
      (should (= delta (plist-get (ebox--scroll-get-state region) :scroll-offset)))
      (should (>= (length (plist-get (ebox--scroll-get-state region) :content-lines))
                  (+ delta height)))
      (ebox-scroll-cold-test--assert-fresh)
      (should (= (- delta) (ebox--surface-scroll-region-by (current-buffer) region (- delta) 1)))
      (ebox-scroll-cold-test--assert-fresh))))

(ert-deftest ebox-scroll-cold-root-text-rejection ()
  (ebox-scroll-cold-test--rollback 'root 'text))
(ert-deftest ebox-scroll-cold-root-client-state-rejection ()
  (ebox-scroll-cold-test--rollback 'root 'client-state))
(ert-deftest ebox-scroll-cold-nested-text-rejection ()
  (ebox-scroll-cold-test--rollback 'nested 'text))
(ert-deftest ebox-scroll-cold-nested-client-state-rejection ()
  (ebox-scroll-cold-test--rollback 'nested 'client-state))
(ert-deftest ebox-scroll-cold-enclosing-scroll-text-rejection ()
  (ebox-scroll-cold-test--rollback 'enclosing-scroll 'text))
(ert-deftest ebox-scroll-cold-enclosing-scroll-client-state-rejection ()
  (ebox-scroll-cold-test--rollback 'enclosing-scroll 'client-state))

(defun ebox-scroll-cold-test--continue-after-hit (caller)
  "Run CALLER after a cache hit and verify the continuation's published owner."
  (ebox-scroll-cold-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-scroll-cold-test--input 'root))
    (let* ((region (cdr (ebox-selector--region-target
                        (ebox-region-resolve (current-buffer) "target"))))
           (initial (ebox--scroll-get-state region))
           (count (length (plist-get initial :content-lines))))
      (should (= count 4))
      (should-not (plist-get initial :content-lines-complete-p))
      (should (ebox--surface-scroll-cached-intent-p initial 1))
      (should (= 1 (ebox--surface-scroll-region-by (current-buffer) region 1 1)))
      (let* ((runtime (ebox--buffer-render-state (current-buffer)))
             (owner-id (ebox--buffer-region-render-owner-node-id (current-buffer) region))
             (owner (ebox-runtime-index-get owner-id (plist-get runtime :node-table)))
             (state (ebox--scroll-get-state region)))
        (should (= count (length (plist-get state :content-lines))))
        (ebox-scroll-cold-test--assert-eq "Hit owner" owner (plist-get state :box))
        (should (functionp (plist-get state :render-content-prefix)))
        (should (functionp (plist-get state :materialize-content-lines)))
        (pcase caller
          ('prefix
           (setq state (ebox--scroll-state-ensure-prefix-lines region state (1+ count) t)))
          ('idle
           (let ((ebox-scroll-lazy-idle-prefetch-lines 2)
                 (ebox-scroll-lazy-idle-prefetch-slice-lines 2))
             ;; Invoke the actual idle callback once without scheduling another
             ;; turn; its own bounded-prefix logic remains exercised.
             (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                        (lambda (&rest _) nil)))
               (ebox--scroll-idle-prefetch region)))
           (setq state (ebox--scroll-get-state region)))
          ('materializer
           (setq state (ebox--scroll-state-materialize-lines region state))
           (should (plist-get state :content-lines-complete-p))))
        (should (> (length (plist-get state :content-lines)) count))
        (should (= 1 (plist-get state :scroll-offset)))
        (ebox-scroll-cold-test--assert-eq
         "Continued owner" owner (plist-get state :box))
        (ebox-scroll-cold-test--assert-eq
         "Current owner after continuation" owner
         (ebox-runtime-index-get owner-id
                                 (plist-get (ebox--buffer-render-state (current-buffer)) :node-table)))
        (ebox-scroll-cold-test--assert-fresh)
        (should (= -1 (ebox--surface-scroll-region-by (current-buffer) region -1 1)))
        (ebox-scroll-cold-test--assert-fresh)))))

(ert-deftest ebox-scroll-cold-root-hit-prefix-keeps-current-owner ()
  (ebox-scroll-cold-test--continue-after-hit 'prefix))
(ert-deftest ebox-scroll-cold-root-hit-idle-keeps-current-owner ()
  (ebox-scroll-cold-test--continue-after-hit 'idle))
(ert-deftest ebox-scroll-cold-root-hit-materializer-keeps-current-owner ()
  (ebox-scroll-cold-test--continue-after-hit 'materializer))

(provide 'ebox-scroll-cold-tests)
;;; ebox-scroll-cold-tests.el ends here
