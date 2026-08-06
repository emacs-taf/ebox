;;; ebox-incremental.el --- Incremental update planner for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns dirty-set construction, patch-set planning, viewport invalidation, and
;; update reports.  It does not own DSL parsing or low-level buffer spans.

;;; Code:

(require 'cl-lib)
(require 'ebox-cache)
(require 'ebox-fragment)
(require 'ebox-flex)
(require 'ebox-tree)
(require 'ebox-buffer-backend)
(require 'ebox-render-context)

(defvar ebox-region-types)
(declare-function ebox--scroll-state-region-ids-containing-node-ids
                  "ebox" (buffer node-ids))
(declare-function ebox--scroll-cache-side-effects-for-region-ids
                  "ebox" (region-id-set))
(declare-function ebox--scroll-cache-actions-replayable-p
                  "ebox" (actions &optional portable))
(declare-function ebox--scroll-cache-actions-portable-p
                  "ebox" (actions))
(declare-function ebox--replay-scroll-cache-actions
                  "ebox" (actions &optional portable))
(declare-function ebox-tree-validate-declarative-root
                  "ebox-tree" (root))
(declare-function ebox-tree-clear-runtime-identities
                  "ebox-tree" (root))
(declare-function ebox-tree-copy-node-structure
                  "ebox-tree" (root))
(declare-function ebox-tree-reconcile-runtime
                  "ebox-tree" (old new))
(declare-function ebox-tree-transfer-runtime-identity
                  "ebox-tree" (old new))
(declare-function ebox-tree-runtime-identity-snapshot
                  "ebox-tree" (root))
(declare-function ebox-surface-region-mounts
                  "ebox-surface" (buffer region-id &optional roles))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-get "ebox" (box key))
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--schedule-buffer-runtime-prewarm
                  "ebox" (buffer))
(declare-function ebox--cancel-buffer-runtime-prewarm
                  "ebox" (buffer))
(declare-function ebox--scroll-clear-state
                  "ebox" (region-id))
(declare-function ebox--scroll-cancel-idle-prefetch
                  "ebox" (region-id))
(declare-function ebox--scroll-schedule-idle-prefetch
                  "ebox" (region-id &optional delay))
(declare-function ebox--scroll-window-rebind-state-producers
                  "ebox-layout" (state box))
(declare-function ebox--smooth-scroll-stop
                  "ebox" (region-id))
(declare-function ebox--node-children
                  "ebox" (node))
(declare-function ebox--root-region-box
                  "ebox" (root region-id))
(declare-function ebox--literal-root-pixel-width
                  "ebox" (box))
(declare-function ebox-put "ebox" (box key value))
(declare-function ebox--confirm-reflow-prewarm-scratch
                  "ebox" (buffer region-id revision))
(declare-function ebox-cache-publish-report
                  "ebox-cache" (buffer report))
(declare-function ebox-cache-snapshot-report
                  "ebox-cache" (buffer))
(declare-function ebox-cache-restore-report
                  "ebox-cache" (buffer snapshot))

(defvar ebox-viewport-width)
(defvar ebox-viewport-height)
(defvar ebox--region-id-counter)
(defvar ebox--runtime-node-id-counter)
(defvar ebox--region-box-table)
(defvar ebox--scroll-global-state)
(defvar ebox--scroll-idle-prefetch-timers)
(defvar ebox--smooth-scroll-state-table)
(defvar ebox--render-region-id)
(defvar ebox--defer-scroll-content-index)
(defvar ebox--flex-content-min-width-table)

;;; Render Cache

(defvar ebox--render-cache-table nil
  "Dynamic buffer-local render cache used during incremental rerenders.")

(defvar ebox--prepared-root-render nil
  "Dynamically bound validated root render for one visible transaction.")

(defvar ebox--collect-rebuilt-scroll-state-region-ids nil
  "Non-nil while one update records scroll states rebuilt by rendering.")

(defvar ebox--rebuilt-scroll-state-region-ids nil
  "Scroll region ids rebuilt in the current recorded render transaction.")

(defvar ebox--render-cache-scroll-state-region-ids nil
  "Dynamically bound set of scroll region ids touched by one cached render.")

(defvar ebox--render-cache-scroll-state-restorable-p t
  "Non-nil when cached scroll state belongs to the live runtime tree.
Isolated prewarming binds this to nil because its prefix renderers capture a
copied tree and must never be published into the live buffer runtime.")

(defvar ebox--render-cache-scroll-state-retained-cost-cache nil
  "Dynamic identity cache for scroll snapshot costs in one root render.")

(defvar ebox-incremental-before-runtime-mutation-hook nil
  "Functions run before an existing buffer runtime is mutated.
Each function receives the target buffer and a mutation kind.  Hooks may
invalidate speculative work, but must not mutate the pending operation's
arguments.")

(defvar ebox-incremental--runtime-mutation-hooks-inhibited-p nil
  "Non-nil while a validated prepared-root transaction owns its mutation.")

(defvar ebox-incremental--declarative-commit-buffer nil
  "Buffer whose declarative root commit currently owns publication.")

(cl-defstruct
    (ebox-candidate
     (:constructor ebox-incremental--make-candidate)
     (:conc-name ebox-candidate--))
  "One-shot logical declarative transaction based on a published runtime."
  buffer
  base-state
  base-root
  base-revision
  base-buffer-tick
  replacements
  sealed-p)

(cl-defstruct
    (ebox-incremental--candidate-replacement
     (:constructor ebox-incremental--make-candidate-replacement)
     (:conc-name ebox-incremental--candidate-replacement-))
  "One logical anchor replacement and its optional semantic transition."
  anchor-id
  subtree
  old-semantic-key
  new-semantic-key)

(cl-defstruct
    (ebox-incremental--detached-history
     (:constructor ebox-incremental--make-detached-history)
     (:conc-name ebox-incremental--detached-history-))
  "One buffer-owned bounded detached runtime identity history."
  table
  order
  node-count)

(defvar ebox-incremental--candidate-proof-node-table nil
  "Dynamic `(BUFFER . TABLE)' for proof-local owner subtree copies.")

(defvar ebox-incremental--candidate-base-state nil
  "Dynamic `(BUFFER . STATE)' holding proof-time published runtime nodes.")

(defvar ebox-incremental--candidate-path-copy-trace nil
  "Dynamic hash table receiving logical candidate path-copy facts.
Each key is a base anchor node id.  Values describe the final copied node,
its candidate parent, whether it is a replacement anchor, and whether a
direct child runtime id changed.  The trace lets index preparation skip every
untouched sibling without exposing paths outside Ebox.")

(defvar ebox-incremental--candidate-path-copy-origin-table nil
  "Dynamic current-node-id to base-origin-id map for candidate path copies.
Type-changing ancestor replacements receive fresh runtime ids.  Later
descendant refinements still use those fresh ids while copying their path, so
this transaction-local map keeps every successive copy recorded under the
original published identity.  Candidate-only nodes with no base origin map to
themselves.")

(defvar ebox-incremental--after-declarative-publication nil
  "Internal callback run inside declarative publication's quit-free boundary.

Framework adapters may dynamically bind this to a one-argument, pointer-only
promotion function receiving the candidate update report.  It must not call
user code or signal after mutation.")

(defun ebox-incremental--notify-before-runtime-mutation (buffer kind)
  "Notify speculative consumers before BUFFER runtime mutation KIND."
  (unless ebox-incremental--runtime-mutation-hooks-inhibited-p
    (run-hook-with-args
     'ebox-incremental-before-runtime-mutation-hook buffer kind)))

(defvar ebox--buffer-render-state-table)
(defvar ebox-surface--buffer-surface)

(declare-function tp-surface-client-state "tp-surface" (surface))
(declare-function tp-surface-live-p "tp-surface" (surface))

(defvar ebox-render-cache-max-entries 2048
  "Maximum persistent render cache entries retained per buffer.
The public customization is declared by the `ebox' facade after internal
modules have loaded.")

(defvar ebox-render-cache-max-bytes (* 32 1024 1024)
  "Approximate persistent render cache byte budget per buffer.
The public customization is declared by the `ebox' facade after internal
modules have loaded.")

(defvar ebox-render-root-cache-max-entries 16
  "Maximum complete root render outputs retained per buffer.
The public customization is declared by the `ebox' facade after internal
modules have loaded.")

(defvar ebox-render-root-cache-max-bytes (* 8 1024 1024)
  "Approximate complete root render output budget per buffer.
The public customization is declared by the `ebox' facade after internal
modules have loaded.")

(defvar ebox-incremental--detached-history-entry-limit 16
  "Maximum semantic subtree identities retained per buffer.")

(defvar ebox-incremental--detached-history-node-limit 8192
  "Maximum identity skeleton nodes retained per buffer.")

(defvar ebox--render-cache-ring-table
  (make-hash-table :test 'eq :weakness 'key)
  "Weak map from render cache tables to fixed-capacity eviction rings.")

(defvar ebox--render-root-cache-table-table
  (make-hash-table :test 'eq :weakness 'key)
  "Weak map from subtree caches to their bounded complete-root caches.")

(defvar ebox--render-cache-entry-side-effects-table
  (make-hash-table :test 'eq :weakness 'key)
  "Weak cache-entry map for render-time scroll state side effects.")

(defvar ebox--render-cache-signature-cache nil
  "Dynamic render-pass cache for recursive render signatures.")

(defvar ebox--scroll-prefetch-delay-override nil)
(defvar ebox--scroll-window-initial-lookahead-lines-override nil)

(defvar ebox--root-reflow-gc-deferred-p nil
  "Non-nil while an outer root reflow already defers garbage collection.")

(defvar ebox--prepared-root-defer-index-refresh nil
  "Prepared animation index policy.
Nil uses ordinary root refresh, `incremental' splices exact Rust patch spans,
and any other non-nil value defers broad indexes for a display-only frame.")

(defconst ebox--root-reflow-scroll-lookahead-lines 13
  "Lazy scroll lines retained by latency-sensitive root reflows.
The scroll window already renders one completion sentinel, so this leaves a
14-line published runway; an immediate exact-prefix extension fills the rest
of a default smooth-wheel step without rebuilding the rendered prefix.")

(defconst ebox--latency-sensitive-scroll-node-limit 512
  "Runtime size above which lazy scroll rows stay strictly demand-driven.
Large indexed runtimes can hide a composite flex subtree behind one logical
scroll line.  Bounding work by requested lines alone is therefore insufficient
unless root reflow and idle prefetch also avoid crossing several such rows.")

(defun ebox--buffer-latency-sensitive-scroll-prefix-p (buffer)
  "Return non-nil when BUFFER's lazy scroll rows need atomic scheduling."
  ;; A logical candidate may deliberately defer rebuilding selector paths
  ;; until the first selector query.  Scroll policy needs only the retained
  ;; runtime type membership and must not turn proof rendering into a
  ;; logical-tree selector-index rebuild.
  (let* ((state (ebox--buffer-render-state buffer))
         (type-counts (plist-get state :runtime-type-count-table))
         (node-table (plist-get state :node-table)))
    (or (plist-get state :selector-index-stale-p)
        (and (hash-table-p type-counts)
             (> (or (gethash 'item type-counts) 0) 0))
        (and (hash-table-p node-table)
             (>= (hash-table-count node-table)
                 ebox--latency-sensitive-scroll-node-limit)))))

(defun ebox--root-reflow-scroll-lookahead-lines-for-buffer (buffer)
  "Return the root-reflow lazy scroll runway for BUFFER.
Explicit flex items and large runtimes can render an expensive composite row
for one requested line.  Keep those rows demand-driven; other sources retain
the short runway that makes immediate post-resize smooth scrolling cheap."
  (if (ebox--buffer-latency-sensitive-scroll-prefix-p buffer)
      0
    ebox--root-reflow-scroll-lookahead-lines))

(defvar ebox--viewport-dependent-node-ids-cache nil
  "Dynamic render-pass cache for viewport dependency discovery.")

(defvar ebox--viewport-dependent-subtree-cache nil
  "Dynamic render-pass cache for viewport dependency existence checks.")

(defvar ebox--viewport-height-dependent-subtree-cache nil
  "Dynamic render-pass cache for viewport-height dependency checks.")

(defvar ebox--render-cache-allow-viewport-dependent nil
  "Non-nil allows caching viewport-dependent nodes for the current context.")

(defun ebox--render-cache-contained-viewport-node-p (node)
  "Return non-nil when NODE bounds descendant viewport-dependent layout."
  (and (eq (and (listp node) (plist-get node :ebox-type)) 'box)
       (ebox--span-patch-definite-size-value-p (ebox-get node :width))))

(defun ebox--render-cacheable-node-p (node)
  "Return non-nil when NODE can reuse rendered output in the current context."
  (and ebox--render-cache-table
       (listp node)
       (not (stringp node))
       (plist-get node :ebox-type)
       (or ebox--render-cache-allow-viewport-dependent
           (not (ebox--viewport-dependent-subtree-p node))
           (ebox--render-cache-contained-viewport-node-p node))))

(defun ebox--render-cacheable-box-p (node)
  "Return non-nil when NODE is a cacheable box.
Kept as a narrow predicate for callers that need box-only sizing semantics."
  (and (eq (and (listp node) (plist-get node :ebox-type)) 'box)
       (ebox--render-cacheable-node-p node)))

(defun ebox--render-cache-value-signature (value)
  "Return VALUE normalized for render cache signatures."
  (cond
   ((and (listp value)
         (not (stringp value))
         (plist-get value :ebox-type))
    (ebox--render-cache-node-body-signature value))
   ((consp value)
    (cons (ebox--render-cache-value-signature (car value))
          (ebox--render-cache-value-signature (cdr value))))
   (t value)))

(defun ebox--render-cache-plist-signature (node)
  "Return NODE's render-relevant plist signature."
  (let ((plist node)
        signature)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (unless (memq key '(:render-cache :surface-object))
          (push key signature)
          (push (ebox--render-cache-value-signature value) signature))))
    (nreverse signature)))

(defun ebox--render-cache-node-body-signature (node)
  "Return NODE's recursive body signature, memoized within a render pass."
  (if (not (and ebox--render-cache-signature-cache
                (listp node)
                (not (stringp node))))
      (ebox--render-cache-plist-signature node)
    (let* ((missing (make-symbol "ebox-render-signature-missing"))
           (cached (gethash node ebox--render-cache-signature-cache
                            missing)))
      (if (not (eq cached missing))
          cached
        (puthash node
                 (ebox--render-cache-plist-signature node)
                 ebox--render-cache-signature-cache)))))

(defun ebox--render-cache-node-signature (node)
  "Return a cache signature for NODE render output."
  (list (ebox--current-display-signature)
        (when (and (ebox--viewport-dependent-subtree-p node)
                   (not (ebox--render-cache-contained-viewport-node-p
                         node)))
          ebox-viewport-width)
        (when (ebox--viewport-height-dependent-subtree-p node)
          ebox-viewport-height)
        (ebox--render-cache-node-body-signature node)))

(defun ebox--render-cache-box-signature (box)
  "Return a cache signature for BOX render output."
  (ebox--render-cache-node-signature box))

(defsubst ebox--render-cache-effective-key (cache-key signature)
  "Return CACHE-KEY namespaced by the complete render SIGNATURE.
The complete signature keeps distinct values in one `sxhash-equal' bucket."
  (list cache-key signature))

(defun ebox--render-cache-retained-cost (object &optional limit)
  "Return a conservative retained-byte estimate for OBJECT up to LIMIT.
Rendered Ebox strings encode most geometry in text-property intervals rather
than character bytes.  Charging every character as one possible interval keeps
the estimate cheap enough for cache misses while bounding those hidden values.
When LIMIT is non-nil, stop once the estimate exceeds it; callers only need to
know that an oversized value cannot be retained."
  (let ((seen (make-hash-table :test 'eq))
        (stack (list object))
        (total 0))
    (while (and stack
                (or (null limit) (<= total limit)))
      (let ((current (pop stack)))
        (unless (or (null current)
                    (numberp current)
                    (symbolp current)
                    (gethash current seen))
          (puthash current t seen)
          (cond
           ((stringp current)
            (cl-incf total (+ 64 (string-bytes current)
                               (* 128 (length current)))))
           ((consp current)
            (cl-incf total 16)
            (push (car current) stack)
            (push (cdr current) stack))
           ((vectorp current)
            (cl-incf total (+ 32 (* 8 (length current))))
            (dotimes (index (length current))
              (push (aref current index) stack)))
           ((hash-table-p current)
            (cl-incf total 64)
            (maphash (lambda (key value)
                       (push key stack)
                       (push value stack))
                     current))))))
    total))

(defun ebox--render-cache-side-effect-string-cost (string)
  "Return retained bytes for one scroll metadata STRING.
The snapshot owns line strings separately from the cached output.  Charge a
bounded property-bearing character estimate without walking each interval;
doing so here would put cache accounting itself on the resize hot path."
  (+ 64 (string-bytes string) (* 16 (length string))))

(defun ebox--render-cache-side-effects-retained-cost
    (metadata &optional limit)
  "Return bounded retained bytes for scroll side-effect METADATA.
Live boxes are already owned by the runtime and renderer closures capture that
same tree, so this charges them shallowly.  Snapshot line strings and their
text-property interval spines are charged exactly once by identity."
  (let ((seen (make-hash-table :test 'eq))
        (total 64))
    (cl-labels
        ((room-p () (or (null limit) (<= total limit)))
         (charge-lines (lines)
           (while (and lines (room-p))
             (cl-incf total 16)
             (let ((line (pop lines)))
               (when (and (stringp line) (not (gethash line seen)))
                 (puthash line t seen)
                 (cl-incf total
                          (ebox--render-cache-side-effect-string-cost
                           line)))))))
      (dolist (action (plist-get metadata :scroll-actions))
        (when (room-p)
          (cl-incf total 48)
          (when (eq (car action) 'set)
            (let ((template (nth 2 action)))
              (cl-incf total (* 16 (length template)))
              (charge-lines (plist-get template :content-lines))
              (charge-lines (plist-get template :rendered-content-lines))
              (when (plist-get template :render-content-prefix)
                (cl-incf total 512))
              (when (plist-get template :materialize-content-lines)
                (cl-incf total 256)))))))
    total))

(defun ebox--render-cache-entry-retained-cost (entry &optional limit)
  "Return retained bytes for ENTRY's value and metadata, up to LIMIT."
  (let* ((rendered-cost
          (ebox--render-cache-retained-cost (cdr entry) limit))
         (metadata
          (gethash entry ebox--render-cache-entry-side-effects-table)))
    (if (or (null metadata)
            (and limit (> rendered-cost limit)))
        rendered-cost
      (+ rendered-cost
         (or (plist-get metadata :retained-cost)
             (ebox--render-cache-side-effects-retained-cost
              metadata (and limit (max 0 (- limit rendered-cost)))))))))

(defsubst ebox--render-cache-entry-limit ()
  "Return the positive configured render cache entry limit."
  (max 1 ebox-render-cache-max-entries))

(defsubst ebox--render-cache-byte-limit ()
  "Return the positive configured render cache byte limit."
  (max 1 ebox-render-cache-max-bytes))

(defsubst ebox--render-cache-ring-reset (ring entry-limit byte-limit)
  "Reset RING metadata for ENTRY-LIMIT and BYTE-LIMIT."
  (aset ring 0 (make-vector entry-limit nil))
  (aset ring 1 (make-vector entry-limit 0))
  (aset ring 2 0)
  (aset ring 3 0)
  (aset ring 4 entry-limit)
  (aset ring 5 0)
  (aset ring 6 byte-limit))

(defsubst ebox--render-cache-ring-evict-oldest (ring)
  "Evict and forget RING's oldest entry."
  (when (> (aref ring 3) 0)
    (let* ((keys (aref ring 0))
           (costs (aref ring 1))
           (start (aref ring 2))
           (cost (aref costs start))
           (effective-key (aref keys start))
           (entry (gethash effective-key ebox--render-cache-table)))
      (remhash effective-key ebox--render-cache-table)
      (when entry
        (remhash entry ebox--render-cache-entry-side-effects-table))
      (aset keys start nil)
      (aset costs start 0)
      (aset ring 2 (% (1+ start) (aref ring 4)))
      (aset ring 3 (1- (aref ring 3)))
      (aset ring 5 (max 0 (- (aref ring 5) cost))))))

(defsubst ebox--render-cache-ring-enforce-byte-limit (ring)
  "Evict oldest RING entries until its byte budget is satisfied."
  (while (and (> (aref ring 3) 0)
              (> (aref ring 5) (aref ring 6)))
    (ebox--render-cache-ring-evict-oldest ring)))

(defsubst ebox--render-cache-ring-append (ring effective-key cost)
  "Append EFFECTIVE-KEY with retained COST to cache eviction RING."
  (when (= (aref ring 3) (aref ring 4))
    (ebox--render-cache-ring-evict-oldest ring))
  (let* ((keys (aref ring 0))
         (costs (aref ring 1))
         (index (% (+ (aref ring 2) (aref ring 3)) (aref ring 4))))
    (aset keys index effective-key)
    (aset costs index cost)
    (aset ring 3 (1+ (aref ring 3)))
    (aset ring 5 (+ (aref ring 5) cost)))
  (ebox--render-cache-ring-enforce-byte-limit ring))

(defun ebox--render-cache-ring ()
  "Return eviction ring owned by the current render cache table."
  (or (gethash ebox--render-cache-table ebox--render-cache-ring-table)
      (let* ((entry-limit (ebox--render-cache-entry-limit))
             (byte-limit (ebox--render-cache-byte-limit))
             (ring (vector (make-vector entry-limit nil)
                           (make-vector entry-limit 0)
                           0 0 entry-limit 0 byte-limit)))
        (puthash ebox--render-cache-table ring ebox--render-cache-ring-table)
        ring)))

(defun ebox--render-cache-ring-rebuild (ring entry-limit byte-limit)
  "Rebuild RING from the current cache with ENTRY-LIMIT and BYTE-LIMIT.
This is reserved for exceptional private mutations that bypass cache stores."
  (let (entries)
    (maphash (lambda (key entry)
               (push (cons key
                           (ebox--render-cache-entry-retained-cost
                            entry byte-limit))
                     entries))
             ebox--render-cache-table)
    (ebox--render-cache-ring-reset ring entry-limit byte-limit)
    (dolist (entry (nreverse entries))
      (when (gethash (car entry) ebox--render-cache-table)
        (ebox--render-cache-ring-append ring (car entry) (cdr entry))))))

(defun ebox--render-cache-ring-resize (ring entry-limit byte-limit)
  "Resize RING while retaining its newest entries within both limits."
  (let ((old-keys (aref ring 0))
        (old-costs (aref ring 1))
        (old-start (aref ring 2))
        (old-count (aref ring 3))
        (old-limit (aref ring 4))
        entries)
    (dotimes (offset old-count)
      (let ((index (% (+ old-start offset) old-limit)))
        (push (cons (aref old-keys index) (aref old-costs index)) entries)))
    (ebox--render-cache-ring-reset ring entry-limit byte-limit)
    (dolist (entry (nreverse entries))
      (when (gethash (car entry) ebox--render-cache-table)
        (ebox--render-cache-ring-append ring (car entry) (cdr entry))))))

(defun ebox--render-cache-ring-update-cost (ring effective-key cost)
  "Update EFFECTIVE-KEY retained COST in RING, rebuilding if it is absent."
  (let ((keys (aref ring 0))
        (costs (aref ring 1))
        (start (aref ring 2))
        (count (aref ring 3))
        (limit (aref ring 4))
        found)
    (dotimes (offset count)
      (let ((index (% (+ start offset) limit)))
        (when (equal (aref keys index) effective-key)
          (aset ring 5 (+ (aref ring 5) (- cost (aref costs index))))
          (aset costs index cost)
          (setq found t))))
    (if found
        (ebox--render-cache-ring-enforce-byte-limit ring)
      (ebox--render-cache-ring-rebuild
       ring (ebox--render-cache-entry-limit) (ebox--render-cache-byte-limit)))))

(defun ebox--render-cache-ring-sync (ring)
  "Synchronize RING with the current render cache table.
This normally does no work.  It rebuilds metadata only after a defensive
`clrhash' or another exceptional private cache mutation."
  (let ((entry-limit (ebox--render-cache-entry-limit))
        (byte-limit (ebox--render-cache-byte-limit)))
    (cond
     ((/= (aref ring 3) (hash-table-count ebox--render-cache-table))
      (ebox--render-cache-ring-rebuild ring entry-limit byte-limit))
     ((or (/= (aref ring 4) entry-limit)
          (/= (aref ring 6) byte-limit))
      (ebox--render-cache-ring-resize ring entry-limit byte-limit)))))

(defun ebox--render-cache-lookup-entry (cache-key signature)
  "Return the raw cache entry for CACHE-KEY matching SIGNATURE."
  (let ((entry (gethash (ebox--render-cache-effective-key
                         cache-key signature)
                        ebox--render-cache-table)))
    (and entry
         (equal-including-properties (car entry) signature)
         entry)))

(defun ebox--render-cache-lookup (cache-key signature)
  "Return cached render output for CACHE-KEY matching SIGNATURE."
  (let ((entry (ebox--render-cache-lookup-entry cache-key signature)))
    (if (and entry
             (equal-including-properties (car entry) signature))
        (prog1 (cdr entry)
          (when ebox-cache-report-buffer
            (ebox-cache-record-hit ebox-cache-report-buffer 'render-body)))
      (when ebox-cache-report-buffer
        (ebox-cache-record-miss ebox-cache-report-buffer 'render-body))
      nil)))

(defun ebox--render-cache-store
    (cache-key signature rendered &optional side-effects)
  "Store RENDERED for CACHE-KEY and SIGNATURE with SIDE-EFFECTS metadata."
  (let* ((effective-key
          (ebox--render-cache-effective-key cache-key signature))
         (old-entry (gethash effective-key ebox--render-cache-table))
         (new-entry-p
          (null old-entry))
         (ring (ebox--render-cache-ring))
         (entry (cons signature rendered)))
    (ebox--render-cache-ring-sync ring)
    (when old-entry
      (remhash old-entry ebox--render-cache-entry-side-effects-table))
    (puthash effective-key entry ebox--render-cache-table)
    (when side-effects
      (puthash entry side-effects ebox--render-cache-entry-side-effects-table))
    (let ((cost (ebox--render-cache-entry-retained-cost entry (aref ring 6))))
      (cond
       ((> cost (aref ring 6))
        ;; The budget contract: an oversized value stays renderable for
        ;; this caller but is never retained.  Appending it first would
        ;; make byte enforcement evict every healthy older entry before
        ;; discarding the oversized entry itself.
        (remhash effective-key ebox--render-cache-table)
        (remhash entry ebox--render-cache-entry-side-effects-table)
        (unless new-entry-p
          (ebox--render-cache-ring-rebuild
           ring (ebox--render-cache-entry-limit)
           (ebox--render-cache-byte-limit))))
       (new-entry-p
        (ebox--render-cache-ring-append ring effective-key cost))
       (t
        (ebox--render-cache-ring-update-cost ring effective-key cost)))))
  rendered)

(defun ebox--render-cache-scroll-actions-stateful-p (actions)
  "Return non-nil when ACTIONS contain a scroll state installation."
  (cl-some (lambda (action) (eq (car action) 'set)) actions))

(defun ebox--render-cache-entry-reusable-p (entry)
  "Return non-nil when ENTRY can safely replay in the current render tree."
  (let ((metadata
         (gethash entry ebox--render-cache-entry-side-effects-table)))
    (or (null metadata)
        (not (plist-get metadata :stateful-p))
        (and (plist-get metadata :restorable-p)
             (or ebox--render-cache-scroll-state-restorable-p
                 (plist-get metadata :portable-p))
             (ebox--scroll-cache-actions-replayable-p
              (plist-get metadata :scroll-actions)
              (plist-get metadata :portable-p))))))

(defun ebox--render-cache-replay-entry-side-effects (entry)
  "Replay ENTRY's scroll side effects before its rendered output is reused."
  (when-let ((metadata
              (gethash entry ebox--render-cache-entry-side-effects-table)))
    (ebox--replay-scroll-cache-actions
     (plist-get metadata :scroll-actions)
     (plist-get metadata :portable-p))))

(defun ebox--render-cache-merge-scroll-region-ids (source target)
  "Merge scroll region ids from SOURCE hash table into TARGET."
  (when (and (hash-table-p source) (hash-table-p target))
    (maphash (lambda (region-id _)
               (puthash region-id t target))
             source)))

(defun ebox--render-cache-render-with-scroll-actions (node)
  "Render NODE and return its output plus complete scroll side effects."
  (let ((parent-region-ids ebox--render-cache-scroll-state-region-ids)
        (region-ids (make-hash-table :test 'equal))
        (ebox--render-cache-scroll-state-retained-cost-cache
         (or ebox--render-cache-scroll-state-retained-cost-cache
             (make-hash-table :test 'eq)))
        rendered)
    (let ((ebox--render-cache-scroll-state-region-ids region-ids))
      (setq rendered (ebox-render node)))
    (ebox--render-cache-merge-scroll-region-ids
     region-ids parent-region-ids)
    (list rendered
          (ebox--scroll-cache-side-effects-for-region-ids region-ids))))

(defun ebox--render-root-cache-table (subtree-cache)
  "Return the bounded complete-root cache paired with SUBTREE-CACHE."
  (or (gethash subtree-cache ebox--render-root-cache-table-table)
      (let ((root-cache (make-hash-table :test 'equal)))
        (puthash subtree-cache root-cache ebox--render-root-cache-table-table)
        root-cache)))

(defun ebox--prepared-root-render-matches-p (node prepared)
  "Return non-nil when PREPARED is exact for NODE's current transaction."
  (let* ((state (gethash (current-buffer) ebox--buffer-render-state-table))
         (kind (plist-get prepared :kind))
         (region-id (plist-get prepared :region-id)))
    (and state
         (eq state (plist-get prepared :render-state))
         (eq node (plist-get state :root-node))
         (equal (ebox--ensure-node-id node)
                (plist-get prepared :node-id))
         (equal (plist-get state :runtime-revision)
                (plist-get prepared :runtime-revision))
         (equal (ebox--current-display-signature)
                (plist-get prepared :display-signature))
         (equal (plist-get state :viewport-width)
                (plist-get prepared :viewport-width))
         (equal (plist-get state :viewport-height)
                (plist-get prepared :viewport-height))
         (or (stringp (plist-get prepared :rendered))
             (plist-get (plist-get prepared :native-patch) :native-patch))
         (pcase kind
           ('viewport t)
           ('root-width
            (when-let ((box (ebox--root-region-box node region-id)))
              (equal (ebox--literal-root-pixel-width box)
                     (plist-get prepared :root-width))))
           (_ nil)))))

(defun ebox--take-prepared-root-render (node)
  "Consume and return a validated dynamic root render for NODE."
  (when (and ebox--prepared-root-render
             (stringp (plist-get ebox--prepared-root-render :rendered)))
    (let ((prepared ebox--prepared-root-render))
      (setq ebox--prepared-root-render nil)
      (when (ebox--prepared-root-render-matches-p node prepared)
        (plist-put prepared :consumed-p t)
        (plist-get prepared :rendered)))))


(defun ebox--render-cache-context-signature
    (node force &optional external-signature)
  "Return NODE's render signature for FORCE and EXTERNAL-SIGNATURE."
  (let ((signature
         (if (not force)
             (ebox--render-cache-node-signature node)
           (let ((ebox--viewport-dependent-node-ids-cache
                  (make-hash-table :test 'eq))
                 (ebox--viewport-dependent-subtree-cache
                  (make-hash-table :test 'eq))
                 (ebox--viewport-height-dependent-subtree-cache
                  (make-hash-table :test 'eq)))
             (ebox--render-cache-node-signature node)))))
    (if external-signature
        (list signature external-signature)
      signature)))

(defun ebox--render-cache-context
    (node force &optional external-signature)
  "Return exact cache context for NODE, FORCE, and EXTERNAL-SIGNATURE."
  (when (or (and (or force external-signature) ebox--render-cache-table)
            (ebox--render-cacheable-node-p node))
    (let* ((subtree-cache ebox--render-cache-table)
           (root-cache-p (and force t)))
      (list
       :cache-key (list (ebox--ensure-node-id node) 'natural)
       :signature
       (ebox--render-cache-context-signature
        node force external-signature)
       :cache (if root-cache-p
                  (ebox--render-root-cache-table subtree-cache)
                subtree-cache)
       :entry-limit (if root-cache-p
                        ebox-render-root-cache-max-entries
                      ebox-render-cache-max-entries)
       :byte-limit (if root-cache-p
                       ebox-render-root-cache-max-bytes
                     ebox-render-cache-max-bytes)))))

(defun ebox--render-cache-probe
    (node &optional force external-signature)
  "Return NODE's exact cache context, with `:rendered' when reusable.
FORCE includes the complete viewport context in the cache signature.
EXTERNAL-SIGNATURE may prove a viewport-dependent non-root context."
  (when-let ((context
              (ebox--render-cache-context
               node force external-signature)))
    (let* ((ebox--render-cache-table (plist-get context :cache))
           (entry
            (ebox--render-cache-lookup-entry
             (plist-get context :cache-key)
             (plist-get context :signature))))
      (if (and entry (ebox--render-cache-entry-reusable-p entry))
          (progn
            (when ebox-cache-report-buffer
              (ebox-cache-record-hit ebox-cache-report-buffer 'render-body))
            (ebox--render-cache-replay-entry-side-effects entry)
            (ebox--flex-recache-source-boxes node)
            (plist-put context :rendered (cdr entry)))
        (when ebox-cache-report-buffer
          (ebox-cache-record-miss ebox-cache-report-buffer 'render-body))
        context))))

(defun ebox--render-cache-store-context
    (context rendered &optional metadata)
  "Store RENDERED with METADATA in exact cache CONTEXT."
  (let ((ebox--render-cache-table (plist-get context :cache))
        (ebox-render-cache-max-entries (plist-get context :entry-limit))
        (ebox-render-cache-max-bytes (plist-get context :byte-limit)))
    (ebox--render-cache-store
     (plist-get context :cache-key)
     (plist-get context :signature)
     rendered metadata)))

(defun ebox--render-with-cache (node &optional force cache-probe)
  "Render NODE, reusing stable subtree output inside buffer render contexts.
When FORCE is non-nil, cache NODE even when its output is viewport-dependent;
the complete viewport context remains part of the render signature.
CACHE-PROBE may supply a prior exact miss from an accelerator boundary."
  (if-let ((prepared (and force
                          (ebox--take-prepared-root-render node))))
      (prog1 prepared
        (ebox--flex-recache-source-boxes node))
    (let ((probe (or cache-probe
                     (ebox--render-cache-probe node force))))
      (cond
       ((null probe)
        (ebox-render node))
       ((plist-member probe :rendered)
        (plist-get probe :rendered))
       (t
        (pcase-let* ((`(,rendered ,side-effects)
                       (ebox--render-cache-render-with-scroll-actions node))
                     (actions (plist-get side-effects :scroll-actions))
                     (stateful-p
                      (ebox--render-cache-scroll-actions-stateful-p actions))
                     (portable-p
                      (and stateful-p
                           (not ebox--render-cache-scroll-state-restorable-p)
                           (ebox--scroll-cache-actions-portable-p actions)))
                     (metadata
                      (append
                       side-effects
                       (list :stateful-p stateful-p
                             :portable-p portable-p
                             :restorable-p
                             (or ebox--render-cache-scroll-state-restorable-p
                                 portable-p)))))
          ;; An isolated copy may still warm pure descendant entries, but a
          ;; cached node that created scroll state owns closures over that
          ;; copy and cannot safely cross into the live runtime.
          (unless (and stateful-p
                       (not (or ebox--render-cache-scroll-state-restorable-p
                                portable-p)))
            (ebox--render-cache-store-context probe rendered metadata))
          rendered))))))

;;; Buffer Runtime State

(defvar ebox--buffer-render-state-table (make-hash-table :test 'eq)
  "Maps buffer objects to render state plists.
Each state contains :root-node, viewport dimensions, and derived layout
snapshots so every incremental rerender can use the same layout context as the
original buffer render.")

(defvar ebox-incremental--buffer-render-state-override nil
  "Dynamically bound `(BUFFER . STATE)' used while preparing a candidate.")

(defvar ebox-incremental--batch-table (make-hash-table :test 'eq)
  "Buffer-keyed explicit incremental batch state.")

(defvar ebox-incremental--after-successful-batch-flush-hook nil
  "Functions called after a non-empty explicit batch flush succeeds.
Each function receives BUFFER, the original PENDING entries, and the final
update REPORT.")

(defvar ebox--scroll-global-state (make-hash-table :test 'equal)
  "Global hash table storing scroll state.
Keys are region-id, values are plists with :scroll-offset, :content-lines, etc.")

(defun ebox--buffer-render-state (buffer)
  "Return render state for BUFFER."
  (if (and ebox-incremental--buffer-render-state-override
           (eq buffer
               (car ebox-incremental--buffer-render-state-override)))
      (cdr ebox-incremental--buffer-render-state-override)
    (let ((surface
           (and (buffer-live-p buffer)
                (boundp 'ebox-surface--buffer-surface)
                (with-current-buffer buffer
                  ebox-surface--buffer-surface))))
      (if (and surface (tp-surface-live-p surface))
          (tp-surface-client-state surface)
        (gethash buffer ebox--buffer-render-state-table)))))

(defun ebox--buffer-update-report (buffer)
  "Return the update report stored in BUFFER's render state."
  (plist-get (ebox--buffer-render-state buffer) :last-update-report))

(defun ebox--set-buffer-update-report (buffer report)
  "Store REPORT in BUFFER's render state and return REPORT."
  (let ((state (ebox--buffer-render-state buffer)))
    (unless state
      (error "Ebox cannot store an update report without render state: %S"
             buffer))
    (plist-put state :last-update-report report)
    report))

(defun ebox--buffer-root-node (buffer)
  "Return the render root node stored for BUFFER."
  (plist-get (ebox--buffer-render-state buffer) :root-node))

(defun ebox--buffer-root-node-id (buffer)
  "Return BUFFER's root runtime node id."
  (when-let ((root (ebox--buffer-root-node buffer)))
    (ebox--ensure-node-id root)))

(defun ebox--runtime-region-id-conflict (region-id-set target-buffer)
  "Return `(REGION-ID . BUFFER)' for REGION-ID-SET outside TARGET-BUFFER."
  (ebox--prune-dead-buffer-render-states)
  (let ((target (and target-buffer (get-buffer target-buffer))))
    (catch 'conflict
      (maphash
       (lambda (buffer state)
         (unless (eq buffer target)
           (when-let ((owner-set (plist-get state :region-id-set)))
             (maphash
              (lambda (region-id _present)
                (when (gethash region-id owner-set)
                  (throw 'conflict (cons region-id buffer))))
              region-id-set))))
       ebox--buffer-render-state-table)
      nil)))


(defun ebox-incremental--adjust-runtime-type-count (table node delta)
  "Adjust NODE's raw selector-type count in TABLE by DELTA."
  (when-let ((type (ebox-tree-node-selector-type node)))
    (let ((count (+ (or (gethash type table) 0) delta)))
      (cond
       ((< count 0)
        (error "Ebox runtime type count became negative: %S" type))
       ((= count 0) (remhash type table))
       (t (puthash type count table))))))

(defun ebox--runtime-index (root-node &optional collect-region-boxes)
  "Return persistent runtime indexes for ROOT-NODE.
When COLLECT-REGION-BOXES is non-nil, collect `:region-box-table' during the
same traversal in complete-render overwrite order."
  (let ((node-table (make-hash-table :test 'equal))
        (parent-table (make-hash-table :test 'equal))
        (region-id-set (make-hash-table :test 'equal))
        (region-node-table (make-hash-table :test 'equal))
        (region-box-table
         (and collect-region-boxes (make-hash-table :test 'equal)))
        (region-box-count-table (make-hash-table :test 'equal))
        (host-ref-table (make-hash-table :test 'equal))
        (runtime-type-count-table (make-hash-table :test 'eq))
        native-node-postorder)
    (cl-labels ((index-host-ref (node node-id)
                  (when-let ((host-ref (plist-get node :host-ref)))
                    (let ((count (hash-table-count host-ref-table)))
                      (puthash host-ref node-id host-ref-table)
                      (when (= count (hash-table-count host-ref-table))
                        (error
                         "Ebox declarative tree uses duplicate host ref %S"
                         host-ref)))))
                (index-region-id (node node-id)
                  (pcase (plist-get node :ebox-type)
                    ('box
                     (let ((region-id (ebox--ensure-region-id node)))
                       (puthash region-id t region-id-set)
                       (puthash region-id
                                (1+ (or (gethash region-id
                                                 region-box-count-table)
                                        0))
                                region-box-count-table)
                       ;; A flex wrapper is visited after its flex owner.  Keep
                       ;; that earlier render-owner mapping instead of
                       ;; replacing it with the non-renderable source box.
                       (unless (gethash region-id region-node-table)
                         (puthash region-id node-id region-node-table))))
                    ('flex
                     (when-let ((box (plist-get node :box)))
                       (let ((region-id (ebox--ensure-region-id box)))
                         (puthash region-id t region-id-set)
                         ;; Preserve the recursive lookup's first-match
                         ;; semantics when malformed trees reuse a region id.
                         (unless (gethash region-id region-node-table)
                           (puthash region-id node-id
                                    region-node-table)))))))
                (index-region-box (node)
                  ;; Box rendering records region ownership after rendering
                  ;; child content.  Preserve that postorder overwrite order
                  ;; so duplicate legacy ids resolve exactly as they do after
                  ;; a complete render, including flex container wrappers.
                  (when region-box-table
                    (pcase (plist-get node :ebox-type)
                      ('box
                       (puthash (ebox--ensure-region-id node)
                                node region-box-table))
                      ('flex
                       (when-let ((box (plist-get node :box)))
                         (puthash (ebox--ensure-region-id box)
                                  box region-box-table))))))
                (visit (node parent-id native-layout-p)
                  (when (and (listp node)
                             (not (stringp node)))
                    (let ((node-id (ebox--ensure-node-id node))
                          (type (plist-get node :ebox-type)))
                      (puthash node-id node node-table)
                      (ebox-incremental--adjust-runtime-type-count
                       runtime-type-count-table node 1)
                      (when parent-id
                        (puthash node-id parent-id parent-table))
                      (index-region-id node node-id)
                      (index-host-ref node node-id)
                      (dolist (child (ebox--node-children node))
                        (visit
                         child node-id
                         (and native-layout-p
                              (not (and (eq type 'flex)
                                        (eq child (plist-get node :box)))))))
                      (index-region-box node)
                      ;; This is the same child-before-parent order used by
                      ;; the recursive Layout IR compiler.  Flex wrapper
                      ;; source boxes and `flex-item' metadata nodes are not
                      ;; independent native nodes, so retain their runtime
                      ;; indexes without adding duplicate compiler work.
                      (when (and native-layout-p
                                 (not (eq type 'flex-item)))
                        (push node native-node-postorder))))))
      (visit root-node nil t))
    (let ((selector-index (ebox-tree-selector-index root-node)))
      (list :node-table node-table
            :parent-table parent-table
            :region-id-set region-id-set
            :region-node-table region-node-table
            :region-box-table region-box-table
            :region-box-count-table region-box-count-table
            :host-ref-table host-ref-table
            :selector-id-table (plist-get selector-index :selector-id-table)
            :selector-class-table
            (plist-get selector-index :selector-class-table)
            :selector-type-table
            (plist-get selector-index :selector-type-table)
            :runtime-type-count-table runtime-type-count-table
            :native-node-postorder
            (vconcat (nreverse native-node-postorder))))))

(defun ebox-incremental--ensure-buffer-selector-indexes (buffer)
  "Return BUFFER's state after materializing deferred selector indexes."
  (let ((state (ebox--buffer-render-state buffer)))
    (when (and state (plist-get state :selector-index-stale-p))
      (let ((index (ebox-tree-selector-index
                    (plist-get state :root-node))))
        (dolist (key '(:selector-id-table
                       :selector-class-table
                       :selector-type-table))
          (plist-put state key (plist-get index key)))
        (plist-put state :selector-index-stale-p nil)))
    state))

(defun ebox--new-buffer-render-state (root-node)
  "Return fresh buffer-independent runtime state for ROOT-NODE."
  (list :root-node root-node
        :viewport-width ebox-viewport-width
        :viewport-height ebox-viewport-height
        :display-signature (ebox--current-display-signature)
        :layout-snapshots (make-hash-table :test 'equal)
        :layout-snapshots-complete-p nil
        :layout-snapshot-detail-generation 0
        :runtime-revision 0 :last-update-report nil
        :render-cache (make-hash-table :test 'equal)
        :detached-identity-history
        (ebox-incremental--make-detached-history
         :table (make-hash-table :test 'equal)
         :order nil :node-count 0)
        :render-signature-cache (make-hash-table :test 'eq)
        :flex-content-min-widths (make-hash-table :test 'eq)
        :viewport-height-dependent-subtree-cache
        (make-hash-table :test 'eq)))

(defun ebox--render-state-install-index (state index)
  "Install runtime INDEX tables into candidate STATE and return STATE."
  (dolist (key '(:node-table :parent-table :region-id-set :region-node-table
                 :region-box-count-table :region-box-table :host-ref-table
                 :selector-id-table :selector-class-table
                 :selector-type-table :runtime-type-count-table
                 :native-node-postorder))
    (setq state (plist-put state key (plist-get index key))))
  state)

(defun ebox--make-buffer-render-state (root-node)
  "Return unpublished complete runtime state for ROOT-NODE."
  (ebox--render-state-install-index
   (ebox--new-buffer-render-state root-node)
   (ebox--runtime-index root-node t)))

(defun ebox--set-buffer-render-state (buffer root-node)
  "Store ROOT-NODE and current render context for BUFFER."
  (puthash buffer (ebox--make-buffer-render-state root-node)
           ebox--buffer-render-state-table)
  (ebox--buffer-viewport-dependent-node-id-axes buffer))

(defun ebox--buffer-node-table (buffer)
  "Return BUFFER's runtime node table."
  (plist-get (ebox--buffer-render-state buffer) :node-table))

(defun ebox--buffer-parent-table (buffer)
  "Return BUFFER's runtime parent table."
  (plist-get (ebox--buffer-render-state buffer) :parent-table))

(defun ebox--buffer-region-id-set (buffer)
  "Return BUFFER's runtime region id set."
  (plist-get (ebox--buffer-render-state buffer) :region-id-set))

(defun ebox--buffer-region-node-table (buffer)
  "Return BUFFER's region id to render-owner node id table."
  (plist-get (ebox--buffer-render-state buffer) :region-node-table))

(defun ebox--buffer-region-box-table (buffer)
  "Return BUFFER's region id to runtime box table."
  (plist-get (ebox--buffer-render-state buffer) :region-box-table))

(defun ebox--buffer-host-ref-table (buffer)
  "Return BUFFER's opaque host reference to runtime node id table."
  (plist-get (ebox--buffer-render-state buffer) :host-ref-table))

(defun ebox--buffer-region-render-owner-node-id (buffer region-id)
  "Return REGION-ID's smallest render-owner node id in BUFFER.
Use the persistent runtime index when available.  Legacy runtime states that
lack the index, or an indexed entry, fall back to a recursive tree lookup."
  (or (when-let ((table (ebox--buffer-region-node-table buffer)))
        (gethash region-id table))
      (when-let* ((root (ebox--buffer-root-node buffer))
                  (path (ebox--node-path-to-region root region-id)))
        (ebox--ensure-node-id (car path)))))

(defun ebox--buffer-region-render-owner-node (buffer region-id)
  "Return REGION-ID's smallest render-owner node in BUFFER.
Use both persistent runtime indexes in the normal path.  Fall back to the
recursive region path only for legacy or incomplete runtime state."
  (when-let ((node-id
              (ebox--buffer-region-render-owner-node-id buffer region-id)))
    (ebox--buffer-runtime-node buffer node-id)))

(defun ebox--buffer-selector-id-table (buffer)
  "Return BUFFER's runtime selector id index."
  (plist-get (ebox-incremental--ensure-buffer-selector-indexes buffer)
             :selector-id-table))

(defun ebox--buffer-selector-class-table (buffer)
  "Return BUFFER's runtime selector class index."
  (plist-get (ebox-incremental--ensure-buffer-selector-indexes buffer)
             :selector-class-table))

(defun ebox--buffer-selector-type-table (buffer)
  "Return BUFFER's runtime selector type index."
  (plist-get (ebox-incremental--ensure-buffer-selector-indexes buffer)
             :selector-type-table))

(defun ebox--buffer-render-cache (buffer)
  "Return BUFFER's persistent render cache table."
  (plist-get (ebox--buffer-render-state buffer) :render-cache))

(defun ebox--buffer-viewport-height-subtree-cache (buffer)
  "Return BUFFER's persistent viewport-height subtree cache."
  (plist-get (ebox--buffer-render-state buffer)
             :viewport-height-dependent-subtree-cache))

(defun ebox--bump-buffer-runtime-revision
    (buffer &optional preserve-reflow-prewarm-scratch)
  "Increment and return BUFFER's runtime mutation revision.
Discard the isolated reflow scratch tree unless
PRESERVE-REFLOW-PREWARM-SCRATCH is non-nil.  Callers may preserve it only
while validating one predicted root-width mutation against the new revision."
  (when-let ((state (ebox--buffer-render-state buffer)))
    (let ((revision
           (1+ (or (plist-get state :runtime-revision) 0))))
      (plist-put state :runtime-revision revision)
      (unless preserve-reflow-prewarm-scratch
        (plist-put state :reflow-prewarm-scratch nil))
      revision)))

(defun ebox--buffer-viewport-dependent-node-id-axes (buffer)
  "Return cached viewport-dependent node ids by axis for BUFFER."
  (when-let ((state (ebox--buffer-render-state buffer)))
    (if (and (plist-get state :viewport-dependent-node-ids-ready)
             (plist-member state :viewport-dependent-node-id-axes))
        (plist-get state :viewport-dependent-node-id-axes)
      (let* ((root (plist-get state :root-node))
             (axes (and root
                        (let ((ebox--viewport-dependent-node-ids-cache
                               (make-hash-table :test 'eq))
                              (ebox--viewport-height-dependent-subtree-cache
                               (or (ebox--buffer-viewport-height-subtree-cache
                                    buffer)
                                   (make-hash-table :test 'eq))))
                          (ebox--viewport-dependent-node-id-axes root)))))
        (plist-put state :viewport-dependent-node-id-axes axes)
        (plist-put state :viewport-dependent-node-ids
                   (and axes
                        (delete-dups
                         (copy-sequence
                          (append (car axes) (cdr axes))))))
        (plist-put state :viewport-dependent-node-ids-ready t)
        axes))))

(defun ebox--buffer-viewport-dependent-node-ids (buffer)
  "Return cached viewport-dependent node ids for BUFFER."
  (when-let ((state (ebox--buffer-render-state buffer)))
    (ebox--buffer-viewport-dependent-node-id-axes buffer)
    (plist-get state :viewport-dependent-node-ids)))

(defun ebox--invalidate-buffer-viewport-dependencies (buffer)
  "Invalidate BUFFER's cached viewport dependency list."
  (when-let ((state (ebox--buffer-render-state buffer)))
    (plist-put state :viewport-dependent-node-ids nil)
    (plist-put state :viewport-dependent-node-id-axes nil)
    (plist-put state :viewport-dependent-node-ids-ready nil)))

(defun ebox--ensure-buffer-layout-snapshots (buffer)
  "Return BUFFER's layout snapshot table, creating it when needed."
  (let ((state (ebox--buffer-render-state buffer)))
    (when state
      (or (plist-get state :layout-snapshots)
          (let ((snapshots (make-hash-table :test 'equal)))
            (plist-put state :layout-snapshots snapshots)
            snapshots)))))

(defconst ebox--layout-snapshot-detail-keys
  '(:buffer-span :buffer-spans :line-signature
    :span-footprint-signature :external-footprint-signature
    :parent-slot-signature :role-topology-signature
    :overflow-signature :detail-generation)
  "Expensive layout snapshot detail keys that depend on current buffer spans.")

(defun ebox--buffer-layout-snapshot-detail-generation (buffer)
  "Return BUFFER's current layout snapshot detail generation."
  (or (plist-get (ebox--buffer-render-state buffer)
                 :layout-snapshot-detail-generation)
      0))

(defun ebox--layout-snapshot-details-current-p (buffer snapshot)
  "Return non-nil when SNAPSHOT's buffer-dependent detail fields are current."
  (or (not (cl-some (lambda (key) (plist-member snapshot key))
                    ebox--layout-snapshot-detail-keys))
      (= (or (plist-get snapshot :detail-generation) -1)
         (ebox--buffer-layout-snapshot-detail-generation buffer))))

(defun ebox--layout-snapshot (buffer node-id)
  "Return BUFFER's layout snapshot for NODE-ID."
  (when-let ((snapshots (ebox--ensure-buffer-layout-snapshots buffer)))
    (let ((snapshot (or (gethash node-id snapshots)
                        (when-let ((node (ebox--snapshot-published-node
                                          buffer node-id)))
                          (let ((created
                                 (ebox--node-layout-snapshot
                                  buffer node nil)))
                            (puthash node-id created snapshots)
                            created)))))
      (when snapshot
        (if (ebox--layout-snapshot-details-current-p buffer snapshot)
            snapshot
          (let ((stripped (ebox--layout-snapshot-strip-details snapshot)))
            (puthash node-id stripped snapshots)
            stripped))))))

(defvar ebox--region-line-index nil
  "Dynamic snapshot-detail-local line/region index.
This is an optimization for completing snapshot details, not persistent state.")

(defvar ebox--region-line-index-buffer nil
  "Dynamic snapshot-detail-local buffer used when a line index is available.")

(defmacro ebox--with-layout-snapshot-detail-context (buffer &rest body)
  "Evaluate BODY with shared node caches for BUFFER snapshot detail capture.
This context is intentionally lazy and does not build a full region-line index.
Use `ebox--with-layout-snapshot-index-context' for batch snapshot capture."
  (declare (indent 1) (debug t))
  (let ((snapshot-buffer (make-symbol "snapshot-buffer")))
    `(let ((,snapshot-buffer ,buffer))
       (let ((ebox--region-line-index
              ebox--region-line-index)
             (ebox--region-line-index-buffer
              (or ebox--region-line-index-buffer ,snapshot-buffer))
             (ebox--node-region-ids-cache
              (or ebox--node-region-ids-cache
                  (make-hash-table :test 'eq))))
         ,@body))))

(defmacro ebox--with-layout-snapshot-index-context (buffer &rest body)
  "Evaluate BODY with shared node caches and an eager line index for BUFFER."
  (declare (indent 1) (debug t))
  (let ((snapshot-buffer (make-symbol "snapshot-buffer")))
    `(let ((,snapshot-buffer ,buffer))
       (let ((ebox--region-line-index
              (or ebox--region-line-index
                  (and (buffer-live-p ,snapshot-buffer)
                       (with-current-buffer ,snapshot-buffer
                         (ebox--build-region-line-index)))))
             (ebox--region-line-index-buffer ,snapshot-buffer)
             (ebox--node-region-ids-cache
              (or ebox--node-region-ids-cache
                  (make-hash-table :test 'eq))))
         ,@body))))

(defun ebox--current-layout-snapshots (buffer &optional details)
  "Return a copy of BUFFER's current layout snapshot table.
When DETAILS is non-nil, include derived buffer spans and line signatures in
the returned copy without mutating BUFFER's stored snapshot table."
  (when-let ((state (ebox--buffer-render-state buffer)))
    (when (and (plist-get state :root-node)
               (not (plist-get state :layout-snapshots-complete-p)))
      (ebox--refresh-buffer-layout-snapshots buffer details)))
  (let ((copy (make-hash-table :test 'equal)))
    (when-let ((snapshots (ebox--ensure-buffer-layout-snapshots buffer)))
      (let (entries)
        (maphash (lambda (node-id snapshot)
                   (push (cons node-id
                               (if (ebox--layout-snapshot-details-current-p
                                    buffer snapshot)
                                   snapshot
                                 (ebox--layout-snapshot-strip-details
                                  snapshot)))
                         entries))
                 snapshots)
        (if details
            (ebox--with-layout-snapshot-index-context buffer
              (dolist (entry entries)
                (let* ((node-id (car entry))
                       (snapshot (cdr entry))
                       (node (ebox--buffer-runtime-node buffer node-id)))
                  (puthash node-id
                           (if node
                               (ebox--complete-layout-snapshot
                                buffer node snapshot t)
                             (copy-sequence snapshot))
                           copy))))
          (dolist (entry entries)
            (puthash (car entry)
                     (copy-sequence (cdr entry))
                     copy)))))
    copy))

(defun ebox--put-layout-snapshot (buffer node-id snapshot)
  "Store SNAPSHOT for NODE-ID in BUFFER render state."
  (puthash node-id snapshot (ebox--ensure-buffer-layout-snapshots buffer)))

(defun ebox--clear-layout-snapshots (buffer)
  "Clear BUFFER's layout snapshots."
  (when-let ((state (ebox--buffer-render-state buffer)))
    (plist-put state :layout-snapshots-complete-p nil))
  (when-let ((snapshots (ebox--ensure-buffer-layout-snapshots buffer)))
    (clrhash snapshots)))

(defun ebox--plist-remove-key (plist key)
  "Return PLIST without KEY and its value."
  (let (result)
    (while plist
      (let ((current-key (pop plist))
            (value (pop plist)))
        (unless (eq current-key key)
          (push current-key result)
          (push value result))))
    (nreverse result)))

(defun ebox--layout-snapshot-strip-details (snapshot)
  "Return SNAPSHOT with stale buffer-dependent detail fields removed."
  (let ((result (copy-sequence snapshot)))
    (dolist (key ebox--layout-snapshot-detail-keys result)
      (setq result (ebox--plist-remove-key result key)))))

(defun ebox--clear-buffer-render-state (&optional buffer)
  "Remove stored buffer-owned runtime state for BUFFER.
Defaults to the current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (when-let ((cache (ebox--buffer-render-cache buffer)))
      (when-let ((root-cache
                  (gethash cache ebox--render-root-cache-table-table)))
        (remhash root-cache ebox--render-cache-ring-table))
      (remhash cache ebox--render-root-cache-table-table)
      (remhash cache ebox--render-cache-ring-table))
    (remhash buffer ebox--buffer-render-state-table)
    (remhash buffer ebox-incremental--batch-table)
    (ebox-cache-discard-report buffer)))

;;; Runtime Buffer Lookup

(defun ebox--prune-dead-buffer-render-states ()
  "Remove killed buffers from buffer-owned runtime tables."
  (let (dead-buffers)
    (maphash
     (lambda (buffer _state)
       (unless (buffer-live-p buffer)
         (push buffer dead-buffers)))
     ebox--buffer-render-state-table)
    (dolist (buffer dead-buffers)
      (ebox--clear-buffer-render-state buffer))))

;;; Snapshot Dirty Patch Runtime

(defun ebox--region-id-set (region-ids)
  "Return a hash set for REGION-IDS."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (region-id region-ids)
      (puthash region-id t set))
    set))

(defun ebox--pos-region-ids (pos)
  "Return all ebox region ids present at POS."
  (let (ids)
    (dolist (region-id (get-text-property pos 'ebox-content-owners))
      (cl-pushnew region-id ids :test #'equal))
    (dolist (entry ebox-region-types)
      (when-let ((region-id (get-text-property pos (cdr entry))))
        (cl-pushnew region-id ids :test #'equal)))
    ids))

(defun ebox--pos-region-role-ids (pos)
  "Return all ebox region role/id pairs present at POS."
  (let (role-ids)
    (dolist (entry ebox-region-types)
      (when-let ((region-id (get-text-property pos (cdr entry))))
        (push (cons (car entry) region-id) role-ids)))
    role-ids))

(defun ebox--next-region-property-change (pos limit)
  "Return the next ebox region property change after POS, capped at LIMIT."
  (let ((next limit))
    (dolist (entry ebox-region-types)
      (let ((change (next-single-property-change
                     pos (cdr entry) nil limit)))
        (when (< change next)
          (setq next change))))
    next))

(defun ebox--index-add-region-line-range
    (region-lines region-id line-number start end)
  "Record REGION-ID ownership from START to END on LINE-NUMBER."
  (let ((line-map (or (gethash region-id region-lines)
                      (let ((map (make-hash-table :test 'eql)))
                        (puthash region-id map region-lines)
                        map))))
    (if-let ((range (gethash line-number line-map)))
        (setcdr range (max (cdr range) end))
      (puthash line-number (cons start end) line-map))))

(defun ebox--build-region-line-index ()
  "Return a per-line index of ebox region ownership in the current buffer."
  (let ((region-lines (make-hash-table :test 'equal))
        (line-number 0)
        lines)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((line-end (line-end-position))
              segments)
          (let ((pos (point)))
            (while (< pos line-end)
              (let* ((role-ids (ebox--pos-region-role-ids pos))
                     (ids (delete-dups
                           (mapcar #'cdr (copy-sequence role-ids))))
                     (next (ebox--next-region-property-change
                            pos line-end)))
                (when ids
                  (push (list :start pos :end next
                              :ids ids :role-ids role-ids)
                        segments))
                (setq pos (max next (1+ pos))))))
          (setq segments (nreverse segments))
          (dolist (segment segments)
            (dolist (region-id (plist-get segment :ids))
              (ebox--index-add-region-line-range
               region-lines region-id line-number
               (plist-get segment :start)
               (plist-get segment :end))))
          (push (list :segments segments) lines))
        (setq line-number (1+ line-number))
        (forward-line 1)))
    (list :lines (vconcat (nreverse lines))
          :region-lines region-lines)))

(defun ebox--build-region-line-index-for-spans (spans)
  "Return a dense region ownership index limited to current buffer SPANS."
  (let ((region-lines (make-hash-table :test 'equal))
        (line-number 0)
        lines)
    (save-excursion
      (dolist (span spans)
        (let ((end (cdr span)))
          (goto-char (car span))
          (while (< (point) end)
            (let ((line-end (min (line-end-position) end))
                  segments)
              (let ((pos (point)))
                (while (< pos line-end)
                  (let* ((role-ids (ebox--pos-region-role-ids pos))
                         (ids (delete-dups
                               (mapcar #'cdr (copy-sequence role-ids))))
                         (next (ebox--next-region-property-change
                                pos line-end)))
                    (when ids
                      (push (list :start pos :end next
                                  :ids ids :role-ids role-ids)
                            segments))
                    (setq pos (max next (1+ pos))))))
              (setq segments (nreverse segments))
              (dolist (segment segments)
                (dolist (region-id (plist-get segment :ids))
                  (ebox--index-add-region-line-range
                   region-lines region-id line-number
                   (plist-get segment :start)
                   (plist-get segment :end))))
              (push (list :segments segments) lines)
              (setq line-number (1+ line-number)))
            (forward-line 1)))))
    (list :lines (vconcat (nreverse lines))
          :region-lines region-lines)))

(defun ebox--region-id-member-p (region-id region-set)
  "Return non-nil when REGION-ID belongs to REGION-SET."
  (gethash region-id region-set))

(defun ebox--region-ids-subset-p (region-ids region-set)
  "Return non-nil when every REGION-IDS entry belongs to REGION-SET."
  (cl-every (lambda (region-id)
              (ebox--region-id-member-p region-id region-set))
            region-ids))

(defun ebox--region-role-ids-compatible-p (role-ids region-set)
  "Return non-nil when ROLE-IDS do not contain foreign blocking owners.
Wrapper and decoration roles may enclose a child patch span.  A foreign direct
`content' owner means the candidate span crosses another editable box and is
therefore unsafe."
  (cl-every (lambda (role-id)
              (or (not (eq (car role-id) 'content))
                  (ebox--region-id-member-p (cdr role-id) region-set)))
            role-ids))

(defun ebox--segment-overlaps-span-p (segment start end)
  "Return non-nil when SEGMENT overlaps START..END."
  (and (< (plist-get segment :start) end)
       (> (plist-get segment :end) start)))

(defun ebox--region-set-line-spans-from-index (region-ids index)
  "Return per-line spans for REGION-IDS using precomputed INDEX."
  (let ((region-set (ebox--region-id-set region-ids))
        (lines (plist-get index :lines))
        (region-lines (plist-get index :region-lines))
        (candidate-lines (make-hash-table :test 'eql))
        spans)
    (dolist (region-id region-ids)
      (when-let ((line-map (gethash region-id region-lines)))
        (maphash
         (lambda (line-number range)
           (if-let ((existing (gethash line-number candidate-lines)))
               (progn
                 (setcar existing (min (car existing) (car range)))
                 (setcdr existing (max (cdr existing) (cdr range))))
             (puthash line-number (copy-tree range) candidate-lines)))
         line-map)))
    (dolist (line-number
             (sort (let (keys)
                     (maphash (lambda (key _value)
                                (push key keys))
                              candidate-lines)
                     keys)
                   #'<))
      (let* ((span (gethash line-number candidate-lines))
             (span-start (car span))
             (span-end (cdr span))
             (segments (plist-get (aref lines line-number) :segments))
             (patchable t))
        (dolist (segment segments)
          (when (and patchable
                     (ebox--segment-overlaps-span-p
                      segment span-start span-end)
                     (not (ebox--region-role-ids-compatible-p
                           (or (plist-get segment :role-ids)
                               (mapcar (lambda (region-id)
                                         (cons 'content region-id))
                                       (plist-get segment :ids)))
                           region-set)))
            (setq patchable nil)))
        (when patchable
          (push (cons span-start span-end) spans))))
    (nreverse spans)))

(defun ebox--add-role-span-line-ranges (line-ranges span)
  "Add per-line coverage from SPAN to LINE-RANGES."
  (save-excursion
    (let ((end (cdr span)))
      (goto-char (car span))
      (while (< (point) end)
        (let* ((line-start (line-beginning-position))
               (line-end (line-end-position))
               (range-start (max (point) line-start))
               (range-end (min end line-end)))
          (when (< range-start range-end)
            (if-let ((existing (gethash line-start line-ranges)))
                (progn
                  (setcar existing (min (car existing) range-start))
                  (setcdr existing (max (cdr existing) range-end)))
              (puthash line-start (cons range-start range-end)
                       line-ranges)))
          (forward-line 1))))))

(defun ebox--role-compatible-span-p (span region-set)
  "Return non-nil when SPAN does not cross foreign content owners."
  (let ((pos (car span))
        (end (cdr span))
        (compatible t))
    (while (and compatible (< pos end))
      (let ((next (or (next-single-property-change
                       pos 'ebox-content nil end)
                      end))
            (content-owner (get-text-property pos 'ebox-content)))
        (when (and content-owner
                   (not (ebox--region-id-member-p
                         content-owner region-set)))
          (setq compatible nil))
        (setq pos (max next (1+ pos)))))
    compatible))

(defun ebox--region-set-line-spans-from-mounts (region-ids)
  "Return per-line spans for REGION-IDS using TP-owned mounts."
  (let ((region-set (ebox--region-id-set region-ids))
        (line-ranges (make-hash-table :test 'eql))
        spans)
    (dolist (region-id region-ids)
      (dolist (mount
               (ebox-surface-region-mounts
                (current-buffer) region-id (mapcar #'car ebox-region-types)))
        (ebox--add-role-span-line-ranges
         line-ranges
         (cons (plist-get mount :start) (plist-get mount :end)))))
    (dolist (line-start
             (sort (let (keys)
                     (maphash (lambda (key _value)
                                (push key keys))
                              line-ranges)
                     keys)
                   #'<))
      (let ((span (gethash line-start line-ranges)))
        (when (ebox--role-compatible-span-p span region-set)
          (push (copy-tree span) spans))))
    (nreverse spans)))

(defun ebox--region-set-line-spans (region-ids)
  "Return patchable per-line spans owned by REGION-IDS.
If a line span would cross a foreign ebox region, return nil."
  (if ebox--region-line-index
      (ebox--region-set-line-spans-from-index
       region-ids ebox--region-line-index)
    (ebox--region-set-line-spans-from-mounts region-ids)))

(defun ebox--spans-line-signature (spans)
  "Return pixel-width signature for current buffer SPANS."
  (mapcar (lambda (span)
            (ebox--string-pixel-width
             (buffer-substring (car span) (cdr span))))
          spans))

(defun ebox--rendered-line-signature (rendered)
  "Return pixel-width signature for RENDERED."
  (mapcar #'ebox--string-pixel-width (ebox-string-lines rendered)))

(defun ebox--safe-max-number (numbers)
  "Return the maximum number in NUMBERS, or 0 for an empty list."
  (if numbers
      (apply #'max numbers)
    0))

(defun ebox--span-whole-line-p (span)
  "Return non-nil when SPAN covers the whole current buffer line."
  (save-excursion
    (goto-char (car span))
    (and (= (car span) (line-beginning-position))
         (= (cdr span) (line-end-position)))))

(defun ebox--spans-contiguous-lines-p (spans)
  "Return non-nil when SPANS cover adjacent current buffer lines."
  (or (null spans)
      (cl-loop for rest on spans
               while (cdr rest)
               always (= (caadr rest) (1+ (cdar rest))))))

(defun ebox--span-footprint-signature
    (span-count pixel-widths char-lengths &optional whole-line-flags
                contiguous-lines)
  "Return the normalized footprint signature for replaceable spans."
  (list :span-count span-count
        :line-pixel-widths pixel-widths
        :char-lengths char-lengths
        :whole-line-flags whole-line-flags
        :contiguous-lines contiguous-lines))

(defun ebox--spans-span-footprint-signature (spans)
  "Return the L2 span-footprint signature for current buffer SPANS."
  (let ((pixel-widths (ebox--spans-line-signature spans))
        char-lengths
        whole-line-flags)
    (dolist (span spans)
      (push (- (cdr span) (car span)) char-lengths)
      (push (ebox--span-whole-line-p span) whole-line-flags))
    (ebox--span-footprint-signature
     (length spans)
     pixel-widths
     (nreverse char-lengths)
     (nreverse whole-line-flags)
     (ebox--spans-contiguous-lines-p spans))))

(defun ebox--rendered-span-footprint-signature (rendered)
  "Return the L2 span-footprint signature for RENDERED."
  (let* ((lines (ebox-string-lines rendered))
         (pixel-widths (mapcar #'ebox--string-pixel-width lines))
         (char-lengths (mapcar #'length lines)))
    (ebox--span-footprint-signature
     (length lines)
     pixel-widths
     char-lengths
     (make-list (length lines) t)
     t)))

(defun ebox--external-footprint-signature-from-span-footprint (signature)
  "Return parent-visible footprint facts derived from SIGNATURE."
  (let ((pixel-widths (plist-get signature :line-pixel-widths)))
    (list :block-lines (plist-get signature :span-count)
          :max-line-pixel-width (ebox--safe-max-number pixel-widths))))

(defun ebox--span-parent-slot (span)
  "Return parent-facing placement facts for SPAN in the current buffer."
  (save-excursion
    (goto-char (car span))
    (let* ((line-start (line-beginning-position))
           (start-pixel
            (ebox--string-pixel-width
             (buffer-substring line-start (car span))))
           (width
            (ebox--string-pixel-width
             (buffer-substring (car span) (cdr span)))))
      (list :line (line-number-at-pos (car span) t)
            :start-pixel start-pixel
            :end-pixel (+ start-pixel width)
            :whole-line (ebox--span-whole-line-p span)))))

(defun ebox--spans-parent-slot-signature (spans)
  "Return parent-facing slot signature for current buffer SPANS."
  (list :slot-count (length spans)
        :slots (mapcar #'ebox--span-parent-slot spans)))

(defun ebox--project-parent-slot-signature
    (old-parent-slot new-span-footprint)
  "Return the projected parent slot after applying NEW-SPAN-FOOTPRINT."
  (let ((widths (plist-get new-span-footprint :line-pixel-widths))
        projected-slots)
    (cl-loop for slot in (plist-get old-parent-slot :slots)
             for width in widths
             do (push (plist-put (copy-sequence slot)
                                 :end-pixel
                                 (+ (plist-get slot :start-pixel) width))
                      projected-slots))
    (list :slot-count (plist-get new-span-footprint :span-count)
          :slots (nreverse projected-slots))))

(defun ebox--parent-slot-compatible-p (old new)
  "Return non-nil when OLD and NEW parent slots are equivalent."
  (equal old new))

(defun ebox--role-topology-signature (region-ids)
  "Return the set of rendered region roles present for REGION-IDS."
  (let ((role-set (make-hash-table :test 'eq))
        roles)
    (let ((roles (mapcar #'car ebox-region-types))
          (buffer (current-buffer)))
      (dolist (region-id region-ids)
        (dolist (mount
                 (ebox-surface-region-mounts buffer region-id roles))
          (dolist (role (plist-get (plist-get mount :tags) :ebox/roles))
            (puthash role t role-set)))))
    (maphash (lambda (role _) (push role roles)) role-set)
    (list :roles
          (sort roles
                (lambda (left right)
                  (string< (symbol-name left)
                           (symbol-name right)))))))

(defun ebox--overflow-signature (node)
  "Return visible-overflow facts for NODE."
  (list :visible (and node (ebox--node-visible-overflow-p node))))

(defun ebox--span-footprint-compatible-p (old new)
  "Return non-nil when OLD and NEW span footprints are L2-compatible."
  (and old new
       (= (plist-get old :span-count)
          (plist-get new :span-count))
       (equal (plist-get old :line-pixel-widths)
              (plist-get new :line-pixel-widths))))

(defun ebox--external-footprint-compatible-p (old new)
  "Return non-nil when OLD and NEW parent-visible footprints match."
  (equal old new))

(defun ebox--buffer-line-spans (buffer)
  "Return whole-line spans for BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let (spans)
        (save-excursion
          (goto-char (point-min))
          (while (< (point) (point-max))
            (push (cons (line-beginning-position)
                        (line-end-position))
                  spans)
            (forward-line 1)))
        (nreverse spans)))))

(defun ebox--complete-layout-snapshot-spans
    (buffer node snapshot &optional copy)
  "Return SNAPSHOT with buffer spans for NODE in BUFFER.
When COPY is non-nil, complete and return a copied snapshot without mutating
the original plist."
  (let ((snapshot (if copy (copy-sequence snapshot) snapshot)))
    (if (ebox--layout-snapshot-spans-p snapshot)
        snapshot
      (let* ((region-ids (or (plist-get snapshot :region-ids)
                             (ebox--node-all-region-ids node)))
             (spans (if (equal (plist-get snapshot :node-id)
                                (ebox--buffer-root-node-id buffer))
                        (ebox--buffer-line-spans buffer)
                      (and region-ids
                           (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (ebox--region-set-line-spans region-ids))))))
        (setq snapshot (plist-put snapshot :region-ids region-ids))
        (setq snapshot (plist-put snapshot :buffer-spans spans))
        (setq snapshot
              (plist-put snapshot :detail-generation
                         (ebox--buffer-layout-snapshot-detail-generation
                          buffer)))
        snapshot))))

(defun ebox--complete-layout-snapshot (buffer node snapshot &optional copy)
  "Return SNAPSHOT with derived spans and line signature for NODE in BUFFER.
When COPY is non-nil, complete and return a copied snapshot without mutating
the original plist."
  (let ((snapshot (ebox--complete-layout-snapshot-spans
                   buffer node snapshot copy)))
    (if (ebox--layout-snapshot-detailed-p snapshot)
        snapshot
      (let* ((spans (plist-get snapshot :buffer-spans))
             (span-footprint
              (and spans
                   (with-current-buffer buffer
                     (ebox--spans-span-footprint-signature spans))))
             (line-signature
              (plist-get span-footprint :line-pixel-widths))
             (external-footprint
              (and span-footprint
                   (ebox--external-footprint-signature-from-span-footprint
                    span-footprint)))
             (parent-slot
              (and spans
                   (with-current-buffer buffer
                     (ebox--spans-parent-slot-signature spans))))
             (role-topology
              (and (plist-get snapshot :region-ids)
                   (with-current-buffer buffer
                     (ebox--role-topology-signature
                      (plist-get snapshot :region-ids)))))
             (overflow (ebox--overflow-signature node)))
        (setq snapshot (plist-put snapshot :line-signature line-signature))
        (setq snapshot
              (plist-put snapshot
                         :span-footprint-signature span-footprint))
        (setq snapshot
              (plist-put snapshot
                         :external-footprint-signature external-footprint))
        (setq snapshot
              (plist-put snapshot :parent-slot-signature parent-slot))
        (setq snapshot
              (plist-put snapshot :role-topology-signature role-topology))
        (setq snapshot
              (plist-put snapshot :overflow-signature overflow))
        snapshot))))

(defun ebox--snapshot-published-node (buffer node-id)
  "Return the node whose PUBLISHED rendering a snapshot must describe.
During a logical-candidate planning pass the runtime lookup resolves
path-copied candidate nodes whose children already reflect the next
tree, but stored layout snapshots describe the still-published
buffer.  Completing a snapshot from a candidate node drops regions
the candidate no longer contains, producing spans with holes and a
misplaced text replacement, so the base state's node wins whenever
the planning pass has one for this buffer."
  (or (when-let* ((base ebox-incremental--candidate-base-state)
                  ((eq buffer (car base)))
                  (node-table (plist-get (cdr base) :node-table)))
        (gethash node-id node-table))
      (ebox--buffer-runtime-node buffer node-id)))

(defun ebox--ensure-layout-snapshot-spans (buffer node-id)
  "Ensure BUFFER's stored snapshot for NODE-ID has buffer span details."
  (when-let ((snapshot (ebox--layout-snapshot buffer node-id)))
    (if (ebox--layout-snapshot-spans-p snapshot)
        snapshot
      (when-let ((node (ebox--snapshot-published-node buffer node-id)))
        (let ((detailed
               (ebox--with-layout-snapshot-detail-context buffer
                 (ebox--complete-layout-snapshot-spans
                  buffer node snapshot))))
          (ebox--put-layout-snapshot buffer node-id detailed)
          detailed)))))

(defun ebox--ensure-layout-snapshot-details (buffer node-id)
  "Ensure BUFFER's stored snapshot for NODE-ID has expensive detail fields."
  (when-let ((snapshot (ebox--layout-snapshot buffer node-id)))
    (if (ebox--layout-snapshot-detailed-p snapshot)
        snapshot
      (when-let ((node (ebox--snapshot-published-node buffer node-id)))
        (let ((detailed
               (ebox--with-layout-snapshot-detail-context buffer
                 (ebox--complete-layout-snapshot buffer node snapshot))))
          (ebox--put-layout-snapshot buffer node-id detailed)
          detailed)))))

(defun ebox--capture-layout-snapshots (buffer node &optional details)
  "Capture derived layout snapshots for NODE's runtime tree in BUFFER.
When DETAILS is non-nil, include expensive per-line detail fields."
  (when (and (buffer-live-p buffer)
             (listp node))
    (let ((node-id (ebox--ensure-node-id node)))
      (ebox--put-layout-snapshot
       buffer node-id (ebox--node-layout-snapshot buffer node details))
      (dolist (child (ebox--node-children node))
        (ebox--capture-layout-snapshots buffer child details)))))

(defun ebox--refresh-buffer-layout-snapshots (buffer &optional details)
  "Recapture BUFFER's layout snapshots from its stored runtime root.
When DETAILS is non-nil, include expensive per-line detail fields."
  (when-let ((root (ebox--buffer-root-node buffer)))
    (ebox--clear-layout-snapshots buffer)
    (let ((ebox--node-region-ids-cache (make-hash-table :test 'eq)))
      (if details
          (ebox--with-layout-snapshot-index-context buffer
            (ebox--capture-layout-snapshots buffer root t))
        (ebox--capture-layout-snapshots buffer root)))
    (when-let ((state (ebox--buffer-render-state buffer)))
      (plist-put state :layout-snapshots-complete-p t))))

(defconst ebox--dirty-kind-order
  '(paint span geometry placement structure)
  "Dirty kinds ordered from cheapest to most disruptive.")

(defun ebox--dirty-entry (node-id kind &rest props)
  "Return a dirty-set entry for NODE-ID and KIND."
  (append (list :node-id node-id :dirty-kind kind) props))

(defun ebox--dirty-set-kinds (dirty-set)
  "Return ordered distinct dirty kinds from DIRTY-SET."
  (let (kinds)
    (dolist (entry dirty-set (nreverse kinds))
      (let ((kind (plist-get entry :dirty-kind)))
        (unless (memq kind kinds)
          (push kind kinds))))))

(defun ebox--dirty-set-changed-keys (dirty-set)
  "Return ordered distinct changed keys from DIRTY-SET."
  (let (keys)
    (dolist (entry dirty-set (nreverse keys))
      (dolist (key (plist-get entry :changed-keys))
        (unless (memq key keys)
          (push key keys))))))

(defun ebox--dirty-set-impact-vector (dirty-set)
  "Return ordered distinct impact facts from DIRTY-SET."
  (let (impacts)
    (dolist (entry dirty-set (nreverse impacts))
      (dolist (impact (plist-get entry :impact-vector))
        (unless (memq impact impacts)
          (push impact impacts))))))

(defun ebox--constraint-change
    (source owner-id owner-type root-node-id dirty-set &rest props)
  "Return a normalized constraint-change descriptor."
  (append (list :constraint-source source
                :constraint-owner-id owner-id
                :constraint-owner-type owner-type
                :constraint-root-node-id root-node-id
                :dirty-set dirty-set)
          props))

(defun ebox--constraint-change-report-props (change)
  "Return update-report properties describing CHANGE."
  (let ((dirty-set (plist-get change :dirty-set)))
    (list :constraint-source (plist-get change :constraint-source)
          :constraint-owner-id (plist-get change :constraint-owner-id)
          :constraint-owner-type (plist-get change :constraint-owner-type)
          :constraint-root-node-id (plist-get change :constraint-root-node-id)
          :dirty-kinds (ebox--dirty-set-kinds dirty-set)
          :dirty-keys (ebox--dirty-set-changed-keys dirty-set)
          :impact-vector (ebox--dirty-set-impact-vector dirty-set))))

(defun ebox--diff-layout-snapshots (old-table new-table)
  "Return dirty-set entries comparing OLD-TABLE and NEW-TABLE."
  (let (dirty)
    (maphash
     (lambda (node-id old)
       (unless (gethash node-id new-table)
         (push (ebox--dirty-entry node-id 'structure
                                  :old old :new nil)
               dirty)))
     old-table)
    (maphash
     (lambda (node-id new)
       (let* ((old (gethash node-id old-table))
              (kind (ebox--layout-snapshot-dirty-kind old new)))
         (when kind
           (push (ebox--dirty-entry node-id kind
                                    :old old :new new)
                 dirty))))
     new-table)
    (nreverse dirty)))

(defun ebox--runtime-node-by-id (node node-id)
  "Return runtime NODE's descendant with NODE-ID."
  (cond
   ((or (stringp node) (not (listp node))) nil)
   ((equal (ebox--ensure-node-id node) node-id) node)
   (t
    (cl-some (lambda (child)
               (ebox--runtime-node-by-id child node-id))
             (ebox--node-children node)))))

(defun ebox--buffer-runtime-node (buffer node-id)
  "Return runtime node NODE-ID in BUFFER."
  (or (and ebox-incremental--candidate-proof-node-table
           (eq buffer
               (car ebox-incremental--candidate-proof-node-table))
           (gethash node-id
                    (cdr ebox-incremental--candidate-proof-node-table)))
      (when-let ((node-table (ebox--buffer-node-table buffer)))
        (gethash node-id node-table))
      (when-let ((root (ebox--buffer-root-node buffer)))
        (ebox--runtime-node-by-id root node-id))))

(defun ebox--runtime-parent-id (buffer node-id)
  "Return NODE-ID's parent id in BUFFER runtime state."
  (when-let ((parent-table (ebox--buffer-parent-table buffer)))
    (gethash node-id parent-table)))

(defun ebox--invalidate-runtime-render-signature-path
    (node-id node-table parent-table signature-cache height-cache)
  "Invalidate NODE-ID to root in explicit runtime structural caches."
  (if (null node-id)
      (progn
        (when signature-cache (clrhash signature-cache))
        (when height-cache (clrhash height-cache)))
    (while node-id
      (when-let ((node (gethash node-id node-table)))
        (when signature-cache (remhash node signature-cache))
        (when height-cache (remhash node height-cache)))
      (setq node-id (gethash node-id parent-table)))))

(defun ebox--runtime-ancestor-id-p (buffer ancestor-id node-id)
  "Return non-nil when ANCESTOR-ID is NODE-ID's ancestor in BUFFER."
  (let ((parent (ebox--runtime-parent-id buffer node-id))
        found)
    (while (and parent (not found))
      (if (equal parent ancestor-id)
          (setq found t)
        (setq parent (ebox--runtime-parent-id buffer parent))))
    found))

(defun ebox--patch-op (op owner-id &rest props)
  "Return a patch-set operation."
  (append (list :op op :owner-id owner-id) props))


(defvar ebox--patchable-owner-cache nil
  "Dynamic patch-planning cache for `ebox--patchable-owner-p' results.")

(defvar ebox--runtime-ancestor-cache nil
  "Dynamic patch-planning cache for runtime ancestor checks.")

(defvar ebox--flex-slot-safety-cache nil
  "Dynamic patch-planning cache for flex item slot safety checks.")

(defconst ebox--owner-coalesce-min-count 8
  "Minimum owner-rerender op count before considering root coalescing.")

(defconst ebox--owner-coalesce-min-coverage 0.8
  "Minimum root line coverage ratio before coalescing local owner patches.")

(defconst ebox-incremental--broad-dirty-min-node-coverage 0.8
  "Minimum dirty descendant ratio for broad owner pre-coalescing.")


(defconst ebox--span-patch-local-style-keys
  '(:content :text-align :vertical-align :wrap-mode :scroll-offset
    :visibility)
  "Geometry style keys that can be local span-patch candidates.
Visibility toggles rerender the owner's own spans with ink suppressed
or restored while the footprint stays identical, so they are local by
construction.")

(defconst ebox--span-patch-border-box-inline-keys
  '(:padding-left-pixel :padding-right-pixel
    :border-left-pixel :border-right-pixel)
  "Border-box inline keys that can be internal span-patch candidates.")

(defconst ebox--span-patch-border-box-block-keys
  '(:padding-top-height :padding-bottom-height)
  "Border-box block keys that can be internal span-patch candidates.")

(defun ebox--cached-patchable-owner-p
    (buffer node-id &optional dirty-kind allow-owned-overflow-coverage)
  "Return whether NODE-ID is patchable, using a patch-planning cache."
  (if (not ebox--patchable-owner-cache)
      (ebox--patchable-owner-p
       buffer node-id dirty-kind allow-owned-overflow-coverage)
    (let* ((key (list node-id dirty-kind allow-owned-overflow-coverage))
           (missing (make-symbol "ebox-patchable-missing"))
           (cached (gethash key ebox--patchable-owner-cache missing)))
      (if (not (eq cached missing))
          cached
        (puthash key
                 (ebox--patchable-owner-p
                  buffer node-id dirty-kind allow-owned-overflow-coverage)
                 ebox--patchable-owner-cache)))))

(defun ebox--runtime-ancestor-id-set (buffer node-id)
  "Return NODE-ID's complete strict-ancestor id set in BUFFER.
Uses the planning cache when bound so one parent walk serves every
later membership check for the same node."
  (or (and ebox--runtime-ancestor-cache
           (gethash node-id ebox--runtime-ancestor-cache))
      (let ((ancestors (make-hash-table :test 'equal))
            (walk (ebox--runtime-parent-id buffer node-id)))
        (while walk
          (puthash walk t ancestors)
          (setq walk (ebox--runtime-parent-id buffer walk)))
        (when ebox--runtime-ancestor-cache
          (puthash node-id ancestors ebox--runtime-ancestor-cache))
        ancestors)))

(defun ebox--cached-runtime-ancestor-id-p (buffer ancestor-id node-id)
  "Return whether ANCESTOR-ID covers NODE-ID, using a planning cache.
The cache stores one complete ancestor-id set per node, built by a
single parent walk, so a planning pass with many pairwise dominance
checks pays one walk per distinct node instead of one walk per pair."
  (if (not ebox--runtime-ancestor-cache)
      (ebox--runtime-ancestor-id-p buffer ancestor-id node-id)
    (gethash ancestor-id
             (ebox--runtime-ancestor-id-set buffer node-id))))

(defun ebox--patch-operation-strength (strategy)
  "Return structural dominance strength for patch STRATEGY."
  (pcase strategy
    ('owner-rerender 3)
    ('span-patch 2)
    ('paint-patch 1)
    ('child-splice 0)
    ('child-reorder 0)
    (_ 0)))

(defun ebox--dirty-kind-strength (kind)
  "Return relative disruption strength for dirty KIND."
  (or (cl-position kind ebox--dirty-kind-order) -1))

(defun ebox--dirty-provenance-node-ids (dirty)
  "Return the distinct source node ids recorded by DIRTY provenance."
  (delete-dups
   (append (when-let ((node-id (plist-get dirty :node-id)))
             (list node-id))
           (copy-sequence (or (plist-get dirty :node-ids) nil)))))

(defun ebox--merge-dirty-provenance (primary secondary)
  "Merge SECONDARY dirty provenance into PRIMARY."
  (cond
   ((null primary) (copy-sequence secondary))
   ((null secondary) (copy-sequence primary))
   (t
    (let ((merged (copy-sequence primary)))
      (setq merged
            (plist-put
             merged :node-ids
             (delete-dups
              (append (ebox--dirty-provenance-node-ids primary)
                      (ebox--dirty-provenance-node-ids secondary)))))
      (dolist (key '(:changed-keys :region-ids :old-region-ids
                     :new-region-ids :impact-vector))
        (setq merged
              (plist-put
               merged key
               (delete-dups
                (append (copy-sequence (or (plist-get primary key) nil))
                        (copy-sequence (or (plist-get secondary key) nil)))))))
      (when (or (plist-get primary :requires-owned-overflow-coverage)
                (plist-get secondary :requires-owned-overflow-coverage))
        (setq merged
              (plist-put merged :requires-owned-overflow-coverage t)))
      (when (> (ebox--dirty-kind-strength
                (plist-get secondary :dirty-kind))
               (ebox--dirty-kind-strength
                (plist-get primary :dirty-kind)))
        (setq merged
              (plist-put merged :dirty-kind
                         (plist-get secondary :dirty-kind))))
      merged))))

(defun ebox--merge-dirty-provenance-list (entries)
  "Merge dirty provenance from ENTRIES into one entry."
  (when entries
    (cl-reduce #'ebox--merge-dirty-provenance entries)))

(defun ebox--patch-op-merge-dirty (op absorbed)
  "Return OP with dirty provenance from ABSORBED merged into it."
  (let ((merged (copy-sequence op)))
    (plist-put merged :dirty
               (ebox--merge-dirty-provenance
                (plist-get op :dirty)
                (plist-get absorbed :dirty)))))

(defun ebox--merge-same-owner-patch-ops (left right)
  "Return the stronger same-owner patch with merged dirty provenance."
  (let* ((left-strength
          (ebox--patch-operation-strength (plist-get left :op)))
         (right-strength
          (ebox--patch-operation-strength (plist-get right :op)))
         (left-dirty-strength
          (ebox--dirty-kind-strength
           (plist-get (plist-get left :dirty) :dirty-kind)))
         (right-dirty-strength
          (ebox--dirty-kind-strength
           (plist-get (plist-get right :dirty) :dirty-kind)))
         (left-wins
          (or (> left-strength right-strength)
              (and (= left-strength right-strength)
                   (>= left-dirty-strength right-dirty-strength))))
         (winner (if left-wins left right))
         (loser (if left-wins right left))
         (merged (copy-sequence winner)))
    (plist-put merged :dirty
               (ebox--merge-dirty-provenance
                (plist-get winner :dirty)
                (plist-get loser :dirty)))))

(defun ebox--patch-op-covers-node-p (buffer op node-id node-strategy)
  "Return non-nil when OP dominates NODE-STRATEGY at NODE-ID in BUFFER."
  (let* ((owner-id (plist-get op :owner-id))
         (op-strength
          (ebox--patch-operation-strength (plist-get op :op))))
    (and owner-id node-id
         (if (equal owner-id node-id)
             (>= op-strength
                 (ebox--patch-operation-strength node-strategy))
           (and (>= op-strength
                    (ebox--patch-operation-strength 'span-patch))
                (or (equal owner-id (ebox--buffer-root-node-id buffer))
                    (ebox--cached-runtime-ancestor-id-p
                     buffer owner-id node-id)))))))

(defun ebox--patch-op-dominates-p (buffer op other)
  "Return non-nil when OP makes OTHER redundant in BUFFER."
  (ebox--patch-op-covers-node-p
   buffer op (plist-get other :owner-id) (plist-get other :op)))

(defun ebox--merge-patch-op-into-set (buffer ops candidate)
  "Merge CANDIDATE into OPS using operation-aware coverage in BUFFER."
  (let* ((owner-id (plist-get candidate :owner-id))
         (same-owner
          (cl-find-if (lambda (op)
                        (equal (plist-get op :owner-id) owner-id))
                      ops))
         (candidate (if same-owner
                        (ebox--merge-same-owner-patch-ops
                         same-owner candidate)
                      candidate))
         (remaining (if same-owner
                        (delq same-owner (copy-sequence ops))
                      (copy-sequence ops))))
    (if-let ((dominator
              (cl-find-if
               (lambda (op)
                 (ebox--patch-op-dominates-p buffer op candidate))
               remaining)))
        (mapcar (lambda (op)
                  (if (eq op dominator)
                      (ebox--patch-op-merge-dirty op candidate)
                    op))
                remaining)
      (let ((survivors nil))
        (dolist (op remaining)
          (if (ebox--patch-op-dominates-p buffer candidate op)
              (setq candidate (ebox--patch-op-merge-dirty candidate op))
            (push op survivors)))
        (append (nreverse survivors) (list candidate))))))

(defun ebox--span-patch-definite-size-value-p (value)
  "Return non-nil when VALUE is definite enough for local span planning."
  (and value
       (not (memq value '(auto min-content max-content fit-content
                          stretch contain viewport)))
       (not (ebox--viewport-dependent-size-value-p value))))

(defun ebox--dirty-entry-local-span-keys-p (entry)
  "Return non-nil when ENTRY changed only local span candidate keys.
Paint-class keys ride along: a span rerender republishes the owner's
text together with its faces and surface text properties, so mixing
`:surface-properties' or paint signature keys with local span keys
keeps the change local to the owner's own rendered spans."
  (let ((changed-keys (plist-get entry :changed-keys)))
    (and changed-keys
         (cl-every (lambda (key)
                     (or (memq key ebox--span-patch-local-style-keys)
                         (eq key :surface-properties)
                         (memq key ebox--paint-style-signature-keys)))
                   changed-keys))))

(defun ebox--border-box-inline-content-fits-p (style-node)
  "Return non-nil when STYLE-NODE's inline chrome fits its fixed width."
  (let ((width (ebox-get style-node :width)))
    (and (numberp width)
         (>= width
             (+ (ebox-get style-node :padding-left-pixel)
                (ebox-get style-node :padding-right-pixel)
                (ebox-get style-node :border-left-pixel)
                (ebox-get style-node :border-right-pixel))))))

(defun ebox--border-box-block-content-fits-p (style-node)
  "Return non-nil when STYLE-NODE's block padding leaves one content line."
  (let ((height (ebox-get style-node :height)))
    (and (numberp height)
         (>= height
             (+ 1
                (floor (ebox-get style-node :padding-top-height))
                (floor (ebox-get style-node :padding-bottom-height)))))))

(defun ebox--dirty-entry-border-box-internal-span-p (buffer entry)
  "Return non-nil when ENTRY changes only fixed border-box internals.
Inline and block padding/border fields may arrive together after shorthand
expansion.  Treat that mixed set as one local candidate when the corresponding
outer width and height are definite and still contain their inner chrome."
  (let* ((changed-keys (plist-get entry :changed-keys))
         (inline-changed
          (cl-some (lambda (key)
                     (memq key ebox--span-patch-border-box-inline-keys))
                   changed-keys))
         (block-changed
          (cl-some (lambda (key)
                     (memq key ebox--span-patch-border-box-block-keys))
                   changed-keys)))
    (and changed-keys
         (cl-every
          (lambda (key)
            (or (memq key ebox--span-patch-border-box-inline-keys)
                (memq key ebox--span-patch-border-box-block-keys)))
          changed-keys)
         (when-let* ((node-id (plist-get entry :node-id))
                     (node (ebox--buffer-runtime-node buffer node-id))
                     (style-node (ebox-fragment-style-source-node node)))
           (and (eq (ebox-get style-node :box-sizing) 'border-box)
                (or (not inline-changed)
                    (ebox--border-box-inline-content-fits-p style-node))
                (or (not block-changed)
                    (ebox--border-box-block-content-fits-p style-node)))))))

(defun ebox--dirty-entry-span-patch-candidate-p (buffer entry)
  "Return non-nil when ENTRY can first attempt a local span patch."
  (and buffer
       (eq (plist-get entry :dirty-kind) 'geometry)
       (or (ebox--dirty-entry-local-span-keys-p entry)
           (ebox--dirty-entry-border-box-internal-span-p buffer entry))))

(defun ebox--changed-key-impact (key style-node)
  "Return impact facts for changed KEY on STYLE-NODE."
  (cond
   ((memq key ebox--paint-style-signature-keys)
    '(paint))
   ;; Surface text properties are stamped onto the owner's rendered
   ;; spans and cannot move any geometry, exactly like paint; the
   ;; declarative dirty-kind classifier already groups them with paint.
   ((eq key :surface-properties)
    '(paint))
   ((eq key :content)
    '(internal-fragment external-footprint-proof))
   ((memq key ebox--span-patch-local-style-keys)
    '(internal-fragment))
   ((and (eq (ebox-get style-node :box-sizing) 'border-box)
         (memq key ebox--span-patch-border-box-inline-keys)
         (ebox--span-patch-definite-size-value-p
          (ebox-get style-node :width)))
    '(internal-fragment external-footprint-proof))
   ((and (eq (ebox-get style-node :box-sizing) 'border-box)
         (memq key ebox--span-patch-border-box-block-keys)
         (numberp (ebox-get style-node :height)))
    '(internal-fragment external-footprint-proof))
   ((eq key :overflow)
    '(clipping external-footprint))
   ((eq key :box-sizing)
    '(size-interpretation external-footprint))
   ((memq key '(:margin-left-pixel :margin-right-pixel
                :margin-top-height :margin-bottom-height))
    '(external-footprint parent-layout))
   (t
    '(external-footprint parent-layout))))

(defun ebox--dirty-entry-impact-vector (buffer entry)
  "Return normalized impact vector for dirty ENTRY in BUFFER."
  (let* ((node-id (plist-get entry :node-id))
         (node (and node-id (ebox--buffer-runtime-node buffer node-id)))
         (style-node (and node (ebox-fragment-style-source-node node)))
         impacts)
    (dolist (key (plist-get entry :changed-keys))
      (dolist (impact (ebox--changed-key-impact key style-node))
        (cl-pushnew impact impacts)))
    (nreverse impacts)))

(defun ebox--dirty-entry-requires-owned-overflow-coverage-p (buffer entry)
  "Return non-nil when ENTRY changes to or from unowned visible overflow."
  (when (memq :overflow (plist-get entry :changed-keys))
    (let* ((node-id (plist-get entry :node-id))
           (node (and node-id (ebox--buffer-runtime-node buffer node-id)))
           (style-node (and node (ebox-fragment-style-source-node node)))
           (old-values (plist-get entry :old-style-values))
           (stored-snapshots
            (plist-get (ebox--buffer-render-state buffer) :layout-snapshots))
           (old-snapshot
            (or (plist-get entry :old)
                (and stored-snapshots node-id
                     (gethash node-id stored-snapshots))))
           (old-style (and old-snapshot
                           (plist-get old-snapshot :style-signature)))
           (old-overflow-known
            (or (plist-member old-values :overflow)
                (and old-style (plist-member old-style :overflow))))
           (old-overflow
            (if (plist-member old-values :overflow)
                (plist-get old-values :overflow)
              (plist-get old-style :overflow)))
           (new-overflow (and style-node (ebox-get style-node :overflow))))
      (or (not old-overflow-known)
          (eq old-overflow 'visible)
          (eq new-overflow 'visible)))))

(defun ebox--dirty-entry-with-impact-vector (buffer entry)
  "Return ENTRY with an impact vector computed in BUFFER."
  (setq entry
        (plist-put entry :impact-vector
                   (ebox--dirty-entry-impact-vector buffer entry)))
  (when (ebox--dirty-entry-requires-owned-overflow-coverage-p buffer entry)
    (setq entry
          (plist-put entry :requires-owned-overflow-coverage t)))
  entry)

(defun ebox--impact-vector-requires-parent-promotion-p (impact-vector)
  "Return non-nil when IMPACT-VECTOR requires parent-layout promotion."
  (or (null impact-vector)
      (memq 'parent-layout impact-vector)
      (memq 'clipping impact-vector)
      (memq 'size-interpretation impact-vector)))

(defun ebox--impact-vector-requires-conservative-owner-p (impact-vector)
  "Return non-nil when IMPACT-VECTOR must use conservative owner rerendering."
  (or (memq 'clipping impact-vector)
      (memq 'size-interpretation impact-vector)))

(defun ebox--node-own-overflow-visible-p (buffer node-id)
  "Return non-nil when NODE-ID's current or stored own overflow is visible."
  (let* ((node (ebox--buffer-runtime-node buffer node-id))
         (style-node (and node (ebox-fragment-style-source-node node)))
         (snapshots
          (plist-get (ebox--buffer-render-state buffer) :layout-snapshots))
         (snapshot (and snapshots (gethash node-id snapshots)))
         (old-style (and snapshot
                         (plist-get snapshot :style-signature))))
    (or (eq (and style-node (ebox-get style-node :overflow)) 'visible)
        (eq (plist-get old-style :overflow) 'visible))))

(defun ebox--ancestor-own-overflow-visible-p (buffer node-id)
  "Return non-nil when an ancestor of NODE-ID has visible own overflow."
  (let ((ancestor-id (ebox--runtime-parent-id buffer node-id))
        found)
    (while (and ancestor-id (not found))
      (if (ebox--node-own-overflow-visible-p buffer ancestor-id)
          (setq found t)
        (setq ancestor-id (ebox--runtime-parent-id buffer ancestor-id))))
    found))

(defun ebox--owned-overflow-coverage-wrapper-node-p (buffer node-id)
  "Return non-nil when NODE-ID's wrapper owns the required overflow footprint."
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
              (style-node (ebox-fragment-style-source-node node)))
    (let* ((parent-id (ebox--runtime-parent-id buffer node-id))
           (parent (and parent-id
                        (ebox--buffer-runtime-node buffer parent-id))))
      (and (ebox-get style-node :region-id)
           (not (eq (ebox-get style-node :overflow) 'visible))
           (not (ebox--ancestor-own-overflow-visible-p buffer node-id))
           (not (and parent
                     (eq (ebox--display-inner parent) 'flex)))))))

(defun ebox--patch-op-from-dirty-entry (entry &optional buffer)
  "Return the patch op for dirty-set ENTRY.
When BUFFER is non-nil, non-paint entries promote to patchable owners."
  (let* ((node-id (plist-get entry :node-id))
         (dirty-kind (plist-get entry :dirty-kind))
         (requires-owned-overflow-coverage
          (or (plist-get entry :requires-owned-overflow-coverage)
              (and buffer
                   (ebox--dirty-entry-requires-owned-overflow-coverage-p
                    buffer entry))))
         (entry
          (if requires-owned-overflow-coverage
              (plist-put entry :requires-owned-overflow-coverage t)
            entry))
         (impact-vector (or (plist-get entry :impact-vector)
                            (and buffer
                                 (plist-get entry :changed-keys)
                                 (ebox--dirty-entry-impact-vector
                                  buffer entry)))))
    (pcase dirty-kind
      ('paint
       (ebox--patch-op 'paint-patch node-id
                       :dirty entry))
      (_
       (if-let ((span-owner-id
                 (and buffer
                      (ebox--span-patch-owner-id-for-dirty-entry
                       entry buffer))))
           (ebox--patch-op 'span-patch span-owner-id
                           :dirty entry)
         (let ((fallback-owner-id
                (or (and buffer
                         requires-owned-overflow-coverage
                         (or (ebox--next-patchable-owner-ancestor
                              buffer node-id dirty-kind t)
                             (ebox--buffer-root-node-id buffer)))
                    (and buffer
                         (or (memq 'size-interpretation impact-vector)
                             (not
                              (ebox--impact-vector-requires-conservative-owner-p
                               impact-vector)))
                         (ebox--promote-to-patchable-owner
                          buffer node-id dirty-kind
                          (plist-get entry :changed-keys)
                          impact-vector))
                    (and buffer (ebox--buffer-root-node-id buffer))
                    node-id)))
           (ebox--patch-op 'owner-rerender fallback-owner-id
                           :dirty entry)))))))


(defun ebox--line-spans-cover-whole-lines-p (spans)
  "Return non-nil when every span in SPANS owns whole buffer lines."
  (cl-every (lambda (span)
              (save-excursion
                (goto-char (car span))
                (and (= (car span) (line-beginning-position))
                     (= (cdr span) (line-end-position)))))
            spans))

(defun ebox--row-or-flex-layout-p (node)
  "Return non-nil when NODE repositions siblings after child geometry changes."
  (memq (ebox--display-inner node) '(row flex)))

(defun ebox--row-or-flex-ancestor-p (buffer node-id)
  "Return non-nil when NODE-ID is contained by a row or flex layout ancestor."
  (let ((ancestor-id (ebox--runtime-parent-id buffer node-id))
        found)
    (while (and ancestor-id (not found))
      (let ((ancestor (ebox--buffer-runtime-node buffer ancestor-id)))
        (if (and ancestor (ebox--row-or-flex-layout-p ancestor))
            (setq found t)
          (setq ancestor-id
                (ebox--runtime-parent-id buffer ancestor-id)))))
    found))

(defun ebox--geometry-affects-parent-layout-p (buffer node-id)
  "Return non-nil when NODE-ID geometry can change parent layout in BUFFER."
  (when-let* ((parent-id (ebox--runtime-parent-id buffer node-id))
              (parent (ebox--buffer-runtime-node buffer parent-id)))
    (or (ebox--row-or-flex-layout-p parent)
        (ebox--row-or-flex-ancestor-p buffer parent-id)
        (not (ebox--definite-containment-formatting-context-p
              buffer parent-id)))))

(defun ebox--definite-containment-inline-size-value-p (value)
  "Return non-nil when VALUE is independent of intrinsic inline content."
  (and (ebox--span-patch-definite-size-value-p value)
       (not (eq (car-safe value) 'fit-content))))

(defun ebox--inline-size-change-p (changed-keys)
  "Return non-nil when CHANGED-KEYS contains only inline-size fields."
  (and changed-keys
       (cl-every (lambda (key)
                   (memq key '(:width :min-width :max-width)))
                 changed-keys)))

(defun ebox--definite-containment-formatting-context-p (buffer node-id)
  "Return non-nil when NODE-ID contains descendant inline size in BUFFER.
A formatting context is a safe local owner candidate only when both outer axes
are definite and neither it nor a descendant allows visible overflow.  Backend
footprint and parent-slot checks still decide whether it may actually be
patched."
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
              ((ebox--formatting-context-p node))
              (style-node (ebox-fragment-style-source-node node)))
    (let ((min-width (ebox-get style-node :min-width))
          (max-width (ebox-get style-node :max-width))
          (min-height (ebox-get style-node :min-height))
          (max-height (ebox-get style-node :max-height)))
      (and (ebox--definite-containment-inline-size-value-p
            (ebox-get style-node :width))
           (or (null min-width)
               (ebox--definite-containment-inline-size-value-p min-width))
           (or (null max-width)
               (eq max-width 'none)
               (ebox--definite-containment-inline-size-value-p max-width))
           (numberp (ebox-get style-node :height))
           (or (null min-height) (numberp min-height))
           (or (null max-height)
               (eq max-height 'none)
               (numberp max-height))
           (not (eq (ebox-get style-node :overflow) 'visible))
           (not (ebox--node-visible-overflow-p node))))))

(defun ebox--direct-row-or-flex-parent-p (buffer node-id)
  "Return non-nil when NODE-ID is a direct row/flex item owner."
  (when-let* ((parent-id (ebox--runtime-parent-id buffer node-id))
              (parent (ebox--buffer-runtime-node buffer parent-id)))
    (ebox--row-or-flex-layout-p parent)))

(defun ebox--direct-flex-parent-p (buffer node-id)
  "Return non-nil when NODE-ID is a direct flex item owner."
  (when-let* ((parent-id (ebox--runtime-parent-id buffer node-id))
              (parent (ebox--buffer-runtime-node buffer parent-id)))
    (eq (ebox--display-inner parent) 'flex)))

(defconst ebox--flex-participation-style-keys
  '(:flex :flex-grow :flex-shrink :flex-basis :order :align-self
    :flex-participation)
  "Keys that participate in a parent flex sizing or placement algorithm.")

(defun ebox--flex-main-axis (flex-node)
  "Return FLEX-NODE's main axis."
  (if (memq (plist-get (plist-get flex-node :props) :flex-direction)
            '(column column-reverse))
      'column
    'row))

(defun ebox--flex-main-definite-size-p (style-node axis)
  "Return non-nil when STYLE-NODE has a definite main-axis outer size."
  (and style-node
       (if (eq axis 'row)
           (ebox--span-patch-definite-size-value-p
            (ebox-get style-node :width))
         (numberp (ebox-get style-node :height)))))

(defun ebox--flex-border-box-main-internal-key-p (key axis)
  "Return non-nil when KEY can be internal to a fixed border-box main size."
  (if (eq axis 'row)
      (memq key '(:padding-left-pixel :padding-right-pixel
                  :border-left-pixel :border-right-pixel))
    (memq key '(:padding-top-height :padding-bottom-height))))

(defun ebox--flex-content-flow-main-key-p (key)
  "Return non-nil when KEY can change an auto/content flex base size."
  (memq key '(:content :wrap-mode)))

(defun ebox--flex-main-footprint-key-p (key axis style-node)
  "Return non-nil when KEY can change STYLE-NODE's flex main footprint."
  (or (memq key ebox--flex-participation-style-keys)
      (eq key :box-sizing)
      (if (eq axis 'row)
          (memq key '(:width :min-width :max-width
                      :margin-left-pixel :margin-right-pixel))
        (memq key '(:height :min-height :max-height
                    :margin-top-height :margin-bottom-height)))
      (and (ebox--flex-border-box-main-internal-key-p key axis)
           (not (and (eq (ebox-get style-node :box-sizing) 'border-box)
                     (ebox--flex-main-definite-size-p style-node axis))))
      (and (ebox--flex-content-flow-main-key-p key)
           (not (ebox--flex-main-definite-size-p style-node axis)))))

(defun ebox--flex-main-size-keys-p (buffer node-id changed-keys)
  "Return non-nil when CHANGED-KEYS can change NODE-ID's flex main footprint."
  (and changed-keys
       (when-let* ((parent-id (ebox--runtime-parent-id buffer node-id))
                   (parent (ebox--buffer-runtime-node buffer parent-id))
                   ((eq (ebox--display-inner parent) 'flex))
                   (node (ebox--buffer-runtime-node buffer node-id))
                   (style-node (ebox-fragment-style-source-node node)))
         (let ((axis (ebox--flex-main-axis parent)))
           (cl-some (lambda (key)
                      (ebox--flex-main-footprint-key-p
                       key axis style-node))
                    changed-keys)))))

(defun ebox--flex-item-slot-at-declared-main-p (buffer node-id)
  "Return non-nil when NODE-ID's flex slot equals its declared main size.
Such an allocation is anchored by the item's own definite size rather
than by its content minimum, so a descendant footprint change cannot
move the slot while free space and sibling bases stay untouched.  A
slot above or below the declared size was decided by grow, shrink, or
a content-minimum clamp, and descendant changes may move it."
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
              (parent-id (ebox--runtime-parent-id buffer node-id))
              (parent (ebox--buffer-runtime-node buffer parent-id))
              ((eq (ebox--display-inner parent) 'flex))
              (style-node (ebox-fragment-style-source-node node))
              (snapshot (ebox--ensure-layout-snapshot-spans buffer node-id))
              (spans (plist-get snapshot :buffer-spans))
              (footprint
               (or (plist-get snapshot :span-footprint-signature)
                   (with-current-buffer buffer
                     (ebox--spans-span-footprint-signature spans))))
              (widths (plist-get footprint :line-pixel-widths))
              ((> (length widths) 0)))
    (let* ((axis (ebox--flex-main-axis parent))
           (slot-main (if (eq axis 'row)
                          (apply #'max widths)
                        (length widths)))
           (declared (ebox--flex-box-main-constraint
                      style-node axis
                      (if (eq axis 'row) :width :height))))
      (and declared (= slot-main declared)))))

(defun ebox--flex-item-footprint-keys-p (buffer node-id changed-keys)
  "Return non-nil when CHANGED-KEYS can change NODE-ID's flex footprint.
Both axes count: main-axis keys change the item's slot width and
cross-axis keys change its row footprint, exactly the pair
`ebox--flex-slot-allocation-stable-p' refuses for slot reuse."
  (and changed-keys
       (when-let* ((parent-id (ebox--runtime-parent-id buffer node-id))
                   (parent (ebox--buffer-runtime-node buffer parent-id))
                   ((eq (ebox--display-inner parent) 'flex))
                   (node (ebox--buffer-runtime-node buffer node-id))
                   (style-node (ebox-fragment-style-source-node node)))
         (let ((axis (ebox--flex-main-axis parent)))
           (cl-some (lambda (key)
                      (or (ebox--flex-main-footprint-key-p
                           key axis style-node)
                          (ebox--flex-main-footprint-key-p
                           key (ebox--flex-cross-axis axis) style-node)))
                    changed-keys)))))

(defun ebox--flex-child-for-source-node (flex-node node-id)
  "Return FLEX-NODE's child whose source owns NODE-ID."
  (cl-find-if
   (lambda (child)
     (when-let ((source (ebox--flex-item-source-node child)))
       (equal (plist-get source :node-id) node-id)))
   (plist-get flex-node :children)))

(defun ebox--flex-cross-axis (axis)
  "Return the axis perpendicular to flex AXIS."
  (if (eq axis 'row) 'column 'row))

(defun ebox--flex-content-allocation-stable-p
    (buffer style-node item-props axis current-main)
  "Return non-nil when content cannot change this flex allocation.
STYLE-NODE must have a definite main size used by the default auto basis, and
its new minimum must still fit CURRENT-MAIN."
  (when (and (eq (plist-get item-props :flex-basis) 'auto)
             (ebox--flex-main-definite-size-p style-node axis))
    (let ((rendered
           (if (and (eq axis 'row)
                    (null (ebox-get style-node :wrap-mode)))
               (ebox--with-buffer-render-context buffer
                 (ebox-render style-node))
             "")))
      (<= (ebox--flex-min-main style-node rendered axis)
          current-main))))

(defun ebox--flex-slot-allocation-stable-p
    (buffer node child axis current-main changed-keys)
  "Return non-nil when CHANGED-KEYS preserve NODE's flex allocation.
Unknown changes fail closed.  A fixed outer size is insufficient for content
updates unless the auto flex basis stays fixed and the new minimum still fits
the already published slot."
  (when-let ((style-node (ebox-fragment-style-source-node node)))
    (and changed-keys
         (cl-every
          (lambda (key)
            (and (not (ebox--flex-main-footprint-key-p
                       key axis style-node))
                 (not (ebox--flex-main-footprint-key-p
                       key (ebox--flex-cross-axis axis) style-node))))
          changed-keys)
         (or (not (cl-some #'ebox--flex-content-flow-main-key-p
                           changed-keys))
             (ebox--flex-content-allocation-stable-p
              buffer style-node (ebox--flex-item-props child)
              axis current-main)))))

(defun ebox--flex-item-slot-sized-node
    (buffer node-id snapshot &optional changed-keys)
  "Return NODE-ID copied to its currently rendered flex slot.
SNAPSHOT supplies the already published parent-facing footprint.  This keeps
incremental rendering in the same used-size context as the parent flex layout
instead of re-expanding the source node to its declared intrinsic size.
CHANGED-KEYS must prove that reusing the allocation is safe."
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
              ((eq (plist-get node :ebox-type) 'box))
              (parent-id (ebox--runtime-parent-id buffer node-id))
              (parent (ebox--buffer-runtime-node buffer parent-id))
              ((eq (ebox--display-inner parent) 'flex))
              (child (ebox--flex-child-for-source-node parent node-id))
              (spans (plist-get snapshot :buffer-spans))
              (footprint
               (or (plist-get snapshot :span-footprint-signature)
                   (with-current-buffer buffer
                     (ebox--spans-span-footprint-signature spans))))
              (widths (plist-get footprint :line-pixel-widths))
              ((and widths (> (length widths) 0))))
    (let* ((container-props
            (ebox--flex-container-content-props
             (plist-get parent :props)
             (plist-get parent :raw-props)
             (plist-get parent :box)))
           (axis (ebox--flex-axis container-props))
           (main (if (eq axis 'row)
                     (apply #'max widths)
                   (length widths)))
           (cross (if (eq axis 'row)
                      (length widths)
                    (apply #'max widths)))
           (item-props (ebox--flex-item-props child))
           (item-align (plist-get item-props :align-self))
           (align (if (memq item-align '(nil auto))
                      (plist-get container-props :align-items)
                    item-align))
           (stretch (memq align '(stretch normal))))
      (when (ebox--flex-slot-allocation-stable-p
             buffer node child axis main changed-keys)
        (ebox--flex-copy-node-for-size node axis main cross stretch)))))

(defun ebox--render-node-in-current-flex-slot
    (buffer node-id snapshot &optional changed-keys)
  "Render NODE-ID in BUFFER using its proven-stable flex slot, or return nil."
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
              (sized-node
               (ebox--flex-item-slot-sized-node
                buffer node-id snapshot changed-keys)))
    (prog1
        (ebox-render sized-node)
      ;; Rendering the sized copy reuses the stable region id.  Restore the
      ;; authoritative source object so later public updates never target the
      ;; temporary used-size copy.
      (ebox--flex-recache-source-boxes node))))

(defun ebox--flex-item-slot-footprint-safe-p
    (buffer node-id changed-keys)
  "Return non-nil when NODE-ID's current render still fits its old flex slot."
  (when-let* ((snapshot (ebox--ensure-layout-snapshot-details buffer node-id))
              (spans (plist-get snapshot :buffer-spans))
              (old-span-footprint
               (plist-get snapshot :span-footprint-signature))
              (old-external-footprint
               (plist-get snapshot :external-footprint-signature))
              (old-parent-slot
               (plist-get snapshot :parent-slot-signature))
              (node (ebox--buffer-runtime-node buffer node-id))
              ((not (ebox--node-visible-overflow-p node))))
    (ebox--with-buffer-render-context buffer
      (let* ((rendered
              (or (ebox--render-node-in-current-flex-slot
                   buffer node-id snapshot changed-keys)
                  (ebox-render node)))
             (slot-rendered
              (with-current-buffer buffer
                (ebox-buffer--rendered-in-existing-slots spans rendered)))
             (final-rendered (or slot-rendered rendered))
             (new-span-footprint
              (ebox--rendered-span-footprint-signature final-rendered))
             (new-external-footprint
              (ebox--external-footprint-signature-from-span-footprint
               new-span-footprint))
             (new-parent-slot
              (ebox--project-parent-slot-signature
               old-parent-slot new-span-footprint)))
        (and (ebox--span-footprint-compatible-p
              old-span-footprint new-span-footprint)
             (ebox--external-footprint-compatible-p
              old-external-footprint new-external-footprint)
             (ebox--parent-slot-compatible-p
              old-parent-slot new-parent-slot))))))

(defun ebox--cached-flex-item-slot-footprint-safe-p
    (buffer node-id changed-keys)
  "Return cached flex slot footprint safety for NODE-ID in BUFFER."
  (if (not ebox--flex-slot-safety-cache)
      (ebox--flex-item-slot-footprint-safe-p buffer node-id changed-keys)
    (let* ((key (list buffer node-id changed-keys))
           (missing (make-symbol "ebox-flex-slot-safety-missing"))
           (cached (gethash key ebox--flex-slot-safety-cache missing)))
      (if (not (eq cached missing))
          cached
        (puthash key
                 (ebox--flex-item-slot-footprint-safe-p
                  buffer node-id changed-keys)
                 ebox--flex-slot-safety-cache)))))

(defun ebox--flex-item-slot-safe-p
    (buffer node-id changed-keys &optional own-change)
  "Return non-nil when NODE-ID can keep its old flex item slot.
Footprint CHANGED-KEYS on either axis veto the slot when OWN-CHANGE
is non-nil.  For a climbed ancestor (OWN-CHANGE nil) they are
tolerable only while the slot is anchored at the item's own declared
main size: a descendant's size-family change flows into the item's
content minimum, and an allocation decided by that minimum (or by
grow/shrink) legitimately changes with it, so a slot-preserving
publication would freeze stale sibling geometry."
  (and (ebox--direct-flex-parent-p buffer node-id)
       (or (not (ebox--flex-item-footprint-keys-p
                 buffer node-id changed-keys))
           (and (not own-change)
                (ebox--flex-item-slot-at-declared-main-p buffer node-id)))
       (ebox--cached-flex-item-slot-footprint-safe-p
        buffer node-id changed-keys)))

(defun ebox--contained-partial-flex-owner-p (buffer node-id)
  "Return non-nil when NODE-ID is a definite flex stored in partial slots."
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
              ((eq (ebox--display-inner node) 'flex))
              ((ebox--definite-containment-formatting-context-p
                buffer node-id))
              (snapshot (ebox--ensure-layout-snapshot-spans buffer node-id))
              (spans (plist-get snapshot :buffer-spans)))
    (with-current-buffer buffer
      (ebox-buffer--partial-line-slots-p spans))))

(defun ebox--dirty-node-is-owner-style-source-p
    (buffer dirty-node-id owner-id)
  "Return non-nil when DIRTY-NODE-ID carries OWNER-ID's outer style."
  (when-let* ((owner (ebox--buffer-runtime-node buffer owner-id))
              (style-source (ebox-fragment-style-source-node owner)))
    (equal dirty-node-id (plist-get style-source :node-id))))

(defun ebox--first-geometry-owner-candidate
    (buffer node-id dirty-kind &optional changed-keys impact-vector)
  "Return the first structurally possible patch owner for NODE-ID.
Geometry changes inside layout containers must promote to the container before
running expensive span and snapshot checks."
  (let ((candidate node-id)
        (dirty-node-id node-id))
    (while (and (eq dirty-kind 'geometry)
                (ebox--impact-vector-requires-parent-promotion-p
                 impact-vector)
                (not (and (not (equal candidate dirty-node-id))
                          (ebox--contained-partial-flex-owner-p
                           buffer candidate)
                          (not
                           (ebox--dirty-node-is-owner-style-source-p
                            buffer dirty-node-id candidate))))
                (ebox--geometry-affects-parent-layout-p buffer candidate)
                (not (ebox--flex-item-slot-safe-p
                      buffer candidate changed-keys
                      (equal candidate dirty-node-id))))
      (setq candidate (ebox--runtime-parent-id buffer candidate)))
    candidate))

(defun ebox--partial-slot-owner-p (buffer node-id)
  "Return non-nil when NODE-ID owns replaceable partial row/flex slots."
  (when-let* ((snapshot (ebox--ensure-layout-snapshot-spans buffer node-id))
              (spans (plist-get snapshot :buffer-spans)))
    (with-current-buffer buffer
      (and (ebox--direct-flex-parent-p buffer node-id)
           (cl-some (lambda (span)
                      (not (ebox--span-whole-line-p span)))
                    spans)))))

(defun ebox--patchable-owner-p
    (buffer node-id &optional dirty-kind allow-owned-overflow-coverage)
  "Return non-nil when NODE-ID can be safely range patched in BUFFER."
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
              (snapshot (ebox--ensure-layout-snapshot-spans buffer node-id))
              (spans (plist-get snapshot :buffer-spans)))
    (with-current-buffer buffer
      (let* ((partial-slot (ebox--partial-slot-owner-p buffer node-id))
             (coverage-flex
              (and allow-owned-overflow-coverage
                   (eq (ebox--display-inner node) 'flex)))
             (contained-flex
              (ebox--contained-partial-flex-owner-p buffer node-id))
             (local-flex (or coverage-flex contained-flex)))
        (and (or (eq dirty-kind 'span)
                 (ebox--line-spans-cover-whole-lines-p spans)
                 (and (eq dirty-kind 'geometry) partial-slot)
                 (and (memq dirty-kind '(geometry structure))
                      local-flex))
             (not (and (eq dirty-kind 'geometry)
                       (ebox--geometry-affects-parent-layout-p buffer node-id)
                       (not partial-slot)
                       (not local-flex)))
             (or partial-slot
                 local-flex
                 (not (ebox--node-visible-overflow-p node))))))))

(defun ebox--span-patchable-owner-p (buffer node-id)
  "Return non-nil when NODE-ID can attempt verified span patching."
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
              (snapshot (ebox--ensure-layout-snapshot-spans buffer node-id))
              (spans (plist-get snapshot :buffer-spans)))
    (and spans
         (not (ebox--node-visible-overflow-p node)))))

(defun ebox--promote-to-patchable-owner
    (buffer node-id &optional dirty-kind changed-keys impact-vector)
  "Return the smallest patchable owner id for NODE-ID in BUFFER."
  (let ((candidate (ebox--first-geometry-owner-candidate
                    buffer node-id dirty-kind changed-keys
                    impact-vector))
        owner)
    (while (and candidate (not owner))
      (if (ebox--cached-patchable-owner-p buffer candidate dirty-kind)
          (setq owner candidate)
        (setq candidate (ebox--runtime-parent-id buffer candidate))))
    owner))

(defun ebox--promote-to-span-patchable-owner
    (buffer node-id &optional dirty-kind changed-keys)
  "Return the smallest structural owner worth one verified span-patch attempt."
  (let ((candidate node-id)
        (root-id (ebox--buffer-root-node-id buffer))
        owner)
    (ignore dirty-kind)
    (while (and candidate (not owner))
      (cond
       ((equal candidate root-id)
        (setq candidate nil))
       ((and (ebox--span-patchable-owner-p buffer candidate)
             (let ((parent-id (ebox--runtime-parent-id buffer candidate)))
               (or (not (ebox--geometry-affects-parent-layout-p
                         buffer candidate))
                   (not parent-id)
                   (and (not (equal candidate node-id))
                        (ebox--inline-size-change-p changed-keys)
                        (not
                         (ebox--dirty-node-is-owner-style-source-p
                          buffer node-id candidate))
                        (ebox--definite-containment-formatting-context-p
                         buffer candidate))
                   (ebox--flex-item-slot-safe-p
                    buffer candidate changed-keys
                    (equal candidate node-id)))))
        (setq owner candidate))
       (t
        (setq candidate (ebox--runtime-parent-id buffer candidate)))))
    owner))

(defun ebox--block-size-change-p (changed-keys)
  "Return non-nil when CHANGED-KEYS contains only block-size constraints."
  (and changed-keys
       (cl-every (lambda (key)
                   (memq key '(:height :min-height :max-height)))
                 changed-keys)))

(defun ebox--block-size-containment-owner-id (buffer node-id)
  "Return NODE-ID's nearest strict fixed partial-flex containment owner."
  (let ((candidate (ebox--runtime-parent-id buffer node-id))
        (root-id (ebox--buffer-root-node-id buffer))
        owner)
    (while (and candidate (not owner))
      (cond
       ((equal candidate root-id)
        (setq candidate nil))
       ((and (ebox--contained-partial-flex-owner-p buffer candidate)
             (ebox--span-patchable-owner-p buffer candidate))
        (setq owner candidate))
       (t
        (setq candidate (ebox--runtime-parent-id buffer candidate)))))
    owner))

(defun ebox--runtime-child-under-ancestor (buffer ancestor-id node-id)
  "Return the direct child id under ANCESTOR-ID on NODE-ID's runtime path."
  (let ((child-id node-id)
        (parent-id (ebox--runtime-parent-id buffer node-id))
        found)
    (while (and parent-id (not found))
      (if (equal parent-id ancestor-id)
          (setq found child-id)
        (setq child-id parent-id
              parent-id (ebox--runtime-parent-id buffer parent-id))))
    found))

(defun ebox--skip-flex-span-probe-p (buffer entry owner-id)
  "Return non-nil when a flex OWNER-ID span probe would duplicate rerender work."
  (let ((node-id (plist-get entry :node-id))
        (changed-keys (plist-get entry :changed-keys)))
    (and (eq (plist-get entry :dirty-kind) 'geometry)
         changed-keys
         (when-let* ((owner (ebox--buffer-runtime-node buffer owner-id))
                     ((eq (ebox--display-inner owner) 'flex))
                     ((or (equal owner-id node-id)
                          (not
                           (and
                            (or (ebox--inline-size-change-p changed-keys)
                                (ebox--block-size-change-p changed-keys))
                            (ebox--definite-containment-formatting-context-p
                             buffer owner-id)))))
                     (child-id
                      (ebox--runtime-child-under-ancestor
                       buffer owner-id node-id)))
           (and (ebox--direct-flex-parent-p buffer child-id)
                (not (ebox--flex-item-slot-safe-p
                      buffer child-id changed-keys)))))))

(defun ebox--span-patch-owner-id-for-dirty-entry (entry buffer)
  "Return a local span patch owner for ENTRY in BUFFER, or nil."
  (let* ((node-id (plist-get entry :node-id))
         (dirty-kind (plist-get entry :dirty-kind))
         (impact-vector (or (plist-get entry :impact-vector)
                            (and (plist-get entry :changed-keys)
                                 (ebox--dirty-entry-impact-vector
                                  buffer entry)))))
    (unless (ebox--impact-vector-requires-conservative-owner-p impact-vector)
      (cond
       ((and (ebox--dirty-entry-span-patch-candidate-p buffer entry)
             (not (cl-some
                   (lambda (key)
                     (memq key ebox--span-patch-border-box-block-keys))
                   (plist-get entry :changed-keys)))
             (ebox--cached-patchable-owner-p buffer node-id 'span)
             (or (not (ebox--direct-flex-parent-p buffer node-id))
                 (ebox--flex-item-slot-safe-p
                  buffer node-id (plist-get entry :changed-keys) t)))
        node-id)
       ((and (eq dirty-kind 'geometry)
             (plist-get entry :changed-keys))
        (let ((owner-id
               (or (and (ebox--block-size-change-p
                         (plist-get entry :changed-keys))
                        (ebox--block-size-containment-owner-id
                         buffer node-id))
                   (ebox--promote-to-span-patchable-owner
                    buffer node-id dirty-kind
                    (plist-get entry :changed-keys)))))
          (unless (and owner-id
                       (ebox--skip-flex-span-probe-p buffer entry owner-id))
            owner-id)))))))

(defun ebox--make-patch-op-merge-index ()
  "Return fresh mutable state for indexed patch-op antichain merging."
  (list :owner-table (make-hash-table :test 'equal)
        :ancestor-table (make-hash-table :test 'equal)
        :serial 0))

(defun ebox--patch-op-merge-index-insert (buffer index entry)
  "Register ENTRY (a vector [OP SERIAL ANCESTOR-SET]) into INDEX."
  (puthash (plist-get (aref entry 0) :owner-id)
           entry (plist-get index :owner-table))
  (let ((ancestor-table (plist-get index :ancestor-table)))
    (maphash (lambda (ancestor-id _present)
               (push entry (gethash ancestor-id ancestor-table)))
             (aref entry 2)))
  (ignore buffer))

(defun ebox--patch-op-merge-index-remove (index entry)
  "Remove ENTRY from INDEX."
  (remhash (plist-get (aref entry 0) :owner-id)
           (plist-get index :owner-table))
  (let ((ancestor-table (plist-get index :ancestor-table)))
    (maphash (lambda (ancestor-id _present)
               (puthash ancestor-id
                        (delq entry (gethash ancestor-id ancestor-table))
                        ancestor-table))
             (aref entry 2))))

(defun ebox--patch-op-merge-index-add (buffer index candidate)
  "Merge CANDIDATE into indexed antichain INDEX for BUFFER.
Preserves `ebox--merge-patch-op-into-set' semantics exactly: a
same-owner op merges by strength first, then the earliest-inserted
op at an ancestor with span strength or better absorbs the candidate,
otherwise the candidate absorbs every entry below it (in insertion
order) and joins the set.  Ancestor relations resolve through the
per-node ancestor sets, so each insertion costs one walk plus
hash lookups instead of a scan of the whole set."
  (let* ((owner-table (plist-get index :owner-table))
         (owner-id (plist-get candidate :owner-id))
         (same-owner (gethash owner-id owner-table)))
    (when same-owner
      (setq candidate (ebox--merge-same-owner-patch-ops
                       (aref same-owner 0) candidate))
      (ebox--patch-op-merge-index-remove index same-owner))
    (let* ((ancestors (ebox--runtime-ancestor-id-set buffer owner-id))
           (dominator nil))
      (maphash
       (lambda (ancestor-id _present)
         (when-let ((entry (gethash ancestor-id owner-table)))
           (when (and (>= (ebox--patch-operation-strength
                           (plist-get (aref entry 0) :op))
                          (ebox--patch-operation-strength 'span-patch))
                      (or (null dominator)
                          (< (aref entry 1) (aref dominator 1))))
             (setq dominator entry))))
       ancestors)
      (if dominator
          (aset dominator 0
                (ebox--patch-op-merge-dirty (aref dominator 0) candidate))
        (when (>= (ebox--patch-operation-strength
                   (plist-get candidate :op))
                  (ebox--patch-operation-strength 'span-patch))
          (dolist (entry (sort (copy-sequence
                                (gethash owner-id
                                         (plist-get index :ancestor-table)))
                               (lambda (a b) (< (aref a 1) (aref b 1)))))
            (setq candidate
                  (ebox--patch-op-merge-dirty candidate (aref entry 0)))
            (ebox--patch-op-merge-index-remove index entry)))
        (let ((entry (vector candidate
                             (plist-get index :serial)
                             ancestors)))
          (plist-put index :serial (1+ (plist-get index :serial)))
          (ebox--patch-op-merge-index-insert buffer index entry))))))

(defun ebox--patch-op-merge-index-result (index)
  "Return INDEX's surviving ops in insertion order."
  (let (entries)
    (maphash (lambda (_owner-id entry) (push entry entries))
             (plist-get index :owner-table))
    (mapcar (lambda (entry) (aref entry 0))
            (sort entries (lambda (a b) (< (aref a 1) (aref b 1)))))))

(defun ebox--dedupe-patch-owners (buffer ops)
  "Merge same-owner OPS and remove structurally covered descendants in BUFFER."
  (let ((index (ebox--make-patch-op-merge-index)))
    (dolist (op ops)
      (ebox--patch-op-merge-index-add buffer index op))
    (ebox--patch-op-merge-index-result index)))


(defun ebox--next-patchable-owner-ancestor
    (buffer owner-id dirty-kind &optional require-owned-overflow-coverage)
  "Return the nearest non-root patchable ancestor above OWNER-ID.
When REQUIRE-OWNED-OVERFLOW-COVERAGE is non-nil, skip ancestors whose wrapper
cannot cover an old unowned visible-overflow suffix."
  (let ((candidate (ebox--runtime-parent-id buffer owner-id))
        (root-id (ebox--buffer-root-node-id buffer))
        owner)
    (while (and candidate (not owner))
      (cond
       ((equal candidate root-id)
        (setq candidate nil))
       ((and (or (not require-owned-overflow-coverage)
                 (ebox--owned-overflow-coverage-wrapper-node-p
                  buffer candidate))
             (ebox--cached-patchable-owner-p
              buffer candidate dirty-kind require-owned-overflow-coverage))
        (setq owner candidate))
       (t
        (setq candidate (ebox--runtime-parent-id buffer candidate)))))
    owner))

(defun ebox--patch-results-strategy (results)
  "Return aggregate update strategy for executed patch RESULTS."
  (cond
   ((cl-some (lambda (result)
               (eq (plist-get result :op) 'owner-rerender))
             results)
    'owner-rerender)
   ((cl-some (lambda (result)
               (eq (plist-get result :op) 'span-patch))
             results)
    'span-patch)
   ((cl-some (lambda (result)
               (eq (plist-get result :op) 'child-splice))
             results)
    'child-splice)
   ((cl-some (lambda (result)
               (eq (plist-get result :op) 'child-reorder))
             results)
    'child-reorder)
   ((cl-every (lambda (result)
                (eq (plist-get result :op) 'paint-patch))
              results)
    'paint-patch)
   (t 'owner-rerender)))

(defun ebox--viewport-dependent-size-value-p (value &optional nil-dependent)
  "Return non-nil when horizontal size VALUE depends on viewport context.
When NIL-DEPENDENT is non-nil, nil is treated as viewport-dependent auto width."
  (or (and nil-dependent (null value))
      (and nil-dependent (eq value 'auto))
      (memq value '(stretch contain fit-content viewport))
      (and (consp value)
           (or (eq (car value) 'viewport)
               (and (eq (car value) 'fit-content)
                    (ebox--viewport-dependent-size-value-p (cadr value)))))))

(defun ebox--viewport-dependent-height-value-p (value)
  "Return non-nil when vertical size VALUE depends on viewport height."
  (or (eq value 'viewport-height)
      (and (consp value)
           (or (eq (car value) 'viewport-height)
               (and (memq (car value) '(+ -))
                    (cl-some #'ebox--viewport-dependent-height-value-p
                             (cdr value)))))))

(defun ebox--viewport-dependent-height-props-p (props)
  "Return non-nil when PROPS has a viewport-height size constraint."
  (cl-some
   (lambda (property)
     (ebox--viewport-dependent-height-value-p
      (plist-get props property)))
   '(:height :min-height :max-height)))

(defun ebox--node-direct-viewport-height-dependent-p (node)
  "Return non-nil when NODE's own vertical size uses viewport height."
  (when (and (listp node)
             (not (stringp node)))
    (pcase (plist-get node :ebox-type)
      ('box
       (ebox--viewport-dependent-height-props-p node))
      ('flex
       (or (ebox--viewport-dependent-height-props-p
            (plist-get node :props))
           (ebox--viewport-dependent-height-props-p
            (plist-get node :raw-props)))))))

(defun ebox--flex-participation-viewport-dependent-p (node)
  "Return non-nil when NODE's flex item metadata depends on viewport context."
  (when-let ((participation (ebox--flex-participation-props node)))
    (ebox--viewport-dependent-size-value-p
     (plist-get participation :flex-basis))))

(defun ebox--node-direct-viewport-width-dependent-p (node)
  "Return non-nil when NODE's own layout depends on viewport width."
  (when (listp node)
    (or (ebox--flex-participation-viewport-dependent-p node)
        (unless (eq (plist-get node :ebox-type) 'flex-item)
          (cond
           ((eq (ebox--display-inner node) 'flex)
            (ebox--viewport-dependent-size-value-p
             (plist-get (plist-get node :props) :width) t))
           ((eq (ebox--display-inner node) 'flow)
            (or (ebox--viewport-dependent-size-value-p
                 (plist-get node :width) t)
                (ebox--viewport-dependent-size-value-p
                 (plist-get node :min-width))
                (ebox--viewport-dependent-size-value-p
                 (plist-get node :max-width)))))))))

(defun ebox--node-direct-viewport-dependent-p (node)
  "Return non-nil when NODE's own layout depends on viewport context."
  (or (ebox--node-direct-viewport-width-dependent-p node)
      (ebox--node-direct-viewport-height-dependent-p node)))

(defun ebox--viewport-height-dependent-subtree-p (node)
  "Return non-nil when NODE or a descendant depends on viewport height."
  (when (and (listp node)
             (not (stringp node)))
    (cl-labels
        ((compute ()
           (or (ebox--node-direct-viewport-height-dependent-p node)
               (cl-some #'ebox--viewport-height-dependent-subtree-p
                        (ebox--node-children node)))))
      (if (not ebox--viewport-height-dependent-subtree-cache)
          (compute)
        (let* ((missing (make-symbol "ebox-viewport-height-subtree-missing"))
               (cached
                (gethash node ebox--viewport-height-dependent-subtree-cache
                         missing)))
          (if (not (eq cached missing))
              cached
            (puthash node (compute)
                     ebox--viewport-height-dependent-subtree-cache)))))))

(defun ebox--viewport-dependent-subtree-p (node)
  "Return non-nil when NODE or any descendant depends on viewport width."
  (when (and (listp node)
             (not (stringp node)))
    (if (not ebox--viewport-dependent-subtree-cache)
        (or (ebox--node-direct-viewport-width-dependent-p node)
            (cl-some #'ebox--viewport-dependent-subtree-p
                     (ebox--node-children node)))
      (let* ((missing (make-symbol "ebox-viewport-subtree-missing"))
             (cached (gethash node ebox--viewport-dependent-subtree-cache
                              missing)))
        (if (not (eq cached missing))
            cached
          (puthash
           node
           (or (ebox--node-direct-viewport-width-dependent-p node)
               (cl-some #'ebox--viewport-dependent-subtree-p
                        (ebox--node-children node)))
           ebox--viewport-dependent-subtree-cache))))))

(defun ebox--viewport-dependent-node-id-axes (node)
  "Return (WIDTH-IDS . HEIGHT-IDS) below NODE.
Definite width contains descendant width ids, but not height ids."
  (when (and (listp node)
             (not (stringp node)))
    (cl-labels
        ((collect ()
           (let* ((width-direct
                   (ebox--node-direct-viewport-width-dependent-p node))
                  (vertical
                   (ebox--node-direct-viewport-height-dependent-p node))
                  (contained
                   (ebox--render-cache-contained-viewport-node-p node))
                  (children (ebox--node-children node))
                  (relevant-children
                   (if contained
                       (cl-remove-if-not
                        #'ebox--viewport-height-dependent-subtree-p
                        children)
                     children))
                  (child-axes
                   (mapcar #'ebox--viewport-dependent-node-id-axes
                           relevant-children))
                  (node-id (and (or width-direct vertical)
                                (ebox--ensure-node-id node))))
             (cons
              (append
               (when width-direct
                 (list node-id))
               (unless contained
                 (apply #'append (mapcar #'car child-axes))))
              (append
               (when vertical
                 (list node-id))
               (apply #'append (mapcar #'cdr child-axes)))))))
      (if (not ebox--viewport-dependent-node-ids-cache)
          (collect)
        (let* ((missing (make-symbol "ebox-viewport-dependent-missing"))
               (cached (gethash node ebox--viewport-dependent-node-ids-cache
                                missing)))
          (if (not (eq cached missing))
              cached
            (puthash node (collect)
                     ebox--viewport-dependent-node-ids-cache)))))))

(defun ebox--viewport-dependent-node-ids (node)
  "Return runtime node ids under NODE that depend on viewport context."
  (when-let ((axes (ebox--viewport-dependent-node-id-axes node)))
    (delete-dups (copy-sequence (append (car axes) (cdr axes))))))

(defun ebox--viewport-dirty-set (root)
  "Return viewport dirty-set entries for ROOT."
  (mapcar (lambda (node-id)
            (ebox--dirty-entry node-id 'geometry))
          (delete-dups
           (copy-sequence (ebox--viewport-dependent-node-ids root)))))

(defun ebox--viewport-constraint-change (buffer &optional axes)
  "Return the implicit viewport constraint change for BUFFER.
AXES may be `width', `height', `both', or `none'.  Nil means both axes for
legacy callers."
  (when-let ((root (ebox--buffer-root-node buffer)))
    (let* ((node-ids
            (pcase axes
              ('width
               (car (ebox--buffer-viewport-dependent-node-id-axes buffer)))
              ('height
               (cdr (ebox--buffer-viewport-dependent-node-id-axes buffer)))
              ('none nil)
              (_
               (ebox--buffer-viewport-dependent-node-ids buffer))))
           (node-ids (delete-dups (copy-sequence node-ids)))
           (root-node-id (ebox--ensure-node-id root))
           (coalesced
            (>= (length node-ids) ebox--owner-coalesce-min-count))
           (dirty-set
            (if coalesced
                (list (ebox--dirty-entry
                       root-node-id 'geometry :node-ids node-ids))
              (mapcar (lambda (node-id)
                        (ebox--dirty-entry node-id 'geometry))
                      node-ids))))
      (ebox--constraint-change
       'viewport 'viewport 'viewport
       root-node-id dirty-set
       :coalesced-dirty-count (and coalesced (length node-ids))))))

(defun ebox--region-update-dirty-kind (changed-keys)
  "Return the dirty kind for CHANGED-KEYS from `ebox-region-update'."
  (if (cl-every (lambda (key)
                  (memq key ebox--paint-style-signature-keys))
                changed-keys)
      'paint
    'geometry))

(defun ebox--region-constraint-change
    (buffer region-id dirty-kind &optional changed-keys old-style-values)
  "Return the explicit region constraint change for REGION-ID in BUFFER."
  (when-let* ((root (ebox--buffer-root-node buffer))
              (dirty-node
               (ebox--buffer-region-render-owner-node buffer region-id))
              (dirty-node-id (ebox--ensure-node-id dirty-node)))
    (let ((dirty-entry
           (ebox--dirty-entry dirty-node-id dirty-kind
                              :region-id region-id
                              :changed-keys changed-keys
                              :old-style-values old-style-values
                              :region-ids
                              (and (eq dirty-kind 'paint)
                                   (ebox--node-all-region-ids dirty-node)))))
      (ebox--constraint-change
       'region dirty-node-id (plist-get dirty-node :ebox-type)
       (ebox--ensure-node-id root)
       (list (ebox--dirty-entry-with-impact-vector buffer dirty-entry))
       :region-id region-id))))

(defun ebox--update-report (region-id strategy &rest props)
  "Build an update report for REGION-ID using STRATEGY and PROPS."
  (append (list :region-id region-id
                :strategy strategy
                :full-rerender (eq strategy 'full-rerender))
          props
          (when ebox-cache-report-buffer
            (ebox-cache-report ebox-cache-report-buffer))))

(defun ebox-incremental--batch-state (buffer)
  "Return explicit batch state for BUFFER."
  (gethash buffer ebox-incremental--batch-table))

(defun ebox-incremental-batching-p (buffer)
  "Return non-nil when BUFFER is inside an explicit incremental batch."
  (and (buffer-live-p buffer)
       (plist-get (ebox-incremental--batch-state buffer) :active)))

(defun ebox-incremental-begin-batch (buffer)
  "Begin an explicit incremental update batch for BUFFER."
  (unless (buffer-live-p buffer)
    (error "ebox-incremental: buffer is not live: %S" buffer))
  (let ((state (list :active t
                     :pending nil
                     :flush-count 0
                     :surface-candidate-root nil
                     :surface-publisher nil)))
    (puthash buffer state ebox-incremental--batch-table)
    state))

(defun ebox-incremental-pending-count (buffer)
  "Return the number of pending explicit batch changes for BUFFER."
  (length (plist-get (ebox-incremental--batch-state buffer) :pending)))

(defun ebox-incremental-surface-batch-root (buffer)
  "Return BUFFER's unpublished surface batch root, or nil."
  (plist-get (ebox-incremental--batch-state buffer)
             :surface-candidate-root))

(defun ebox-incremental-record-surface-region-change
    (buffer candidate-root region-id handle dirty-kind changed-keys
            old-style-values publisher)
  "Record one surface-scoped change for BUFFER's explicit batch.
CANDIDATE-ROOT is the accumulated unpublished tree.  REGION-ID and HANDLE
identify the logical target, DIRTY-KIND, CHANGED-KEYS, and OLD-STYLE-VALUES
describe the semantic change, and PUBLISHER commits the complete batch once
during `ebox-incremental-flush'."
  (when (ebox-incremental-batching-p buffer)
    (let ((state (ebox-incremental--batch-state buffer)))
      (plist-put state :surface-candidate-root candidate-root)
      (plist-put state :surface-publisher publisher)
      (plist-put state :pending
                 (append
                  (plist-get state :pending)
                  (list (list :region-id region-id
                              :region-handle handle
                              :dirty-kind dirty-kind
                              :changed-keys changed-keys
                              :old-style-values old-style-values))))
      t)))

(defun ebox-incremental--merge-old-style-values (old-values additions)
  "Merge ADDITIONS into OLD-VALUES while preserving each first old value."
  (let ((merged (copy-sequence old-values))
        (additions (copy-sequence additions)))
    (while additions
      (let ((key (pop additions))
            (value (pop additions)))
        (unless (plist-member merged key)
          (setq merged (append merged (list key value))))))
    merged))

(defun ebox-incremental--batch-dirty-set (buffer pending)
  "Return a dirty set for BUFFER from PENDING batch entries."
  (let ((seen (make-hash-table :test 'equal))
        dirty-set)
    (dolist (entry pending)
      (when-let* ((region-id (plist-get entry :region-id))
                  (dirty-kind (plist-get entry :dirty-kind))
                  (dirty-node
                   (ebox--buffer-region-render-owner-node buffer region-id))
                  (node-id (ebox--ensure-node-id dirty-node)))
        (let* ((key (list node-id dirty-kind))
               (changed-keys (plist-get entry :changed-keys))
               (existing (gethash key seen)))
          (if existing
              (progn
                (plist-put
                 existing :changed-keys
                 (delete-dups
                  (append (copy-sequence
                           (or (plist-get existing :changed-keys) nil))
                          (copy-sequence changed-keys))))
                (plist-put
                 existing :old-style-values
                 (ebox-incremental--merge-old-style-values
                  (plist-get existing :old-style-values)
                  (plist-get entry :old-style-values)))
                (ebox--dirty-entry-with-impact-vector buffer existing))
            (let ((dirty-entry
                   (ebox--dirty-entry
                    node-id dirty-kind
                    :region-id region-id
                    :changed-keys changed-keys
                    :old-style-values (plist-get entry :old-style-values)
                    :region-ids
                    (and (eq dirty-kind 'paint)
                         (ebox--node-all-region-ids dirty-node)))))
              (setq dirty-entry
                    (ebox--dirty-entry-with-impact-vector buffer dirty-entry))
              (puthash key dirty-entry seen)
              (push dirty-entry dirty-set))))))
    (nreverse dirty-set)))

(defun ebox-incremental--batch-change (buffer pending)
  "Return a normalized batch constraint change for BUFFER and PENDING."
  (when-let ((root (ebox--buffer-root-node buffer)))
    (ebox--constraint-change
     'batch 'batch 'batch
     (ebox--ensure-node-id root)
     (ebox-incremental--batch-dirty-set buffer pending))))

(defun ebox-incremental-flush (buffer)
  "Flush BUFFER's explicit incremental update batch."
  (unless (buffer-live-p buffer)
    (error "ebox-incremental: buffer is not live: %S" buffer))
  (let* ((state (ebox-incremental--batch-state buffer))
         (pending (plist-get state :pending))
         (surface-publisher (plist-get state :surface-publisher)))
    (unless state
      (error "ebox-incremental: no active batch for buffer: %S" buffer))
    (plist-put state :active nil)
    (plist-put state :pending nil)
    (plist-put state :flush-count
               (1+ (or (plist-get state :flush-count) 0)))
    (if (null pending)
        (ebox--set-buffer-update-report
         buffer
         (ebox--update-report nil 'no-op
                              :dirty-count 0
                              :patch-count 0
                              :patch-ops nil
                              :flush-count 1))
      (ebox--invalidate-buffer-viewport-dependencies buffer)
      (unless surface-publisher
        (error "Ebox batch has no TP surface publisher"))
      (let (report)
        (unwind-protect
            (setq report
                  (funcall
                   surface-publisher buffer
                   (plist-get state :surface-candidate-root) pending))
          ;; A quit or render error during execution must leave the
          ;; batch active with its recorded changes still pending so a
          ;; later retry cannot silently publish a no-op.  If execution
          ;; returned a report, including an explicit no-op report, the
          ;; flush completed and the batch should close normally.
          (when (null report)
            (plist-put state :active t)
            (plist-put state :pending pending)
            (plist-put state :flush-count
                       (1- (plist-get state :flush-count)))))
        (setq report
              (append report
                      (list :flush-count 1
                            :batched-count (length pending))))
        (ebox--set-buffer-update-report buffer report)
        (when (and report
                   (not (eq (plist-get report :strategy) 'no-op)))
          (unless (plist-get report :runtime-published)
            (ebox--bump-buffer-runtime-revision buffer))
          (run-hook-with-args
           'ebox-incremental--after-successful-batch-flush-hook
           buffer pending report))
        (ebox--buffer-update-report buffer)))))

;;; Declarative Root Commit

(defun ebox-incremental-candidate-begin (buffer)
  "Return a logical one-shot candidate based on BUFFER's current runtime."
  (unless (buffer-live-p buffer)
    (error "Ebox candidate requires a live buffer: %S" buffer))
  (let ((state (ebox--buffer-render-state buffer)))
    (unless state
      (error "Ebox buffer has no rendered runtime: %S" buffer))
    (ebox-incremental--make-candidate
     :buffer buffer
     :base-state state
     :base-root (plist-get state :root-node)
     :base-revision (or (plist-get state :runtime-revision) 0)
     :base-buffer-tick
     (with-current-buffer buffer (buffer-modified-tick))
     :replacements nil
     :sealed-p nil)))

(defun ebox-incremental--candidate-ancestor-p
    (candidate ancestor-id descendant-id)
  "Return non-nil when ANCESTOR-ID contains DESCENDANT-ID in CANDIDATE's base."
  (let* ((state (ebox-candidate--base-state candidate))
         (parent-table (plist-get state :parent-table))
         (current (gethash descendant-id parent-table))
         found)
    (while (and current (not found))
      (if (equal current ancestor-id)
          (setq found t)
        (setq current (gethash current parent-table))))
    found))

(defun ebox-incremental-candidate-replace
    (candidate node-id next-subtree
               &optional old-semantic-key new-semantic-key)
  "Replace NODE-ID in CANDIDATE with an isolated copy of NEXT-SUBTREE.

Repeated replacement of one anchor is last-wins.  A later ancestor supersedes
earlier descendants; a later descendant is applied inside an earlier ancestor.
When both OLD-SEMANTIC-KEY and NEW-SEMANTIC-KEY are non-nil, they identify
detached semantic variants of this stable anchor for bounded identity reuse."
  (unless (ebox-candidate-p candidate)
    (error "Ebox candidate replacement requires an Ebox candidate"))
  (when (ebox-candidate--sealed-p candidate)
    (error "Ebox candidate is already sealed"))
  (unless (eq (null old-semantic-key) (null new-semantic-key))
    (error "Ebox semantic replacement requires both old and new keys"))
  (let* ((state (ebox-candidate--base-state candidate))
         (node-table (plist-get state :node-table))
         retained)
    (unless (gethash node-id node-table)
      (error "Ebox candidate anchor does not exist: %S" node-id))
    (unless (and (listp next-subtree) (not (stringp next-subtree)))
      (error "Ebox candidate replacement must be an Ebox node"))
    ;; Validate before copying so reused objects and cycles remain observable.
    (ebox-tree-validate-declarative-root next-subtree)
    (let ((replacement
           (ebox-tree-clear-runtime-identities
            (ebox-tree-copy-node-structure next-subtree))))
      ;; The new operation supersedes an earlier operation at the same anchor
      ;; and every earlier descendant operation.  An earlier ancestor stays
      ;; before a new descendant so the descendant is applied inside its
      ;; candidate-owned subtree at commit time instead of being discarded.
      (dolist (entry (ebox-candidate--replacements candidate))
        (let ((existing-id
               (ebox-incremental--candidate-replacement-anchor-id entry)))
          (unless (or (equal existing-id node-id)
                      (ebox-incremental--candidate-ancestor-p
                       candidate node-id existing-id))
            (push entry retained))))
      (setf (ebox-candidate--replacements candidate)
            (append
             (nreverse retained)
             (list
              (ebox-incremental--make-candidate-replacement
               :anchor-id node-id
               :subtree replacement
               :old-semantic-key old-semantic-key
               :new-semantic-key new-semantic-key)))))
    candidate))

(defun ebox-incremental-candidate-replace-host-ref
    (candidate host-ref next-subtree
               &optional old-semantic-key new-semantic-key)
  "Replace HOST-REF in CANDIDATE with declarative NEXT-SUBTREE.

HOST-REF is resolved against the exact published base captured when CANDIDATE
was begun.  References introduced only by earlier candidate replacements are
not anchors for the same transaction.  OLD-SEMANTIC-KEY and NEW-SEMANTIC-KEY
have the same optional detached-identity meaning as in
`ebox-incremental-candidate-replace'."
  (unless (ebox-candidate-p candidate)
    (error "Ebox host-ref replacement requires an Ebox candidate"))
  (when (ebox-candidate--sealed-p candidate)
    (error "Ebox candidate is already sealed"))
  (let* ((missing (make-symbol "ebox-missing-host-ref"))
         (node-id
          (gethash host-ref
                   (plist-get (ebox-candidate--base-state candidate)
                              :host-ref-table)
                   missing)))
    (when (eq node-id missing)
      (error "Ebox candidate host ref does not exist: %S" host-ref))
    (ebox-incremental-candidate-replace
     candidate node-id next-subtree
     old-semantic-key new-semantic-key)))

(defun ebox-incremental--candidate-assert-current
    (candidate buffer old-state)
  "Reject CANDIDATE unless BUFFER still publishes its exact captured base."
  (unless (eq buffer (ebox-candidate--buffer candidate))
    (error "Ebox candidate belongs to another buffer"))
  (unless (eq old-state (ebox-candidate--base-state candidate))
    (error "Ebox candidate base state changed"))
  (let ((current-state (ebox--buffer-render-state buffer)))
    (unless (eq current-state (ebox-candidate--base-state candidate))
      (error "Ebox candidate is stale: runtime state changed"))
    (unless (eq (plist-get current-state :root-node)
                (ebox-candidate--base-root candidate))
      (error "Ebox candidate is stale: runtime root changed"))
    (unless (equal (or (plist-get current-state :runtime-revision) 0)
                   (ebox-candidate--base-revision candidate))
      (error "Ebox candidate is stale: runtime revision changed"))
    (with-current-buffer buffer
      (unless (= (buffer-modified-tick)
                 (ebox-candidate--base-buffer-tick candidate))
        (error "Ebox candidate is stale: buffer changed")))))

(defun ebox-incremental--candidate-path-index (root)
  "Return node and parent tables for path-copying runtime ROOT.
This intentionally omits root-global semantic validation; only the final
logical tree crosses that boundary."
  (let ((node-table (make-hash-table :test 'equal))
        (parent-table (make-hash-table :test 'equal)))
    (cl-labels
        ((visit (node parent-id)
           (when (and (listp node) (not (stringp node)))
             (let ((node-id (ebox--ensure-node-id node)))
               (puthash node-id node node-table)
               (when parent-id
                 (puthash node-id parent-id parent-table))
               (dolist (child (ebox-tree--children-raw node))
                 (visit child node-id))))))
      (visit root nil))
    (list :node-table node-table :parent-table parent-table)))

(defun ebox-incremental--candidate-record-path-copy
    (base-node-id next-node parent-id anchor-p structure-p)
  "Record one candidate path copy when trace collection is active."
  (when (hash-table-p ebox-incremental--candidate-path-copy-trace)
    (let* ((origin-table
            ebox-incremental--candidate-path-copy-origin-table)
           (origin-node-id
            (if (hash-table-p origin-table)
                (or (gethash base-node-id origin-table) base-node-id)
              base-node-id))
           (existing
            (gethash origin-node-id
                     ebox-incremental--candidate-path-copy-trace)))
      (puthash
       origin-node-id
       (list :node next-node
             :parent-id parent-id
             :anchor-p (or anchor-p (plist-get existing :anchor-p))
             :structure-p
             (or structure-p (plist-get existing :structure-p)))
       ebox-incremental--candidate-path-copy-trace)
      (when (hash-table-p origin-table)
        (puthash origin-node-id origin-node-id origin-table)
        (puthash (plist-get next-node :node-id) origin-node-id
                 origin-table)))))

(defun ebox-incremental--candidate-path-copy-one
    (root node-id replacement index)
  "Return ROOT path-copied with NODE-ID replaced by REPLACEMENT."
  (let* ((node-table (plist-get index :node-table))
         (parent-table (plist-get index :parent-table))
         (old-child (gethash node-id node-table))
         (new-child replacement)
         (parent-id (gethash node-id parent-table)))
    (unless old-child
      (error "Ebox candidate anchor is absent after an ancestor replacement: %S"
             node-id))
    (ebox-incremental--candidate-record-path-copy
     node-id replacement parent-id t
     (not (equal (plist-get old-child :node-id)
                 (plist-get replacement :node-id))))
    (while parent-id
      (let* ((current-parent-id parent-id)
             (old-parent (gethash current-parent-id node-table))
             (new-parent
              (ebox-tree-copy-with-direct-child-replacements
               old-parent (list (cons old-child new-child))))
             (grandparent-id
              (gethash current-parent-id parent-table)))
        (ebox-incremental--candidate-record-path-copy
         current-parent-id new-parent grandparent-id nil
         (not (equal (plist-get old-child :node-id)
                     (plist-get new-child :node-id))))
        (setq old-child old-parent
              new-child new-parent
              parent-id grandparent-id)))
    (if (equal node-id (plist-get root :node-id))
        replacement
      new-child)))

(defun ebox-incremental--candidate-path-copy-many
    (root index replacements)
  "Return ROOT with node-id REPLACEMENTS applied by one bottom-up path copy."
  (let* ((node-table (plist-get index :node-table))
         (parent-table (plist-get index :parent-table))
         (direct (make-hash-table :test 'equal))
         (affected-table (make-hash-table :test 'equal))
         affected-ids)
    (maphash
     (lambda (node-id replacement)
       (let ((old-node (gethash node-id node-table))
             (parent-id (gethash node-id parent-table)))
         (unless old-node
           (error "Ebox candidate path-copy node is absent: %S" node-id))
         (ebox-incremental--candidate-record-path-copy
          node-id replacement parent-id t
          (not (equal (plist-get old-node :node-id)
                      (plist-get replacement :node-id))))
         (if parent-id
             (puthash parent-id
                      (cons (cons old-node replacement)
                            (gethash parent-id direct))
                      direct)
           (puthash node-id replacement direct))
         (while parent-id
           (unless (gethash parent-id affected-table)
             (puthash parent-id t affected-table)
             (push parent-id affected-ids))
           (setq parent-id (gethash parent-id parent-table)))))
     replacements)
    (let ((depth-table (make-hash-table :test 'equal)))
      (cl-labels
          ((depth
            (node-id)
            (or (gethash node-id depth-table)
                (let ((current node-id)
                      path
                      (result -1))
                  (while (and current
                              (not (gethash current depth-table)))
                    (push current path)
                    (setq current (gethash current parent-table)))
                  (when current
                    (setq result (gethash current depth-table)))
                  (dolist (path-id path)
                    (puthash path-id (cl-incf result) depth-table))
                  (gethash node-id depth-table)))))
        (setq affected-ids
              (sort affected-ids
                    (lambda (left right)
                      (> (depth left) (depth right)))))))
    (let ((result (gethash (plist-get root :node-id) replacements)))
      (dolist (parent-id affected-ids)
        (let* ((child-replacements (gethash parent-id direct))
               (old-parent (gethash parent-id node-table))
               (copy
                (ebox-tree-copy-with-direct-child-replacements
                 old-parent child-replacements))
               (grandparent-id (gethash parent-id parent-table)))
          (ebox-incremental--candidate-record-path-copy
           parent-id copy grandparent-id nil
           (cl-some
            (lambda (replacement)
              (not (equal (plist-get (car replacement) :node-id)
                          (plist-get (cdr replacement) :node-id))))
            child-replacements))
          (if grandparent-id
              (puthash grandparent-id
                       (cons (cons old-parent copy)
                             (gethash grandparent-id direct))
                       direct)
            (setq result copy))))
      (or result root))))

(defun ebox-incremental--candidate-replacements-disjoint-p
    (replacements parent-table)
  "Return non-nil when REPLACEMENTS have no ancestor relationship.

PARENT-TABLE belongs to the exact candidate base.  Every public replacement
anchor is resolved against that base, so disjointness can be proven without
building an index for an intermediate path-copied root."
  (cl-labels
      ((ancestor-p
        (ancestor-id descendant-id)
        (let ((current (gethash descendant-id parent-table))
              found)
          (while (and current (not found))
            (if (equal current ancestor-id)
                (setq found t)
              (setq current (gethash current parent-table))))
          found)))
    (cl-loop
     for tail on replacements
     always
     (cl-loop
      for right in (cdr tail)
      never
      (let ((left-id
             (ebox-incremental--candidate-replacement-anchor-id
              (car tail)))
            (right-id
             (ebox-incremental--candidate-replacement-anchor-id right)))
        (or (ancestor-p left-id right-id)
            (ancestor-p right-id left-id)))))))

(defun ebox-incremental--candidate-replacement-for-anchor
    (entries anchor-id)
  "Return the replacement in ENTRIES for ANCHOR-ID, or nil."
  (cl-find
   anchor-id entries
   :key #'ebox-incremental--candidate-replacement-anchor-id
   :test #'equal))

(defun ebox-incremental--validate-candidate-replacements
    (base-index entries)
  "Validate ENTRIES' cross-boundary identity against BASE-INDEX.
Each replacement subtree was internally validated when recorded; what
remains is the shared context the full-tree walk used to re-check on
every commit: the replacement's sibling key must stay unique under
its anchor's parent, and every host ref inside a replacement must be
either fresh or owned by a node that some replaced anchor is removing.
Cost is proportional to the replacements, never to the page."
  (let* ((node-table (plist-get base-index :node-table))
         (parent-table (plist-get base-index :parent-table))
         (host-ref-table (plist-get base-index :host-ref-table))
         (replacement-host-refs (make-hash-table :test 'equal))
         (anchor-ids
          (mapcar
           #'ebox-incremental--candidate-replacement-anchor-id
           entries)))
    (cl-labels
        ((inside-replaced-anchor-p (node-id)
           (let ((walk node-id))
             (while (and walk (not (member walk anchor-ids)))
               (setq walk (gethash walk parent-table)))
             walk))
         (collect-host-refs (node acc)
           (if (or (not (listp node)) (stringp node))
               acc
             (let ((ref (plist-get node :host-ref)))
               (when ref (push ref acc)))
             (dolist (child (ebox-tree--children-raw node) acc)
               (setq acc (collect-host-refs child acc))))))
      (dolist (entry entries)
        (let* ((node-id
                (ebox-incremental--candidate-replacement-anchor-id entry))
               (replacement
                (ebox-incremental--candidate-replacement-subtree entry))
               (replacement-key (plist-get replacement :key))
               (parent-id (gethash node-id parent-table))
               (parent (and parent-id (gethash parent-id node-table))))
          ;; Sibling keys stay unique under the anchor's parent.
          (when (and replacement-key parent)
            (dolist (sibling (ebox-tree--children-raw parent))
              (let ((sibling-id (plist-get sibling :node-id)))
                (when (and sibling-id
                           (not (equal sibling-id node-id))
                           (equal (plist-get
                                   (if-let
                                       ((sibling-replacement
                                         (ebox-incremental--candidate-replacement-for-anchor
                                          entries sibling-id)))
                                       (ebox-incremental--candidate-replacement-subtree
                                        sibling-replacement)
                                     sibling)
                                   :key)
                                  replacement-key))
                  (error
                   "Ebox declarative sibling key %S is not unique"
                   replacement-key)))))
          ;; Host refs must be fresh or freed by this same commit.
          (when host-ref-table
            (dolist (ref (collect-host-refs replacement nil))
              (let ((count (hash-table-count replacement-host-refs)))
                (puthash ref t replacement-host-refs)
                (when (= count (hash-table-count replacement-host-refs))
                  (error
                   "Ebox declarative host reference %S is not unique"
                   ref)))
              (when-let ((owner-id (gethash ref host-ref-table)))
                (unless (inside-replaced-anchor-p owner-id)
                  (error
                   "Ebox declarative host reference %S is not unique"
                   ref))))))))))

(defun ebox-incremental--copy-detached-history (state)
  "Return an unpublished detached identity history copied from STATE."
  (if-let ((history (plist-get state :detached-identity-history)))
      (ebox-incremental--make-detached-history
       :table
       (copy-hash-table
        (ebox-incremental--detached-history-table history))
       :order
       (copy-sequence
        (ebox-incremental--detached-history-order history))
       :node-count
       (ebox-incremental--detached-history-node-count history))
    (ebox-incremental--make-detached-history
     :table (make-hash-table :test 'equal)
     :order nil
     :node-count 0)))

(defun ebox-incremental--detached-history-store
    (history key snapshot)
  "Store SNAPSHOT under KEY in bounded detached identity HISTORY."
  (let* ((table (ebox-incremental--detached-history-table history))
         (existing (gethash key table))
         (count (ebox-incremental--detached-history-node-count history)))
    (when existing
      (cl-decf count (plist-get existing :node-count)))
    (puthash key snapshot table)
    (cl-incf count (plist-get snapshot :node-count))
    (setf (ebox-incremental--detached-history-order history)
          (append
           (cl-delete key
                      (ebox-incremental--detached-history-order history)
                      :test #'equal)
           (list key)))
    (setf (ebox-incremental--detached-history-node-count history) count)
    (while (or (> (hash-table-count table)
                  (max 0 ebox-incremental--detached-history-entry-limit))
               (> (ebox-incremental--detached-history-node-count history)
                  (max 0 ebox-incremental--detached-history-node-limit)))
      (let* ((oldest
              (pop (ebox-incremental--detached-history-order history)))
             (removed (gethash oldest table)))
        (remhash oldest table)
        (cl-decf (ebox-incremental--detached-history-node-count history)
                 (plist-get removed :node-count)))))
  history)

(defun ebox-incremental--detached-snapshot-safe-p
    (buffer state current-snapshot historical-snapshot)
  "Return non-nil when HISTORICAL-SNAPSHOT can reenter BUFFER's STATE.
CURRENT-SNAPSHOT identifies the subtree identities being replaced."
  (let ((current-node-ids (plist-get current-snapshot :node-id-set))
        (node-table (plist-get state :node-table))
        conflict)
    (maphash
     (lambda (node-id _present)
       (when (and (gethash node-id node-table)
                  (not (gethash node-id current-node-ids)))
         (setq conflict t)))
     (plist-get historical-snapshot :node-id-set))
    (and
     (not conflict)
     (not
      (ebox--runtime-region-id-conflict
       (plist-get historical-snapshot :region-id-set)
       buffer)))))

(defun ebox-incremental--reconcile-detached-replacement
    (candidate state entry old-anchor history)
  "Reconcile CANDIDATE's ENTRY with OLD-ANCHOR and STATE.
Use candidate-owned HISTORY for detached identity reuse."
  (let* ((replacement
          (ebox-incremental--candidate-replacement-subtree entry))
         (old-key
          (ebox-incremental--candidate-replacement-old-semantic-key entry))
         (new-key
          (ebox-incremental--candidate-replacement-new-semantic-key entry))
         (anchor-id
          (ebox-incremental--candidate-replacement-anchor-id entry)))
    (if (or (null history)
            (null old-key)
            (null new-key)
            (not (eq (plist-get old-anchor :ebox-type)
                     (plist-get replacement :ebox-type))))
        (ebox-tree-reconcile-runtime old-anchor replacement)
      (let* ((current (ebox-tree-runtime-identity-snapshot old-anchor))
             (old-history-key (list anchor-id old-key))
             (new-history-key (list anchor-id new-key)))
        (ebox-incremental--detached-history-store
         history old-history-key current)
        (let ((historical
               (gethash
                new-history-key
                (ebox-incremental--detached-history-table history))))
          (if (and historical
                   (eq (plist-get (plist-get historical :root) :ebox-type)
                       (plist-get replacement :ebox-type))
                   (ebox-incremental--detached-snapshot-safe-p
                    (ebox-candidate--buffer candidate)
                    state current historical))
              (progn
                (ebox-tree-reconcile-runtime
                 (plist-get historical :root) replacement)
                (ebox-tree-transfer-runtime-identity
                 old-anchor replacement))
            (ebox-tree-reconcile-runtime old-anchor replacement))))))
  (ebox-incremental--candidate-replacement-subtree entry))

(defun ebox-incremental--candidate-logical-root
    (candidate &optional detached-history)
  "Return CANDIDATE's complete logical root without copying unchanged subtrees.
DETACHED-HISTORY receives identity snapshots for semantic replacements."
  (let ((ebox-incremental--candidate-path-copy-origin-table
         (make-hash-table :test 'equal)))
    (let* ((root (ebox-candidate--base-root candidate))
           (state (ebox-candidate--base-state candidate))
           (base-index
            (list :node-table (plist-get state :node-table)
                  :parent-table (plist-get state :parent-table)
                  :host-ref-table (plist-get state :host-ref-table)))
           (entries (ebox-candidate--replacements candidate)))
      (if (ebox-incremental--candidate-replacements-disjoint-p
           entries (plist-get base-index :parent-table))
          (let ((replacements (make-hash-table :test 'equal)))
            (ebox-incremental--validate-candidate-replacements
             base-index entries)
            ;; Reconcile every independent anchor against the same published
            ;; base, then copy their shared ancestor paths in one bottom-up pass.
            (dolist (entry entries)
              (let* ((node-id
                      (ebox-incremental--candidate-replacement-anchor-id entry))
                     (old-anchor
                      (gethash node-id (plist-get base-index :node-table))))
                (unless old-anchor
                  (error "Ebox candidate anchor is absent: %S" node-id))
                ;; Replacements were validated when they were recorded
                ;; by `ebox-candidate-replace-host-ref'.
                (puthash
                 node-id
                 (ebox-incremental--reconcile-detached-replacement
                  candidate state entry old-anchor detached-history)
                 replacements)))
            (ebox-incremental--candidate-path-copy-many
             root base-index replacements))
        ;; Ancestor/descendant overlap is intentionally rare and order-sensitive:
        ;; a later descendant refines the earlier candidate-owned ancestor.
        (when (cl-some
               (lambda (entry)
                 (ebox-incremental--candidate-replacement-old-semantic-key
                  entry))
               entries)
          (error "Ebox semantic candidate replacements must be disjoint"))
        (let ((first-p t))
          (ebox-incremental--validate-candidate-replacements
           base-index entries)
          (dolist (entry entries)
            (let* ((node-id
                    (ebox-incremental--candidate-replacement-anchor-id entry))
                   (replacement
                    (ebox-incremental--candidate-replacement-subtree entry))
                   (index
                    (if first-p
                        base-index
                      (ebox-incremental--candidate-path-index root)))
                   (old-anchor
                    (gethash node-id (plist-get index :node-table))))
              (setq first-p nil)
              (unless old-anchor
                (error
                 "Ebox candidate anchor is absent after an ancestor replacement: %S"
                 node-id))
              (ebox-tree-reconcile-runtime old-anchor replacement)
              (setq root
                    (ebox-incremental--candidate-path-copy-one
                     root node-id replacement index))))
          root)))))

(defun ebox-incremental-consume-candidate (buffer-or-name candidate)
  "Consume CANDIDATE for BUFFER-OR-NAME and return its pure surface input.
The returned plist contains the prepared root, Ebox plan report, identity
policy, and runtime state overrides needed by the TP surface publisher.
CANDIDATE is sealed before target and staleness validation, so every attempted
commit consumes it even when later preparation fails."
  (unless (ebox-candidate-p candidate)
    (error "Ebox logical commit requires an Ebox candidate"))
  (when (ebox-candidate--sealed-p candidate)
    (error "Ebox candidate is already sealed"))
  (setf (ebox-candidate--sealed-p candidate) t)
  (let ((buffer (get-buffer buffer-or-name))
        (old-state (ebox-candidate--base-state candidate)))
    (unless (buffer-live-p buffer)
      (error "Ebox candidate commit requires a live buffer: %S"
             buffer-or-name))
    (ebox-incremental--candidate-assert-current candidate buffer old-state)
    (ebox-incremental--surface-commit-input
     buffer old-state
     (ebox-incremental--prepare-logical-candidate
      buffer old-state candidate))))

(defun ebox-incremental-prepare-root-commit (buffer-or-name next-root)
  "Prepare declarative NEXT-ROOT for TP publication in BUFFER-OR-NAME.
Return the same pure surface-input shape as
`ebox-incremental-consume-candidate'."
  (let* ((buffer (get-buffer buffer-or-name))
         (old-state (and buffer (ebox--buffer-render-state buffer))))
    (unless (buffer-live-p buffer)
      (error "Ebox declarative commit requires a live buffer: %S"
             buffer-or-name))
    (unless old-state
      (error "Ebox buffer has no rendered runtime: %S" buffer))
    (ebox-incremental--surface-commit-input
     buffer old-state
     (ebox-incremental--prepare-declarative-root
      buffer old-state next-root))))

(defun ebox-incremental--hash-keys (table)
  "Return the keys currently present in hash TABLE."
  (let (keys)
    (when (hash-table-p table)
      (maphash (lambda (key _value) (push key keys)) table))
    (nreverse keys)))

(defun ebox-incremental--hash-snapshot (table keys)
  "Return restorable entries for KEYS in hash TABLE."
  (let ((missing (make-symbol "missing"))
        entries)
    (dolist (key keys (nreverse entries))
      (let ((value (gethash key table missing)))
        (push (list key (not (eq value missing))
                    (unless (eq value missing) value))
              entries)))))

(defun ebox-incremental--restore-hash-snapshot (table entries)
  "Restore hash TABLE entries from ENTRIES."
  (dolist (entry entries)
    (if (nth 1 entry)
        (puthash (car entry) (nth 2 entry) table)
      (remhash (car entry) table))))

(defun ebox-incremental--replace-hash-entries (target keys source)
  "Replace TARGET entries under KEYS with every entry from SOURCE."
  (dolist (key keys)
    (remhash key target))
  (when (hash-table-p source)
    (maphash (lambda (key value) (puthash key value target)) source)))

(defun ebox-incremental--buffer-scroll-keys (buffer)
  "Return global scroll-state keys currently owned by BUFFER."
  (let (keys)
    (maphash
     (lambda (key state)
       (when (eq (plist-get state :buffer) buffer)
         (push key keys)))
     ebox--scroll-global-state)
    (nreverse keys)))

(defun ebox-incremental--candidate-layout-snapshots
    (old-state candidate-root candidate-index)
  "Seed CANDIDATE-ROOT snapshots from OLD-STATE's published geometry."
  (let* ((old-snapshots (plist-get old-state :layout-snapshots))
         (old-root (plist-get old-state :root-node))
         (old-root-id (plist-get old-root :node-id))
         (candidate-root-id (plist-get candidate-root :node-id))
         (candidate-node-table (plist-get candidate-index :node-table))
         (snapshots (make-hash-table :test 'equal)))
    (when (hash-table-p old-snapshots)
      (maphash
       (lambda (node-id _node)
         (when-let ((snapshot (gethash node-id old-snapshots)))
           (puthash node-id (copy-sequence snapshot) snapshots)))
       candidate-node-table)
      ;; A root type replacement receives a fresh runtime id, but its patch
      ;; owner still covers the currently published complete-buffer geometry.
      (unless (equal old-root-id candidate-root-id)
        (when-let ((snapshot (gethash old-root-id old-snapshots)))
          (setq snapshot (copy-sequence snapshot))
          (setq snapshot (plist-put snapshot :node-id candidate-root-id))
          (puthash candidate-root-id snapshot snapshots))))
    snapshots))

(defun ebox-incremental--candidate-scroll-state-table
    (buffer old-state candidate-index candidate-region-box-table)
  "Return retained BUFFER scroll state rebound to the candidate runtime."
  (let ((candidate-region-set (plist-get candidate-index :region-id-set))
        (scroll-state-table (make-hash-table :test 'equal)))
    (dolist
        (region-id
         (delete-dups
          (append (copy-sequence (plist-get old-state :scroll-region-ids))
                  (ebox-incremental--buffer-scroll-keys buffer))))
      (when-let* (((gethash region-id candidate-region-set))
                  (old-scroll-state (gethash region-id ebox--scroll-global-state))
                  (candidate-box
                   (gethash region-id candidate-region-box-table)))
        (let ((candidate-scroll-state (copy-sequence old-scroll-state)))
          (setq candidate-scroll-state
                (plist-put candidate-scroll-state :box candidate-box))
          (setq candidate-scroll-state
                (plist-put candidate-scroll-state :buffer buffer))
          (setq candidate-scroll-state
                (ebox--scroll-window-rebind-state-producers
                 candidate-scroll-state candidate-box))
          (puthash region-id candidate-scroll-state scroll-state-table))))
    scroll-state-table))

(defun ebox-incremental--node-child-ids-equal-p (old new)
  "Return non-nil when OLD and NEW have identical direct child runtime ids."
  (let ((old-children (ebox--node-children old))
        (new-children (ebox--node-children new))
        equal-p)
    (setq equal-p t)
    (while (and equal-p old-children new-children)
      (setq equal-p
            (equal (plist-get (car old-children) :node-id)
                   (plist-get (car new-children) :node-id)))
      (setq old-children (cdr old-children)
            new-children (cdr new-children)))
    (and equal-p (null old-children) (null new-children))))

(defun ebox-incremental--node-child-ids (node)
  "Return NODE's direct child runtime ids in render order."
  (mapcar #'ebox--ensure-node-id (ebox--node-children node)))

(defun ebox-incremental--pure-child-reorder-p (old-ids new-ids)
  "Return non-nil when OLD-IDS and NEW-IDS are one pure permutation."
  (when (and (> (length old-ids) 1)
             (= (length old-ids) (length new-ids))
             (not (equal old-ids new-ids)))
    (let ((remaining (make-hash-table :test 'equal))
          valid)
      (setq valid t)
      (dolist (node-id old-ids)
        (if (gethash node-id remaining)
            (setq valid nil)
          (puthash node-id t remaining)))
      (dolist (node-id new-ids)
        (if (gethash node-id remaining)
            (remhash node-id remaining)
          (setq valid nil)))
      (and valid (zerop (hash-table-count remaining))))))

(defun ebox-incremental--child-splice-p (old-ids new-ids)
  "Return non-nil when OLD-IDS and NEW-IDS are one insert or remove run."
  (when (and (not (equal old-ids new-ids))
             (not (ebox-incremental--pure-child-reorder-p old-ids new-ids)))
    (pcase-let ((`(,old-middle ,new-middle)
                 (ebox-incremental--child-list-middle old-ids new-ids)))
      (or (and old-middle (not new-middle))
          (and new-middle (not old-middle))))))

(defun ebox-incremental--child-list-middle (old-ids new-ids)
  "Return minimal changed middle child id ranges for OLD-IDS and NEW-IDS."
  (let* ((old (vconcat old-ids))
         (new (vconcat new-ids))
         (start 0)
         (old-end (length old))
         (new-end (length new)))
    (while (and (< start old-end)
                (< start new-end)
                (equal (aref old start) (aref new start)))
      (cl-incf start))
    (while (and (> old-end start)
                (> new-end start)
                (equal (aref old (1- old-end))
                       (aref new (1- new-end))))
      (cl-decf old-end)
      (cl-decf new-end))
    (list (append (cl-subseq old start old-end) nil)
          (append (cl-subseq new start new-end) nil))))

(defun ebox-incremental--direct-child-by-id (owner child-id)
  "Return OWNER's direct child with runtime CHILD-ID."
  (cl-find-if
   (lambda (child)
     (equal (ebox--ensure-node-id child) child-id))
   (ebox--node-children owner)))

(defun ebox-incremental--simple-new-child-splice-p
    (buffer owner-id dirty)
  "Return non-nil when DIRTY is a cheap vertical child splice."
  (when-let ((owner (ebox--buffer-runtime-node buffer owner-id)))
    (pcase-let* ((old-ids (plist-get dirty :old-child-ids))
                 (new-ids (plist-get dirty :new-child-ids))
                 (`(,_old-middle ,new-middle)
                  (ebox-incremental--child-list-middle old-ids new-ids)))
      (and (eq (plist-get owner :ebox-type) 'stack)
           (eq (ebox-tree-display-inner owner) 'column)
           (when-let ((snapshot
                       (ebox--ensure-layout-snapshot-spans
                        buffer owner-id)))
             (unless (with-current-buffer buffer
                       (ebox-buffer--partial-line-slots-p
                        (plist-get snapshot :buffer-spans)))
               (cl-every
                (lambda (child-id)
                  (let ((child
                         (ebox-incremental--direct-child-by-id
                          owner child-id)))
                    (and child (eq (plist-get child :ebox-type) 'box))))
                new-middle)))))))

(defun ebox-incremental--child-change-props
    (old-node new-node children-changed)
  "Return direct-child provenance for OLD-NODE and NEW-NODE when changed."
  (when children-changed
    (let ((old-ids (ebox-incremental--node-child-ids old-node))
          (new-ids (ebox-incremental--node-child-ids new-node)))
      (list :old-child-ids old-ids
            :new-child-ids new-ids
            :pure-child-reorder-p
            (ebox-incremental--pure-child-reorder-p old-ids new-ids)
            :child-splice-p
            (ebox-incremental--child-splice-p old-ids new-ids)))))

(defun ebox-incremental--declarative-dirty-kind (changed-keys)
  "Return a declarative dirty kind for CHANGED-KEYS."
  (cond
   ((and changed-keys
         (cl-every (lambda (key)
                     (memq key ebox-tree-metadata-source-keys))
                   changed-keys))
    'metadata)
   ((and changed-keys
         (cl-every (lambda (key)
                     (or (eq key :surface-properties)
                         (memq key ebox--paint-style-signature-keys)))
                   changed-keys))
    'paint)
   ((memq :display changed-keys) 'structure)
   (t 'geometry)))

(defun ebox-incremental--candidate-region-box-table (state)
  "Return STATE's buffer-owned region boxes from the active side table."
  (if-let* ((owned-table (plist-get state :region-box-table))
            ((hash-table-p owned-table)))
      (copy-hash-table owned-table)
    (let ((table (make-hash-table :test 'equal)))
      (when-let ((region-id-set (plist-get state :region-id-set)))
        (maphash
         (lambda (region-id _present)
           (when-let ((box (gethash region-id ebox--region-box-table)))
             (puthash region-id box table)))
         region-id-set))
      table)))

(defun ebox-incremental--candidate-base-index (state)
  "Return STATE's persistent indexes without copying unchanged core tables."
  (list :node-table (plist-get state :node-table)
        :parent-table (plist-get state :parent-table)
        :region-id-set (plist-get state :region-id-set)
        :region-node-table (plist-get state :region-node-table)
        :region-box-count-table (plist-get state :region-box-count-table)
        :region-box-table
        (ebox-incremental--candidate-region-box-table state)
        :host-ref-table (plist-get state :host-ref-table)
        :selector-id-table (plist-get state :selector-id-table)
        :selector-class-table (plist-get state :selector-class-table)
        :selector-type-table (plist-get state :selector-type-table)
        :runtime-type-count-table
        (plist-get state :runtime-type-count-table)
        :selector-index-stale-p
        (plist-get state :selector-index-stale-p)
        :native-node-postorder (plist-get state :native-node-postorder)))

(defun ebox-incremental--candidate-copy-index-table (state key test)
  "Return a materialized copy of STATE's hash table under KEY."
  (let ((table (plist-get state key)))
    (if (hash-table-p table)
        (copy-hash-table table)
      (make-hash-table :test test))))

(defun ebox-incremental--candidate-node-region-record (node)
  "Return NODE's `(REGION-ID OWNER-ID BOX)' record, or nil."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box
     (list (ebox--ensure-region-id node)
           (ebox--ensure-node-id node)
           node))
    ('flex
     (when-let ((box (plist-get node :box)))
       (list (ebox--ensure-region-id box)
             (ebox--ensure-node-id node)
             box)))))

(defun ebox-incremental--candidate-adjust-region-box-count
    (table node delta)
  "Adjust TABLE's box-object region count for NODE by DELTA."
  (when (eq (and (listp node) (plist-get node :ebox-type)) 'box)
    (let* ((region-id (ebox--ensure-region-id node))
           (count (+ (or (gethash region-id table) 0) delta)))
      (if (> count 0)
          (puthash region-id count table)
        (remhash region-id table)))))

(defun ebox-incremental--candidate-region-box-count-table (root)
  "Return complete box-object region multiplicities below legacy ROOT."
  (let ((table (make-hash-table :test 'equal)))
    (cl-labels
        ((visit (node)
           (when (and (listp node) (not (stringp node)))
             (ebox-incremental--candidate-adjust-region-box-count
              table node 1)
             (dolist (child (ebox--node-children node))
               (visit child)))))
      (visit root))
    table))

(defun ebox-incremental--candidate-recompute-regions
    (root region-ids region-id-set region-node-table region-box-table)
  "Recompute REGION-IDS below ROOT with complete traversal ordering.

This is the compatibility path for duplicated legacy region ids.  Core
logical-candidate updates stay local for unique ids; duplicates need the
complete preorder first-owner and postorder last-box semantics."
  (maphash
   (lambda (region-id _present)
     (remhash region-id region-id-set)
     (remhash region-id region-node-table)
     (remhash region-id region-box-table))
   region-ids)
  (cl-labels
      ((visit (node)
         (when (and (listp node) (not (stringp node)))
           (when-let ((record
                       (ebox-incremental--candidate-node-region-record node)))
             (pcase-let ((`(,region-id ,owner-id ,_box) record))
               (when (gethash region-id region-ids)
                 (puthash region-id t region-id-set)
                 (unless (gethash region-id region-node-table)
                   (puthash region-id owner-id region-node-table)))))
           (dolist (child (ebox--node-children node))
             (visit child))
           (when-let ((record
                       (ebox-incremental--candidate-node-region-record node)))
             (pcase-let ((`(,region-id ,_owner-id ,box) record))
               (when (gethash region-id region-ids)
                 (puthash region-id box region-box-table)))))))
    (visit root)))

(defun ebox-incremental--candidate-native-postorder (root)
  "Return ROOT's native compiler postorder without building other indexes."
  (let (postorder)
    (cl-labels
        ((visit (node native-layout-p)
           (when (and (listp node) (not (stringp node)))
             (let ((type (plist-get node :ebox-type)))
               (dolist (child (ebox--node-children node))
                 (visit child
                        (and native-layout-p
                             (not (and (eq type 'flex)
                                       (eq child (plist-get node :box)))))))
               (when (and native-layout-p (not (eq type 'flex-item)))
                 (push node postorder))))))
      (visit root t))
    (vconcat (nreverse postorder))))

(defun ebox-incremental--candidate-map-native-postorder
    (old-state candidate-node-table)
  "Re-key OLD-STATE's structurally stable native postorder to candidate nodes."
  (let ((old-postorder (plist-get old-state :native-node-postorder)))
    (if (vectorp old-postorder)
        (vconcat
         (mapcar
          (lambda (old-node)
            (or (gethash (plist-get old-node :node-id)
                         candidate-node-table)
                (error "Ebox candidate lost a structurally retained native node")))
          (append old-postorder nil)))
      nil)))

(defun ebox-incremental--candidate-dirty-set-from-touched
    (old-state candidate-root touched)
  "Return declarative dirty entries for path-local TOUCHED nodes."
  (let ((old-root (plist-get old-state :root-node))
        dirty)
    (if (not (equal (plist-get old-root :node-id)
                    (plist-get candidate-root :node-id)))
        (list
         (ebox--dirty-entry
          (plist-get candidate-root :node-id) 'structure
          :changed-keys '(:ebox-type)
          :old-region-ids (ebox--node-all-region-ids old-root)
          :new-region-ids (ebox--node-all-region-ids candidate-root)
          :old old-root :new candidate-root))
      (dolist (entry touched)
        (pcase-let ((`(,old-node ,new-node ,_parent-id ,children-changed)
                     entry))
          (when old-node
            (let* ((changed-keys
                    (ebox-tree-node-local-changed-keys old-node new-node))
                   (kind
                    (cond
                     (children-changed 'structure)
                     (changed-keys
                      (ebox-incremental--declarative-dirty-kind
                       changed-keys)))))
              (when kind
                (push
                 (append
                  (ebox--dirty-entry
                   (plist-get new-node :node-id) kind
                   :changed-keys
                   (if children-changed
                       (cons :children changed-keys)
                     changed-keys)
                   :old-region-ids
                   (and children-changed
                        (ebox--node-all-region-ids old-node))
                   :new-region-ids
                   (and children-changed
                        (ebox--node-all-region-ids new-node))
                   :old-signature
                   (ebox-tree-node-local-source-signature old-node)
                   :new-signature
                   (ebox-tree-node-local-source-signature new-node))
                  (ebox-incremental--child-change-props
                   old-node new-node children-changed))
                 dirty))))))
      (nreverse dirty))))

(defconst ebox-incremental--candidate-full-index-min-touched 64
  "Minimum touched nodes before a candidate may rebuild its complete index.")

(defun ebox-incremental--candidate-full-index-p (old-state touched)
  "Return non-nil when TOUCHED justifies rebuilding OLD-STATE's index."
  (let ((touched-count (length touched))
        (old-count (hash-table-count (plist-get old-state :node-table))))
    (and (>= touched-count
             ebox-incremental--candidate-full-index-min-touched)
         (>= (* 2 touched-count) old-count))))

(defun ebox-incremental--candidate-full-index-preparation
    (old-state candidate-root touched removed)
  "Return broad candidate preparation from TOUCHED and REMOVED nodes."
  (let ((index (ebox--runtime-index candidate-root t)))
    (setq index (plist-put index :selector-index-stale-p nil))
    (list :index index
          :dirty-set
          (ebox-incremental--candidate-dirty-set-from-touched
           old-state candidate-root touched)
          :touched-count (length touched)
          :removed-count (length removed))))

(defun ebox-incremental--candidate-local-index-delta
    (old-state candidate-root &optional path-copy-trace)
  "Return local indexes and dirty entries for CANDIDATE-ROOT.

Traversal stops at every node that is `eq' to OLD-STATE's indexed node.  The
work is therefore bounded by copied ancestor paths plus added, removed, and
replacement subtrees.  Core tables are materialized in this stage so existing
scalar `gethash' consumers remain unchanged; publication journaling can later
replace those O(n) table copies without changing this delta contract."
  (let ((old-root (plist-get old-state :root-node)))
    (if (eq candidate-root old-root)
        (list :index (ebox-incremental--candidate-base-index old-state)
              :dirty-set nil
              :touched-count 0
              :removed-count 0)
      (let* ((old-node-table (plist-get old-state :node-table))
             (missing (make-symbol "ebox-candidate-missing-node"))
             (removed-seen (make-hash-table :test 'equal))
             (visited-new (make-hash-table :test 'equal))
             (touched-parent-table (make-hash-table :test 'equal))
             touched removed)
        (cl-labels
            ((remove-old-subtree (node)
               (let ((node-id (ebox--ensure-node-id node)))
                 (unless (gethash node-id removed-seen)
                   (puthash node-id t removed-seen)
                   (push node removed)
                   (dolist (child (ebox--node-children node))
                     (remove-old-subtree child)))))
             (record-touched
              (old-node new-node parent-id children-changed)
              (let ((node-id (ebox--ensure-node-id new-node)))
                (puthash node-id parent-id touched-parent-table)
                (push (list old-node new-node parent-id children-changed)
                      touched)))
             (visit-new (node parent-id)
               (let* ((node-id (ebox--ensure-node-id node))
                      (old-node (gethash node-id old-node-table missing)))
                 (unless (or (gethash node-id visited-new)
                             (eq node old-node))
                   (puthash node-id t visited-new)
                   (when (eq old-node missing)
                     (setq old-node nil))
                   (let ((children-changed
                          (or (null old-node)
                              (not
                               (ebox-incremental--node-child-ids-equal-p
                                old-node node)))))
                     (record-touched
                      old-node node parent-id children-changed)
                     (when (and old-node children-changed)
                       (let ((new-child-ids (make-hash-table :test 'equal)))
                         (dolist (child (ebox--node-children node))
                           (puthash (ebox--ensure-node-id child) t
                                    new-child-ids))
                         (dolist (old-child (ebox--node-children old-node))
                           (unless (gethash (ebox--ensure-node-id old-child)
                                            new-child-ids)
                             (remove-old-subtree old-child)))))
                     (dolist (child (ebox--node-children node))
                       (visit-new child node-id)))))))
          (if (and (hash-table-p path-copy-trace)
                   (> (hash-table-count path-copy-trace) 0))
              (progn
                ;; Replacement anchors own their affected subtrees.  Visit
                ;; those first so descendant anchors are naturally deduped.
                (maphash
                 (lambda (base-node-id trace)
                   (when (plist-get trace :anchor-p)
                     (let* ((old-node (gethash base-node-id old-node-table))
                            (new-node (plist-get trace :node))
                            (parent-id (plist-get trace :parent-id)))
                       (when (and old-node
                                  (not (equal (plist-get old-node :node-id)
                                              (plist-get new-node :node-id))))
                         (remove-old-subtree old-node))
                       (visit-new new-node parent-id))))
                 path-copy-trace)
                ;; Ancestor copies are known exactly from path construction;
                ;; indexing them must not probe every untouched sibling.
                (maphash
                 (lambda (base-node-id trace)
                   (unless (plist-get trace :anchor-p)
                     (let* ((new-node (plist-get trace :node))
                            (node-id (plist-get new-node :node-id)))
                       (unless (gethash node-id visited-new)
                         (puthash node-id t visited-new)
                         (record-touched
                          (gethash base-node-id old-node-table)
                          new-node
                          (plist-get trace :parent-id)
                          (plist-get trace :structure-p))))))
                 path-copy-trace))
            (unless (equal (plist-get old-root :node-id)
                           (plist-get candidate-root :node-id))
              (remove-old-subtree old-root))
            (visit-new candidate-root nil)))
        ;; A type-changing anchor first marks its complete old subtree as
        ;; removed, then runtime reconciliation may retain keyed descendants
        ;; under the new type.  Those descendants also appear in TOUCHED and
        ;; must not be debited a second time from core indexes or region
        ;; multiplicities.
        (setq removed
              (cl-delete-if
               (lambda (node)
                 (gethash (plist-get node :node-id) visited-new))
               (nreverse removed)))
        (if (ebox-incremental--candidate-full-index-p old-state touched)
            (ebox-incremental--candidate-full-index-preparation
             old-state candidate-root touched removed)
          (progn
            ;; Local region owner repair needs ancestors before descendants.
            ;; A complete index rebuild already establishes that order itself.
            (let ((depth-table (make-hash-table :test 'equal))
                  (old-parent-table (plist-get old-state :parent-table)))
              (cl-labels
                  ((parent-id
                    (node-id)
                    (if (gethash node-id visited-new)
                        (gethash node-id touched-parent-table)
                      (gethash node-id old-parent-table)))
                   (depth
                    (node-id)
                    (or (gethash node-id depth-table)
                        (let ((current node-id)
                              path
                              (result -1))
                          (while (and current
                                      (not (gethash current depth-table)))
                            (push current path)
                            (setq current (parent-id current)))
                          (when current
                            (setq result (gethash current depth-table)))
                          (dolist (path-id path)
                            (puthash path-id (cl-incf result) depth-table))
                          (gethash node-id depth-table)))))
                (setq touched
                      (sort touched
                            (lambda (left right)
                              (< (depth (plist-get (nth 1 left) :node-id))
                                 (depth
                                  (plist-get (nth 1 right) :node-id))))))))
            (let* ((node-table
                (ebox-incremental--candidate-copy-index-table
                 old-state :node-table 'equal))
               (parent-table
                (ebox-incremental--candidate-copy-index-table
                 old-state :parent-table 'equal))
               (region-id-set
                (ebox-incremental--candidate-copy-index-table
                 old-state :region-id-set 'equal))
               (region-node-table
                (ebox-incremental--candidate-copy-index-table
                 old-state :region-node-table 'equal))
               (old-region-box-count-table
                (plist-get old-state :region-box-count-table))
               (region-box-count-table
                (if (hash-table-p old-region-box-count-table)
                    (copy-hash-table old-region-box-count-table)
                  (ebox-incremental--candidate-region-box-count-table
                   candidate-root)))
               (region-box-table
                (ebox-incremental--candidate-region-box-table old-state))
               (host-ref-table
                (ebox-incremental--candidate-copy-index-table
                 old-state :host-ref-table 'equal))
               (runtime-type-count-table
                (ebox-incremental--candidate-copy-index-table
                 old-state :runtime-type-count-table 'eq))
               (affected-region-ids (make-hash-table :test 'equal))
               (ambiguous-region-ids (make-hash-table :test 'equal)))
          (dolist (node removed)
            (let ((node-id (plist-get node :node-id)))
              (ebox-incremental--adjust-runtime-type-count
               runtime-type-count-table node -1)
              (remhash node-id node-table)
              (remhash node-id parent-table)
              (when-let ((host-ref (plist-get node :host-ref)))
                (when (equal (gethash host-ref host-ref-table) node-id)
                  (remhash host-ref host-ref-table)))
              (when-let ((record
                          (ebox-incremental--candidate-node-region-record node)))
                (puthash (car record) t affected-region-ids))
              (when (hash-table-p old-region-box-count-table)
                (ebox-incremental--candidate-adjust-region-box-count
                 region-box-count-table node -1))))
          ;; Remove every old Host binding before installing any new one.
          ;; Final candidate trees may legally exchange two unique refs; a
          ;; per-node remove/install loop would reject that valid final state
          ;; merely because the other old binding had not been visited yet.
          (dolist (entry touched)
            (when-let* ((old-node (car entry))
                        (old-host-ref (plist-get old-node :host-ref)))
              (let ((node-id (plist-get old-node :node-id)))
                (when (equal (gethash old-host-ref host-ref-table) node-id)
                  (remhash old-host-ref host-ref-table)))))
          (dolist (entry touched)
            (pcase-let ((`(,old-node ,new-node ,parent-id ,_children-changed)
                         entry))
              (let ((node-id (plist-get new-node :node-id)))
                (when old-node
                  (ebox-incremental--adjust-runtime-type-count
                   runtime-type-count-table old-node -1)
                  (when-let ((record
                              (ebox-incremental--candidate-node-region-record
                               old-node)))
                    (puthash (car record) t affected-region-ids))
                  (when (hash-table-p old-region-box-count-table)
                    (ebox-incremental--candidate-adjust-region-box-count
                     region-box-count-table old-node -1)))
                (puthash node-id new-node node-table)
                (ebox-incremental--adjust-runtime-type-count
                 runtime-type-count-table new-node 1)
                (if parent-id
                    (puthash node-id parent-id parent-table)
                  (remhash node-id parent-table))
                ;; Replacement subtrees were validated before recording and
                ;; checked against untouched Host refs before path copying.
                (when-let ((new-host-ref (plist-get new-node :host-ref)))
                  (puthash new-host-ref node-id host-ref-table))
                (when-let ((record
                            (ebox-incremental--candidate-node-region-record
                             new-node)))
                  (puthash (car record) t affected-region-ids))
                (when (hash-table-p old-region-box-count-table)
                  (ebox-incremental--candidate-adjust-region-box-count
                   region-box-count-table new-node 1)))))
          (maphash
           (lambda (region-id _present)
             (when (or (not (hash-table-p old-region-box-count-table))
                       (> (or (and old-region-box-count-table
                                   (gethash region-id
                                            old-region-box-count-table))
                              0)
                          1)
                       (> (or (gethash region-id region-box-count-table) 0)
                          1))
               (puthash region-id t ambiguous-region-ids)))
           affected-region-ids)
          (maphash
           (lambda (region-id _present)
             (remhash region-id region-id-set)
             (remhash region-id region-node-table)
             (remhash region-id region-box-table))
           affected-region-ids)
          ;; TOUCHED is preorder, matching `ebox--runtime-index' ownership:
          ;; a flex owner claims its wrapper before the wrapper box is visited.
          (dolist (entry touched)
            (when-let ((record
                        (ebox-incremental--candidate-node-region-record
                         (nth 1 entry))))
              (pcase-let ((`(,region-id ,owner-id ,box) record))
                (puthash region-id t region-id-set)
                (unless (gethash region-id region-node-table)
                  (puthash region-id owner-id region-node-table))
                (puthash region-id box region-box-table))))
          (when (> (hash-table-count ambiguous-region-ids) 0)
            (ebox-incremental--candidate-recompute-regions
             candidate-root ambiguous-region-ids
             region-id-set region-node-table region-box-table))
          (let* ((dirty-set
                  (ebox-incremental--candidate-dirty-set-from-touched
                   old-state candidate-root touched))
                 (structure-p
                  (cl-some
                   (lambda (entry)
                     (eq (plist-get entry :dirty-kind) 'structure))
                   dirty-set))
                 (native-node-postorder
                  (if structure-p
                      (ebox-incremental--candidate-native-postorder
                       candidate-root)
                    (ebox-incremental--candidate-map-native-postorder
                     old-state node-table)))
                 (index
                  (list :node-table node-table
                        :parent-table parent-table
                        :region-id-set region-id-set
                        :region-node-table region-node-table
                        :region-box-count-table region-box-count-table
                        :region-box-table region-box-table
                        :host-ref-table host-ref-table
                        ;; Paths contain ancestor objects, so a path copy makes
                        ;; selector indexes stale even when selector metadata
                        ;; itself did not change.  Rebuild on first query.
                        :selector-id-table
                        (plist-get old-state :selector-id-table)
                        :selector-class-table
                        (plist-get old-state :selector-class-table)
                        :selector-type-table
                        (plist-get old-state :selector-type-table)
                        :runtime-type-count-table runtime-type-count-table
                        :selector-index-stale-p t
                        :native-node-postorder native-node-postorder)))
            (list :index index
                  :dirty-set dirty-set
                  :touched-node-ids
                  (mapcar
                   (lambda (entry)
                     (plist-get (nth 1 entry) :node-id))
                   touched)
                  :removed-node-ids
                  (mapcar
                   (lambda (node) (plist-get node :node-id))
                   removed)
                  :touched-count (length touched)
                  :removed-count (length removed))))))))))

(defun ebox-incremental--declarative-dirty-set
    (old-state candidate-root candidate-index)
  "Return source-level dirty entries from OLD-STATE to CANDIDATE-ROOT.
CANDIDATE-INDEX is the prepared runtime index for CANDIDATE-ROOT."
  (let ((old-table (plist-get old-state :node-table))
        (new-table (plist-get candidate-index :node-table))
        (old-root (plist-get old-state :root-node))
        dirty)
    (if (not (equal (plist-get old-root :node-id)
                    (plist-get candidate-root :node-id)))
        (push (ebox--dirty-entry
               (plist-get candidate-root :node-id) 'structure
               :changed-keys '(:ebox-type)
               :old-region-ids (ebox--node-all-region-ids old-root)
               :new-region-ids (ebox--node-all-region-ids candidate-root)
               :old old-root :new candidate-root)
              dirty)
      (maphash
       (lambda (node-id new-node)
         (when-let ((old-node (gethash node-id old-table)))
           (let* ((changed-keys
                   (ebox-tree-node-local-changed-keys
                    old-node new-node))
                  (children-changed
                   (not
                    (ebox-incremental--node-child-ids-equal-p
                     old-node new-node)))
                  (kind (cond
                         (children-changed 'structure)
                         (changed-keys
                          (ebox-incremental--declarative-dirty-kind
                           changed-keys)))))
             (when kind
               (push
                (append
                 (ebox--dirty-entry
                  node-id kind
                  :changed-keys
                  (if children-changed
                      (cons :children changed-keys)
                    changed-keys)
                  :old-region-ids
                  (and children-changed
                       (ebox--node-all-region-ids old-node))
                  :new-region-ids
                  (and children-changed
                       (ebox--node-all-region-ids new-node))
                  :old-signature
                  (ebox-tree-node-local-source-signature old-node)
                  :new-signature
                  (ebox-tree-node-local-source-signature new-node))
                 (ebox-incremental--child-change-props
                  old-node new-node children-changed))
                dirty)))))
       new-table))
    (nreverse dirty)))

(defun ebox-incremental--candidate-state
    (old-state candidate-root candidate-index prepared)
  "Return unpublished runtime state for a prepared declarative root."
  (let ((state (copy-sequence old-state)))
    (dolist
        (entry
         `((:root-node ,candidate-root)
           (:logical-candidate-p
            ,(plist-get prepared :logical-candidate-p))
           (:layout-snapshots ,(plist-get prepared :layout-snapshots))
           (:layout-snapshots-complete-p nil)
           (:layout-snapshot-detail-generation
            ,(or (plist-get old-state :layout-snapshot-detail-generation)
                 0))
           (:runtime-revision
            ,(1+ (or (plist-get old-state :runtime-revision) 0)))
           (:display-signature ,(plist-get prepared :display-signature))
           (:render-cache ,(plist-get prepared :render-cache))
           (:detached-identity-history
            ,(or (plist-get prepared :detached-identity-history)
                 (plist-get old-state :detached-identity-history)))
           (:render-signature-cache
            ,(plist-get prepared :render-signature-cache))
           (:flex-content-min-widths ,(make-hash-table :test 'eq))
           (:viewport-height-dependent-subtree-cache
            ,(plist-get prepared
                        :viewport-height-dependent-subtree-cache))
           (:viewport-dependent-node-ids-ready
            ,(and (eq candidate-root (plist-get old-state :root-node))
                  (plist-get old-state
                             :viewport-dependent-node-ids-ready)))
           (:viewport-dependent-node-ids
            ,(and (eq candidate-root (plist-get old-state :root-node))
                  (plist-get old-state :viewport-dependent-node-ids)))
           (:viewport-dependent-node-id-axes
            ,(and (eq candidate-root (plist-get old-state :root-node))
                  (plist-get old-state
                             :viewport-dependent-node-id-axes)))
           (:reflow-prewarm-scratch nil)
           (:scroll-region-ids
            ,(ebox-incremental--hash-keys
              (plist-get prepared :scroll-state-table)))
           (:node-table ,(plist-get candidate-index :node-table))
           (:parent-table ,(plist-get candidate-index :parent-table))
           (:region-id-set ,(plist-get candidate-index :region-id-set))
           (:region-node-table
            ,(plist-get candidate-index :region-node-table))
           (:region-box-count-table
            ,(plist-get candidate-index :region-box-count-table))
           (:region-box-table
            ,(plist-get candidate-index :region-box-table))
           (:host-ref-table
            ,(plist-get candidate-index :host-ref-table))
           (:selector-id-table
            ,(plist-get candidate-index :selector-id-table))
           (:selector-class-table
            ,(plist-get candidate-index :selector-class-table))
           (:selector-type-table
            ,(plist-get candidate-index :selector-type-table))
           (:runtime-type-count-table
            ,(plist-get candidate-index :runtime-type-count-table))
           (:selector-index-stale-p
            ,(plist-get candidate-index :selector-index-stale-p))
           (:native-node-postorder
            ,(plist-get candidate-index :native-node-postorder))))
      (setq state
            (plist-put state (car entry) (cadr entry))))
    state))

(defun ebox-incremental--seed-candidate-node-cache
    (old-cache old-node-table candidate-node-table)
  "Seed an eq-keyed candidate cache from OLD-CACHE by stable node identity."
  (let ((candidate-cache (make-hash-table :test 'eq))
        (missing (make-symbol "ebox-candidate-cache-missing")))
    (when (and (hash-table-p old-cache)
               (hash-table-p old-node-table)
               (hash-table-p candidate-node-table))
      (maphash
       (lambda (node-id candidate-node)
         (when-let ((old-node (gethash node-id old-node-table)))
           (let ((cached (gethash old-node old-cache missing)))
             (unless (eq cached missing)
               (puthash candidate-node cached candidate-cache)))))
       candidate-node-table))
    candidate-cache))

(defun ebox-incremental--copy-pruned-candidate-node-cache
    (old-cache old-node-table old-parent-table dirty-set
               touched-node-ids removed-node-ids)
  "Copy OLD-CACHE and remove stale candidate-local nodes.
TOUCHED-NODE-IDS and REMOVED-NODE-IDS name old runtime nodes that no longer
belong in the candidate tree.  DIRTY-SET removes old ancestor-path facts that
must be recomputed in the next publication."
  (let ((candidate-cache
         (if (hash-table-p old-cache)
             (copy-hash-table old-cache)
           (make-hash-table :test 'eq))))
    (dolist (entry dirty-set)
      (ebox--invalidate-runtime-render-signature-path
       (plist-get entry :node-id)
       old-node-table old-parent-table
       candidate-cache nil))
    (dolist (node-id (append touched-node-ids removed-node-ids))
      (when-let ((old-node (gethash node-id old-node-table)))
        (remhash old-node candidate-cache)))
    candidate-cache))

(defun ebox-incremental--candidate-structural-caches
    (old-state candidate-index dirty-set &optional local-preparation)
  "Return seeded candidate signature caches invalidated by DIRTY-SET."
  (let* ((old-node-table (plist-get old-state :node-table))
         (old-parent-table (plist-get old-state :parent-table))
         (candidate-node-table (plist-get candidate-index :node-table))
         (candidate-parent-table (plist-get candidate-index :parent-table))
         (touched-node-ids
          (plist-get local-preparation :touched-node-ids))
         (removed-node-ids
          (plist-get local-preparation :removed-node-ids))
         (signature-cache
          (if touched-node-ids
              (ebox-incremental--copy-pruned-candidate-node-cache
               (plist-get old-state :render-signature-cache)
               old-node-table old-parent-table dirty-set
               touched-node-ids removed-node-ids)
            (ebox-incremental--seed-candidate-node-cache
             (plist-get old-state :render-signature-cache)
             old-node-table candidate-node-table)))
         (height-cache
          (if touched-node-ids
              (ebox-incremental--copy-pruned-candidate-node-cache
               (plist-get old-state :viewport-height-dependent-subtree-cache)
               old-node-table old-parent-table dirty-set
               touched-node-ids removed-node-ids)
            (ebox-incremental--seed-candidate-node-cache
             (plist-get old-state :viewport-height-dependent-subtree-cache)
             old-node-table candidate-node-table))))
    (unless touched-node-ids
      (dolist (entry dirty-set)
        (ebox--invalidate-runtime-render-signature-path
         (plist-get entry :node-id)
         candidate-node-table candidate-parent-table
         signature-cache height-cache)))
    (list :render-signature-cache signature-cache
          :viewport-height-dependent-subtree-cache height-cache)))

(defun ebox-incremental--prepare-declarative-runtime
    (buffer old-state candidate-root &optional logical-candidate-p
            local-preparation)
  "Prepare CANDIDATE-ROOT for BUFFER without mutating its published runtime."
  (let* ((old-root (plist-get old-state :root-node))
         (render-cache
          (or (plist-get old-state :render-cache)
              (make-hash-table :test 'equal))))
    (let* ((candidate-index
            (or (plist-get local-preparation :index)
                (ebox--runtime-index candidate-root t)))
           (candidate-region-box-table
            (plist-get candidate-index :region-box-table))
           (dirty-set
            (if local-preparation
                (plist-get local-preparation :dirty-set)
              (ebox-incremental--declarative-dirty-set
               old-state candidate-root candidate-index)))
           (current-display-signature (ebox--current-display-signature)))
      (unless (equal (plist-get old-state :display-signature)
                     current-display-signature)
        (push
         (ebox--dirty-entry
          (plist-get candidate-root :node-id) 'geometry
          :changed-keys '(:display-signature)
          :old-region-ids (ebox--node-all-region-ids old-root)
          :new-region-ids (ebox--node-all-region-ids candidate-root))
         dirty-set))
      ;; Dirty-owner planning needs the geometry that is actually published,
      ;; not geometry recomputed from the candidate source.  Freeze only the
      ;; lightweight text spans here; detail consumers complete footprint and
      ;; topology fields on demand before the candidate becomes current.
      (with-current-buffer buffer
        (dolist (entry dirty-set)
          (when (memq (plist-get entry :dirty-kind) '(geometry structure))
            (when (gethash (plist-get entry :node-id)
                           (plist-get old-state :node-table))
              (ebox--ensure-layout-snapshot-spans
               buffer (plist-get entry :node-id)))))
        (unless (equal (plist-get old-root :node-id)
                       (plist-get candidate-root :node-id))
          (ebox--ensure-layout-snapshot-spans
           buffer (plist-get old-root :node-id))))
      (let* ((structural-caches
              (ebox-incremental--candidate-structural-caches
               old-state candidate-index dirty-set local-preparation))
             (render-signature-cache
              (plist-get structural-caches :render-signature-cache))
             (viewport-height-dependent-subtree-cache
              (plist-get structural-caches
                         :viewport-height-dependent-subtree-cache)))
        (let* ((candidate-scroll-state-table
                (ebox-incremental--candidate-scroll-state-table
                 buffer old-state candidate-index candidate-region-box-table))
               (layout-snapshots
                (ebox-incremental--candidate-layout-snapshots
                 old-state candidate-root candidate-index)))
          (list :root candidate-root
                :logical-candidate-p logical-candidate-p
                :index candidate-index
                :dirty-set dirty-set
                :display-signature current-display-signature
                :render-cache render-cache
                :detached-identity-history
                (or (plist-get local-preparation
                               :detached-identity-history)
                    (plist-get old-state :detached-identity-history))
                :render-signature-cache render-signature-cache
                :viewport-height-dependent-subtree-cache
                viewport-height-dependent-subtree-cache
                :layout-snapshots layout-snapshots
                :scroll-state-table candidate-scroll-state-table))))))

(defun ebox-incremental--prepare-declarative-root
    (buffer old-state next-root)
  "Prepare newly built NEXT-ROOT for BUFFER without mutating publication."
  (unless (and (listp next-root) (not (stringp next-root)))
    (error "Ebox declarative root must be an Ebox node"))
  ;; Validate before copying so shared references and cycles remain visible.
  (ebox-tree-validate-declarative-root next-root)
  (let* ((candidate-root
          (ebox-tree-clear-runtime-identities
           (ebox-tree-copy-node-structure next-root)))
         (old-root (plist-get old-state :root-node)))
    ;; Failed preparation may leave harmless allocator gaps, but cannot publish
    ;; duplicate runtime identities.
    (ebox-tree-reconcile-runtime old-root candidate-root)
    (ebox-incremental--prepare-declarative-runtime
     buffer old-state candidate-root nil)))

(defun ebox-incremental--prepare-logical-candidate
    (buffer old-state candidate)
  "Prepare CANDIDATE's path-copied logical root for BUFFER."
  (let* ((path-copy-trace (make-hash-table :test 'equal))
         (detached-history
          (ebox-incremental--copy-detached-history old-state))
         (candidate-root
          (let ((ebox-incremental--candidate-path-copy-trace
                 path-copy-trace))
            (ebox-incremental--candidate-logical-root
             candidate detached-history)))
         (local-preparation
          (ebox-incremental--candidate-local-index-delta
           old-state candidate-root path-copy-trace)))
    ;; Replaced subtrees were validated when they were recorded; the
    ;; untouched published remainder was validated when it was itself
    ;; published, and path copying introduces no new sibling or ref
    ;; relations outside the replaced anchors.  Re-walking the whole
    ;; tree here made every commit pay one full-page validation.
    (setq local-preparation
          (plist-put local-preparation
                     :detached-identity-history detached-history))
    (ebox-incremental--prepare-declarative-runtime
     buffer old-state candidate-root t local-preparation)))

(defun ebox-incremental--declarative-tentative-op (buffer entry)
  "Return the smallest proof candidate for declarative dirty ENTRY."
  (let* ((entry (ebox--dirty-entry-with-impact-vector buffer entry))
         (node-id (plist-get entry :node-id))
         (dirty-kind (plist-get entry :dirty-kind)))
    (if (and (equal (plist-get entry :changed-keys) '(:children))
             (or (plist-get entry :pure-child-reorder-p)
                 (and (plist-get entry :child-splice-p)
                      (ebox-incremental--simple-new-child-splice-p
                       buffer node-id entry))))
        (if (plist-get entry :pure-child-reorder-p)
            (ebox--patch-op 'child-reorder node-id :dirty entry)
          (ebox--patch-op 'child-splice node-id :dirty entry))
      (pcase dirty-kind
        ('paint
         (ebox--patch-op 'paint-patch node-id :dirty entry))
        ('geometry
         (ebox--patch-op-from-dirty-entry entry buffer))
        (_
         (if-let ((span-owner-id
                   (ebox--span-patch-owner-id-for-dirty-entry entry buffer)))
             (ebox--patch-op 'span-patch span-owner-id :dirty entry)
           (when (and (eq dirty-kind 'structure)
                      (not
                       (ebox-incremental--owner-can-absorb-line-count-change-p
                        buffer node-id)))
             (setq node-id
                   (or (ebox-incremental--declarative-next-owner-id
                        buffer node-id entry)
                       (ebox--buffer-root-node-id buffer))))
           (ebox--patch-op 'owner-rerender node-id :dirty entry)))))))

(defun ebox-incremental--coalesce-sibling-line-span-ops (buffer ops)
  "Merge sibling span patches sharing one published line in BUFFER.
Two or more span-patch ops whose owners are direct children of the
same parent, when that parent owns exactly one buffer line and is
itself span patchable, become one span patch at the parent: the
line is rerendered and republished once instead of once per child.
The parent proof still verifies the rendered line against the
published slots, so this only changes op granularity, never safety."
  (let ((groups (make-hash-table :test 'equal))
        (coalesced nil)
        (result nil))
    (dolist (op ops)
      (let ((parent-id
             (and (eq (plist-get op :op) 'span-patch)
                  (ebox--runtime-parent-id
                   buffer (plist-get op :owner-id)))))
        (if parent-id
            (push op (gethash parent-id groups))
          (push op result))))
    (maphash
     (lambda (parent-id group)
       (if (and (cdr group)
                (not (equal parent-id (ebox--buffer-root-node-id buffer)))
                (when-let* ((snapshot (ebox--ensure-layout-snapshot-spans
                                       buffer parent-id))
                            (spans (plist-get snapshot :buffer-spans)))
                  (= (length spans) 1))
                (ebox--cached-patchable-owner-p buffer parent-id 'span))
           (let ((merged (ebox--patch-op
                          'span-patch parent-id
                          :dirty (plist-get (car group) :dirty))))
             (dolist (op (cdr group))
               (setq merged (ebox--patch-op-merge-dirty merged op)))
             (let ((candidate-id parent-id)
                   contained-owner-id)
               (while (and candidate-id (not contained-owner-id))
                 (if (ebox--contained-partial-flex-owner-p
                      buffer candidate-id)
                     (setq contained-owner-id candidate-id)
                   (setq candidate-id
                         (ebox--runtime-parent-id buffer candidate-id))))
               (when contained-owner-id
                 (setq merged
                       (ebox--patch-op
                        'owner-rerender contained-owner-id
                        :dirty (plist-get merged :dirty)))))
             (push merged coalesced))
         (setq result (nconc group result))))
     groups)
    ;; Coalesced parents re-enter dominance merging: a parent op may
    ;; now cover other surviving descendants.
    (dolist (op coalesced)
      (setq result (ebox--merge-patch-op-into-set buffer result op)))
    result))

(defun ebox-incremental--owner-can-absorb-line-count-change-p
    (buffer node-id)
  "Return non-nil when NODE-ID could publish a line-count change.
An owner whose spans cover whole buffer lines can replace them with a
different number of lines; a definite containment context can clamp a
descendant's line-count change inside its fixed height.  A partial-slot
owner with neither property shares its lines with siblings, so any
render whose line count moved is unpublishable there by construction."
  (or (when-let* ((snapshot
                   (ebox--ensure-layout-snapshot-spans buffer node-id))
                  (spans (plist-get snapshot :buffer-spans)))
        (with-current-buffer buffer
          (ebox--line-spans-cover-whole-lines-p spans)))
      (ebox--definite-containment-formatting-context-p buffer node-id)))

(defun ebox-incremental--common-runtime-ancestor-id (buffer node-ids)
  "Return the lowest common runtime ancestor of NODE-IDS in BUFFER."
  (let ((ancestor-id (car node-ids)))
    (dolist (node-id (cdr node-ids))
      (while (and ancestor-id
                  (not (or (equal ancestor-id node-id)
                           (ebox--cached-runtime-ancestor-id-p
                            buffer ancestor-id node-id))))
        (setq ancestor-id
              (ebox--runtime-parent-id buffer ancestor-id))))
    ancestor-id))

(defun ebox-incremental--broad-dirty-owner-id (buffer node-ids)
  "Return one structurally safe broad owner for NODE-IDS in BUFFER."
  (let* ((root-id (ebox--buffer-root-node-id buffer))
         (root (ebox--buffer-runtime-node buffer root-id))
         (owner-id
          (ebox-incremental--common-runtime-ancestor-id
           buffer node-ids)))
    (when (and root-id root owner-id)
      (if (or (equal owner-id root-id)
              (not (eq (ebox-tree-display-inner root) 'column)))
          root-id
        ;; A direct child of a column root owns complete vertical lines.
        ;; Publishing it can therefore absorb descendant line-count changes
        ;; without probing every intermediate ancestor's buffer spans.
        (while (and owner-id
                    (not (equal
                          (ebox--runtime-parent-id buffer owner-id)
                          root-id)))
          (setq owner-id (ebox--runtime-parent-id buffer owner-id)))
        owner-id))))

(defun ebox-incremental--runtime-descendant-count (node)
  "Return the number of declarative descendants below runtime NODE."
  (cl-loop for child in (ebox-tree-node-children node)
           sum (1+ (ebox-incremental--runtime-descendant-count child))))

(defun ebox-incremental--broad-dirty-op (buffer render-dirty-set)
  "Return one safely proofable owner op for a broad RENDER-DIRTY-SET."
  (when (and (>= (length render-dirty-set)
                 ebox--owner-coalesce-min-count)
             (cl-some (lambda (entry)
                        (not (eq (plist-get entry :dirty-kind) 'paint)))
                      render-dirty-set))
    (let* ((node-ids
            (delete-dups
             (cl-mapcan #'ebox--dirty-provenance-node-ids
                        render-dirty-set)))
           (owner-id
            (ebox-incremental--broad-dirty-owner-id
             buffer node-ids)))
      (when-let* ((owner (and owner-id
                              (ebox--buffer-runtime-node buffer owner-id)))
                  (descendant-count
                   (ebox-incremental--runtime-descendant-count owner))
                  ((> descendant-count 0))
                  (dirty-descendant-count
                   (cl-count-if
                    (lambda (node-id)
                      (not (equal node-id owner-id)))
                    node-ids))
                  ((>= (/ (float dirty-descendant-count) descendant-count)
                       ebox-incremental--broad-dirty-min-node-coverage)))
        (ebox--patch-op
         'owner-rerender owner-id
         :dirty (ebox--merge-dirty-provenance-list render-dirty-set))))))

(defun ebox-incremental--local-reflow-op (buffer render-dirty-set)
  "Return one local wrapper op for related geometry RENDER-DIRTY-SET."
  (when (and (> (length render-dirty-set) 1)
             (not
              (cl-every
               (lambda (entry)
                 (equal (plist-get entry :changed-keys) '(:content)))
               render-dirty-set))
             (cl-every
              (lambda (entry)
                (let ((entry (ebox--dirty-entry-with-impact-vector
                              buffer entry)))
                  (and (eq (plist-get entry :dirty-kind) 'geometry)
                       (memq 'parent-layout
                             (plist-get entry :impact-vector))
                       (cl-some
                        (lambda (node-id)
                          (ebox--geometry-affects-parent-layout-p
                           buffer node-id))
                        (ebox--dirty-provenance-node-ids entry)))))
              render-dirty-set))
    (let* ((root-id (ebox--buffer-root-node-id buffer))
           (node-ids
            (delete-dups
             (cl-mapcan #'ebox--dirty-provenance-node-ids
                        render-dirty-set)))
           (owner-id
            (ebox-incremental--common-runtime-ancestor-id
             buffer node-ids)))
      (while (and owner-id (not (equal owner-id root-id))
                  (not (ebox--owned-overflow-coverage-wrapper-node-p
                        buffer owner-id)))
        (setq owner-id (ebox--runtime-parent-id buffer owner-id)))
      (when (and owner-id (not (equal owner-id root-id))
                 (not (equal (ebox--runtime-parent-id buffer owner-id)
                             root-id)))
        (ebox--patch-op
         'owner-rerender owner-id
         :dirty (ebox--merge-dirty-provenance-list render-dirty-set))))))

(defun ebox-incremental--dirty-set-has-child-splice-p
    (buffer render-dirty-set)
  "Return non-nil when RENDER-DIRTY-SET contains a provable child splice."
  (cl-some
   (lambda (entry)
     (and (equal (plist-get entry :changed-keys) '(:children))
          (plist-get entry :child-splice-p)
          (ebox-incremental--simple-new-child-splice-p
           buffer (plist-get entry :node-id) entry)))
   render-dirty-set))

(defun ebox-incremental--declarative-tentative-patch-set
    (buffer render-dirty-set)
  "Return merged smallest-owner candidates for RENDER-DIRTY-SET."
  (let ((ebox--patchable-owner-cache (make-hash-table :test 'equal))
        (ebox--runtime-ancestor-cache (make-hash-table :test 'equal))
        (ebox--flex-slot-safety-cache (make-hash-table :test 'equal))
        (index (ebox--make-patch-op-merge-index))
        ops)
    (ebox--with-layout-snapshot-detail-context buffer
      (if-let ((coalesced-op
                (and (not
                      (ebox-incremental--dirty-set-has-child-splice-p
                       buffer render-dirty-set))
                     (or (ebox-incremental--broad-dirty-op
                          buffer render-dirty-set)
                         (ebox-incremental--local-reflow-op
                          buffer render-dirty-set)))))
          (setq ops (list coalesced-op))
        (dolist (entry render-dirty-set)
          (ebox--patch-op-merge-index-add
           buffer index
           (ebox-incremental--declarative-tentative-op buffer entry)))
        (setq ops
              (ebox-incremental--coalesce-sibling-line-span-ops
               buffer (ebox--patch-op-merge-index-result index)))))
    (ebox--dedupe-patch-owners buffer ops)))

(defun ebox-incremental--declarative-next-owner-id
    (buffer owner-id dirty)
  "Return the next ancestor of OWNER-ID worth proving for DIRTY."
  (let* ((root-id (ebox--buffer-root-node-id buffer))
         (ancestor-id
          (or (ebox--runtime-parent-id buffer owner-id) root-id))
         (structure-change
          (eq (plist-get dirty :dirty-kind) 'structure))
         (overflow-coverage
          (plist-get dirty :requires-owned-overflow-coverage))
         (pure-overflow
          (equal (plist-get dirty :changed-keys) '(:overflow))))
    (while
        (and ancestor-id
             (not (equal ancestor-id root-id))
             (or
              (and structure-change
                   (not
                    (ebox-incremental--owner-can-absorb-line-count-change-p
                     buffer ancestor-id)))
              (and overflow-coverage
                   (or
                    (not
                     (ebox--owned-overflow-coverage-wrapper-node-p
                      buffer ancestor-id))
                    (and (not pure-overflow)
                         (ebox--partial-slot-owner-p
                          buffer ancestor-id))))))
      (setq ancestor-id
            (or (ebox--runtime-parent-id buffer ancestor-id) root-id)))
    ancestor-id))

(defun ebox-incremental--layout-owner-plan
    (buffer old-state candidate-state dirty-set)
  "Return BUFFER layout-owner plan from OLD-STATE to CANDIDATE-STATE for DIRTY-SET."
  (when-let ((render-dirty-set
              (cl-remove-if
               (lambda (entry)
                 (eq (plist-get entry :dirty-kind) 'metadata))
               dirty-set)))
    (let ((ebox-incremental--buffer-render-state-override
           (cons buffer candidate-state))
          (ebox-incremental--candidate-base-state
           (cons buffer old-state))
          (ebox--region-box-table
           (plist-get candidate-state :region-box-table))
          (ebox--scroll-global-state
           (plist-get candidate-state :scroll-state-table))
          (ebox--scroll-idle-prefetch-timers
           (make-hash-table :test 'equal))
          (ebox--smooth-scroll-state-table
           (make-hash-table :test 'equal))
          (ebox--render-cache-scroll-state-restorable-p nil))
      (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                 (lambda (&rest _) nil)))
        (ebox-incremental--declarative-tentative-patch-set
         buffer render-dirty-set)))))

(defun ebox-incremental--layout-owner-report
    (prepared owner-plan candidate-state)
  "Return Ebox report for PREPARED, OWNER-PLAN, and CANDIDATE-STATE."
  (let* ((owner-ids
          (mapcar (lambda (op) (plist-get op :owner-id)) owner-plan))
         (single-owner (and (= (length owner-ids) 1) (car owner-ids)))
         (snapshots (plist-get candidate-state :layout-snapshots))
         (node-table (plist-get candidate-state :node-table))
         (report
          (and owner-plan
               (ebox--update-report
                nil (ebox--patch-results-strategy owner-plan)
                :dirty-count (length (plist-get prepared :dirty-set))
                :patch-count (length owner-plan)
                :patch-ops
                (mapcar (lambda (op) (plist-get op :op)) owner-plan)
                :owner-ids owner-ids
                :owner-type
                (plist-get (gethash single-owner node-table) :ebox-type)
                :span-count
                (cl-loop for owner-id in owner-ids
                         for snapshot = (and snapshots
                                             (gethash owner-id snapshots))
                         sum (length (plist-get snapshot :buffer-spans)))
                :publication-scope 'layout-owners))))
    (ebox-incremental--commit-report prepared report candidate-state)))

(defun ebox-incremental--same-root-surface-identity-p (old-root new-root)
  "Return non-nil when OLD-ROOT and NEW-ROOT retain one TP root object."
  (and (eq (plist-get old-root :ebox-type)
           (plist-get new-root :ebox-type))
       (equal (ebox-tree-node-key old-root)
              (ebox-tree-node-key new-root))))

(defun ebox-incremental--surface-commit-input
    (buffer old-state prepared)
  "Return TP surface input for BUFFER from OLD-STATE and PREPARED runtime."
  (let* ((candidate-state
          (ebox-incremental--candidate-state
           old-state (plist-get prepared :root)
           (plist-get prepared :index) prepared))
         (owner-plan
          (ebox-incremental--layout-owner-plan
           buffer old-state candidate-state
           (plist-get prepared :dirty-set)))
         (same-root-identity-p
          (ebox-incremental--same-root-surface-identity-p
           (plist-get old-state :root-node)
           (plist-get candidate-state :root-node)))
         (scope-node-ids
          (and same-root-identity-p
               (delete-dups
                (or (mapcar (lambda (op) (plist-get op :owner-id)) owner-plan)
                    (mapcar (lambda (entry) (plist-get entry :node-id))
                            (plist-get prepared :dirty-set))))))
         (report
          (ebox-incremental--layout-owner-report
           prepared owner-plan candidate-state)))
    (unless same-root-identity-p
      (setq report (plist-put report :strategy 'root-rerender))
      (setq report (plist-put report :publication-scope 'root))
      (setq report (plist-put report :root-rerender t)))
    (list :root (plist-get prepared :root)
          :scope-node-ids scope-node-ids
          :report-base report
          :preserve-identities-p t
          :state-overrides
          (list :viewport-width (plist-get old-state :viewport-width)
                :viewport-height (plist-get old-state :viewport-height)
                :display-signature
                (plist-get prepared :display-signature)
                :scroll-state-table
                (plist-get prepared :scroll-state-table)
                :logical-candidate-p
                (plist-get prepared :logical-candidate-p)
                :detached-identity-history
                (plist-get prepared :detached-identity-history)))))

(defun ebox-incremental--plist-overlay (base overrides)
  "Return BASE with every property in OVERRIDES replaced."
  (setq base (copy-sequence base))
  (while overrides
    (setq base (plist-put base (pop overrides) (pop overrides))))
  base)

(defun ebox-incremental-prepare-scoped-commit
    (buffer next-root report-overrides)
  "Prepare NEXT-ROOT for object-scoped TP publication in BUFFER.
REPORT-OVERRIDES replaces Ebox semantic report fields.  The returned plist
contains the isolated candidate root, Ebox node identities, report, and
runtime overrides; the surface layer resolves identities to opaque TP objects."
  (let ((old-state (ebox--buffer-render-state buffer)))
    (unless old-state
      (error "Ebox buffer has no rendered runtime: %S" buffer))
    (let* ((prepared
            (ebox-incremental--prepare-declarative-root
             buffer old-state next-root))
           (candidate-state
            (ebox-incremental--candidate-state
             old-state (plist-get prepared :root)
             (plist-get prepared :index) prepared))
           (owner-plan
            (ebox-incremental--layout-owner-plan
             buffer old-state candidate-state
             (plist-get prepared :dirty-set)))
           (scope-node-ids
            (delete-dups
             (or (mapcar (lambda (op) (plist-get op :owner-id)) owner-plan)
                 (mapcar (lambda (entry) (plist-get entry :node-id))
                         (plist-get prepared :dirty-set)))))
           (report
            (ebox-incremental--plist-overlay
             (ebox-incremental--layout-owner-report
              prepared owner-plan candidate-state)
             report-overrides)))
      (list :root (plist-get prepared :root)
            :scope-node-ids scope-node-ids
            :report-base report
            :state-overrides
            (list :viewport-width (plist-get old-state :viewport-width)
                  :viewport-height (plist-get old-state :viewport-height)
                  :display-signature
                  (plist-get prepared :display-signature)
                  :scroll-state-table
                  (plist-get prepared :scroll-state-table)
                  :detached-identity-history
                  (plist-get prepared :detached-identity-history))))))

(defun ebox-incremental--viewport-state-overrides (state)
  "Return surface overrides from viewport candidate STATE."
  (list :viewport-width (plist-get state :viewport-width)
        :viewport-height (plist-get state :viewport-height)
        :display-signature (plist-get state :display-signature)
        :render-cache (plist-get state :render-cache)
        :render-signature-cache (plist-get state :render-signature-cache)
        :flex-content-min-widths (plist-get state :flex-content-min-widths)
        :viewport-height-dependent-subtree-cache
        (plist-get state :viewport-height-dependent-subtree-cache)
        :viewport-dependent-node-ids-ready
        (plist-get state :viewport-dependent-node-ids-ready)
        :viewport-dependent-node-ids
        (plist-get state :viewport-dependent-node-ids)
        :viewport-dependent-node-id-axes
        (plist-get state :viewport-dependent-node-id-axes)
        :scroll-state-table (plist-get state :scroll-state-table)
        :detached-identity-history
        (plist-get state :detached-identity-history)))

(defun ebox-incremental-prepare-viewport-commit
    (buffer viewport-width viewport-height axes display-signature)
  "Prepare BUFFER for VIEWPORT-WIDTH, VIEWPORT-HEIGHT, AXES, and DISPLAY-SIGNATURE."
  (let* ((old-state (ebox--buffer-render-state buffer))
         (change (ebox--viewport-constraint-change buffer axes))
         (display-changed
          (not (equal display-signature
                      (plist-get old-state :display-signature))))
         (dirty-set
          (if display-changed
              (let ((root (plist-get old-state :root-node)))
                (list
                 (ebox--dirty-entry
                  (plist-get root :node-id) 'geometry
                  :changed-keys '(:display-signature)
                  :old-region-ids (ebox--node-all-region-ids root)
                  :new-region-ids (ebox--node-all-region-ids root))))
            (plist-get change :dirty-set)))
         (target-height
          (or viewport-height (plist-get old-state :viewport-height))))
    (setq change (plist-put change :dirty-set dirty-set))
    (if (null dirty-set)
        (list :no-op t
              :report-base
              (append
               (ebox--update-report
                nil 'no-op :dirty-count 0 :patch-count 0 :patch-ops nil)
               (ebox--constraint-change-report-props change)
               (list :viewport-axes axes
                     :host-context-changed display-changed))
              :state-overrides
              (list :viewport-width viewport-width
                    :viewport-height target-height
                    :display-signature display-signature))
      (let* ((candidate-scroll-table
              (ebox-incremental--candidate-scroll-state-table
               buffer old-state old-state
               (plist-get old-state :region-box-table)))
             (candidate-state (copy-sequence old-state))
             (prepared
              (list :root (plist-get old-state :root-node)
                    :dirty-set dirty-set
                    :display-signature display-signature
                    :scroll-state-table candidate-scroll-table))
             owner-plan report)
        (plist-put candidate-state :viewport-width viewport-width)
        (plist-put candidate-state :viewport-height target-height)
        (plist-put candidate-state :display-signature display-signature)
        (plist-put candidate-state :runtime-revision
                   (1+ (or (plist-get old-state :runtime-revision) 0)))
        (plist-put candidate-state :region-box-table
                   (copy-hash-table
                    (plist-get old-state :region-box-table)))
        (plist-put candidate-state :scroll-state-table candidate-scroll-table)
        (setq owner-plan
              (ebox-incremental--layout-owner-plan
               buffer old-state candidate-state dirty-set)
              report
              (ebox-incremental--plist-overlay
               (ebox-incremental--layout-owner-report
                prepared owner-plan candidate-state)
               (append (ebox--constraint-change-report-props change)
                       (list :viewport-axes axes
                             :host-context-changed display-changed))))
        (list :root (plist-get candidate-state :root-node)
              :scope-node-ids
              (delete-dups
               (or (mapcar (lambda (op) (plist-get op :owner-id)) owner-plan)
                   (mapcar (lambda (entry) (plist-get entry :node-id))
                           dirty-set)))
              :report-base report
              :state-overrides
              (ebox-incremental--viewport-state-overrides
               candidate-state))))))

(defun ebox-incremental--finalize-declarative-scroll-publication
    (scroll-keys &optional prefetch-delay)
  "Retire stale scroll work and resume committed SCROLL-KEYS.
PREFETCH-DELAY is forwarded when a live, inactive scroll region needs warming."
  (dolist (region-id scroll-keys)
    (ignore-errors (ebox--scroll-cancel-idle-prefetch region-id))
    (if (gethash region-id ebox--scroll-global-state)
        (unless (gethash region-id ebox--smooth-scroll-state-table)
          (ignore-errors
            (ebox--scroll-schedule-idle-prefetch
             region-id prefetch-delay)))
      (ignore-errors (ebox--smooth-scroll-stop region-id)))))

(defun ebox-incremental--commit-report (prepared patch-report state)
  "Return the declarative report for PREPARED, PATCH-REPORT, and STATE."
  (let* ((dirty-set (plist-get prepared :dirty-set))
         (report
          (or (and patch-report (copy-sequence patch-report))
              (ebox--update-report
               nil 'no-op :dirty-count 0 :patch-count 0 :patch-ops nil))))
    (setq report (plist-put report :constraint-source 'declarative))
    (setq report
          (plist-put report :constraint-root-node-id
                     (plist-get (plist-get prepared :root) :node-id)))
    (setq report (plist-put report :dirty-count (length dirty-set)))
    (setq report
          (plist-put report :dirty-kinds (ebox--dirty-set-kinds dirty-set)))
    (setq report
          (plist-put report :dirty-keys
                     (ebox--dirty-set-changed-keys dirty-set)))
    (setq report
          (plist-put report :render-scope
                     (if patch-report 'dirty-owners 'none)))
    (setq report
          (plist-put report :rendered-owner-ids
                     (copy-sequence (plist-get report :owner-ids))))
    (setq report
          (plist-put report :publication-scope
                     (if patch-report
                         (or (plist-get report :publication-scope)
                             'minimal-spans)
                       'runtime-only)))
    (setq report (plist-put report :runtime-published t))
    (setq report
          (plist-put report :runtime-revision
                     (plist-get state :runtime-revision)))
    report))

(provide 'ebox-incremental)

;;; ebox-incremental.el ends here
