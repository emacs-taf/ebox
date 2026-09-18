;;; ebox-paint.el --- Ebox-owned mutable paint slots -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Paint slots are stable named-face addresses used by Ebox computed styles.
;; The slot and its face-remapping journal are owned by Ebox so rendering does
;; not cross the generic TP property layer for an operation that is local to a
;; mounted Ebox buffer.

;;; Code:

(require 'cl-lib)

(define-error 'ebox-invalid-paint-slot
  "Invalid Ebox paint slot declaration")

(cl-defstruct (ebox-paint-slot
               (:constructor ebox-paint--make-slot))
  "Stable named-face address for one mutable Ebox paint contribution."
  face spec installed-p)

(defvar ebox-paint--slot-counter 0
  "Monotonic id source for private Ebox paint-slot faces.")

(defun ebox-paint--face-spec (spec)
  "Return validated face SPEC for an Ebox paint slot."
  (unless (and (listp spec)
               (zerop (% (length spec) 2))
               (cl-loop for key in spec by #'cddr always (keywordp key)))
    (signal 'ebox-invalid-paint-slot (list :spec spec)))
  (copy-tree spec))

(defun ebox-paint-slot-create (spec)
  "Create a stable paint slot initialized from anonymous face SPEC."
  (let* ((face (intern (format "ebox-paint-slot-%d"
                               (cl-incf ebox-paint--slot-counter))))
         (slot (ebox-paint--make-slot
                :face face
                :spec (ebox-paint--face-spec spec)
                :installed-p nil)))
    (make-face face)
    slot))

(defun ebox-paint-slot-update (slot spec)
  "Update SLOT to anonymous face SPEC without changing its address."
  (unless (ebox-paint-slot-p slot)
    (signal 'wrong-type-argument (list 'ebox-paint-slot-p slot)))
  (let* ((face (ebox-paint-slot-face slot))
         (next (ebox-paint--face-spec spec))
         (previous (ebox-paint-slot-spec slot)))
    (condition-case err
        (progn
          (face-spec-reset-face face)
          (when next
            (face-spec-set face `((t ,next))))
          (setf (ebox-paint-slot-spec slot) next))
      (error
       (face-spec-reset-face face)
       (when previous
         (face-spec-set face `((t ,previous))))
       (signal (car err) (cdr err))))
    slot))

(defun ebox-paint-slot-apply-updates (buffer updates)
  "Apply `(SLOT . SPEC)' UPDATES to BUFFER in one face-remap swap.
Return a rollback journal containing the previous buffer map and slot specs."
  (unless (buffer-live-p buffer)
    (signal 'wrong-type-argument (list 'buffer-live-p buffer)))
  (let ((normalized
         (mapcar
          (lambda (entry)
            (unless (ebox-paint-slot-p (car entry))
              (signal 'wrong-type-argument
                      (list 'ebox-paint-slot-p (car entry))))
            (cons (car entry) (ebox-paint--face-spec (cdr entry))))
          updates))
        slot-journal next)
    (with-current-buffer buffer
      (setq next (copy-tree face-remapping-alist))
      (dolist (entry normalized)
        (let* ((slot (car entry))
               (spec (cdr entry))
               (face (ebox-paint-slot-face slot)))
          (push (list slot (copy-tree (ebox-paint-slot-spec slot))
                      (ebox-paint-slot-installed-p slot))
                slot-journal)
          (setq next (assq-delete-all face next))
          (when spec
            (push (list face spec) next))
          (setf (ebox-paint-slot-spec slot) spec
                (ebox-paint-slot-installed-p slot) t)))
      (prog1
          (list :buffer buffer
                :face-remapping-alist (copy-tree face-remapping-alist)
                :slot-specs (nreverse slot-journal))
        (setq-local face-remapping-alist next)))))

(defun ebox-paint-slot-rollback-updates (journal)
  "Restore Ebox paint slots from reverse-safe JOURNAL."
  (when-let* ((buffer (plist-get journal :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local face-remapping-alist
                    (copy-tree
                     (plist-get journal :face-remapping-alist))))))
  (dolist (entry (reverse (plist-get journal :slot-specs)))
    (setf (ebox-paint-slot-spec (nth 0 entry)) (copy-tree (nth 1 entry))
          (ebox-paint-slot-installed-p (nth 0 entry)) (nth 2 entry)))
  nil)

(provide 'ebox-paint)
;;; ebox-paint.el ends here
