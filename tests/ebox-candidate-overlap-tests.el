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

(defun ebox-overlap-test--range-input (title value &optional part)
  "Build nested Range owners with TITLE and VALUE, or just PART's input."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((text-node (id text)
           (ebox-text-create
            :value text
            :source-handle (ebox-source-builder-bind builder :identity id :key id)
            :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (box-node (id children)
           (ebox-box-create
            :source-builder builder
            :source-handle (ebox-source-builder-bind builder :identity id :key id)
            :layout (ebox-column-layout-create)
            :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
            :children children))
         (body ()
           (box-node 'body (list (ebox-child-range 'body-items (text-node 'value value)))))
         (content ()
           (box-node 'content
                     (list (ebox-child-range 'heading (text-node 'title title))
                           (body)))))
      (let ((node (pcase part
                    ('title (text-node 'title title))
                    ('value (text-node 'value value))
                    ('content (content))
                    ('empty-content (box-node 'content nil))
                    (_ (box-node 'root
                                 (list (ebox-child-range 'content-items (content))
                                       (text-node 'tail "Unchanged")))))))
        (unless part
          (setq node (box-node 'frame (list (text-node 'aside "Other content") node))))
        (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder))))))

(ert-deftest ebox-nested-range-updates-preserve-later-host-replacements ()
  "Ancestor and descendant Range updates leave both Hosts usable afterwards."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-overlap-test--range-input "Title A" "Value A"))
    (dolist (value '("Value B" "Value C"))
      (let ((candidate (ebox-candidate-begin (current-buffer))))
        (ebox-candidate-replace-range-ref
         candidate 'heading (ebox-overlap-test--range-input "Title B" value 'title))
        (ebox-candidate-replace-range-ref
         candidate 'body-items (ebox-overlap-test--range-input "Title B" value 'value))
        (ebox-commit (current-buffer) candidate))
      (should (string-match-p "Title B" (buffer-string)))
      (should (string-match-p value (buffer-string)))
      (let ((candidate (ebox-candidate-begin (current-buffer))))
        (ebox-candidate-replace-host-ref
         candidate 'value (ebox-overlap-test--range-input "Title B" "Next value" 'value))
        (ebox-commit (current-buffer) candidate))
      (should (string-match-p "Next value" (buffer-string)))
      (should (string-match-p "Unchanged" (buffer-string))))))

(ert-deftest ebox-overlapping-ranges-preserve-followup-child-updates ()
  "Nested replacements publish a tree whose child addresses remain usable."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-overlap-test--range-input "Title A" "Value A"))
    (dolist (value '("Value B" "Value C"))
      (let ((candidate (ebox-candidate-begin (current-buffer))))
        (dolist (ref (if (equal value "Value B")
                         '(content-items body-items) '(body-items content-items)))
          (ebox-candidate-replace-range-ref
           candidate ref
           (if (eq ref 'content-items)
               (ebox-overlap-test--range-input "Title B" "Outer snapshot" 'content)
             (ebox-overlap-test--range-input "Title B" value 'value))))
        (ebox-commit (current-buffer) candidate))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     (substring-no-properties
                      (ebox-render (ebox-overlap-test--range-input "Title B" value)))))
      (let ((candidate (ebox-candidate-begin (current-buffer))))
        (ebox-candidate-replace-host-ref
         candidate 'value (ebox-overlap-test--range-input "Title B" "Followup" 'value))
        (ebox-commit (current-buffer) candidate))
      (should (string-match-p "Followup" (buffer-string))))
    (let ((candidate (ebox-candidate-begin (current-buffer))))
      (ebox-candidate-replace-range-ref
       candidate 'body-items (ebox-overlap-test--range-input "Title" "Removed" 'value))
      (ebox-candidate-replace-range-ref
       candidate 'content-items (ebox-overlap-test--range-input "Title" "Removed" 'empty-content))
      (ebox-commit (current-buffer) candidate))
    (should-not (string-match-p "Removed\\|Followup" (buffer-string)))
    (should (string-match-p "Unchanged" (buffer-string)))
    (should-error (ebox-focus 'value) :type 'user-error)))

(defun ebox-overlap-test--shifted-input (notice value &optional part unkeyed)
  "Build a field after NOTICE, or just PART; UNKEYED omits author keys."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((text-node (id text)
           (ebox-text-create
            :value text :source-handle (ebox-source-builder-bind builder :identity id :key (unless unkeyed id))
            :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (box-node (id children)
           (ebox-box-create
            :source-builder builder
            :source-handle (ebox-source-builder-bind builder :identity id :key (unless unkeyed id))
            :layout (ebox-column-layout-create)
            :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
            :children children)))
      (let* ((field (box-node 'field (list (text-node 'value value))))
             (root
              (if (eq part 'field) field
                (box-node 'panel
                          (list (apply #'ebox-child-range 'fields
                                       (append (when notice (list (text-node 'notice notice)))
                                               (list field))))))))
        (unless part (setq root (box-node 'frame (list root (text-node 'aside "Aside")))))
        (ebox-canonical-input-create (list root) (ebox-source-builder-finish builder))))))

(defun ebox-overlap-test--shifted-workflow (unkeyed)
  "Check nested field changes and rejection, omitting author keys if UNKEYED."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-overlap-test--shifted-input nil "A" nil unkeyed))
    (ebox-focus 'field)
    (dolist (notice '("Busy" nil))
      (let ((candidate (ebox-candidate-begin (current-buffer))))
        (ebox-candidate-replace-host-ref candidate 'panel
                                         (ebox-overlap-test--shifted-input notice "A" 'panel unkeyed))
        (ebox-candidate-replace-host-ref candidate 'field
                                         (ebox-overlap-test--shifted-input notice "B" 'field unkeyed))
        (ebox-commit (current-buffer) candidate))
      (should (eq 'field (ebox-focused-host-ref)))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     (substring-no-properties
                      (ebox-render (ebox-overlap-test--shifted-input notice "B" nil unkeyed))))))
    (let ((candidate (ebox-candidate-begin (current-buffer)))
          (before (buffer-substring-no-properties (point-min) (point-max))))
      (ebox-candidate-replace-host-ref candidate 'panel
                                       (ebox-overlap-test--shifted-input "Rejected" "B" 'panel unkeyed))
      (ebox-candidate-replace-host-ref candidate 'field
                                       (ebox-overlap-test--shifted-input nil "Rejected" 'field unkeyed))
      (should-error (ebox-commit (current-buffer) candidate (lambda (_) (error "Reject"))))
      (should (equal before (buffer-substring-no-properties (point-min) (point-max))))
      (should (eq 'field (ebox-focused-host-ref))))))

(ert-deftest ebox-keyed-range-child-moves-before-a-nested-host-update ()
  "A retained field uses its current position after a notice is inserted or removed."
  (ebox-overlap-test--shifted-workflow nil))

(ert-deftest ebox-explicit-host-identity-survives-sibling-changes-without-keys ()
  "An explicit Host identity remains targetable after conditional siblings move."
  (ebox-overlap-test--shifted-workflow t))

(defun ebox-overlap-test--list-input (count &optional embedded)
  "Build COUNT keyed records, EMBEDDED beside independent content when non-nil."
  (let* ((builder (ebox-source-builder-create))
         (children
          (cl-loop for id from 1 to count collect
                   (ebox-text-create
                    :value (format "Record %03d" id)
                    :source-handle (ebox-source-builder-bind builder :identity (list 'record id) :key id)
                    :owned-facts (ebox-canonical-facts-from-declarations 'text nil))))
         (node (ebox-box-create
                :source-handle (ebox-source-builder-bind builder :identity 'records)
                :layout (ebox-column-layout-create)
                :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
                :children children)))
    (when embedded
      (setq node (ebox-box-create
                  :source-handle (ebox-source-builder-bind builder :identity 'frame)
                  :layout (ebox-column-layout-create)
                  :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
                  :children (list (ebox-text-create
                                   :value "Independent content"
                                   :source-handle (ebox-source-builder-bind builder :identity 'aside)
                                   :owned-facts (ebox-canonical-facts-from-declarations 'text nil))
                                  node))))
    (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder))))

(ert-deftest ebox-large-candidate-removal-preserves-source-order-and-rollback ()
  "Replacing a large list keeps final source order, later updates and rejection."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-overlap-test--list-input 100 t))
    (dolist (count '(90 95))
      (let ((candidate (ebox-candidate-begin (current-buffer))))
        (ebox-candidate-replace-host-ref candidate 'records (ebox-overlap-test--list-input count))
        (ebox-commit (current-buffer) candidate))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     (substring-no-properties (ebox-render (ebox-overlap-test--list-input count t))))))
    (let ((before (buffer-substring-no-properties (point-min) (point-max)))
          (candidate (ebox-candidate-begin (current-buffer))))
      (ebox-candidate-replace-host-ref candidate 'records (ebox-overlap-test--list-input 80))
      (should-error (ebox-commit (current-buffer) candidate (lambda (_report) (error "Reject"))))
      (should (equal before (buffer-substring-no-properties (point-min) (point-max)))))))

(provide 'ebox-candidate-overlap-tests)
;;; ebox-candidate-overlap-tests.el ends here
