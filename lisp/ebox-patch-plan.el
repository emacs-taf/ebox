;;; ebox-patch-plan.el --- Pure Ebox patch artifact planning -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Reduces tentative patch operations into one deterministic antichain.  The
;; planner consumes only operation plists and an immutable node parent table;
;; it does not read a buffer, call a surface, or publish an artifact.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-runtime-index)

(define-error 'ebox-patch-plan-error "Invalid Ebox patch plan input")

(defconst ebox-patch-plan--dirty-kind-order
  '(paint span geometry placement structure)
  "Dirty kinds ordered from cheapest to most disruptive.")

(defun ebox-patch-plan--operation-strength (strategy)
  "Return structural dominance strength for patch STRATEGY."
  (pcase strategy
    ('native-frame 4)
    ('owner-rerender 3)
    ('span-patch 2)
    ('paint-patch 1)
    ((or 'child-splice 'child-reorder) 0)
    (_ 0)))

(defun ebox-patch-plan--dirty-kind-strength (kind)
  "Return relative disruption strength for dirty KIND."
  (or (cl-position kind ebox-patch-plan--dirty-kind-order) -1))

(defun ebox-patch-plan--dirty-node-ids (dirty)
  "Return distinct source node ids recorded by DIRTY."
  (delete-dups
   (append (when-let* ((node-id (plist-get dirty :node-id)))
             (list node-id))
           (copy-sequence (or (plist-get dirty :node-ids) nil)))))

(defun ebox-patch-plan--merge-dirty (primary secondary)
  "Merge SECONDARY dirty provenance into PRIMARY without mutating either."
  (cond
   ((null primary) (copy-sequence secondary))
   ((null secondary) (copy-sequence primary))
   (t
    (let ((merged (copy-sequence primary)))
      (setq merged
            (plist-put
             merged :node-ids
             (delete-dups
              (append (ebox-patch-plan--dirty-node-ids primary)
                      (ebox-patch-plan--dirty-node-ids secondary)))))
      (dolist (key '(:changed-keys :region-ids :old-region-ids
                     :new-region-ids :impact-vector))
        (setq merged
              (plist-put
               merged key
               (delete-dups
                (append (copy-sequence (or (plist-get primary key) nil))
                        (copy-sequence
                         (or (plist-get secondary key) nil)))))))
      (when (or (plist-get primary :requires-owned-overflow-coverage)
                (plist-get secondary :requires-owned-overflow-coverage))
        (setq merged
              (plist-put merged :requires-owned-overflow-coverage t)))
      (when (> (ebox-patch-plan--dirty-kind-strength
                (plist-get secondary :dirty-kind))
               (ebox-patch-plan--dirty-kind-strength
                (plist-get primary :dirty-kind)))
        (setq merged
              (plist-put merged :dirty-kind
                         (plist-get secondary :dirty-kind))))
      merged))))

(defun ebox-patch-plan--merge-op-dirty (op absorbed)
  "Return OP with ABSORBED's dirty provenance merged into a fresh plist."
  (let ((merged (copy-sequence op)))
    (plist-put merged :dirty
               (ebox-patch-plan--merge-dirty
                (plist-get op :dirty)
                (plist-get absorbed :dirty)))))

(defun ebox-patch-plan--merge-same-owner (left right)
  "Return the stronger same-owner op with merged dirty provenance."
  (let* ((left-strength
          (ebox-patch-plan--operation-strength (plist-get left :op)))
         (right-strength
          (ebox-patch-plan--operation-strength (plist-get right :op)))
         (left-dirty-strength
          (ebox-patch-plan--dirty-kind-strength
           (plist-get (plist-get left :dirty) :dirty-kind)))
         (right-dirty-strength
          (ebox-patch-plan--dirty-kind-strength
           (plist-get (plist-get right :dirty) :dirty-kind)))
         (left-wins
          (or (> left-strength right-strength)
              (and (= left-strength right-strength)
                   (>= left-dirty-strength right-dirty-strength))))
         (winner (if left-wins left right))
         (loser (if left-wins right left)))
    (ebox-patch-plan--merge-op-dirty winner loser)))

(defun ebox-patch-plan--validate-op (op)
  "Signal unless OP is one complete tentative patch artifact."
  (unless (and (proper-list-p op)
               (plist-member op :op)
               (plist-member op :owner-id))
    (signal 'ebox-patch-plan-error (list :malformed-operation op)))
  op)

(defun ebox-patch-plan--ancestor-set (parent-table owner-id)
  "Return OWNER-ID's strict ancestors from immutable PARENT-TABLE."
  (let ((ancestors (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        (walk (ebox-runtime-index-get owner-id parent-table)))
    (while walk
      (when (gethash walk seen)
        (signal 'ebox-patch-plan-error
                (list :cyclic-parent-table :node-id walk)))
      (puthash walk t seen)
      (puthash walk t ancestors)
      (setq walk (ebox-runtime-index-get walk parent-table)))
    ancestors))

(defun ebox-patch-plan--make-index ()
  "Return fresh planner-local antichain merge state."
  (list :owner-table (make-hash-table :test #'equal)
        :ancestor-table (make-hash-table :test #'equal)
        :serial 0))

(defun ebox-patch-plan--index-insert (index entry)
  "Register planner ENTRY in INDEX."
  (puthash (plist-get (aref entry 0) :owner-id)
           entry (plist-get index :owner-table))
  (let ((ancestor-table (plist-get index :ancestor-table)))
    (maphash
     (lambda (ancestor-id _present)
       (push entry (gethash ancestor-id ancestor-table)))
     (aref entry 2))))

(defun ebox-patch-plan--index-remove (index entry)
  "Remove planner ENTRY from INDEX."
  (remhash (plist-get (aref entry 0) :owner-id)
           (plist-get index :owner-table))
  (let ((ancestor-table (plist-get index :ancestor-table)))
    (maphash
     (lambda (ancestor-id _present)
       (puthash ancestor-id
                (delq entry (gethash ancestor-id ancestor-table))
                ancestor-table))
     (aref entry 2))))

(defun ebox-patch-plan--index-add (parent-table index candidate)
  "Merge CANDIDATE into INDEX using immutable PARENT-TABLE ancestry."
  (setq candidate (ebox-patch-plan--validate-op candidate))
  (let* ((owner-table (plist-get index :owner-table))
         (owner-id (plist-get candidate :owner-id))
         (same-owner (gethash owner-id owner-table)))
    (when same-owner
      (setq candidate
            (ebox-patch-plan--merge-same-owner
             (aref same-owner 0) candidate))
      (ebox-patch-plan--index-remove index same-owner))
    (let* ((ancestors
            (ebox-patch-plan--ancestor-set parent-table owner-id))
           dominator)
      (maphash
       (lambda (ancestor-id _present)
         (when-let* ((entry (gethash ancestor-id owner-table)))
           (when (and (>= (ebox-patch-plan--operation-strength
                           (plist-get (aref entry 0) :op))
                          (ebox-patch-plan--operation-strength 'span-patch))
                      (or (null dominator)
                          (< (aref entry 1) (aref dominator 1))))
             (setq dominator entry))))
       ancestors)
      (if dominator
          (aset dominator 0
                (ebox-patch-plan--merge-op-dirty
                 (aref dominator 0) candidate))
        (when (>= (ebox-patch-plan--operation-strength
                   (plist-get candidate :op))
                  (ebox-patch-plan--operation-strength 'span-patch))
          (dolist (entry
                   (sort
                    (copy-sequence
                     (gethash owner-id (plist-get index :ancestor-table)))
                    (lambda (left right)
                      (< (aref left 1) (aref right 1)))))
            (setq candidate
                  (ebox-patch-plan--merge-op-dirty
                   candidate (aref entry 0)))
            (ebox-patch-plan--index-remove index entry)))
        (let ((entry (vector candidate
                             (plist-get index :serial)
                             ancestors)))
          (plist-put index :serial (1+ (plist-get index :serial)))
          (ebox-patch-plan--index-insert index entry))))))

(defun ebox-patch-plan--index-result (index)
  "Return INDEX's surviving operations in stable insertion order."
  (let (entries)
    (maphash (lambda (_owner-id entry) (push entry entries))
             (plist-get index :owner-table))
    (mapcar (lambda (entry) (aref entry 0))
            (sort entries
                  (lambda (left right)
                    (< (aref left 1) (aref right 1)))))))

(defun ebox-patch-plan-merge-ops (parent-table operations)
  "Return the pure deterministic antichain for tentative OPERATIONS.

PARENT-TABLE maps a node id to its parent id and is treated as immutable.
OPERATIONS are patch artifact plists.  This function mutates neither input and
has no publication capability."
  (unless (ebox-runtime-index-like-p parent-table)
    (signal 'ebox-patch-plan-error
            (list :malformed-parent-table parent-table)))
  (unless (proper-list-p operations)
    (signal 'ebox-patch-plan-error
            (list :malformed-operations operations)))
  (let ((index (ebox-patch-plan--make-index)))
    (dolist (operation operations)
      (ebox-patch-plan--index-add parent-table index operation))
    (ebox-patch-plan--index-result index)))

(provide 'ebox-patch-plan)

;;; ebox-patch-plan.el ends here
