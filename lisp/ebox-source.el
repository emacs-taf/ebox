;;; ebox-source.el --- Owned author source facts -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns opaque author source handles, sealed source records, and candidate
;; source indexes.  Prepared updates bind private source and value cells
;; to an already-owned runtime node; public exports freeze those cells.
;; This module does not own tree traversal, selector matching, layout, paint,
;; buffers, or publication.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-text)
(require 'ebox-interaction)

(declare-function ebox-style-schema-id "ebox-style" (name))

(cl-defstruct (ebox-style-scope (:constructor ebox-style--make-scope))
  "Immutable stylesheet shared by explicitly marked roots and member sources."
  identity stylesheet)

(cl-defstruct (ebox-source-record
               (:constructor ebox-source--make-record))
  "Sealed author facts and candidate-derived interaction states for one source.
MUTABLE-PREPARED-P marks private live source cells, never exported by sharing."
  key id classes attributes states interaction-states declarations provenance interactions
  ecss ecss-targets ecss-scopes ecss-scope-roots mutable-prepared-p)

(cl-defstruct (ebox-source--update-slots
               (:constructor ebox-source--update-slots-create))
  "Prepared private source/node cells with reusable value rollback storage."
  index handle kinds source-cells node-cells value-cells old-values staged-count
  selector-context)

(cl-defstruct (ebox-source-handle
               (:constructor ebox-source--make-handle)
               (:conc-name ebox-source--handle-))
  "Opaque identity for one author source."
  identity)

(cl-defstruct (ebox-source-index
               (:constructor ebox-source--make-index)
               (:conc-name ebox-source--index-))
  "Sealed generation mapping from source handles to owned records.
Only privately prepared records permit bounded source-value mutation."
  records handle-records order subjects node-subjects entries root-subject selector-view selector-topology
  selector-id-table selector-class-table selector-type-table host-ref-table
  derived-stale-p prepared-selector-context)

(cl-defstruct (ebox-source-builder
               (:constructor ebox-source--make-builder)
               (:conc-name ebox-source--builder-))
  "Private mutable source assembly sealed into one immutable source index."
  records handle-records order sealed-p)

(cl-defstruct (ebox-source-table
               (:constructor ebox-source--make-table))
  "Persistent immutable table overlay with a derived lookup memo."
  base added removed count test depth memo)

(cl-defstruct (ebox-source-order
               (:constructor ebox-source--make-order))
  "Bounded persistent document-order handle delta."
  base replacements removed appended local-handles handles depth)

(defconst ebox-source--persistent-max-depth 4
  "Maximum SourceIndex overlay depth before exact compaction.")

(defconst ebox-source--memo-missing (make-symbol "ebox-source-memo-missing")
  "Private marker for a memoized absent persistent-table key.")

(defconst ebox-source--memo-unset (make-symbol "ebox-source-memo-unset")
  "Private marker for a persistent-table key not present in its memo.")

(defconst ebox-source--lookup-missing
  (make-symbol "ebox-source-lookup-missing")
  "Private marker for an absent persistent-table lookup.")

(defconst ebox-source--local-missing
  (make-symbol "ebox-source-local-missing")
  "Private marker for an absent binding in one table overlay.")

(defconst ebox-source--order-missing
  (make-symbol "ebox-source-order-missing")
  "Private marker for a handle without an order replacement.")

(defun ebox-source--flat-table (hash test)
  "Seal HASH as a flat immutable source table using TEST."
  (ebox-source--make-table
   :base nil :added hash :removed (make-hash-table :test test)
   :count (hash-table-count hash) :test test :depth 0 :memo nil))

(defun ebox-source--table-seal (table test)
  "Return TABLE as an immutable persistent table using TEST."
  (cond
   ((null table) nil)
   ((ebox-source-table-p table) table)
   ((hash-table-p table) (ebox-source--flat-table table test))
   (t (signal 'wrong-type-argument (list 'hash-table-p table)))))

(defun ebox-source--table-value (table key)
  "Return KEY's value from persistent or flat TABLE, or nil."
  (cond
   ((ebox-source-table-p table)
    (let ((value
           (ebox-source--table-get table key ebox-source--lookup-missing)))
      (unless (eq value ebox-source--lookup-missing) value)))
   ((hash-table-p table) (gethash key table))
   ((null table) nil)
   (t (signal 'wrong-type-argument (list 'hash-table-p table)))))

(defun ebox-source--table-size (table)
  "Return the number of bindings retained by TABLE."
  (cond
   ((ebox-source-table-p table) (ebox-source-table-count table))
   ((hash-table-p table) (hash-table-count table))
   ((null table) 0)
   (t (signal 'wrong-type-argument (list 'hash-table-p table)))))

(defun ebox-source--table-get (table key missing)
  "Return KEY from persistent TABLE, or MISSING."
  (let* ((memo (ebox-source-table-memo table))
         (memoized
          (and memo (gethash key memo ebox-source--memo-unset))))
    (if (and memo (not (eq memoized ebox-source--memo-unset)))
        (if (eq memoized ebox-source--memo-missing) missing memoized)
      (let* ((local
              (gethash key (ebox-source-table-added table)
                       ebox-source--local-missing))
             (resolved
              (cond
               ((not (eq local ebox-source--local-missing)) local)
               ((gethash key (ebox-source-table-removed table))
                ebox-source--memo-missing)
               ((ebox-source-table-base table)
                (ebox-source--table-get
                 (ebox-source-table-base table)
                 key ebox-source--memo-missing))
               (t ebox-source--memo-missing))))
        ;; Facts remain immutable.  The memo only path-compresses a lookup whose
        ;; answer is fixed by this immutable overlay and its immutable base.
        (when memo (puthash key resolved memo))
        (if (eq resolved ebox-source--memo-missing) missing resolved)))))

(defun ebox-source--table-materialize (table)
  "Return a fresh flat hash table with persistent TABLE's exact bindings."
  (let ((result
         (if (ebox-source-table-base table)
             (ebox-source--table-materialize (ebox-source-table-base table))
           (make-hash-table :test (ebox-source-table-test table)))))
    (maphash (lambda (key _value) (remhash key result))
             (ebox-source-table-removed table))
    (maphash (lambda (key value) (puthash key value result))
             (ebox-source-table-added table))
    result))

(defun ebox-source--table-member-p (table key)
  "Return non-nil when persistent TABLE contains KEY."
  (not (eq (ebox-source--table-get table key ebox-source--lookup-missing)
           ebox-source--lookup-missing)))

(defun ebox-source--table-overlay (base added removed count)
  "Return bounded persistent BASE overlaid by ADDED and REMOVED with COUNT."
  (let ((depth (1+ (ebox-source-table-depth base))))
    (if (< depth ebox-source--persistent-max-depth)
        (ebox-source--make-table
         :base base :added added :removed removed :count count
         :test (ebox-source-table-test base) :depth depth
         :memo (make-hash-table :test (ebox-source-table-test base)))
      (let ((flat (ebox-source--table-materialize base)))
        (maphash (lambda (key _value) (remhash key flat)) removed)
        (maphash (lambda (key value) (puthash key value flat)) added)
        (unless (= (hash-table-count flat) count)
          (error "Ebox persistent source table count is inconsistent"))
        (ebox-source--flat-table flat (ebox-source-table-test base))))))

(defun ebox-source--order-apply (handles replacements removed appended)
  "Apply order delta to HANDLES and return a fresh exact order."
  (let (result)
    (dolist (handle handles)
      (let ((replacement
             (gethash handle replacements ebox-source--order-missing)))
        (cond
         ((not (eq replacement ebox-source--order-missing))
          (push replacement result))
         ((gethash handle removed) nil)
         (t (push handle result)))))
    (append (nreverse result) (copy-sequence appended))))

(defun ebox-source--order-handles (order)
  "Materialize persistent source ORDER."
  (cond
   ((listp order) (copy-sequence order))
   ((ebox-source-order-handles order)
    (copy-sequence (ebox-source-order-handles order)))
   (t
    (ebox-source--order-apply
     (ebox-source--order-handles (ebox-source-order-base order))
     (ebox-source-order-replacements order)
     (ebox-source-order-removed order)
     (ebox-source-order-appended order)))))

(defun ebox-source--order-overlay
    (base replacements removed appended local-handles)
  "Return a bounded persistent order delta over BASE."
  (let* ((base-depth (if (ebox-source-order-p base)
                         (or (ebox-source-order-depth base) 0)
                       0))
         (depth (1+ base-depth)))
    (if (< depth ebox-source--persistent-max-depth)
        (ebox-source--make-order
         :base base :replacements replacements :removed removed
         :appended appended :local-handles (copy-sequence local-handles)
         :depth depth)
      (ebox-source--make-order
       :handles
       (ebox-source--order-apply
        (ebox-source--order-handles base) replacements removed appended)
       :local-handles (copy-sequence local-handles)
       :depth 0))))

(defun ebox-source--copy-data (value)
  "Return a detached copy of mutable source VALUE.
Functions and records are opaque values and retain identity."
  (cond
   ((functionp value) value)
   ((hash-table-p value)
    (let ((copy (copy-hash-table value)))
      (clrhash copy)
      (maphash
       (lambda (key item)
         (puthash (ebox-source--copy-data key)
                  (ebox-source--copy-data item)
                  copy))
       value)
      copy))
   ((consp value)
    (cons (ebox-source--copy-data (car value))
          (ebox-source--copy-data (cdr value))))
   ((stringp value) (copy-sequence value))
   ((bool-vector-p value) (copy-sequence value))
   ((recordp value) value)
   ((vectorp value)
    (let ((copy (copy-sequence value)))
      (dotimes (index (length copy))
        (aset copy index
              (ebox-source--copy-data (aref copy index))))
      copy))
   (t value)))

(defun ebox-source-index-interactions (index handle)
  "Return detached fixed interaction facts for HANDLE in INDEX."
  (when-let* ((record (ebox-source--index-record index handle)))
    (ebox-text-property-value-copy (ebox-source-record-interactions record))))

(defun ebox-source-stable-key-p (value)
  "Return non-nil when VALUE is one public stable source key."
  (and value (or (symbolp value) (stringp value) (integerp value))))

(defun ebox-source-semantic-id-p (value)
  "Return non-nil when VALUE is one public semantic id."
  (and value (or (symbolp value) (stringp value) (integerp value))))

(defun ebox-source-class-list-p (value)
  "Return non-nil when VALUE is a public class token or proper token list."
  (or (symbolp value)
      (stringp value)
      (and (proper-list-p value)
           (cl-every (lambda (token)
                       (or (symbolp token) (stringp token)))
                     value))))

(defun ebox-source-selector-states-p (value)
  "Return non-nil when VALUE is a public selector-state token list."
  (ebox-source-class-list-p value))

(defun ebox-source--metadata-string (value)
  "Return VALUE normalized to a selector metadata string."
  (cond
   ((null value) nil)
   ((symbolp value) (symbol-name value))
   ((stringp value) (copy-sequence value))
   (t (format "%s" value))))

(defun ebox-source--metadata-tokens (value)
  "Return VALUE as unique normalized selector metadata tokens."
  (delete-dups
   (delq nil
         (mapcar #'ebox-source--metadata-string
                 (if (listp value) value (list value))))))

(defun ebox-source--attribute-key (key)
  "Return canonical keyword selector attribute KEY."
  (cond
   ((keywordp key) key)
   ((symbolp key) (intern (concat ":" (symbol-name key))))
   ((stringp key)
    (intern (if (string-prefix-p ":" key) key (concat ":" key))))
   (t (error "Ebox source attribute name is invalid: %S" key))))

(defun ebox-source-selector-attributes-p (value)
  "Return non-nil when VALUE is a valid selector attribute alist."
  (and (or (null value) (proper-list-p value))
       (cl-every (lambda (entry)
                   (and (consp entry)
                        (or (stringp (car entry))
                            (symbolp (car entry))
                            (keywordp (car entry)))))
                 value)))

(defun ebox-source--attributes (attributes)
  "Return detached canonical selector ATTRIBUTES."
  (unless (ebox-source-selector-attributes-p attributes)
    (error "Ebox source attributes must be an alist: %S" attributes))
  (mapcar
   (lambda (attribute)
     (unless (consp attribute)
       (error "Ebox source attributes must be an alist: %S" attributes))
     (cons (ebox-source--attribute-key (car attribute))
           (ebox-source--copy-data (cdr attribute))))
   attributes))

(defun ebox-source--declarations (declarations)
  "Return detached canonical DECLARATIONS after shape validation."
  (unless (and (proper-list-p declarations)
               (zerop (% (length declarations) 2)))
    (error "Ebox source declarations must be an even plist: %S"
           declarations))
  (ebox-source--copy-data declarations))

(defun ebox-source-builder-create ()
  "Return a mutable source builder for one canonical input."
  (ebox-source--make-builder
   :records (make-hash-table :test #'equal)
   :handle-records (make-hash-table :test #'eq)
   :order nil
   :sealed-p nil))

(defun ebox-source--builder-assert-open (builder)
  "Signal unless BUILDER is a live mutable source builder."
  (unless (ebox-source-builder-p builder)
    (signal 'wrong-type-argument (list 'ebox-source-builder-p builder)))
  (when (ebox-source--builder-sealed-p builder)
    (error "Ebox source builder is already sealed")))

(defun ebox-source--builder-add-record (builder handle record)
  "Add identity-only HANDLE and immutable RECORD to open BUILDER."
  (ebox-source--builder-assert-open builder)
  (unless (ebox-source-handle-p handle)
    (signal 'wrong-type-argument (list 'ebox-source-handle-p handle)))
  (unless (ebox-source-record-p record)
    (signal 'wrong-type-argument (list 'ebox-source-record-p record)))
  (let* ((identity (ebox-source--handle-id-view handle))
         (records (ebox-source--builder-records builder)))
    (when (gethash identity records)
      (error "Ebox source identity occurs more than once: %S" identity))
    (puthash identity record records)
    ;; Both indexes retain the same immutable record object.  Identity lookup
    ;; owns uniqueness; exact-handle lookup owns hot-path resolution.
    (puthash handle record (ebox-source--builder-handle-records builder))
    (push handle (ebox-source--builder-order builder))
    handle))

(cl-defun ebox-source-builder-bind
    (builder &key identity key id class selector-attributes selector-state
             declarations provenance interactions ecss (ecss-targets t)
             ecss-scopes ecss-scope-roots)
  "Bind normalized source facts in BUILDER and return an opaque handle.
The returned handle contains identity only; all facts are owned by BUILDER
until `ebox-source-builder-finish' seals them into a source index.
SELECTOR-STATE accepts authored tokens except disabled, focus and active.
Disabled is derived from INTERACTIONS :disabled; focus and active belong to
the mounted buffer. Declaring these as authored states is an error.
ECSS-TARGETS is t for all descendants or a proper list of source identities
eligible for this source's ECSS rules.  nil selects none.  Identities use
`equal'; the list is snapshotted and resolved within each candidate input.
ECSS-SCOPES and ECSS-SCOPE-ROOTS are lists of distinct shared scope objects,
declaring membership and independent roots.  Both lists are snapshotted."
  (unless (or (eq ecss-targets t) (proper-list-p ecss-targets))
    (signal 'wrong-type-argument (list 'listp ecss-targets)))
  (dolist (scopes (list ecss-scopes ecss-scope-roots))
    (unless (and (proper-list-p scopes)
                 (cl-every #'ebox-style-scope-p scopes)
                 (= (length scopes)
                    (length (delete-dups
                             (mapcar #'ebox-style-scope-identity scopes)))))
      (error "Ebox shared scopes must be a list of distinct scope identities")))
  (when (and key (not (ebox-source-stable-key-p key)))
    (error "Ebox source key must be a non-nil symbol, string, or integer: %S"
           key))
  (when (and id (not (ebox-source-semantic-id-p id)))
    (error "Ebox source id must be a non-nil symbol, string, or integer: %S"
           id))
  (unless (ebox-source-class-list-p class)
    (error "Ebox source class must be a token or proper token list: %S"
           class))
  (unless (ebox-source-selector-states-p selector-state)
    (error "Ebox source selector state must be a token or proper token list: %S"
           selector-state))
  (when (cl-intersection '("disabled" "focus" "active")
                         (ebox-source--metadata-tokens selector-state) :test #'equal)
    (error "Ebox disabled, focus and active selector states cannot be authored"))
  (unless (ebox-source-selector-attributes-p selector-attributes)
    (error "Ebox source selector attributes must be an alist: %S"
           selector-attributes))
  (let ((handle
         (ebox-source--make-handle
          :identity (ebox-source--copy-data
                     (or identity (make-symbol "ebox-source")))))
        (record
         (ebox-source--make-record
          :key (ebox-source--copy-data key)
          :id (ebox-source--metadata-string id)
          :classes (ebox-source--metadata-tokens class)
          :attributes (ebox-source--attributes selector-attributes)
          :states (ebox-source--metadata-tokens selector-state)
          :declarations (ebox-source--declarations declarations)
          :provenance (ebox-source--copy-data provenance)
          :interactions (ebox-interaction-normalize interactions)
          :ecss (ebox-source--copy-data ecss)
          :ecss-targets (ebox-source--copy-data ecss-targets)
          :ecss-scopes (copy-sequence ecss-scopes)
          :ecss-scope-roots (copy-sequence ecss-scope-roots))))
    (ebox-source--builder-add-record builder handle record)))

(defun ebox-source--builder-record (builder handle)
  "Return open BUILDER's immutable record for exact HANDLE."
  (ebox-source--builder-assert-open builder)
  (gethash handle (ebox-source--builder-handle-records builder)))

(defun ebox-source-builder-import (builder index)
  "Import INDEX's immutable source facts into open BUILDER.
Exact handles and sealed records are shared.  Private live prepared records
are frozen into detached records.  Duplicate source identity is an error
because one canonical forest cannot contain the same source twice."
  (ebox-source--builder-assert-open builder)
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (dolist (handle (ebox-source-index-handles index))
    (let ((record (or (ebox-source--index-record index handle)
                      (error "Ebox imported source handle is absent from its index"))))
      (ebox-source--builder-add-record
       builder handle
       (if (ebox-source-record-mutable-prepared-p record)
           (ebox-source--copy-record record)
         record))))
  builder)

(defconst ebox-source--border-properties
  [[:border-top-width :border-top-style :border-top-color]
   [:border-right-width :border-right-style :border-right-color]
   [:border-bottom-width :border-bottom-style :border-bottom-color]
   [:border-left-width :border-left-style :border-left-color]]
  "Source border longhands in fixed top/right/bottom/left order.")

(defun ebox-source--update-slots-class-value (index node)
  "Return NODE's detached canonical class tokens in INDEX."
  (ebox-source--copy-data
   (ebox-source-record-classes
    (ebox-source--index-record index (plist-get node :ebox-source-handle)))))

(defun ebox-source--update-slots-border-value (index node)
  "Return NODE's uniform explicit source border in INDEX, or nil."
  (let* ((record (ebox-source--index-record index (plist-get node :ebox-source-handle)))
         (declarations (and record (ebox-source-record-declarations record)))
         (width (plist-get declarations 'ebox/border-top-width))
         (style (plist-get declarations 'ebox/border-top-style))
         (color (plist-get declarations 'ebox/border-top-color))
         (valid (and (consp width) (eq (car width) 'px) (numberp (cadr width))
                     (null (cddr width)) (eq style 'solid))))
    (dotimes (side 4)
      (let ((keys (aref ebox-source--border-properties side)))
        (unless (and (let ((actual (plist-get node (aref [:border-top-pixel :border-right-pixel
                                                         :border-bottom-pixel :border-left-pixel] side))))
                       (or (equal width actual) (equal (cadr width) actual)))
                     (eq style (plist-get node (aref keys 1))))
          (setq valid nil))
        (dotimes (part 3)
          (let* ((key (aref keys part)) (id (ebox-style-schema-id key))
                 (wanted (pcase part (0 width) (1 style) (_ color))))
            (unless (and (plist-member declarations id)
                         (equal wanted (plist-get declarations id))
                         (or (/= part 2)
                             (and (plist-member node key) (equal wanted (plist-get node key)))))
              (setq valid nil))))))
    (when valid (list (copy-tree width) style (ebox-source--copy-data color)))))

(defun ebox-source--update-slots-border-valid-p (slots position value)
  "Check VALUE against SLOTS' fixed border geometry at POSITION."
  (let ((current (ebox-source--update-slots-value slots position)))
    (and (eq (aref (ebox-source--update-slots-kinds slots) position) 'border)
         (consp value) (consp (cdr value)) (consp (cddr value)) (null (cdddr value))
         (equal (car value) (car current)) (eq (cadr value) (cadr current))
         (or (null (caddr value)) (stringp (caddr value))))))

(defun ebox-source--update-slots-bind-selector
    (slots position context capture apply rollback)
  "Bind SLOTS' class POSITION to cold CONTEXT callbacks.
CAPTURE saves undo without changing facts; APPLY writes the admitted value;
ROLLBACK restores that captured value.  All callbacks have fixed ownership."
  (unless (eq (aref (ebox-source--update-slots-kinds slots) position) 'class)
    (error "Prepared selector binding requires a class slot"))
  (setf (ebox-source--update-slots-selector-context slots) context)
  (aset (ebox-source--update-slots-value-cells slots) position (vector capture apply rollback)))

(defun ebox-source--update-slots-prepare (index node properties)
  "Prepare private source and value cells for NODE in INDEX.
PROPERTIES fixes the incoming value-vector order.  Return slots carrying an
equivalent replacement source index and handle, or nil if any requested
primitive cannot be bound.  Style slots require explicit concrete source
values equal to their engine projections.  Native `:hover-content' binds its
explicit source interaction; the caller owns its compiled hover registration.
`:content'
binds a Text node's canonical value and engine content together.
Unbound geometry fields other than left/top/z-index stay fixed; the caller
must prove that their incoming values do not change.
The caller proves effective inline winners, validates subsequent VALUES,
and installs the returned index/handle together.  Numeric unit slots retain
their unit tag.  Incoming nonnumeric values are already caller-owned; stage
does not copy strings or invoke callbacks.  Preparation replaces only
private equivalent node values, keeping prior canonical inputs and exports
isolated from later writes."
  (catch 'unsupported
    (let* ((handle (plist-get node :ebox-source-handle))
           (original (and handle (ebox-source--index-record index handle)))
           (record (and original (ebox-source--copy-record original)))
           (count (length properties))
           (kinds (make-vector count nil))
           (source-cells (make-vector count nil))
           (node-cells (make-vector count nil))
           (value-cells (make-vector count nil))
           (old-values (make-vector count nil))
           (seen (make-hash-table :test #'eq))
           (mutable-count 0))
      (unless (and record (> count 0)) (throw 'unsupported nil))
      (dotimes (position count)
        (let* ((property (elt properties position))
               (engine-property (if (eq property :background-color) :bgcolor property))
               source-cell targets value kind)
          (cond
           ((eq property :content)
            (let ((canonical (cdr (plist-member node :ebox-text-value)))
                  (content (cdr (plist-member node :content))))
              (unless (and (eq (plist-get node :ebox-kind) 'text)
                           canonical content (stringp (car canonical))
                           (equal (car canonical) (car content)))
                (throw 'unsupported nil))
              (setq targets (vector canonical content) value (car canonical) kind 'value)))
           ((eq property :hover-content)
            (setq source-cell (cdr (plist-member (ebox-source-record-interactions record)
                                                property))
                  targets (vector source-cell)
                  kind 'value))
           ((eq property :class)
            (setq value (ebox-source--copy-data (ebox-source-record-classes record))
                  targets (vector (list value)) kind 'class))
           ((eq property :border)
            (setq value (ebox-source--update-slots-border-value index node))
            (unless value (throw 'unsupported nil))
            (setq source-cell (make-vector 4 nil) targets (make-vector 5 nil) kind 'border)
            (aset targets 0 (list value))
            (dotimes (side 4)
              (let ((key (aref (aref ebox-source--border-properties side) 2)))
                (aset source-cell side
                      (cdr (plist-member (ebox-source-record-declarations record)
                                         (ebox-style-schema-id key))))
                (aset targets (1+ side) (cdr (plist-member node key))))))
           ((eq property :font-weight)
            (setq source-cell (cdr (plist-member (ebox-source-record-declarations record)
                                                'ebox/font-weight))
                  targets (vector source-cell) kind 'value))
           ((memq property '(:box-sizing :position :left :top :z-index :layer :anchor :placement
                             :width :min-width :max-width :height :min-height :max-height
                             :color :background-color :bgcolor))
            (setq source-cell
                  (cdr (plist-member (ebox-source-record-declarations record)
                                     (ebox-style-schema-id property)))
                  targets (vector (cdr (plist-member node engine-property)))
                  kind 'value)
            (let ((current (car source-cell)))
              (when (and (memq property '(:left :top :width :min-width :max-width
                                         :height :min-height :max-height))
                         (consp current) (consp (cdr current)) (null (cddr current))
                         (memq (car current) '(px % vw vh ch lh)) (numberp (cadr current)))
                (setq kind 'unit))))
           (t (throw 'unsupported nil)))
          (unless (memq property '(:content :class :border))
            (if (and source-cell (aref targets 0)
                     (equal (car source-cell) (car (aref targets 0))))
                (setq value (car source-cell))
              (if (memq property '(:box-sizing :position :layer :anchor :placement
                                  :width :min-width :max-width :height :min-height :max-height))
                  (setq kind 'fixed source-cell nil value (car (aref targets 0)))
                (throw 'unsupported nil))))
          (unless (eq kind 'fixed)
            (when (gethash (aref targets 0) seen) (throw 'unsupported nil))
            (puthash (aref targets 0) t seen)
            (setq mutable-count (1+ mutable-count)))
          (aset kinds position kind)
          (aset source-cells position source-cell)
          (aset node-cells position targets)
          (aset old-values position (pcase kind ('unit (cadr value))
                                      ('border (make-vector 5 nil)) (_ value)))
          (when (eq kind 'unit) (aset value-cells position (cdr value)))))
      (when (zerop mutable-count) (throw 'unsupported nil))
      (let* ((replacement handle)
             (builder (ebox-source-builder-create))
             (sources (make-hash-table :test #'eq))
             candidate)
        (setf (ebox-source-record-mutable-prepared-p record) t)
        (ebox-source--builder-add-record builder replacement record)
        (puthash replacement (ebox-source-builder-finish builder) sources)
        (setq candidate
              (ebox-source--index-replace-handles
               index (list handle) (list replacement) sources
               (list (cons handle replacement))))
        ;; Handles carry identity only.  Preserve that exact identity so a
        ;; shared runtime node remains resolvable in earlier source indexes;
        ;; only this candidate index sees the private mutable record.
        (setf (ebox-source--index-selector-topology candidate)
              (ebox-source--index-selector-topology index)
              (ebox-source--index-selector-view candidate)
              (ebox-source--index-selector-view index)
              (ebox-source--index-derived-stale-p candidate)
              (ebox-source--index-derived-stale-p index))
        (dotimes (position count)
          (unless (memq (aref kinds position) '(fixed class border))
            (let* ((source (aref source-cells position))
                   (targets (aref node-cells position))
                   (value (if source (car source) (aref old-values position))))
              (dotimes (target (length targets))
                (setcar (aref targets target) value))))
          (when (eq (aref kinds position) 'border)
            (dotimes (side 4)
              (setcar (aref (aref node-cells position) (1+ side))
                      (car (aref (aref source-cells position) side))))))
        (ebox-source--update-slots-create
         :index candidate :handle replacement :kinds kinds
         :source-cells source-cells :node-cells node-cells
         :value-cells value-cells :old-values old-values :staged-count 0)))))

(defun ebox-source--update-slots-current-p (slots index)
  "Return non-nil when INDEX still owns SLOTS' exact prepared source record."
  (and (ebox-source--update-slots-p slots)
       (ebox-source-index-p index)
       (or (null (ebox-source--update-slots-selector-context slots))
           (eq (ebox-source--update-slots-selector-context slots)
               (ebox-source--index-prepared-selector-context index)))
       (let ((handle (ebox-source--update-slots-handle slots)))
         (eq (ebox-source--index-record index handle)
             (ebox-source--index-record (ebox-source--update-slots-index slots) handle)))))

(defun ebox-source--update-slots-value (slots position)
  "Read SLOTS' current canonical value at compiled POSITION without a lookup."
  (car (aref (aref (ebox-source--update-slots-node-cells slots) position) 0)))

(defun ebox-source--update-slots-stage (slots values)
  "Write already-admitted VALUES through SLOTS' retained source/node cells.
VALUES is a reused vector in the prepared property order.  The caller owns
its string or capability values and has checked numeric unit tags.  No
candidate record, node, plist, unit cell or undo graph is allocated here."
  (let ((position 0)
        (kinds (ebox-source--update-slots-kinds slots))
        (old-values (ebox-source--update-slots-old-values slots))
        (value-cells (ebox-source--update-slots-value-cells slots))
        (node-cells (ebox-source--update-slots-node-cells slots))
        (source-cells (ebox-source--update-slots-source-cells slots)))
    (setf (ebox-source--update-slots-staged-count slots) 0)
    (while (< position (length kinds))
      (cond
       ((eq (aref kinds position) 'unit)
        (let ((cell (aref value-cells position)))
          (aset old-values position (car cell))
          (setf (ebox-source--update-slots-staged-count slots) (1+ position))
          (setcar cell (cadr (aref values position)))))
       ((eq (aref kinds position) 'value)
        (let* ((source (aref source-cells position))
               (targets (aref node-cells position))
               (value (aref values position)))
          (aset old-values position (car (aref targets 0)))
          (setf (ebox-source--update-slots-staged-count slots) (1+ position))
          (when source (setcar source value))
          (dotimes (target (length targets))
            (setcar (aref targets target) value))))
       ((eq (aref kinds position) 'border)
        (let* ((sources (aref source-cells position)) (targets (aref node-cells position))
               (undo (aref old-values position))
               (border (car (aref targets 0))) (color (caddr (aref values position))))
          (aset undo 0 (caddr border))
          (dotimes (side 4) (aset undo (1+ side) (car (aref sources side))))
          (setf (ebox-source--update-slots-staged-count slots) (1+ position))
          (setcar (cddr border) color)
          (dotimes (side 4)
            (setcar (aref sources side) color)
            (setcar (aref targets (1+ side)) color))))
       ((eq (aref kinds position) 'class)
        (let ((callbacks (aref value-cells position)) (value (aref values position)))
          (unless callbacks (error "Prepared class slot has no selector proof"))
          (funcall (aref callbacks 0) value)
          (setf (ebox-source--update-slots-staged-count slots) (1+ position))
          (funcall (aref callbacks 1) value))))
      (setq position (1+ position))))
  slots)

(defun ebox-source--update-slots-rollback (slots)
  "Restore SLOTS' last staged values, including a partially completed stage."
  (let ((position 0)
        (kinds (ebox-source--update-slots-kinds slots))
        (old-values (ebox-source--update-slots-old-values slots))
        (value-cells (ebox-source--update-slots-value-cells slots))
        (node-cells (ebox-source--update-slots-node-cells slots))
        (source-cells (ebox-source--update-slots-source-cells slots)))
    (while (< position (ebox-source--update-slots-staged-count slots))
      (let ((value (aref old-values position)))
        (cond
         ((eq (aref kinds position) 'unit)
          (setcar (aref value-cells position) value))
         ((eq (aref kinds position) 'value)
          (let ((source (aref source-cells position))
                (targets (aref node-cells position)))
            (when source (setcar source value))
            (dotimes (target (length targets))
              (setcar (aref targets target) value))))
         ((eq (aref kinds position) 'border)
          (let ((sources (aref source-cells position)) (targets (aref node-cells position)))
            (setcar (cddr (car (aref targets 0))) (aref value 0))
            (dotimes (side 4)
              (setcar (aref sources side) (aref value (1+ side)))
              (setcar (aref targets (1+ side)) (aref value (1+ side))))))
         ((eq (aref kinds position) 'class)
          (funcall (aref (aref value-cells position) 2)))))
      (setq position (1+ position)))
    (setf (ebox-source--update-slots-staged-count slots) 0))
  slots)

(cl-defun ebox-source-index-rebind
    (index handle &key
           (key nil key-p) (id nil id-p) (class nil class-p)
           (selector-attributes nil attributes-p)
           (selector-state nil states-p)
           (declarations nil declarations-p)
           (ecss nil ecss-p)
           (ecss-targets nil ecss-targets-p)
           (ecss-scopes nil ecss-scopes-p)
           (ecss-scope-roots nil ecss-scope-roots-p)
           (interactions nil interactions-p)
           (provenance nil provenance-p))
  "Return `(NEW-INDEX . NEW-HANDLE)' after rebinding HANDLE in INDEX.
The semantic identity and all omitted immutable facts are retained.  A fresh
exact handle makes the candidate generation change explicit without placing
facts on the canonical node."
  (let ((record (or (ebox-source--index-record index handle)
                    (error "Ebox source rebind handle is absent")))
        (builder (ebox-source-builder-create)))
    (let* ((new-handle
            (ebox-source-builder-bind
             builder
             :identity (ebox-source--handle-id-view handle)
             :key (if key-p key (ebox-source-record-key record))
             :id (if id-p id (ebox-source-record-id record))
             :class (if class-p class (ebox-source-record-classes record))
             :selector-attributes
             (if attributes-p
                 selector-attributes
               (ebox-source-record-attributes record))
             :selector-state
             (if states-p selector-state (ebox-source-record-states record))
             :declarations (if declarations-p
                               declarations
                             (ebox-source-record-declarations record))
             :ecss (if ecss-p ecss (ebox-source-record-ecss record))
             :ecss-targets (if ecss-targets-p ecss-targets
                             (ebox-source-record-ecss-targets record))
             :ecss-scopes (if ecss-scopes-p ecss-scopes
                            (ebox-source-record-ecss-scopes record))
             :ecss-scope-roots (if ecss-scope-roots-p ecss-scope-roots
                                 (ebox-source-record-ecss-scope-roots record))
             :interactions (if interactions-p interactions
                             (ebox-source-record-interactions record))
             :provenance
             (if provenance-p provenance
               (ebox-source-record-provenance record))))
           (incoming (ebox-source-builder-finish builder))
           (sources (make-hash-table :test #'eq)))
      (puthash new-handle incoming sources)
      (let* ((candidate
              (ebox-source--index-replace-handles
               index (list handle) (list new-handle) sources
               (list (cons handle new-handle))))
             (node-subjects (ebox-source--index-node-subjects index))
             (selector-stable-p
              (not (or id-p class-p attributes-p states-p
                       (not (equal
                             (ebox-source--record-selector-states record)
                             (ebox-source--record-selector-states
                              (ebox-source--index-record incoming new-handle)))))))
             (subject (and selector-stable-p node-subjects
                           (ebox-source--table-value node-subjects handle))))
        (cond
         (subject
          (let ((added (make-hash-table :test #'eq))
                (removed (make-hash-table :test #'eq)))
            (puthash new-handle subject added)
            (puthash handle t removed)
            (setq candidate
                  (ebox-source--with-derived
                   candidate
                   :subjects (ebox-source--index-subjects index)
                   :node-subjects
                   (ebox-source--table-overlay
                    node-subjects added removed
                    (ebox-source--table-size node-subjects))
                   :entries (ebox-source--index-entries index)
                   :root-subject (ebox-source--index-root-subject index)
                   :selector-topology (ebox-source--index-selector-topology index)
                   :selector-view (ebox-source--index-selector-view index)
                   :selector-id-table
                   (ebox-source--index-selector-id-table index)
                   :selector-class-table
                   (ebox-source--index-selector-class-table index)
                   :selector-type-table
                   (ebox-source--index-selector-type-table index)
                   :host-ref-table (ebox-source--index-host-ref-table index)
                   :derived-stale-p t))))
         (node-subjects
          ;; Selector metadata changes invalidate subject identity and ancestry;
          ;; the tree owner must derive them again from the candidate root.
          (setq candidate
                (ebox-source--with-derived
                 candidate :host-ref-table
                 (ebox-source--index-host-ref-table index)
                 :derived-stale-p t))))
        (cons candidate new-handle)))))

(defun ebox-source-builder-finish (builder)
  "Seal BUILDER and return its fact-only immutable source index."
  (ebox-source--builder-assert-open builder)
  (let ((records (copy-hash-table (ebox-source--builder-records builder)))
        (handle-records
         (copy-hash-table (ebox-source--builder-handle-records builder)))
        (order (nreverse (copy-sequence (ebox-source--builder-order builder)))))
    (setf (ebox-source--builder-sealed-p builder) t
          (ebox-source--builder-records builder) nil
          (ebox-source--builder-handle-records builder) nil
          (ebox-source--builder-order builder) nil)
    (ebox-source--make-index
     :records (ebox-source--flat-table records #'equal)
     :handle-records (ebox-source--flat-table handle-records #'eq)
     :order order)))

(defun ebox-source-handle-id (handle)
  "Return a detached copy of HANDLE's opaque diagnostic identity."
  (ebox-source--copy-data (ebox-source--handle-id-view handle)))

(defun ebox-source--handle-id-view (handle)
  "Return HANDLE's private immutable identity view."
  (unless (ebox-source-handle-p handle)
    (signal 'wrong-type-argument (list 'ebox-source-handle-p handle)))
  (ebox-source--handle-identity handle))

(cl-defun ebox-source--with-derived
    (index &key subjects node-subjects entries root-subject selector-view selector-topology
           selector-id-table selector-class-table selector-type-table
           host-ref-table derived-stale-p)
  "Return INDEX completed with immutable tree-derived query facts."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (ebox-source--make-index
   :records (ebox-source--index-records index)
   :handle-records (ebox-source--index-handle-records index)
   :order (ebox-source--index-order index)
   :subjects (ebox-source--table-seal subjects #'equal)
   :node-subjects (ebox-source--table-seal node-subjects #'eq)
   :entries entries :root-subject root-subject
   :selector-view (and selector-view (ebox-source--table-seal selector-view #'eq))
   :selector-topology selector-topology
   :selector-id-table selector-id-table
   :selector-class-table selector-class-table
   :selector-type-table selector-type-table
   :host-ref-table host-ref-table
   :derived-stale-p derived-stale-p))

(defun ebox-source--with-order (index handles)
  "Return INDEX sharing all facts with exact document-order HANDLES."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (let* ((order (ebox-source--index-order index))
         (local-handles
          (and (ebox-source-order-p order)
               (copy-sequence (ebox-source-order-local-handles order)))))
    (ebox-source--make-index
     :records (ebox-source--index-records index)
     :handle-records (ebox-source--index-handle-records index)
     :order (if local-handles
                (ebox-source--make-order
                 :handles (copy-sequence handles)
                 :local-handles local-handles :depth 0)
              (copy-sequence handles))
     :selector-topology (ebox-source--index-selector-topology index)
     :selector-view (ebox-source--index-selector-view index)
     :subjects (ebox-source--index-subjects index)
     :node-subjects (ebox-source--index-node-subjects index)
     :entries (ebox-source--index-entries index)
     :root-subject (ebox-source--index-root-subject index)
     :selector-id-table (ebox-source--index-selector-id-table index)
     :selector-class-table (ebox-source--index-selector-class-table index)
     :selector-type-table (ebox-source--index-selector-type-table index)
     :host-ref-table (ebox-source--index-host-ref-table index)
     :derived-stale-p (ebox-source--index-derived-stale-p index))))

(defun ebox-source--with-runtime-hosts (index host-ref-table)
  "Return INDEX sharing its source facts with runtime HOST-REF-TABLE."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (ebox-source--make-index
   :records (ebox-source--index-records index)
   :handle-records (ebox-source--index-handle-records index)
   :order (ebox-source--index-order index)
   :selector-topology (ebox-source--index-selector-topology index)
   :selector-view (ebox-source--index-selector-view index)
   :subjects (ebox-source--index-subjects index)
   :node-subjects (ebox-source--index-node-subjects index)
   :entries (ebox-source--index-entries index)
   :root-subject (ebox-source--index-root-subject index)
   :selector-id-table (ebox-source--index-selector-id-table index)
   :selector-class-table (ebox-source--index-selector-class-table index)
   :selector-type-table (ebox-source--index-selector-type-table index)
   :host-ref-table host-ref-table
   :derived-stale-p (ebox-source--index-derived-stale-p index)))

(defun ebox-source--index-replace-handles
    (index removed added incoming-source-indexes
           &optional replacement-pairs final-order)
  "Return candidate INDEX after two-phase REMOVED and ADDED handle changes.
Source records and exact handle membership are updated persistently.  Tree and
selector derivations remain shared but are marked stale until explicitly
rebuilt or patched by the tree owner.  REPLACEMENT-PAIRS preserve exact order
for nonstructural changes; structural changes supply FINAL-ORDER."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (let ((removed-identities (make-hash-table :test #'equal))
        (removed-handles (make-hash-table :test #'eq))
        (added-records (make-hash-table :test #'equal))
        (added-handle-records (make-hash-table :test #'eq))
        (replacement-table (make-hash-table :test #'eq))
        (replacement-values (make-hash-table :test #'eq))
        added-order)
    (dolist (handle removed)
      (when (ebox-source-handle-p handle)
        (unless (ebox-source-index-handle-member-p index handle)
          (error "Ebox removed source handle is absent"))
        (puthash handle t removed-handles)
        (puthash (ebox-source--handle-id-view handle) t
                 removed-identities)))
    (dolist (handle added)
      (unless (ebox-source-handle-p handle)
        (signal 'wrong-type-argument (list 'ebox-source-handle-p handle)))
      (let ((identity (ebox-source--handle-id-view handle)))
        (when (or (gethash identity added-records)
                  (and (ebox-source--table-member-p
                        (ebox-source--index-records index) identity)
                       (not (gethash identity removed-identities))))
          (error "Ebox source identity occurs more than once: %S" identity))
        (let* ((incoming-index
                (and (hash-table-p incoming-source-indexes)
                     (gethash handle incoming-source-indexes)))
               (record
                (and incoming-index
                     (ebox-source--index-record incoming-index handle))))
          (unless record
            (error "Ebox candidate source is absent from incoming input"))
          (puthash identity record added-records)
          (puthash handle record added-handle-records))
        (push handle added-order)))
    (setq added-order (nreverse added-order))
    (dolist (pair replacement-pairs)
      (unless (and (gethash (car pair) removed-handles)
                   (gethash (cdr pair) added-handle-records))
        (error "Ebox source order replacement is not part of its fact delta"))
      (puthash (car pair) (cdr pair) replacement-table)
      (puthash (cdr pair) t replacement-values))
    (unless final-order
      (maphash
       (lambda (handle _value)
         (unless (gethash handle replacement-table)
           (error "Structural source removal requires a final document order")))
       removed-handles)
      (dolist (handle added-order)
        (unless (gethash handle replacement-values)
          (error "Structural source insertion requires a final document order"))))
    (ebox-source--make-index
     :records
     (ebox-source--table-overlay
      (ebox-source--index-records index) added-records removed-identities
      (+ (- (ebox-source-table-count (ebox-source--index-records index))
            (hash-table-count removed-identities))
         (hash-table-count added-records)))
     :handle-records
     (ebox-source--table-overlay
      (ebox-source--index-handle-records index)
      added-handle-records removed-handles
      (+ (- (ebox-source-table-count
             (ebox-source--index-handle-records index))
            (hash-table-count removed-handles))
         (hash-table-count added-handle-records)))
     :order
     (if final-order
         (ebox-source--make-order
          :handles (copy-sequence final-order)
          :local-handles (copy-sequence added-order) :depth 0)
       (ebox-source--order-overlay
        (ebox-source--index-order index)
        replacement-table removed-handles nil added-order))
     :subjects (ebox-source--index-subjects index)
     :node-subjects (ebox-source--index-node-subjects index)
     :entries (ebox-source--index-entries index)
     :root-subject (ebox-source--index-root-subject index)
     :selector-id-table (ebox-source--index-selector-id-table index)
     :selector-class-table (ebox-source--index-selector-class-table index)
     :selector-type-table (ebox-source--index-selector-type-table index)
     :host-ref-table (ebox-source--index-host-ref-table index)
     :derived-stale-p t)))

(defun ebox-source-index-handles (index)
  "Return source handles from immutable INDEX in document order."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (ebox-source--order-handles (ebox-source--index-order index)))

(defun ebox-source--index-local-handles (index)
  "Return handles added by INDEX's newest persistent overlay."
  (let ((order (ebox-source--index-order index)))
    (and (ebox-source-order-p order)
         (copy-sequence (ebox-source-order-local-handles order)))))

(defun ebox-source-index-handle-member-p (index handle)
  "Return non-nil when exact opaque HANDLE belongs to candidate INDEX."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (and (ebox-source-handle-p handle)
       (ebox-source--table-member-p
        (ebox-source--index-handle-records index) handle)))

(defun ebox-source--index-record (index handle)
  "Return INDEX-owned record for HANDLE, or nil."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (unless (ebox-source-handle-p handle)
    (signal 'wrong-type-argument (list 'ebox-source-handle-p handle)))
  (ebox-source--table-value
   (ebox-source--index-handle-records index) handle))

(defun ebox-source-index-key (index handle)
  "Return HANDLE's detached author key from candidate INDEX."
  (ebox-source--copy-data (ebox-source--index-key-view index handle)))

(defun ebox-source--index-key-view (index handle)
  "Return HANDLE's private immutable author key view in INDEX."
  (when-let* ((record (ebox-source--index-record index handle)))
    (ebox-source-record-key record)))

(defun ebox-source-index-id (index handle)
  "Return HANDLE's detached selector id from candidate INDEX."
  (ebox-source--copy-data (ebox-source--index-id-view index handle)))

(defun ebox-source--index-id-view (index handle)
  "Return HANDLE's private immutable selector id view in INDEX."
  (when-let* ((record (ebox-source--index-record index handle)))
    (ebox-source-record-id record)))

(defun ebox-source-index-classes (index handle)
  "Return HANDLE's detached selector classes in candidate INDEX."
  (ebox-source--copy-data (ebox-source--index-classes-view index handle)))

(defun ebox-source--index-classes-view (index handle)
  "Return HANDLE's private immutable selector classes view in INDEX."
  (when-let* ((record (ebox-source--index-record index handle)))
    (ebox-source-record-classes record)))

(defun ebox-source-index-attributes (index handle)
  "Return HANDLE's detached selector attributes in candidate INDEX."
  (ebox-source--copy-data (ebox-source--index-attributes-view index handle)))

(defun ebox-source--index-attributes-view (index handle)
  "Return HANDLE's private immutable selector attributes view in INDEX."
  (when-let* ((record (ebox-source--index-record index handle)))
    (ebox-source-record-attributes record)))

(defun ebox-source-index-states (index handle)
  "Return HANDLE's detached selector states in candidate INDEX."
  (ebox-source--copy-data (ebox-source--index-states-view index handle)))

(defun ebox-source--with-interaction-state (index state target-handle &optional known-owners)
  "Return INDEX with buffer-derived STATE projected on TARGET-HANDLE.
KNOWN-OWNERS, when non-nil, lists the previous owners in an unchanged tree.
A list containing nil certifies that no previous owner exists."
  (let ((records (make-hash-table :test #'equal))
        (handles (make-hash-table :test #'eq)))
    (dolist (handle (if known-owners
                       (delete-dups (delq nil (cons target-handle
                                                   (copy-sequence known-owners))))
                     (ebox-source-index-handles index)))
      (let* ((record (ebox-source--index-record index handle))
             (enabled (eq handle target-handle))
             (states (ebox-source-record-interaction-states record)))
        (unless (eq enabled (not (null (member state states))))
          (let ((copy (copy-ebox-source-record record)))
            (setf (ebox-source-record-interaction-states copy)
                  (if enabled (cons state states) (remove state states)))
            (puthash (ebox-source--handle-id-view handle) copy records)
            (puthash handle copy handles)))))
    (if (zerop (hash-table-count handles)) index
      ;; Interaction changes invalidate selector facts, not retained Host
      ;; identity. Focus and active state are projected in sequence and both
      ;; must resolve against the same runtime topology.
      (let ((copy (ebox-source--with-derived
                   index :host-ref-table (ebox-source--index-host-ref-table index)
                   ;; Retain the old relationship witness for Tree's rebuild.
                   ;; Its subjects are not a current selector view: their
                   ;; local state facts still belong to the previous index.
                   :subjects (ebox-source--index-subjects index)
                   :selector-topology (ebox-source--index-selector-topology index)
                   :derived-stale-p t)))
        (setf (ebox-source--index-records copy)
              (ebox-source--table-overlay
               (ebox-source--index-records index) records
               (make-hash-table :test #'equal)
               (ebox-source--table-size (ebox-source--index-records index)))
              (ebox-source--index-handle-records copy)
              (ebox-source--table-overlay
               (ebox-source--index-handle-records index) handles
               (make-hash-table :test #'eq)
               (ebox-source--table-size (ebox-source--index-handle-records index))))
        copy))))

(defun ebox-source--record-selector-states (record)
  "Return authored and interaction-derived selector states for RECORD."
  (let ((states (append (ebox-source-record-interaction-states record)
                        (ebox-source-record-states record))))
    (if (plist-get (ebox-source-record-interactions record) :disabled)
        (cons "disabled" states)
      states)))

(defun ebox-source--index-states-view (index handle)
  "Return HANDLE's private immutable selector states view in INDEX."
  (when-let* ((record (ebox-source--index-record index handle)))
    (ebox-source--record-selector-states record)))

(defun ebox-source-index-declarations (index handle)
  "Return HANDLE's detached canonical declarations from candidate INDEX."
  (ebox-source--copy-data
   (ebox-source--index-declarations-view index handle)))

(defun ebox-source--index-declarations-view (index handle)
  "Return HANDLE's private declaration view in INDEX.
Prepared live updates may mutate only their provider-owned source cells."
  (when-let* ((record (ebox-source--index-record index handle)))
    (ebox-source-record-declarations record)))

(defun ebox-source-index-provenance (index handle)
  "Return HANDLE's detached provenance in candidate INDEX."
  (ebox-source--copy-data (ebox-source--index-provenance-view index handle)))

(defun ebox-source--index-provenance-view (index handle)
  "Return HANDLE's private immutable provenance view in INDEX."
  (when-let* ((record (ebox-source--index-record index handle)))
    (ebox-source-record-provenance record)))

(defun ebox-source--copy-record (record)
  "Return a detached copy of source RECORD."
  (and record
       (ebox-source--make-record
        :ecss (ebox-source--copy-data (ebox-source-record-ecss record))
        :ecss-targets (ebox-source--copy-data
                       (ebox-source-record-ecss-targets record))
        :ecss-scopes (copy-sequence (ebox-source-record-ecss-scopes record))
        :ecss-scope-roots (copy-sequence (ebox-source-record-ecss-scope-roots record))
        :key (ebox-source--copy-data (ebox-source-record-key record))
        :id (ebox-source--copy-data (ebox-source-record-id record))
        :classes (ebox-source--copy-data
                  (ebox-source-record-classes record))
        :attributes (ebox-source--copy-data
                     (ebox-source-record-attributes record))
        :states (ebox-source--copy-data (ebox-source-record-states record))
        :interaction-states (copy-sequence (ebox-source-record-interaction-states record))
        :declarations (ebox-source--copy-data
                       (ebox-source-record-declarations record))
        :provenance (ebox-source--copy-data
                     (ebox-source-record-provenance record))
        :interactions (ebox-text-property-value-copy
                       (ebox-source-record-interactions record)))))

(defun ebox-source-index-record (index handle)
  "Return a detached source record for HANDLE in INDEX, or nil."
  (ebox-source--copy-record (ebox-source--index-record index handle)))

(defun ebox-source--index-subject (index handle)
  "Return INDEX-owned ECSS subject for HANDLE, or nil."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (ebox-source--table-value
   (ebox-source--index-subjects index)
   (ebox-source--handle-id-view handle)))

(defun ebox-source--index-node-subject (index node)
  "Return INDEX-owned ECSS subject for canonical NODE, or nil.
Node copies retain the same opaque source handle, so subject lookup must not
depend on the identity of a particular plist object."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (when-let* ((handle (and (listp node)
                           (plist-get node :ebox-source-handle))))
    (ebox-source--table-value
     (ebox-source--index-node-subjects index) handle)))

(defun ebox-source--subject-table-get (table handle)
  "Return exact HANDLE's subject from immutable TABLE."
  (ebox-source--table-value table handle))

(defun ebox-source--index-node-subject-table-view (index)
  "Return INDEX's immutable source-handle to ECSS-subject table."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (ebox-source--index-node-subjects index))

(defun ebox-source--index-entries-view (index)
  "Return INDEX's immutable document-order subject entries."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (ebox-source--index-entries index))

(defun ebox-source--index-root-subject-view (index)
  "Return INDEX's ECSS root subject."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (ebox-source--index-root-subject index))

(defun ebox-source--index-host-ref-table-view (index)
  "Return INDEX's immutable host-reference table."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (ebox-source--index-host-ref-table index))

(defun ebox-source--index-selector-table (index kind)
  "Return INDEX's derived selector table of KIND."
  (unless (ebox-source-index-p index)
    (signal 'wrong-type-argument (list 'ebox-source-index-p index)))
  (pcase kind
    ('id (ebox-source--index-selector-id-table index))
    ('class (ebox-source--index-selector-class-table index))
    ('type (ebox-source--index-selector-type-table index))
    (_ (error "Unknown Ebox source selector index kind: %S" kind))))

(provide 'ebox-source)
;;; ebox-source.el ends here
