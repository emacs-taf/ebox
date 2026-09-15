;;; ebox-focus-within-tests.el --- Scoped public focus navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; Menus and dialogs navigate a logical subtree through the shared focus owner.

;;; Code:
(require 'ert)
(require 'ebox)
(require 'tp)

(defun ebox-focus-within-test--input (items)
  "Build an outside control and a panel containing ITEMS in their given order."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels ((node (identity text &optional children disabled)
                  (let* ((tag (if children 'column 'text))
                         (interactions (unless children (list :tab-index 0 :disabled disabled)))
                         (source (ebox-source-builder-bind
                                  builder :identity identity :key identity :id identity
                                  :interactions interactions))
                         (facts (ebox-canonical-facts-from-declarations tag nil interactions)))
                    (if children
                        (ebox-box-create :source-handle source :owned-facts facts
                                         :layout (ebox-column-layout-create) :children children)
                      (ebox-text-create :source-handle source :owned-facts facts :value text)))))
      (let* ((panel (node 'panel nil
                          (mapcar (lambda (item) (node (car item) (symbol-name (car item)) nil (cadr item))) items)))
             (root (node 'root nil (list (node 'outside "Outside") panel))))
        (ebox-canonical-input-create (list root) (ebox-source-builder-finish builder))))))

(ert-deftest ebox-focus-within-navigates-retained-subtrees ()
  "Scoped order, wrapping and keyed reordering use the same logical focus."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer)
                          (ebox-focus-within-test--input '((a) (disabled t) (b))))
    (ebox-focus 'outside)
    (should-not (ebox-focus-within 'panel 0))
    (should (eq (ebox-focus-within 'panel) 'a))
    (should (eq (ebox-focus-within 'panel 1 t) 'b))
    (should (eq (ebox-focus-within 'panel 1 t) 'a))
    (should (eq (ebox-focus-within 'panel -1 t) 'b))
    (should (eq (ebox-focused-host-ref) 'b))
    (should-error (ebox-focus-within 'panel 1) :type 'user-error)
    (should (eq (ebox-focused-host-ref) 'b))
    (ebox-commit (current-buffer) (ebox-focus-within-test--input '((b) (a))))
    (should (eq (ebox-focus-within 'panel 0) 'b))
    (should (eq (ebox-focus-within 'panel 1) 'a))
    (ebox-commit (current-buffer) (ebox-focus-within-test--input '((b))))
    (should (eq (ebox-focus-within 'panel) 'b))
    ;; Other explicit focus operations remain unrestricted.
    (should (eq (ebox-focus 'outside) 'outside))))

(ert-deftest ebox-focus-within-rejects-unavailable-and-unaccepted-targets ()
  "Rejected roots and transactions preserve accepted focus and point."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-focus-within-test--input '((a))))
    (ebox-focus 'outside)
    (let ((position (point)))
      (should-error (ebox-focus-within 'missing) :type 'user-error)
      (should-error (ebox-focus-within 'panel 'bad) :type 'wrong-type-argument)
      (should-error (tp-with-transaction (ebox-focus-within 'panel)))
      (should (eq (ebox-focused-host-ref) 'outside))
      (should (= position (point))))
    (ebox-region-update "panel" :visibility 'hidden)
    (should-error (ebox-focus-within 'panel) :type 'user-error)
    (should (eq (ebox-focused-host-ref) 'outside))
    (ebox-unmount-buffer (current-buffer))
    (should-error (ebox-focus-within 'panel) :type 'user-error)))

(provide 'ebox-focus-within-tests)
;;; ebox-focus-within-tests.el ends here
