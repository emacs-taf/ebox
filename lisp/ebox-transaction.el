;;; ebox-transaction.el --- Structured publication transaction contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Geekinney

;; Author: Geekinney (kinneyzhang666@gmail.com)

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3 of
;; the License, or (at your option) any later version.

;;; Commentary:

;; Bounded framework authority writes for Ebox final acceptance.

;;; Code:

(require 'cl-lib)
(require 'ebox-text)

(define-error 'ebox--pub-transaction-contract-error
  "Invalid Ebox publication transaction contract")
(define-error 'ebox--pub-publication-binding-error
  "Ebox publication artifact binding mismatch"
  'ebox--pub-transaction-contract-error)
(define-error 'ebox--pub-publication-state-error
  "Invalid Ebox publication artifact state transition"
  'ebox--pub-transaction-contract-error)
(define-error 'ebox--pub-final-marker-error
  "Invalid Ebox final-accept marker"
  'ebox--pub-transaction-contract-error)

(defconst ebox--pub--final-marker-max-count 8
  "Maximum number of opaque final markers in one transaction.")

(defconst ebox--pub--final-marker-max-slot-writes 16
  "Maximum total fixed marker slot writes in one transaction.")

(cl-defstruct (ebox--pub--final-marker-operation
               (:constructor ebox--pub--make-final-marker-operation)
               (:copier nil))
  "One trusted operation descriptor resolved before final accept."
  (key nil :read-only t)
  (validate nil :read-only t)
  (apply nil :read-only t)
  (restore nil :read-only t)
  (max-slot-writes nil :read-only t))

(cl-defstruct (ebox--pub-final-marker-expectation
               (:constructor ebox--pub--make-final-marker-expectation)
               (:copier nil))
  "One prebuilt expected scalar stored in a fixed vector slot."
  (target nil :read-only t)
  (index nil :read-only t)
  (value nil :read-only t))

(cl-defstruct (ebox--pub-final-marker-slot-write
               (:constructor ebox--pub--make-final-marker-slot-write)
               (:copier nil))
  "One prebuilt fixed vector slot write."
  (target nil :read-only t)
  (index nil :read-only t)
  (value nil :read-only t))

(defun ebox--pub--final-marker-vector-index-p (target index)
  "Return non-nil when INDEX denotes a writable slot in TARGET."
  (and (vectorp target) (integerp index) (<= 0 index) (< index (length target))))

(cl-defun ebox--pub--final-marker-expectation-create (&key target index value)
  "Create an expectation that TARGET slot INDEX currently equals VALUE."
  (unless (ebox--pub--final-marker-vector-index-p target index)
    (signal 'ebox--pub-final-marker-error (list :expectation target index)))
  (ebox--pub--make-final-marker-expectation
   :target target :index index :value value))

(cl-defun ebox-final-marker-expectation-create (&key target index value)
  "Create a final-marker expectation for TARGET slot INDEX and VALUE."
  (ebox--pub--final-marker-expectation-create
   :target target :index index :value value))

(cl-defun ebox--pub--final-marker-slot-write-create (&key target index value)
  "Create one prebuilt write of VALUE into TARGET slot INDEX."
  (unless (ebox--pub--final-marker-vector-index-p target index)
    (signal 'ebox--pub-final-marker-error (list :slot-write target index)))
  (ebox--pub--make-final-marker-slot-write :target target :index index :value value))

(cl-defun ebox-final-marker-slot-write-create (&key target index value)
  "Create one bounded final-marker write to TARGET slot INDEX with VALUE."
  (ebox--pub--final-marker-slot-write-create
   :target target :index index :value value))

(defun ebox--pub--final-marker-expectation-current-p (expectation)
  "Return non-nil when EXPECTATION matches its current fixed slot."
  (and (ebox--pub-final-marker-expectation-p expectation)
       (equal
        (aref (ebox--pub-final-marker-expectation-target expectation)
              (ebox--pub-final-marker-expectation-index expectation))
        (ebox--pub-final-marker-expectation-value expectation))))

(defun ebox--pub--final-marker-slot-write-shape-p (write)
  "Return non-nil when WRITE still denotes one valid fixed vector slot."
  (and (ebox--pub-final-marker-slot-write-p write)
       (ebox--pub--final-marker-vector-index-p
        (ebox--pub-final-marker-slot-write-target write)
        (ebox--pub-final-marker-slot-write-index write))))

(defun ebox--pub--final-marker-vector-payload-shape-p (marker)
  "Return non-nil when MARKER has exact paired fixed vector slot payloads."
  (let ((next (ebox--pub-final-accept-marker-next-values marker))
        (inverse (ebox--pub-final-accept-marker-inverse-values marker))
        (count (ebox--pub-final-accept-marker-slot-write-count marker))
        seen valid)
    (setq valid
          (and (vectorp next) (vectorp inverse)
               (= (length next) count) (= (length inverse) count)))
    (let ((index 0))
      (while (and valid (< index count))
        (let ((next-write (aref next index))
              (inverse-write (aref inverse index)))
          (setq valid
                (and
                 (ebox--pub--final-marker-slot-write-shape-p next-write)
                 (ebox--pub--final-marker-slot-write-shape-p inverse-write)
                 (eq (ebox--pub-final-marker-slot-write-target next-write)
                     (ebox--pub-final-marker-slot-write-target inverse-write))
                 (= (ebox--pub-final-marker-slot-write-index next-write)
                    (ebox--pub-final-marker-slot-write-index inverse-write))
                 (not
                  (cl-find-if
                   (lambda (entry)
                     (and
                      (eq (car entry)
                          (ebox--pub-final-marker-slot-write-target next-write))
                      (= (cdr entry)
                         (ebox--pub-final-marker-slot-write-index next-write))))
                   seen))))
          (when valid
            (push (cons (ebox--pub-final-marker-slot-write-target next-write)
                        (ebox--pub-final-marker-slot-write-index next-write))
                  seen)))
        (setq index (1+ index))))
    valid))

(defun ebox--pub--final-marker-vector-slots-validate (marker)
  "Validate MARKER expectations and inverse values without changing state."
  (and
   (ebox--pub--final-marker-vector-payload-shape-p marker)
   (ebox--pub--final-marker-expectation-current-p
    (ebox--pub-final-accept-marker-expected-token marker))
   (ebox--pub--final-marker-expectation-current-p
    (ebox--pub-final-accept-marker-expected-version marker))
   (let* ((inverse (ebox--pub-final-accept-marker-inverse-values marker))
          (count (length inverse))
          (index 0)
          (valid t))
     (while (and valid (< index count))
       (let ((write (aref inverse index)))
         (setq valid
               (equal
                (aref (ebox--pub-final-marker-slot-write-target write)
                      (ebox--pub-final-marker-slot-write-index write))
                (ebox--pub-final-marker-slot-write-value write))))
       (setq index (1+ index)))
     valid)))

(defun ebox--pub--final-marker-vector-slots-apply (marker)
  "Apply MARKER's fixed next-value vector slots in order."
  (let* ((writes (ebox--pub-final-accept-marker-next-values marker))
         (count (length writes))
         (index 0))
    (while (< index count)
      (let ((write (aref writes index)))
        (aset (ebox--pub-final-marker-slot-write-target write)
              (ebox--pub-final-marker-slot-write-index write)
              (ebox--pub-final-marker-slot-write-value write)))
      (setq index (1+ index)))))

(defun ebox--pub--final-marker-vector-slots-restore (marker)
  "Restore MARKER's fixed inverse-value vector slots in reverse order."
  (let* ((writes (ebox--pub-final-accept-marker-inverse-values marker))
         (index (1- (length writes))))
    (while (>= index 0)
      (let ((write (aref writes index)))
        (aset (ebox--pub-final-marker-slot-write-target write)
              (ebox--pub-final-marker-slot-write-index write)
              (ebox--pub-final-marker-slot-write-value write)))
      (setq index (1- index)))))

(defconst ebox--pub--final-marker-operation-whitelist
  (list
   (ebox--pub--make-final-marker-operation
    :key 'ebox-vector-slots/v1
    :validate (symbol-function 'ebox--pub--final-marker-vector-slots-validate)
    :apply (symbol-function 'ebox--pub--final-marker-vector-slots-apply)
    :restore (symbol-function 'ebox--pub--final-marker-vector-slots-restore)
    :max-slot-writes ebox--pub--final-marker-max-slot-writes))
  "Closed package-owned final-marker primitive whitelist.")

(defun ebox--pub--final-marker-operation-resolve (key)
  "Return the trusted final marker operation registered for KEY."
  (let ((operation
         (cl-find key ebox--pub--final-marker-operation-whitelist
                  :key #'ebox--pub--final-marker-operation-key :test #'eq)))
    (or operation
        (signal 'ebox--pub-final-marker-error (list :operation-not-whitelisted key)))))

(cl-defstruct (ebox--pub-final-accept-marker
               (:constructor ebox--pub--make-final-accept-marker)
               (:copier nil))
  "One opaque, bounded, one-shot final-accept authority marker."
  (owner-key nil :read-only t)
  (expected-token nil :read-only t)
  (expected-version nil :read-only t)
  (next-values nil :read-only t)
  (inverse-values nil :read-only t)
  (slot-write-count nil :read-only t)
  (operation-key nil :read-only t)
  (operation nil :read-only t)
  state)

(cl-defun ebox--pub--final-accept-marker-create
    (&key owner-key expected-token expected-version next-values inverse-values
          slot-write-count operation-key)
  "Create an OWNER-KEY marker after resolving OPERATION-KEY.  EXPECTED-TOKEN
and EXPECTED-VERSION bind owner state.  NEXT-VALUES and INVERSE-VALUES are
opaque prebuilt payloads with fixed SLOT-WRITE-COUNT."
  (let ((operation (ebox--pub--final-marker-operation-resolve operation-key)))
    (unless (and owner-key
                 (ebox--pub-final-marker-expectation-p expected-token)
                 (ebox--pub-final-marker-expectation-p expected-version)
                 (integerp
                  (ebox--pub-final-marker-expectation-value expected-version))
                 (>= (ebox--pub-final-marker-expectation-value expected-version) 0)
                 (integerp slot-write-count) (> slot-write-count 0)
                 (<= slot-write-count
                     (ebox--pub--final-marker-operation-max-slot-writes operation)))
      (signal 'ebox--pub-final-marker-error
              (list :marker owner-key expected-token expected-version
                    slot-write-count operation-key)))
    (let ((marker
           (ebox--pub--make-final-accept-marker
            :owner-key (ebox-text--copy-property-value owner-key)
            :expected-token expected-token
            :expected-version expected-version
            :next-values (and (vectorp next-values)
                              (copy-sequence next-values))
            :inverse-values (and (vectorp inverse-values)
                                 (copy-sequence inverse-values))
            :slot-write-count slot-write-count
            :operation-key operation-key
            :operation operation
            :state 'prepared)))
      (unless (ebox--pub--final-marker-vector-payload-shape-p marker)
        (signal 'ebox--pub-final-marker-error
                (list :marker-payload owner-key slot-write-count)))
      marker)))

(defun ebox--pub--final-accept-marker-validate (marker)
  "Validate MARKER's expected owner state before the critical section."
  (unless (and (ebox--pub-final-accept-marker-p marker)
               (eq (ebox--pub-final-accept-marker-state marker) 'prepared)
               (funcall
                (ebox--pub--final-marker-operation-validate
                 (ebox--pub-final-accept-marker-operation marker))
                marker))
    (signal 'ebox--pub-final-marker-error
            (list :expected-state
                  (and (ebox--pub-final-accept-marker-p marker)
                       (ebox--pub-final-accept-marker-owner-key marker)))))
  marker)

(provide 'ebox-transaction)
;;; ebox-transaction.el ends here
