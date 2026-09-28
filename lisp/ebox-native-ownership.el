;;; ebox-native-ownership.el --- Numeric retained ownership projection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ebox contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Private optional acceleration for ordinary and native surface projection.
;; Rust retains numeric topology and role programs; Lisp retains exact tags.
;; A candidate is used once, then kept only as an immutable fork baseline.

;;; Code:

(require 'cl-lib)
(require 'ebox-native-reflow)

(declare-function ebox-native--module-ownership-create "ebox_native_reflow"
                  (parents regions capacity))
(declare-function ebox-native--module-ownership-fork "ebox_native_reflow"
                  (handle parents removed-nodes regions removed-regions))
(declare-function ebox-native--module-ownership-project "ebox_native_reflow"
                  (handle recipes recipe-count runs run-count output))
(declare-function ebox-native--module-ownership-read "ebox_native_reflow"
                  (handle output))
(declare-function ebox-native--module-ownership-release "ebox_native_reflow"
                  (handle))

(defconst ebox-native-ownership--maximum-ranges 262144)
(defconst ebox-native-ownership--maximum-programs 131072)
(defconst ebox-native-ownership--maximum-scalars 4194304)

(cl-defstruct (ebox-native-ownership--state
               (:constructor ebox-native-ownership--make-state))
  handle capacity programs base-programs tags base-tags tag-keys base-tag-keys
  (next-program 0) (next-tag 2) recipes (recipe-count 0) runs (run-count 0)
  output started finished failed)

(defun ebox-native-ownership-available-p ()
  "Return non-nil when the optional numeric ownership ABI is usable."
  (condition-case nil
      (and (ebox-native-reflow-layout-ready-p)
           (fboundp 'ebox-native--module-ownership-create)
           (fboundp 'ebox-native--module-ownership-fork)
           (fboundp 'ebox-native--module-ownership-project)
           (fboundp 'ebox-native--module-ownership-read)
           (fboundp 'ebox-native--module-ownership-release))
    (error nil)))

(defun ebox-native-ownership--state (handle capacity &optional base)
  "Wrap numeric HANDLE with CAPACITY and immutable BASE caches."
  (when handle
    (let ((tags (make-hash-table :test #'eql)))
      (puthash 0 '(:ebox/descendant-output t) tags)
      (puthash 1 '(:ebox/layout-output t) tags)
      (ebox-native-ownership--make-state
       :handle handle :capacity capacity
       :programs (make-hash-table :test #'equal)
       :base-programs (and base (ebox-native-ownership--state-programs base))
       :tags tags :base-tags (and base (ebox-native-ownership--state-tags base))
       :tag-keys (make-hash-table :test #'equal)
       :base-tag-keys (and base (ebox-native-ownership--state-tag-keys base))
       :next-program (if base (ebox-native-ownership--state-next-program base) 0)
       :next-tag (if base (ebox-native-ownership--state-next-tag base) 2)
       :recipes [] :runs [] :output []))))

(defun ebox-native-ownership-create (parents regions &optional capacity)
  "Create an optional ownership baseline from numeric PARENTS and REGIONS.
PARENTS is a flat vector of node ID and parent ID pairs; zero marks roots.
REGIONS is a flat vector of region ID and node ID pairs.  Positive integer
identities remain stable across candidates.  CAPACITY bounds merged ranges,
defaulting to 65536.  Return nil for unavailable or unsupported input."
  (when (ebox-native-ownership-available-p)
    (condition-case nil
        (let ((limit (or capacity 65536)))
          (ebox-native-ownership--state
           (ebox-native--module-ownership-create parents regions limit) limit))
      (error nil))))

(defun ebox-native-ownership-fork
    (old &optional parent-upserts removed-nodes region-upserts removed-regions)
  "Fork finished OLD with sparse numeric topology changes.
UPSERT vectors contain ID/value pairs; REMOVED vectors contain IDs.  Nil
means no change.  OLD remains immutable and usable after candidate failure.
Unchanged numeric topology is shared; structural changes copy numeric maps
and invalidate only programs depending on changed region or ancestor IDs."
  (when (and (ebox-native-ownership-available-p)
             (ebox-native-ownership--state-p old)
             (ebox-native-ownership--state-handle old)
             (ebox-native-ownership--state-finished old)
             (not (ebox-native-ownership--state-failed old)))
    (condition-case nil
        (ebox-native-ownership--state
         (ebox-native--module-ownership-fork
          (ebox-native-ownership--state-handle old)
          parent-upserts removed-nodes region-upserts removed-regions)
         (ebox-native-ownership--state-capacity old) old)
      (error nil))))

(defun ebox-native-ownership-begin (candidate &optional run-capacity)
  "Begin the single ownership projection for CANDIDATE.
RUN-CAPACITY optionally reserves numeric run storage.  Return nil on decline."
  (when (and (ebox-native-ownership--state-p candidate)
             (ebox-native-ownership--state-handle candidate)
             (not (ebox-native-ownership--state-started candidate))
             (not (ebox-native-ownership--state-failed candidate)))
    (let ((capacity (or run-capacity 128)))
      (when (and (integerp capacity) (<= 0 capacity)
                 (<= capacity ebox-native-ownership--maximum-ranges))
        (setf (ebox-native-ownership--state-runs candidate)
              (make-vector (* 3 capacity) 0)
              (ebox-native-ownership--state-started candidate) t)
        t))))

(defun ebox-native-ownership--grow (vector needed)
  "Return VECTOR or larger numeric storage for NEEDED scalars."
  (when (<= needed ebox-native-ownership--maximum-scalars)
    (if (<= needed (length vector)) vector
      (let ((grown (make-vector
                    (min ebox-native-ownership--maximum-scalars
                         (max needed 64 (* 2 (length vector)))) 0)))
        (cl-loop for index below (length vector)
                 do (aset grown index (aref vector index)))
        grown))))

(defun ebox-native-ownership--tag-id (candidate region roles)
  "Intern REGION and ordered ROLES as an exact Lisp-owned tag."
  (let* ((tag (list :ebox/region-id region :ebox/roles roles))
         (keys (ebox-native-ownership--state-tag-keys candidate))
         (base (ebox-native-ownership--state-base-tag-keys candidate))
         (id (or (gethash tag keys) (and base (gethash tag base)))))
    (unless id
      (setq id (ebox-native-ownership--state-next-tag candidate))
      (cl-incf (ebox-native-ownership--state-next-tag candidate)))
    (unless (gethash id (ebox-native-ownership--state-tags candidate))
      (setq tag (copy-tree tag))
      (puthash id tag (ebox-native-ownership--state-tags candidate))
      (puthash tag id keys))
    id))

(defun ebox-native-ownership--program (candidate roles layout)
  "Intern one exact ROLES and LAYOUT recipe in CANDIDATE without FFI."
  (let* ((key (if layout (cons layout roles) roles))
         (programs (ebox-native-ownership--state-programs candidate))
         (entry (gethash key programs)))
    (or entry
        (when (< (hash-table-count programs)
                 ebox-native-ownership--maximum-programs)
          (let ((base (ebox-native-ownership--state-base-programs candidate)))
            (setq entry (and base (gethash key base))))
          (if entry
              (let ((tags (ebox-native-ownership--state-tags candidate))
                    (base-tags (ebox-native-ownership--state-base-tags candidate))
                    (keys (ebox-native-ownership--state-tag-keys candidate)))
                (dolist (id (cdr entry))
                  (let ((tag (gethash id base-tags)))
                    (unless tag (error "Native ownership lost an exact role tag"))
                    (puthash id tag tags)
                    (puthash tag id keys))))
            (let ((regions (delete-dups (mapcar #'cdr roles)))
                  (id (ebox-native-ownership--state-next-program candidate))
                  (offset (ebox-native-ownership--state-recipe-count candidate))
                  direct tag-ids)
              (dolist (region regions)
                (let ((tag-id
                       (ebox-native-ownership--tag-id
                        candidate region
                        (cl-loop for (role . owner) in roles
                                 when (equal owner region) collect role))))
                  (push region direct)
                  (push tag-id direct)
                  (push tag-id tag-ids)))
              (setq direct (nreverse direct))
              (let* ((values (append (list id (length regions) (length layout))
                                     direct layout))
                     (needed (+ offset (length values)))
                     (recipes (ebox-native-ownership--grow
                               (ebox-native-ownership--state-recipes candidate)
                               needed)))
                (unless recipes (error "Native ownership recipe capacity exceeded"))
                (dolist (value values)
                  (aset recipes offset value)
                  (cl-incf offset))
                (setf (ebox-native-ownership--state-recipes candidate) recipes
                      (ebox-native-ownership--state-recipe-count candidate) needed)
                (cl-incf (ebox-native-ownership--state-next-program candidate))
                (setq entry (cons id tag-ids)))))
          (puthash (copy-tree key) entry programs)
          entry))))

(defun ebox-native-ownership-add-run
    (candidate role-ids start end &optional layout-region-ids)
  "Accumulate one ordered ownership run in CANDIDATE, without an FFI call.
ROLE-IDS preserves exact role/region order and LAYOUT-REGION-IDS contains
allocation dependencies.  Return nil on decline; then discard CANDIDATE."
  (when (and (ebox-native-ownership--state-p candidate)
             (ebox-native-ownership--state-started candidate)
             (not (ebox-native-ownership--state-finished candidate))
             (not (ebox-native-ownership--state-failed candidate)))
    (condition-case nil
        (let* ((count (ebox-native-ownership--state-run-count candidate))
               (program (and (< count ebox-native-ownership--maximum-ranges)
                             (ebox-native-ownership--program
                              candidate role-ids layout-region-ids)))
               (runs (and program
                          (ebox-native-ownership--grow
                           (ebox-native-ownership--state-runs candidate)
                           (* 3 (1+ count))))))
          (unless runs (error "Native ownership run capacity exceeded"))
          (aset runs (* 3 count) (car program))
          (aset runs (1+ (* 3 count)) start)
          (aset runs (+ 2 (* 3 count)) end)
          (setf (ebox-native-ownership--state-runs candidate) runs
                (ebox-native-ownership--state-run-count candidate) (1+ count))
          t)
      (error (setf (ebox-native-ownership--state-failed candidate) t) nil))))

(defun ebox-native-ownership-finish (candidate)
  "Project CANDIDATE once and return (COUNT . VECTOR), or nil to decline.
VECTOR contains COUNT flat [node-id tag-id start end] records.  New recipes
and all run coordinates cross the module boundary in one batch.  A larger
output allocation requires only a second copy call, never recomputation.
The caller owns the returned vector and may resolve its identity slots in
place before transferring it to the publisher.  Native forks use retained
numeric storage and never inspect this Lisp result vector."
  (when (and (ebox-native-ownership--state-p candidate)
             (ebox-native-ownership--state-handle candidate)
             (ebox-native-ownership--state-started candidate)
             (not (ebox-native-ownership--state-finished candidate))
             (not (ebox-native-ownership--state-failed candidate)))
    (condition-case nil
        (let* ((handle (ebox-native-ownership--state-handle candidate))
               (output (ebox-native-ownership--state-output candidate))
               (count (ebox-native--module-ownership-project
                       handle (ebox-native-ownership--state-recipes candidate)
                       (ebox-native-ownership--state-recipe-count candidate)
                       (ebox-native-ownership--state-runs candidate)
                       (ebox-native-ownership--state-run-count candidate) output)))
          (unless (integerp count) (error "Native ownership candidate declined"))
          (when (< count 0)
            (setq output (make-vector (* -4 count) 0)
                  count (ebox-native--module-ownership-read handle output)))
          (unless (and (integerp count) (<= 0 count))
            (error "Native ownership output declined"))
          (setf (ebox-native-ownership--state-output candidate) output
                (ebox-native-ownership--state-finished candidate) t
                (ebox-native-ownership--state-base-programs candidate) nil
                (ebox-native-ownership--state-base-tags candidate) nil
                (ebox-native-ownership--state-base-tag-keys candidate) nil
                (ebox-native-ownership--state-recipes candidate) nil
                (ebox-native-ownership--state-runs candidate) nil)
          (cons count output))
      (error (setf (ebox-native-ownership--state-failed candidate) t) nil))))

(defun ebox-native-ownership-tag (candidate tag-id)
  "Return CANDIDATE's immutable Lisp tag for numeric TAG-ID."
  (gethash tag-id (ebox-native-ownership--state-tags candidate)))

(defun ebox-native-ownership-release (candidate)
  "Release CANDIDATE's native storage without changing another generation."
  (when (and (ebox-native-ownership--state-p candidate)
             (ebox-native-ownership--state-handle candidate))
    (let ((handle (ebox-native-ownership--state-handle candidate)))
      (setf (ebox-native-ownership--state-handle candidate) nil)
      (ebox-native--module-ownership-release handle)))
  nil)

(provide 'ebox-native-ownership)
;;; ebox-native-ownership.el ends here
