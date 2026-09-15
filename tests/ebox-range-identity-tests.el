;;; ebox-range-identity-tests.el --- Retained Range identity -*- lexical-binding: t; -*-

;;; Commentary:
;; Reordered source identities keep focus and accept later nested updates.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-range-identity-test--input (order value part keyed)
  "Build ORDER with VALUE in row a; PART selects a forest or its nested value.
KEYED adds author keys; source identities remain stable in either case."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((text-node (id text)
           (ebox-text-create
            :value text
            :source-handle (ebox-source-builder-bind builder :identity id)
            :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (row-value (id)
           (text-node (list 'text id) (if (eq id 'a) value (symbol-name id))))
         (box-node (id children)
           (ebox-box-create
            :source-builder builder
            :source-handle (ebox-source-builder-bind builder :identity id :key (when keyed id))
            :layout (ebox-column-layout-create)
            :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
            :children children))
         (row (id)
           (box-node id (list (ebox-child-range (list 'value id) (row-value id))))))
      (let ((nodes (if (eq part 'value) (list (row-value 'a)) (mapcar #'row order))))
        (unless part
          (setq nodes (list (box-node 'root (list (apply #'ebox-child-range 'rows nodes))))))
        (ebox-canonical-input-create nodes (ebox-source-builder-finish builder))))))

(ert-deftest ebox-range-reorders-preserve-nested-updates-and-focus ()
  "Range and root publication agree on unkeyed source identity after moves."
  (dolist (keyed '(nil t))
    (dolist (root-update '(nil t))
      (dolist (focused '(nil t))
        (with-temp-buffer
          (let ((value "A"))
            (ebox-render-to-buffer (current-buffer)
                                   (ebox-range-identity-test--input '(a b) value nil keyed))
            (when focused (ebox-focus 'a))
            (dolist (order '((b a) (c b a) (a c b) (c a)))
              (let ((candidate (ebox-candidate-begin (current-buffer))))
                (if root-update
                    (ebox-candidate-replace-root
                     candidate (ebox-range-identity-test--input order value nil keyed))
                  (ebox-candidate-replace-range-ref
                   candidate 'rows (ebox-range-identity-test--input order value 'rows keyed)))
                (ebox-commit (current-buffer) candidate))
              (should (eq (ebox-focused-host-ref) (and focused 'a)))
              (setq value (concat value "+"))
              (let ((candidate (ebox-candidate-begin (current-buffer))))
                (ebox-candidate-replace-range-ref
                 candidate '(value a) (ebox-range-identity-test--input nil value 'value keyed))
                (ebox-commit (current-buffer) candidate))
              (should (eq (ebox-focused-host-ref) (and focused 'a)))
              (should (integer-or-marker-p (ebox-host-ref-position (current-buffer) 'a)))
              (let ((expected (substring-no-properties
                               (ebox-render (ebox-range-identity-test--input order value nil keyed)))))
                (should (equal expected (buffer-substring-no-properties (point-min) (point-max))))
                (should (equal expected
                               (substring-no-properties
                                (ebox-render (plist-get (ebox-surface-buffer-snapshot
                                                         (current-buffer)) :input)))))))))))))

(provide 'ebox-range-identity-tests)
;;; ebox-range-identity-tests.el ends here
