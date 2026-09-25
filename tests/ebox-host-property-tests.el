;;; ebox-host-property-tests.el --- Composable Host updates -*- lexical-binding: t; -*-

;;; Commentary:
;; Framework property updates retain content, children and public addresses.
;; Compare published output with a fresh canonical render, independently of
;; the projection strategy chosen by Ebox.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-host-property-test--input (&rest specs)
  "Build SPECS of (REF TAG STYLE INTERACTIONS CONTENT &optional CLASS RULES).
CONTENT is text or child specs; (:range REF SPEC...) describes a child Range."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((node (spec)
           (if (eq (car spec) :range)
               (apply #'ebox-child-range (cadr spec) (mapcar #'node (cddr spec)))
             (pcase-let* ((`(,ref ,tag ,style ,interactions ,content . ,rest) spec)
                          (declarations (ebox-style-compile-form tag style))
                          (handle (ebox-source-builder-bind
                                   builder :identity ref :key ref :id ref
                                   :class (car rest) :interactions interactions
                                   :ecss (ebox-style-compile-rules (cadr rest))
                                   :declarations declarations))
                          (facts (ebox-canonical-facts-from-declarations
                                  tag declarations interactions)))
               (if (eq tag 'text)
                   (ebox-text-create :value content :source-handle handle
                                     :owned-facts facts)
                 (apply #'ebox-box-create
                        (append
                         (ebox-canonical-box-configuration tag declarations)
                         (list :source-handle handle :owned-facts facts
                               :source-builder builder
                               :children (mapcar #'node content)))))))))
      (let ((roots (mapcar #'node specs)))
        (ebox-canonical-input-create roots (ebox-source-builder-finish builder))))))

(defun ebox-host-property-test--visible (text)
  "Return observable content, geometry, paint and help from rendered TEXT."
  (list (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (mapcar (lambda (property)
                                   (get-text-property position property text))
                                 '(face display help-echo pointer mouse-face)))))

(defun ebox-host-property-test--matches (input)
  "Assert the current buffer and its exported snapshot render like INPUT."
  (let ((expected (ebox-host-property-test--visible (ebox-render input))))
    (should (equal expected (ebox-host-property-test--visible (buffer-string))))
    (should
     (equal expected
            (ebox-host-property-test--visible
             (ebox-render (plist-get (ebox-surface-buffer-snapshot
                                      (current-buffer)) :input)))))))

(ert-deftest ebox-host-properties-compose-layout-interaction-and-content ()
  "Layout, native bindings and child content change through one candidate."
  (dolist (tag '(column row flex grid))
    (let* ((clicks 0)
           (keymap (ebox-keymap-create :activate (lambda () (cl-incf clicks))))
           (initial '(panel column (:width (ch 28)) nil
                            ((message text nil nil "Before"))))
           (previous (ebox-host-property-test--input initial)))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) previous)
        (let ((handle (ebox-region-resolve (current-buffer) "message")))
          (dolist (enabled '(nil t))
            (let* ((style (when (not enabled)
                            '(:width (ch 16) :padding ((lh 1) (ch 2))
                                     :color "red")))
                   (interactions (list :keymap keymap :tab-index 0
                                       :disabled (not enabled)
                                       :help-echo (if enabled "Ready" "Busy")))
                   (next (ebox-host-property-test--input
                          `(panel ,tag ,style ,interactions
                                  ((ignored text nil nil "Ignored")))))
                   (candidate (ebox-candidate-begin (current-buffer))))
              (should (eq candidate
                          (ebox-candidate-update-host-properties
                           candidate 'panel previous next)))
              (ebox-candidate-replace-host-ref
               candidate 'message
               (ebox-host-property-test--input '(message text nil nil "After")))
              (ebox-commit (current-buffer) candidate)
              (ebox-host-property-test--matches
               (ebox-host-property-test--input
                `(panel ,tag ,style ,interactions ((message text nil nil "After")))))
              (ebox-region-update handle :content "After")
              (ebox-activate (ebox-host-ref-position (current-buffer) 'message) t)
              (should (= clicks (if enabled 1 0)))
              (setq previous next))))))))

(ert-deftest ebox-host-properties-compose-with-range-reorder ()
  "A parent property update retains a reordered Range and child addresses."
  (dolist (properties-first '(nil t))
    (let* ((before (ebox-host-property-test--input
                    '(panel column (:width (ch 24)) nil
                            ((:range rows (a text nil (:tab-index 0) "A")
                                     (b text nil nil "B"))))))
           (next (ebox-host-property-test--input
                  '(panel column (:width (ch 12) :color "blue") nil nil))))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) before)
        (ebox-focus 'a)
        (let ((handle (ebox-region-resolve (current-buffer) "a"))
              (candidate (ebox-candidate-begin (current-buffer))))
          (when properties-first
            (ebox-candidate-update-host-properties candidate 'panel before next))
          (ebox-candidate-replace-range-ref
           candidate 'rows
           (ebox-host-property-test--input
            '(b text nil nil "B2") '(a text nil (:tab-index 0) "A2")))
          (unless properties-first
            (ebox-candidate-update-host-properties candidate 'panel before next))
          (ebox-commit (current-buffer) candidate)
          (should (eq 'a (ebox-focused-host-ref)))
          (ebox-host-property-test--matches
           (ebox-host-property-test--input
            '(panel column (:width (ch 12) :color "blue") nil
                    ((:range rows (b text nil nil "B2")
                             (a text nil (:tab-index 0) "A2"))))))
          (ebox-region-update handle :content "A2"))))))

(ert-deftest ebox-host-properties-inherit-into-replaced-styled-subtrees ()
  "An inherited property update composes with replaced items that own styled children.

The replaced Range items are Boxes whose children carry their own author
declarations, so the inherited color must reach every new leaf while the
publication stays consistent."
  (dolist (properties-first '(nil t))
    (let* ((before (ebox-host-property-test--input
                    '(panel column (:width (ch 24)) nil
                            ((:range rows
                                     (a row (:padding-left (ch 1)) nil
                                        ((a1 text (:font-weight bold) nil "A1")
                                         (a2 text (:font-weight bold) nil "A2")))
                                     (b row (:padding-left (ch 1)) nil
                                        ((b1 text (:font-weight bold) nil "B1"))))))))
           (next (ebox-host-property-test--input
                  '(panel column (:width (ch 24) :color "blue") nil nil)))
           (items '((b row (:padding-left (ch 2)) nil
                       ((b1 text (:font-weight bold) nil "B1")
                        (b2 text (:font-weight bold) nil "B2")))
                    (a row (:padding-left (ch 2)) nil
                       ((a1 text (:font-weight bold) nil "A1"))))))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) before)
        (let ((candidate (ebox-candidate-begin (current-buffer))))
          (when properties-first
            (ebox-candidate-update-host-properties candidate 'panel before next))
          (ebox-candidate-replace-range-ref
           candidate 'rows (apply #'ebox-host-property-test--input items))
          (unless properties-first
            (ebox-candidate-update-host-properties candidate 'panel before next))
          (ebox-commit (current-buffer) candidate)
          (ebox-host-property-test--matches
           (ebox-host-property-test--input
            (list 'panel 'column '(:width (ch 24) :color "blue") nil
                  (list (append '(:range rows) items))))))))))

(ert-deftest ebox-host-properties-preserve-text-and-structural-ownership ()
  "Property updates refine retained owners and cannot resurrect removed owners."
  (dolist (operation '(content parent remove root))
    (with-temp-buffer
      (let* ((before (ebox-host-property-test--input
                      '(outer column nil nil
                              ((panel column nil nil ((a text nil nil "Before")))))))
             (next (ebox-host-property-test--input
                    '(a text (:color "red") (:help-echo "New") "Ignored"))))
        (ebox-render-to-buffer (current-buffer) before)
        (let ((candidate (ebox-candidate-begin (current-buffer))))
          (ebox-candidate-update-host-properties candidate 'a before next)
          (pcase operation
            ('content
             (ebox-candidate-replace-host-ref
              candidate 'a (ebox-host-property-test--input '(a text nil nil "After"))))
            ((or 'parent 'remove)
             (ebox-candidate-replace-host-ref
              candidate 'panel
              (ebox-host-property-test--input
               `(panel column nil nil ,(when (eq operation 'parent)
                                         '((a text nil nil "After")))))))
            ('root
             (ebox-candidate-replace-root
              candidate (ebox-host-property-test--input
                         '(outer column nil nil
                                 ((panel column nil nil ((a text nil nil "After")))))))))
          (ebox-commit (current-buffer) candidate)
          (ebox-host-property-test--matches
           (ebox-host-property-test--input
            `(outer column nil nil
                    ((panel column nil nil
                            ,(pcase operation
                               ('remove nil)
                               ('root '((a text nil nil "After")))
                               (_ '((a text (:color "red") (:help-echo "New") "After"))))))))))))))

(ert-deftest ebox-host-properties-update-selector-facts-and-rules ()
  "Rule and class changes restyle retained descendants without new child input."
  (cl-labels ((input (class rules &optional empty)
                (ebox-host-property-test--input
                 `(panel column (:width (ch 24)) nil
                         ,(unless empty '((a text nil nil "Retained")))
                         ,class ,rules))))
    (let ((previous (input nil nil)))
      (with-temp-buffer
        (ebox-render-to-buffer (current-buffer) previous)
        (dolist (step '(("accent" (("&.accent text" :color "red")))
                        (nil (("&.accent text" :color "red")))
                        ("accent" (("&.accent text" :color "blue")))
                        ("accent" nil)))
          (let* ((next (input (car step) (cadr step) t))
                 (candidate (ebox-candidate-begin (current-buffer))))
            (ebox-candidate-update-host-properties candidate 'panel previous next)
            (ebox-commit (current-buffer) candidate)
            (ebox-host-property-test--matches (apply #'input step))
            (setq previous next)))))))

(provide 'ebox-host-property-tests)
;;; ebox-host-property-tests.el ends here
