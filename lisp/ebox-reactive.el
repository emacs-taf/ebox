;;; ebox-reactive.el --- Exact signals and binding scheduler -*- lexical-binding: t -*-

;; Copyright (C) 2024-2026 Geekinney

;; Author: Geekinney (kinneyzhang666@gmail.com)

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3 of
;; the License, or (at your option) any later version.

;;; Commentary:

;; Ebox display signals, style bindings and atomic publication coordination.

;;; Code:

(require 'cl-lib)

(declare-function ebox--pub--signal "ebox-publication" (condition data &optional trailer))
(require 'ebox-text)
(require 'ebox-transaction)

(define-error 'ebox--pub-reactive-error "Ebox reactive runtime error")
(define-error 'ebox--pub-invalid-signal-scope "Invalid Ebox signal scope"
  'ebox--pub-reactive-error)
(define-error 'ebox--pub-disposed-signal "Ebox signal is disposed" 'ebox--pub-reactive-error)
(define-error 'ebox--pub-disposed-binding "Ebox binding is disposed" 'ebox--pub-reactive-error)
(define-error 'ebox--pub-binding-cycle "Ebox binding dependency cycle"
  'ebox--pub-reactive-error)

(cl-defstruct (ebox--pub-signal (:constructor ebox--pub--make-signal))
  "Reactive source with a committed value and exact subscribers."
  id committed-value equality subscribers scope adapter-key disposed revision)

(cl-defstruct (ebox--pub-binding (:constructor ebox--pub--make-binding))
  "Memoized computation installed on one owner and namespaced key."
  id owner key compute equality last-value initialized-p dependencies
  subscribers dirty state revision lifecycle disposed)

(cl-defstruct (ebox--pub--binding-snapshot
               (:constructor ebox--pub--make-binding-snapshot))
  compute equality last-value initialized-p dependencies dirty state
  revision lifecycle disposed)

(cl-defstruct (ebox--pub--transaction-participant
               (:constructor ebox--pub--make-transaction-participant))
  "One structured transaction participant."
  key rollback protocol order stage precommit after-commit journal state)

(cl-defstruct (ebox--pub--signal-commit-entry
               (:constructor ebox--pub--make-signal-commit-entry))
  "One transaction signal's candidate and exact committed rollback state."
  signal old-committed-value old-revision candidate-value)

(defconst ebox--pub--reactive-absent (make-symbol "ebox--pub-reactive-absent"))

(defvar ebox--pub--signal-id-counter 0)
(defvar ebox--pub--binding-id-counter 0)
(defvar ebox--pub--signals nil)
(defvar ebox--pub--bindings nil)
(defvar ebox--pub--owner-bindings (make-hash-table :test #'eq))

(defvar-local ebox--pub--buffer-signals nil)

(defvar ebox--pub--reactive-counters
  (list :invalidated 0 :recomputed 0 :skipped 0
        :subscription-added 0 :subscription-removed 0))

(defvar ebox--pub--transaction-active nil)
(defvar ebox--pub--prepared-frame-active nil
  "Non-nil while a prepared primitive publication owns the transaction.")

(defun ebox-transaction-active-p ()
  "Return non-nil while the current dynamic extent is in a Ebox transaction."
  (and ebox--pub--transaction-active t))
(defvar ebox--pub--transaction-signal-values nil)
(defvar ebox--pub--transaction-signals nil)
(defvar ebox--pub--transaction-dirty-set nil)
(defvar ebox--pub--transaction-dirty-queue nil)
(defvar ebox--pub--transaction-binding-snapshots nil)
(defvar ebox--pub--transaction-created-bindings nil)
(defvar ebox--pub--transaction-recompute-counts nil)
(defvar ebox--pub--transaction-extensions nil)
(defvar ebox--pub--transaction-counter-start nil)
(defvar ebox--pub--transaction-after-commit-callbacks nil)
(defvar ebox--pub--transaction-participants nil)
(defvar ebox--pub--transaction-participant-keys nil)
(defvar ebox--pub--transaction-participant-order 0)
(defvar ebox--pub--transaction-published-participants nil)
(defvar ebox--pub--transaction-signal-commit-journal nil)
(defvar ebox--pub--transaction-phase nil)
(defvar ebox--pub--publication-started-p nil)
(defvar ebox--pub--transaction-structured-participants nil)
(defvar ebox--pub--transaction-final-marker-registry nil)
(defvar ebox--pub--transaction-final-marker-owner-keys nil)
(defvar ebox--pub--transaction-final-marker-count 0)
(defvar ebox--pub--transaction-final-marker-slot-writes 0)
(defvar ebox--pub--transaction-final-markers-frozen-p nil)
(defvar ebox--pub--transaction-applied-final-marker-count 0)
(defvar ebox--pub--transaction-marker-restore-failures nil)
(defvar ebox--pub--transaction-contained-failures nil)
(defvar ebox--pub--last-transaction-diagnostics nil)
(defvar ebox--pub--current-binding nil)
(defvar ebox--pub--binding-compute-stack nil)
(defvar ebox--pub--collected-dependency-set nil)
(defvar ebox--pub--collected-dependencies nil)
(defvar ebox--pub--binding-touch-function nil)
(defvar ebox--pub--binding-changed-functions nil)
(defvar ebox--pub--transaction-publish-functions nil)
(defvar ebox--pub--transaction-precommit-functions nil
  "Internal Ebox-owned precommit hook symbols in deterministic order.")
(defconst ebox--pub--transaction-precommit-allowed-functions
  '(ebox--pub--surface-precommit-transaction)
  "Exact Ebox-owned symbols allowed in the internal precommit registry.")
(defvar ebox--pub--transaction-final-accept-function
  #'ebox--pub--transaction-noop-final-accept
  "Internal single final-accept function for the active transaction.")
(defvar ebox--pub--transaction-rollback-functions nil)
(defvar ebox--pub--transaction-rollback-final-functions nil)
(defvar ebox--pub--transaction-committed-functions nil)

(defvar ebox--pub--transaction-participant-precommit-allowed-functions nil
  "Declared internal structured-participant precommit validators.")

(defconst ebox--pub--transaction-condition-trailer-tag
  (make-symbol "ebox--pub--transaction-condition-trailer")
  "Unforgeable tag separating primary condition data from Ebox metadata.")

(defun ebox--pub--counter-increment (key)
  "Increment reactive counter KEY."
  (setq ebox--pub--reactive-counters
        (plist-put ebox--pub--reactive-counters key
                   (1+ (plist-get ebox--pub--reactive-counters key)))))

(defun ebox--pub--dependency-subscribers (dependency)
  "Return the subscriber table owned by DEPENDENCY."
  (cond ((ebox--pub-signal-p dependency) (ebox--pub-signal-subscribers dependency))
        ((ebox--pub-binding-p dependency) (ebox--pub-binding-subscribers dependency))
        (t (signal 'wrong-type-argument
                   (list '(or ebox--pub-signal-p ebox--pub-binding-p) dependency)))))

(defun ebox--pub--subscription-add (dependency binding)
  "Subscribe BINDING to DEPENDENCY."
  (let ((subscribers (ebox--pub--dependency-subscribers dependency)))
    (unless (gethash binding subscribers)
      (puthash binding t subscribers)
      (ebox--pub--counter-increment :subscription-added))))

(defun ebox--pub--subscription-remove (dependency binding)
  "Unsubscribe BINDING from DEPENDENCY."
  (let ((subscribers (ebox--pub--dependency-subscribers dependency)))
    (when (gethash binding subscribers)
      (remhash binding subscribers)
      (ebox--pub--counter-increment :subscription-removed))))

(defun ebox--pub--sorted-subscribers (dependency)
  "Return DEPENDENCY subscribers ordered by stable binding id."
  (let (bindings)
    (maphash (lambda (binding _present) (push binding bindings))
             (ebox--pub--dependency-subscribers dependency))
    (sort bindings (lambda (left right)
                     (< (ebox--pub-binding-id left) (ebox--pub-binding-id right))))))

(defun ebox--pub--binding-snapshot (binding)
  "Return a rollback snapshot of BINDING."
  (ebox--pub--make-binding-snapshot
   :compute (ebox--pub-binding-compute binding)
   :equality (ebox--pub-binding-equality binding)
   :last-value (ebox--pub-binding-last-value binding)
   :initialized-p (ebox--pub-binding-initialized-p binding)
   :dependencies (copy-sequence (ebox--pub-binding-dependencies binding))
   :dirty (ebox--pub-binding-dirty binding)
   :state (ebox--pub-binding-state binding)
   :revision (ebox--pub-binding-revision binding)
   :lifecycle (ebox--pub-binding-lifecycle binding)
   :disposed (ebox--pub-binding-disposed binding)))

(defun ebox--pub--snapshot-binding (binding)
  "Save BINDING once for the active transaction."
  (when (and ebox--pub--transaction-active
             (not (memq binding ebox--pub--transaction-created-bindings))
             (not (gethash binding ebox--pub--transaction-binding-snapshots)))
    (puthash binding (ebox--pub--binding-snapshot binding)
             ebox--pub--transaction-binding-snapshots)))

(defun ebox--pub--owner-binding-table (owner &optional create)
  "Return OWNER's binding table, creating it when CREATE is non-nil."
  (or (gethash owner ebox--pub--owner-bindings)
      (when create
        (let ((table (make-hash-table :test #'equal)))
          (puthash owner table ebox--pub--owner-bindings)
          table))))

(defun ebox--pub--register-binding (binding)
  "Register BINDING under its owner and key."
  (puthash (ebox--pub-binding-key binding) binding
           (ebox--pub--owner-binding-table (ebox--pub-binding-owner binding) t))
  (cl-pushnew binding ebox--pub--bindings :test #'eq))

(defun ebox--pub--unregister-binding (binding)
  "Remove BINDING from owner and global registries."
  (when-let* ((table (ebox--pub--owner-binding-table (ebox--pub-binding-owner binding))))
    (remhash (ebox--pub-binding-key binding) table)
    (when (zerop (hash-table-count table))
      (remhash (ebox--pub-binding-owner binding) ebox--pub--owner-bindings)))
  (setq ebox--pub--bindings (delq binding ebox--pub--bindings)))

(defun ebox--pub--enqueue-binding (binding)
  "Add dirty BINDING to the current transaction queue once."
  (unless (gethash binding ebox--pub--transaction-dirty-set)
    (puthash binding t ebox--pub--transaction-dirty-set)
    (push binding ebox--pub--transaction-dirty-queue)))

(defun ebox--pub--mark-binding-dirty (binding)
  "Mark live BINDING dirty in the current transaction."
  (when (and (ebox--pub-binding-p binding) (not (ebox--pub-binding-disposed binding)))
    (ebox--pub--snapshot-binding binding)
    (unless (ebox--pub-binding-dirty binding)
      (setf (ebox--pub-binding-dirty binding) t)
      (ebox--pub--counter-increment :invalidated))
    (ebox--pub--enqueue-binding binding)))

(defun ebox--pub--invalidate-subscribers (dependency &optional skip)
  "Dirty DEPENDENCY subscribers except SKIP."
  (dolist (binding (ebox--pub--sorted-subscribers dependency))
    (unless (eq binding skip)
      (ebox--pub--mark-binding-dirty binding))))

(defun ebox--pub--record-dependency (dependency)
  "Record DEPENDENCY for the binding currently being computed."
  (when ebox--pub--current-binding
    (unless (gethash dependency ebox--pub--collected-dependency-set)
      (puthash dependency t ebox--pub--collected-dependency-set)
      (push dependency ebox--pub--collected-dependencies))))

(defun ebox--pub--signal-value-in-transaction (signal)
  "Return SIGNAL's candidate or committed value."
  (if ebox--pub--transaction-active
      (let ((candidate (gethash signal ebox--pub--transaction-signal-values
                                ebox--pub--reactive-absent)))
        (if (eq candidate ebox--pub--reactive-absent)
            (ebox--pub-signal-committed-value signal)
          candidate))
    (ebox--pub-signal-committed-value signal)))

(defun ebox--pub--validate-live-signal (signal)
  "Signal an error unless SIGNAL is live."
  (unless (ebox--pub-signal-p signal)
    (signal 'wrong-type-argument (list 'ebox--pub-signal-p signal)))
  (when (ebox--pub-signal-disposed signal)
    (signal 'ebox--pub-disposed-signal (list (ebox--pub-signal-id signal)))))

(defun ebox--pub-signal-live-p (signal)
  "Return non-nil when SIGNAL is a live Ebox signal."
  (and (ebox--pub-signal-p signal) (not (ebox--pub-signal-disposed signal))))

(defun ebox--pub--buffer-signal-kill ()
  "Dispose signals scoped to the buffer being killed."
  (let ((signals ebox--pub--buffer-signals))
    (setq ebox--pub--buffer-signals nil)
    (dolist (signal signals)
      (ebox--pub--dispose-signal signal))))

(cl-defun ebox--pub-signal-create (initial-value &key (equality #'equal) (scope 'global))
  "Create a signal holding INITIAL-VALUE.  EQUALITY compares writes.  SCOPE is
`global' or a live buffer."
  (unless (functionp equality)
    (signal 'wrong-type-argument (list 'functionp equality)))
  (unless (or (eq scope 'global) (buffer-live-p scope))
    (signal 'ebox--pub-invalid-signal-scope (list scope)))
  (let ((signal (ebox--pub--make-signal
                 :id (cl-incf ebox--pub--signal-id-counter)
                 :committed-value initial-value :equality equality
                 :subscribers (make-hash-table :test #'eq)
                 :scope scope :revision 0)))
    (push signal ebox--pub--signals)
    (when (bufferp scope)
      (with-current-buffer scope
        (push signal ebox--pub--buffer-signals)
        (add-hook 'kill-buffer-hook #'ebox--pub--buffer-signal-kill nil t)))
    signal))

(defun ebox--pub-signal-peek (signal)
  "Return SIGNAL's effective value without collecting a dependency."
  (ebox--pub--validate-live-signal signal)
  (ebox--pub--signal-value-in-transaction signal))

(defun ebox--pub-signal-read (signal)
  "Read SIGNAL and register the current binding as a subscriber."
  (ebox--pub--validate-live-signal signal)
  (ebox--pub--record-dependency signal)
  (ebox--pub--signal-value-in-transaction signal))

(defun ebox--pub--set-signal-candidate (signal value)
  "Set candidate VALUE for SIGNAL in the active transaction."
  (let ((old (ebox--pub--signal-value-in-transaction signal)))
    (unless (funcall (ebox--pub-signal-equality signal) old value)
      (when (eq (gethash signal ebox--pub--transaction-signal-values
                         ebox--pub--reactive-absent)
                ebox--pub--reactive-absent)
        (push signal ebox--pub--transaction-signals))
      (puthash signal value ebox--pub--transaction-signal-values)
      (ebox--pub--invalidate-subscribers signal)
      (when (and ebox--pub--current-binding
                 (gethash signal ebox--pub--collected-dependency-set))
        (ebox--pub--mark-binding-dirty ebox--pub--current-binding))))
  value)

(defun ebox--pub-signal-set (signal value)
  "Set SIGNAL to VALUE transactionally and return VALUE."
  (ebox--pub--validate-live-signal signal)
  (if ebox--pub--transaction-active
      (ebox--pub--set-signal-candidate signal value)
    (ebox--pub--call-with-transaction
     (lambda () (ebox--pub--set-signal-candidate signal value)))))

(defun ebox--pub--binding-dependency-path (start target visited)
  "Return a binding path from START to TARGET, avoiding VISITED."
  (cond
   ((eq start target) (list target))
   ((memq start visited) nil)
   (t
    (cl-loop for dependency in (ebox--pub-binding-dependencies start)
             when (ebox--pub-binding-p dependency)
             for path = (ebox--pub--binding-dependency-path
                         dependency target (cons start visited))
             when path return (cons start path)))))

(defun ebox--pub--stack-cycle-path (target)
  "Return the active compute-stack cycle ending at TARGET."
  (let ((path (reverse ebox--pub--binding-compute-stack)))
    (while (and path (not (eq (car path) target)))
      (setq path (cdr path)))
    (append path (list target))))

(defun ebox--pub--signal-binding-cycle (path)
  "Signal a binding-cycle error for binding PATH."
  (signal 'ebox--pub-binding-cycle
          (list (mapcar (lambda (binding)
                          (ebox-text--copy-property-value
                           (ebox--pub-binding-key binding)))
                        path))))

(defun ebox--pub--validate-binding-read (binding &optional computing-only)
  "Validate reading BINDING from the current computation.  When COMPUTING-ONLY
is non-nil, defer old-graph traversal until after a dirty target has
recomputed."
  (when ebox--pub--current-binding
    (when (eq (ebox--pub-binding-state binding) 'computing)
      (ebox--pub--signal-binding-cycle (ebox--pub--stack-cycle-path binding)))
    (unless computing-only
      (when-let* ((path (ebox--pub--binding-dependency-path
                        binding ebox--pub--current-binding nil)))
        (ebox--pub--signal-binding-cycle (cons ebox--pub--current-binding path))))))

(defun ebox--pub--replace-binding-dependencies (binding dependencies)
  "Replace BINDING dependencies with DEPENDENCIES."
  (let ((old (ebox--pub-binding-dependencies binding)))
    (dolist (dependency old)
      (unless (memq dependency dependencies)
        (ebox--pub--subscription-remove dependency binding)))
    (dolist (dependency dependencies)
      (unless (memq dependency old)
        (ebox--pub--subscription-add dependency binding)))
    (setf (ebox--pub-binding-dependencies binding) dependencies)))

(defun ebox--pub--note-binding-recompute (binding)
  "Record one recomputation of BINDING and reject runaway feedback."
  (let ((count (1+ (gethash binding ebox--pub--transaction-recompute-counts 0))))
    (puthash binding count ebox--pub--transaction-recompute-counts)
    (when (> count 100)
      (ebox--pub--signal-binding-cycle (list binding binding)))))

(defun ebox--pub--binding-recompute (binding)
  "Recompute dirty BINDING inside the active transaction."
  (ebox--pub--snapshot-binding binding)
  (ebox--pub--note-binding-recompute binding)
  (let ((requester ebox--pub--current-binding)
        (old (ebox--pub-binding-last-value binding))
        (initialized (ebox--pub-binding-initialized-p binding))
        (ebox--pub--current-binding binding)
        (ebox--pub--binding-compute-stack (cons binding ebox--pub--binding-compute-stack))
        (ebox--pub--collected-dependency-set (make-hash-table :test #'eq))
        (ebox--pub--collected-dependencies nil))
    (setf (ebox--pub-binding-state binding) 'computing
          (ebox--pub-binding-dirty binding) nil)
    (let* ((value (funcall (ebox--pub-binding-compute binding)))
           (dependencies (nreverse ebox--pub--collected-dependencies))
           (changed (or (not initialized)
                        (not (funcall (ebox--pub-binding-equality binding)
                                      old value)))))
      (ebox--pub--replace-binding-dependencies binding dependencies)
      (setf (ebox--pub-binding-state binding) 'clean)
      (ebox--pub--counter-increment :recomputed)
      (if changed
          (progn
            (setf (ebox--pub-binding-last-value binding) value
                  (ebox--pub-binding-initialized-p binding) t
                  (ebox--pub-binding-revision binding)
                  (1+ (ebox--pub-binding-revision binding)))
            (run-hook-with-args 'ebox--pub--binding-changed-functions
                                binding old value)
            (ebox--pub--invalidate-subscribers binding requester))
        (ebox--pub--counter-increment :skipped))
      value)))

(defun ebox--pub--validate-live-binding (binding)
  "Signal an error unless BINDING is live."
  (unless (ebox--pub-binding-p binding)
    (signal 'wrong-type-argument (list 'ebox--pub-binding-p binding)))
  (when (ebox--pub-binding-disposed binding)
    (signal 'ebox--pub-disposed-binding (list (ebox--pub-binding-id binding)))))

(defun ebox--pub-binding-live-p (binding)
  "Return non-nil when BINDING is a live Ebox binding."
  (and (ebox--pub-binding-p binding) (not (ebox--pub-binding-disposed binding))))

(defun ebox--pub-binding-read (binding)
  "Read BINDING's memoized value and collect a dependency."
  (ebox--pub--validate-live-binding binding)
  (ebox--pub--validate-binding-read binding t)
  (when (ebox--pub-binding-dirty binding)
    (if ebox--pub--transaction-active
        (ebox--pub--binding-recompute binding)
      (ebox--pub--call-with-transaction (lambda () (ebox--pub--binding-recompute binding)))))
  (ebox--pub--validate-binding-read binding)
  (ebox--pub--record-dependency binding)
  (ebox--pub-binding-last-value binding))

(defun ebox--pub-binding-dependency-count (binding)
  "Return BINDING's current direct dependency count.  Disposed bindings return
zero."
  (unless (ebox--pub-binding-p binding)
    (signal 'wrong-type-argument (list 'ebox--pub-binding-p binding)))
  (length (ebox--pub-binding-dependencies binding)))

(defun ebox--pub--validate-binding-options (compute equality lifecycle)
  "Validate binding COMPUTE, EQUALITY, and LIFECYCLE."
  (unless (functionp compute)
    (signal 'wrong-type-argument (list 'functionp compute)))
  (unless (functionp equality)
    (signal 'wrong-type-argument (list 'functionp equality)))
  (unless (memq lifecycle '(delete retain))
    (signal 'ebox--pub-reactive-error (list :lifecycle lifecycle))))

(defun ebox--pub--bind-in-transaction (owner key compute equality lifecycle)
  "Install COMPUTE for OWNER and KEY in the active transaction.  EQUALITY
compares values and LIFECYCLE controls retention."
  (let* ((table (ebox--pub--owner-binding-table owner t))
         (binding (gethash key table)))
    (if binding
        (unless (and (eq compute (ebox--pub-binding-compute binding))
                     (eq equality (ebox--pub-binding-equality binding))
                     (eq lifecycle (ebox--pub-binding-lifecycle binding)))
          (ebox--pub--snapshot-binding binding)
          (setf (ebox--pub-binding-compute binding) compute
                (ebox--pub-binding-equality binding) equality
                (ebox--pub-binding-lifecycle binding) lifecycle)
          (ebox--pub--mark-binding-dirty binding))
      (setq binding
            (ebox--pub--make-binding
             :id (cl-incf ebox--pub--binding-id-counter)
             :owner owner :key (ebox-text--copy-property-value key) :compute compute
             :equality equality :subscribers (make-hash-table :test #'eq)
             :dirty t :state 'clean :revision 0 :lifecycle lifecycle))
      (ebox--pub--register-binding binding)
      (push binding ebox--pub--transaction-created-bindings)
      (ebox--pub--enqueue-binding binding))
    (when ebox--pub--binding-touch-function
      (funcall ebox--pub--binding-touch-function binding))
    binding))

(cl-defun ebox--pub-bind (owner key compute &key (equality #'equal) (lifecycle 'delete))
  "Idempotently install COMPUTE on OWNER under namespaced KEY.  EQUALITY
suppresses unchanged downstream updates.  LIFECYCLE is `delete' or `retain'."
  (when (null owner)
    (signal 'ebox--pub-reactive-error (list :owner owner)))
  (when (null key)
    (signal 'ebox--pub-reactive-error (list :binding-key key)))
  (ebox--pub--validate-binding-options compute equality lifecycle)
  (if ebox--pub--transaction-active
      (ebox--pub--bind-in-transaction owner key compute equality lifecycle)
    (ebox--pub--call-with-transaction
     (lambda () (ebox--pub--bind-in-transaction
                 owner key compute equality lifecycle)))))

(defun ebox--pub--bind-precomputed-in-transaction
    (owner key compute value dependencies equality lifecycle)
  "Install OWNER's KEY using COMPUTE, VALUE, and explicit DEPENDENCIES.
EQUALITY controls change detection and LIFECYCLE controls candidate
omission."
  (let ((table (ebox--pub--owner-binding-table owner t)))
    (when (gethash key table)
      (signal 'ebox--pub-reactive-error (list :precomputed-binding-exists key)))
    (dolist (dependency dependencies)
      (cond ((ebox--pub-signal-p dependency) (ebox--pub--validate-live-signal dependency))
            ((ebox--pub-binding-p dependency) (ebox--pub--validate-live-binding dependency))
            (t (signal 'wrong-type-argument
                       (list '(or ebox--pub-signal-p ebox--pub-binding-p) dependency)))))
    (let ((binding
           (ebox--pub--make-binding
            :id (cl-incf ebox--pub--binding-id-counter)
            :owner owner :key (ebox-text--copy-property-value key) :compute compute
            :equality equality :last-value value :initialized-p t
            :dependencies (copy-sequence dependencies)
            :subscribers (make-hash-table :test #'eq)
            :dirty nil :state 'clean :revision 1 :lifecycle lifecycle)))
      (ebox--pub--register-binding binding)
      (push binding ebox--pub--transaction-created-bindings)
      (dolist (dependency dependencies)
        (ebox--pub--subscription-add dependency binding))
      (when ebox--pub--binding-touch-function
        (funcall ebox--pub--binding-touch-function binding))
      binding)))

(cl-defun ebox--pub-bind-precomputed
    (owner key compute value dependencies
           &key (equality #'equal) (lifecycle 'delete))
  "Install a new binding with precomputed VALUE and explicit DEPENDENCIES.
OWNER and KEY identify the binding; EQUALITY and LIFECYCLE retain their
normal `ebox--pub-bind' meanings.  COMPUTE remains the authoritative
recomputation function after any dependency changes.  This entry avoids
evaluating COMPUTE merely to rediscover a value and graph edges already
produced by a compiler or pure projection pass."
  (when (null owner)
    (signal 'ebox--pub-reactive-error (list :owner owner)))
  (when (null key)
    (signal 'ebox--pub-reactive-error (list :binding-key key)))
  (ebox--pub--validate-binding-options compute equality lifecycle)
  (unless (proper-list-p dependencies)
    (signal 'wrong-type-argument (list 'proper-list-p dependencies)))
  (if ebox--pub--transaction-active
      (ebox--pub--bind-precomputed-in-transaction
       owner key compute value dependencies equality lifecycle)
    (ebox--pub--call-with-transaction
     (lambda ()
       (ebox--pub--bind-precomputed-in-transaction
        owner key compute value dependencies equality lifecycle)))))

(defun ebox--pub--detach-binding-dependencies (binding)
  "Remove BINDING from all dependency subscriber tables."
  (dolist (dependency (ebox--pub-binding-dependencies binding))
    (ebox--pub--subscription-remove dependency binding))
  (setf (ebox--pub-binding-dependencies binding) nil))

(defun ebox--pub--detach-binding-subscribers (binding)
  "Detach every direct subscriber from BINDING."
  (dolist (subscriber (ebox--pub--sorted-subscribers binding))
    (ebox--pub--snapshot-binding subscriber)
    (setf (ebox--pub-binding-dependencies subscriber)
          (delq binding (ebox--pub-binding-dependencies subscriber))
          (ebox--pub-binding-dirty subscriber) t)
    (ebox--pub--subscription-remove binding subscriber)))

(defun ebox--pub--dispose-binding (binding)
  "Dispose live BINDING without starting a transaction."
  (unless (ebox--pub-binding-disposed binding)
    (ebox--pub--snapshot-binding binding)
    (ebox--pub--detach-binding-dependencies binding)
    (ebox--pub--detach-binding-subscribers binding)
    (ebox--pub--unregister-binding binding)
    (setf (ebox--pub-binding-disposed binding) t
          (ebox--pub-binding-dirty binding) nil
          (ebox--pub-binding-state binding) 'disposed)))

(defun ebox--pub-binding-dispose-owner (owner)
  "Dispose every binding installed on OWNER and return the count."
  (let ((bindings (when-let* ((table (ebox--pub--owner-binding-table owner)))
                    (let (items)
                      (maphash (lambda (_key binding) (push binding items)) table)
                      (sort items (lambda (left right)
                                    (< (ebox--pub-binding-id left)
                                       (ebox--pub-binding-id right))))))))
    (if ebox--pub--transaction-active
        (dolist (binding bindings) (ebox--pub--dispose-binding binding))
      (ebox--pub--call-with-transaction
       (lambda () (dolist (binding bindings) (ebox--pub--dispose-binding binding)))))
    (length bindings)))

(defun ebox--pub-binding-owner-bindings (owner)
  "Return OWNER's live bindings ordered by stable binding id."
  (when-let* ((table (ebox--pub--owner-binding-table owner)))
    (let (bindings)
      (maphash (lambda (_key binding) (push binding bindings)) table)
      (sort bindings (lambda (left right)
                       (< (ebox--pub-binding-id left) (ebox--pub-binding-id right)))))))

(defun ebox--pub-binding-dispose (binding)
  "Dispose BINDING and detach all of its graph edges."
  (ebox--pub--validate-live-binding binding)
  (if ebox--pub--transaction-active
      (ebox--pub--dispose-binding binding)
    (ebox--pub--call-with-transaction (lambda () (ebox--pub--dispose-binding binding))))
  nil)

(defun ebox--pub--transaction-extension (key &optional create)
  "Return transaction extension state for KEY.  When CREATE is non-nil, install
and return a fresh hash table when absent."
  (unless ebox--pub--transaction-active
    (signal 'ebox--pub-reactive-error (list :outside-transaction key)))
  (or (gethash key ebox--pub--transaction-extensions)
      (when create
        (let ((state (make-hash-table :test #'eq)))
          (puthash key state ebox--pub--transaction-extensions)
          state))))

(defun ebox--pub--transaction-counter-delta (key)
  "Return active transaction counter delta for KEY."
  (if ebox--pub--transaction-counter-start
      (- (plist-get ebox--pub--reactive-counters key)
         (plist-get ebox--pub--transaction-counter-start key))
    0))

(defun ebox--pub--enqueue-after-commit (function)
  "Run FUNCTION after the active outer transaction has exited."
  (unless ebox--pub--transaction-active
    (signal 'ebox--pub-reactive-error (list :outside-transaction function)))
  (push function ebox--pub--transaction-after-commit-callbacks))

(defun ebox--pub--transaction-participant-precommit-function-p (function)
  "Return non-nil when FUNCTION is a declared internal participant validator."
  (or (null function)
      (and (symbolp function)
           (memq function
                 ebox--pub--transaction-participant-precommit-allowed-functions)
           (fboundp function))))

(defun ebox--pub--transaction-register-participant (participant)
  "Register structured PARTICIPANT once in the active transaction."
  (unless ebox--pub--transaction-active
    (signal 'ebox--pub-reactive-error
            (list :participant-outside-transaction
                  (ebox--pub--transaction-participant-key participant))))
  (let ((key (ebox--pub--transaction-participant-key participant)))
    (unless key
      (signal 'ebox--pub-reactive-error (list :participant-key key)))
  (when (member key ebox--pub--transaction-participant-keys)
    (signal 'ebox--pub-reactive-error (list :duplicate-participant-key key)))
    (push (ebox-text--copy-property-value key) ebox--pub--transaction-participant-keys)
    (push participant ebox--pub--transaction-participants)
    participant))

(defun ebox--pub--transaction-make-participant
    (key stage rollback protocol precommit after-commit journal)
  "Build a participant from KEY, STAGE, ROLLBACK, and PROTOCOL.  PRECOMMIT and
AFTER-COMMIT are optional internal callbacks; JOURNAL is opaque owner-local
rollback state."
  (unless (functionp stage)
    (signal 'wrong-type-argument (list 'functionp stage)))
  (unless (functionp rollback)
    (signal 'wrong-type-argument (list 'functionp rollback)))
  (unless (ebox--pub--transaction-participant-precommit-function-p precommit)
    (signal 'ebox--pub-reactive-error
            (list :invalid-participant-precommit precommit)))
  (unless (or (null after-commit) (functionp after-commit))
    (signal 'wrong-type-argument (list 'functionp after-commit)))
  (ebox--pub--make-transaction-participant
   :key (ebox-text--copy-property-value key)
   :rollback rollback
   :protocol protocol
   :order (prog1 ebox--pub--transaction-participant-order
            (cl-incf ebox--pub--transaction-participant-order))
   :stage stage
   :precommit precommit
   :after-commit after-commit
   :journal journal
   :state 'prepared))

(cl-defun ebox--pub--transaction-participate-v2
    (&key key stage rollback precommit after-commit journal)
  "Register internal KEY with structured STAGE and ROLLBACK capabilities.
PRECOMMIT and AFTER-COMMIT are optional declared callbacks.  JOURNAL is the
participant's opaque owner-local state."
  (unless ebox--pub--transaction-active
    (signal 'ebox--pub-reactive-error (list :participant-outside-transaction key)))
  (unless key
    (signal 'ebox--pub-reactive-error (list :participant-key key)))
  (ebox--pub--transaction-register-participant
   (ebox--pub--transaction-make-participant
    key stage rollback 'v2 precommit after-commit journal)))

(cl-defun ebox-transaction-participate
    (&key key stage rollback precommit after-commit journal)
  "Register a structured rollback-capable participant under KEY.  STAGE and
ROLLBACK are required no-argument functions.  PRECOMMIT may be one declared
package-owned validator; AFTER-COMMIT is contained work queued only after
final accept.  JOURNAL is opaque owner-local rollback state.  Return KEY
without exposing Ebox's internal participant object."
  (ebox--pub--transaction-participate-v2
   :key key :stage stage :rollback rollback :precommit precommit
   :after-commit after-commit :journal journal)
  key)

(defun ebox--pub--transaction-participants-in-registration-order ()
  "Return the authoritative participants in deterministic declaration order."
  (reverse ebox--pub--transaction-participants))

(defun ebox--pub--transaction-validate-structured-participants ()
  "Return the frozen participant vector after exact identity validation."
  (let* ((participants ebox--pub--transaction-structured-participants)
         (registered (ebox--pub--transaction-participants-in-registration-order))
         (count (length registered)))
    (unless (and (vectorp participants) (= (length participants) count))
      (signal 'ebox--pub-publication-binding-error
              (list :participant-count participants registered)))
    (cl-loop for participant in registered
             for index from 0
             unless (eq participant (aref participants index))
             do (signal 'ebox--pub-publication-binding-error
                        (list :participant-order index participant
                              (aref participants index))))
    participants))

(defun ebox--pub--stage-structured-transaction-participants ()
  "Stage the frozen structured participant vector in declaration order."
  (let ((participants (ebox--pub--transaction-validate-structured-participants)))
    (dotimes (index (length participants))
      (let ((participant (aref participants index)))
        (push participant ebox--pub--transaction-published-participants)
        (setf (ebox--pub--transaction-participant-state participant) 'staged)
        (funcall (ebox--pub--transaction-participant-stage participant))))))

(defun ebox--pub--rollback-transaction-participants ()
  "Rollback published participants and return any failures."
  (let (failures)
    (dolist (participant ebox--pub--transaction-published-participants)
      (unwind-protect
          (condition-case failure
              (funcall (ebox--pub--transaction-participant-rollback participant))
            ((error quit)
             (push (list 'participants
                         (ebox--pub--transaction-participant-key participant)
                         failure)
                   failures)))
        (setf (ebox--pub--transaction-participant-state participant) 'rolled-back)))
    (dolist (participant ebox--pub--transaction-participants)
      (when (eq (ebox--pub--transaction-participant-state participant) 'prepared)
        (setf (ebox--pub--transaction-participant-state participant) 'rolled-back)))
    (nreverse failures)))

(defun ebox--pub--run-structured-transaction-participant-precommits ()
  "Run validators from the frozen structured participant vector."
  (let ((participants (ebox--pub--transaction-validate-structured-participants)))
    (dotimes (index (length participants))
      (when-let* ((function
                   (ebox--pub--transaction-participant-precommit
                    (aref participants index))))
        (unless (ebox--pub--transaction-participant-precommit-function-p function)
          (signal 'ebox--pub-reactive-error
                  (list :invalid-participant-precommit function)))
        (funcall function)))))

(defun ebox--pub--commit-structured-transaction-participants ()
  "Commit states from the frozen structured participant vector."
  (let ((participants (ebox--pub--transaction-validate-structured-participants)))
    (dotimes (index (length participants))
      (let ((participant (aref participants index)))
        (when (eq (ebox--pub--transaction-participant-state participant) 'staged)
          (setf (ebox--pub--transaction-participant-state participant) 'committed)
          (when-let* ((function
                       (ebox--pub--transaction-participant-after-commit participant)))
            (ebox--pub--enqueue-after-commit function)))))))

(defun ebox--pub--dequeue-dirty-binding ()
  "Return and remove the next queued dirty binding."
  (let (binding)
    (while (and ebox--pub--transaction-dirty-queue (null binding))
      (let ((candidate (pop ebox--pub--transaction-dirty-queue)))
        (when (gethash candidate ebox--pub--transaction-dirty-set)
          (remhash candidate ebox--pub--transaction-dirty-set)
          (setq binding candidate))))
    binding))

(defun ebox--pub--flush-dirty-bindings ()
  "Recompute the transaction's exact dirty closure."
  (let (binding)
    (while (setq binding (ebox--pub--dequeue-dirty-binding))
      (when (and (ebox--pub-binding-live-p binding) (ebox--pub-binding-dirty binding))
        (ebox--pub--binding-recompute binding)))))

(defun ebox--pub--restore-binding (binding snapshot)
  "Restore BINDING fields from SNAPSHOT."
  (setf (ebox--pub-binding-compute binding) (ebox--pub--binding-snapshot-compute snapshot)
        (ebox--pub-binding-equality binding) (ebox--pub--binding-snapshot-equality snapshot)
        (ebox--pub-binding-last-value binding) (ebox--pub--binding-snapshot-last-value snapshot)
        (ebox--pub-binding-initialized-p binding)
        (ebox--pub--binding-snapshot-initialized-p snapshot)
        (ebox--pub-binding-dependencies binding)
        (copy-sequence (ebox--pub--binding-snapshot-dependencies snapshot))
        (ebox--pub-binding-dirty binding) (ebox--pub--binding-snapshot-dirty snapshot)
        (ebox--pub-binding-state binding) (ebox--pub--binding-snapshot-state snapshot)
        (ebox--pub-binding-revision binding) (ebox--pub--binding-snapshot-revision snapshot)
        (ebox--pub-binding-lifecycle binding) (ebox--pub--binding-snapshot-lifecycle snapshot)
        (ebox--pub-binding-disposed binding) (ebox--pub--binding-snapshot-disposed snapshot)))

(defun ebox--pub--rollback-bindings ()
  "Restore all bindings touched by the active transaction."
  (let (snapshots)
    (maphash (lambda (binding snapshot)
               (push (cons binding snapshot) snapshots))
             ebox--pub--transaction-binding-snapshots)
    (dolist (binding (append ebox--pub--transaction-created-bindings
                             (mapcar #'car snapshots)))
      (ebox--pub--detach-binding-dependencies binding))
    (dolist (binding ebox--pub--transaction-created-bindings)
      (ebox--pub--unregister-binding binding)
      (setf (ebox--pub-binding-disposed binding) t
            (ebox--pub-binding-state binding) 'disposed))
    (dolist (entry snapshots)
      (pcase-let ((`(,binding . ,snapshot) entry))
        (ebox--pub--restore-binding binding snapshot)
        (unless (ebox--pub-binding-disposed binding)
          (ebox--pub--register-binding binding)
          (dolist (dependency (ebox--pub-binding-dependencies binding))
            (ebox--pub--subscription-add dependency binding)))))))

(defun ebox--pub--transaction-noop-final-accept ()
  "Accept a pure reactive transaction with no external publication work."
  nil)

(defun ebox--pub--transaction-precommit-function-p (function)
  "Return non-nil when FUNCTION is a declared Ebox-internal hook symbol."
  (and (symbolp function)
       (memq function ebox--pub--transaction-precommit-allowed-functions)
       (fboundp function)))

(defun ebox--pub--transaction-register-precommit-function (function)
  "Register declared Ebox-internal precommit FUNCTION once."
  (unless (ebox--pub--transaction-precommit-function-p function)
    (signal 'ebox--pub-reactive-error
            (list :invalid-precommit-function function)))
  (unless (memq function ebox--pub--transaction-precommit-functions)
    (setq ebox--pub--transaction-precommit-functions
          (append ebox--pub--transaction-precommit-functions (list function))))
  function)

(defun ebox--pub--transaction-install-final-accept (function)
  "Install the active transaction's single final-accept FUNCTION."
  (unless ebox--pub--transaction-active
    (signal 'ebox--pub-reactive-error (list :final-accept-outside-transaction)))
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (unless (eq ebox--pub--transaction-final-accept-function
              #'ebox--pub--transaction-noop-final-accept)
    (signal 'ebox--pub-reactive-error
            (list :duplicate-final-accept-function
                  ebox--pub--transaction-final-accept-function function)))
  (setq ebox--pub--transaction-final-accept-function function))

(defun ebox--pub--transaction-enter-phase (phase)
  "Enter transaction PHASE for lifecycle validation."
  (setq ebox--pub--transaction-phase phase))

(cl-defun ebox--pub--transaction-register-final-marker
    (&key owner-key expected-token expected-version next-values inverse-values
          slot-write-count operation-key)
  "Register a bounded opaque marker for OWNER-KEY before precommit.
EXPECTED-TOKEN and EXPECTED-VERSION bind owner state.  NEXT-VALUES and
INVERSE-VALUES are prebuilt opaque payloads.  SLOT-WRITE-COUNT is checked
against the trusted OPERATION-KEY descriptor and the transaction bound."
  (unless (and ebox--pub--transaction-active
               (memq ebox--pub--transaction-phase
                     '(body recompute publication participants))
               (not ebox--pub--transaction-final-markers-frozen-p))
    (signal 'ebox--pub-final-marker-error
            (list :registration-phase ebox--pub--transaction-phase)))
  (when (>= ebox--pub--transaction-final-marker-count ebox--pub--final-marker-max-count)
    (signal 'ebox--pub-final-marker-error
            (list :marker-count ebox--pub--transaction-final-marker-count)))
  (let ((duplicate nil))
    (dotimes (index ebox--pub--transaction-final-marker-count)
      (when (equal owner-key
                   (aref ebox--pub--transaction-final-marker-owner-keys index))
        (setq duplicate t)))
    (when duplicate
      (signal 'ebox--pub-final-marker-error (list :duplicate-owner-key owner-key))))
  (let ((marker
         (ebox--pub--final-accept-marker-create
          :owner-key owner-key
          :expected-token expected-token
          :expected-version expected-version
          :next-values next-values
          :inverse-values inverse-values
          :slot-write-count slot-write-count
          :operation-key operation-key)))
    (when (> (+ ebox--pub--transaction-final-marker-slot-writes slot-write-count)
             ebox--pub--final-marker-max-slot-writes)
      (signal 'ebox--pub-final-marker-error
              (list :slot-write-bound
                    ebox--pub--transaction-final-marker-slot-writes
                    slot-write-count)))
    (aset ebox--pub--transaction-final-marker-registry
          ebox--pub--transaction-final-marker-count marker)
    (aset ebox--pub--transaction-final-marker-owner-keys
          ebox--pub--transaction-final-marker-count
          (ebox-text--copy-property-value owner-key))
    (cl-incf ebox--pub--transaction-final-marker-count)
    (cl-incf ebox--pub--transaction-final-marker-slot-writes slot-write-count)
    marker))

(cl-defun ebox-transaction-register-final-marker
    (&key owner-key expected-token expected-version next-values inverse-values
          slot-write-count operation-key)
  "Register one bounded final-accept authority marker.  OWNER-KEY must be
unique in the active transaction.  EXPECTED-TOKEN and EXPECTED-VERSION bind
owner state; NEXT-VALUES and INVERSE-VALUES are prebuilt slot-write vectors
with fixed SLOT-WRITE-COUNT.  OPERATION-KEY must resolve through Ebox's
closed marker-operation whitelist."
  (ebox--pub--transaction-register-final-marker
   :owner-key owner-key
   :expected-token expected-token
   :expected-version expected-version
   :next-values next-values
   :inverse-values inverse-values
   :slot-write-count slot-write-count
   :operation-key operation-key))

(defun ebox--pub--transaction-freeze-final-markers ()
  "Seal framework markers only when an Ebox publication is staged."
  (when (and (> ebox--pub--transaction-final-marker-count 0)
             (not ebox--pub--publication-started-p))
    (signal 'ebox--pub-final-marker-error (list :marker-without-publication)))
  (dotimes (index ebox--pub--transaction-final-marker-count)
    (ebox--pub--final-accept-marker-validate
     (aref ebox--pub--transaction-final-marker-registry index)))
  (setq ebox--pub--transaction-final-markers-frozen-p t))

(defun ebox--pub--transaction-apply-one-final-marker (marker)
  "Apply one prevalidated MARKER through its closed package primitive."
  (funcall
   (ebox--pub--final-marker-operation-apply
    (ebox--pub-final-accept-marker-operation marker))
   marker))

(defun ebox--pub--transaction-restore-one-final-marker (marker)
  "Restore one prevalidated MARKER through its closed package primitive."
  (funcall
   (ebox--pub--final-marker-operation-restore
    (ebox--pub-final-accept-marker-operation marker))
   marker))

(defun ebox--pub--transaction-restore-final-marker-at (index failures-cell)
  "Restore marker INDEX, then exhaustively continue using FAILURES-CELL."
  (when (>= index 0)
    (let ((marker (aref ebox--pub--transaction-final-marker-registry index)))
      (unwind-protect
          (when (memq (ebox--pub-final-accept-marker-state marker)
                      '(applying applied))
            (setf (ebox--pub-final-accept-marker-state marker) 'restoring)
            (condition-case failure
                (progn
                  (ebox--pub--transaction-restore-one-final-marker marker)
                  (setf (ebox--pub-final-accept-marker-state marker) 'restored))
              ((error quit)
               (setf (ebox--pub-final-accept-marker-state marker) 'restore-failed)
               (aset
                failures-cell 0
                (cons (list 'final-markers
                            (ebox--pub-final-accept-marker-owner-key marker)
                            failure)
                      (aref failures-cell 0))))))
        ;; This cleanup runs even when a test or corrupted primitive exits by
        ;; an arbitrary nonlocal throw, so no earlier applied marker is skipped.
        (ebox--pub--transaction-restore-final-marker-at
         (1- index) failures-cell)))))

(defun ebox--pub--transaction-restore-applied-final-markers ()
  "Reverse every applied marker and return contained restore failures."
  (let ((index (1- ebox--pub--transaction-applied-final-marker-count))
        (failures-cell (vector nil)))
    (setq ebox--pub--transaction-applied-final-marker-count 0)
    (ebox--pub--transaction-restore-final-marker-at index failures-cell)
    (nreverse (aref failures-cell 0))))

(defun ebox--pub--transaction-apply-final-markers ()
  "Apply every sealed marker in registration order."
  (dotimes (index ebox--pub--transaction-final-marker-count)
    (let ((marker (aref ebox--pub--transaction-final-marker-registry index)))
      ;; Count and mark first so mutate-then-signal is still reverse-restored.
      (setq ebox--pub--transaction-applied-final-marker-count (1+ index))
      (setf (ebox--pub-final-accept-marker-state marker) 'applying)
      (ebox--pub--transaction-apply-one-final-marker marker)
      (setf (ebox--pub-final-accept-marker-state marker) 'applied))))

(defun ebox--pub--transaction-commit-final-markers ()
  "Finalize marker state through fixed writes after successful accept."
  (dotimes (index ebox--pub--transaction-final-marker-count)
    (setf (ebox--pub-final-accept-marker-state
           (aref ebox--pub--transaction-final-marker-registry index))
          'committed))
  (setq ebox--pub--transaction-applied-final-marker-count 0))

(defun ebox--pub--transaction-run-final-accept ()
  "Apply bounded framework markers and accept the shared journal."
  (let (accepted)
    (unwind-protect
        (progn
          (ebox--pub--transaction-apply-final-markers)
          (funcall ebox--pub--transaction-final-accept-function)
          (setq accepted t))
      (unless accepted
        (setq ebox--pub--transaction-marker-restore-failures
              (ebox--pub--transaction-restore-applied-final-markers))))
    (when accepted (ebox--pub--transaction-commit-final-markers))))

(defun ebox--pub--transaction-finish-rollback (_primary-condition _rollback-failures)
  "Retire markers that never reached acceptance."
  (dotimes (index ebox--pub--transaction-final-marker-count)
    (let ((marker (aref ebox--pub--transaction-final-marker-registry index)))
      (when (eq (ebox--pub-final-accept-marker-state marker) 'prepared)
        (setf (ebox--pub-final-accept-marker-state marker) 'rolled-back)))))

(defun ebox--pub--run-contained-transaction-functions (phase functions)
  "Run postaccept PHASE FUNCTIONS and record contained failures."
  (dolist (function (ebox--pub--transaction-hook-functions functions))
    (let ((inhibit-quit t)
          (quit-flag nil))
      (condition-case failure
          (funcall function)
        ((error quit)
         (push (list phase function failure)
               ebox--pub--transaction-contained-failures))))))

(defun ebox--pub--run-transaction-precommit-functions ()
  "Run the internal declared precommit registry in deterministic order."
  (dolist (function ebox--pub--transaction-precommit-functions)
    (unless (ebox--pub--transaction-precommit-function-p function)
      (signal 'ebox--pub-reactive-error
              (list :invalid-precommit-function function)))
    (funcall function)))

(defun ebox--pub--prepare-signal-commit-journal ()
  "Capture every touched signal before any committed field is mutated."
  (setq ebox--pub--transaction-signal-commit-journal
        (mapcar
         (lambda (signal)
           (ebox--pub--make-signal-commit-entry
            :signal signal
            :old-committed-value (ebox--pub-signal-committed-value signal)
            :old-revision (ebox--pub-signal-revision signal)
            :candidate-value
            (gethash signal ebox--pub--transaction-signal-values)))
         (nreverse (copy-sequence ebox--pub--transaction-signals)))))

(defun ebox--pub--commit-signal-entry (entry)
  "Commit signal journal ENTRY exactly once."
  (let ((signal (ebox--pub--signal-commit-entry-signal entry)))
    (setf (ebox--pub-signal-committed-value signal)
          (ebox--pub--signal-commit-entry-candidate-value entry)
          (ebox--pub-signal-revision signal)
          (1+ (ebox--pub--signal-commit-entry-old-revision entry)))))

(defun ebox--pub--restore-signal-entry (entry)
  "Restore signal journal ENTRY's exact committed state."
  (let ((signal (ebox--pub--signal-commit-entry-signal entry)))
    (setf (ebox--pub-signal-committed-value signal)
          (ebox--pub--signal-commit-entry-old-committed-value entry)
          (ebox--pub-signal-revision signal)
          (ebox--pub--signal-commit-entry-old-revision entry))))

(defun ebox--pub--commit-signal-values ()
  "Journal and commit candidate signals in stable first-touch order."
  (ebox--pub--prepare-signal-commit-journal)
  (dolist (entry ebox--pub--transaction-signal-commit-journal)
    (ebox--pub--commit-signal-entry entry)))

(defun ebox--pub--restore-transaction-counters (snapshot)
  "Restore reactive counters from SNAPSHOT."
  (setq ebox--pub--reactive-counters snapshot))

(defun ebox--pub--transaction-hook-functions (value)
  "Return hook VALUE as one ordered function list."
  (cond
   ((null value) nil)
   ((functionp value) (list value))
   (t value)))

(defun ebox--pub--rollback-hook-phase (phase functions)
  "Run rollback PHASE FUNCTIONS and return ordered failures."
  (let (failures)
    (dolist (function (ebox--pub--transaction-hook-functions functions))
      (condition-case failure
          (funcall function)
        ((error quit)
         (push (list phase function failure) failures))))
    (nreverse failures)))

(defun ebox--pub--rollback-signal-journal ()
  "Restore every signal journal entry and return ordered failures."
  (let (failures)
    (dolist (entry ebox--pub--transaction-signal-commit-journal)
      (condition-case failure
          (ebox--pub--restore-signal-entry entry)
        ((error quit)
         (push (list 'signal-journal
                     (ebox--pub-signal-id
                      (ebox--pub--signal-commit-entry-signal entry))
                     failure)
               failures))))
    (nreverse failures)))

(defun ebox--pub--rollback-transaction-state (counter-snapshot)
  "Restore COUNTER-SNAPSHOT through every rollback phase.  Return contained
failures in phase order."
  (let ((failures (copy-sequence ebox--pub--transaction-marker-restore-failures)))
    (setq failures
          (append
           failures
           (ebox--pub--rollback-transaction-participants)
           (ebox--pub--rollback-hook-phase
            'rollback-hooks ebox--pub--transaction-rollback-functions)
           (ebox--pub--rollback-signal-journal)))
    (condition-case failure
        (ebox--pub--rollback-bindings)
      ((error quit)
       (setq failures
             (append failures
                     (list (list 'bindings 'binding-graph failure))))))
    (condition-case failure
        (ebox--pub--restore-transaction-counters counter-snapshot)
      ((error quit)
       (setq failures
             (append failures
                     (list (list 'counters 'reactive-counters failure))))))
    (append
     failures
     (ebox--pub--rollback-hook-phase
      'rollback-final ebox--pub--transaction-rollback-final-functions))))

(defun ebox--pub--resignal-transaction-primary (primary-condition failures)
  "Re-signal PRIMARY-CONDITION with ordered rollback FAILURES attached."
  (let* ((condition (car primary-condition))
         (data (cdr primary-condition))
         (trailer (when failures
                    (list ebox--pub--transaction-condition-trailer-tag
                          (list :rollback-failures failures)))))
    ;; Rollback keys and secondary conditions can retain callback graphs too.
    ;; Bound only publication-owned conditions; application errors preserve
    ;; the data supplied by their caller.
    (if (memq 'ebox--pub-surface-error (get condition 'error-conditions))
        (ebox--pub--signal condition data trailer)
      (signal condition (if trailer (append data trailer) data)))))

(defun ebox--pub--transaction-condition-trailer (condition property)
  "Return PROPERTY from the exact transaction trailer of CONDITION.
Transaction rollback metadata is appended after, and never merged into, the
primary condition data."
  (let ((trailer (last condition 2)))
    (and (eq (car trailer) ebox--pub--transaction-condition-trailer-tag)
         (plist-get (cadr trailer) property))))

(defun ebox--pub--call-with-transaction (function)
  "Call FUNCTION in one atomic signal and binding transaction."
  (when ebox--pub--prepared-frame-active
    (signal 'ebox--pub-transaction-contract-error
            (list :nested-prepared-publication)))
  (if ebox--pub--transaction-active
      (funcall function)
    (let (after-commit result
          (ebox--pub--transaction-contained-failures nil))
      (setq result
            (let ((ebox--pub--transaction-active t)
                  (ebox--pub--transaction-phase 'body)
                  (ebox--pub--transaction-signal-values
                   (make-hash-table :test #'eq))
                  (ebox--pub--transaction-signals nil)
                  (ebox--pub--transaction-dirty-set (make-hash-table :test #'eq))
                  (ebox--pub--transaction-dirty-queue nil)
                  (ebox--pub--transaction-binding-snapshots
                   (make-hash-table :test #'eq))
                  (ebox--pub--transaction-created-bindings nil)
                  (ebox--pub--transaction-recompute-counts
                   (make-hash-table :test #'eq))
                  (ebox--pub--transaction-extensions (make-hash-table :test #'eq))
                  (ebox--pub--transaction-after-commit-callbacks nil)
                  (ebox--pub--transaction-participants nil)
                  (ebox--pub--transaction-participant-keys nil)
                  (ebox--pub--transaction-participant-order 0)
                  (ebox--pub--transaction-published-participants nil)
                  (ebox--pub--transaction-signal-commit-journal nil)
                  (ebox--pub--publication-started-p nil)
                  (ebox--pub--transaction-structured-participants nil)
                  (ebox--pub--transaction-final-marker-registry
                   (make-vector ebox--pub--final-marker-max-count nil))
                  (ebox--pub--transaction-final-marker-owner-keys
                   (make-vector ebox--pub--final-marker-max-count nil))
                  (ebox--pub--transaction-final-marker-count 0)
                  (ebox--pub--transaction-final-marker-slot-writes 0)
                  (ebox--pub--transaction-final-markers-frozen-p nil)
                  (ebox--pub--transaction-applied-final-marker-count 0)
                  (ebox--pub--transaction-marker-restore-failures nil)
                  (ebox--pub--transaction-final-accept-function
                   #'ebox--pub--transaction-noop-final-accept)
                  (counter-snapshot (copy-sequence ebox--pub--reactive-counters))
                  (ebox--pub--transaction-counter-start nil)
                  success transaction-result primary-condition
                  rollback-failures pending-quit)
              (setq ebox--pub--transaction-counter-start counter-snapshot)
              (unwind-protect
                  (condition-case condition
                      (progn
                        (setq transaction-result (funcall function))
                        (ebox--pub--transaction-enter-phase 'recompute)
                        (ebox--pub--flush-dirty-bindings)
                        (ebox--pub--transaction-enter-phase 'publication)
                        (setq ebox--pub--transaction-structured-participants
                              (vconcat
                               (ebox--pub--transaction-participants-in-registration-order)))
                        (run-hooks 'ebox--pub--transaction-publish-functions)
                        nil
                        (ebox--pub--transaction-enter-phase 'participants)
                        (ebox--pub--stage-structured-transaction-participants)
                        nil
                        (ebox--pub--transaction-enter-phase 'precommit)
                        (ebox--pub--run-structured-transaction-participant-precommits)
                        (ebox--pub--run-transaction-precommit-functions)
                        (ebox--pub--transaction-freeze-final-markers)
                        nil
                        (ebox--pub--transaction-enter-phase 'signal-commit)
                        (ebox--pub--commit-signal-values)
                        nil
                        (ebox--pub--transaction-enter-phase 'final-accept)
                        nil
                        (condition-case deferred-quit
                            (progn
                              (let ((inhibit-quit t)
                                    (quit-flag nil))
                                (unwind-protect
                                    (progn
                                      (unless
                                          (functionp
                                           ebox--pub--transaction-final-accept-function)
                                        (signal
                                         'ebox--pub-reactive-error
                                         (list
                                          :invalid-final-accept-function
                                          ebox--pub--transaction-final-accept-function)))
                                      (ebox--pub--transaction-run-final-accept)
                                      (setq success t)
                                      (ebox--pub--commit-structured-transaction-participants)
                                      nil
                                      (when quit-flag
                                        (setq pending-quit t
                                              quit-flag nil))
                                      (ebox--pub--run-contained-transaction-functions
                                       'committed
                                       ebox--pub--transaction-committed-functions)
                                      (setq after-commit
                                            (nreverse
                                             ebox--pub--transaction-after-commit-callbacks))
                                      (when pending-quit
                                        (push
                                         (list 'final-accept
                                               ebox--pub--transaction-final-accept-function
                                               '(quit))
                                         ebox--pub--transaction-contained-failures)))
                                  (setq quit-flag nil)))
                              nil)
                          (quit
                           (if success
                               (push
                                (list 'final-accept
                                      ebox--pub--transaction-final-accept-function
                                      deferred-quit)
                                ebox--pub--transaction-contained-failures)
                             (signal (car deferred-quit)
                                     (cdr deferred-quit))))))
                    ((error quit)
                     (setq primary-condition condition)))
                (unless success
                  (let ((inhibit-quit t)
                        (quit-flag nil))
                    (unwind-protect
                        (progn
                          (setq ebox--pub--transaction-phase
                                (or ebox--pub--transaction-phase 'rollback)
                                rollback-failures
                                (ebox--pub--rollback-transaction-state
                                 counter-snapshot))
                          (ebox--pub--transaction-finish-rollback
                           primary-condition rollback-failures))
                      (setq quit-flag nil)))))
              (when primary-condition
                (ebox--pub--resignal-transaction-primary
                 primary-condition rollback-failures))
              transaction-result))
      (ebox--pub--run-contained-transaction-functions 'after-commit after-commit)
      (setq ebox--pub--last-transaction-diagnostics
            (nreverse ebox--pub--transaction-contained-failures))
      result)))

(defmacro ebox-with-transaction (&rest body)
  "Evaluate BODY in one atomic signal and binding transaction."
  (declare (indent 0) (debug t))
  `(ebox--pub--call-with-transaction (lambda () ,@body)))

(defun ebox--pub--dispose-signal (signal)
  "Dispose SIGNAL and detach its graph and adapter state."
  (unless (ebox--pub-signal-disposed signal)
    (dolist (binding (ebox--pub--sorted-subscribers signal))
      (setf (ebox--pub-binding-dependencies binding)
            (delq signal (ebox--pub-binding-dependencies binding))
            (ebox--pub-binding-dirty binding) t))
    (clrhash (ebox--pub-signal-subscribers signal))
    (when-let* ((scope (and (bufferp (ebox--pub-signal-scope signal))
                           (ebox--pub-signal-scope signal))))
      (when (buffer-live-p scope)
        (with-current-buffer scope
          (setq ebox--pub--buffer-signals (delq signal ebox--pub--buffer-signals)))))
    (setf (ebox--pub-signal-disposed signal) t)
    (setq ebox--pub--signals (delq signal ebox--pub--signals))))

(defun ebox--pub-signal-dispose (signal)
  "Dispose SIGNAL, detach its subscriptions, and return nil."
  (unless (ebox--pub-signal-p signal)
    (signal 'wrong-type-argument (list 'ebox--pub-signal-p signal)))
  (when ebox--pub--transaction-active
    (signal 'ebox--pub-reactive-error (list :dispose-during-transaction)))
  (ebox--pub--dispose-signal signal)
  nil)

(provide 'ebox-reactive)
;;; ebox-reactive.el ends here
