;;; ebox-selector-view.el --- Persistent selector relationships -*- lexical-binding: t; -*-

;;; Commentary:
;; Selector subjects retain immutable local facts and stable relationship keys.
;; A candidate's view resolves those keys without mutating published subjects.
;; ECSS owns matching and cascade through its ordinary subject adapter.

;;; Code:
(require 'cl-lib)
(require 'ecss)
(require 'ebox-source)

(cl-defstruct (ebox-selector-subject
               (:constructor ebox-selector-subject-create))
  "One selector subject version; parent and children are stable tokens."
  token type id classes attributes states parent children)

(defvar ebox-selector-view--current nil
  "Immutable token-to-subject index for the current selector evaluation.")

(defvar ebox-selector-view--topology nil
  "Identity of the current view's parent/child topology.")

(defun ebox-selector-view-topology-stable-p (base added removed)
  "Compare BASE relationships with a candidate ADDED/REMOVED subject delta.
Replacing a source record does not change selector topology when the retained
subject tokens, parents and ordered children are identical."
  (and base
       (cl-loop for token being the hash-keys of removed
                always (gethash token added))
       (cl-loop for token being the hash-keys of added using (hash-values subject)
                for old = (ebox-source--table-value base token)
                always (and old
                            (eq (ebox-selector-subject-parent old)
                                (ebox-selector-subject-parent subject))
                            (equal (ebox-selector-subject-children old)
                                   (ebox-selector-subject-children subject))))))

(defun ebox-selector-view-parent (subject)
  "Resolve SUBJECT's parent in the current candidate view."
  (when-let* ((token (ebox-selector-subject-parent subject)))
    (or (ebox-source--table-value ebox-selector-view--current token)
        (error "Ebox selector parent is absent from its candidate view"))))

(defun ebox-selector-view-children (subject)
  "Resolve SUBJECT's children in the current candidate view."
  (mapcar (lambda (token)
            (or (ebox-source--table-value ebox-selector-view--current token)
                (error "Ebox selector child is absent from its candidate view")))
          (ebox-selector-subject-children subject)))

(defconst ebox-selector-view-adapter
  (ecss-subject-adapter-create
   :type #'ebox-selector-subject-type :id #'ebox-selector-subject-id
   :classes #'ebox-selector-subject-classes :attributes #'ebox-selector-subject-attributes
   :states #'ebox-selector-subject-states :parent #'ebox-selector-view-parent
   :children #'ebox-selector-view-children)
  "ECSS adapter over Ebox's immutable selector facts and candidate relationships.")

(provide 'ebox-selector-view)
;;; ebox-selector-view.el ends here
