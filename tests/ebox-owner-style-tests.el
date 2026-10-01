;;; ebox-owner-style-tests.el --- Retained owner style publication -*- lexical-binding: t; -*-

;;; Commentary:
;; Owner paint and inherited fonts publish locally only in retained slots.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defun ebox-owner-style-test--canonical (spec)
  "Build canonical SPEC with stable source identities and public Host refs."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((node (entry)
           (pcase-let* ((`(,ref ,tag ,style ,surface . ,children) entry)
                        (declarations (ebox-style-compile-form tag style))
                        (handle (ebox-source-builder-bind
                                 builder :identity ref :key ref :id ref
                                 :declarations declarations))
                        (facts (ebox-canonical-facts-from-declarations
                                tag declarations surface)))
             (if (eq tag 'text)
                 (ebox-text-create :value (car children) :source-handle handle
                                   :owned-facts facts)
               (apply #'ebox-box-create
                      (append (ebox-canonical-box-configuration tag declarations)
                              (list :source-handle handle :owned-facts facts
                                    :source-builder builder
                                    :children (mapcar #'node children))))))))
      (let ((root (node spec)))
        (ebox-canonical-input-create
         (list root) (ebox-source-builder-finish builder))))))

(defun ebox-owner-style-test--row (index selected &optional changes)
  "Describe row INDEX with SELECTED paint and optional CHANGES."
  (let* ((active (= index selected))
         (ref (intern (format "row-%d" index)))
         (cells
          `((,(intern (format "index-%d" index)) box
             (:width stretch :height (lh 1) :overflow hidden :font-weight normal
              :color ,(if active "#ff0000" "#777777")) nil
             (,(intern (format "number-%d" index)) text nil nil
              ,(number-to-string index)))
            (,(intern (format "title-%d" index)) box
             (:width stretch :height (lh 1) :overflow hidden) nil
             (,(intern (format "label-%d" index)) text nil nil
              ,(or (plist-get changes :label)
                   (if (= index 0) "Alpha" "Bravo")))))))
    `(,ref grid
       (:width ,(or (plist-get changes :width) 'stretch)
        :height ,(or (plist-get changes :height) '(lh 1))
        :padding-inline ,(or (plist-get changes :padding) '(ch 1))
        :grid-template-columns ((ch 4) (fr 1))
        :overflow hidden :wrap-mode none
        :font-weight ,(if active 'bold 'normal)
        :background-color ,(if active "#223344" "#ffffff"))
       (:help-echo ,(if active "Selected row" "Choose row"))
       ,@(if (plist-get changes :reorder) (reverse cells) cells))))

(defun ebox-owner-style-test--rows (selected &optional changes)
  "Describe the retained owner with SELECTED style and CHANGES."
  `(rows column (:max-width none :max-height none :width ,(or (plist-get changes :width) '(ch 40))
                 :height ,(or (plist-get changes :height) '(lh 3))
                 :font-weight ,(if (= selected 1) 'bold 'normal)
                 :background-color ,(if (= selected 1) "#445566" "#eeeeee")) nil
     ,(ebox-owner-style-test--row 0 selected changes)
     ,(ebox-owner-style-test--row 1 selected changes)))

(defun ebox-owner-style-test--input (selected &optional changes)
  "Build two fixed Grid rows with SELECTED paint and optional CHANGES."
  (ebox-owner-style-test--canonical
   `(root column (:width (ch 40) :height (lh 6) :color "#112233"
                  :background-color "#dddddd") nil
      (heading text nil nil "Heading")
      ,(ebox-owner-style-test--rows selected changes)
      (footer text nil nil "Footer"))))

(defun ebox-owner-style-test--candidate (selected &optional changes)
  "Replace one retained owner with SELECTED style and CHANGES."
  (let ((candidate (ebox-candidate-begin (current-buffer))))
    (ebox-candidate-replace-host-ref
     candidate 'rows
     (ebox-owner-style-test--canonical (ebox-owner-style-test--rows selected changes)))
    candidate))

(defun ebox-owner-style-test--visible (text)
  "Return TEXT's visible characters, paint, display and interaction properties."
  (list (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (mapcar (lambda (property)
                                   (get-text-property position property text))
                                 '(face display help-echo pointer)))))

(defun ebox-owner-style-test--check (input)
  "Compare the current publication with a fresh rendering of INPUT."
  (should (equal (ebox-owner-style-test--visible (buffer-string))
                 (ebox-owner-style-test--visible (ebox-render input)))))

(defun ebox-owner-style-test--local-report ()
  "Require the current committed report to describe local owner projection."
  (let ((report (ebox-buffer-update-report (current-buffer))))
    (ert-info ((format "%S" report))
      (should (memq (plist-get report :projection-kind) '(span-patch owner-scoped)))
      (should (memq (plist-get report :strategy) '(span-patch owner-rerender)))
      (should-not (plist-get report :native-fallback-reason))
      (should-not (plist-get report :publication-full-root)))))

(ert-deftest ebox-owner-style-grid-row-keeps-one-line-slot ()
  "A Grid owner's paint, font, child content and native properties stay local."
  (let ((ebox-native-reflow-module-path nil))
    (cl-labels ((input (selected label)
                 (ebox-owner-style-test--canonical
                  `(root column (:width (ch 40) :height (lh 4)
                                 :background-color "#cccccc") nil
                     ,(ebox-owner-style-test--row 0 selected (list :label label))
                     (footer text nil nil "Unchanged footer")))))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer (current-buffer) (input 1 "Alpha"))
              (dolist (case '((0 "Longer title") (1 "X") (0 "Alpha")))
                (pcase-let ((`(,selected ,label) case)
                            (candidate (ebox-candidate-begin (current-buffer))))
                  (ebox-candidate-replace-host-ref
                   candidate 'row-0
                   (ebox-owner-style-test--canonical
                    (ebox-owner-style-test--row 0 selected (list :label label))))
                  (ebox-commit (current-buffer) candidate)
                  (ebox-owner-style-test--local-report)
                  (should (= 1 (plist-get (ebox-buffer-update-report (current-buffer))
                                         :patch-count)))
                  (ebox-owner-style-test--check (input selected label)))))
          (ebox-unmount-buffer (current-buffer)))))))

(ert-deftest ebox-owner-style-publishes-paint-and-inherited-fonts-locally ()
  "An owner's own paint and font changes retain the group of row slots."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
            (dolist (selected '(1 0 1))
              (let ((next (ebox-owner-style-test--input selected)))
                (should-not (ebox-canonical-input-equal-p
                             next (ebox-owner-style-test--input (- 1 selected))))
                (ebox-commit (current-buffer) (ebox-owner-style-test--candidate selected))
                (ebox-owner-style-test--local-report)
                (ebox-owner-style-test--check next))))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-rejection-preserves-published-generation ()
  "Rejected local style publication preserves pixels and permits a local retry."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
            (let ((before (buffer-string))
                  (report (ebox-buffer-update-report (current-buffer)))
                  (next (ebox-owner-style-test--input 1)))
              (should-error
               (ebox-commit (current-buffer) (ebox-owner-style-test--candidate 1)
                            (lambda (_report) (error "Reject owner style"))))
              (should (equal-including-properties before (buffer-string)))
              (should (equal report (ebox-buffer-update-report (current-buffer))))
              (ebox-commit (current-buffer) (ebox-owner-style-test--candidate 1))
              (ebox-owner-style-test--local-report)
              (ebox-owner-style-test--check next)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-declines-changed-layout-inputs ()
  "Owner padding changes cannot reuse a paint/typography slot proof."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
            (let ((next (ebox-owner-style-test--input 1 '(:padding (ch 2)))))
              (ebox-commit (current-buffer)
                           (ebox-owner-style-test--candidate 1 '(:padding (ch 2))))
              (should-not (memq (plist-get (ebox-buffer-update-report (current-buffer))
                                           :projection-kind)
                                '(span-patch owner-scoped)))
              (ebox-owner-style-test--check next)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-declines-reordered-children ()
  "Moving keyed cells cannot be certified as an unchanged owner role topology."
  (let ((ebox-native-reflow-module-path nil))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
            (let ((next (ebox-owner-style-test--input 1 '(:reorder t))))
              (ebox-commit (current-buffer)
                           (ebox-owner-style-test--candidate 1 '(:reorder t)))
              (should-not (memq (plist-get (ebox-buffer-update-report (current-buffer))
                                           :projection-kind)
                                '(span-patch owner-scoped)))
              (ebox-owner-style-test--check next)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-owner-style-declines-changed-owner-slots ()
  "Changed owner widths and heights require a new allocation."
  (let ((ebox-native-reflow-module-path nil))
    (dolist (changes '((:width (ch 30)) (:height (lh 2))))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer (current-buffer) (ebox-owner-style-test--input 0))
              (let ((next (ebox-owner-style-test--input 1 changes)))
                (ebox-commit (current-buffer)
                             (ebox-owner-style-test--candidate 1 changes))
                (should-not (memq (plist-get (ebox-buffer-update-report (current-buffer))
                                             :projection-kind)
                                  '(span-patch owner-scoped)))
                (ebox-owner-style-test--check next)))
          (ebox-unmount-buffer (current-buffer)))))))

(ert-deftest ebox-native-plan-declines-intrinsic-and-stretch-heights ()
  "Unchanged descendant heights are checked before native frame execution."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (let ((ebox-viewport-width 40) (ebox-viewport-height 8))
    (dolist (property '(:height :min-height :max-height))
      (dolist (height '(stretch min-content max-content fit-content))
        (cl-labels
            ((pane (size)
               `(pane column (,property ,size) nil
                  (child text nil nil "Retained")))
             (input (label size)
               (ebox-owner-style-test--canonical
                `(root column (:width stretch :height (lh 6)) nil
                   (label-a text nil nil ,label)
                   (label-b text nil nil ,label)
                   (label-c text nil nil ,label) ,(pane size))))
             (change (label &optional size)
               (let ((candidate (ebox-candidate-begin (current-buffer))))
                 (dolist (ref '(label-a label-b label-c))
                   (ebox-candidate-replace-host-ref
                    candidate ref
                    (ebox-owner-style-test--canonical `(,ref text nil nil ,label))))
                 (when size
                   (ebox-candidate-replace-host-ref
                    candidate 'pane (ebox-owner-style-test--canonical (pane size))))
                 (ebox-commit (current-buffer) candidate))))
          (with-temp-buffer
            (unwind-protect
                (progn
                  (ebox-render-to-buffer (current-buffer) (input "Before" height))
                  (ebox-rerender-buffer-with-context (current-buffer) 40 8)
                  (change "After")
                  (let ((report (ebox-buffer-update-report (current-buffer))))
                    (should-not (eq (plist-get report :projection-kind) 'native-frame))
                    (should-not (plist-get report :native-attempt))
                    (should-not (plist-get report :native-fallback-reason)))
                  (ebox-owner-style-test--check (input "After" height))
                  ;; Horizontal stretch stays native-capable once the vertical
                  ;; dimension returns to the compiler's supported subset.
                  (let ((size (pcase property
                                (:height '(lh 2)) (:max-height 'none) (_ 'auto))))
                    (change "Native" size)
                    (let ((report (ebox-buffer-update-report (current-buffer))))
                      (ert-info ((format "%S %S: %S" property height report))
                        (should (eq (plist-get report :projection-kind) 'native-frame))))
                    (ebox-owner-style-test--check (input "Native" size))))
              (ebox-unmount-buffer (current-buffer)))))))))

(provide 'ebox-owner-style-tests)
;;; ebox-owner-style-tests.el ends here
