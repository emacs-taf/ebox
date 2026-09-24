;;; ebox-update-selector.el --- Prepared selector facts -*- lexical-binding: t; -*-

;;; Commentary:
;; Compile finite selector fact changes into private source/subject cells.
;; Selector matching and cascade remain ECSS-owned.  Query indexes contain
;; cold candidate supersets; ECSS checks the current subject on every query.

;;; Code:
(require 'cl-lib)
(require 'ebox-source)
(require 'ebox-selector-view)
(require 'ebox-tree)
(require 'ebox-surface)

(cl-defstruct (ebox-update-selector--proof (:constructor ebox-update-selector--make-proof))
  node classes raw tokens lookup initial)

(cl-defstruct (ebox-update-selector--context (:constructor ebox-update-selector--make-context))
  index entries ranks)

(cl-defstruct (ebox-source--interaction-slots (:constructor ebox-source--make-interaction-slots))
  index context lookup entries undo undo-count marks epoch)

(cl-defstruct (ebox-update-selector--interaction-entry
               (:constructor ebox-update-selector--make-interaction-entry))
  record subject source-values subject-values ordinal)

(defun ebox-update-selector--class-dependent-p (selector changed)
  "Return whether SELECTOR can observe any class token in CHANGED."
  (let ((ast (ecss-selector-normalize selector)))
    (cl-labels ((visit (form)
                 (and (consp form)
                      (or (and (eq (car form) :class) (gethash (cadr form) changed))
                          ;; Attribute matching must not gain an unproved
                          ;; alternate observation of the complete class text.
                          (and (eq (car form) :attr)
                               (member (cadr form) '(class "class")))
                          (cl-some #'visit form)))))
      (visit ast))))

(defun ebox-update-selector-prepare (state node raw-variants)
  "Prove NODE's finite canonical RAW-VARIANTS leave the cascade unchanged.
Each variant follows the source class grammar: a string or symbol is one
token; nil or a flat token list is a class set.  Strings are not split.
The strong gate rejects every rule or rule-scope selector that mentions a
changing class token, including relational and combined selectors.  Thus
several admitted Hosts cannot jointly activate a previously inactive rule.
Static bindings and untagged declarations exclude independent evaluators;
all selector predicates, declaration winners, provenance and inherited
computed-style closures consequently remain unchanged.  Unknown cases
return nil before any source or selector mutation."
  (catch 'unsupported
    (condition-case nil
        (let* ((source (plist-get state :source-index))
               (record (ebox-source--index-record source (plist-get node :ebox-source-handle)))
               (classes (and record (ebox-source-record-classes record)))
               (changed (make-hash-table :test #'equal))
               (lookup (make-hash-table :test #'equal))
               (raw (and (vectorp raw-variants) (copy-sequence raw-variants)))
               (tokens (and raw (make-vector (length raw) nil))) initial)
          (unless (and record raw (> (length raw) 0)) (throw 'unsupported nil))
          (dotimes (index (length raw))
            (unless (ebox-source-class-list-p (aref raw index)) (throw 'unsupported nil))
            (aset raw index (ebox-source--copy-data (aref raw index)))
            (let ((value (ebox-source--metadata-tokens (aref raw index))))
              (aset tokens index value)
              (puthash (aref raw index) (1+ index) lookup)
              (when (equal classes value) (setq initial (1+ index)))
              (dolist (token classes)
                (unless (member token value) (puthash token t changed)))
              (dolist (token value)
                (unless (member token classes) (puthash token t changed)))))
          (unless initial (throw 'unsupported nil))
          (when (> (hash-table-count changed) 0)
            (unless (ebox-incremental--static-style-bindings-p state) (throw 'unsupported nil))
            (dolist (handle (ebox-source-index-handles source))
              (let ((declarations (ebox-source-record-declarations
                                   (ebox-source--index-record source handle))))
                (while declarations
                  (when (or (functionp (cadr declarations))
                            (ecss-declaration-value-tagged-p (cadr declarations)))
                    (throw 'unsupported nil))
                  (setq declarations (cddr declarations)))))
            (dolist (sheet (cons ebox-style-stylesheet
                                 (mapcar #'ecss-scope-stylesheet
                                         (ebox-style-source-scopes source (plist-get state :root-node)))))
              (dolist (rule (ecss-stylesheet-rules sheet))
                (when (or (ebox-update-selector--class-dependent-p (ecss-rule-selector rule) changed)
                          (and (ecss-rule-scope rule)
                               (ebox-update-selector--class-dependent-p (ecss-rule-scope rule) changed)))
                  (throw 'unsupported nil)))))
          (ebox-update-selector--make-proof
           :node node :classes (copy-sequence classes) :raw raw :tokens tokens :lookup lookup
           :initial initial))
      (error nil))))

(defun ebox-update-selector-value-p (proof raw)
  "Return non-nil when RAW belongs to PROOF's cold finite domain."
  (and (gethash raw (ebox-update-selector--proof-lookup proof)) t))

(defun ebox-update-selector-value (proof raw)
  "Return PROOF's owned RAW representative.
Use `ebox-update-selector-value-p' to distinguish an admitted nil from a miss."
  (when-let* ((index (gethash raw (ebox-update-selector--proof-lookup proof))))
    (aref (ebox-update-selector--proof-raw proof) (1- index))))

(defun ebox-update-selector--table-copy (table)
  "Copy private selector TABLE into a cold mutable hash table."
  (if (ebox-source-table-p table) (ebox-source--table-materialize table) (copy-hash-table table)))

(defun ebox-update-selector--context (index)
  "Return INDEX's shared private selector context, preparing it once."
  (or (ebox-source--index-prepared-selector-context index)
      (let* ((view (ebox-update-selector--table-copy (ebox-source--index-selector-view index)))
             (subjects (ebox-update-selector--table-copy (ebox-source--index-subjects index)))
             (nodes (ebox-update-selector--table-copy (ebox-source--index-node-subjects index)))
             (classes (copy-hash-table (ebox-source--index-selector-class-table index)))
             (entries (make-hash-table :test #'eq)) (ranks (make-hash-table :test #'eq))
             (context (ebox-update-selector--make-context :entries entries :ranks ranks))
             (rank 0) query-entries candidate)
        (maphash (lambda (token subject) (puthash token (copy-ebox-selector-subject subject) view)) view)
        (dolist (table (list subjects nodes))
          (maphash (lambda (key subject)
                     (puthash key (gethash (ebox-selector-subject-token subject) view) table)) table))
        (dolist (entry (ebox-source--index-entries index))
          (let* ((node (plist-get entry :node)) (copy (copy-sequence entry))
                 (subject (gethash (plist-get node :ebox-source-handle) nodes)))
            (plist-put copy :subject subject)
            (push copy query-entries)
            (puthash node (cons node (plist-get entry :path)) entries)
            (puthash node rank ranks)
            (setq rank (1+ rank))))
        (setq candidate
              (ebox-source--with-derived
               index :subjects subjects :node-subjects nodes :selector-view view
               :selector-topology (ebox-source--index-selector-topology index)
               :entries (nreverse query-entries)
               :root-subject (and (ebox-source--index-root-subject index)
                                  (gethash (ebox-selector-subject-token
                                            (ebox-source--index-root-subject index)) view))
               :selector-id-table (ebox-source--index-selector-id-table index)
               :selector-class-table classes :selector-type-table (ebox-source--index-selector-type-table index)
               :host-ref-table (ebox-source--index-host-ref-table index) :derived-stale-p nil))
        (setf (ebox-source--index-prepared-selector-context candidate) context
              (ebox-update-selector--context-index context) candidate)
        context)))

(defun ebox-update-selector-bind (state slots position proof)
  "Bind SLOTS' class POSITION and PROOF into STATE's shared selector authority.
This cold equivalent preparation changes no visible selector facts.  Warm
class writes update only the copied source record, its private subject and
the prebound raw-value cell.  Query candidate supersets are built here once."
  (when (or (plist-get state :selector-index-stale-p)
            (ebox-source--index-derived-stale-p (plist-get state :source-index)))
    (let* ((source (plist-get state :source-index))
           (rebuilt (ebox-source--with-runtime-hosts
                     (ebox-tree-source-index (plist-get state :root-node) nil nil source)
                     (ebox-source--index-host-ref-table source))))
      (plist-put state :source-index rebuilt)))
  (let* ((index (plist-get state :source-index))
         (context (ebox-update-selector--context index))
         (candidate (ebox-update-selector--context-index context))
         (handle (ebox-source--update-slots-handle slots))
         (record (ebox-source--index-record candidate handle))
         (subject (ebox-source--index-node-subject candidate (ebox-update-selector--proof-node proof)))
         (node (ebox-update-selector--proof-node proof))
         (entry (gethash node (ebox-update-selector--context-entries context)))
         (table (ebox-source--index-selector-class-table candidate))
         (ranks (ebox-update-selector--context-ranks context))
         (raw-cell (aref (aref (ebox-source--update-slots-node-cells slots) position) 0))
         (undo (make-vector 3 nil)))
    (unless (and (ebox-source--update-slots-current-p slots index) subject entry
                 (equal (ebox-source-record-classes record) (ebox-update-selector--proof-classes proof)))
      (error "Prepared class proof no longer describes its source"))
    (setcar raw-cell (aref (ebox-update-selector--proof-raw proof)
                          (1- (ebox-update-selector--proof-initial proof))))
    (dotimes (variant (length (ebox-update-selector--proof-tokens proof)))
      (dolist (token (aref (ebox-update-selector--proof-tokens proof) variant))
        (unless (assq node (gethash token table))
          (puthash token
                   (sort (cons entry (copy-sequence (gethash token table)))
                         (lambda (left right) (< (gethash (car left) ranks) (gethash (car right) ranks))))
                   table))))
    (ebox-source--update-slots-bind-selector
     slots position context
     (lambda (_raw)
       (aset undo 0 (ebox-source-record-classes record))
       (aset undo 1 (ebox-selector-subject-classes subject))
       (aset undo 2 (car raw-cell)))
     (lambda (raw)
       (let* ((ordinal (gethash raw (ebox-update-selector--proof-lookup proof)))
              (tokens (and ordinal (aref (ebox-update-selector--proof-tokens proof) (1- ordinal)))))
         (unless ordinal (error "Prepared class value is outside its finite domain"))
         (setf (ebox-source-record-classes record) tokens
               (ebox-selector-subject-classes subject) tokens)
         (setcar raw-cell (aref (ebox-update-selector--proof-raw proof) (1- ordinal)))))
     (lambda ()
       (setf (ebox-source-record-classes record) (aref undo 0)
             (ebox-selector-subject-classes subject) (aref undo 1))
       (setcar raw-cell (aref undo 2))))
    (plist-put state :source-index candidate)
    (plist-put state :selector-id-table (ebox-source--index-selector-id-table candidate))
    (plist-put state :selector-class-table table)
    (plist-put state :selector-type-table (ebox-source--index-selector-type-table candidate))
    (plist-put state :selector-index-stale-p nil)
    t))

(defun ebox-source--interaction-slots-prepare (index handles)
  "Bind private interaction source/subject cells for opaque HANDLES in INDEX.
Existing prepared records retain identity and declaration/class cells."
  (if (zerop (length handles))
      (ebox-source--make-interaction-slots
       :index index :context (ebox-source--index-prepared-selector-context index)
       :lookup (make-hash-table :test #'eq) :entries [] :undo [] :undo-count 0 :marks [] :epoch 0)
   (let* ((context (ebox-update-selector--context index))
         (candidate (ebox-update-selector--context-index context))
         (added (make-hash-table :test #'eq)) (builder (ebox-source-builder-create))
         (lookup (make-hash-table :test #'eq)) replacements entries)
    (dotimes (position (length handles))
     (let ((handle (elt handles position)))
      (when (and handle (not (gethash handle lookup)))
        (let* ((record (ebox-source--index-record candidate handle))
               (subject (ebox-source--table-value (ebox-source--index-node-subjects candidate) handle)))
          (unless (and record subject) (error "Prepared interaction target has no source subject"))
          (unless (ebox-source-record-mutable-prepared-p record)
            (setq record (ebox-source--copy-record record))
            (setf (ebox-source-record-mutable-prepared-p record) t)
            (ebox-source--builder-add-record builder handle record)
            (push handle replacements))
          (let ((source-values (make-vector 4 nil)) (subject-values (make-vector 4 nil))
                (copy (copy-ebox-source-record record)))
            (dotimes (mask 4)
              (setf (ebox-source-record-interaction-states copy)
                    (append (when (/= 0 (logand mask 1)) '("focus"))
                            (when (/= 0 (logand mask 2)) '("active"))
                            (cl-remove-if (lambda (state) (member state '("focus" "active")))
                                          (ebox-source-record-interaction-states record))))
              (aset source-values mask (ebox-source-record-interaction-states copy))
              (aset subject-values mask (ebox-source--record-selector-states copy)))
            (let ((entry (ebox-update-selector--make-interaction-entry
                          :record record :subject subject :source-values source-values
                          :subject-values subject-values :ordinal (length entries))))
              (puthash handle entry lookup) (push entry entries)))))))
    (when replacements
      (let ((incoming (ebox-source-builder-finish builder)))
        (dolist (handle replacements) (puthash handle incoming added))
        (setq candidate (ebox-source--index-replace-handles
                         candidate replacements replacements added
                         (mapcar (lambda (handle) (cons handle handle)) replacements)))
        (setf (ebox-source--index-selector-view candidate)
              (ebox-source--index-selector-view (ebox-update-selector--context-index context))
              (ebox-source--index-selector-topology candidate)
              (ebox-source--index-selector-topology (ebox-update-selector--context-index context))
              (ebox-source--index-derived-stale-p candidate) nil
              (ebox-source--index-prepared-selector-context candidate) context
              (ebox-update-selector--context-index context) candidate)))
    (ebox-source--make-interaction-slots
     :index candidate :context context :lookup lookup :entries (vconcat entries)
     :undo (make-vector 12 nil) :undo-count 0 :marks (make-vector (length entries) 0) :epoch 0))))

(defun ebox-source--interaction-slots-current-p (slots index)
  "Return whether INDEX retains SLOTS' exact private selector context."
  (and (ebox-source--interaction-slots-p slots) (ebox-source-index-p index)
       (eq (ebox-source--interaction-slots-context slots)
           (ebox-source--index-prepared-selector-context index))))

(defun ebox-source--interaction-slots-stage (slots old-focus new-focus old-active new-active)
  "Stage focus/active HANDLES through SLOTS with at most four undo entries."
  (let ((inhibit-quit t)
        (epoch (1+ (ebox-source--interaction-slots-epoch slots)))
        (marks (ebox-source--interaction-slots-marks slots))
        (undo (ebox-source--interaction-slots-undo slots)))
    (setf (ebox-source--interaction-slots-epoch slots) epoch
          (ebox-source--interaction-slots-undo-count slots) 0)
    (dotimes (index 4)
      (let ((handle (pcase index (0 old-focus) (1 new-focus) (2 old-active) (_ new-active))))
        (when handle
          (let* ((entry (gethash handle (ebox-source--interaction-slots-lookup slots)))
                 (ordinal (and entry (ebox-update-selector--interaction-entry-ordinal entry))))
            (unless entry (error "Prepared interaction handle is outside its target pool"))
            (unless (= (aref marks ordinal) epoch)
              (aset marks ordinal epoch)
              (let ((offset (* 3 (ebox-source--interaction-slots-undo-count slots))))
                (aset undo offset entry)
                (aset undo (1+ offset) (ebox-source-record-interaction-states
                                      (ebox-update-selector--interaction-entry-record entry)))
                (aset undo (+ 2 offset) (ebox-selector-subject-states
                                       (ebox-update-selector--interaction-entry-subject entry)))
                (cl-incf (ebox-source--interaction-slots-undo-count slots))))))))
    (dotimes (index (ebox-source--interaction-slots-undo-count slots))
      (let* ((entry (aref undo (* 3 index)))
             (record (ebox-update-selector--interaction-entry-record entry))
             (focus (and new-focus (eq entry (gethash new-focus (ebox-source--interaction-slots-lookup slots)))))
             (active (and new-active (eq entry (gethash new-active (ebox-source--interaction-slots-lookup slots)))))
             (mask (+ (if focus 1 0) (if active 2 0))))
        (setf (ebox-source-record-interaction-states record)
              (aref (ebox-update-selector--interaction-entry-source-values entry) mask)
              (ebox-selector-subject-states (ebox-update-selector--interaction-entry-subject entry))
              (aref (ebox-update-selector--interaction-entry-subject-values entry) mask))))))

(defun ebox-source--interaction-slots-rollback (slots)
  "Restore SLOTS' last bounded interaction source/subject journal."
  (let ((inhibit-quit t) (undo (ebox-source--interaction-slots-undo slots)))
    (dotimes (index (ebox-source--interaction-slots-undo-count slots))
      (let* ((offset (* 3 index)) (entry (aref undo offset)))
        (setf (ebox-source-record-interaction-states (ebox-update-selector--interaction-entry-record entry))
              (aref undo (1+ offset))
              (ebox-selector-subject-states (ebox-update-selector--interaction-entry-subject entry))
              (aref undo (+ 2 offset)))))
    (setf (ebox-source--interaction-slots-undo-count slots) 0)))

(provide 'ebox-update-selector)
;;; ebox-update-selector.el ends here
