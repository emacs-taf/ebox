;;; ebox-property.el --- Ebox-owned native property policies -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; This is the small native-property kernel needed by Ebox.  It deliberately
;; does not provide TP's search, surface, or reactive APIs.  Ebox uses it for
;; identity-preserving keymap comparison and explicit computed style values.

;;; Code:

(require 'cl-lib)

(define-error 'ebox-property-error "Ebox property error")
(define-error 'ebox-invalid-property-policy
  "Invalid Ebox property policy" 'ebox-property-error)

(cl-defstruct (ebox-property-policy
               (:constructor ebox-property--make-policy))
  "Policy governing one namespaced Ebox direct property."
  id normalizer validator equality merge projector)

(cl-defstruct (ebox-property--computed-source
               (:constructor ebox-property--make-computed-source))
  "Explicit computed value source used by Ebox style evaluation."
  function)

(defvar ebox-property--policies (make-hash-table :test #'eq)
  "Registered Ebox native property policies by namespaced id.")

(defun ebox-property--canonical-id-p (id)
  "Return non-nil when ID is a namespaced property symbol."
  (and (symbolp id)
       (let ((name (symbol-name id)))
         (and (string-match-p "/" name)
              (not (string-prefix-p "/" name))
              (not (string-suffix-p "/" name))))))

(defun ebox-property--option (options key fallback)
  "Return KEY from OPTIONS when present, otherwise FALLBACK."
  (if (plist-member options key) (plist-get options key) fallback))

(defun ebox-property--policy-options-valid-p (options)
  "Return non-nil when OPTIONS is a supported property policy plist."
  (and (listp options)
       (zerop (% (length options) 2))
       (cl-loop for key in options by #'cddr
                always (memq key '(:normalizer :validator :equality
                                   :merge :projector)))))

(defun ebox-property--build-policy (id options)
  "Build and validate a policy for ID from OPTIONS."
  (unless (and (ebox-property--canonical-id-p id)
               (ebox-property--policy-options-valid-p options))
    (signal 'ebox-invalid-property-policy (list :property id options)))
  (dolist (key '(:normalizer :validator :equality :merge :projector))
    (let ((value (plist-get options key)))
      (unless (or (null value) (functionp value))
        (signal 'ebox-invalid-property-policy (list key value)))))
  (ebox-property--make-policy
   :id id
   :normalizer (ebox-property--option options :normalizer #'identity)
   :validator (ebox-property--option options :validator (lambda (_value) t))
   :equality (ebox-property--option options :equality #'equal)
   :merge (ebox-property--option options :merge (lambda (_old new) new))
   :projector (plist-get options :projector)))

(defun ebox-define-property-policy (id &rest options)
  "Register namespaced property ID using policy OPTIONS and return its policy."
  (let ((policy (ebox-property--build-policy id options)))
    (puthash id policy ebox-property--policies)
    policy))

(defun ebox-property-policy (id)
  "Return the registered property policy for ID, or nil."
  (gethash id ebox-property--policies))

(defun ebox-text-property-id (property)
  "Return the canonical `text/' policy id for Emacs PROPERTY."
  (unless (symbolp property)
    (signal 'wrong-type-argument (list 'symbolp property)))
  (intern (format "text/%s" property)))

(defun ebox-property--native-keymap-equal-p (left right)
  "Compare native snapshots LEFT and RIGHT, retaining command identity."
  (let ((seen (make-hash-table :test #'eq)))
    (cl-labels
        ((bindings (map)
           (let ((local (copy-sequence (if (symbolp map)
                                           (indirect-function map) map)))
                 entries)
             (set-keymap-parent local nil)
             (map-keymap (lambda (key value) (push (cons key value) entries)) local)
             entries))
         (same (old new)
           (cond
            ((eq old new) t)
            ((memq new (gethash old seen)) t)
            ((and (keymapp old) (keymapp new))
             (puthash old (cons new (gethash old seen)) seen)
             (and (equal-including-properties (keymap-prompt old)
                                               (keymap-prompt new))
                  (same (bindings old) (bindings new))
                  (same (keymap-parent old) (keymap-parent new))))
            ((or (functionp old) (functionp new)) nil)
            ((and (consp old) (consp new))
             (puthash old (cons new (gethash old seen)) seen)
             (and (same (car old) (car new)) (same (cdr old) (cdr new))))
            ((and (vectorp old) (vectorp new) (= (length old) (length new)))
             (puthash old (cons new (gethash old seen)) seen)
             (cl-loop for index below (length old)
                      always (same (aref old index) (aref new index))))
            (t (equal old new)))))
      (same left right))))

(defun ebox-property--native-value-equal-p (left right)
  "Compare native values LEFT and RIGHT while preserving callable identity."
  (cond
   ((and (keymapp left) (keymapp right))
    (ebox-property--native-keymap-equal-p left right))
   ((or (functionp left) (functionp right)) (eq left right))
   (t (equal left right))))

(defun ebox-register-text-property (property)
  "Register and return a direct policy for Emacs PROPERTY."
  (let* ((id (ebox-text-property-id property))
         (existing (ebox-property-policy id)))
    (or existing
        (ebox-define-property-policy
         id :equality #'ebox-property--native-value-equal-p
         :projector (lambda (value) (list property value))))))

(defun ebox-computed (function)
  "Return an explicit computed value source wrapping FUNCTION."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (ebox-property--make-computed-source :function function))

(defun ebox-computed-p (value)
  "Return non-nil when VALUE is an explicit Ebox computed source."
  (ebox-property--computed-source-p value))

(defun ebox-resolve-value (value &optional _property _subject)
  "Resolve VALUE only when it is an explicit `ebox-computed' source."
  (if (ebox-property--computed-source-p value)
      (funcall (ebox-property--computed-source-function value))
    value))

(provide 'ebox-property)
;;; ebox-property.el ends here
