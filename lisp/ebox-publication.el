;;; ebox-publication.el --- Retained text surfaces and publication -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Geekinney

;; Author: Geekinney (kinneyzhang666@gmail.com)

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3 of
;; the License, or (at your option) any later version.

;;; Commentary:

;; Ebox content publication, retained mounts and rollback journals.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ebox-text)
(require 'ebox-property)
(require 'ebox-reactive)

(define-error 'ebox--pub-surface-error "Ebox retained surface error")
(define-error 'ebox--pub-invalid-surface-plan "Invalid Ebox surface plan"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-duplicate-object-key "Duplicate Ebox object key"
  'ebox--pub-invalid-surface-plan)
(define-error 'ebox--pub-invalid-prepare-context "Invalid Ebox prepare context"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-stale-object "Stale Ebox object" 'ebox--pub-surface-error)
(define-error 'ebox--pub-cross-surface-object "Cross-surface Ebox object"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-orphan-object "Orphan Ebox object" 'ebox--pub-surface-error)
(define-error 'ebox--pub-capability-error "Ebox mount capability violation"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-stale-mount "Stale Ebox mount" 'ebox--pub-surface-error)
(define-error 'ebox--pub-property-conflict "Ebox property ownership conflict"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-dead-surface "Dead Ebox surface" 'ebox--pub-surface-error)
(define-error 'ebox--pub-invalid-range-anchor "Invalid Ebox range anchor"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-invalid-content-range "Invalid Ebox content leaf range"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-producer-buffer-mutation
  "Ebox producer mutated a live surface buffer during prepare"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-publication-mismatch
  "Ebox publication was changed by an external buffer hook"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-scope-mismatch "Scoped Ebox update changed outside its objects"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-owned-result-error "Invalid Ebox owned producer result"
  'ebox--pub-surface-error)
(define-error 'ebox--pub-surface-rollback-error "Ebox surface rollback phase failed"
  'ebox--pub-surface-error)

(cl-defstruct (ebox--pub-surface-plan (:constructor ebox--pub--make-surface-plan))
  "Pure retained node data accepted by a Ebox surface."
  key kind text props children tags capability)

(cl-defstruct (ebox--pub-surface-result
               (:constructor ebox--pub--make-surface-result
                             (plan client-state &optional plan-owned-p
                                   owner-context)))
  "A producer result carrying PLAN and opaque CLIENT-STATE.
PLAN-OWNED-P marks an explicit candidate-local ownership transfer.  The
owned result is bound to OWNER-CONTEXT and consumed once during prepare."
  plan client-state plan-owned-p owner-context consumed-p)

(cl-defstruct (ebox--pub-retained-content-candidate
               (:constructor ebox--pub--make-retained-content-candidate))
  "Candidate for a content-only update on an unchanged Ebox object tree.
PLAN is the candidate's unchanged object topology with a new text leaf,
RENDERED is the candidate text, RANGES are the candidate-owned content-range
attachments, and PROPERTY-CONTRIBUTIONS are ordered relative range property
layers composed by Ebox during prepare.  CONTEXT authenticates the one-shot
producer result to the active prepare transaction."
  plan rendered ranges property-contributions client-state context
  full-surface-p consumed-p)

(cl-defstruct (ebox--pub-commit-batch (:constructor ebox--pub--make-commit-batch))
  "One precomputed content commit for a stable retained surface topology."
  base-revision target-revision base-extent target-extent patches
  coordinate-patches client-state
  context mount-specs exact-mount-specs-p reuse-mount-projection-p consumed-p)

(cl-defstruct (ebox--pub-surface
               (:constructor ebox--pub--make-surface)
               (:conc-name ebox--pub--surface-))
  "One live retained tree mounted in a buffer."
  id buffer capability start end options producer producer-binding plan objects
  mounts index mount-index ledger client-state revision report live stale
  observers)

(cl-defstruct (ebox--pub-object
               (:constructor ebox--pub--make-surface-object)
               (:conc-name ebox--pub--surface-object-))
  "Opaque retained identity local to one surface."
  id surface parent key kind path live disposed candidate-context)

(cl-defstruct (ebox--pub-prepare-context
               (:constructor ebox--pub--make-prepare-context)
               (:conc-name ebox--pub--context-))
  "Short-lived candidate identity and attachment owner."
  surface objects touched retained bindings attachments fragment-attachments
  content-range-attachments child-seen
  child-positions new-objects created-anchors active ephemeral)

(cl-defstruct (ebox--pub--surface-mount (:constructor ebox--pub--make-surface-mount))
  id object start end tags capability anchor)

(defun ebox--pub--mount-position (position)
  "Return numeric POSITION for a marker or coordinate mount endpoint."
  (if (markerp position) (marker-position position) position))

(cl-defstruct (ebox--pub--property-ledger (:constructor ebox--pub--make-property-ledger))
  start end property baseline-present baseline-value published-present
  published-value anchors)

(cl-defstruct (ebox--pub--prepared-surface (:constructor ebox--pub--make-prepared-surface))
  surface context plan rendered mount-specs ledger-specs property-operations
  objects client-state producer initial created removed moved reconciled
  scope-objects scope-patches scope-fallback live-mounts live-mount-index
  live-ledger report retained-content-p commit-batch
  retained-mount-state-p mount-coordinate-updates mount-coordinate-undo
  baseline-output expected-output)

(cl-defstruct (ebox--pub--surface-snapshot (:constructor ebox--pub--make-surface-snapshot))
  plan objects mounts index mount-index ledger client-state producer revision
  report live stale)

(defvar ebox--pub--surface-id-counter 0)
(defvar ebox--pub--object-id-counter 0)
(defvar ebox--pub--mount-id-counter 0)

(defvar ebox--pub--surface-transaction-id 0)
(defvar ebox--pub--surfaces (make-hash-table :test #'eql :weakness 'value))
(defvar ebox--pub--current-prepare-context nil)
(defvar ebox--pub--surface-publishing nil)
(defvar ebox--pub--surface-guarding-prepare nil)
(defvar ebox--pub--surface-publication-step-function nil)
(defvar ebox--pub--surface-precommit-step-function nil)
(defvar ebox--pub--surface-cleanup-step-function nil)
(defvar ebox--pub--content-published-ranges nil)

(defvar-local ebox--pub--buffer-surfaces nil)
(defvar-local ebox--pub--surface-character-tick 0)
(defvar-local ebox--pub--surface-before-change-state nil)

(defconst ebox--pub--surface-producer-key '(ebox/publication . producer))
(defconst ebox--pub--surface-extension-key 'ebox--pub-surface)

(defun ebox--pub--normalize-surface-observers (observers)
  "Validate OBSERVERS and return them once each, in declaration order."
  (unless (listp observers)
    (signal 'wrong-type-argument (list 'listp observers)))
  (let (normalized)
    (dolist (observer observers)
      (unless (functionp observer)
        (signal 'wrong-type-argument (list 'functionp observer)))
      (unless (memq observer normalized)
        (push observer normalized)))
    (nreverse normalized)))

(defun ebox--pub--surface-observation-clock ()
  "Return the current time for optional surface publication observation."
  (float-time))

(defun ebox--pub--plist-shape-p (value)
  "Return non-nil when VALUE is an even property list with symbol keys."
  (and (listp value)
       (zerop (% (length value) 2))
       (cl-loop for (key _value) on value by #'cddr always (symbolp key))))

(defun ebox--pub--validate-plan-fields (kind text props children capability)
  "Validate plan KIND, TEXT, PROPS, CHILDREN, and CAPABILITY."
  (unless kind
    (signal 'ebox--pub-invalid-surface-plan (list :kind kind)))
  (unless (or (null text) (stringp text))
    (signal 'ebox--pub-invalid-surface-plan (list :text text)))
  (unless (ebox--pub--plist-shape-p props)
    (signal 'ebox--pub-invalid-surface-plan (list :props props)))
  (unless (and (listp children) (cl-every #'ebox--pub-surface-plan-p children))
    (signal 'ebox--pub-invalid-surface-plan (list :children children)))
  (when (and text children)
    (signal 'ebox--pub-invalid-surface-plan (list :text-and-children kind)))
  (unless (memq capability '(nil content))
    (signal 'ebox--pub-capability-error (list capability))))

(defun ebox--pub--validate-sibling-keys (children)
  "Reject duplicate explicit keys among CHILDREN."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (child children)
      (when-let* ((key (ebox--pub-surface-plan-key child)))
        (when (gethash key seen)
          (signal 'ebox--pub-duplicate-object-key (list key)))
        (puthash key t seen)))))

(defun ebox--pub--validate-surface-plan-tree (plan)
  "Validate PLAN recursively without copying its caller-owned values."
  (unless (ebox--pub-surface-plan-p plan)
    (signal 'wrong-type-argument (list 'ebox--pub-surface-plan-p plan)))
  (let ((children (ebox--pub-surface-plan-children plan)))
    (ebox--pub--validate-plan-fields
     (ebox--pub-surface-plan-kind plan)
     (ebox--pub-surface-plan-text plan)
     (ebox--pub-surface-plan-props plan)
     children
     (ebox--pub-surface-plan-capability plan))
    (ebox--pub--validate-sibling-keys children)
    (dolist (child children)
      (ebox--pub--validate-surface-plan-tree child)))
  plan)

(defun ebox--pub--copy-surface-plan (plan &optional cache)
  "Return a validated defensive snapshot of PLAN.  CACHE is shared by one
top-level snapshot so repeated source identities retain one copied identity
across sibling nodes without canonicalizing equal values."
  (unless (ebox--pub-surface-plan-p plan)
    (signal 'wrong-type-argument (list 'ebox--pub-surface-plan-p plan)))
  (let* ((cache (or cache (make-hash-table :test #'eq)))
         (children
          (mapcar (lambda (child)
                    (ebox--pub--copy-surface-plan child cache))
                  (ebox--pub-surface-plan-children plan)))
         (kind (ebox-text--copy-property-value (ebox--pub-surface-plan-kind plan) cache))
         (text (ebox-text--copy-property-value (ebox--pub-surface-plan-text plan) cache))
         (props (ebox-text--copy-property-value (ebox--pub-surface-plan-props plan) cache))
         (capability (ebox--pub-surface-plan-capability plan)))
    (ebox--pub--validate-plan-fields kind text props children capability)
    (ebox--pub--validate-sibling-keys children)
    (ebox--pub--make-surface-plan
     :key (ebox-text--copy-property-value (ebox--pub-surface-plan-key plan) cache)
     :kind kind :text text :props props :children children
     :tags (ebox-text--copy-property-value (ebox--pub-surface-plan-tags plan) cache)
     :capability capability)))

(cl-defun ebox--pub-surface-plan-create
    (&key key kind text props children tags capability)
  "Create a defensive surface plan node.  KEY is sibling-local identity, KIND
is an opaque discriminator, TEXT is a leaf string, PROPS are final direct
text properties, CHILDREN are ordered plans, TAGS are opaque metadata, and
CAPABILITY is `content' or `properties'."
  (ebox--pub--copy-surface-plan
   (ebox--pub--make-surface-plan
    :key key :kind kind :text text :props props :children children
    :tags tags :capability capability)))

(cl-defun ebox--pub-surface-plan-create-owned
    (&key key kind text props children tags capability)
  "Create a candidate-local surface plan without copying its values.  KEY,
KIND, TEXT, PROPS, CHILDREN, TAGS, and CAPABILITY have the same meanings as
in `ebox--pub-surface-plan-create'.  The caller transfers ownership of those
values; after this call they must not be mutated or exposed to another
owner.  Use `ebox--pub-surface-plan-create' for ordinary caller-owned
values."
  (ebox--pub--validate-surface-plan-tree
   (ebox--pub--make-surface-plan
    :key key :kind kind :text text :props props :children children
    :tags tags :capability capability)))

(defun ebox--pub-surface-result-create (plan &optional client-state)
  "Return a producer result containing PLAN and opaque CLIENT-STATE.  Ebox
always renders the submitted plan inside its prepare transaction.  This
keeps the plan as the single authoritative source for published content."
  (ebox--pub--make-surface-result
   (ebox--pub--copy-surface-plan plan) client-state))

(defun ebox--pub-surface-result-create-owned (context plan &optional client-state)
  "Create a one-shot result by adopting candidate-local PLAN.  CONTEXT must be
the active prepare context that owns PLAN.  PLAN and all nested values must
be freshly allocated for that candidate and must not be mutated or exposed
after this call.  CLIENT-STATE is opaque producer state.  Use
`ebox--pub-surface-result-create' for ordinary caller-owned plans."
  (ebox--pub--validate-prepare-context context)
  (unless (eq context ebox--pub--current-prepare-context)
    (signal 'ebox--pub-owned-result-error
            (list :context-not-current context ebox--pub--current-prepare-context)))
  (ebox--pub--make-surface-result
   (ebox--pub--validate-surface-plan-tree plan) client-state t context))

(defun ebox--pub-surface-retained-content-result-create
    (context plan rendered ranges &optional client-state full-surface-p
             property-contributions)
  "Create a one-shot retained content candidate for CONTEXT.  PLAN must
preserve the committed Ebox object topology and contain the new text leaf.
RENDERED is the final propertized text and RANGES are candidate-local
content attachments already associated with PLAN's text leaf.  CLIENT-STATE
is opaque owner state and FULL-SURFACE-P asserts complete scope.
PROPERTY-CONTRIBUTIONS is an ordered list of relative `:start', `:end', and
`:props' plists.  Ebox composes them over RENDERED using registered property
merge policy before diff and publication.  This entry point is intentionally
narrow: callers must prove that object topology is unchanged; Ebox still
validates every object, range, scope, and publication phase."
  (ebox--pub--validate-prepare-context context)
  (unless (eq context ebox--pub--current-prepare-context)
    (signal 'ebox--pub-owned-result-error
            (list :context-not-current context ebox--pub--current-prepare-context)))
  (unless (and (ebox--pub-surface-plan-p plan)
               (stringp rendered)
               (proper-list-p ranges))
    (signal 'ebox--pub-invalid-surface-plan
            (list :retained-content plan rendered ranges)))
  (ebox--pub--make-retained-content-candidate
   :plan plan :rendered rendered :ranges ranges
   :property-contributions property-contributions
   :client-state client-state :context context
   :full-surface-p full-surface-p))

(defun ebox--pub--compose-relative-property-contributions (rendered contributions)
  "Compose ordered relative CONTRIBUTIONS over RENDERED.  Each contribution
contains `:start', `:end', and direct `:props'."
  (unless (proper-list-p contributions)
    (signal 'ebox--pub-invalid-content-range
            (list :property-contributions contributions)))
  (let ((result (copy-sequence rendered))
        (limit (length rendered)))
    (dolist (contribution contributions)
      (let ((start (plist-get contribution :start))
            (end (plist-get contribution :end))
            (props (plist-get contribution :props)))
        (unless (and (integerp start) (integerp end)
                     (<= 0 start) (<= start end) (<= end limit))
          (signal 'ebox--pub-invalid-content-range
                  (list :property-contribution contribution
                        :leaf-length limit)))
        (unless (ebox--pub--plist-shape-p props)
          (signal 'ebox--pub-invalid-surface-plan
                  (list :property-contribution-props props)))
        (cl-loop for (property value) on props by #'cddr
                 do
                 (let ((position start)
                       (merge
                        (ebox-property-policy-merge
                         (ebox-register-text-property property))))
                   (while (< position end)
                     (let* ((next
                             (or (next-single-property-change
                                  position property result end)
                                 end))
                            (cell
                             (plist-member
                              (text-properties-at position result) property))
                            (target
                             (cond
                              ((null value) nil)
                              (cell (funcall merge (cadr cell) value))
                              (t (ebox-text--copy-property-value value)))))
                       (put-text-property position next property target result)
                       (setq position next)))))))
    result))

(defun ebox--pub--property-value-equal-p (property left right)
  "Return non-nil when PROPERTY values LEFT and RIGHT are policy-equal."
  (funcall (ebox-property-policy-equality (ebox-register-text-property property))
           left right))

(defun ebox--pub--plan-props-equal-p (left right)
  "Return non-nil when text property plists LEFT and RIGHT are policy-equal."
  (and (= (length left) (length right))
       (cl-loop for (property value) on left by #'cddr
                for cell = (plist-member right property)
                always (and cell
                            (ebox--pub--property-value-equal-p
                             property value (cadr cell))))))

(defun ebox--pub--plan-equal-p (left right)
  "Return non-nil when LEFT and RIGHT plans are semantically equal."
  (and (equal (ebox--pub-surface-plan-key left) (ebox--pub-surface-plan-key right))
       (equal (ebox--pub-surface-plan-kind left) (ebox--pub-surface-plan-kind right))
       (let ((a (ebox--pub-surface-plan-text left))
             (b (ebox--pub-surface-plan-text right)))
         (if (and (stringp a) (stringp b))
             (ebox--pub--text-property-semantic-equal-p a b)
           (equal a b)))
       (ebox--pub--plan-props-equal-p (ebox--pub-surface-plan-props left)
                               (ebox--pub-surface-plan-props right))
       (equal (ebox--pub-surface-plan-tags left) (ebox--pub-surface-plan-tags right))
       (eq (ebox--pub-surface-plan-capability left)
           (ebox--pub-surface-plan-capability right))
       (let ((a (ebox--pub-surface-plan-children left))
             (b (ebox--pub-surface-plan-children right)))
         (and (= (length a) (length b))
              (cl-every #'identity
                        (cl-mapcar #'ebox--pub--plan-equal-p a b))))))

(defun ebox--pub--hash-copy (table)
  "Return a shallow copy of hash TABLE."
  (let ((copy (make-hash-table :test (hash-table-test table))))
    (maphash (lambda (key value) (puthash key value copy)) table)
    copy))

(defun ebox--pub--context-parent-key (context parent)
  "Return the child-table key for PARENT in CONTEXT."
  (or parent (ebox--pub--context-surface context)))

(defun ebox--pub--context-child-table (context parent)
  "Return CONTEXT's explicit child-key table for PARENT."
  (let* ((owner (ebox--pub--context-parent-key context parent))
         (tables (ebox--pub--context-child-seen context)))
    (or (gethash owner tables)
        (let ((table (make-hash-table :test #'equal)))
          (puthash owner table tables)
          table))))

(defun ebox--pub--context-next-position (context parent)
  "Return and advance CONTEXT's unkeyed child position for PARENT."
  (let* ((owner (ebox--pub--context-parent-key context parent))
         (positions (ebox--pub--context-child-positions context))
         (position (gethash owner positions 0)))
    (puthash owner (1+ position) positions)
    position))

(defun ebox--pub--object-path-segment (context parent key kind)
  "Return CONTEXT's candidate path segment for KEY and KIND below PARENT."
  (if key
      (let ((seen (ebox--pub--context-child-table context parent)))
        (when (gethash key seen)
          (signal 'ebox--pub-duplicate-object-key (list key)))
        (puthash key t seen)
        key)
    (list :position (ebox--pub--context-next-position context parent) :kind kind)))

(defun ebox--pub--validate-context-parent (context parent)
  "Validate PARENT for candidate CONTEXT."
  (when parent
    (unless (ebox--pub-object-p parent)
      (signal 'wrong-type-argument (list 'ebox--pub-object-p parent)))
    (unless (eq (ebox--pub--surface-object-surface parent)
                (ebox--pub--context-surface context))
      (signal 'ebox--pub-cross-surface-object (list parent)))
    (unless (gethash (ebox--pub--surface-object-path parent)
                     (ebox--pub--context-objects context))
      (signal 'ebox--pub-stale-object (list parent)))))

(defun ebox--pub--validate-prepare-context (context)
  "Signal unless CONTEXT is active."
  (unless (and (ebox--pub-prepare-context-p context) (ebox--pub--context-active context))
    (signal 'ebox--pub-invalid-prepare-context (list context))))

(defun ebox--pub--new-candidate-object (context parent key kind path)
  "Create a candidate object for KEY and KIND in CONTEXT below PARENT at PATH."
  (let ((object (ebox--pub--make-surface-object
                 :id (cl-incf ebox--pub--object-id-counter)
                 :surface (ebox--pub--context-surface context) :parent parent
                 :key (ebox-text--copy-property-value key)
                 :kind kind :path path
                 :candidate-context context)))
    (push object (ebox--pub--context-new-objects context))
    object))

(defun ebox--pub-object-ensure (context parent key kind)
  "Return candidate identity for KEY and KIND below PARENT in CONTEXT."
  (ebox--pub--validate-prepare-context context)
  (ebox--pub--validate-context-parent context parent)
  (unless kind
    (signal 'ebox--pub-invalid-surface-plan (list :kind kind)))
  (let* ((segment (ebox--pub--object-path-segment context parent key kind))
         (path (append (and parent (ebox--pub--surface-object-path parent))
                       (list segment)))
         (objects (ebox--pub--context-objects context))
         (old (gethash path objects))
         (object (if (and old (equal kind (ebox--pub--surface-object-kind old)))
                     old
                   (ebox--pub--new-candidate-object context parent key kind path))))
    (puthash path object objects)
    (puthash object t (ebox--pub--context-touched context))
    object))

(defun ebox--pub-object-live-p (object)
  "Return non-nil when OBJECT is committed on a live surface."
  (and (ebox--pub-object-p object) (ebox--pub--surface-object-live object)
       (not (ebox--pub--surface-object-disposed object))
       (ebox--pub-surface-live-p (ebox--pub--surface-object-surface object))))

(defun ebox--pub-object-mounted-p (object)
  "Return non-nil when live OBJECT owns at least one published mount.  This
predicate does not copy mount tags; use `ebox--pub-object-mounts' when
callers need the public coordinate and metadata snapshots."
  (unless (ebox--pub-object-live-p object)
    (signal 'ebox--pub-stale-object (list object)))
  (and (gethash object
                (ebox--pub--surface-mount-index
                 (ebox--pub--surface-object-surface object)))
       t))

(defun ebox--pub-object-mounts (object)
  "Return OBJECT's live numeric mount ranges and opaque tags.  Each result is a
plist with `:start', `:end', and `:tags'.  Marker objects remain private so
callers cannot mutate Ebox's publication coordinates."
  (unless (ebox--pub-object-live-p object)
    (signal 'ebox--pub-stale-object (list object)))
  (let* ((surface (ebox--pub--surface-object-surface object))
         (mounts (gethash object (ebox--pub--surface-mount-index surface))))
    (mapcar
     (lambda (mount)
       (list :start (ebox--pub--mount-position (ebox--pub--surface-mount-start mount))
             :end (ebox--pub--mount-position (ebox--pub--surface-mount-end mount))
             :tags (ebox-text--copy-property-value
                    (ebox--pub--surface-mount-tags mount))))
     mounts)))

(defun ebox--pub--make-context (surface &optional ephemeral)
  "Create a prepare context for SURFACE.  When EPHEMERAL is non-nil, no
identity may be promoted."
  (ebox--pub--make-prepare-context
   :surface surface
   :objects (if (ebox--pub--surface-objects surface)
                (ebox--pub--hash-copy (ebox--pub--surface-objects surface))
              (make-hash-table :test #'equal))
   :touched (make-hash-table :test #'eq)
   :retained (make-hash-table :test #'eq)
   :bindings (make-hash-table :test #'eq)
   :attachments (make-hash-table :test #'eq)
   :fragment-attachments (make-hash-table :test #'eq)
         :content-range-attachments (make-hash-table :test #'eq)
   :child-seen (make-hash-table :test #'eq)
   :child-positions (make-hash-table :test #'eq)
   :active t :ephemeral ephemeral))

(defun ebox--pub--validate-context-object (context object)
  "Require OBJECT to be a candidate in active CONTEXT."
  (ebox--pub--validate-prepare-context context)
  (unless (and (ebox--pub-object-p object)
               (eq (ebox--pub--surface-object-surface object)
                   (ebox--pub--context-surface context))
               (or (gethash object (ebox--pub--context-touched context))
                   (gethash object (ebox--pub--context-retained context))))
    (signal 'ebox--pub-stale-object (list object))))

(defun ebox--pub-object-retain (context object)
  "Retain candidate OBJECT in CONTEXT even when it owns no output fragment."
  (ebox--pub--validate-context-object context object)
  (puthash object t (ebox--pub--context-retained context))
  object)

(defun ebox--pub-object-reuse (context object)
  "Reuse one proven unchanged live OBJECT in CONTEXT.  The object and its live
bindings remain in the candidate without being marked as touched.  The
caller owns the proof that identity, parent path, output, and lifecycle are
unchanged."
  (ebox--pub--validate-prepare-context context)
  (unless (ebox--pub-object-p object)
    (signal 'wrong-type-argument (list 'ebox--pub-object-p object)))
  (let* ((surface (ebox--pub--context-surface context))
         (path (ebox--pub--surface-object-path object))
         (objects (ebox--pub--context-objects context)))
    (unless (and (ebox--pub-object-live-p object)
                 (eq (ebox--pub--surface-object-surface object) surface)
                 (eq object (gethash path objects)))
      (signal 'ebox--pub-stale-object (list object)))
    (puthash object t (ebox--pub--context-retained context))
    (dolist (binding (ebox--pub-binding-owner-bindings object))
      (when (ebox--pub-binding-live-p binding)
        (puthash binding t (ebox--pub--context-bindings context)))))
  object)

(defun ebox--pub--object-path-prefix-p (prefix path)
  "Return non-nil when PREFIX is a path prefix of PATH."
  (and (<= (length prefix) (length path))
       (equal prefix (cl-subseq path 0 (length prefix)))))

(defun ebox--pub-object-reuse-subtree (context root)
  "Reuse a proven unchanged live subtree in CONTEXT.  ROOT must be a live
object already owned by CONTEXT's surface.  The subtree's objects and live
bindings remain in the candidate, but are not marked touched or reconciled.
The caller must still provide a complete candidate plan and prove that the
subtree's identity, output, and lifecycle are unchanged."
  (ebox--pub--validate-prepare-context context)
  (unless (ebox--pub-object-p root)
    (signal 'wrong-type-argument (list 'ebox--pub-object-p root)))
  (let* ((surface (ebox--pub--context-surface context))
         (path (ebox--pub--surface-object-path root))
         (objects (ebox--pub--context-objects context)))
    (unless (and (ebox--pub-object-live-p root)
                 (eq root (gethash path objects)))
      (signal 'ebox--pub-stale-object (list root)))
    (maphash
     (lambda (_candidate-path object)
       (when (ebox--pub--object-path-prefix-p
              path (ebox--pub--surface-object-path object))
         (unless (and (eq (ebox--pub--surface-object-surface object) surface)
                      (ebox--pub-object-live-p object))
           (signal 'ebox--pub-stale-object (list object)))
         (puthash object t (ebox--pub--context-retained context))
         (dolist (binding (ebox--pub-binding-owner-bindings object))
           (when (ebox--pub-binding-live-p binding)
             (puthash binding t (ebox--pub--context-bindings context))))))
     objects))
  root)

(defun ebox--pub--validate-content-range (start end)
  "Signal unless START and END describe a nonempty local leaf range."
  (unless (and (integerp start) (integerp end)
               (>= start 0) (> end start))
    (signal 'ebox--pub-invalid-content-range (list :start start :end end))))

(defun ebox--pub--copy-content-range-tags (tags &optional copies)
  "Return a defensive copy of non-nil content-range TAGS.  COPIES, when
non-nil, is a call-local `eq' cache owned by one bulk attach operation.  A
singular attach always snapshots TAGS independently, so later caller
mutation cannot alter an earlier attachment."
  (if (null tags)
      nil
    (let ((copy (and copies (gethash tags copies))))
      (or copy
          (let ((copy (ebox-text--copy-property-value tags)))
            (when copies
              (puthash tags copy copies))
            copy)))))

(defun ebox--pub--attach-content-ranges (context leaf ranges copy-tags-p)
  "Attach RANGES to LEAF for CONTEXT, copying TAGS when COPY-TAGS-P is non-nil."
  (ebox--pub--validate-context-object context leaf)
  (let ((attachments (gethash leaf
                              (ebox--pub--context-content-range-attachments context)))
        (copies (and copy-tags-p (make-hash-table :test #'eq)))
        added)
    (dolist (range ranges)
      (let ((object (plist-get range :object))
            (start (plist-get range :start))
            (end (plist-get range :end))
            (tags (plist-get range :tags)))
        (ebox--pub--validate-context-object context object)
        (ebox--pub--validate-content-range start end)
        (push (list :object object :start start :end end
                    :tags (if copy-tags-p
                              (ebox--pub--copy-content-range-tags tags copies)
                            tags))
              added)
        (unless (gethash object (ebox--pub--context-retained context))
          (ebox--pub-object-retain context object))))
    (puthash leaf (nconc added attachments)
             (ebox--pub--context-content-range-attachments context)))
  ranges)

(defun ebox--pub-object-attach-content-ranges-owned (context leaf ranges)
  "Attach candidate RANGES to LEAF for CONTEXT with owned TAGS snapshots.  Use
this only when each non-nil TAGS value was freshly allocated for the
candidate and will not be mutated or exposed to caller mutation after this
call.  Ebox transfers those values without copying; failed candidates
discard the transferred values with the rest of their prepare state."
  (ebox--pub--attach-content-ranges context leaf ranges nil))

(defun ebox--pub--touch-context-binding (context binding)
  "Record BINDING as touched by CONTEXT."
  (let ((owner (ebox--pub-binding-owner binding)))
    (unless (and (ebox--pub-object-p owner)
                 (eq (ebox--pub--surface-object-surface owner)
                     (ebox--pub--context-surface context)))
      (signal 'ebox--pub-cross-surface-object (list owner)))
    (puthash binding t (ebox--pub--context-bindings context))))

(defun ebox--pub--plist-overlay (parent child &optional owned-p)
  "Return a fresh plist where CHILD values override PARENT values.  When
OWNED-P is non-nil, reuse candidate-owned property values while copying only
the plist spine.  The non-owned path keeps the defensive value copies needed
by ordinary Ebox callers."
  (let ((result (if owned-p
                    (copy-sequence parent)
                  (ebox-text--copy-property-value parent))))
    (cl-loop for (property value) on child by #'cddr
             do (setq result
                      (plist-put result property
                                 (if owned-p
                                     value
                                   (ebox-text--copy-property-value value)))))
    result))

(defun ebox--pub--plan-segment (plan position)
  "Return PLAN's path segment at sibling POSITION."
  (or (ebox--pub-surface-plan-key plan)
      (list :position position :kind (ebox--pub-surface-plan-kind plan))))

(defun ebox--pub--render-plan (plan context &optional owned-p)
  "Return PLAN's propertized string and side records in CONTEXT.  OWNED-P
transfers candidate-local property values through the render pass."
  (let (records)
    (cl-labels
        ((walk (node path inherited offset)
           (let* ((props (ebox--pub--plist-overlay
                          inherited (ebox--pub-surface-plan-props node) owned-p))
                  (begin offset)
                  (children (ebox--pub-surface-plan-children node))
                  pieces)
             (if children
                 (cl-loop for child in children for position from 0
                          for child-path =
                          (append path (list (ebox--pub--plan-segment child position)))
                          for result = (walk child child-path props offset)
                          do (push (car result) pieces)
                          do (setq offset (cdr result)))
               (let ((text (copy-sequence
                            (or (ebox--pub-surface-plan-text node) ""))))
                 (when (> (length text) 0)
                   (add-text-properties 0 (length text) props text))
                 (push text pieces)
                 (setq offset (+ offset (length text)))))
             (let ((object (gethash path (ebox--pub--context-objects context))))
               (unless object
                 (signal 'ebox--pub-orphan-object (list path)))
               (push (list :path path :object object :start begin :end offset
                           :props props :tags (ebox--pub-surface-plan-tags node)
                           :leaf (null children))
                     records))
             (cons (apply #'concat (nreverse pieces)) offset))))
      (let* ((path (list (ebox--pub--plan-segment plan 0)))
             (result (walk plan path nil 0)))
        (cons (car result) (nreverse records))))))

(defun ebox--pub--ensure-plan-objects (context plan &optional parent)
  "Ensure identities for PLAN recursively below PARENT in CONTEXT."
  (let ((object (ebox--pub-object-ensure
                 context parent (ebox--pub-surface-plan-key plan)
                 (ebox--pub-surface-plan-kind plan))))
    (dolist (child (ebox--pub-surface-plan-children plan))
      (ebox--pub--ensure-plan-objects context child object))
    object))

(defun ebox--pub--plan-paths (plan)
  "Return PLAN's object paths in traversal order."
  (let (paths)
    (cl-labels
        ((walk (node path)
           (push path paths)
           (cl-loop for child in (ebox--pub-surface-plan-children node)
                    for position from 0
                    do (walk child
                             (append path
                                     (list (ebox--pub--plan-segment child position)))))))
      (walk plan (list (ebox--pub--plan-segment plan 0))))
    (nreverse paths)))

(defun ebox--pub--validate-context-tree (context plan)
  "Validate PLAN and CONTEXT's retained and fragment object paths."
  (let ((expected (make-hash-table :test #'equal))
        (actual (make-hash-table :test #'equal)))
    (dolist (path (ebox--pub--plan-paths plan)) (puthash path t expected))
    (maphash
     (lambda (_path object)
       (when (or (gethash object (ebox--pub--context-touched context))
                 (gethash object (ebox--pub--context-retained context)))
         (puthash (ebox--pub--surface-object-path object) object actual)))
     (ebox--pub--context-objects context))
    (maphash
     (lambda (path _present)
       (unless (gethash path actual)
        (signal 'ebox--pub-orphan-object (list :missing path))))
     expected)
    (maphash
     (lambda (path object)
       (unless (or (gethash path expected)
                   (gethash object (ebox--pub--context-retained context)))
         (signal 'ebox--pub-orphan-object (list :extra path))))
     actual)
    (maphash
     (lambda (fragment _attachments)
       (unless (gethash (ebox--pub--surface-object-path fragment) expected)
         (signal 'ebox--pub-orphan-object
                 (list :unplanned-fragment
                       (ebox--pub--surface-object-path fragment)))))
     (ebox--pub--context-fragment-attachments context))))

(defun ebox--pub--validate-plan-capability (plan capability)
  "Validate PLAN recursively against mount CAPABILITY."
  (let ((declared (ebox--pub-surface-plan-capability plan)))
    (when (and declared (not (eq declared capability)))
      (signal 'ebox--pub-capability-error (list declared capability)))
    (when (and nil (ebox--pub-surface-plan-text plan))
      (signal 'ebox--pub-capability-error (list :properties-text)))
    (dolist (child (ebox--pub-surface-plan-children plan))
      (ebox--pub--validate-plan-capability child capability))))

(defun ebox--pub--producer-result (value surface options context)
  "Normalize producer VALUE for SURFACE and active CONTEXT using OPTIONS."
  (cond
   ((ebox--pub-commit-batch-p value)
    (unless (and context
                 (ebox--pub--context-active context)
                 (eq context ebox--pub--current-prepare-context)
                 (eq context (ebox--pub-commit-batch-context value))
                 (not (ebox--pub-commit-batch-consumed-p value)))
      (signal 'ebox--pub-owned-result-error (list value context)))
    (setf (ebox--pub-commit-batch-consumed-p value) t
          (ebox--pub-commit-batch-context value) nil)
    (list :commit-batch value))
   ((ebox--pub-retained-content-candidate-p value)
    (unless (and context
                 (ebox--pub--context-active context)
                 (eq context ebox--pub--current-prepare-context)
                 (eq context
                     (ebox--pub-retained-content-candidate-context value))
                 (not (ebox--pub-retained-content-candidate-consumed-p value)))
      (signal 'ebox--pub-owned-result-error (list value context)))
    (setf (ebox--pub-retained-content-candidate-consumed-p value) t
          (ebox--pub-retained-content-candidate-context value) nil)
    (list :retained-content value))
   ((ebox--pub-surface-result-p value)
    (let ((owned-p (ebox--pub-surface-result-plan-owned-p value)))
      (if owned-p
          (progn
            (unless (and context
                         (ebox--pub--context-active context)
                         (eq context ebox--pub--current-prepare-context)
                         (eq context (ebox--pub-surface-result-owner-context value))
                         (not (ebox--pub-surface-result-consumed-p value)))
              (signal 'ebox--pub-owned-result-error (list value context)))
              (let ((plan (ebox--pub-surface-result-plan value))
                  (client-state (ebox--pub-surface-result-client-state value)))
              (setf (ebox--pub-surface-result-consumed-p value) t
                    (ebox--pub-surface-result-plan value) nil
                    (ebox--pub-surface-result-client-state value) nil
                    (ebox--pub-surface-result-owner-context value) nil)
              (list plan client-state t)))
        (list (ebox--pub--copy-surface-plan (ebox--pub-surface-result-plan value))
              (ebox--pub-surface-result-client-state value) nil))))
   ((ebox--pub-surface-plan-p value)
   (list value
          (if (plist-member options :client-state)
              (plist-get options :client-state)
            (ebox--pub--surface-client-state surface))
          nil))
   (t (signal 'ebox--pub-invalid-surface-plan (list value)))))

(defun ebox--pub--context-binding-removals (context objects)
  "Return default-lifecycle bindings omitted from CONTEXT among OBJECTS."
  (cl-loop for object in objects append
           (cl-loop for binding in (ebox--pub-binding-owner-bindings object)
                    unless (or (gethash binding (ebox--pub--context-bindings context))
                               (eq (ebox--pub-binding-lifecycle binding) 'retain))
                    collect binding)))

(defun ebox--pub--context-live-objects (surface)
  "Return SURFACE's current objects."
  (let (objects)
    (when (ebox--pub--surface-objects surface)
      (maphash (lambda (_path object) (push object objects))
               (ebox--pub--surface-objects surface)))
    objects))

(defun ebox--pub--object-set-difference (left right)
  "Return objects in LEFT that are not `eq' to an object in RIGHT."
  (cl-remove-if (lambda (object) (memq object right)) left))

(defun ebox--pub--plan-key-positions (plan)
  "Return an alist from PLAN keyed paths to sibling positions."
  (let (positions)
    (cl-labels
        ((walk (node path)
           (cl-loop for child in (ebox--pub-surface-plan-children node)
                    for position from 0
                    for key = (ebox--pub-surface-plan-key child)
                    for child-path = (and key (append path (list key)))
                    when key do (push (cons child-path position) positions)
                    do (walk child
                             (or child-path
                                 (append path
                                         (list (ebox--pub--plan-segment
                                                child position))))))))
      (walk plan (list (ebox--pub--plan-segment plan 0))))
    positions))

(defun ebox--pub--plan-moved-count (old new)
  "Return the number of keyed objects moved between OLD and NEW plans."
  (if (null old)
      0
    (let ((old-positions (ebox--pub--plan-key-positions old)))
      (cl-loop for (path . position) in (ebox--pub--plan-key-positions new)
               for old-position = (alist-get path old-positions nil nil #'equal)
               count (and old-position (/= old-position position))))))

(defun ebox--pub--candidate-object-list (context)
  "Return CONTEXT's touched and retained candidate objects."
  (let (objects)
    (maphash
     (lambda (_path object)
       (when (or (gethash object (ebox--pub--context-touched context))
                 (gethash object (ebox--pub--context-retained context)))
         (push object objects)))
     (ebox--pub--context-objects context))
    objects))

(defun ebox--pub--candidate-reconciled-count (context created)
  "Return the number of touched retained objects in CONTEXT excluding CREATED."
  (- (hash-table-count (ebox--pub--context-touched context))
     (length created)))

(defun ebox--pub--content-mount-spec (object record &optional tags tags-owned-p)
  "Return one content mount spec for OBJECT over RECORD with TAGS.
TAGS-OWNED-P skips a second snapshot when TAGS already belongs to the
candidate."
  (list :object object :start (plist-get record :start)
        :end (plist-get record :end)
        :tags (if tags-owned-p
                  tags
                (ebox-text--copy-property-value
                 (if tags tags (plist-get record :tags))))))

(defun ebox--pub--content-mount-specs (records context)
  "Return direct and logical range mount specs for RECORDS in CONTEXT."
  (let (specs)
    (dolist (record records)
      (let* ((leaf (plist-get record :object))
             (fragment-attachments
              (nreverse
               (copy-sequence
                (gethash leaf
                         (ebox--pub--context-fragment-attachments context)))))
             (range-attachments
              (nreverse
               (copy-sequence
                (gethash leaf
                         (ebox--pub--context-content-range-attachments context))))))
        (push (ebox--pub--content-mount-spec leaf record) specs)
        (dolist (attachment fragment-attachments)
          (push (ebox--pub--content-mount-spec
                 (car attachment) record (cdr attachment) t)
                specs))
        (when range-attachments
          (unless (plist-get record :leaf)
            (signal 'ebox--pub-invalid-content-range
                    (list :leaf leaf :reason 'not-a-text-leaf)))
          (let ((leaf-start (plist-get record :start))
                (leaf-length (- (plist-get record :end)
                                (plist-get record :start))))
            (dolist (attachment range-attachments)
              (let ((start (plist-get attachment :start))
                    (end (plist-get attachment :end)))
                (unless (and (<= end leaf-length)
                             (<= start end))
                  (signal 'ebox--pub-invalid-content-range
                          (list :start start :end end
                                :leaf-length leaf-length)))
                (push (list :object (plist-get attachment :object)
                            :start (+ leaf-start start)
                            :end (+ leaf-start end)
                            :tags (plist-get attachment :tags))
                      specs)))))))
    (nreverse specs)))

(defun ebox--pub--plan-record-mount-specs (records _capability context)
  "Build candidate mount specs from RECORDS for CAPABILITY in CONTEXT."
  (ebox--pub--content-mount-specs records context))

(defun ebox--pub--ranges-overlap-p (left-start left-end right-start right-end)
  "Return non-nil when LEFT-START..LEFT-END overlaps RIGHT-START..RIGHT-END."
  (and (< left-start left-end) (< right-start right-end)
       (< left-start right-end) (< right-start left-end)))

(defun ebox--pub--candidate-ranges (surface _mount-specs rendered)
  "Return SURFACE ranges described by MOUNT-SPECS and RENDERED."
  (let ((start (marker-position (ebox--pub--surface-start surface))))
    (list (cons start (+ start (length rendered))))))

(defun ebox--pub--validate-cross-surface-ranges (surface mount-specs rendered)
  "Reject MOUNT-SPECS and RENDERED when SURFACE overlaps another surface."
  (let ((ranges (ebox--pub--candidate-ranges surface mount-specs rendered)))
    (with-current-buffer (ebox--pub--surface-buffer surface)
      (dolist (other ebox--pub--buffer-surfaces)
        (unless (eq other surface)
          (dolist (mount (ebox--pub--surface-mounts other))
            (let ((start (ebox--pub--mount-position (ebox--pub--surface-mount-start mount)))
                  (end (ebox--pub--mount-position (ebox--pub--surface-mount-end mount))))
              (when (cl-some (lambda (range)
                               (ebox--pub--ranges-overlap-p
                                (car range) (cdr range) start end))
                             ranges)
                (signal 'ebox--pub-capability-error
                        (list :cross-surface-overlap
                              (ebox--pub--surface-id other)))))))))))

(defun ebox--pub--prepare-input (surface input options context)
  "Run INPUT for SURFACE in CONTEXT and normalize its result."
  (let ((ebox--pub--current-prepare-context context)
        (ebox--pub--binding-touch-function
         (lambda (binding) (ebox--pub--touch-context-binding context binding))))
    (if (functionp input)
      (ebox--pub--producer-result (funcall input context) surface options context)
      (let ((plan input))
        (ebox--pub--ensure-plan-objects context plan)
        (list plan
              (if (plist-member options :client-state)
                  (plist-get options :client-state)
                (ebox--pub--surface-client-state surface)))))))

(defun ebox--pub--call-with-prepare-buffer-guard (surface function)
  "Call FUNCTION while rejecting producer edits to SURFACE's buffer."
  (let* ((buffer (ebox--pub--surface-buffer surface))
         (before-tick (with-current-buffer buffer
                        (buffer-modified-tick)))
         (group (ebox--pub--prepare-change-group-for-buffers (list buffer)))
         (ebox--pub--surface-guarding-prepare t))
    (unwind-protect
        (let ((result (funcall function)))
          (unless (= before-tick
                     (with-current-buffer buffer
                       (buffer-modified-tick)))
            (signal 'ebox--pub-producer-buffer-mutation
                    (list (ebox--pub--surface-id surface))))
          result)
      (ebox--pub--cancel-change-group-safely group))))

(defun ebox--pub--normalize-surface-scopes (surface objects)
  "Return validated retained OBJECTS owned by SURFACE."
  (unless (and (proper-list-p objects) objects)
    (signal 'wrong-type-argument (list 'non-empty-proper-list-p objects)))
  (setq objects
        (cl-delete-duplicates (copy-sequence objects) :test #'eq))
  (dolist (object objects)
    (unless (ebox--pub-object-p object)
      (signal 'wrong-type-argument (list 'ebox--pub-object-p object)))
    (unless (ebox--pub-object-live-p object)
      (signal 'ebox--pub-stale-object (list object)))
    (unless (eq (ebox--pub--surface-object-surface object) surface)
      (signal 'ebox--pub-cross-surface-object (list object surface))))
  objects)

(defun ebox--pub--coalesce-ranges (ranges)
  "Return sorted, merged nonempty RANGES."
  (setq ranges
        (sort (cl-remove-if (lambda (range) (>= (car range) (cdr range)))
                            (mapcar (lambda (range)
                                      (cons (car range) (cdr range)))
                                    ranges))
              (lambda (left right) (< (car left) (car right)))))
  (let (merged)
    (dolist (range ranges (nreverse merged))
      (if (and merged (<= (car range) (cdar merged)))
          (setcdr (car merged) (max (cdar merged) (cdr range)))
        (push range merged)))))

(defun ebox--pub--subtract-ranges (ranges exclusions)
  "Return RANGES with EXCLUSIONS removed.  Both arguments contain numeric
half-open relative intervals."
  (let (result)
    (dolist (range ranges (nreverse result))
      (let ((cursor (car range))
            (end (cdr range)))
        (dolist (exclusion exclusions)
          (when (and (< cursor end) (> (cdr exclusion) cursor))
            (when (< cursor (car exclusion))
              (push (cons cursor (min end (car exclusion))) result))
            (setq cursor (max cursor (cdr exclusion)))))
        (when (< cursor end)
          (push (cons cursor end) result))))))

(defun ebox--pub--live-scope-ranges (surface objects &optional relative)
  "Return live mount ranges for OBJECTS on SURFACE.  When RELATIVE is non-nil,
return offsets from the surface start."
  (let ((base (if relative
                  (marker-position (ebox--pub--surface-start surface))
                0))
        ranges)
    (dolist (object objects)
      (dolist (mount (gethash object (ebox--pub--surface-mount-index surface)))
        (let ((start (ebox--pub--mount-position (ebox--pub--surface-mount-start mount)))
              (end (ebox--pub--mount-position (ebox--pub--surface-mount-end mount))))
          (unless (and start end)
            (signal 'ebox--pub-stale-mount (list object)))
          (push (cons (- start base) (- end base)) ranges))))
    (ebox--pub--coalesce-ranges ranges)))

(defun ebox--pub--candidate-scope-ranges (mount-specs objects)
  "Return relative candidate MOUNT-SPECS ranges owned by OBJECTS."
  (let ((scope-set (make-hash-table :test #'eq)) ranges)
    (dolist (object objects) (puthash object t scope-set))
    (dolist (spec mount-specs)
      (when (gethash (plist-get spec :object) scope-set)
        (push (cons (plist-get spec :start) (plist-get spec :end)) ranges)))
    (ebox--pub--coalesce-ranges ranges)))

(defun ebox--pub--surface-content-string (surface)
  "Return SURFACE's current propertized content string."
  (pcase-let ((`(,start . ,end) (ebox--pub--surface-range surface)))
    (with-current-buffer (ebox--pub--surface-buffer surface)
      (save-restriction
        (widen)
        (buffer-substring start end)))))

(defun ebox--pub--complement-ranges (length ranges)
  "Return the nonempty complement of RANGES inside zero to LENGTH."
  (let ((cursor 0) complement)
    (dolist (range ranges)
      (when (< cursor (car range))
        (push (cons cursor (car range)) complement))
      (setq cursor (cdr range)))
    (when (< cursor length)
      (push (cons cursor length) complement))
    (nreverse complement)))

(defun ebox--pub--substring-ranges (string ranges)
  "Return STRING content from RANGES concatenated with properties."
  (apply #'concat
         (mapcar (lambda (range)
                   (substring string (car range) (cdr range)))
                 ranges)))

(defun ebox--pub--pair-outside-ranges (old-ranges new-ranges)
  "Pair equal-length pieces of OLD-RANGES and NEW-RANGES in order."
  (let ((old-ranges (copy-tree old-ranges))
        (new-ranges (copy-tree new-ranges))
        pairs)
    (while (and old-ranges new-ranges)
      (let* ((old (car old-ranges))
             (new (car new-ranges))
             (length (min (- (cdr old) (car old))
                          (- (cdr new) (car new)))))
        (push (list (car old) (+ (car old) length)
                    (car new) (+ (car new) length))
              pairs)
        (setcar old-ranges (cons (+ (car old) length) (cdr old)))
        (setcar new-ranges (cons (+ (car new) length) (cdr new)))
        (when (= (caar old-ranges) (cdar old-ranges)) (pop old-ranges))
        (when (= (caar new-ranges) (cdar new-ranges)) (pop new-ranges))))
    (nreverse pairs)))

(defun ebox--pub--mouse-face-groups-equal-p
    (left left-start left-end right right-start right-end)
  "Compare native hover boundaries in LEFT and RIGHT without comparing
identities.  LEFT-START..LEFT-END and RIGHT-START..RIGHT-END delimit
equal-length ranges.  Each snapshot may own different face objects, but its
contiguous grouping must agree.  Native interval traversal requires no
property-value copies."
  (let ((match t))
    (while (and match (< left-start left-end))
      (let ((left-next (next-single-property-change
                        left-start 'mouse-face left left-end))
            (right-next (next-single-property-change
                         right-start 'mouse-face right right-end)))
        (setq match (= (- left-next left-start) (- right-next right-start))
              left-start left-next right-start right-next)))
    (and match (= left-start left-end) (= right-start right-end))))

(defun ebox--pub--text-property-semantic-equal-p (left right)
  "Return non-nil when propertized strings LEFT and RIGHT are policy-equal."
  (when (and (stringp left)
             (stringp right)
             (= (length left) (length right)))
    ;; Compare characters once.  The property loop below visits only
    ;; property-boundary positions, avoiding a substring/all-runs allocation
    ;; on every scoped update.
    (and (equal (substring-no-properties left)
                (substring-no-properties right))
         (ebox--pub--mouse-face-groups-equal-p left 0 (length left)
                                       right 0 (length right))
         (let ((position 0)
               (limit (length left))
               equal-p)
           (setq equal-p t)
           (while (and equal-p (< position limit))
             (unless (ebox--pub--plan-props-equal-p
                      (text-properties-at position left)
                      (text-properties-at position right))
               (setq equal-p nil))
             (setq position
                   (min (or (next-property-change position left limit) limit)
                        (or (next-property-change position right limit) limit))))
           equal-p))))

(defun ebox--pub--layout-separator-only-p (text)
  "Return non-nil when TEXT contains only layout line separators."
  (and (stringp text)
       (cl-every (lambda (char) (= char ?\n))
                 (substring-no-properties text))))

(defun ebox--pub--scope-outside-separator-equivalent-p (left right)
  "Return non-nil when scoped outside gaps LEFT and RIGHT are separators.
Logical Ebox owners may absorb a newline between two owned rendered runs
when one candidate line grows or shrinks.  Treating that delimiter as part
of the owner preserves scoped publication while still rejecting every
non-separator outside change."
  (and (ebox--pub--layout-separator-only-p left)
       (ebox--pub--layout-separator-only-p right)))

(defun ebox--pub--scope-patches-between-anchors (old new anchors)
  "Return patches between equal outside ANCHORS in OLD and NEW."
  (let ((old-position 0) (new-position 0) patches)
    (dolist (anchor (append anchors
                            (list (list (length old) (length old)
                                        (length new) (length new)))))
      (let* ((old-end (nth 0 anchor))
             (new-end (nth 2 anchor))
             (replacement (substring new new-position new-end)))
        (unless (ebox--pub--text-property-semantic-equal-p
                 (substring old old-position old-end) replacement)
          (push (list :old-start old-position :old-end old-end
                      :new-start new-position :new-end new-end
                      :replacement replacement)
                patches)))
      (setq old-position (nth 1 anchor)
            new-position (nth 3 anchor)))
    (nreverse patches)))

(defun ebox--pub--scope-replacement-analysis (old new old-ranges new-ranges)
  "Compare OLD-RANGES and NEW-RANGES from OLD to NEW.  Return scoped
replacement metadata, or nil on mismatch."
  (let* ((old-outside (ebox--pub--complement-ranges (length old) old-ranges))
         (new-outside (ebox--pub--complement-ranges (length new) new-ranges))
         (anchors (ebox--pub--pair-outside-ranges old-outside new-outside))
         previous)
    (when
        (or
         (and (= (cl-loop for (start . end) in old-outside sum (- end start))
                 (cl-loop for (start . end) in new-outside sum (- end start)))
              (cl-every
               (lambda (anchor)
                 (pcase-let ((`(,old-start ,old-end ,new-start ,new-end) anchor))
                   (prog1
                       (and
                        ;; Only real adjacent intervals have a shared hover
                        ;; boundary.  A removed scope must not create one.
                        (or (null previous)
                            (/= (nth 1 previous) old-start)
                            (/= (nth 3 previous) new-start)
                            (eq (eq (get-text-property (1- old-start) 'mouse-face old)
                                    (get-text-property old-start 'mouse-face old))
                                (eq (get-text-property (1- new-start) 'mouse-face new)
                                    (get-text-property new-start 'mouse-face new))))
                        (ebox--pub--shadow-text-range-equal-p
                         old old-start old-end new new-start new-end))
                     (setq previous anchor))))
               anchors))
         (ebox--pub--scope-outside-separator-equivalent-p
          (ebox--pub--substring-ranges old old-outside)
          (ebox--pub--substring-ranges new new-outside)))
      (list :patches (ebox--pub--scope-patches-between-anchors old new anchors)))))

(defun ebox--pub--prepare-content-scope
    (surface rendered mount-specs objects options)
  "Return scoped publication metadata for RENDERED on SURFACE.  MOUNT-SPECS
describe the candidate OBJECTS.  OPTIONS accepts `:on-mismatch' as `error'
or `root'."
  (let* ((old (ebox--pub--surface-content-string surface))
         (old-ranges (ebox--pub--live-scope-ranges surface objects t))
         (new-ranges (ebox--pub--candidate-scope-ranges mount-specs objects))
         (analysis
          (ebox--pub--scope-replacement-analysis
           old rendered old-ranges new-ranges)))
    (cond
     (analysis (list :patches (plist-get analysis :patches) :fallback nil))
     ((eq (plist-get options :on-mismatch) 'root)
      (list :patches nil :fallback t))
     (t
      (signal 'ebox--pub-scope-mismatch
              (list :surface (ebox--pub--surface-id surface)
                    :old-ranges old-ranges :new-ranges new-ranges))))))

(defun ebox--pub--prepare-retained-content
    (surface candidate context scope-objects scope-options initial)
  "Prepare CANDIDATE for SURFACE in CONTEXT without traversing its plan.
SCOPE-OBJECTS and SCOPE-OPTIONS constrain publication; INITIAL must be nil.
The candidate is valid only when its plan has the same three-level content
surface topology as the committed plan.  Its text and content attachments
are still validated and published through the ordinary Ebox transaction
phases."
  (when initial
    (signal 'ebox--pub-invalid-surface-plan
            (list :retained-content-initial t)))
  nil
  (let*
      ((plan (ebox--pub-retained-content-candidate-plan candidate))
       (rendered
        (ebox--pub--compose-relative-property-contributions
         (ebox--pub-retained-content-candidate-rendered candidate)
         (ebox--pub-retained-content-candidate-property-contributions
          candidate)))
       (ranges (ebox--pub-retained-content-candidate-ranges candidate))
       (objects (ebox--pub--context-objects context))
       (root-path (list (ebox--pub--plan-segment plan 0)))
       (fragment-plan (car (ebox--pub-surface-plan-children plan)))
       (fragment-path
        (append root-path
                (list (ebox--pub--plan-segment fragment-plan 0))))
       (text-plan
        (car (ebox--pub-surface-plan-children fragment-plan)))
       (text-path
        (append fragment-path
                (list (ebox--pub--plan-segment text-plan 0))))
       (surface-root (gethash root-path objects))
       (fragment-root (gethash fragment-path objects))
       (text-leaf (gethash text-path objects)))
    (unless
        (and surface-root fragment-root text-leaf
             (null (ebox--pub-surface-plan-props plan))
             (null (ebox--pub-surface-plan-props fragment-plan))
             (null (ebox--pub-surface-plan-props text-plan))
             (null (ebox--pub-surface-plan-children text-plan))
             (equal (ebox--pub-surface-plan-key plan)
                    (ebox--pub-surface-plan-key
                     (ebox--pub--surface-plan surface))))
      (signal 'ebox--pub-invalid-surface-plan
              (list :retained-content-topology plan)))
    (ebox--pub--validate-plan-capability plan
                                         (ebox--pub--surface-capability
                                          surface))
    (when
        (and ranges
             (null
              (gethash text-leaf
                       (ebox--pub--context-content-range-attachments
                        context))))
      (ebox--pub--validate-context-object context text-leaf)
      (dolist (range ranges)
        (let
            ((object (plist-get range :object))
             (start (plist-get range :start))
             (end (plist-get range :end)))
          (ebox--pub--validate-context-object context object)
          (ebox--pub--validate-content-range start end)
          (unless (<= end (length rendered))
            (signal 'ebox--pub-invalid-content-range
                    (list :start start :end end :leaf-length
                          (length rendered))))))
      (puthash text-leaf ranges
               (ebox--pub--context-content-range-attachments context)))
    (let*
        ((length (length rendered))
         (records
          (list
           (list :object text-leaf :start 0 :end length :props nil
                 :tags nil :leaf t)
           (list :object fragment-root :start 0 :end length :props nil
                 :tags nil :leaf nil)
           (list :object surface-root :start 0 :end length :props nil
                 :tags nil :leaf nil)))
         (mount-specs (ebox--pub--content-mount-specs records context))
         (_ranges
          (ebox--pub--validate-cross-surface-ranges surface
                                                    mount-specs
                                                    rendered))
         (full-surface-p
          (ebox--pub-retained-content-candidate-full-surface-p
           candidate))
         (scope-analysis
          (cond
           ((and full-surface-p scope-objects)
            (let
                ((old-length
                  (length (ebox--pub--surface-content-string surface))))
              (list :patches
                    (list
                     (list :old-start 0 :old-end old-length :new-start
                           0 :new-end (length rendered) :replacement
                           rendered))
                    :fallback nil)))
           (scope-objects
            (ebox--pub--prepare-content-scope surface rendered
                                              mount-specs
                                              scope-objects
                                              scope-options))))
         (scope-patches (plist-get scope-analysis :patches))
         (retained-content-p
          (and full-surface-p scope-analysis
               (not (plist-get scope-analysis :fallback))))
         (old-objects (ebox--pub--context-live-objects surface))
         (candidate-objects (ebox--pub--candidate-object-list context)))
      (unless
          (equal
           (sort (copy-sequence old-objects)
                 (lambda (left right)
                   (< (ebox--pub--surface-object-id left)
                      (ebox--pub--surface-object-id right))))
           (sort (copy-sequence candidate-objects)
                 (lambda (left right)
                   (< (ebox--pub--surface-object-id left)
                      (ebox--pub--surface-object-id right)))))
        (signal 'ebox--pub-orphan-object
                (list :retained-content-object-set)))
      (ebox--pub--make-prepared-surface :surface surface :context
                                        context :plan plan :rendered
                                        rendered :mount-specs
                                        mount-specs :objects
                                        candidate-objects
                                        :client-state
                                        (ebox--pub-retained-content-candidate-client-state
                                         candidate)
                                        :producer candidate :initial
                                        nil :created nil :removed nil
                                        :moved 0 :reconciled 0
                                        :scope-objects scope-objects
                                        :scope-patches scope-patches
                                        :scope-fallback
                                        (plist-get scope-analysis
                                                   :fallback)
                                        :retained-content-p
                                        retained-content-p))))

(defun ebox--pub--commit-batch-rebase-position (patches position end-p)
  "Map old POSITION through ordered coordinate PATCHES.  END-P selects the
right boundary when POSITION lies inside a replacement."
  (let ((delta 0) result)
    (while (and patches (null result))
      (let* ((patch (car patches))
             (old-start (plist-get patch :old-start))
             (old-end (plist-get patch :old-end))
             (new-start (plist-get patch :new-start))
             (new-end (plist-get patch :new-end)))
        (cond
         ((< position old-start) (setq result (+ position delta)))
         ((= position old-start) (setq result new-start))
         ((< position old-end) (setq result (if end-p new-end new-start)))
         ((= position old-end) (setq result new-end))
         (t (setq delta (- new-end old-end)
                  patches (cdr patches))))))
    (or result (+ position delta))))

(defun ebox--pub--commit-batch-mount-specs (surface batch)
  "Return SURFACE coordinate mounts rebased through BATCH."
  (let ((base (marker-position (ebox--pub--surface-start surface))))
    (mapcar
     (lambda (mount)
       (let ((start (- (ebox--pub--mount-position
                        (ebox--pub--surface-mount-start mount)) base))
             (end (- (ebox--pub--mount-position
                      (ebox--pub--surface-mount-end mount)) base))
             (patches (ebox--pub-commit-batch-coordinate-patches batch)))
         (list :object (ebox--pub--surface-mount-object mount)
               :start (ebox--pub--commit-batch-rebase-position patches start nil)
               :end (ebox--pub--commit-batch-rebase-position patches end t)
               :tags (copy-tree (ebox--pub--surface-mount-tags mount)))))
     (ebox--pub--surface-mounts surface))))

(defun ebox--pub--commit-batch-retained-mount-state
    (surface mount-specs context target-extent)
  "Return exact coordinate updates when SURFACE can retain MOUNT-SPECS.
CONTEXT authenticates candidate objects and TARGET-EXTENT bounds
coordinates.  The returned cons distinguishes an exact empty update set from
a proof miss."
  (let ((base (marker-position (ebox--pub--surface-start surface)))
        (mounts (ebox--pub--surface-mounts surface))
        (specs mount-specs)
        (retainable
         (and (plist-get (ebox--pub--surface-options surface) :coordinate-mounts) t))
        (updates
         (and (plist-get (ebox--pub--surface-options surface) :coordinate-mounts)
              (make-vector (* 3 (length mount-specs)) nil)))
        (update-index 0))
    (while specs
      (let* ((spec (pop specs))
             (mount (and mounts (pop mounts)))
             (object (plist-get spec :object))
             (start (plist-get spec :start))
             (end (plist-get spec :end)))
        (unless (and (ebox--pub-object-p object)
                     (or (gethash object (ebox--pub--context-touched context))
                         (gethash object (ebox--pub--context-retained context)))
                     (integerp start) (integerp end)
                     (<= 0 start end target-extent))
          (signal 'ebox--pub-surface-error
                  (list :commit-mount-range start end target-extent)))
        (if (and retainable mount
                 (integerp (ebox--pub--surface-mount-start mount))
                 (integerp (ebox--pub--surface-mount-end mount))
                 (eq (ebox--pub--surface-mount-object mount) object)
                 (eq (ebox--pub--surface-mount-tags mount)
                     (plist-get spec :tags)))
            (progn
              (aset updates update-index mount)
              (aset updates (1+ update-index) (+ base start))
              (aset updates (+ update-index 2) (+ base end))
              (setq update-index (+ update-index 3)))
          (setq retainable nil
                updates nil))))
    (when mounts (setq retainable nil))
    (and retainable (cons t updates))))

(defun ebox--pub--commit-batch-stable-object-set-p (surface objects)
  "Return non-nil when OBJECTS are exactly SURFACE's retained identities."
  (let ((live (ebox--pub--surface-objects surface)))
    (and (hash-table-p live)
         (= (hash-table-count live) (length objects))
         (cl-every
          (lambda (object)
            (eq (gethash (ebox--pub--surface-object-path object) live) object))
          objects))))

(defun ebox--pub--commit-batch-coordinate-identity-p (batch)
  "Return non-nil when BATCH cannot move any retained coordinate."
  (and (= (ebox--pub-commit-batch-base-extent batch)
          (ebox--pub-commit-batch-target-extent batch))
       (cl-every
        (lambda (patch)
          (and (= (plist-get patch :old-start)
                  (plist-get patch :new-start))
               (= (plist-get patch :old-end)
                  (plist-get patch :new-end))))
        (ebox--pub-commit-batch-coordinate-patches batch))))

(defun ebox--pub--prepare-commit-batch
    (surface candidate context scope-objects input initial)
  "Prepare strict equal-coordinate CANDIDATE for stable SURFACE topology."
  (when initial
    (signal 'ebox--pub-invalid-surface-plan
            (list :commit-batch-initial t)))
  (unless
      (and t
           (plist-get (ebox--pub--surface-options surface)
                      :coordinate-mounts))
    (signal 'ebox--pub-capability-error
            (list :commit-batch-coordinate-surface)))
  (let*
      ((batch candidate)
       (extent
        (- (marker-position (ebox--pub--surface-end surface))
           (marker-position (ebox--pub--surface-start surface))))
       (reuse-mount-projection-p
        (ebox--pub-commit-batch-reuse-mount-projection-p
         candidate))
       (objects
        (if reuse-mount-projection-p
            (ebox--pub--context-live-objects surface)
          (ebox--pub--candidate-object-list context)))
       (coordinate-identity-p
        (and (not reuse-mount-projection-p)
             (not
              (ebox--pub-commit-batch-exact-mount-specs-p
               candidate))
             (ebox--pub--commit-batch-coordinate-identity-p batch)))
       (mount-specs
        (cond
         ((ebox--pub-commit-batch-exact-mount-specs-p
           candidate)
          (ebox--pub-commit-batch-mount-specs candidate))
         (reuse-mount-projection-p nil) (coordinate-identity-p nil)
         (t (ebox--pub--commit-batch-mount-specs surface batch))))
       (retained-mount-state
        (if (or reuse-mount-projection-p coordinate-identity-p)
            (cons t [])
          (ebox--pub--commit-batch-retained-mount-state surface
                                                        mount-specs
                                                        context
                                                        (ebox--pub-commit-batch-target-extent
                                                         batch)))))
    (unless
        (and
         (= (ebox--pub-commit-batch-base-revision batch)
            (ebox--pub--surface-revision surface))
         (= (ebox--pub-commit-batch-target-revision batch)
            (1+ (ebox--pub--surface-revision surface)))
         (= extent (ebox--pub-commit-batch-base-extent batch))
         (or (not reuse-mount-projection-p)
             (= (ebox--pub-commit-batch-base-extent batch)
                (ebox--pub-commit-batch-target-extent batch))))
      (signal 'ebox--pub-surface-error
              (list :unsupported-commit-batch batch)))
    (unless
        (or reuse-mount-projection-p
            (ebox--pub--commit-batch-stable-object-set-p surface
                                                         objects))
      (signal 'ebox--pub-orphan-object (list :commit-batch-object-set)))
    (when reuse-mount-projection-p
      (ebox--pub--discard-new-objects context))
    (ebox--pub--make-prepared-surface :surface surface :context
                                      context :plan
                                      (ebox--pub--surface-plan surface)
                                      :rendered nil :mount-specs
                                      mount-specs :objects objects
                                      :client-state
                                      (ebox--pub-commit-batch-client-state batch)
                                      :producer input :initial nil
                                      :created nil :removed nil :moved
                                      0 :reconciled 0 :scope-objects
                                      scope-objects :scope-patches
                                      (ebox--pub-commit-batch-patches
                                       batch)
                                      :scope-fallback nil
                                      :commit-batch batch
                                      :retained-mount-state-p
                                      (and retained-mount-state t)
                                      :mount-coordinate-updates
                                      (cdr retained-mount-state))))

(defun ebox--pub--prepare-surface (surface input options initial)
  "Prepare INPUT for SURFACE without publishing it.  OPTIONS configure the
mount and INITIAL is non-nil for first publication."
  (ebox--pub--validate-surface-buffer surface initial)
  (when (and (not initial) (ebox--pub--surface-stale surface))
    (signal 'ebox--pub-stale-mount
            (list (ebox--pub--surface-id surface))))
  (let*
      ((scope-request (ebox--pub--surface-scope-request surface))
       (context (ebox--pub--make-context surface))
       (scope-objects
        (and scope-request
             (ebox--pub--normalize-surface-scopes surface
                                                  (plist-get
                                                   scope-request
                                                   :objects))))
       (scope-options (plist-get scope-request :options))
       (success nil) result)
    (unwind-protect
        (let
            ((normalized
              (ebox--pub--call-with-prepare-buffer-guard surface
                                                         (lambda nil
                                                           (ebox--pub--prepare-input
                                                            surface
                                                            input
                                                            options
                                                            context)))))
          (if
              (memq (car normalized)
                    '(:retained-content :commit-batch))
              (setq result
                    (if (eq (car normalized) :retained-content)
                        (ebox--pub--prepare-retained-content surface
                                                             (cadr
                                                              normalized)
                                                             context
                                                             scope-objects
                                                             scope-options
                                                             initial)
                      (ebox--pub--prepare-commit-batch surface
                                                       (cadr
                                                        normalized)
                                                       context
                                                       scope-objects
                                                       input initial)))
            (let*
                ((plan (nth 0 normalized))
                 (client-state (nth 1 normalized))
                 (owned-p (nth 2 normalized))
                 (_capability
                  (ebox--pub--validate-plan-capability plan
                                                       (ebox--pub--surface-capability
                                                        surface)))
                 (_tree
                  (ebox--pub--validate-context-tree context plan))
                 (render-result
                  (ebox--pub--render-plan plan context owned-p))
                 (rendered (car render-result))
                 (records (cdr render-result))
                 (objects (ebox--pub--candidate-object-list context))
                 (old-objects
                  (ebox--pub--context-live-objects surface))
                 (created
                  (ebox--pub--object-set-difference objects
                                                    old-objects))
                 (removed
                  (ebox--pub--object-set-difference old-objects
                                                    objects))
                 (mount-specs
                  (ebox--pub--plan-record-mount-specs records
                                                      (ebox--pub--surface-capability
                                                       surface)
                                                      context))
                 (_ranges
                  (ebox--pub--validate-cross-surface-ranges surface
                                                            mount-specs
                                                            rendered))
                 (property-result nil)
                 (scope-analysis
                  (when scope-objects
                    (ebox--pub--prepare-content-scope surface rendered
                                                      mount-specs
                                                      scope-objects
                                                      scope-options))))
              (setq result
                    (ebox--pub--make-prepared-surface :surface surface
                                                      :context context
                                                      :plan plan
                                                      :rendered
                                                      rendered
                                                      :mount-specs
                                                      mount-specs
                                                      :ledger-specs
                                                      (car
                                                       property-result)
                                                      :property-operations
                                                      (cdr
                                                       property-result)
                                                      :objects objects
                                                      :client-state
                                                      client-state
                                                      :producer input
                                                      :initial initial
                                                      :created created
                                                      :removed removed
                                                      :moved
                                                      (ebox--pub--plan-moved-count
                                                       (ebox--pub--surface-plan
                                                        surface)
                                                       plan)
                                                      :reconciled
                                                      (ebox--pub--candidate-reconciled-count
                                                       context created)
                                                      :scope-objects
                                                      scope-objects
                                                      :scope-patches
                                                      (plist-get
                                                       scope-analysis
                                                       :patches)
                                                      :scope-fallback
                                                      (plist-get
                                                       scope-analysis
                                                       :fallback)))))
          (setq success t) result)
      (unless success (ebox--pub--discard-context context)))))

(defun ebox--pub--validate-live-surface (surface)
  "Signal unless SURFACE is live and its buffer exists."
  (unless (ebox--pub-surface-p surface)
    (signal 'wrong-type-argument (list 'ebox--pub-surface-p surface)))
  (unless (and (ebox--pub--surface-live surface)
               (buffer-live-p (ebox--pub--surface-buffer surface)))
    (signal 'ebox--pub-dead-surface (list (and (ebox--pub-surface-p surface)
                                        (ebox--pub--surface-id surface))))))

(defun ebox--pub-surface-live-p (surface)
  "Return non-nil when SURFACE is mounted in a live buffer."
  (and (ebox--pub-surface-p surface) (ebox--pub--surface-live surface)
       (buffer-live-p (ebox--pub--surface-buffer surface))))

(defun ebox--pub-surface-revision (surface)
  "Return SURFACE's committed revision."
  (unless (ebox--pub-surface-p surface)
    (signal 'wrong-type-argument (list 'ebox--pub-surface-p surface)))
  (ebox--pub--surface-revision surface))

(defun ebox--pub-surface-client-state (surface)
  "Return SURFACE's opaque committed client state."
  (ebox--pub--validate-live-surface surface)
  (ebox--pub--surface-client-state surface))

(cl-defun ebox--pub-commit-batch-create
    (&key base-revision target-revision base-extent target-extent
          patches coordinate-patches client-state)
  "Create a validated precomputed content commit batch.  BASE-REVISION and
TARGET-REVISION bind the transition; BASE-EXTENT and TARGET-EXTENT bind its
coordinates.  COORDINATE-PATCHES project retained mounts, and CLIENT-STATE
is opaque owner state.  PATCHES are ordered plists containing :old-start,
:old-end, :new-start, :new-end, and a propertized :replacement string.
Optional patch-local :property-contributions use ordered :start, :end, and
:props ranges within that replacement.  Registered merge policies are
evaluated now, at batch construction, and only the final propertized
replacement is retained."
  (unless (and (integerp base-revision) (>= base-revision 0)
               (integerp target-revision)
               (= target-revision (1+ base-revision)))
    (signal 'ebox--pub-surface-error
            (list :commit-revision base-revision target-revision)))
  (unless (and (integerp base-extent) (>= base-extent 0)
               (integerp target-extent) (>= target-extent 0)
               (proper-list-p patches) (proper-list-p coordinate-patches))
    (signal 'ebox--pub-surface-error
            (list :commit-extents base-extent target-extent)))
  (let ((old-cursor 0) (new-cursor 0) copy coordinate-copy)
    (dolist (patch patches)
      (let ((old-start (plist-get patch :old-start))
            (old-end (plist-get patch :old-end))
            (new-start (plist-get patch :new-start))
            (new-end (plist-get patch :new-end))
            (replacement (plist-get patch :replacement)))
        (unless (and (integerp old-start) (integerp old-end)
                     (integerp new-start) (integerp new-end)
                     (<= old-cursor old-start old-end base-extent)
                     (<= new-cursor new-start new-end target-extent)
                     (= (- old-start old-cursor)
                        (- new-start new-cursor))
                     (stringp replacement)
                     (= (length replacement) (- new-end new-start)))
          (signal 'ebox--pub-surface-error (list :commit-patch patch)))
        (let ((candidate
               (if (plist-member patch :property-contributions)
                   (copy-sequence patch)
                 patch)))
          (when (plist-member patch :property-contributions)
            (plist-put candidate :replacement
                       (ebox--pub--compose-relative-property-contributions
                        (plist-get candidate :replacement)
                        (plist-get candidate :property-contributions)))
            (cl-remf candidate :property-contributions))
          (push candidate copy))
        (setq old-cursor old-end new-cursor new-end)))
    (unless (= (- base-extent old-cursor)
               (- target-extent new-cursor))
      (signal 'ebox--pub-surface-error
              (list :commit-tail old-cursor new-cursor)))
    (setq old-cursor 0 new-cursor 0)
    (dolist (patch coordinate-patches)
      (let ((old-start (plist-get patch :old-start))
            (old-end (plist-get patch :old-end))
            (new-start (plist-get patch :new-start))
            (new-end (plist-get patch :new-end)))
        (unless (and (integerp old-start) (integerp old-end)
                     (integerp new-start) (integerp new-end)
                     (<= old-cursor old-start old-end base-extent)
                     (<= new-cursor new-start new-end target-extent)
                     (= (- old-start old-cursor)
                        (- new-start new-cursor)))
          (signal 'ebox--pub-surface-error
                  (list :commit-coordinate-patch patch)))
        (push patch coordinate-copy)
        (setq old-cursor old-end new-cursor new-end)))
    (unless (= (- base-extent old-cursor)
               (- target-extent new-cursor))
      (signal 'ebox--pub-surface-error
              (list :commit-coordinate-tail old-cursor new-cursor)))
    (ebox--pub--make-commit-batch
     :base-revision base-revision :target-revision target-revision
     :base-extent base-extent :target-extent target-extent
     :patches (nreverse copy)
     :coordinate-patches (nreverse coordinate-copy)
     :client-state client-state)))

(cl-defun ebox--pub-commit-batch-result-create
    (context batch &key (mount-specs nil mount-specs-p)
             (client-state nil client-state-p) reuse-mount-projection)
  "Transfer BATCH into CONTEXT with its Ebox-owned state and mount projection."
  (ebox--pub--validate-prepare-context context)
  (unless (and (eq context ebox--pub--current-prepare-context)
               (ebox--pub-commit-batch-p batch)
               (not (ebox--pub-commit-batch-context batch))
               (not (ebox--pub-commit-batch-consumed-p batch)))
    (signal 'ebox--pub-owned-result-error (list :commit-batch context batch)))
  (when (and mount-specs-p reuse-mount-projection)
    (signal 'ebox--pub-surface-error (list :conflicting-commit-mount-projection)))
  (unless (proper-list-p mount-specs)
    (signal 'ebox--pub-surface-error (list :commit-mount-specs)))
  (setf (ebox--pub-commit-batch-context batch) context
        (ebox--pub-commit-batch-mount-specs batch) mount-specs
        (ebox--pub-commit-batch-exact-mount-specs-p batch) mount-specs-p
        (ebox--pub-commit-batch-reuse-mount-projection-p batch)
        (and reuse-mount-projection t))
  (when client-state-p
    (setf (ebox--pub-commit-batch-client-state batch) client-state))
  batch)

(defun ebox--pub--commit-batch-apply-patches (surface batch)
  "Apply BATCH's validated patches to SURFACE, retaining unchanged characters.
The prefix/suffix proof preserves cursor and window anchors in unchanged
text.  Properties are still projected over each complete declared patch.
Return the actual (TEXT-OPERATIONS . PROPERTY-OPERATIONS) counts."
  (let ((buffer (ebox--pub--surface-buffer surface))
        (base (marker-position (ebox--pub--surface-start surface)))
        (text-operations 0) (property-operations 0))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (let ((inhibit-read-only
               (plist-get (ebox--pub--surface-options surface)
                          :inhibit-read-only)))
          (dolist (patch (reverse (ebox--pub-commit-batch-patches batch)))
            (let* ((start (+ base (plist-get patch :old-start)))
                   (end (+ base (plist-get patch :old-end)))
                   (replacement (plist-get patch :replacement))
                   (old (buffer-substring-no-properties start end))
                   (prefix (ebox--pub--common-prefix-length old replacement))
                   (suffix (ebox--pub--common-suffix-length old replacement prefix)))
              (unless (and (= prefix (length old))
                           (= prefix (length replacement)))
                (delete-region (+ start prefix) (- end suffix))
                (goto-char (+ start prefix))
                (let ((inserted (substring replacement prefix
                                           (- (length replacement) suffix))))
                  (insert inserted)
                  (cl-incf text-operations)
                  (unless (ebox--pub--validate-published-content-range
                           buffer (+ start prefix) inserted)
                    (signal 'ebox--pub-publication-mismatch
                            (list :commit-patch patch)))))
              ;; Keep undo recording for the standalone public batch API as
              ;; well as transaction publication.  Host property hooks are
              ;; inhibited just as in the ordinary content-property writer.
              (let ((inhibit-modification-hooks t))
                (dolist (operation
                         (ebox--pub--content-property-operations-in-range
                          buffer start replacement 0 (length replacement)))
                  (set-text-properties (plist-get operation :start)
                                       (plist-get operation :end)
                                       (plist-get operation :props))
                  (cl-incf property-operations))))))))
    (set-marker (ebox--pub--surface-start surface) base buffer)
    (set-marker (ebox--pub--surface-end surface)
                (+ base (ebox--pub-commit-batch-target-extent batch)) buffer)
    (cons text-operations property-operations)))

(defun ebox--pub--commit-batch-validate-buffer (surface batch)
  "Validate BATCH's published extent and changed spans on SURFACE."
  (let ((buffer (ebox--pub--surface-buffer surface))
        (base (marker-position (ebox--pub--surface-start surface))))
    (let ((actual (- (marker-position (ebox--pub--surface-end surface)) base))
          (expected (ebox--pub-commit-batch-target-extent batch)))
      (unless (= actual expected)
        (signal 'ebox--pub-publication-mismatch
                (list :commit-extent :actual actual :expected expected))))
    (dolist (patch (ebox--pub-commit-batch-patches batch))
      (let ((start (+ base (plist-get patch :new-start)))
            (end (+ base (plist-get patch :new-end)))
            (replacement (plist-get patch :replacement)))
        (unless (ebox--pub--text-property-semantic-equal-p
                 (with-current-buffer buffer (buffer-substring start end))
                 replacement)
          (signal 'ebox--pub-publication-mismatch
                  (list :commit-patch patch)))))))

(defun ebox--pub--commit-batch-validate-mounts (surface batch mounts)
  "Validate target MOUNTS for BATCH inside SURFACE."
  (let ((base (marker-position (ebox--pub--surface-start surface)))
        (limit (+ (marker-position (ebox--pub--surface-start surface))
                  (ebox--pub-commit-batch-target-extent batch))))
    (dolist (mount mounts)
      (let ((start (ebox--pub--mount-position (ebox--pub--surface-mount-start mount)))
            (end (ebox--pub--mount-position (ebox--pub--surface-mount-end mount))))
        (unless (and start end (<= base start end limit))
          (signal 'ebox--pub-publication-mismatch
                  (list :commit-mount mount)))))))

(defun ebox--pub--validate-surface-buffer (surface initial)
  "Validate SURFACE's buffer before prepare; INITIAL permits a candidate."
  (let ((buffer (ebox--pub--surface-buffer surface)))
    (unless (buffer-live-p buffer)
      (signal 'ebox--pub-dead-surface (list (ebox--pub--surface-id surface))))
    (when (buffer-base-buffer buffer)
      (signal 'ebox-unsupported-buffer (list :indirect buffer)))
    (unless (or initial (ebox--pub--surface-live surface))
      (signal 'ebox--pub-dead-surface (list (ebox--pub--surface-id surface))))
    (with-current-buffer buffer
      (when (and buffer-read-only
                 (not (plist-get (ebox--pub--surface-options surface)
                                 :inhibit-read-only)))
        (signal 'buffer-read-only (list buffer))))))

(defun ebox--pub--surface-range (surface)
  "Return SURFACE's live start and end positions."
  (let ((start (marker-position (ebox--pub--surface-start surface)))
        (end (marker-position (ebox--pub--surface-end surface))))
    (unless (and start end)
      (signal 'ebox--pub-stale-mount (list (ebox--pub--surface-id surface))))
    (cons start end)))

(defun ebox--pub--create-surface (buffer capability options)
  "Create an unmounted BUFFER surface with CAPABILITY and OPTIONS."
  nil
  (when (buffer-base-buffer buffer)
    (signal 'ebox-unsupported-buffer (list :indirect buffer)))
  (let*
      ((range
        (with-current-buffer buffer
          (save-restriction
            (widen)
            (cons (or (plist-get options :start) (point-min))
                  (or (plist-get options :end) (point-max))))))
       (_valid
        (ebox-text--validate-buffer-range buffer (car range)
                                          (cdr range))))
    (ebox--pub--make-surface :id
                             (cl-incf ebox--pub--surface-id-counter)
                             :buffer buffer :capability capability
                             :start (copy-marker (car range) nil) :end
                             (copy-marker (cdr range) t) :options
                             (ebox-text--copy-property-value options)
                             :objects (make-hash-table :test #'equal)
                             :mounts nil :index nil :mount-index
                             (make-hash-table :test #'eq) :ledger nil
                             :revision 0 :live nil :stale nil
                             :observers
                             (ebox--pub--normalize-surface-observers
                              (plist-get options :observers)))))

(defun ebox--pub--surface-compute-function (surface input options initial)
  "Return SURFACE's producer binding for INPUT, OPTIONS, and INITIAL state."
  (lambda ()
    (ebox--pub--prepare-surface
     surface input options (and initial (not (ebox--pub--surface-live surface))))))

(defun ebox--pub--install-surface-producer (surface input options initial)
  "Install INPUT as SURFACE's producer binding."
  (ebox--pub--clear-surface-scope-request surface)
  (let ((binding
         (ebox--pub-bind surface ebox--pub--surface-producer-key
                  (ebox--pub--surface-compute-function surface input options initial)
                  :equality (lambda (_old _new) nil) :lifecycle 'retain)))
    (setf (ebox--pub--surface-producer-binding surface) binding)
    binding))

(defun ebox--pub--dispose-marker (marker)
  "Detach MARKER when it is live."
  (when (markerp marker) (set-marker marker nil)))

(defun ebox--pub--discard-new-objects (context)
  "Invalidate CONTEXT's uncommitted object handles."
  (dolist (object (ebox--pub--context-new-objects context))
    (unless (ebox--pub--surface-object-live object)
      (ebox--pub-binding-dispose-owner object)
      (setf (ebox--pub--surface-object-disposed object) t
            (ebox--pub--surface-object-candidate-context object) nil))))

(defun ebox--pub--discard-context (context)
  "Release unpromoted content handles owned by CONTEXT."
  (when (and (ebox--pub-prepare-context-p context) (ebox--pub--context-active context))
    (setf (ebox--pub--context-active context) nil)
    (ebox--pub--discard-new-objects context)))

(defun ebox--pub--surface-mount-cleanup (surface)
  "Release candidate markers and bindings for failed SURFACE mount."
  (ebox--pub-binding-dispose-owner surface)
  (ebox--pub--dispose-marker (ebox--pub--surface-start surface))
  (ebox--pub--dispose-marker (ebox--pub--surface-end surface))
  (setf (ebox--pub--surface-live surface) nil))

(defun ebox--pub-surface-mount (buffer plan-or-producer &optional options)
  "Mount PLAN-OR-PRODUCER into BUFFER according to OPTIONS.  OPTIONS accepts
only the content capability, and :start, :end, :inhibit-read-only,
:coordinate-mounts, :client-state, and :observers.  When :coordinate-mounts
is non-nil, content mounts store numeric coordinates rather than private
markers; use it only when host edits make the whole content surface stale
and all writes are published through Ebox publication.  Return a surface handle."
  (let* ((target (get-buffer buffer))
         (_live (unless (buffer-live-p target)
                  (signal 'ebox-unsupported-buffer (list buffer))))
         (capability (or (plist-get options :capability)
                         (and (ebox--pub-surface-plan-p plan-or-producer)
                              (ebox--pub-surface-plan-capability plan-or-producer))
                         'content))
         (surface (ebox--pub--create-surface target capability options))
         success)
    (unwind-protect
        (progn
          (ebox--pub--install-surface-producer surface plan-or-producer options t)
          (setq success t)
          surface)
      (unless success (ebox--pub--surface-mount-cleanup surface)))))

(defun ebox--pub-surface-update (surface plan-or-producer)
  "Atomically update SURFACE from PLAN-OR-PRODUCER and return its report."
  (ebox--pub--validate-live-surface surface)
  (ebox--pub--install-surface-producer
   surface plan-or-producer (ebox--pub--surface-options surface) nil)
  (ebox--pub-surface-report surface))

(defun ebox--pub-surface-add-observer (surface observer)
  "Add function OBSERVER to live SURFACE and return SURFACE.  OBSERVER receives
SURFACE and a defensive REPORT copy after each successful publication.
Adding the same function more than once has no effect."
  (ebox--pub--validate-live-surface surface)
  (unless (functionp observer)
    (signal 'wrong-type-argument (list 'functionp observer)))
  (unless (memq observer (ebox--pub--surface-observers surface))
    (setf (ebox--pub--surface-observers surface)
          (append (ebox--pub--surface-observers surface) (list observer))))
  surface)

(defun ebox--pub-surface-remove-observer (surface observer)
  "Remove function OBSERVER from live SURFACE and return SURFACE.  Removing a
function that is not registered has no effect."
  (ebox--pub--validate-live-surface surface)
  (unless (functionp observer)
    (signal 'wrong-type-argument (list 'functionp observer)))
  (setf (ebox--pub--surface-observers surface)
        (delq observer (ebox--pub--surface-observers surface)))
  surface)

(defun ebox--pub-surface-update-scoped
    (surface objects plan-or-producer &optional options)
  "Atomically update SURFACE within retained OBJECTS.  PLAN-OR-PRODUCER has the
same full candidate contract as `ebox--pub-surface-update'.  Ebox resolves
OBJECTS through its mount index and rejects any candidate output change
outside their ranges before publication.

OPTIONS accepts `:on-mismatch' and `:return-report'.  Its default mismatch
policy, `error', signals `ebox--pub-scope-mismatch'; `root' permits an
explicit full-surface fallback.  The report is returned as a defensive
snapshot by default; `:return-report nil' avoids materializing that snapshot
when the caller reads the scalar summary from the surface instead."
  (ebox--pub--validate-live-surface surface)
  (setq objects (ebox--pub--normalize-surface-scopes surface objects))
  (let ((on-mismatch (or (plist-get options :on-mismatch) 'error))
        (return-report (if (plist-member options :return-report)
                           (plist-get options :return-report)
                         t)))
    (unless (memq on-mismatch '(error root))
      (signal 'wrong-type-argument
              (list '(member error root) on-mismatch)))
    (ebox--pub--call-with-transaction
     (lambda ()
       (ebox--pub--install-surface-producer
        surface plan-or-producer (ebox--pub--surface-options surface) nil)
       (ebox--pub--set-surface-scope-request
        surface objects (list :on-mismatch on-mismatch))))
  (when return-report
    (ebox--pub-surface-report surface))))

(defun ebox--pub--edit-touches-span-p (beg edit-end start end)
  "Return non-nil when BEG..EDIT-END touches the old START..END span."
  (if (= beg edit-end)
      (and (> beg start) (< beg end))
    (and (< beg end) (> edit-end start))))

(defun ebox--pub--surface-before-change (beg end)
  "Capture owned content ranges before a host edit from BEG to END."
  (setq ebox--pub--surface-before-change-state nil)
  (unless (or ebox--pub--surface-publishing ebox--pub--surface-guarding-prepare)
    (let (content)
      (dolist (surface ebox--pub--buffer-surfaces)
        (when (ebox--pub-surface-live-p surface)
          (pcase-let ((`(,start . ,finish) (ebox--pub--surface-range surface)))
            (push (list surface start finish) content))))
      (setq ebox--pub--surface-before-change-state
            (list :beg beg :end end :content content)))))

(defun ebox--pub--surface-after-change (_beg _end _old-length)
  "Mark owned content stale after a host character edit."
  (let* ((tick (buffer-chars-modified-tick))
         (changed (/= tick ebox--pub--surface-character-tick))
         (state ebox--pub--surface-before-change-state))
    (setq ebox--pub--surface-character-tick tick
          ebox--pub--surface-before-change-state nil)
    (when (and changed state (not ebox--pub--surface-publishing)
               (not ebox--pub--surface-guarding-prepare))
      (dolist (entry (plist-get state :content))
        (pcase-let ((`(,surface ,start ,end) entry))
          (when (and (ebox--pub-surface-live-p surface)
                     (ebox--pub--edit-touches-span-p
                      (plist-get state :beg) (plist-get state :end) start end))
            (setf (ebox--pub--surface-stale surface) t)))))))

(defun ebox--pub--surface-buffer-killed ()
  "Dispose every retained surface owned by the current buffer."
  (let ((surfaces ebox--pub--buffer-surfaces))
    (setq ebox--pub--buffer-surfaces nil)
    (dolist (surface surfaces) (ebox--pub--teardown-surface surface t))))

(defun ebox--pub--register-live-surface (surface)
  "Register committed SURFACE under its buffer lifecycle owner."
  (puthash (ebox--pub--surface-id surface) surface ebox--pub--surfaces)
  (with-current-buffer (ebox--pub--surface-buffer surface)
    (cl-pushnew surface ebox--pub--buffer-surfaces :test #'eq)
    (setq ebox--pub--surface-character-tick (buffer-chars-modified-tick))
    (add-hook 'before-change-functions #'ebox--pub--surface-before-change nil t)
    (add-hook 'after-change-functions #'ebox--pub--surface-after-change nil t)
    (add-hook 'kill-buffer-hook #'ebox--pub--surface-buffer-killed nil t)))

(defun ebox--pub--surface-extension-state ()
  "Return the surface extension state for the active transaction."
  (ebox--pub--transaction-extension ebox--pub--surface-extension-key t))

(defun ebox--pub--surface-scope-table (&optional create)
  "Return the transaction-local scope table, creating it when CREATE is
non-nil."
  (when-let* ((state (ebox--pub--transaction-extension
                     ebox--pub--surface-extension-key create)))
    (or (gethash 'scopes state)
        (when create
          (let ((table (make-hash-table :test #'eq)))
            (puthash 'scopes table state)
            table)))))

(defun ebox--pub--surface-scope-request (surface)
  "Return SURFACE's one-shot scope request in the active transaction."
  (when-let* ((table (ebox--pub--surface-scope-table)))
    (gethash surface table)))

(defun ebox--pub--clear-surface-scope-request (surface)
  "Clear SURFACE's pending one-shot scope request when one exists."
  (when ebox--pub--transaction-active
    (when-let* ((table (ebox--pub--surface-scope-table)))
      (remhash surface table))))

(defun ebox--pub--set-surface-scope-request (surface objects options)
  "Set SURFACE's one-shot scope request to OBJECTS and OPTIONS."
  (puthash surface
           (list :objects (copy-sequence objects)
                 :options (ebox-text--copy-property-value options))
           (ebox--pub--surface-scope-table t)))

(defun ebox--pub--surface-prepared-table ()
  "Return the transaction-local surface candidate table."
  (let ((state (ebox--pub--surface-extension-state)))
    (or (gethash 'prepared state)
        (let ((table (make-hash-table :test #'eq)))
          (puthash 'prepared table state)
          table))))

(defun ebox--pub--surface-binding-changed (binding _old new)
  "Queue NEW when BINDING is a retained surface producer."
  (when (and (equal (ebox--pub-binding-key binding) ebox--pub--surface-producer-key)
             (ebox--pub-surface-p (ebox--pub-binding-owner binding)))
    (unless (ebox--pub--prepared-surface-p new)
      (signal 'ebox--pub-invalid-surface-plan (list :producer-result new)))
    (let* ((table (ebox--pub--surface-prepared-table))
           (surface (ebox--pub-binding-owner binding))
           (previous (gethash surface table)))
      (when previous
        (ebox--pub--discard-context (ebox--pub--prepared-surface-context previous)))
      (puthash surface new table))))

(defun ebox--pub--prepared-mount-signature (prepared &optional retained-signature)
  "Return PREPARED's exact target mount attachment signature.
RETAINED-SIGNATURE may supply the already captured live signature."
  (if (ebox--pub--prepared-surface-retained-mount-state-p prepared)
      (let* ((surface (ebox--pub--prepared-surface-surface prepared))
             (updates (ebox--pub--prepared-surface-mount-coordinate-updates prepared))
             (base (marker-position (ebox--pub--surface-start surface))))
        (if (zerop (length updates))
            (or retained-signature (ebox--pub--live-mount-signature surface))
          (cl-loop for index from 0 below (length updates) by 3
                   for mount = (aref updates index)
                   collect (list (ebox--pub--surface-mount-object mount)
                                 (ebox--pub--surface-mount-anchor mount)
                                 (- (aref updates (1+ index)) base)
                                 (- (aref updates (+ index 2)) base)
                                 (ebox--pub--surface-mount-tags mount)))))
    (mapcar (lambda (spec)
              (list (plist-get spec :object) (plist-get spec :anchor)
                    (plist-get spec :start) (plist-get spec :end)
                    (plist-get spec :tags)))
            (ebox--pub--prepared-surface-mount-specs prepared))))

(defun ebox--pub--live-mount-signature (surface)
  "Return SURFACE's stable live mount signature."
  (let ((base (marker-position (ebox--pub--surface-start surface))))
    (mapcar
     (lambda (mount)
       (list (ebox--pub--surface-mount-object mount)
             (ebox--pub--surface-mount-anchor mount)
             (-
              (ebox--pub--mount-position
               (ebox--pub--surface-mount-start mount))
              base)
             (-
              (ebox--pub--mount-position
               (ebox--pub--surface-mount-end mount))
              base)
             (ebox--pub--surface-mount-tags mount)))
     (ebox--pub--surface-mounts surface))))

(defun ebox--pub--ensure-surface-mount-id (mount)
  "Return MOUNT's stable private id, allocating it before publication if
absent."
  (or (ebox--pub--surface-mount-id mount)
      (setf (ebox--pub--surface-mount-id mount) (cl-incf ebox--pub--mount-id-counter))))

(defun ebox--pub--mount-match-queues (mounts object capability seen)
  "Group matching MOUNTS by anchor identity and equal tags in live order.  Only
include OBJECT and CAPABILITY by identity.  SEEN prevents enqueuing the same
mount record twice.  Queue spines are private; no mount IDs are allocated."
  (let ((anchors (make-hash-table :test #'eq)))
    (dolist (mount mounts)
      (when (and (eq object (ebox--pub--surface-mount-object mount))
                 (eq capability (ebox--pub--surface-mount-capability mount))
                 (not (gethash mount seen)))
        (puthash mount t seen)
        (let* ((anchor (ebox--pub--surface-mount-anchor mount))
               (tags (ebox--pub--surface-mount-tags mount))
               (by-tags (or (gethash anchor anchors)
                            (puthash anchor (make-hash-table :test #'equal)
                                     anchors))))
          (push mount (gethash tags by-tags)))))
    (maphash
     (lambda (_anchor by-tags)
       (maphash (lambda (tags queue)
                  (puthash tags (nreverse queue) by-tags))
                by-tags))
     anchors)
    anchors))

(defun ebox--pub--assign-prepared-mount-ids (prepared)
  "Bind PREPARED mount specs to stable live or fresh private mount ids."
  (let* ((surface (ebox--pub--prepared-surface-surface prepared))
         (live (ebox--pub--surface-mounts surface)))
    (if (ebox--pub--prepared-surface-retained-mount-state-p prepared)
        (dolist (mount live) (ebox--pub--ensure-surface-mount-id mount))
      (let ((capability (ebox--pub--surface-capability surface))
            (live-by-object (ebox--pub--surface-mount-index surface))
            (queues-by-object (make-hash-table :test #'eq))
            (seen (make-hash-table :test #'eq)))
        (setf
         (ebox--pub--prepared-surface-mount-specs prepared)
         (mapcar
          (lambda (spec)
            (let* ((object (plist-get spec :object))
                   (anchors
                    (or (gethash object queues-by-object)
                        ;; Cache empty queues too: later unmatched specs must
                        ;; not rebuild the same object's live bucket.
                        (puthash object
                                 (ebox--pub--mount-match-queues
                                  (gethash object live-by-object)
                                  object capability seen)
                                 queues-by-object)))
                   (by-tags (gethash (plist-get spec :anchor) anchors))
                   (tags (plist-get spec :tags))
                   (queue (and by-tags (gethash tags by-tags)))
                   (match (car queue)))
              (when match (puthash tags (cdr queue) by-tags))
              (plist-put
               spec :mount-id
               (if match
                   (ebox--pub--ensure-surface-mount-id match)
                 (cl-incf ebox--pub--mount-id-counter)))))
          (ebox--pub--prepared-surface-mount-specs prepared)))))
    prepared))

(defun ebox--pub--content-output-equal-p (prepared)
  "Return non-nil when PREPARED already matches its content mount."
  (let ((surface (ebox--pub--prepared-surface-surface prepared)))
    (if (not t) t
      (pcase-let
          ((`(,start \, end) (ebox--pub--surface-range surface)))
        (with-current-buffer (ebox--pub--surface-buffer surface)
          (save-restriction
            (widen)
            (ebox--pub--text-property-semantic-equal-p
             (buffer-substring start end)
             (ebox--pub--prepared-surface-rendered prepared))))))))

(defun ebox--pub--prepared-changed-p (prepared)
  "Return non-nil when PREPARED differs from its committed surface."
  (let ((surface (ebox--pub--prepared-surface-surface prepared)))
    (or (ebox--pub--prepared-surface-initial prepared)
        ;; An authenticated batch explicitly advances the revision, including
        ;; an empty batch.  Preparation already checked its base and topology;
        ;; its retained plan is not a new candidate to compare recursively.
        (ebox--pub--prepared-surface-commit-batch prepared)
        (not (ebox--pub--plan-equal-p (ebox--pub--surface-plan surface)
                               (ebox--pub--prepared-surface-plan prepared)))
        (not (equal (ebox--pub--surface-client-state surface)
                    (ebox--pub--prepared-surface-client-state prepared)))
        (not (eq (ebox--pub--surface-producer surface)
                 (ebox--pub--prepared-surface-producer prepared)))
        (ebox--pub--prepared-surface-created prepared)
        (ebox--pub--prepared-surface-removed prepared)
        (not (ebox--pub--content-output-equal-p prepared))
        (not (equal (ebox--pub--live-mount-signature surface)
                    (ebox--pub--prepared-mount-signature prepared))))))

(defun ebox--pub--sorted-prepared-surfaces (table)
  "Return changed candidates in TABLE ordered by surface id."
  (let (prepared)
    (maphash (lambda (_surface candidate)
               (when (ebox--pub--prepared-changed-p candidate)
                 (push candidate prepared)))
             table)
    (sort prepared
          (lambda (left right)
            (< (ebox--pub--surface-id (ebox--pub--prepared-surface-surface left))
               (ebox--pub--surface-id (ebox--pub--prepared-surface-surface right)))))))

(defun ebox--pub--all-prepared-surfaces (table)
  "Return every candidate in TABLE ordered by stable surface id."
  (let (prepared)
    (maphash (lambda (_surface candidate) (push candidate prepared)) table)
    (sort prepared
          (lambda (left right)
            (< (ebox--pub--surface-id (ebox--pub--prepared-surface-surface left))
               (ebox--pub--surface-id (ebox--pub--prepared-surface-surface right)))))))

(defun ebox--pub--publication-step (step surface)
  "Run the internal publication failure hook for STEP and SURFACE."
  (when ebox--pub--surface-publication-step-function
    (funcall ebox--pub--surface-publication-step-function step surface)))

(defun ebox--pub--common-prefix-length (left right)
  "Return the common character prefix length of LEFT and RIGHT."
  (let ((limit (min (length left) (length right))) (index 0))
    (while (and (< index limit) (= (aref left index) (aref right index)))
      (setq index (1+ index)))
    index))

(defun ebox--pub--common-suffix-length (left right prefix)
  "Return LEFT and RIGHT's common suffix length after PREFIX."
  (let ((limit (- (min (length left) (length right)) prefix)) (count 0))
    (while (and (< count limit)
                (= (aref left (- (length left) count 1))
                   (aref right (- (length right) count 1))))
      (setq count (1+ count)))
    count))

(defun ebox--pub--validate-published-content-range (buffer start rendered)
  "Validate inserted BUFFER text from START with RENDERED.  Return whether the
properties match.  An external `after-change-functions' hook may alter the
inserted properties; return nil for that recoverable case so Ebox reapplies
the rendered runs.  A character rewrite is not recoverable at the property
layer and signals before the transaction can commit."
  (with-current-buffer buffer
    (let ((end (+ start (length rendered))))
      (unless (and (<= (point-min) start) (<= end (point-max))
                   (equal (buffer-substring-no-properties start end)
                          (substring-no-properties rendered)))
        (signal 'ebox--pub-publication-mismatch
                (list :buffer buffer :start start :end end)))
      (ebox--pub--text-property-semantic-equal-p
       (buffer-substring start end) rendered))))

(defun ebox--pub--content-text-operation (surface rendered)
  "Publish SURFACE's minimal character replacement for RENDERED."
  (pcase-let* ((`(,start . ,end) (ebox--pub--surface-range surface))
               (old (buffer-substring-no-properties start end))
               (new (substring-no-properties rendered))
               (prefix (ebox--pub--common-prefix-length old new))
               (suffix (ebox--pub--common-suffix-length old new prefix)))
    (unless (equal old new)
      (delete-region (+ start prefix) (- end suffix))
      (goto-char (+ start prefix))
      (let ((inserted (substring rendered prefix (- (length rendered) suffix))))
        (insert inserted)
        (when (ebox--pub--validate-published-content-range
               (ebox--pub--surface-buffer surface) (+ start prefix) inserted)
          (push (cons prefix (- (length new) suffix))
                ebox--pub--content-published-ranges))))
    (set-marker (ebox--pub--surface-start surface) start)
    (set-marker (ebox--pub--surface-end surface) (+ start (length new)))
    (if (equal old new) 0 1)))

(defun ebox--pub--string-property-run-diff-p (buffer start rendered from to)
  "Return non-nil when BUFFER at START differs from RENDERED on FROM..TO.  The
rendered interval is already one direct-property run.  Compare its boundary
value once and reject an interior buffer boundary; scanning every character
makes a large rendered surface quadratic in its number of runs."
  (let* ((buffer-start (+ start from))
         (buffer-end (+ start to))
         (buffer-next (or (next-property-change
                          buffer-start buffer buffer-end)
                         buffer-end)))
    (or (not (ebox--pub--plan-props-equal-p
              (text-properties-at buffer-start buffer)
              (text-properties-at from rendered)))
        ;; Unlike ordinary face paint, native mouse-face boundaries are
        ;; defined by identity.  Every published run must use the candidate
        ;; group's exact value, even when its face attributes compare equal.
        (not (eq (get-text-property buffer-start 'mouse-face buffer)
                 (get-text-property from 'mouse-face rendered)))
        (< buffer-next buffer-end))))

(defun ebox--pub--range-contained-in-p (start end ranges)
  "Return non-nil when START..END is inside one of RANGES."
  (cl-some (lambda (range)
             (and (<= (car range) start) (<= end (cdr range))))
           ranges))

(defun ebox--pub--align-scoped-mouse-face-groups! (buffer base rendered ranges)
  "Preserve native hover identities crossing scoped RANGES in RENDERED.  BUFFER
at BASE already has the candidate characters.  An unchanged outside gap
authenticates the existing identity for its whole contiguous candidate
group.  Separate groups are never interned by paint value.  If outside gaps
disagree on identity, the requested scope cannot publish that group change."
  (let ((seen (make-hash-table :test #'eql))
        (limit (length rendered)))
    (dolist (range ranges)
      (let ((position (car range)))
        (while (< position (cdr range))
          (let* ((value (get-text-property position 'mouse-face rendered))
                 (end (next-single-property-change
                       position 'mouse-face rendered limit))
                 (start (previous-single-property-change
                         (1+ position) 'mouse-face rendered 0)))
            (when (and value (not (gethash start seen)))
              (puthash start t seen)
              (let ((outside (ebox--pub--subtract-ranges (list (cons start end)) ranges))
                    identity found)
                (dolist (gap outside)
                  (let ((cursor (+ base (car gap)))
                        (stop (+ base (cdr gap))))
                    (while (< cursor stop)
                      (let ((actual (get-text-property cursor 'mouse-face buffer)))
                        (unless (and (ebox--pub--property-value-equal-p
                                      'mouse-face value actual)
                                     (or (not found) (eq identity actual)))
                          (signal 'ebox--pub-scope-mismatch
                                  (list :mouse-face-group start end)))
                        (setq identity actual found t
                              cursor (next-single-property-change
                                      cursor 'mouse-face buffer stop))))))
                (when found
                  ;; Reusing the outside identity must not silently erase a
                  ;; candidate boundary against another unchanged group.
                  (dolist (neighbor (list (1- start) end))
                    (when (and (<= 0 neighbor) (< neighbor limit)
                               (not (ebox--pub--range-contained-in-p
                                     neighbor (1+ neighbor) ranges))
                               (eq identity
                                   (get-text-property (+ base neighbor)
                                                      'mouse-face buffer)))
                      (signal 'ebox--pub-scope-mismatch
                              (list :mouse-face-boundary start end))))
                  (unless (eq identity value)
                    (put-text-property start end 'mouse-face identity rendered)
                    ;; Inserted text was validated before this ownership
                    ;; alignment.  Reapply its properties too when its native
                    ;; group now adopts an unchanged outside identity.
                    (setq ebox--pub--content-published-ranges
                          (ebox--pub--subtract-ranges ebox--pub--content-published-ranges
                                               (list (cons start end))))))))
            (setq position end)))))))

(defun ebox--pub--content-property-operations-in-range
    (buffer start rendered from to)
  "Return property operations for RENDERED FROM..TO at BUFFER position START."
  (let ((offset from) operations)
    (while (< offset to)
      (let* ((next (next-property-change offset rendered to))
             (props (text-properties-at offset rendered)))
        (when (ebox--pub--string-property-run-diff-p
               buffer start rendered offset next)
          (push (list :start (+ start offset) :end (+ start next)
                      :props props)
                operations))
        (setq offset next)))
    (nreverse operations)))

(defun ebox--pub--content-property-operations
    (surface rendered &optional ranges scoped)
  "Return exact direct-property operations for SURFACE and RENDERED.  When
SCOPED is non-nil, inspect only RANGES, including an empty set."
  (let* ((buffer (ebox--pub--surface-buffer surface))
         (start (marker-position (ebox--pub--surface-start surface)))
         (ranges (if scoped ranges (list (cons 0 (length rendered)))))
         (_hover-groups
          (when scoped
            (ebox--pub--align-scoped-mouse-face-groups! buffer start rendered ranges)))
         (ranges
          (if ebox--pub--content-published-ranges
              (ebox--pub--subtract-ranges
               ranges (ebox--pub--coalesce-ranges ebox--pub--content-published-ranges))
            ranges))
         operations)
    (dolist (range ranges operations)
      (setq operations
            (nconc operations
                   (ebox--pub--content-property-operations-in-range
                    buffer start rendered (car range) (cdr range)))))))

(defun ebox--pub--apply-content-property-operations (buffer operations)
  "Apply content property OPERATIONS in BUFFER silently."
  (with-current-buffer buffer
    (with-silent-modifications
      (dolist (operation operations)
        (set-text-properties (plist-get operation :start)
                             (plist-get operation :end)
                             (plist-get operation :props) buffer)))))

(defun ebox--pub--make-content-mounts (prepared)
  "Create content mounts for PREPARED using its declared coordinate policy."
  (let* ((surface (ebox--pub--prepared-surface-surface prepared))
         (buffer (ebox--pub--surface-buffer surface))
         (base (marker-position (ebox--pub--surface-start surface)))
         (coordinate-p (plist-get (ebox--pub--surface-options surface)
                                  :coordinate-mounts)))
    (mapcar
     (lambda (spec)
       (ebox--pub--make-surface-mount
        :id (or (plist-get spec :mount-id)
                (cl-incf ebox--pub--mount-id-counter))
        :object (plist-get spec :object)
        :start (if coordinate-p
                   (+ base (plist-get spec :start))
                 (with-current-buffer buffer
                   (copy-marker (+ base (plist-get spec :start)) nil)))
        :end (if coordinate-p
                 (+ base (plist-get spec :end))
               (with-current-buffer buffer
                 (copy-marker (+ base (plist-get spec :end)) t)))
        :tags (plist-get spec :tags) :capability 'content))
     (ebox--pub--prepared-surface-mount-specs prepared))))

(defun ebox--pub--make-live-ledger (prepared)
  "Create marker-backed property ledger entries for PREPARED."
  (let ((buffer (ebox--pub--surface-buffer (ebox--pub--prepared-surface-surface prepared))))
    (mapcar
     (lambda (spec)
       (ebox--pub--make-property-ledger
        :start (with-current-buffer buffer
                 (copy-marker (plist-get spec :start) nil))
        :end (with-current-buffer buffer
               (copy-marker (plist-get spec :end) t))
        :property (plist-get spec :property)
        :baseline-present (plist-get spec :baseline-present)
        :baseline-value (plist-get spec :baseline-value)
        :published-present (plist-get spec :published-present)
        :published-value (plist-get spec :published-value)
        :anchors (plist-get spec :anchors)))
     (ebox--pub--prepared-surface-ledger-specs prepared))))

(defun ebox--pub--index-mounts-by-object (mounts)
  "Return an object-keyed index of marker-backed MOUNTS."
  (let ((index (make-hash-table :test #'eq)))
    (dolist (mount mounts)
      (push mount (gethash (ebox--pub--surface-mount-object mount) index)))
    (maphash (lambda (object entries)
               (puthash object (nreverse entries) index))
             index)
    index))

(defun ebox--pub--create-candidate-mount-state (prepared)
  "Create PREPARED content mounts and their identity index."
  (let ((mounts (ebox--pub--make-content-mounts prepared)))
    (setf (ebox--pub--prepared-surface-live-mounts prepared) mounts
          (ebox--pub--prepared-surface-live-mount-index prepared)
          (ebox--pub--index-mounts-by-object mounts)
          (ebox--pub--prepared-surface-live-ledger prepared) nil)
    mounts))

(defun ebox--pub--retain-candidate-mount-state (prepared)
  "Apply PREPARED coordinate updates while retaining mount identity and index."
  (let* ((surface (ebox--pub--prepared-surface-surface prepared))
         (mounts (ebox--pub--surface-mounts surface))
         (updates (ebox--pub--prepared-surface-mount-coordinate-updates prepared))
         (undo (make-vector (* 2 (/ (length updates) 3)) nil))
         (update-index 0)
         (undo-index 0))
    (while (< update-index (length updates))
      (let ((mount (aref updates update-index)))
        (aset undo undo-index (ebox--pub--surface-mount-start mount))
        (aset undo (1+ undo-index) (ebox--pub--surface-mount-end mount))
        (setf (ebox--pub--surface-mount-start mount)
              (aref updates (1+ update-index))
              (ebox--pub--surface-mount-end mount)
              (aref updates (+ update-index 2)))
        (setq update-index (+ update-index 3)
              undo-index (+ undo-index 2))))
    (setf (ebox--pub--prepared-surface-mount-coordinate-undo prepared)
          undo
          (ebox--pub--prepared-surface-live-mounts prepared) mounts
          (ebox--pub--prepared-surface-live-mount-index prepared)
          (ebox--pub--surface-mount-index surface)
          (ebox--pub--prepared-surface-live-ledger prepared)
          (ebox--pub--surface-ledger surface))
    mounts))

(defun ebox--pub--restore-retained-mount-state (prepared)
  "Restore PREPARED retained mount coordinates after rollback."
  (let ((updates (ebox--pub--prepared-surface-mount-coordinate-updates prepared))
        (undo (ebox--pub--prepared-surface-mount-coordinate-undo prepared))
        (update-index 0)
        (undo-index 0))
    (when (and (vectorp updates) (vectorp undo))
      (while (< update-index (length updates))
        (let ((mount (aref updates update-index)))
          (setf (ebox--pub--surface-mount-start mount) (aref undo undo-index)
                (ebox--pub--surface-mount-end mount) (aref undo (1+ undo-index)))
          (setq update-index (+ update-index 3)
                undo-index (+ undo-index 2))))))
  (setf (ebox--pub--prepared-surface-mount-coordinate-undo prepared) nil))

(defun ebox--pub--surface-snapshot (surface)
  "Return a rollback snapshot of SURFACE side state."
  (ebox--pub--make-surface-snapshot
   :plan (ebox--pub--surface-plan surface) :objects (ebox--pub--surface-objects surface)
   :mounts (ebox--pub--surface-mounts surface) :index (ebox--pub--surface-index surface)
   :mount-index (ebox--pub--surface-mount-index surface)
   :ledger (ebox--pub--surface-ledger surface)
   :client-state (ebox--pub--surface-client-state surface)
   :producer (ebox--pub--surface-producer surface)
   :revision (ebox--pub--surface-revision surface) :report (ebox--pub--surface-report surface)
   :live (ebox--pub--surface-live surface) :stale (ebox--pub--surface-stale surface)))

(defun ebox--pub--surface-object-table (objects)
  "Return a path-indexed hash table containing OBJECTS."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (object objects)
      (puthash (ebox--pub--surface-object-path object) object table))
    table))

(defun ebox--pub--surface-report-value
    (prepared text-ops property-ops)
  "Build PREPARED's report from TEXT-OPS and PROPERTY-OPS."
  (let*
      ((surface (ebox--pub--prepared-surface-surface prepared))
       (old-revision (ebox--pub--surface-revision surface))
       (new-revision (1+ old-revision))
       (scoped (ebox--pub--prepared-surface-scope-objects prepared))
       (fallback (ebox--pub--prepared-surface-scope-fallback prepared))
       (patches (ebox--pub--prepared-surface-scope-patches prepared))
       (touched
        (if-let*
            ((batch
              (ebox--pub--prepared-surface-commit-batch prepared)))
            (cl-loop for patch in
                     (ebox--pub-commit-batch-patches batch) sum
                     (length (plist-get patch :replacement)))
          (if (and scoped (not fallback))
              (cl-loop for patch in patches sum
                       (length (plist-get patch :replacement)))
            (length (ebox--pub--prepared-surface-rendered prepared))))))
    (list :transaction-id ebox--pub--surface-transaction-id
          :surface-id (ebox--pub--surface-id surface) :old-revision
          old-revision :new-revision new-revision
          :candidate-source-writes
          (length ebox--pub--transaction-signals)
          :invalidated-bindings
          (ebox--pub--transaction-counter-delta :invalidated)
          :recomputed-bindings
          (ebox--pub--transaction-counter-delta :recomputed)
          :skipped-bindings
          (ebox--pub--transaction-counter-delta :skipped)
          :reconciled-objects
          (ebox--pub--prepared-surface-reconciled prepared)
          :created-objects
          (length (ebox--pub--prepared-surface-created prepared))
          :removed-objects
          (length (ebox--pub--prepared-surface-removed prepared))
          :moved-objects (ebox--pub--prepared-surface-moved prepared)
          :text-operations text-ops :property-operations property-ops
          :retained-content-p
          (ebox--pub--prepared-surface-retained-content-p prepared)
          :touched-characters touched :full-root
          (or (null scoped) fallback) :scope-count (length scoped)
          :scope-range-count (and scoped (length patches))
          :scope-fallback fallback :property-conflicts nil
          :rolled-back nil :commit-batch
          (and (ebox--pub--prepared-surface-commit-batch prepared) t)
          :retained-mount-state
          (and
           (ebox--pub--prepared-surface-retained-mount-state-p
            prepared)
           t)
          :failure nil :observer-errors nil :timing nil)))

(defun ebox--pub--scoped-content-ranges (patches)
  "Return candidate relative ranges from scoped PATCHES."
  (mapcar (lambda (patch)
            (cons (plist-get patch :new-start)
                  (plist-get patch :new-end)))
          patches))

(defun ebox--pub--publish-scoped-content-text (surface rendered patches)
  "Publish scoped PATCHES from RENDERED for SURFACE.  Return the number of text
operations."
  (let ((base (marker-position (ebox--pub--surface-start surface)))
        (count 0))
    (dolist (patch (reverse patches))
      (let* ((start (+ base (plist-get patch :old-start)))
             (end (+ base (plist-get patch :old-end)))
             (replacement (plist-get patch :replacement))
             (old-plain (buffer-substring-no-properties start end))
             (new-plain (substring-no-properties replacement))
             (prefix (ebox--pub--common-prefix-length old-plain new-plain))
             (suffix (ebox--pub--common-suffix-length old-plain new-plain prefix))
             (old-end (- end suffix))
             (new-end (- (length replacement) suffix)))
        (unless (equal old-plain new-plain)
          (delete-region (+ start prefix) old-end)
          (goto-char (+ start prefix))
          (let ((inserted (substring replacement prefix new-end)))
            (insert inserted)
            (when (ebox--pub--validate-published-content-range
                   (ebox--pub--surface-buffer surface) (+ start prefix) inserted)
              (push (cons (+ (plist-get patch :new-start) prefix)
                          (+ (plist-get patch :new-start) new-end))
                    ebox--pub--content-published-ranges)))
          (cl-incf count))))
    (set-marker (ebox--pub--surface-start surface) base)
    (set-marker (ebox--pub--surface-end surface) (+ base (length rendered)))
    count))

(defun ebox--pub--publish-retained-content-text (prepared)
  "Publish PREPARED retained content in one full-surface text operation.  The
candidate proof guarantees that the retained surface scope is exactly the
surface range.  RENDERED already carries its final text properties, so a
delete/insert preserves the authoritative property runs without constructing
the generic property-operation ledger."
  (let* ((surface (ebox--pub--prepared-surface-surface prepared))
         (buffer (ebox--pub--surface-buffer surface))
         (rendered (ebox--pub--prepared-surface-rendered prepared))
         (range (ebox--pub--surface-range surface))
         (start (car range))
         (end (cdr range))
         (changed (not (ebox--pub--text-property-semantic-equal-p
                        (with-current-buffer buffer
                          (buffer-substring start end))
                        rendered))))
    (with-current-buffer buffer
      (let ((inhibit-read-only
             (plist-get (ebox--pub--surface-options surface) :inhibit-read-only)))
        (unless (= start (point))
          (goto-char start))
        (when changed
          (delete-region start end)
          (goto-char start)
          (insert rendered))
        (set-marker (ebox--pub--surface-start surface) start)
        (set-marker (ebox--pub--surface-end surface) (+ start (length rendered)))))
    (when changed
      (with-current-buffer buffer
        (unless (ebox--pub--validate-published-content-range buffer start rendered)
          (signal 'ebox--pub-publication-mismatch
                  (list :surface (ebox--pub--surface-id surface)
                        :reason 'retained-content-properties)))))
    (if changed 1 0)))

(defun ebox--pub--publish-buffer-content (prepared)
  "Publish PREPARED's text and properties, returning operation counts."
  (cl-block publish
    (when-let* ((batch (ebox--pub--prepared-surface-commit-batch prepared)))
      (let* ((surface (ebox--pub--prepared-surface-surface prepared))
             (counts (ebox--pub--commit-batch-apply-patches surface batch)))
        (ebox--pub--publication-step 'text surface)
        (ebox--pub--commit-batch-validate-buffer surface batch)
        (ebox--pub--publication-step 'property surface)
        (cl-return-from publish counts)))
  (let* ((surface (ebox--pub--prepared-surface-surface prepared))
         (buffer (ebox--pub--surface-buffer surface))
         (rendered (ebox--pub--prepared-surface-rendered prepared))
         (scoped (ebox--pub--prepared-surface-scope-objects prepared))
         (fallback (ebox--pub--prepared-surface-scope-fallback prepared))
         (patches (ebox--pub--prepared-surface-scope-patches prepared))
         (text-operations 0)
         property-operations)
    (let (ebox--pub--content-published-ranges)
      (with-current-buffer buffer
        (let ((point-before (point)))
          (unwind-protect
              (save-restriction
            (widen)
            (let ((inhibit-read-only
                   (plist-get (ebox--pub--surface-options surface) :inhibit-read-only)))
              (setq text-operations
                    (if (ebox--pub--prepared-surface-retained-content-p prepared)
                        (ebox--pub--publish-retained-content-text prepared)
                      (if (and scoped (not fallback))
                          (ebox--pub--publish-scoped-content-text
                           surface rendered patches)
                        (ebox--pub--content-text-operation surface rendered))))
              (ebox--pub--publication-step 'text surface)
              (unless (ebox--pub--prepared-surface-retained-content-p prepared)
                (setq property-operations
                      (ebox--pub--content-property-operations
                       surface rendered
                       (and scoped (not fallback)
                            (ebox--pub--scoped-content-ranges patches))
                       (and scoped (not fallback))))
                (ebox--pub--apply-content-property-operations buffer property-operations)
                (ebox--pub--publication-step 'property surface))
              (when (ebox--pub--prepared-surface-retained-content-p prepared)
                (ebox--pub--publication-step 'property surface))))
            (goto-char (min point-before (point-max)))))
      (cons text-operations (length property-operations)))))))

(defun ebox--pub--promote-prepared-objects (prepared)
  "Promote PREPARED's touched identities to live state."
  (let ((surface (ebox--pub--prepared-surface-surface prepared))
        (context (ebox--pub--prepared-surface-context prepared)))
    (dolist (object (ebox--pub--prepared-surface-objects prepared))
      (setf (ebox--pub--surface-object-surface object) surface
            (ebox--pub--surface-object-live object) t
            (ebox--pub--surface-object-disposed object) nil
            (ebox--pub--surface-object-candidate-context object) nil))
    (setf (ebox--pub--context-active context) nil)))

(defun ebox--pub--swap-surface-state (prepared counts)
  "Promote PREPARED side state using operation COUNTS."
  (let* ((surface (ebox--pub--prepared-surface-surface prepared))
         (mounts (ebox--pub--prepared-surface-live-mounts prepared))
         (ledger (ebox--pub--prepared-surface-live-ledger prepared))
         (report (ebox--pub--surface-report-value prepared (car counts) (cdr counts))))
    (ebox--pub--promote-prepared-objects prepared)
    (setf (ebox--pub--surface-plan surface) (ebox--pub--prepared-surface-plan prepared)
          (ebox--pub--surface-objects surface)
          (if (ebox--pub--prepared-surface-retained-mount-state-p prepared)
              (ebox--pub--surface-objects surface)
            (ebox--pub--surface-object-table
             (ebox--pub--prepared-surface-objects prepared)))
          (ebox--pub--surface-mounts surface) mounts
          (ebox--pub--surface-index surface) mounts
          (ebox--pub--surface-mount-index surface)
          (ebox--pub--prepared-surface-live-mount-index prepared)
          (ebox--pub--surface-ledger surface) ledger
          (ebox--pub--surface-client-state surface)
          (ebox--pub--prepared-surface-client-state prepared)
          (ebox--pub--surface-producer surface) (ebox--pub--prepared-surface-producer prepared)
          (ebox--pub--surface-revision surface) (1+ (ebox--pub--surface-revision surface))
          (ebox--pub--surface-report surface) report
          (ebox--pub--surface-live surface) t
          (ebox--pub--surface-stale surface) nil
          (ebox--pub--prepared-surface-report prepared) report)
    (ebox--pub--publication-step 'client-state surface)
    (when (ebox--pub--prepared-surface-initial prepared)
      (ebox--pub--register-live-surface surface))))

(defun ebox--pub--publish-one-surface (prepared)
  "Publish PREPARED buffer and side state."
  (let*
      ((surface (ebox--pub--prepared-surface-surface prepared))
       (observed (ebox--pub--surface-observers surface))
       (started (and observed (ebox--pub--surface-observation-clock)))
       (counts (ebox--pub--publish-buffer-content prepared)))
    (if (ebox--pub--prepared-surface-retained-mount-state-p prepared)
        (ebox--pub--retain-candidate-mount-state prepared)
      (ebox--pub--create-candidate-mount-state prepared))
    (when-let*
        ((batch
          (and
           (not
            (ebox--pub--prepared-surface-retained-mount-state-p
             prepared))
           (ebox--pub--prepared-surface-commit-batch prepared))))
      (ebox--pub--commit-batch-validate-mounts surface batch
                                               (ebox--pub--prepared-surface-live-mounts
                                                prepared)))
    (ebox--pub--publication-step 'marker surface)
    (ebox--pub--publication-step 'index surface)
    (ebox--pub--swap-surface-state prepared counts)
    (when started
      (let*
          ((duration-ms
            (* 1000.0
               (- (ebox--pub--surface-observation-clock) started)))
           (report (ebox--pub--surface-report surface)))
        (setq report (plist-put report :provider 'ebox-publication)
              report (plist-put report :stage 'publication) report
              (plist-put report :duration-ms duration-ms) report
              (plist-put report :timing
                         (list :publication (/ duration-ms 1000.0))))
        (setf (ebox--pub--surface-report surface) report
              (ebox--pub--prepared-surface-report prepared) report)))))

(defun ebox--pub--journal-intervals (prepared-list)
  "Return buffer intervals whose properties PREPARED-LIST may mutate."
  (let (entries)
    (dolist (prepared prepared-list)
      (let ((surface (ebox--pub--prepared-surface-surface prepared)))
        (if
            (and (ebox--pub--prepared-surface-scope-objects prepared)
                 (not
                  (ebox--pub--prepared-surface-scope-fallback prepared)))
            (let
                ((base
                  (marker-position (ebox--pub--surface-start surface))))
              (dolist
                  (patch
                   (ebox--pub--prepared-surface-scope-patches prepared))
                (push
                 (list (ebox--pub--surface-buffer surface)
                       (+ base (plist-get patch :old-start))
                       (+ base (plist-get patch :old-end)))
                 entries)))
          (pcase-let
              ((`(,start \, end) (ebox--pub--surface-range surface)))
            (push (list (ebox--pub--surface-buffer surface) start end)
                  entries)))))
    entries))

(defun ebox--pub--merge-buffer-intervals (entries)
  "Merge overlapping journal ENTRIES per buffer."
  (let ((by-buffer (make-hash-table :test #'eq)) result)
    (dolist (entry entries)
      (push (cdr entry) (gethash (car entry) by-buffer)))
    (maphash
     (lambda (buffer intervals)
       (setq intervals (sort intervals (lambda (a b) (< (car a) (car b)))))
       (let (merged)
         (dolist (interval intervals)
           (if (and merged (<= (car interval) (cadar merged)))
               (setcar (cdar merged) (max (cadar merged) (cadr interval)))
             (push (copy-sequence interval) merged)))
         (dolist (interval (nreverse merged))
           (push (list buffer (car interval) (cadr interval)) result))))
     by-buffer)
    result))

(defun ebox--pub--capture-property-journals (prepared-list)
  "Capture direct property journals for PREPARED-LIST."
  (mapcar
   (lambda (entry)
     (pcase-let ((`(,buffer ,start ,end) entry))
       (list buffer start end
             (with-current-buffer buffer
               (save-restriction
                 (widen) (buffer-substring start end))))))
   (ebox--pub--merge-buffer-intervals (ebox--pub--journal-intervals prepared-list))))

(defun ebox--pub--replay-string-properties (buffer start string)
  "Restore STRING's direct properties into BUFFER starting at START."
  (let ((length (length string)) (offset 0))
    (when (> length 0)
      (set-text-properties start (+ start length) nil buffer)
      (while (< offset length)
        (let ((next (next-property-change offset string length)))
          (set-text-properties (+ start offset) (+ start next)
                               (text-properties-at offset string) buffer)
          (setq offset next))))))

(defun ebox--pub--restore-property-journals (journals)
  "Restore direct property JOURNALS after buffer change cancellation."
  (dolist (journal journals)
    (pcase-let ((`(,buffer ,start ,_end ,string) journal))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (save-restriction
            (widen)
            (let ((inhibit-read-only t))
              (with-silent-modifications
                (ebox--pub--replay-string-properties buffer start string)))))))))

(defun ebox--pub--prepared-buffers (prepared-list)
  "Return distinct live buffers affected by PREPARED-LIST."
  (let ((seen (make-hash-table :test #'eq)) buffers)
    (dolist (prepared prepared-list)
      (let ((buffer
             (ebox--pub--surface-buffer (ebox--pub--prepared-surface-surface prepared))))
        (unless (gethash buffer seen)
          (puthash buffer t seen)
          (push buffer buffers))))
    (nreverse buffers)))

(defun ebox--pub--capture-view-state (buffers)
  "Capture point, windows, and modified state for BUFFERS."
  (let (states success)
    (unwind-protect
        (progn
          (dolist (buffer buffers)
            (with-current-buffer buffer
              (let ((state
                     ;; Point is a cursor location, not an insertion anchor:
                     ;; content publication must not make it follow a patch
                     ;; to the end of the inserted text.
                     (list buffer (copy-marker (point) nil)
                           (buffer-modified-p) nil)))
                (push state states)
                (dolist (window (get-buffer-window-list buffer nil t))
                  (push (cons window
                              (copy-marker (window-start window) nil))
                        (nth 3 state)))
                (setf (nth 3 state) (nreverse (nth 3 state))))))
          (setq states (nreverse states)
                success t)
          states)
      (unless success (ebox--pub--dispose-view-state states)))))

(defun ebox--pub--dispose-view-state (states)
  "Dispose marker storage retained by captured view STATES."
  (dolist (state states)
    (pcase-let ((`(,_buffer ,point-marker ,_modified ,windows) state))
      (ebox--pub--dispose-marker point-marker)
      (dolist (entry windows) (ebox--pub--dispose-marker (cdr entry))))))

(defun ebox--pub--restore-view-state (states &optional retain-markers)
  "Restore captured point, window, and modified STATES.  When RETAIN-MARKERS is
non-nil, keep snapshot markers for rollback."
  (dolist (state states)
    (pcase-let ((`(,buffer ,point-marker ,modified ,windows) state))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when-let* ((position (marker-position point-marker)))
            (goto-char (min (point-max) (max (point-min) position))))
          (set-buffer-modified-p modified))
        (dolist (entry windows)
          (when (window-live-p (car entry))
            (when-let* ((position (marker-position (cdr entry))))
              (set-window-start (car entry) position t)))))
      (unless retain-markers
        (ebox--pub--dispose-marker point-marker)
        (dolist (entry windows) (ebox--pub--dispose-marker (cdr entry)))))))

(defun ebox--pub--dispose-content-mounts (mounts)
  "Detach private markers owned by content MOUNTS."
  (dolist (mount mounts)
    (progn
      (ebox--pub--dispose-marker
       (ebox--pub--surface-mount-start mount))
      (ebox--pub--dispose-marker (ebox--pub--surface-mount-end mount)))))

(defun ebox--pub--dispose-ledger (ledger)
  "Detach interval markers owned by property LEDGER entries."
  (dolist (entry ledger)
    (ebox--pub--dispose-marker (ebox--pub--property-ledger-start entry))
    (ebox--pub--dispose-marker (ebox--pub--property-ledger-end entry))))

(defun ebox--pub--unregister-surface (surface)
  "Remove SURFACE from weak and buffer-local registries."
  (remhash (ebox--pub--surface-id surface) ebox--pub--surfaces)
  (when (buffer-live-p (ebox--pub--surface-buffer surface))
    (with-current-buffer (ebox--pub--surface-buffer surface)
      (setq ebox--pub--buffer-surfaces (delq surface ebox--pub--buffer-surfaces))
      (unless ebox--pub--buffer-surfaces
        (remove-hook 'before-change-functions #'ebox--pub--surface-before-change t)
        (remove-hook 'after-change-functions #'ebox--pub--surface-after-change t)
        (remove-hook 'kill-buffer-hook #'ebox--pub--surface-buffer-killed t)))))

(defun ebox--pub--restore-surface-snapshot (prepared snapshot)
  "Restore PREPARED's surface from SNAPSHOT after failed publication."
  (let ((surface (ebox--pub--prepared-surface-surface prepared)))
    (ebox--pub--restore-retained-mount-state prepared)
    (ebox--pub--dispose-content-mounts
     (ebox--pub--prepared-surface-live-mounts prepared))
    (ebox--pub--dispose-ledger (ebox--pub--prepared-surface-live-ledger prepared))
    (if (not (buffer-live-p (ebox--pub--surface-buffer surface)))
        (progn
          (when (ebox--pub--surface-snapshot-objects snapshot)
            (maphash (lambda (_path object)
                       (setf (ebox--pub--surface-object-live object) nil
                             (ebox--pub--surface-object-disposed object) t))
                     (ebox--pub--surface-snapshot-objects snapshot)))
          (setf (ebox--pub--surface-live surface) nil
                (ebox--pub--surface-stale surface) 'killed
                (ebox--pub--surface-objects surface)
                (ebox--pub--surface-snapshot-objects snapshot)
                (ebox--pub--surface-mounts surface)
                (ebox--pub--surface-snapshot-mounts snapshot)
                (ebox--pub--surface-index surface)
                (ebox--pub--surface-snapshot-index snapshot)
            (ebox--pub--surface-mount-index surface)
            (ebox--pub--surface-snapshot-mount-index snapshot)
            (ebox--pub--surface-ledger surface)
            (ebox--pub--surface-snapshot-ledger snapshot)))
      (when (and (ebox--pub--surface-live surface)
                 (not (ebox--pub--surface-snapshot-live snapshot)))
        (ebox--pub--unregister-surface surface))
      (dolist (object (ebox--pub--prepared-surface-created prepared))
        (setf (ebox--pub--surface-object-live object) nil
              (ebox--pub--surface-object-disposed object) t))
      (when (ebox--pub--surface-snapshot-objects snapshot)
        (maphash (lambda (_path object)
                   (setf (ebox--pub--surface-object-live object)
                         (ebox--pub--surface-snapshot-live snapshot)
                         (ebox--pub--surface-object-disposed object) nil))
                 (ebox--pub--surface-snapshot-objects snapshot)))
          (setf (ebox--pub--surface-plan surface) (ebox--pub--surface-snapshot-plan snapshot)
            (ebox--pub--surface-objects surface) (ebox--pub--surface-snapshot-objects snapshot)
            (ebox--pub--surface-mounts surface) (ebox--pub--surface-snapshot-mounts snapshot)
            (ebox--pub--surface-index surface) (ebox--pub--surface-snapshot-index snapshot)
            (ebox--pub--surface-mount-index surface)
            (ebox--pub--surface-snapshot-mount-index snapshot)
            (ebox--pub--surface-ledger surface) (ebox--pub--surface-snapshot-ledger snapshot)
            (ebox--pub--surface-client-state surface)
            (ebox--pub--surface-snapshot-client-state snapshot)
            (ebox--pub--surface-producer surface)
            (ebox--pub--surface-snapshot-producer snapshot)
            (ebox--pub--surface-revision surface)
            (ebox--pub--surface-snapshot-revision snapshot)
            (ebox--pub--surface-report surface) (ebox--pub--surface-snapshot-report snapshot)
            (ebox--pub--surface-live surface) (ebox--pub--surface-snapshot-live snapshot)
            (ebox--pub--surface-stale surface) (ebox--pub--surface-snapshot-stale snapshot)))))

(defun ebox--pub--prepare-change-group-for-buffers (buffers)
  "Prepare and activate one multi-buffer change group for BUFFERS."
  (let (handle success)
    (unwind-protect
        (progn
          (dolist (buffer buffers)
            (unless (buffer-live-p buffer)
              (signal 'ebox--pub-dead-surface (list buffer)))
            (setq handle (nconc handle (prepare-change-group buffer))))
          (activate-change-group handle)
          (setq success t)
          handle)
      (unless success (ebox--pub--cancel-change-group-safely handle)))))

(defun ebox--pub--surface-state-snapshots (prepared-list)
  "Return side-state snapshots for PREPARED-LIST."
  (mapcar (lambda (prepared)
            (cons prepared
                  (ebox--pub--surface-snapshot
                   (ebox--pub--prepared-surface-surface prepared))))
          prepared-list))

(defun ebox--pub--shadow-apply-commit-batch-to-string (string batch)
  "Return STRING with BATCH patches applied without touching a buffer."
  (let ((patches (ebox--pub-commit-batch-patches batch)))
    (if (null patches)
        (copy-sequence string)
      (let ((cursor 0) pieces)
        (dolist (patch patches)
          (push (substring string cursor (plist-get patch :old-start)) pieces)
          (push (plist-get patch :replacement) pieces)
          (setq cursor (plist-get patch :old-end)))
        (push (substring string cursor) pieces)
        (apply #'concat (nreverse pieces))))))

(cl-defstruct (ebox--pub--shadow-batch-output
               (:constructor ebox--pub--make-shadow-batch-output))
  "Detached patch evidence over the unchanged output of a retained surface."
  base patches extent)

(defun ebox--pub--shadow-batch-output-create (base batch)
  "Snapshot BASE and BATCH's output evidence without rebuilding the target.
BASE is the already captured buffer string.  Patch strings and coordinates
are detached before publication, so changing a staged patch cannot change
the expected output.  Native callback identities survive the snapshot."
  (ebox--pub--make-shadow-batch-output
   :base base :extent (ebox--pub-commit-batch-target-extent batch)
   :patches
   (mapcar
    (lambda (patch)
      (list :old-start (plist-get patch :old-start)
            :old-end (plist-get patch :old-end)
            :new-start (plist-get patch :new-start)
            :new-end (plist-get patch :new-end)
            :mouse-face-first
            (let ((text (plist-get patch :replacement)))
              (and (> (length text) 0) (get-text-property 0 'mouse-face text)))
            :mouse-face-last
            (let ((text (plist-get patch :replacement)))
              (and (> (length text) 0)
                   (get-text-property (1- (length text)) 'mouse-face text)))
            :replacement
            (ebox-text-property-value-copy (plist-get patch :replacement))))
    (ebox--pub-commit-batch-patches batch))))

(defun ebox--pub--shadow-props-identical-p (left right)
  "Return non-nil when property lists LEFT and RIGHT have identical values.  An
identity match is sufficient proof even for opaque native callbacks.
Different order or copied values require the ordinary policy comparison."
  (while (and left right (eq (car left) (car right))
              (eq (cadr left) (cadr right)))
    (setq left (cddr left) right (cddr right)))
  (and (null left) (null right)))

(defvar ebox--pub--shadow-output-reusable-p nil
  "Non-nil while a live output proof has used only identity or pure policies.
Custom equality functions may retain or mutate their arguments without
changing the buffer tick, so their proofs need a separate actual snapshot.")

(defun ebox--pub--shadow-text-range-equal-p
  (left left-start left-end right right-start right-end)
  "Compare LEFT from LEFT-START to LEFT-END with RIGHT's corresponding range.
RIGHT-START and RIGHT-END delimit that range in the RIGHT string or buffer.
Unchanged runs use property identity as a proof; changed identities still
use the same native-property policies as ordinary publication."
  (and (= (- left-end left-start) (- right-end right-start))
       (eq t (if (bufferp right)
                 (compare-strings
                  left left-start left-end
                  (with-current-buffer right
                    (buffer-substring-no-properties right-start right-end))
                  0 nil)
               (compare-strings left left-start left-end
                                right right-start right-end)))
       (ebox--pub--mouse-face-groups-equal-p
        left left-start left-end right right-start right-end)
       (let ((equal-p t))
         (while (and equal-p (< left-start left-end))
           (let ((left-props (text-properties-at left-start left))
                 (right-props (text-properties-at right-start right)))
             (unless (or (ebox--pub--shadow-props-identical-p left-props right-props)
                         (progn
                           (when ebox--pub--shadow-output-reusable-p
                             (setq ebox--pub--shadow-output-reusable-p
                                   (cl-loop for (property _value) on left-props by #'cddr
                                            always
                                            (memq (ebox-property-policy-equality
                                                   (ebox-register-text-property property))
                                                  '(eq equal ebox-property--native-value-equal-p)))))
                           (ebox--pub--plan-props-equal-p left-props right-props)))
               (setq equal-p nil)))
           (let ((step
                  (min (- (next-property-change left-start left left-end)
                          left-start)
                       (- (next-property-change right-start right right-end)
                          right-start))))
             (setq left-start (+ left-start step)
                   right-start (+ right-start step))))
         equal-p)))

(defun ebox--pub--shadow-batch-output-equal-p
    (expected actual &optional actual-start actual-end groups-only)
  "Prove ACTUAL equals EXPECTED's patches and every unchanged outside gap.
This checks the whole output, including hostile writes made with hooks or
undo recording inhibited.  Only construction of a second full output and
semantic comparison of identical property values are avoided.  ACTUAL may be
a buffer delimited by ACTUAL-START and ACTUAL-END.  With GROUPS-ONLY,
compare only native hover topology.  This shares the same segment and seam
evidence with precommit validation without copying output."
  (setq actual-start (or actual-start 0)
        actual-end (or actual-end (and (stringp actual) (length actual))))
  (and (or (stringp actual) (buffer-live-p actual))
       actual-end
       (= (- actual-end actual-start) (ebox--pub--shadow-batch-output-extent expected))
       (let ((base (ebox--pub--shadow-batch-output-base expected))
             (patches (ebox--pub--shadow-batch-output-patches expected))
             (old-position 0) (new-position 0) (equal-p t)
             previous-face have-previous)
         (cl-labels
             ((segment-equal-p
               (source from to target-start target-end first-face last-face)
               (setq target-start (+ actual-start target-start)
                     target-end (+ actual-start target-end))
               (and
                (or (= from to)
                    (prog1
                        (or (not have-previous)
                            (eq (eq previous-face first-face)
                                (eq (get-text-property (1- target-start)
                                                       'mouse-face actual)
                                    (get-text-property target-start
                                                       'mouse-face actual))))
                      (setq previous-face last-face have-previous t)))
                (if groups-only
                    (ebox--pub--mouse-face-groups-equal-p
                     source from to actual target-start target-end)
                  (ebox--pub--shadow-text-range-equal-p
                   source from to actual target-start target-end))))
              (base-equal-p (from to target-start target-end)
                (segment-equal-p
                 base from to target-start target-end
                 (and (< from to) (get-text-property from 'mouse-face base))
                 (and (< from to) (get-text-property (1- to) 'mouse-face base)))))
         (while (and equal-p patches)
           (let* ((patch (pop patches))
                  (old-start (plist-get patch :old-start))
                  (new-start (plist-get patch :new-start))
                  (replacement (plist-get patch :replacement)))
             (setq equal-p
                   (and (base-equal-p old-position old-start new-position new-start)
                        (segment-equal-p
                         replacement 0 (length replacement)
                         new-start (plist-get patch :new-end)
                         (plist-get patch :mouse-face-first)
                         (plist-get patch :mouse-face-last))))
             (setq old-position (plist-get patch :old-end)
                   new-position (plist-get patch :new-end))))
         (and equal-p
              (base-equal-p old-position (length base)
                            new-position (- actual-end actual-start)))))))

(defun ebox--pub--shadow-surface-output (surface)
  "Return SURFACE's current text and direct properties as one snapshot."
  (pcase-let ((`(,start . ,end) (ebox--pub--surface-range surface)))
    (with-current-buffer (ebox--pub--surface-buffer surface)
      (buffer-substring start end))))

(defun ebox--pub--shadow-target-output (prepared old-output)
  "Return PREPARED's expected output using the retained baseline OLD-OUTPUT."
  (if-let* ((batch (ebox--pub--prepared-surface-commit-batch prepared)))
      (ebox--pub--shadow-batch-output-create old-output batch)
    (ebox--pub--prepared-surface-rendered prepared)))

(defun ebox--pub--surface-publish-transaction ()
  "Publish owned candidates using one journal and one acceptance boundary."
  (let* ((state (ebox--pub--surface-extension-state))
         (table (gethash 'prepared state))
         (prepared (and table (ebox--pub--sorted-prepared-surfaces table))))
    (when prepared
      (let* ((buffers (ebox--pub--prepared-buffers prepared))
             (journals (ebox--pub--capture-property-journals prepared))
             (views (ebox--pub--capture-view-state buffers))
             (snapshots (ebox--pub--surface-state-snapshots prepared)))
        (puthash 'changed prepared state)
        (puthash 'journals journals state)
        (puthash 'views views state)
        (puthash 'snapshots snapshots state)
        (puthash 'change-group (ebox--pub--prepare-change-group-for-buffers buffers) state)
        (puthash 'surface-transaction-id-before ebox--pub--surface-transaction-id state)
        ;; Producer, writer and rollback coordinator share PREPARED.
        ;; No second target-entry graph or copied client state is constructed.
        (dolist (candidate prepared)
          (ebox--pub--assign-prepared-mount-ids candidate)
          (let ((old (ebox--pub--shadow-surface-output
                      (ebox--pub--prepared-surface-surface candidate))))
            (setf (ebox--pub--prepared-surface-baseline-output candidate) old
                  (ebox--pub--prepared-surface-expected-output candidate)
                  (ebox--pub--shadow-target-output candidate old))))
        (cl-incf ebox--pub--surface-transaction-id)
        (setq ebox--pub--publication-started-p t)
        (let ((ebox--pub--surface-publishing t))
          (dolist (candidate prepared)
            (ebox--pub--publish-one-surface candidate)))))))

(defun ebox--pub--surface-precommit-step (step state)
  "Report precommit STEP for transaction STATE."
  (when ebox--pub--surface-precommit-step-function
    (funcall ebox--pub--surface-precommit-step-function step state)))

(defun ebox--pub--validate-retained-batch-precommit (prepared snapshot)
  "Validate PREPARED retained batch against committed SNAPSHOT identities."
  (let* ((surface (ebox--pub--prepared-surface-surface prepared))
         (batch (ebox--pub--prepared-surface-commit-batch prepared))
         (mounts (ebox--pub--surface-mounts surface))
         (mount-index (ebox--pub--surface-mount-index surface)))
    (ebox--pub--validate-live-surface surface)
    (unless (and batch
                 (eq (ebox--pub--surface-plan surface)
                     (ebox--pub--prepared-surface-plan prepared))
                 (eq (ebox--pub--surface-objects surface)
                     (ebox--pub--surface-snapshot-objects snapshot))
                 (eq mounts (ebox--pub--surface-snapshot-mounts snapshot))
                 (eq mount-index
                     (ebox--pub--surface-snapshot-mount-index snapshot))
                 (eq (ebox--pub--surface-index surface) mounts)
                 (eq (ebox--pub--prepared-surface-live-mounts prepared) mounts)
                 (eq (ebox--pub--prepared-surface-live-mount-index prepared)
                     mount-index)
                 (= (ebox--pub--surface-revision surface)
                    (ebox--pub-commit-batch-target-revision batch))
                 (not (ebox--pub--context-active
                       (ebox--pub--prepared-surface-context prepared)))
                 (plist-get (ebox--pub--surface-report surface) :commit-batch)
                 (plist-get (ebox--pub--surface-report surface)
                            :retained-mount-state))
      (signal 'ebox--pub-surface-error
              (list :invalid-retained-batch-precommit
                    (ebox--pub--surface-id surface))))))

(defun ebox--pub--validate-retained-batch-hover-groups ()
  "Validate final output, including writes by publication participants."
  (when-let* ((state (ebox--pub--transaction-extension ebox--pub--surface-extension-key)))
    (dolist (prepared (gethash 'changed state))
      (let* ((surface (ebox--pub--prepared-surface-surface prepared))
             (range (ebox--pub--surface-range surface))
             (buffer (ebox--pub--surface-buffer surface))
             (expected (ebox--pub--prepared-surface-expected-output prepared)))
        (unless (if (ebox--pub--shadow-batch-output-p expected)
                    (ebox--pub--shadow-batch-output-equal-p
                     expected buffer (car range) (cdr range))
                  (with-current-buffer buffer
                    (ebox--pub--text-property-semantic-equal-p
                     expected (buffer-substring (car range) (cdr range)))))
          (signal 'ebox--pub-publication-mismatch
                  (list :surface (ebox--pub--surface-id surface)
                        :reason 'candidate-output)))))))

(defun ebox--pub--validate-surface-precommit (state)
  "Validate final published semantics and rollback ownership in STATE."
  (unless
      (and (gethash 'change-group state)
           (listp (gethash 'changed state))
           (listp (gethash 'snapshots state))
           (listp (gethash 'views state)))
    (signal 'ebox--pub-surface-error (list :invalid-precommit-state)))
  (dolist (view (gethash 'views state))
    (unless
        (and (bufferp (nth 0 view)) (markerp (nth 1 view))
             (cl-every (lambda (entry) (markerp (cdr entry)))
                       (nth 3 view)))
      (signal 'ebox--pub-surface-error
              (list :invalid-view-cleanup view))))
  (dolist (entry (gethash 'snapshots state))
    (unless
        (and (ebox--pub--prepared-surface-p (car entry))
             (ebox--pub--surface-snapshot-p (cdr entry)))
      (signal 'ebox--pub-surface-error
              (list :invalid-surface-cleanup entry)))
    (let ((prepared (car entry)) (snapshot (cdr entry)))
      (if
          (ebox--pub--prepared-surface-retained-mount-state-p prepared)
          (ebox--pub--validate-retained-batch-precommit prepared
                                                        snapshot)
        (let*
            ((surface (ebox--pub--prepared-surface-surface prepared))
             (plan (ebox--pub--surface-plan surface))
             (objects (ebox--pub--surface-objects surface))
             (mounts (ebox--pub--surface-mounts surface))
             (mount-index (ebox--pub--surface-mount-index surface))
             (capability (ebox--pub--surface-capability surface))
             (mount-set (make-hash-table :test #'eq))
             (indexed-mount-set (make-hash-table :test #'eq)))
          (ebox--pub--validate-live-surface surface)
          (unless
              (eq plan (ebox--pub--prepared-surface-plan prepared))
            (signal 'ebox--pub-surface-error
                    (list :invalid-published-plan surface)))
          (ebox--pub--validate-surface-plan-tree plan)
          (ebox--pub--validate-plan-capability plan capability)
          (ebox--pub--validate-context-tree
           (ebox--pub--prepared-surface-context prepared) plan)
          (unless
              (and (hash-table-p objects) (hash-table-p mount-index)
                   (eq (ebox--pub--surface-index surface) mounts))
            (signal 'ebox--pub-surface-error
                    (list :invalid-published-index surface)))
          (maphash
           (lambda (path object)
             (unless
                 (and (ebox--pub-object-p object)
                      (equal path
                             (ebox--pub--surface-object-path object))
                      (eq (ebox--pub--surface-object-surface object)
                          surface)
                      (ebox--pub--surface-object-live object)
                      (not (ebox--pub--surface-object-disposed object))
                      (null
                       (ebox--pub--surface-object-candidate-context
                        object)))
               (signal 'ebox--pub-surface-error
                       (list :invalid-published-object path object))))
           objects)
          (dolist (mount mounts)
            (when (gethash mount mount-set)
              (signal 'ebox--pub-surface-error
                      (list :duplicate-published-mount mount)))
            (puthash mount t mount-set))
          (maphash
           (lambda (object entries)
             (unless
                 (and (ebox--pub-object-p object)
                      (eq
                       (gethash
                        (ebox--pub--surface-object-path object)
                        objects)
                       object))
               (signal 'ebox--pub-surface-error
                       (list :invalid-mount-index-owner object)))
             (dolist (mount entries)
               (unless
                   (and (gethash mount mount-set)
                        (eq (ebox--pub--surface-mount-object mount)
                            object)
                        (not (gethash mount indexed-mount-set)))
                 (signal 'ebox--pub-surface-error
                         (list :invalid-mount-index-entry object mount)))
               (puthash mount t indexed-mount-set)))
           mount-index)
          (unless
              (= (hash-table-count mount-set)
                 (hash-table-count indexed-mount-set))
            (signal 'ebox--pub-surface-error
                    (list :incomplete-mount-index surface)))
          (dolist (mount mounts)
            (let
                ((object
                  (and (ebox--pub--surface-mount-p mount)
                       (ebox--pub--surface-mount-object mount))))
              (unless
                  (and object
                       (eq
                        (gethash
                         (ebox--pub--surface-object-path object)
                         objects)
                        object)
                       (eq (ebox--pub--surface-mount-capability mount)
                           capability)
                       (gethash mount indexed-mount-set))
                (signal 'ebox--pub-surface-error
                        (list :invalid-published-mount mount)))
              (ebox-text--validate-buffer-range
               (ebox--pub--surface-buffer surface)
               (ebox--pub--surface-mount-start mount)
               (ebox--pub--surface-mount-end mount))
              (progn
                (when (ebox--pub--surface-mount-anchor mount)
                  (signal 'ebox--pub-surface-error
                          (list :invalid-content-anchor mount)))))))))
    (ebox--pub--validate-retained-batch-hover-groups) state))

(defun ebox--pub--surface-prevalidate-cleanup (state)
  "Validate marker-backed cleanup lists retained in surface STATE."
  (dolist (entry (gethash 'snapshots state))
    (let ((prepared (car entry)))
      (unless
          (ebox--pub--prepared-surface-retained-mount-state-p prepared)
        (let*
            ((snapshot (cdr entry))
             (surface (ebox--pub--prepared-surface-surface prepared))
             (coordinate-p
              (plist-get (ebox--pub--surface-options surface)
                         :coordinate-mounts)))
          (dolist
              (mount (ebox--pub--surface-snapshot-mounts snapshot))
            (progn
              (unless
                  (or
                   (and
                    (markerp (ebox--pub--surface-mount-start mount))
                    (markerp (ebox--pub--surface-mount-end mount)))
                   (and coordinate-p
                        (integerp
                         (ebox--pub--surface-mount-start mount))
                        (integerp (ebox--pub--surface-mount-end mount))))
                (signal 'ebox--pub-surface-error
                        (list :invalid-mount-cleanup mount)))))
          (dolist
              (ledger (ebox--pub--surface-snapshot-ledger snapshot))
            (unless
                (and
                 (markerp (ebox--pub--property-ledger-start ledger))
                 (markerp (ebox--pub--property-ledger-end ledger)))
              (signal 'ebox--pub-surface-error
                      (list :invalid-ledger-cleanup ledger))))))))
  state)

(defun ebox--pub--surface-final-accept ()
  "Accept the active surface transaction's prepared change group."
  (when-let* ((state (ebox--pub--transaction-extension ebox--pub--surface-extension-key)))
    (when-let* ((group (gethash 'change-group state)))
      ;; Lifecycle and cleanup callbacks run after precommit validation.
      ;; A second boundary-only check also covers those unrecorded writes.
      (ebox--pub--validate-retained-batch-hover-groups)
      (accept-change-group group))))

(defun ebox--pub--surface-precommit-transaction ()
  "Validate and settle shared publication candidates before accepting signals."
  (when-let* ((state (ebox--pub--transaction-extension ebox--pub--surface-extension-key))
              (table (gethash 'prepared state)))
    (let ((all-prepared (ebox--pub--all-prepared-surfaces table))
          (changed (gethash 'changed state)))
      (when changed
        (ebox--pub--surface-precommit-step 'validate state)
        (ebox--pub--validate-surface-precommit state)
        (ebox--pub--surface-precommit-step 'view state)
        (ebox--pub--restore-view-state (gethash 'views state) t))
      (dolist (prepared all-prepared)
        (ebox--pub--finalize-object-lifecycle prepared))
      (when changed
        (dolist (prepared changed)
          (ebox--pub--enqueue-surface-observers
           (ebox--pub--prepared-surface-surface prepared)))
        (ebox--pub--surface-prevalidate-cleanup state)
        (ebox--pub--transaction-install-final-accept
         #'ebox--pub--surface-final-accept)))))

(defun ebox--pub--cancel-change-group-safely (group)
  "Cancel active change GROUP without allowing quit to interrupt rollback."
  (when group
    (let ((inhibit-quit t)
          (inhibit-modification-hooks t)
          (ebox--pub--surface-publishing t))
      (condition-case nil
          (cancel-change-group group)
        ((error quit) nil)))))

(defun ebox--pub--cancel-change-group-for-rollback (group)
  "Cancel active change GROUP while allowing failure aggregation."
  (when group
    (let ((inhibit-quit t)
          (inhibit-modification-hooks t)
          (ebox--pub--surface-publishing t))
      (cancel-change-group group))))

(defun ebox--pub--restore-retained-batch-output ()
  "Restore each candidate's old output, including unrecorded callback writes."
  (when-let* ((state (ebox--pub--transaction-extension ebox--pub--surface-extension-key)))
    (dolist (prepared (gethash 'changed state))
      (let* ((surface (ebox--pub--prepared-surface-surface prepared))
             (buffer (ebox--pub--surface-buffer surface))
             (old (ebox--pub--prepared-surface-baseline-output prepared)))
        (when (and (stringp old) (buffer-live-p buffer))
          (with-current-buffer buffer
            (save-restriction
              (widen)
              (pcase-let* ((`(,start . ,end) (ebox--pub--surface-range surface))
                           (plain (buffer-substring-no-properties start end))
                           (prefix (ebox--pub--common-prefix-length plain old))
                           (suffix (ebox--pub--common-suffix-length plain old prefix))
                           (inhibit-read-only t) (inhibit-modification-hooks t)
                           (buffer-undo-list t))
                (unless (equal plain (substring-no-properties old))
                  (delete-region (+ start prefix) (- end suffix))
                  (goto-char (+ start prefix))
                  (insert (substring old prefix (- (length old) suffix))))
                (set-marker (ebox--pub--surface-start surface) start)
                (set-marker (ebox--pub--surface-end surface) (+ start (length old)))
                (ebox--pub--replay-string-properties buffer start old)))))))))

(defun ebox--pub--surface-rollback-transaction ()
  "Rollback buffers, side state, markers, and contexts for this transaction."
  (when-let* ((state (ebox--pub--transaction-extension ebox--pub--surface-extension-key)))
    (let (failures)
      (cl-labels
          ((attempt (owner function)
             (condition-case failure
                 (funcall function)
               ((error quit)
                (push (list owner failure) failures)))))
        (attempt 'change-group
                 (lambda ()
                   (ebox--pub--cancel-change-group-for-rollback
                    (gethash 'change-group state))))
        (attempt 'properties
                 (lambda ()
                   (ebox--pub--restore-property-journals
                    (gethash 'journals state))))
        (attempt 'retained-output #'ebox--pub--restore-retained-batch-output)
        (dolist (entry (gethash 'snapshots state))
          (attempt
           (list 'surface
                 (ebox--pub--surface-id
                  (ebox--pub--prepared-surface-surface (car entry))))
           (lambda ()
             (ebox--pub--restore-surface-snapshot (car entry) (cdr entry)))))
        (attempt 'view
                 (lambda ()
                   (ebox--pub--restore-view-state (gethash 'views state))))
        (attempt 'surface-counter
                 (lambda ()
                   (when (gethash 'surface-transaction-id-before state)
                     (setq ebox--pub--surface-transaction-id
                           (gethash 'surface-transaction-id-before state))))))
        (when failures
          (signal 'ebox--pub-surface-rollback-error
                  (list :failures (nreverse failures)))))))

(defun ebox--pub--surface-finalize-killed-rollback ()
  "Dispose candidate contexts and reapply killed-buffer teardown."
  (when-let* ((state (ebox--pub--transaction-extension ebox--pub--surface-extension-key)))
    (let (failures)
      (when-let* ((table (gethash 'prepared state)))
        (dolist (prepared (ebox--pub--all-prepared-surfaces table))
          (let ((surface (ebox--pub--prepared-surface-surface prepared)))
            (condition-case failure
                (let ((context (ebox--pub--prepared-surface-context prepared)))
                  (setf (ebox--pub--context-active context) t)
                  (ebox--pub--discard-context context)
                  (unless (buffer-live-p (ebox--pub--surface-buffer surface))
                    (ebox--pub--teardown-surface surface t)))
              ((error quit)
               (push (list (ebox--pub--surface-id surface) failure)
                     failures))))))
      (when failures
        (signal 'ebox--pub-surface-rollback-error
                (list :finalize-failures (nreverse failures)))))))

(defun ebox--pub--finalize-object-lifecycle (prepared)
  "Delete omitted bindings and removed objects after PREPARED commits."
  (let* ((context (ebox--pub--prepared-surface-context prepared))
         (objects (ebox--pub--prepared-surface-objects prepared))
         (omitted (ebox--pub--context-binding-removals context objects)))
    (dolist (binding omitted)
      (when (ebox--pub-binding-live-p binding) (ebox--pub-binding-dispose binding)))
    (dolist (object (ebox--pub--prepared-surface-removed prepared))
      (ebox--pub-binding-dispose-owner object)
      (setf (ebox--pub--surface-object-live object) nil
            (ebox--pub--surface-object-disposed object) t))
    (setf (ebox--pub--context-active context) nil)))

(defun ebox--pub--record-observer-error (surface observer failure)
  "Record OBSERVER FAILURE in SURFACE's latest report."
  (let ((report (ebox-text--copy-property-value (ebox--pub--surface-report surface))))
    (setq report
          (plist-put report :observer-errors
                     (append (plist-get report :observer-errors)
                             (list (list :observer observer :error failure)))))
    (setf (ebox--pub--surface-report surface) report)))

(defun ebox--pub--record-cleanup-error (surface owner failure)
  "Record contained cleanup OWNER FAILURE on SURFACE."
  (let ((report (ebox-text--copy-property-value (ebox--pub--surface-report surface))))
    (setq report
          (plist-put report :cleanup-errors
                     (append (plist-get report :cleanup-errors)
                             (list (list :owner owner :error failure)))))
    (setf (ebox--pub--surface-report surface) report)))

(defun ebox--pub--run-surface-observers (surface observers report)
  "Run SURFACE OBSERVERS with REPORT and record their errors."
  (dolist (observer observers)
    (let ((inhibit-quit t)
          (quit-flag nil))
      (condition-case failure
          (funcall observer surface report)
        ((error quit)
         (ebox--pub--record-observer-error surface observer failure))))))

(defun ebox--pub--enqueue-surface-observers (surface)
  "Schedule SURFACE observers outside the publishing transaction."
  (when-let* ((observers (ebox--pub--surface-observers surface)))
    (let ((observers (copy-sequence observers))
          (report (ebox--pub-surface-report surface)))
      (ebox--pub--enqueue-after-commit
       (lambda () (ebox--pub--run-surface-observers surface observers report))))))

(defun ebox--pub--surface-commit-transaction ()
  "Release old mounts and view markers after the publication was accepted."
  (when-let* ((state (ebox--pub--transaction-extension ebox--pub--surface-extension-key)))
    (cl-labels ((cleanup (surface owner function)
                  (condition-case failure
                      (funcall function)
                    ((error quit)
                     (ebox--pub--record-cleanup-error surface owner failure)))))
      (when-let* ((prepared (car (gethash 'changed state))))
        (cleanup (ebox--pub--prepared-surface-surface prepared) 'view-markers
                 (lambda () (ebox--pub--dispose-view-state (gethash 'views state)))))
      (dolist (entry (gethash 'snapshots state))
        (let ((prepared (car entry)) (snapshot (cdr entry)))
          (unless (ebox--pub--prepared-surface-retained-mount-state-p prepared)
            (cleanup (ebox--pub--prepared-surface-surface prepared) 'old-mounts
                     (lambda ()
                       (ebox--pub--dispose-content-mounts
                        (ebox--pub--surface-snapshot-mounts snapshot))))))))))

(defun ebox--pub-surface-materialize-string (plan-or-producer)
  "Materialize PLAN-OR-PRODUCER without creating live runtime state."
  (let* ((surface (ebox--pub--make-surface
                   :id 0 :capability 'content :options nil
                   :objects (make-hash-table :test #'equal)))
         (context (ebox--pub--make-context surface t))
         (success nil)
         rendered)
    (unwind-protect
        (let* ((normalized
                (ebox--pub--prepare-input surface plan-or-producer nil context))
               (plan (car normalized))
               (owned-p (nth 2 normalized)))
          (ebox--pub--validate-plan-capability plan 'content)
          (ebox--pub--validate-context-tree context plan)
          (setq rendered (car (ebox--pub--render-plan plan context owned-p))
                success t)
          rendered)
      (setf (ebox--pub--context-active context) t)
      (ebox--pub--discard-context context)
      (unless success (setq rendered nil)))))

(defun ebox--pub--unmount-journals (surface _operations)
  "Capture property rollback journals for SURFACE and OPERATIONS."
  (let
      ((entries
        (pcase-let
            ((`(,start \, end) (ebox--pub--surface-range surface)))
          (list (list (ebox--pub--surface-buffer surface) start end)))))
    (mapcar
     (lambda (entry)
       (pcase-let ((`(,buffer ,start ,end) entry))
         (list buffer start end
               (with-current-buffer buffer
                 (buffer-substring start end)))))
     (ebox--pub--merge-buffer-intervals entries))))

(defun ebox--pub--publish-unmount (surface _operations)
  "Remove SURFACE content or apply property restoration OPERATIONS."
  (let
      ((buffer (ebox--pub--surface-buffer surface))
       (ebox--pub--surface-publishing t))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (let
            ((inhibit-read-only
              (plist-get (ebox--pub--surface-options surface)
                         :inhibit-read-only)))
          (pcase-let
              ((`(,start \, end) (ebox--pub--surface-range surface)))
            (delete-region start end)))))))

(defun ebox--pub--teardown-surface (surface killed)
  "Release SURFACE runtime state; KILLED means its buffer is gone."
  (when (ebox--pub-surface-p surface)
    (ebox--pub--unregister-surface surface)
    (ebox--pub-binding-dispose-owner surface)
    (when (ebox--pub--surface-objects surface)
      (maphash
       (lambda (_path object)
         (ebox--pub-binding-dispose-owner object)
         (setf (ebox--pub--surface-object-live object) nil
               (ebox--pub--surface-object-disposed object) t))
       (ebox--pub--surface-objects surface)))
    (ebox--pub--dispose-content-mounts (ebox--pub--surface-mounts surface))
    (ebox--pub--dispose-ledger (ebox--pub--surface-ledger surface))
    (ebox--pub--dispose-marker (ebox--pub--surface-start surface))
    (ebox--pub--dispose-marker (ebox--pub--surface-end surface))
    (setf (ebox--pub--surface-live surface) nil
          (ebox--pub--surface-stale surface) (and killed 'killed)
          (ebox--pub--surface-objects surface) (make-hash-table :test #'equal)
          (ebox--pub--surface-mounts surface) nil (ebox--pub--surface-index surface) nil
          (ebox--pub--surface-mount-index surface) (make-hash-table :test #'eq)
          (ebox--pub--surface-ledger surface) nil
          (ebox--pub--surface-client-state surface) nil
          (ebox--pub--surface-observers surface) nil)))

(defun ebox--pub-surface-unmount (surface)
  "Unmount SURFACE and return a generic report.  Properties-only mounts restore
their baseline only when Ebox's last value still owns the property;
conflicting host values are preserved and reported."
  (ebox--pub--validate-live-surface surface)
  (when ebox--pub--transaction-active
    (signal 'ebox--pub-surface-error
            (list :unmount-during-transaction)))
  (let*
      ((property-result (progn (cons nil nil)))
       (operations (car property-result))
       (conflicts (cdr property-result))
       (journals (ebox--pub--unmount-journals surface operations))
       (views
        (ebox--pub--capture-view-state
         (list (ebox--pub--surface-buffer surface))))
       (group
        (ebox--pub--prepare-change-group-for-buffers
         (list (ebox--pub--surface-buffer surface))))
       success)
    (unwind-protect
        (progn
          (ebox--pub--publish-unmount surface operations)
          (accept-change-group group) (setq success t))
      (unless success
        (ebox--pub--cancel-change-group-safely group)
        (ebox--pub--restore-property-journals journals))
      (ebox--pub--restore-view-state views))
    (let
        ((report
          (list :transaction-id
                (cl-incf ebox--pub--surface-transaction-id)
                :surface-id (ebox--pub--surface-id surface)
                :old-revision (ebox--pub--surface-revision surface)
                :new-revision nil :text-operations 1
                :property-operations (length operations)
                :property-conflicts conflicts :unmounted t)))
      (ebox--pub--teardown-surface surface nil) report)))

(defun ebox--pub-surface-report (surface)
  "Return a defensive copy of SURFACE's latest generic commit report."
  (unless (ebox--pub-surface-p surface)
    (signal 'wrong-type-argument (list 'ebox--pub-surface-p surface)))
  (ebox-text--copy-property-value (ebox--pub--surface-report surface)))

(defun ebox--pub-surface-report-summary (surface)
  "Return scalar commit metrics for SURFACE without copying its full report.
The returned plist contains only numbers, symbols, booleans, or nil.  Use
`ebox--pub-surface-report' when callers need arbitrary report payloads or a
defensive snapshot of nested values."
  (unless (ebox--pub-surface-p surface)
    (signal 'wrong-type-argument (list 'ebox--pub-surface-p surface)))
  (let ((report (ebox--pub--surface-report surface)))
    (list :transaction-id (plist-get report :transaction-id)
          :text-operations (plist-get report :text-operations)
          :property-operations (plist-get report :property-operations)
          :full-root (plist-get report :full-root)
          :scope-count (plist-get report :scope-count)
          :scope-range-count (plist-get report :scope-range-count)
          :scope-fallback (plist-get report :scope-fallback)
          :reconciled-objects (plist-get report :reconciled-objects)
          :created-objects (plist-get report :created-objects)
          :removed-objects (plist-get report :removed-objects)
          :moved-objects (plist-get report :moved-objects))))

(defun ebox--pub-surface-inspect (surface)
  "Return read-only retained diagnostics for SURFACE."
  (ebox--pub--validate-live-surface surface)
  (list :surface surface :id (ebox--pub--surface-id surface)
        :buffer (ebox--pub--surface-buffer surface)
        :capability (ebox--pub--surface-capability surface)
        :revision (ebox--pub--surface-revision surface)
        :object-count (hash-table-count (ebox--pub--surface-objects surface))
        :mount-count (length (ebox--pub--surface-mounts surface))
        :client-state (ebox--pub--surface-client-state surface)
        :report (ebox--pub-surface-report surface)))

(add-hook 'ebox--pub--binding-changed-functions #'ebox--pub--surface-binding-changed)
(add-hook 'ebox--pub--transaction-publish-functions #'ebox--pub--surface-publish-transaction)
(ebox--pub--transaction-register-precommit-function
 'ebox--pub--surface-precommit-transaction)
(add-hook 'ebox--pub--transaction-rollback-functions #'ebox--pub--surface-rollback-transaction)
(add-hook 'ebox--pub--transaction-rollback-final-functions
          #'ebox--pub--surface-finalize-killed-rollback)
(add-hook 'ebox--pub--transaction-committed-functions #'ebox--pub--surface-commit-transaction)

(provide 'ebox-publication)
;;; ebox-publication.el ends here
