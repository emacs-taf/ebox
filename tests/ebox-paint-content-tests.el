;;; ebox-paint-content-tests.el --- Retained inherited paint -*- lexical-binding: t; -*-

;;; Commentary:
;; Compose canonical content replacements with inherited parent paint, then
;; validate later updates and exported snapshots through public interfaces.

;;; Code:
(require 'ert)
(require 'ebox)
(require 'face-remap)

(defun ebox-paint-content-test--input (scope color message &optional status count)
  "Build a nested panel, or a single leaf when COLOR is nil.
For a leaf, STATUS is its identity; otherwise it is the displayed status."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((text-node (id value)
           (ebox-text-create
            :value value
            :source-handle (ebox-source-builder-bind
                            builder :identity id :ecss-scopes (list scope))
            :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (box-node (id props children)
           (let* ((tag (if (eq id 'panel) 'box 'column))
                  (declarations (ebox-style-compile-form tag props))
                  (handle (ebox-source-builder-bind
                           builder :identity id :declarations declarations
                           :ecss-scopes (list scope)
                           :ecss-scope-roots (when (eq id 'outer) (list scope)))))
             (apply #'ebox-box-create
                    (append
                     (ebox-canonical-box-configuration tag declarations)
                     (list :source-handle handle :source-builder builder
                           :children children
                           :owned-facts (ebox-canonical-facts-from-declarations
                                         tag declarations)))))))
      (let ((node
             (if color
                 (box-node
                  'outer nil
                  (list
                   (box-node
                    'panel (list :color color :width '(ch 32)
                                 :padding '((lh 1) (ch 1)))
                    (list (box-node 'group nil
                                    (list (text-node 'status status)
                                          (text-node 'message message)
                                          (text-node 'count count)))))))
               (text-node status message))))
        (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder))))))

(ert-deftest ebox-inherited-paint-keeps-subsequent-content-and-snapshots ()
  "Successive parent/child edits publish matching content, styles and source facts."
  (let ((scope (ebox-style-scope-create nil)))
    (cl-labels
        ((input (color message status count)
           (ebox-paint-content-test--input scope color message status count))
         (visible (text)
           (list (substring-no-properties text)
                 (cl-loop for position below (length text)
                          collect (list (get-text-property position 'face text)
                                        (get-text-property position 'display text))))))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) (input "white" "Idle" "Idle" "0"))
        (let ((previous "white"))
          (dolist (step '(("black" "Success 1" "Success" "0")
                          ("black" "Success 2" "Success" "1")
                          ("white" "Failure 3" "Error" "2")
                          ("black" "Success 4" "Success" "2")))
            (let* ((color (nth 0 step))
                   (candidate (ebox-candidate-begin (current-buffer))))
              (cl-mapc
               (lambda (identity value)
                 (ebox-candidate-replace-host-ref
                  candidate identity (input nil value identity nil)))
               '(message status count) (list (nth 1 step) (nth 2 step) (nth 3 step)))
              (unless (equal color previous)
                (should
                 (ebox-candidate-update-host-properties
                  candidate 'panel (input previous "Unused" "Unused" "0")
                  (input color "Unused" "Unused" "0"))))
              (ebox-commit (current-buffer) candidate)
              (let* ((expected (visible (ebox-render (apply #'input step))))
                     (snapshot (ebox-surface-buffer-snapshot (current-buffer))))
                (should (equal expected (visible (buffer-string))))
                (should (equal expected (visible (ebox-render (plist-get snapshot :input))))))
              (setq previous color))))))))

(ert-deftest ebox-retained-content-resamples-display-between-publications ()
  "A scoped measurement snapshot never outlives a font/remapping change."
  (let ((scope (ebox-style-scope-create nil)))
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer) (ebox-paint-content-test--input scope "white" "起点" "Ready" "0"))
      (dolist (scale '(0 2 -1 0))
        (text-scale-set scale)
        (let* ((value (format "中文 mixed width %d\n第二行" scale))
               (candidate (ebox-candidate-begin (current-buffer))))
          (ebox-candidate-replace-host-ref
           candidate 'message (ebox-paint-content-test--input scope nil value 'message))
          (ebox-commit (current-buffer) candidate)
          (let ((fresh (ebox-render
                        (ebox-paint-content-test--input scope "white" value "Ready" "0")))
                (actual (buffer-string)))
            (should (equal (substring-no-properties fresh) (substring-no-properties actual)))
            (dotimes (position (length actual))
              (dolist (property '(face display))
                (should (equal (get-text-property position property fresh)
                               (get-text-property position property actual)))))))))))

(provide 'ebox-paint-content-tests)
;;; ebox-paint-content-tests.el ends here
