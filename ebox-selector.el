;;; ebox-selector.el --- CSS-like runtime selectors for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Delegates CSS-like lookup syntax and matching to ECSS, and adapts Ebox
;; trees/runtime indexes to ECSS subjects.  Stable identity remains node ids,
;; region ids, and keys.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ecss-selector)
(require 'ebox-buffer-backend)
(require 'ebox-tree)
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
(declare-function ebox-region-update "ebox" (handle &rest props))
(declare-function ebox-surface-call-with-observation
                  "ebox-surface" (buffer stage function))

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

;;;###autoload
(defun ebox-selector-parse (selector)
  "Compile CSS-like SELECTOR through the ECSS parser."
  (condition-case error-data
      (ecss-selector-parse selector)
    (ecss-invalid-selector
     (user-error "ebox-selector: invalid selector %S: %S"
                 selector (cdr error-data)))))

(defun ebox-selector--node-region-id (node)
  "Return NODE's editable box region id, or nil."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box (ebox--ensure-region-id node))
    ('flex
     (when-let* ((box (plist-get node :box)))
       (ebox--ensure-region-id box)))
    ('grid
     (when-let* ((box (plist-get node :box)))
       (ebox--ensure-region-id box)))
    (_ nil)))

;;;###autoload
(defun ebox-selector-match-node-p (node selector)
  "Return non-nil when NODE matches structured ECSS SELECTOR."
  (ecss-selector-match-p selector (ebox-tree-node-subject node)))

(defun ebox-selector--match-handle (node path selector)
  "Return a selector match handle for NODE on PATH."
  (list :node node
        :node-id (ebox--ensure-node-id node)
        :region-id (ebox-selector--node-region-id node)
        :path path
        :selector selector))

(defun ebox-selector--matching-subject-entries (root ast)
  "Return semantic ROOT entries whose ECSS subjects match AST."
  (cl-remove-if-not
   (lambda (entry)
     (ecss-selector-match-p ast (plist-get entry :subject)))
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
    (:has t)
    ((or :and :list :is :where :not)
     (cl-some #'ebox-selector--relational-p (cdr ast)))
    (_ nil)))

(defun ebox-selector--descendant-indexable-p (ast)
  "Return non-nil when AST uses no relationship except descendants."
  (pcase (car-safe ast)
    (:descendant
     (and (ebox-selector--descendant-indexable-p (nth 1 ast))
          (ebox-selector--descendant-indexable-p (nth 2 ast))))
    ((or :child :adjacent :sibling :has) nil)
    ((or :and :list :is :where :not)
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
      (push (gethash (if (stringp type) (intern type) type)
                     (ebox--buffer-selector-type-table buffer))
            candidates))
    (when (or id classes type)
      (cons t (ebox-selector--shortest-candidates candidates)))))

(defun ebox-selector--indexed-entry-matches-p (entry ast)
  "Return non-nil when indexed ENTRY matches ECSS selector AST."
  (let ((subject
         (if (ebox-selector--relational-p ast)
             (ebox-tree-subject-for-path (cdr entry))
           (ebox-tree-node-subject (car entry)))))
    (ecss-selector-match-p ast subject)))

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
    (when-let* ((indexed (ebox-selector--indexed-candidates buffer ast)))
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
  (let ((resolved-buffer (ebox-selector--resolve-buffer buffer)))
    (ebox-surface-call-with-observation
     resolved-buffer 'selector
     (lambda ()
       (ebox--with-render-gc
         (let ((matches
                (ebox-selector-query-buffer resolved-buffer selector))
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
                   (list (ebox-selector--update-region
                          (car editable) props))))
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
                 :reports reports)))))))

(provide 'ebox-selector)

;;; ebox-selector.el ends here
