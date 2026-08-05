;;; ebox-selector.el --- CSS-like runtime selectors for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns selector parsing and tree/runtime matching.  Selectors are lookup
;; syntax only; stable identity remains node ids, region ids, and keys.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-buffer-backend)
(require 'ebox-tree)

(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--buffer-root-node "ebox-incremental" (buffer))
(declare-function ebox--buffer-selector-id-table "ebox-incremental" (buffer))
(declare-function ebox--buffer-selector-class-table
                  "ebox-incremental" (buffer))
(declare-function ebox--buffer-selector-type-table
                  "ebox-incremental" (buffer))
(declare-function ebox-incremental-begin-batch "ebox-incremental" (buffer))
(declare-function ebox-incremental-flush "ebox-incremental" (buffer))
(declare-function ebox-region-update "ebox" (region-id &rest props))
(defvar ebox--region-update-buffer-hint)

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

(defun ebox-selector--simple-selector (type id classes attrs)
  "Return a normalized simple selector plist."
  (append
   (when type (list :type type))
   (when id (list :id id))
   (when classes (list :classes (nreverse classes)))
   (when attrs (list :attrs (nreverse attrs)))))

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
    (cons (ebox-selector--simple-selector type id classes attrs) pos)))

;;;###autoload
(defun ebox-selector-parse (selector)
  "Parse SELECTOR into a normalized selector AST."
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
         ((= (aref selector pos) ?>)
          (push :child sequence)
          (setq pos (ebox-selector--skip-space selector (1+ pos)))
          (when (>= pos len)
            (user-error "ebox-selector: child combinator has no target in %S"
                        selector)))
         ((> pos before-space)
          (push :descendant sequence))
         (t
          (user-error "ebox-selector: expected combinator at %d in %S"
                      pos selector)))))
    (list :sequence (nreverse sequence))))

(defun ebox-selector--metadata-string (value)
  "Return VALUE normalized to a selector metadata string."
  (cond
   ((null value) nil)
   ((symbolp value) (symbol-name value))
   ((stringp value) value)
   (t (format "%s" value))))

(defun ebox-selector--node-attr (node attr)
  "Return NODE's selector metadata value for ATTR as a string."
  (pcase attr
    (:id (ebox-tree-node-id node))
    (:key (ebox-tree-node-key node))
    (:class nil)
    (_ (and (listp node)
            (ebox-selector--metadata-string (plist-get node attr))))))

;;;###autoload
(defun ebox-selector-match-node-p (node simple-selector)
  "Return non-nil when NODE satisfies SIMPLE-SELECTOR."
  (and (listp node)
       (or (not (plist-member simple-selector :type))
           (eq (plist-get simple-selector :type)
               (ebox-tree-node-selector-type node)))
       (or (not (plist-member simple-selector :id))
           (equal (plist-get simple-selector :id)
                  (ebox-tree-node-id node)))
       (cl-every (lambda (class)
                   (member class (ebox-tree-node-classes node)))
                 (plist-get simple-selector :classes))
       (cl-every (lambda (attr)
                   (equal (cdr attr)
                          (ebox-selector--node-attr node (car attr))))
                 (plist-get simple-selector :attrs))))

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

(defun ebox-selector--match-handle (node path selector)
  "Return a selector match handle for NODE on PATH."
  (list :node node
        :node-id (ebox--ensure-node-id node)
        :region-id (ebox-selector--node-region-id node)
        :path path
        :selector selector))

(defun ebox-selector--walk (node path)
  "Return pre-order entries under NODE.
Each entry is a cons of (NODE . PATH), where PATH is root-to-node."
  (when (and (listp node) (not (stringp node)))
    (let ((current-path (append path (list node))))
      (cons (cons node current-path)
            (apply #'append
                   (mapcar (lambda (child)
                             (ebox-selector--walk child current-path))
                           (ebox-tree-children node)))))))

(defun ebox-selector--layout-leaves (node)
  "Return semantic selector leaves for layout adapter NODE."
  (cond
   ((or (not (listp node)) (stringp node)) nil)
   (t
    (pcase (plist-get node :ebox-type)
      ('concat
       (apply #'append
              (mapcar #'ebox-selector--layout-leaves
                      (ebox--layout-children node))))
      ('stack
       (apply #'append
              (mapcar #'ebox-selector--layout-leaves
                      (ebox--layout-children node))))
      ('flex-item
       (ebox-selector--layout-leaves (plist-get node :node)))
      (_ (list node))))))

(defun ebox-selector--semantic-children (node)
  "Return NODE's selector child candidates.
This hides internal concat/stack adapter nodes behind wrapper boxes so child
selectors match the user's logical layout children."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box
     (if-let ((content-node (plist-get node :ebox-content-node)))
         (ebox-selector--layout-leaves content-node)
       nil))
    ('concat
     (ebox-selector--layout-leaves node))
    ('stack
     (ebox-selector--layout-leaves node))
    ('flex
     (mapcar #'ebox-tree-flex-item-source-node
             (plist-get node :children)))
    ('grid
     (plist-get node :children))
    ('flex-item
     (delq nil (list (plist-get node :node))))
    (_ (ebox-tree-children node))))

(defun ebox-selector--child-entries (entry)
  "Return semantic child entries for ENTRY."
  (let ((path (cdr entry)))
    (mapcar (lambda (child)
              (cons child (append path (list child))))
            (ebox-selector--semantic-children (car entry)))))

(defun ebox-selector--descendant-entries (entry)
  "Return descendant entries below ENTRY, excluding ENTRY itself."
  (apply #'append
         (mapcar (lambda (child)
                   (ebox-selector--walk child (cdr entry)))
                 (ebox-tree-children (car entry)))))

(defun ebox-selector--filter-entries (entries simple-selector)
  "Return ENTRIES whose nodes match SIMPLE-SELECTOR."
  (cl-remove-if-not (lambda (entry)
                      (ebox-selector-match-node-p
                       (car entry) simple-selector))
                    entries))

(defun ebox-selector--run-sequence (root sequence)
  "Return matched entries for selector SEQUENCE under ROOT."
  (let* ((first (car sequence))
         (entries (ebox-selector--filter-entries
                   (ebox-selector--walk root nil)
                   first))
         (rest (cdr sequence)))
    (while rest
      (let ((combinator (pop rest))
            (simple (pop rest)))
        (unless simple
          (user-error "ebox-selector: combinator %S has no target"
                      combinator))
        (setq entries
              (ebox-selector--filter-entries
               (pcase combinator
                 (:child
                  (apply #'append
                         (mapcar #'ebox-selector--child-entries entries)))
                 (:descendant
                  (apply #'append
                         (mapcar #'ebox-selector--descendant-entries
                                 entries)))
                 (_
                  (user-error "ebox-selector: unsupported combinator %S"
                              combinator)))
               simple))))
    entries))

;;;###autoload
(defun ebox-selector-query-all (root selector)
  "Return document-ordered selector match handles under ROOT."
  (let* ((ast (ebox-selector-parse selector))
         (sequence (plist-get ast :sequence)))
    (mapcar (lambda (entry)
              (ebox-selector--match-handle (car entry) (cdr entry) selector))
            (ebox-selector--run-sequence root sequence))))

(defun ebox-selector--resolve-buffer (buffer)
  "Return live buffer object for BUFFER, or signal a user error."
  (let ((resolved (get-buffer buffer)))
    (unless (and resolved (buffer-live-p resolved))
      (user-error "ebox-selector: buffer is not live: %S" buffer))
    resolved))

(defun ebox-selector--handle-with-buffer (handle buffer)
  "Return selector HANDLE annotated with BUFFER ownership."
  (append handle (list :buffer buffer)))

(defun ebox-selector--single-id-simple (sequence)
  "Return the simple selector when SEQUENCE is a single #id candidate."
  (when (and (= (length sequence) 1)
             (plist-member (car sequence) :id))
    (car sequence)))

(defun ebox-selector--candidate-entries-for-simple (buffer simple)
  "Return indexed candidate entries for SIMPLE in BUFFER, or nil."
  (let (candidates)
    (when-let* ((id (plist-get simple :id))
                (table (ebox--buffer-selector-id-table buffer)))
      (push (gethash id table) candidates))
    (when-let ((table (ebox--buffer-selector-class-table buffer)))
      (dolist (class (plist-get simple :classes))
        (push (gethash class table) candidates)))
    (when-let* ((type (plist-get simple :type))
                (table (ebox--buffer-selector-type-table buffer)))
      (push (gethash type table) candidates))
    (when candidates
      (car (sort (cl-remove-if-not #'identity candidates)
                 (lambda (left right)
                   (< (length left) (length right))))))))

(defun ebox-selector--indexed-simple-entries (buffer simple)
  "Return document-ordered indexed entries matching SIMPLE in BUFFER."
  (when-let ((entries (ebox-selector--candidate-entries-for-simple
                       buffer simple)))
    (cl-remove-if-not
     (lambda (entry)
       (ebox-selector-match-node-p (car entry) simple))
     entries)))

(defun ebox-selector--single-simple-sequence-p (sequence)
  "Return non-nil when SEQUENCE is exactly one simple selector."
  (and (= (length sequence) 1)
       (listp (car sequence))))

(defun ebox-selector--descendant-only-sequence-p (sequence)
  "Return non-nil when SEQUENCE only uses descendant combinators."
  (let ((rest (cdr sequence))
        (ok t))
    (while rest
      (unless (and (eq (car rest) :descendant)
                   (listp (cadr rest)))
        (setq ok nil
              rest nil))
      (setq rest (cddr rest)))
    ok))

(defun ebox-selector--sequence-simples (sequence)
  "Return simple selectors from SEQUENCE."
  (cl-remove-if #'keywordp sequence))

(defun ebox-selector--path-matches-descendant-sequence-p (path sequence)
  "Return non-nil when PATH matches descendant-only SEQUENCE."
  (let ((simples (reverse (ebox-selector--sequence-simples sequence)))
        (nodes (reverse path))
        ok)
    (when (and simples nodes
               (ebox-selector-match-node-p (car nodes) (car simples)))
      (setq ok t
            nodes (cdr nodes)
            simples (cdr simples))
      (while (and ok simples)
        (let (found)
          (while (and nodes (not found))
            (if (ebox-selector-match-node-p (car nodes) (car simples))
                (setq found t)
              (setq nodes (cdr nodes))))
          (if found
              (setq nodes (cdr nodes)
                    simples (cdr simples))
            (setq ok nil)))))
    (and ok (null simples))))

(defun ebox-selector--entries-to-buffer-handles (entries selector buffer)
  "Return selector match handles for ENTRIES annotated with BUFFER."
  (mapcar (lambda (entry)
            (ebox-selector--handle-with-buffer
             (ebox-selector--match-handle
              (car entry) (cdr entry) selector)
             buffer))
          entries))

(defun ebox-selector--query-buffer-index
    (buffer selector sequence)
  "Return indexed matches for SEQUENCE in BUFFER, or nil when unsupported."
  (cond
   ((ebox-selector--single-simple-sequence-p sequence)
    (when-let ((entries (ebox-selector--indexed-simple-entries
                         buffer (car sequence))))
      (ebox-selector--entries-to-buffer-handles entries selector buffer)))
   ((ebox-selector--descendant-only-sequence-p sequence)
    (let* ((last-simple (car (last (ebox-selector--sequence-simples
                                    sequence))))
           (entries (ebox-selector--indexed-simple-entries
                     buffer last-simple)))
      (when entries
        (ebox-selector--entries-to-buffer-handles
         (cl-remove-if-not
          (lambda (entry)
            (ebox-selector--path-matches-descendant-sequence-p
             (cdr entry) sequence))
          entries)
         selector buffer))))))

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
           (sequence (plist-get ast :sequence)))
      (or (ebox-selector--query-buffer-index
           resolved-buffer selector sequence)
          (mapcar (lambda (handle)
                    (ebox-selector--handle-with-buffer
                     handle resolved-buffer))
                  (mapcar (lambda (entry)
                            (ebox-selector--match-handle
                             (car entry) (cdr entry) selector))
                          (ebox-selector--run-sequence
                           root sequence)))))))

(defun ebox-selector--skip-handle (handle reason)
  "Return a structured skip entry for HANDLE and REASON."
  (list :node-id (plist-get handle :node-id)
        :reason reason))

(defun ebox-selector--update-region (handle props)
  "Apply PROPS to HANDLE's region through `ebox-region-update'."
  (let* ((region-id (plist-get handle :region-id))
         (ebox--region-update-buffer-hint (plist-get handle :buffer)))
    (apply #'ebox-region-update region-id props)))

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
        (if (plist-get match :region-id)
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
