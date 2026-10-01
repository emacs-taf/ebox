;;; ebox-canonical-range-comparison-tests.el --- Partial canonical equality -*- lexical-binding: t; -*-

;;; Commentary:
;; Child range contents may vary while all surrounding source authority agrees.

;;; Code:
(require 'ert)
(require 'ebox)

(defun ebox-canonical-range-test--input (values &optional order title class)
  "Build nested ranges from VALUES, with ORDER, own TITLE and source CLASS."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((text (id value)
           (ebox-text-create
            :value value
            :source-handle (ebox-source-builder-bind builder :identity id)
            :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (box (id children)
           (ebox-box-create
            :source-builder builder
            :source-handle (ebox-source-builder-bind
                            builder :identity id :class class)
            :layout (ebox-column-layout-create)
            :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
            :children children)))
      (let ((root
             (box 'root
                  (list
                   (box 'inner
                        (append
                         (list (text 'title (or title "Title")))
                         (mapcar
                          (lambda (ref)
                            (apply #'ebox-child-range ref
                                   (cl-loop for value in (alist-get ref values)
                                            for index from 0
                                            collect (text (list ref index) value))))
                          (or order '(a empty b)))
                         (list (text 'tail "Tail"))))))))
        (ebox-canonical-input-create
         (list root) (ebox-source-builder-finish builder))))))

(ert-deftest ebox-canonical-equality-masks-only-matching-range-contents ()
  "Masks retain range structure, unmasked text properties and source facts."
  (let* ((values '((a "A") (b "B")))
         (base (ebox-canonical-range-test--input values)))
    (dolist (changed '(((a) (b "B"))
                       ((a "A" "more") (b "B"))
                       ((a "changed") (b "B"))))
      (let ((next (ebox-canonical-range-test--input changed)))
        (should-not (ebox-canonical-input-equal-p base next))
        (should-not (ebox-canonical-input-equal-outside-ranges-p base next nil))
        (should-not (ebox-canonical-input-equal-outside-ranges-p base next '(b)))
        (should (ebox-canonical-input-equal-outside-ranges-p base next '(a)))
        (should (ebox-canonical-input-equal-outside-ranges-p next base '(a)))))
    (should
     (ebox-canonical-input-equal-outside-ranges-p
      base (ebox-canonical-range-test--input '((a "AA") (empty "new") (b)))
      '(a empty b)))
    (dolist (order '((b empty a) (a b) (a empty b extra) (empty a b)))
      (should-not
       (ebox-canonical-input-equal-outside-ranges-p
        base (ebox-canonical-range-test--input values order) '(a empty b extra))))
    (dolist (next (list (ebox-canonical-range-test--input values nil "Other")
                       (ebox-canonical-range-test--input
                        values nil (propertize "Title" 'face 'bold))
                       (ebox-canonical-range-test--input values nil nil '(changed))
                       (ebox-canonical-range-test--input
                        (list '(a "A") (list 'b (propertize "B" 'face 'bold))))))
      (should-not (ebox-canonical-input-equal-outside-ranges-p base next '(a))))
    (should (ebox-canonical-input-equal-outside-ranges-p
             base (ebox-canonical-range-test--input values) '(a)))
    (should-not (ebox-canonical-input-equal-outside-ranges-p base nil '(a)))))

(ert-deftest ebox-canonical-equality-masks-only-stable-host-outputs ()
  "Host output masks preserve root identity, kind and sibling membership."
  (let* ((base (ebox-canonical-range-test--input '((a "A") (b "B"))))
         (next (ebox-canonical-range-test--input '((a "Changed") (b "B")))))
    (should (ebox-canonical-input-equal-outside-ranges-p base next nil '((a 0))))
    (should-not (ebox-canonical-input-equal-outside-ranges-p base next nil '((b 0))))
    (should-not
     (ebox-canonical-input-equal-outside-ranges-p
      base (ebox-canonical-range-test--input '((a "Changed" "Extra") (b "B")))
      nil '((a 0))))
    (should-not
     (ebox-canonical-input-equal-outside-ranges-p
      base (ebox-canonical-range-test--input '((a "Changed") (b "B")) '(b empty a))
      nil '((a 0) (b 0)))))
  (cl-flet ((input (kind identity)
              (let* ((builder (ebox-source-builder-create))
                     (handle (ebox-source-builder-bind builder :identity identity))
                     (root (if (eq kind 'text)
                               (ebox-text-create
                                :value "A" :source-handle handle
                                :owned-facts (ebox-canonical-facts-from-declarations 'text nil))
                             (ebox-box-create
                              :source-handle handle :layout (ebox-column-layout-create)
                              :children nil
                              :owned-facts (ebox-canonical-facts-from-declarations 'column nil)))))
                (ebox-canonical-input-create (list root) (ebox-source-builder-finish builder)))))
    (let ((base (input 'text 'a)))
      (should-not (ebox-canonical-input-equal-outside-ranges-p base (input 'text 'b) nil '(a b)))
      (should-not (ebox-canonical-input-equal-outside-ranges-p base (input 'box 'a) nil '(a))))))

(provide 'ebox-canonical-range-comparison-tests)
;;; ebox-canonical-range-comparison-tests.el ends here
