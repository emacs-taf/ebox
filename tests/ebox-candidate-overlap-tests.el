;;; ebox-candidate-overlap-tests.el --- Overlapping public replacements -*- lexical-binding: t; -*-

;;; Commentary:
;; Parent and child writes in one candidate preserve all accepted content.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defun ebox-overlap-test--input (title disabled &optional child-only)
  "Build TITLE and a DISABLED control.
CHILD-ONLY t returns just the control; `frame' wraps the panel with a sibling."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((text-node (id text)
           (ebox-text-create
            :value text
            :source-handle (ebox-source-builder-bind builder :identity id)
            :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (control ()
           (let* ((facts (list :tab-index 0 :disabled disabled))
                  (handle (ebox-source-builder-bind builder :identity 'save :key 'save :interactions facts)))
             (ebox-box-create
              :source-handle handle :layout (ebox-normal-layout-create)
              :owned-facts (ebox-canonical-facts-from-declarations 'box nil facts)
              :children (list (text-node 'save-text "Save"))))))
      (let ((root (if (eq child-only t) (control)
                    (ebox-box-create
                     :source-handle (ebox-source-builder-bind builder :identity 'root :key 'root)
                     :layout (ebox-column-layout-create)
                     :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
                     :children (list (ebox-box-create
                                      :source-handle (ebox-source-builder-bind builder :identity 'form :key 'form)
                                      :layout (ebox-column-layout-create)
                                      :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
                                      :children (list (ebox-box-create
                                                       :source-handle (ebox-source-builder-bind builder :identity 'title-entry)
                                                       :layout (ebox-normal-layout-create)
                                                       :owned-facts (ebox-canonical-facts-from-declarations 'box nil)
                                                       :children (list (text-node 'title title))) (control))))))))
        (when (eq child-only 'frame)
          (setq root (ebox-box-create
                      :source-handle (ebox-source-builder-bind builder :identity 'frame :key 'frame)
                      :layout (ebox-row-layout-create)
                      :owned-facts (ebox-canonical-facts-from-declarations 'row nil)
                      :children (list (text-node 'aside "Other content") root))))
        (ebox-canonical-input-create (list root) (ebox-source-builder-finish builder))))))

(ert-deftest ebox-overlapping-replacements-retain-parent-text-and-child-state ()
  "Same-length text changes survive a subsequent retained child replacement."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-overlap-test--input "AA" nil 'frame))
    (ebox-focus 'title-entry)
    (dolist (entry '(("BB" . t) ("AA") ("中文" . t)))
      (let ((title (car entry)) (disabled (cdr entry))
            (candidate (ebox-candidate-begin (current-buffer))))
        (ebox-candidate-replace-host-ref candidate 'root (ebox-overlap-test--input title disabled))
        (ebox-candidate-replace-host-ref candidate 'save (ebox-overlap-test--input title disabled t))
        (ebox-commit (current-buffer) candidate))
      (should (string-match-p (car entry) (buffer-string)))
      (should (eq (ebox-focused-host-ref) 'title-entry))
      (if (cdr entry)
          (should-error (ebox-focus 'save) :type 'user-error)
        (should (eq (ebox-focus 'save) 'save))
        (ebox-focus 'title-entry)))
    (let ((before (buffer-substring-no-properties (point-min) (point-max)))
          (candidate (ebox-candidate-begin (current-buffer))))
      (ebox-candidate-replace-host-ref candidate 'root (ebox-overlap-test--input "Rejected" nil))
      (ebox-candidate-replace-host-ref candidate 'save (ebox-overlap-test--input "Rejected" nil t))
      (should-error (ebox-commit (current-buffer) candidate (lambda (_report) (error "Reject"))))
      (should (equal before (buffer-substring-no-properties (point-min) (point-max))))
      (should (eq (ebox-focused-host-ref) 'title-entry)))))

(provide 'ebox-candidate-overlap-tests)
;;; ebox-candidate-overlap-tests.el ends here
