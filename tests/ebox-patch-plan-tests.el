;;; ebox-patch-plan-tests.el --- M2a pure patch planner gates -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'benchmark)
(require 'ebox)
(require 'ebox-patch-plan)
(require 'ebox-fixtures)

(defconst ebox-patch-plan-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by patch planner tests.")

(defun ebox-patch-plan-test--read-forms (file)
  "Read and return every top-level form in repository FILE."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file ebox-patch-plan-test--root))
    (let (forms form)
      (condition-case nil
          (while t
            (setq form (read (current-buffer)))
            (push form forms))
        (end-of-file nil))
      (nreverse forms))))

(defun ebox-patch-plan-test--walk-symbols (form function)
  "Call FUNCTION for every symbol contained by FORM."
  (cond
   ((symbolp form) (funcall function form))
   ((consp form)
    (ebox-patch-plan-test--walk-symbols (car form) function)
    (ebox-patch-plan-test--walk-symbols (cdr form) function))
   ((vectorp form)
    (mapc (lambda (item)
            (ebox-patch-plan-test--walk-symbols item function))
          form))))

(defun ebox-patch-plan-test--dirty (node-id kind keys)
  "Return one planner fixture for NODE-ID, KIND, and changed KEYS."
  (list :node-id node-id :dirty-kind kind :changed-keys keys))

(defun ebox-patch-plan-test--reset-runtime-state ()
  "Reset planner-visible global identities and compatibility projections."
  (setq ebox--region-id-counter 0
        ebox--runtime-node-id-counter 0)
  (dolist (table (list ebox--region-box-table ebox--scroll-global-state))
    (when (hash-table-p table) (clrhash table))))

(defun ebox-patch-plan-test--op (operation owner-id dirty)
  "Return one tentative OPERATION for OWNER-ID and DIRTY."
  (list :op operation :owner-id owner-id :dirty dirty))

(ert-deftest ebox-patch-plan-module-has-no-surface-or-publication-capability ()
  "The pure planner cannot inspect buffers or call publication APIs."
  (let (forbidden)
    (dolist (form (ebox-patch-plan-test--read-forms "ebox-patch-plan.el"))
      (ebox-patch-plan-test--walk-symbols
       form
       (lambda (symbol)
         (let ((name (symbol-name symbol)))
           (when (or (string-prefix-p "ebox-surface-" name)
                     (string-prefix-p "tp-surface-" name)
                     (string-prefix-p "tp-object-" name)
                     (memq symbol '(with-current-buffer set-buffer
                                    insert delete-region
                                    put-text-property
                                    ebox--buffer-render-state)))
             (push symbol forbidden))))))
    (should-not (delete-dups forbidden))))

(ert-deftest ebox-patch-plan-merges-one-deterministic-antichain ()
  "A stronger ancestor absorbs descendant dirt without input mutation."
  (let ((parents (make-hash-table :test #'equal))
        operations)
    (puthash 'branch 'root parents)
    (puthash 'leaf 'branch parents)
    (setq operations
          (list
           (ebox-patch-plan-test--op
            'paint-patch 'leaf
            (ebox-patch-plan-test--dirty 'leaf 'paint '(:color)))
           (ebox-patch-plan-test--op
            'span-patch 'branch
            (ebox-patch-plan-test--dirty 'branch 'geometry '(:content)))))
    (let ((before (copy-tree operations))
          (result (ebox-patch-plan-merge-ops parents operations)))
      (should (equal operations before))
      (should (= (length result) 1))
      (should (eq (plist-get (car result) :op) 'span-patch))
      (should (eq (plist-get (car result) :owner-id) 'branch))
      (should
       (equal (sort (copy-sequence
                     (plist-get (plist-get (car result) :dirty) :node-ids))
                    (lambda (left right)
                      (string< (symbol-name left) (symbol-name right))))
              '(branch leaf)))
      (should
       (equal (sort (copy-sequence
                     (plist-get (plist-get (car result) :dirty)
                                :changed-keys))
                    (lambda (left right)
                      (string< (symbol-name left) (symbol-name right))))
              '(:color :content))))))

(ert-deftest ebox-patch-plan-rejects-malformed-and-cyclic-input ()
  "Invalid artifacts fail before any downstream publication can exist."
  (should-error (ebox-patch-plan-merge-ops nil nil)
                :type 'ebox-patch-plan-error)
  (let ((parents (make-hash-table :test #'equal)))
    (should-error (ebox-patch-plan-merge-ops parents '((:op paint-patch)))
                  :type 'ebox-patch-plan-error)
    (puthash 'first 'second parents)
    (puthash 'second 'first parents)
    (should-error
     (ebox-patch-plan-merge-ops
      parents
      (list
       (ebox-patch-plan-test--op
        'paint-patch 'first
        (ebox-patch-plan-test--dirty 'first 'paint '(:color)))))
     :type 'ebox-patch-plan-error)))

(defun ebox-patch-plan-test--integration-fixture ()
  "Return a retained layout covering paint, geometry, and broad planning."
  (apply
   #'ebox-test-column
   :width '(360)
   (cl-loop for index below 12
            collect
            (ebox-test-box
             :key (intern (format "patch-plan-%d" index))
             (ebox-test-text (format "Item %02d" index))
             :width '(160) :height 1))))

(defun ebox-patch-plan-test--route-artifact (buffer dirty route)
  "Return BUFFER's planner artifact for DIRTY through ROUTE."
  (let ((ebox-incremental--patch-planner-route route))
    (ebox-incremental--declarative-tentative-patch-set
     buffer (copy-tree dirty))))

(ert-deftest ebox-patch-plan-pure-route-matches-legacy-artifacts ()
  "Paint, geometry, and broad viewport inputs match the old planner exactly."
  (ebox-patch-plan-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-m2a-e3-artifacts*")))
    (unwind-protect
        (progn
          (let ((ebox-viewport-width 360))
            (ebox-render-to-buffer
             buffer (ebox-patch-plan-test--integration-fixture)))
          (let* ((root (ebox--buffer-root-node buffer))
                 (children (ebox-tree-node-children root))
                 (first-id (plist-get (nth 0 children) :node-id))
                 (second-id (plist-get (nth 1 children) :node-id))
                 (paint
                  (list
                   (ebox-patch-plan-test--dirty
                    first-id 'paint '(:color))))
                 (geometry
                  (list
                   (append
                    (ebox-patch-plan-test--dirty
                     second-id 'geometry '(:content))
                    '(:old-signature (:content "Item 01" :width 160)
                      :new-signature (:content "Item 01 changed" :width 160)))))
                 (broad (ebox--viewport-dirty-set root)))
            (dolist (dirty (list paint geometry broad))
              (let ((legacy
                     (ebox-patch-plan-test--route-artifact
                      buffer dirty 'legacy))
                    (pure
                     (ebox-patch-plan-test--route-artifact
                      buffer dirty 'pure)))
                (should (equal pure legacy))
                (should
                 (equal
                  (ebox-patch-plan-test--route-artifact buffer dirty 'shadow)
                  legacy))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-patch-plan-fault-cannot-publish-live-state ()
  "A pure planner fault leaves buffer text, revision, and client state intact."
  (ebox-patch-plan-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-m2a-e3-fault*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-patch-plan-test--integration-fixture))
          (let* ((surface (ebox-surface--live-buffer-surface buffer))
                 (state (tp-surface-client-state surface))
                 (revision (tp-surface-revision surface))
                 (contents
                  (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max))))
                 (root (plist-get state :root-node))
                 (dirty (ebox--viewport-dirty-set root))
                 (ebox-incremental--patch-planner-route 'pure))
            (cl-letf (((symbol-function 'ebox-patch-plan-merge-ops)
                       (lambda (&rest _arguments)
                         (error "Injected E3 planner fault"))))
              (should-error
               (ebox-incremental--declarative-tentative-patch-set
                buffer dirty)))
            (should (eq (tp-surface-client-state surface) state))
            (should (= (tp-surface-revision surface) revision))
            (should
             (equal-including-properties
              (with-current-buffer buffer
                (buffer-substring (point-min) (point-max)))
              contents))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-patch-plan-feature-route-defaults-pure-and-keeps-legacy ()
  "E3 enables the pure route while retaining explicit rollback selection."
  (should (eq (default-value 'ebox-incremental--patch-planner-route) 'pure))
  (dolist (route '(legacy pure shadow))
    (should (memq route '(legacy pure shadow))))
  (let ((ebox-incremental--patch-planner-route 'unknown)
        (buffer (generate-new-buffer " *ebox-m2a-e3-route*")))
    (unwind-protect
        (should-error
         (ebox-incremental--declarative-tentative-patch-set
          buffer '((:node-id node :dirty-kind paint
                     :changed-keys (:color))))
         :type 'ebox-patch-plan-error)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-patch-plan-performance-bounds-parent-walks ()
  "A wide plan performs one bounded parent walk per tentative artifact."
  (let ((parents (make-hash-table :test #'equal))
        operations)
    (dotimes (index 512)
      (let ((node-id (intern (format "ebox-patch-perf-%d" index))))
        (puthash node-id 'root parents)
        (push
         (ebox-patch-plan-test--op
          'paint-patch node-id
          (ebox-patch-plan-test--dirty node-id 'paint '(:color)))
         operations)))
    (setq operations (nreverse operations))
    (let ((walks 0)
          (original (symbol-function 'ebox-patch-plan--ancestor-set))
          plan benchmark)
      (cl-letf (((symbol-function 'ebox-patch-plan--ancestor-set)
                 (lambda (&rest arguments)
                   (cl-incf walks)
                   (apply original arguments))))
        (setq benchmark
              (benchmark-run
                1
                (setq plan
                      (ebox-patch-plan-merge-ops parents operations)))))
      (should (= (length plan) 512))
      (should (= walks 512))
      (should (< (car benchmark) 2.0)))))

(provide 'ebox-patch-plan-tests)

;;; ebox-patch-plan-tests.el ends here
