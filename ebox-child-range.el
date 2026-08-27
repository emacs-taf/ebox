;;; ebox-child-range.el --- Persistent child sequence core -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Immutable weighted segment and key tries for future child Range integration.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (ebox-child-range--metrics
               (:constructor ebox-child-range--make-metrics))
  (segment-visits 0) (segment-copies 0) (ref-index-visits 0)
  (ref-index-copies 0) (key-visits 0) (key-copies 0)
  (collision-visits 0) (collision-copies 0)
  (old-affected-payload-visits 0) (new-payload-validations 0)
  (new-payload-copies 0) (new-payload-visits 0)
  (unaffected-payload-visits 0) (unaffected-payload-validations 0)
  (unaffected-payload-copies 0))

(cl-defstruct (ebox-child-range--segment
               (:constructor ebox-child-range--make-segment))
  ref payload)

(cl-defstruct (ebox-child-range--segment-node
               (:constructor ebox-child-range--make-segment-node))
  children value weight segment-count)

(cl-defstruct (ebox-child-range--hash-node
               (:constructor ebox-child-range--make-hash-node))
  children bucket)

(cl-defstruct (ebox-child-range--sequence
               (:constructor ebox-child-range--make-sequence))
  root height count ref-index key-root hash-function)

(cl-defstruct (ebox-child-range--descriptor
               (:constructor ebox-child-range--make-descriptor))
  ref items)

(defun ebox-child-range--metric-add (metrics slot &optional amount)
  "Increment METRICS SLOT by AMOUNT, defaulting to one."
  (setf (cl-struct-slot-value 'ebox-child-range--metrics slot metrics)
        (+ (or (cl-struct-slot-value 'ebox-child-range--metrics slot metrics) 0)
           (or amount 1))))

(defun ebox-child-range--height (count)
  "Return the base-32 trie height needed for COUNT segments."
  (let ((height 0) (capacity 1))
    (while (> count capacity)
      (setq height (1+ height) capacity (* capacity 32)))
    height))

(defun ebox-child-range--digit (index level)
  "Return INDEX's five-bit digit at LEVEL."
  (logand 31 (ash index (* -5 level))))

(defun ebox-child-range--segment-insert (node height index value)
  "Persistently insert VALUE at INDEX below NODE of HEIGHT."
  (if (= height 0)
      (ebox-child-range--make-segment-node
       :value value :weight (length (ebox-child-range--segment-payload value))
       :segment-count 1)
    (let* ((slot (ebox-child-range--digit index (1- height)))
         (children (copy-sequence
                    (or (and node (ebox-child-range--segment-node-children node))
                        (make-vector 32 nil))))
         (old (aref children slot))
         (new (if (= height 1)
                  (ebox-child-range--make-segment-node
                   :value value :weight (length (ebox-child-range--segment-payload value))
                   :segment-count 1)
                (ebox-child-range--segment-insert old (1- height) index value))))
    (aset children slot new)
    (ebox-child-range--make-segment-node
     :children children
     :weight (cl-loop for child across children when child
                      sum (ebox-child-range--segment-node-weight child))
     :segment-count (cl-loop for child across children when child
                             sum (ebox-child-range--segment-node-segment-count child))))))

(defun ebox-child-range--segment-at (sequence index)
  "Return SEQUENCE segment at INDEX."
  (unless (and (integerp index) (<= 0 index)
               (< index (ebox-child-range--sequence-count sequence)))
    (signal 'args-out-of-range (list index)))
  (let ((node (ebox-child-range--sequence-root sequence))
        (height (ebox-child-range--sequence-height sequence)))
    (while (> height 0)
      (setq node (aref (ebox-child-range--segment-node-children node)
                       (ebox-child-range--digit index (1- height)))
            height (1- height)))
    (ebox-child-range--segment-node-value node)))

(defun ebox-child-range--segment-replace (node height index value metrics)
  "Return `(NEW-NODE . OLD-SEGMENT)' below NODE of HEIGHT at INDEX.
VALUE is the replacement segment and METRICS records all path work."
  (ebox-child-range--metric-add metrics 'segment-visits)
  (ebox-child-range--metric-add metrics 'segment-copies)
  (if (= height 0)
      (cons (ebox-child-range--make-segment-node
             :value value
             :weight (length (ebox-child-range--segment-payload value))
             :segment-count 1)
            (ebox-child-range--segment-node-value node))
    (let* ((slot (ebox-child-range--digit index (1- height)))
         (children (copy-sequence
                    (ebox-child-range--segment-node-children node)))
         (old (aref children slot))
         result new old-segment)
    (if (= height 1)
        (progn
          (ebox-child-range--metric-add metrics 'segment-visits)
          (ebox-child-range--metric-add metrics 'segment-copies)
          (setq old-segment (ebox-child-range--segment-node-value old)
                new (ebox-child-range--make-segment-node
                     :value value
                     :weight (length (ebox-child-range--segment-payload value))
                     :segment-count 1)))
      (setq result (ebox-child-range--segment-replace
                    old (1- height) index value metrics)
            new (car result)
            old-segment (cdr result)))
    (aset children slot new)
    (cons
     (ebox-child-range--make-segment-node
      :children children
      :weight (cl-loop for child across children when child
                       sum (ebox-child-range--segment-node-weight child))
      :segment-count (ebox-child-range--segment-node-segment-count node))
     old-segment))))

(defun ebox-child-range--stable-hash (key)
  "Return KEY's stable unsigned 32-bit hash."
  (logand #xffffffff (sxhash-equal key)))

(defun ebox-child-range--bucket-find (bucket key metrics)
  "Return KEY entry in collision BUCKET and count METRICS comparisons."
  (let (found)
    (while bucket
      (ebox-child-range--metric-add metrics 'collision-visits)
      (when (equal key (caar bucket)) (setq found (car bucket)))
      (setq bucket (cdr bucket)))
    found))

(defun ebox-child-range--hash-change
    (node key value hash depth remove-p metrics)
  "Persistently change KEY in sparse hash NODE using HASH at DEPTH."
  (if (= depth 7)
      (let* ((source (and node (ebox-child-range--hash-node-bucket node)))
             (found (ebox-child-range--bucket-find source key metrics))
             (bucket (copy-sequence source)))
        (ebox-child-range--metric-add metrics 'collision-copies
                                      (length source))
        (cond
         (remove-p
          (ebox-child-range--make-hash-node
           :bucket (cl-delete key bucket :key #'car :test #'equal)))
         (found (error "Ebox child key is not unique: %S" key))
         (t (ebox-child-range--make-hash-node
             :bucket (cons (cons key value) bucket)))))
    (ebox-child-range--metric-add metrics 'key-visits)
    (ebox-child-range--metric-add metrics 'key-copies)
    (let* ((slot (logand 31 (ash hash (* -5 depth))))
           (children (copy-sequence (and node
                                         (ebox-child-range--hash-node-children
                                          node))))
           (old (cdr (assq slot children)))
           (new (ebox-child-range--hash-change
                 old key value hash (1+ depth) remove-p metrics)))
      (setq children (cons (cons slot new) (assq-delete-all slot children)))
      (ebox-child-range--make-hash-node :children children))))

(defun ebox-child-range--hash-lookup (root key hash)
  "Look up KEY with HASH in ROOT."
  (let ((node root) (depth 0))
    (while (< depth 7)
      (setq node (and node
                      (cdr (assq (logand 31 (ash hash (* -5 depth)))
                                 (ebox-child-range--hash-node-children node))))
            depth (1+ depth)))
    (cdr (assoc key (and node (ebox-child-range--hash-node-bucket node))
                #'equal))))

(defun ebox-child-range--item-copy (item metrics &optional retain-identity-p)
  "Validate declarative ITEM while recording METRICS.
Return ITEM itself when RETAIN-IDENTITY-P is non-nil; otherwise return a
shallow copy owned by the persistent sequence."
  (when (ebox-child-range--descriptor-p item)
    (error "Nested child Range descriptors are reserved"))
  (unless (and (listp item) (not (stringp item)))
    (error "Ebox child Range item must be one declarative node"))
  (ebox-child-range--metric-add metrics 'new-payload-validations)
  (ebox-child-range--metric-add metrics 'new-payload-visits)
  (if retain-identity-p
      item
    (ebox-child-range--metric-add metrics 'new-payload-copies)
    (copy-sequence item)))

(defun ebox-child-range--descriptor-create (ref items)
  "Return a reserved Range descriptor for non-nil REF and list ITEMS."
  (unless ref (error "Ebox child Range ref must be non-nil"))
  (unless (proper-list-p items)
    (signal 'wrong-type-argument (list 'proper-list-p items)))
  (ebox-child-range--make-descriptor :ref ref :items items))

(defun ebox-child-range--build
    (segments &optional hash-function retain-item-identities-p)
  "Build an immutable child sequence from SEGMENTS.
Each entry is `(REF . ITEMS)'; nil REF denotes one static child item.
HASH-FUNCTION optionally supplies the stable key hash.  When
RETAIN-ITEM-IDENTITIES-P is non-nil, ITEMS are already-owned canonical nodes
and the sequence retains those exact objects instead of copying them."
  (unless (proper-list-p segments)
    (signal 'wrong-type-argument (list 'proper-list-p segments)))
  (let* ((count (length segments))
         (height (ebox-child-range--height count))
         (hash-function (or hash-function #'ebox-child-range--stable-hash))
         (metrics (ebox-child-range--make-metrics))
         root key-root (refs (make-hash-table :test #'equal)) (index 0))
    (when (zerop count) (error "Ebox child sequence requires a segment"))
    (dolist (entry segments)
      (let* ((ref (car entry))
             (items (cdr entry)))
        (unless (proper-list-p items)
          (signal 'wrong-type-argument (list 'proper-list-p items)))
        (when (and (null ref) (/= (length items) 1))
          (error "Ebox static child segment requires exactly one item"))
        (when (and ref (gethash ref refs))
          (error "Ebox child Range ref is not unique: %S" ref))
        (when ref (puthash ref index refs))
        (let ((payload (vconcat
                        (mapcar (lambda (item)
                                  (ebox-child-range--item-copy
                                   item metrics retain-item-identities-p))
                                items))))
          (setq root (ebox-child-range--segment-insert
                      root height index
                      (ebox-child-range--make-segment :ref ref :payload payload)))
          (dotimes (offset (length payload))
            (let* ((item (aref payload offset)) (key (plist-get item :key)))
              (when key
                (setq key-root
                      (ebox-child-range--hash-change
                       key-root key (cons index offset)
                       (funcall hash-function key) 0 nil metrics)))))))
      (setq index (1+ index)))
    (ebox-child-range--make-sequence
     :root root :height height :count count :ref-index refs
     :key-root key-root :hash-function hash-function)))

(defun ebox-child-range--replace (sequence ref items)
  "Return `(NEW-SEQUENCE . METRICS)' for SEQUENCE after replacing REF ITEMS."
  (ebox-child-range--replace-many sequence (list (cons ref items))))

(defun ebox-child-range--replace-many (sequence replacements &optional reuse-maps)
  "Replace RANGE REPLACEMENTS in SEQUENCE with one two-phase transaction.
REUSE-MAPS is an alist from Range ref to proven `(NEW . OLD)' item indexes;
those NEW items already name canonical published objects and are not copied."
  (let ((metrics (ebox-child-range--make-metrics))
        (missing (make-symbol "missing-range-ref"))
        (seen (make-hash-table :test #'equal)) records)
    (unless (proper-list-p replacements)
      (signal 'wrong-type-argument (list 'proper-list-p replacements)))
    (dolist (entry replacements)
      (unless (proper-list-p (cdr entry))
        (signal 'wrong-type-argument (list 'proper-list-p (cdr entry))))
      (when (gethash (car entry) seen)
        (error "Ebox child Range replacement ref repeats: %S" (car entry)))
      (puthash (car entry) t seen)
      (ebox-child-range--metric-add metrics 'ref-index-visits)
      (let ((index (gethash (car entry)
                            (ebox-child-range--sequence-ref-index sequence)
                            missing)))
        (when (eq index missing)
          (error "Ebox child Range ref does not exist: %S" (car entry)))
        (let ((reuse-map (cdr (assoc (car entry) reuse-maps #'equal))))
          (push (list (car entry) index
                      (vconcat
                       (cl-loop for item in (cdr entry) for offset from 0
                                collect
                                (if (assq offset reuse-map)
                                    item
                                  (ebox-child-range--item-copy item metrics)))))
              records))))
    (setq records (nreverse records))
    (let ((key-root (ebox-child-range--sequence-key-root sequence))
          (hash-function (ebox-child-range--sequence-hash-function sequence))
          (root (ebox-child-range--sequence-root sequence)))
      ;; Each affected ref performs exactly one measured segment path copy;
      ;; the returned old leaf supplies phase-one key removal.
      (setq records
            (mapcar
             (lambda (record)
               (let* ((result
                       (ebox-child-range--segment-replace
                        root (ebox-child-range--sequence-height sequence)
                        (nth 1 record)
                        (ebox-child-range--make-segment
                         :ref (car record) :payload (nth 2 record))
                        metrics)))
                 (setq root (car result))
                 (list (car record) (nth 1 record) (cdr result)
                       (nth 2 record))))
             records))
      (dolist (record records)
        (let ((payload (ebox-child-range--segment-payload (nth 2 record))))
          (dotimes (offset (length payload))
            (ebox-child-range--metric-add metrics 'old-affected-payload-visits)
            (when-let* ((key (plist-get (aref payload offset) :key)))
              (setq key-root
                    (ebox-child-range--hash-change
                     key-root key nil (funcall hash-function key) 0 t metrics))))))
      (dolist (record records)
        (let ((index (nth 1 record)) (payload (nth 3 record)))
          (dotimes (offset (length payload))
            (when-let* ((key (plist-get (aref payload offset) :key)))
              (setq key-root
                    (ebox-child-range--hash-change
                     key-root key (cons index offset)
                     (funcall hash-function key) 0 nil metrics))))))
      (cons (ebox-child-range--make-sequence
             :root root :height (ebox-child-range--sequence-height sequence)
             :count (ebox-child-range--sequence-count sequence)
             :ref-index (ebox-child-range--sequence-ref-index sequence)
             :key-root key-root :hash-function hash-function)
            metrics))))

(defun ebox-child-range--replace-item-at
    (sequence segment-index offset old-item new-item)
  "Persistently replace OLD-ITEM by NEW-ITEM in SEQUENCE.
SEGMENT-INDEX and OFFSET identify its exact material-child location."
  (let* ((segment (ebox-child-range--segment-at sequence segment-index))
         (payload (copy-sequence (ebox-child-range--segment-payload segment)))
         (key-root (ebox-child-range--sequence-key-root sequence))
         (hash-function (ebox-child-range--sequence-hash-function sequence))
         (metrics (ebox-child-range--make-metrics))
         (old-key (plist-get old-item :key))
         (new-key (plist-get new-item :key)))
    (unless (eq (aref payload offset) old-item)
      (error "Ebox child sequence location is stale"))
    (when old-key
      (setq key-root (ebox-child-range--hash-change
                      key-root old-key nil (funcall hash-function old-key)
                      0 t metrics)))
    (when new-key
      (setq key-root (ebox-child-range--hash-change
                      key-root new-key (cons segment-index offset)
                      (funcall hash-function new-key) 0 nil metrics)))
    (aset payload offset new-item)
    (let ((result
           (ebox-child-range--segment-replace
            (ebox-child-range--sequence-root sequence)
            (ebox-child-range--sequence-height sequence) segment-index
            (ebox-child-range--make-segment
             :ref (ebox-child-range--segment-ref segment) :payload payload)
            metrics)))
      (ebox-child-range--make-sequence
       :root (car result) :height (ebox-child-range--sequence-height sequence)
       :count (ebox-child-range--sequence-count sequence)
       :ref-index (ebox-child-range--sequence-ref-index sequence)
       :key-root key-root :hash-function hash-function))))

(defun ebox-child-range--prefix-weight (sequence index)
  "Return flattened item weight before segment INDEX in SEQUENCE."
  (let ((node (ebox-child-range--sequence-root sequence))
        (height (ebox-child-range--sequence-height sequence))
        (weight 0))
    (while (> height 0)
      (let* ((children (ebox-child-range--segment-node-children node))
             (slot (ebox-child-range--digit index (1- height))))
        (dotimes (cursor slot)
          (when-let* ((child (aref children cursor)))
            (setq weight (+ weight
                            (ebox-child-range--segment-node-weight child)))))
        (setq node (aref children slot)
              height (1- height))))
    weight))

(defun ebox-child-range--rank (sequence index)
  "Return the flattened child rank of segment INDEX in SEQUENCE."
  (ebox-child-range--prefix-weight sequence index))

(defun ebox-child-range--lookup-ref (sequence ref)
  "Return SEQUENCE's segment addressed by non-nil REF."
  (let ((missing (make-symbol "missing-range-ref")))
    (let ((index (gethash ref (ebox-child-range--sequence-ref-index sequence)
                          missing)))
      (unless (eq index missing)
        (ebox-child-range--segment-at sequence index)))))

(defun ebox-child-range--range-records (sequence)
  "Return stable `(REF INDEX)' records for SEQUENCE ranges."
  (let (records)
    (dotimes (index (ebox-child-range--sequence-count sequence))
      (let ((segment (ebox-child-range--segment-at sequence index)))
        (when-let* ((ref (ebox-child-range--segment-ref segment)))
          (push (list ref index) records))))
    (nreverse records)))

(defun ebox-child-range--segment-memory (sequence)
  "Return `(NODES . EDGES)' used by SEQUENCE's fixed-vector segment trie."
  (let ((nodes 0) (edges 0))
    (cl-labels ((walk (node)
                  (setq nodes (1+ nodes))
                  (when-let* ((children
                              (ebox-child-range--segment-node-children node)))
                    (dotimes (slot 32)
                      (when-let* ((child (aref children slot)))
                        (setq edges (1+ edges))
                        (walk child))))))
      (walk (ebox-child-range--sequence-root sequence)))
    (cons nodes edges)))

(defun ebox-child-range--segment-vector-memory (sequence)
  "Return `(VECTORS . SLOTS)' allocated by SEQUENCE's segment trie."
  (let ((vectors 0))
    (cl-labels ((walk (node)
                  (when-let* ((children
                              (ebox-child-range--segment-node-children node)))
                    (setq vectors (1+ vectors))
                    (dotimes (slot 32)
                      (when-let* ((child (aref children slot))) (walk child))))))
      (walk (ebox-child-range--sequence-root sequence)))
    (cons vectors (* 32 vectors))))

(defun ebox-child-range--hash-memory (root)
  "Return `(NODES . EDGES)' for sparse persistent hash ROOT."
  (let ((nodes 0) (edges 0))
    (cl-labels ((walk (node)
                  (when node
                    (setq nodes (1+ nodes))
                    (dolist (entry (ebox-child-range--hash-node-children node))
                      (setq edges (1+ edges))
                      (walk (cdr entry))))))
      (walk root))
    (cons nodes edges)))

(defun ebox-child-range--metrics-plist (metrics)
  "Return a read-only plist snapshot of METRICS."
  (list :segment-visits (ebox-child-range--metrics-segment-visits metrics)
        :segment-copies (ebox-child-range--metrics-segment-copies metrics)
        :ref-index-visits (ebox-child-range--metrics-ref-index-visits metrics)
        :ref-index-copies (ebox-child-range--metrics-ref-index-copies metrics)
        :key-visits (ebox-child-range--metrics-key-visits metrics)
        :key-copies (ebox-child-range--metrics-key-copies metrics)
        :collision-visits (ebox-child-range--metrics-collision-visits metrics)
        :collision-copies (ebox-child-range--metrics-collision-copies metrics)
        :old-affected-payload-visits
        (ebox-child-range--metrics-old-affected-payload-visits metrics)
        :new-payload-validations
        (ebox-child-range--metrics-new-payload-validations metrics)
        :new-payload-copies (ebox-child-range--metrics-new-payload-copies metrics)
        :new-payload-visits (ebox-child-range--metrics-new-payload-visits metrics)
        :unaffected-payload-visits
        (ebox-child-range--metrics-unaffected-payload-visits metrics)
        :unaffected-payload-validations
        (ebox-child-range--metrics-unaffected-payload-validations metrics)
        :unaffected-payload-copies
        (ebox-child-range--metrics-unaffected-payload-copies metrics)))

(defun ebox-child-range--fold (sequence function initial)
  "Fold SEQUENCE payloads in stable order with FUNCTION and INITIAL."
  (let ((value initial)
        (index 0))
    (while (< index (ebox-child-range--sequence-count sequence))
      (let ((payload (ebox-child-range--segment-payload
                      (ebox-child-range--segment-at sequence index))))
        (dotimes (offset (length payload))
          (setq value (funcall function value (aref payload offset)))))
      (setq index (1+ index)))
    value))

(defun ebox-child-range--flatten (sequence)
  "Return SEQUENCE's explicit debug-only flat item list."
  (nreverse
   (ebox-child-range--fold
    sequence (lambda (items item) (cons item items)) nil)))

(provide 'ebox-child-range)
;;; ebox-child-range.el ends here
