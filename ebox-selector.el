;;; ebox-selector.el --- CSS-like runtime selectors for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Compiles CSS-like lookup syntax to TP structured selectors and adapts Ebox
;; trees/runtime indexes to TP subjects.  Stable identity remains node ids,
;; region ids, and keys.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-buffer-backend)
(require 'ebox-tree)
(require 'tp-style)
(require 'tp-surface)

(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--buffer-root-node "ebox-incremental" (buffer))
(declare-function ebox--buffer-render-state "ebox-incremental" (buffer))
(declare-function ebox--buffer-selector-id-table "ebox-incremental" (buffer))
(declare-function ebox--buffer-selector-class-table
                  "ebox-incremental" (buffer))
(declare-function ebox--buffer-selector-type-table
                  "ebox-incremental" (buffer))
(declare-function ebox-incremental-begin-batch "ebox-incremental" (buffer))
(declare-function ebox-incremental-flush "ebox-incremental" (buffer))
(declare-function ebox-region-update "ebox" (region-id &rest props))

(cl-defstruct
    (ebox-region-handle
     (:constructor ebox-selector--make-region-handle)
     (:conc-name ebox-selector--region-handle-))
  "Opaque surface-scoped identity for one editable Ebox region."
  buffer surface object logical-id)

(defun ebox-selector--live-region-handle
    (buffer object &optional logical-id)
  "Return a live region handle for OBJECT in BUFFER, or nil."
  (let* ((state (ebox--buffer-render-state buffer))
         (surface (plist-get state :surface))
         (region-id
          (and (tp-object-live-p object)
               (gethash object
                        (plist-get state :surface-object-region-table)))))
    (when (and (tp-surface-live-p surface) region-id)
      (ebox-selector--make-region-handle
       :buffer buffer :surface surface :object object :logical-id logical-id))))

;;;###autoload
(defun ebox-region-resolve (buffer-or-name logical-id)
  "Resolve LOGICAL-ID in BUFFER-OR-NAME to an opaque editable region handle."
  (let ((buffer (get-buffer buffer-or-name)))
    (unless (buffer-live-p buffer)
      (user-error "Ebox region target is not a live buffer: %S"
                  buffer-or-name))
    (let* ((state (ebox--buffer-render-state buffer))
           (normalized (ebox-tree-metadata-string logical-id))
           (entries
            (and state
                 (gethash normalized
                          (plist-get state :logical-id-region-table))))
           (handles
            (delq nil
                  (mapcar
                   (lambda (entry)
                     (ebox-selector--live-region-handle
                      buffer (car entry) normalized))
                   entries))))
      (pcase (length handles)
        (0 (user-error "Ebox logical region does not exist: %S" logical-id))
        (1 (car handles))
        (_ (user-error "Ebox logical region is ambiguous: %S" logical-id))))))

(defun ebox-selector--region-target (handle)
  "Return HANDLE's current internal `(BUFFER . REGION-ID)' target."
  (unless (ebox-region-handle-p handle)
    (signal 'wrong-type-argument (list 'ebox-region-handle-p handle)))
  (let* ((buffer (ebox-selector--region-handle-buffer handle))
         (surface (ebox-selector--region-handle-surface handle))
         (object (ebox-selector--region-handle-object handle))
         (state (and (buffer-live-p buffer)
                     (ebox--buffer-render-state buffer)))
         (region-id
          (and state
               (eq surface (plist-get state :surface))
               (tp-surface-live-p surface)
               (tp-object-live-p object)
               (gethash object
                        (plist-get state :surface-object-region-table)))))
    (unless region-id
      (user-error "Ebox region handle is stale"))
    (cons buffer region-id)))

(defun ebox-selector--identifier-char-p (char)
  "Return non-nil when CHAR is accepted in a selector identifier."
  (or (and (>= char ?a) (<= char ?z))
      (and (>= char ?A) (<= char ?Z))
      (and (>= char ?0) (<= char ?9))
      (memq char '(?_ ?- ?:))))

(defun ebox-selector--skip-space (selector pos)
  "Return the next non-space position in SELECTOR after POS."
  (let ((len (length selector)))
    (while (and (< pos len)
                (memq (aref selector pos) '(?\s ?\t ?\n ?\r)))
      (setq pos (1+ pos)))
    pos))

(defun ebox-selector--read-identifier (selector pos)
  "Read one selector identifier from SELECTOR at POS.
Return a cons of (IDENTIFIER . NEXT-POS)."
  (let ((start pos)
        (len (length selector)))
    (while (and (< pos len)
                (ebox-selector--identifier-char-p (aref selector pos)))
      (setq pos (1+ pos)))
    (when (= pos start)
      (user-error "ebox-selector: expected identifier at %d in %S"
                  pos selector))
    (cons (substring selector start pos) pos)))

(defun ebox-selector--read-attr-value (selector pos)
  "Read one attribute value from SELECTOR at POS.
Return a cons of (VALUE . NEXT-POS)."
  (let ((len (length selector)))
    (if (and (< pos len) (= (aref selector pos) ?\"))
        (let ((start (1+ pos)))
          (setq pos start)
          (while (and (< pos len)
                      (/= (aref selector pos) ?\"))
            (setq pos (1+ pos)))
          (when (>= pos len)
            (user-error "ebox-selector: unterminated attribute value in %S"
                        selector))
          (cons (substring selector start pos) (1+ pos)))
      (ebox-selector--read-identifier selector pos))))

(defun ebox-selector--compound-selector (type id classes attrs)
  "Return one TP selector combining TYPE, ID, CLASSES, and ATTRS."
  (let ((parts
         (append
          (when type (list (list :type type)))
          (when id (list (list :id id)))
          (mapcar (lambda (class) (list :class class))
                  (nreverse classes))
          (mapcar (lambda (attr) (list :attr (car attr) (cdr attr)))
                  (nreverse attrs)))))
    (if (= (length parts) 1)
        (car parts)
      (cons :and parts))))

(defun ebox-selector--parse-attribute (selector pos attrs)
  "Parse an attribute selector in SELECTOR at POS and push into ATTRS."
  (let* ((name-read (ebox-selector--read-identifier selector (1+ pos)))
         (name (car name-read))
         (next (cdr name-read)))
    (unless (and (< next (length selector))
                 (= (aref selector next) ?=))
      (user-error "ebox-selector: expected = after attribute at %d in %S"
                  next selector))
    (let* ((value-read (ebox-selector--read-attr-value selector (1+ next)))
           (value (car value-read))
           (end (cdr value-read)))
      (unless (and (< end (length selector))
                   (= (aref selector end) ?\]))
        (user-error "ebox-selector: expected ] at %d in %S" end selector))
      (list :attrs (cons (cons (intern (concat ":" name)) value)
                         attrs)
            :pos (1+ end)))))

(defun ebox-selector--parse-simple (selector pos)
  "Parse one simple selector from SELECTOR at POS.
Return a cons of (SIMPLE-SELECTOR . NEXT-POS)."
  (let ((len (length selector))
        type id classes attrs)
    (when (and (< pos len)
               (ebox-selector--identifier-char-p (aref selector pos)))
      (let ((read (ebox-selector--read-identifier selector pos)))
        (setq type (intern (car read))
              pos (cdr read))))
    (while (and (< pos len)
                (memq (aref selector pos) '(?. ?# ?\[)))
      (pcase (aref selector pos)
        (?.
         (let ((read (ebox-selector--read-identifier selector (1+ pos))))
           (push (car read) classes)
           (setq pos (cdr read))))
        (?#
         (let ((read (ebox-selector--read-identifier selector (1+ pos))))
           (setq id (car read)
                 pos (cdr read))))
        (?\[
         (let* ((parsed (ebox-selector--parse-attribute selector pos attrs)))
           (setq attrs (plist-get parsed :attrs)
                 pos (plist-get parsed :pos))))))
    (unless (or type id classes attrs)
      (user-error "ebox-selector: expected selector at %d in %S"
                  pos selector))
    (cons (ebox-selector--compound-selector type id classes attrs) pos)))

(defun ebox-selector--combinator (char)
  "Return TP combinator for CHAR, or nil when CHAR is not a combinator."
  (pcase char
    (?> :child)
    (?+ :adjacent)
    (?~ :sibling)
    (_ nil)))

(defun ebox-selector--combine-sequence (sequence)
  "Fold parsed selector SEQUENCE into one nested TP selector."
  (let ((result (pop sequence)))
    (while sequence
      (let ((combinator (pop sequence))
            (target (pop sequence)))
        (unless target
          (user-error "ebox-selector: combinator %S has no target" combinator))
        (setq result (list combinator result target))))
    result))

;;;###autoload
(defun ebox-selector-parse (selector)
  "Compile CSS-like SELECTOR into TP's structured selector AST."
  (unless (and (stringp selector)
               (> (length (string-trim selector)) 0))
    (user-error "ebox-selector: selector must be a non-empty string"))
  (let* ((pos (ebox-selector--skip-space selector 0))
         (len (length selector))
         sequence)
    (while (< pos len)
      (let ((read (ebox-selector--parse-simple selector pos)))
        (push (car read) sequence)
        (setq pos (cdr read)))
      (let ((before-space pos))
        (setq pos (ebox-selector--skip-space selector pos))
        (cond
         ((>= pos len))
         ((ebox-selector--combinator (aref selector pos))
          (push (ebox-selector--combinator (aref selector pos)) sequence)
          (setq pos (ebox-selector--skip-space selector (1+ pos)))
          (when (>= pos len)
            (user-error "ebox-selector: combinator has no target in %S"
                        selector)))
         ((> pos before-space)
          (push :descendant sequence))
         (t
          (user-error "ebox-selector: expected combinator at %d in %S"
                      pos selector)))))
    (ebox-selector--combine-sequence (nreverse sequence))))

(defun ebox-selector--node-region-id (node)
  "Return NODE's editable box region id, or nil."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box (ebox--ensure-region-id node))
    ('flex
     (when-let ((box (plist-get node :box)))
       (ebox--ensure-region-id box)))
    ('grid
     (when-let ((box (plist-get node :box)))
       (ebox--ensure-region-id box)))
    ('flex-item
     (ebox-selector--node-region-id (plist-get node :node)))
    (_ nil)))

;;;###autoload
(defun ebox-selector-match-node-p (node selector)
  "Return non-nil when NODE matches structured TP SELECTOR."
  (tp-selector-match-p selector (ebox-tree-node-subject node)))

(defun ebox-selector--match-handle (node path selector)
  "Return a selector match handle for NODE on PATH."
  (list :node node
        :node-id (ebox--ensure-node-id node)
        :region-id (ebox-selector--node-region-id node)
        :path path
        :selector selector))

(defun ebox-selector--matching-subject-entries (root ast)
  "Return semantic ROOT entries whose TP subjects match AST."
  (cl-remove-if-not
   (lambda (entry)
     (tp-selector-match-p ast (plist-get entry :subject)))
   (plist-get (ebox-tree-subject-index root) :entries)))

(defun ebox-selector--subject-entry-handle (entry selector)
  "Return a match handle for semantic subject ENTRY and SELECTOR."
  (ebox-selector--match-handle
   (plist-get entry :node) (plist-get entry :path) selector))

;;;###autoload
(defun ebox-selector-query-all (root selector)
  "Return document-ordered selector match handles under ROOT."
  (let ((ast (ebox-selector-parse selector)))
    (mapcar (lambda (entry)
              (ebox-selector--subject-entry-handle entry selector))
            (ebox-selector--matching-subject-entries root ast))))

(defun ebox-selector--resolve-buffer (buffer)
  "Return live buffer object for BUFFER, or signal a user error."
  (let ((resolved (get-buffer buffer)))
    (unless (and resolved (buffer-live-p resolved))
      (user-error "ebox-selector: buffer is not live: %S" buffer))
    resolved))

(defun ebox-selector--handle-with-buffer (handle buffer)
  "Return selector HANDLE annotated with BUFFER ownership."
  (let* ((state (ebox--buffer-render-state buffer))
         (region-id (plist-get handle :region-id))
         (object
          (and region-id
               (gethash region-id
                        (plist-get state :region-surface-object-table))))
         (region-handle
          (and object
               (ebox-selector--live-region-handle
                buffer object
                (ebox-tree-node-id (plist-get handle :node))))))
    (append handle
            (list :buffer buffer :region-handle region-handle))))

(defun ebox-selector--relational-p (ast)
  "Return non-nil when AST contains a selector relationship."
  (pcase (car-safe ast)
    ((or :descendant :child :adjacent :sibling) t)
    ((or :and :is :where :not)
     (cl-some #'ebox-selector--relational-p (cdr ast)))
    (_ nil)))

(defun ebox-selector--descendant-indexable-p (ast)
  "Return non-nil when AST uses no relationship except descendants."
  (pcase (car-safe ast)
    (:descendant
     (and (ebox-selector--descendant-indexable-p (nth 1 ast))
          (ebox-selector--descendant-indexable-p (nth 2 ast))))
    ((or :child :adjacent :sibling) nil)
    ((or :and :is :where :not)
     (cl-every #'ebox-selector--descendant-indexable-p (cdr ast)))
    (_ t)))

(defun ebox-selector--target-selector (ast)
  "Return the rightmost target selector from relational AST."
  (if (memq (car-safe ast) '(:descendant :child :adjacent :sibling))
      (ebox-selector--target-selector (nth 2 ast))
    ast))

(defun ebox-selector--index-hints (ast)
  "Return indexable id, class, and type hints directly contained by AST."
  (let (id classes type)
    (cl-labels ((visit (selector)
                  (pcase (car-safe selector)
                    (:id (setq id (nth 1 selector)))
                    (:class (push (nth 1 selector) classes))
                    (:type (setq type (nth 1 selector)))
                    (:and (mapc #'visit (cdr selector))))))
      (visit ast))
    (list :id id :classes (nreverse classes) :type type)))

(defun ebox-selector--shortest-candidates (candidate-lists)
  "Return the shortest non-empty list from CANDIDATE-LISTS."
  (car (sort (delq nil candidate-lists)
             (lambda (left right) (< (length left) (length right))))))

(defun ebox-selector--indexed-candidates (buffer ast)
  "Return `(SUPPORTED . ENTRIES)' for AST's indexed target in BUFFER."
  (let* ((hints (ebox-selector--index-hints
                 (ebox-selector--target-selector ast)))
         (id (plist-get hints :id))
         (classes (plist-get hints :classes))
         (type (plist-get hints :type))
         candidates)
    (when id
      (push (gethash id (ebox--buffer-selector-id-table buffer)) candidates))
    (dolist (class classes)
      (push (gethash class (ebox--buffer-selector-class-table buffer))
            candidates))
    (when type
      (push (gethash type (ebox--buffer-selector-type-table buffer))
            candidates))
    (when (or id classes type)
      (cons t (ebox-selector--shortest-candidates candidates)))))

(defun ebox-selector--indexed-entry-matches-p (entry ast)
  "Return non-nil when indexed ENTRY matches TP selector AST."
  (let ((subject
         (if (ebox-selector--relational-p ast)
             (ebox-tree-subject-for-path (cdr entry))
           (ebox-tree-node-subject (car entry)))))
    (tp-selector-match-p ast subject)))

(defun ebox-selector--entries-to-buffer-handles (entries selector buffer)
  "Return selector match handles for ENTRIES annotated with BUFFER."
  (mapcar (lambda (entry)
            (ebox-selector--handle-with-buffer
             (ebox-selector--match-handle
              (car entry) (cdr entry) selector)
             buffer))
          entries))

(defun ebox-selector--query-buffer-index (buffer selector ast)
  "Return `(SUPPORTED . HANDLES)' for an indexed AST query in BUFFER."
  (when (ebox-selector--descendant-indexable-p ast)
    (when-let ((indexed (ebox-selector--indexed-candidates buffer ast)))
      (cons
       t
       (ebox-selector--entries-to-buffer-handles
        (cl-remove-if-not
         (lambda (entry) (ebox-selector--indexed-entry-matches-p entry ast))
         (cdr indexed))
        selector buffer)))))

(defun ebox-selector--query-buffer-tree (root selector ast buffer)
  "Return full semantic tree matches for ROOT, SELECTOR, AST, and BUFFER."
  (mapcar
   (lambda (entry)
     (ebox-selector--handle-with-buffer
      (ebox-selector--subject-entry-handle entry selector) buffer))
   (ebox-selector--matching-subject-entries root ast)))

;;;###autoload
(defun ebox-selector-query-buffer (buffer selector)
  "Return document-ordered selector match handles from BUFFER runtime state.
Selector lookup reads the stored runtime root, not rendered buffer text
properties.  Each returned handle includes `:buffer' in addition to the
tree-query handle fields."
  (let* ((resolved-buffer (ebox-selector--resolve-buffer buffer))
         (root (ebox--buffer-root-node resolved-buffer)))
    (unless root
      (user-error "ebox-selector: buffer has no Ebox runtime state: %S"
                  resolved-buffer))
    (let* ((ast (ebox-selector-parse selector))
           (indexed (ebox-selector--query-buffer-index
                     resolved-buffer selector ast)))
      (if indexed
          (cdr indexed)
        (ebox-selector--query-buffer-tree
         root selector ast resolved-buffer)))))

(defun ebox-selector--skip-handle (handle reason)
  "Return a structured skip entry for HANDLE and REASON."
  (list :node-id (plist-get handle :node-id)
        :reason reason))

(defun ebox-selector--update-region (handle props)
  "Apply PROPS to HANDLE's region through `ebox-region-update'."
  (apply #'ebox-region-update (plist-get handle :region-handle) props))

;;;###autoload
(defun ebox-selector-update-buffer (buffer selector &rest props)
  "Apply PROPS to editable selector matches in BUFFER.
SELECTOR locates runtime nodes, then every editable match is updated through
`ebox-region-update'.  Return a summary plist with match counts, structured
skips, and update reports."
  (unless props
    (user-error "ebox-selector: update requires at least one property"))
  (ebox--with-render-gc
    (let* ((resolved-buffer (ebox-selector--resolve-buffer buffer))
           (matches (ebox-selector-query-buffer resolved-buffer selector))
           editable skipped reports)
      (unless matches
        (user-error "ebox-selector: no matches for %S" selector))
      (dolist (match matches)
        (if (plist-get match :region-handle)
            (push match editable)
          (push (ebox-selector--skip-handle match 'no-region) skipped)))
      (setq editable (nreverse editable)
            skipped (nreverse skipped))
      (cond
       ((null editable)
        (setq reports nil))
       ((= (length editable) 1)
        (setq reports
              (list (ebox-selector--update-region (car editable) props))))
       (t
        (ebox-incremental-begin-batch resolved-buffer)
        (dolist (match editable)
          (ebox-selector--update-region match props))
        (setq reports
              (list (ebox-incremental-flush resolved-buffer)))))
      (list :selector selector
            :matched (length matches)
            :updated (length editable)
            :skipped skipped
            :reports reports))))

(provide 'ebox-selector)

;;; ebox-selector.el ends here
