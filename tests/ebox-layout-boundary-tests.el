;;; ebox-layout-boundary-tests.el --- M2a layout dependency gates -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ebox)
(require 'ebox-fixtures)

(defconst ebox-layout-boundary-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by layout boundary tests.")

(defun ebox-layout-boundary-test--source (file)
  "Return repository FILE as text."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name file ebox-layout-boundary-test--root))
    (buffer-string)))

(defun ebox-layout-boundary-test--legacy-static-render (node)
  "Render NODE through the pre-E2 static materialization edge."
  (let ((candidate (ebox-surface--candidate-root node t)))
    (let ((ebox--surface-materialization-active t)
          (ebox--region-box-table (make-hash-table :test #'equal))
          (ebox--scroll-global-state (make-hash-table :test #'equal))
          (ebox--scroll-idle-prefetch-timers (make-hash-table :test #'equal))
          (ebox--smooth-scroll-state-table (make-hash-table :test #'equal))
          (ebox--render-cache-table (make-hash-table :test #'equal))
          (ebox--render-cache-signature-cache (make-hash-table :test #'eq))
          (ebox--box-content-render-cache (make-hash-table :test #'eq))
          (ebox--viewport-dependent-node-ids-cache (make-hash-table :test #'eq))
          (ebox--viewport-dependent-subtree-cache (make-hash-table :test #'eq))
          (ebox--viewport-height-dependent-subtree-cache
           (make-hash-table :test #'eq))
          (ebox--flex-content-min-width-table (make-hash-table :test #'eq))
          (ebox--render-runtime-revision nil)
          (ebox--render-cache-allow-viewport-dependent nil)
          (ebox--render-cache-scroll-state-region-ids nil)
          (ebox--render-cache-scroll-state-restorable-p nil)
          (ebox--render-cache-scroll-state-retained-cost-cache nil))
      (ebox--render-layout candidate))))

(defun ebox-layout-boundary-test--legacy-render (input)
  "Render canonical INPUT through the exact pre-E2 direct call edge."
  (let* ((node
          (ebox-canonical-input--single-root input "legacy E2 artifact"))
         (base-source-index (ebox-canonical-input--source-index input))
         (ebox--render-source-index base-source-index)
         (source-index
          (ebox-tree-source-index
           node t ebox--render-root-parent-kind base-source-index nil))
         (rendered
          (if (and (not (ebox-style-cascade-active-p))
                   (zerop (ebox-tree-author-style-count node))
                   (not (ebox-surface--inline-inheritance-required-p
                         node source-index)))
              (let ((ebox--region-id-counter ebox--region-id-counter)
                    (ebox--runtime-node-id-counter
                     ebox--runtime-node-id-counter))
                (ebox-layout-boundary-test--legacy-static-render node))
            (let ((ebox--surface-materialization-active t)
                  (ebox--region-id-counter ebox--region-id-counter)
                  (ebox--runtime-node-id-counter ebox--runtime-node-id-counter))
              (tp-surface-materialize-string
               (ebox-surface-producer
                node nil t (list :source-base-index base-source-index)))))))
    (ebox--strip-paint-origins! rendered)))

(defun ebox-layout-boundary-test--fixtures ()
  "Return representative static and materialized layout inputs."
  (list
   (ebox-test-column
    (ebox-test-row
     (ebox-test-box (ebox-test-text "A") :width '(48))
     (ebox-test-box (ebox-test-text "B") :width '(48)))
    (ebox-test-box (ebox-test-text "Tail") :width '(96)))
   (ebox-test-flex
    :flex-flow '(row wrap) :column-gap '(2)
    (ebox-test-box (ebox-test-text "One") :width '(52))
    (ebox-test-box (ebox-test-text "Two") :width '(52)))
   (ebox-test-grid
    :grid-template-columns '((54) (fr 1))
    (ebox-test-box (ebox-test-text "Left"))
    (ebox-test-box (ebox-test-text "Right")))
   (ebox-test-box
    :font-size 16
    (ebox-test-box (ebox-test-text "Inherited")))))

(ert-deftest ebox-layout-boundary-has-no-surface-or-publication-edge ()
  "The layout module depends only on its injected render context."
  (let ((source (ebox-layout-boundary-test--source "ebox-layout.el")))
    (should-not (string-match-p "(require[[:space:]]+'ebox-surface)" source))
    (should-not (string-match-p "\\_<ebox-surface-" source))
    (should-not (string-match-p "\\_<tp-surface-" source))
    (should (string-match-p "ebox-render-context-candidate-root" source))
    (should (string-match-p
             "ebox-render-context-materialize-string" source))))

(ert-deftest ebox-layout-boundary-preserves-pre-e2-layout-artifacts ()
  "The injected route preserves every old character and property interval."
  (dolist (input (ebox-layout-boundary-test--fixtures))
    (let ((legacy (ebox-layout-boundary-test--legacy-render input))
          (current (ebox-render input)))
      (should (equal-including-properties current legacy))
      (should
       (equal (mapcar #'ebox--string-pixel-width (ebox-string-lines current))
              (mapcar #'ebox--string-pixel-width
                      (ebox-string-lines legacy)))))))

(ert-deftest ebox-layout-boundary-static-route-is-a-strict-subset ()
  "Static layout uses candidate and inheritance inputs without TP materialize."
  (let ((candidate-calls 0)
        (inheritance-calls 0)
        (materialize-calls 0)
        (default ebox--default-layout-context-port))
    (let ((ebox--layout-context-port
           (ebox-render-context-create-layout-port
            :candidate-root
            (lambda (&rest arguments)
              (cl-incf candidate-calls)
              (apply (ebox-layout-context-port-candidate-root default)
                     arguments))
            :inline-inheritance-required-p
            (lambda (&rest arguments)
              (cl-incf inheritance-calls)
              (apply
               (ebox-layout-context-port-inline-inheritance-required-p default)
               arguments))
            :materialize-string
            (lambda (&rest arguments)
              (cl-incf materialize-calls)
              (apply (ebox-layout-context-port-materialize-string default)
                     arguments)))))
      (ebox-render
       (ebox-test-box (ebox-test-text "Static") :width '(96))))
    (should (= candidate-calls 1))
    (should (= inheritance-calls 1))
    (should (= materialize-calls 0))))

(ert-deftest ebox-layout-boundary-materialized-route-is-exactly-once ()
  "Inherited layout invokes its context materializer exactly once."
  (let ((candidate-calls 0)
        (inheritance-calls 0)
        (materialize-calls 0)
        (default ebox--default-layout-context-port))
    (let ((ebox--layout-context-port
           (ebox-render-context-create-layout-port
            :candidate-root
            (lambda (&rest arguments)
              (cl-incf candidate-calls)
              (apply (ebox-layout-context-port-candidate-root default)
                     arguments))
            :inline-inheritance-required-p
            (lambda (&rest arguments)
              (cl-incf inheritance-calls)
              (apply
               (ebox-layout-context-port-inline-inheritance-required-p default)
               arguments))
            :materialize-string
            (lambda (&rest arguments)
              (cl-incf materialize-calls)
              (apply (ebox-layout-context-port-materialize-string default)
                     arguments)))))
      (ebox-render
       (ebox-test-box
        :font-size 16
        (ebox-test-box (ebox-test-text "Inherited")))))
    (should (= candidate-calls 0))
    ;; Author-style pending is sufficient to choose the materialized route,
    ;; so the inherited-cascade predicate is correctly short-circuited here.
    (should (= inheritance-calls 0))
    (should (= materialize-calls 1))))

(ert-deftest ebox-layout-boundary-port-fault-leaves-source-unmodified ()
  "A materialization-port fault cannot publish or consume source identity."
  (let* ((input
          (ebox-test-box
           :font-size 16
           (ebox-test-box (ebox-test-text "Fault"))))
         (root (ebox-test-root input))
         (source-index (ebox-test-source-index input))
         (region-counter ebox--region-id-counter)
         (node-counter ebox--runtime-node-id-counter)
         (default ebox--default-layout-context-port)
         (ebox--layout-context-port
          (ebox-render-context-create-layout-port
           :candidate-root
           (ebox-layout-context-port-candidate-root default)
           :inline-inheritance-required-p (lambda (&rest _arguments) t)
           :materialize-string
           (lambda (&rest _arguments)
             (error "Injected E2 materialization fault")))))
    (should-error (ebox-render input) :type 'error)
    (should (eq (ebox-test-root input) root))
    (should (eq (ebox-test-source-index input) source-index))
    (should (= ebox--region-id-counter region-counter))
    (should (= ebox--runtime-node-id-counter node-counter))
    (should-not (plist-member root :node-id))
    (should-not (plist-member root :region-id))
    (should-not (plist-member root :surface-object))))

(provide 'ebox-layout-boundary-tests)

;;; ebox-layout-boundary-tests.el ends here
