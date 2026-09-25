;;; ebox-text.el --- Ebox-owned text-property snapshots -*- lexical-binding: t; -*-

;;; Commentary:
;; Mutable text-property values cross the Ebox publication boundary through
;; this small ownership kernel.  It deliberately contains no surface,
;; transaction, layout, or application state.

;;; Code:

(require 'cl-lib)

(define-error 'ebox-unsupported-buffer "Unsupported Ebox buffer")

(defun ebox-text--validate-buffer-range (buffer start end)
  "Validate ordered START and END in live BUFFER."
  (unless (buffer-live-p buffer)
    (signal 'ebox-unsupported-buffer (list buffer)))
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (unless (and (cl-every (lambda (position)
                              (or (integerp position)
                                  (and (markerp position)
                                       (eq (marker-buffer position) buffer)
                                       (marker-position position))))
                            (list start end))
                   (<= (point-min) start end (point-max)))
        (signal 'args-out-of-range (list buffer start end))))))

(defconst ebox-text--copy-cache-missing
  (make-symbol "ebox-text-copy-cache-missing"))

(defvar ebox-text--frozen-values (make-hash-table :test #'eq :weakness 'key)
  "Ebox-owned property values that are never mutated after creation.")

(defun ebox-text--freeze (value)
  "Register Ebox-owned VALUE as immutable and return it.
Owned copies share a frozen value, so its identity survives publication."
  (puthash value t ebox-text--frozen-values)
  value)

(defun ebox-text--copy-mutable-p (value)
  "Return non-nil when VALUE is a recursively copied property container."
  (and (not (functionp value))
       (or (and (consp value) (not (gethash value ebox-text--frozen-values)))
           (stringp value)
           (char-table-p value)
           (and (vectorp value) (not (recordp value))))))

(defun ebox-text--copy-cons-spine (value cache)
  "Copy cons spine VALUE into CACHE while retaining sharing and cycles."
  (let (source head tail reused-p)
    (setq source value)
    (while (consp source)
      (let ((cached (gethash source cache ebox-text--copy-cache-missing)))
        (if (not (eq cached ebox-text--copy-cache-missing))
            (progn
              (if tail (setcdr tail cached) (setq head cached))
              (setq reused-p t source nil))
          (let ((copy (cons nil nil)))
            (puthash source copy cache)
            (if tail (setcdr tail copy) (setq head copy))
            (let ((item (car source)))
              (setcar copy
                       (if (ebox-text--copy-mutable-p item)
                           (ebox-text--copy-property-value item cache)
                         item)))
            (setq tail copy source (cdr source))))))
    (when (and tail (not reused-p))
      (setcdr tail
              (if (null source) nil
                (ebox-text--copy-property-value source cache))))
    head))

(defun ebox-text--copy-proper-list (value cache)
  "Copy proper-list VALUE into CACHE while retaining graph sharing."
  (let ((source value) (cache-free-p t))
    (while (and cache-free-p (consp source))
      (when (not (eq (gethash source cache ebox-text--copy-cache-missing)
                     ebox-text--copy-cache-missing))
        (setq cache-free-p nil))
      (setq source (cdr source)))
    (if (not cache-free-p)
        (ebox-text--copy-cons-spine value cache)
      (let* ((copy (copy-sequence value)) (source value) (target copy))
        (while (consp source)
          (puthash source target cache)
          (let ((item (car source)))
            (when (ebox-text--copy-mutable-p item)
              (setcar target (ebox-text--copy-property-value item cache))))
          (setq source (cdr source) target (cdr target)))
        copy))))

(defun ebox-text--copy-string (value &optional cache reuse-property-p)
  "Copy string VALUE and recursively copy its mutable text properties."
  (let* ((cache (or cache (make-hash-table :test #'eq)))
         (cached (gethash value cache ebox-text--copy-cache-missing)))
    (if (not (eq cached ebox-text--copy-cache-missing))
        cached
      (let ((copy (copy-sequence value)) (position 0) (length (length value)))
        (puthash value copy cache)
        (while (< position length)
          (let ((next (or (next-property-change position value) length))
                (properties (text-properties-at position value)) updates)
            (while properties
              (let* ((property (pop properties))
                     (original (pop properties))
                     (mutable-p (ebox-text--copy-mutable-p original))
                     (reuse-p (and mutable-p reuse-property-p
                                   (funcall reuse-property-p property original)))
                     (copied (if reuse-p original
                               (if mutable-p
                                   (ebox-text--copy-property-value original cache)
                                 original))))
                (unless (eq copied original)
                  (push property updates)
                  (push copied updates))))
            (when updates
              (add-text-properties position next (nreverse updates) copy))
            (setq position next)))
        copy))))

(defun ebox-text--copy-property-value (value &optional cache)
  "Copy mutable property VALUE while retaining sharing and cycles."
  (if (not (ebox-text--copy-mutable-p value))
      value
    (let* ((cache (or cache (make-hash-table :test #'eq)))
           (cached (gethash value cache ebox-text--copy-cache-missing)))
      (if (not (eq cached ebox-text--copy-cache-missing))
          cached
        (cond
         ((consp value)
          (if (proper-list-p value)
              (ebox-text--copy-proper-list value cache)
            (ebox-text--copy-cons-spine value cache)))
         ((stringp value) (ebox-text--copy-string value cache))
         ((char-table-p value)
          (let ((copy (copy-sequence value))
                (default (char-table-range value nil)) entries)
            (puthash value copy cache)
            (set-char-table-parent copy nil)
            (set-char-table-range copy nil nil)
            (map-char-table (lambda (range item) (push (cons range item) entries)) copy)
            (dolist (entry entries)
              (set-char-table-range copy (car entry)
                                    (ebox-text--copy-property-value
                                     (cdr entry) cache)))
            (set-char-table-range copy nil
                                  (ebox-text--copy-property-value default cache))
            (set-char-table-parent copy
                                   (ebox-text--copy-property-value
                                    (char-table-parent value) cache))
            (dotimes (index (or (get (char-table-subtype value)
                                     'char-table-extra-slots) 0))
              (set-char-table-extra-slot
               copy index
               (ebox-text--copy-property-value
                (char-table-extra-slot value index) cache)))
            copy))
         ((vectorp value)
          (let ((copy (copy-sequence value)))
            (puthash value copy cache)
            (dotimes (index (length copy))
              (aset copy index
                    (ebox-text--copy-property-value (aref copy index) cache)))
            copy)))))))

;;;###autoload
(defun ebox-text-property-value-copy (value)
  "Return an owned copy of mutable text-property VALUE."
  (ebox-text--copy-property-value value (make-hash-table :test #'eq)))

;;;###autoload
(defun ebox-text-snapshot (text &optional reuse-property-p)
  "Return an owned copy of TEXT and its mutable text-property values."
  (unless (stringp text)
    (signal 'wrong-type-argument (list 'stringp text)))
  (ebox-text--copy-string text nil reuse-property-p))

(provide 'ebox-text)
;;; ebox-text.el ends here
