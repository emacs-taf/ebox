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
(require 'ebox-patch-plan)
(require 'ebox-runtime-index)
(require 'ebox-size)

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
                  "ebox-tree"
                  (root &optional validate-participation-p root-parent-kind))
(declare-function ebox-tree-validate-indexed-participation
                  "ebox-tree"
                  (node-table parent-table node-ids
                              &optional source source-index))
(declare-function ebox-tree-clear-runtime-identities
                  "ebox-tree" (root))
(declare-function ebox-tree-copy-node-structure
                  "ebox-tree" (root))
(declare-function ebox-tree-reconcile-runtime
                  "ebox-tree"
                  (old old-source-index new new-source-index))
(declare-function ebox-tree-transfer-runtime-identity
                  "ebox-tree" (old new))
(declare-function ebox-tree-runtime-identity-snapshot
                  "ebox-tree" (root))
(declare-function tp-object-mounts
                  "tp-surface" (object))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox-get "ebox" (box key))
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--runtime-node-ids "ebox" (node))
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
(declare-function ebox--format-content
                  "ebox-layout" (box))
(declare-function ebox-put "ebox" (box key value))
(declare-function ebox--confirm-reflow-prewarm-scratch
                  "ebox" (buffer region-id revision))
(declare-function ebox-cache-publish-report
                  "ebox-cache" (buffer report))
(declare-function ebox-cache-snapshot-report
                  "ebox-cache" (buffer))
(declare-function ebox-cache-restore-report
                  "ebox-cache" (buffer snapshot))
(declare-function ebox-style-cascade-active-p
                  "ebox-style" ())
(declare-function ebox-native-commit-plan-eligible-p
                  "ebox-native-commit"
                  (old-state candidate-state prepared))
(declare-function ebox-native-commit--root-box
                  "ebox-native-commit" (node))
(declare-function ebox-native-commit-root-scroll-continuation-p
                  "ebox-native-commit" (state))
(declare-function ebox-native-commit-prepare-viewport-continuity
                  "ebox-native-commit"
                  (previous-state candidate-state))
(declare-function ebox-native-commit-topology-stable-p
                  "ebox-native-commit" (old-state candidate-state prepared))
(declare-function ebox-native-reflow-release-session
                  "ebox-native-reflow" (session))
(declare-function ebox-layer-host-p "ebox-layer" (node))
(declare-function ebox-layer-subtree-p "ebox-layer" (node))
(declare-function ebox-layer-portals-p "ebox-layer" (node))
(declare-function ebox-layer-visible-portals-p "ebox-layer" (node))
(declare-function ebox-layer-cached-root-scroll-p "ebox-layer" (root state))

(cl-defstruct
    (ebox-incremental-context-port
     (:constructor ebox-incremental-context-port-create))
  "Read-only host queries supplied by the Ebox orchestrator."
  (buffer-state nil :read-only t)
  (region-mounts nil :read-only t)
  (cascade-owner-proof-p nil :read-only t)
  (prepare-inline-styles nil :read-only t))

(defvar ebox-incremental--context-port nil
  "Immutable host-query port installed by the Ebox orchestrator.")

(defun ebox-incremental-install-context-port (port)
  "Install validated immutable incremental context PORT."
  (unless (and (ebox-incremental-context-port-p port)
               (cl-every
                #'functionp
                (list
                 (ebox-incremental-context-port-buffer-state port)
                 (ebox-incremental-context-port-region-mounts port)
                 (ebox-incremental-context-port-cascade-owner-proof-p port)
                 (ebox-incremental-context-port-prepare-inline-styles port))))
    (signal 'wrong-type-argument
            (list 'ebox-incremental-context-port-p port)))
  (setq ebox-incremental--context-port port))

(defun ebox-incremental--require-context-port ()
  "Return the installed incremental context port or fail closed."
  (or ebox-incremental--context-port
      (error "Ebox incremental context port is not installed")))

(defun ebox-incremental--buffer-state (buffer)
  "Return BUFFER's live client state through the context port."
  (funcall
   (ebox-incremental-context-port-buffer-state
    (ebox-incremental--require-context-port))
   buffer))

(defvar ebox-incremental--mount-snapshot-cache nil
  "Read-only TP mount snapshots shared within one publication planning pass.
The planning pass ends before TP can publish new coordinates.")

(defvar ebox-incremental--projection-rejections nil
  "Compact rejected local attempts in the current publication planning pass.")

(defvar ebox-incremental--projection-rejections-enabled-p nil
  "Non-nil while Surface has enabled detailed publication observation.")

(defun ebox-incremental--region-mounts (buffer region-id &optional roles)
  "Read BUFFER mounts for REGION-ID and ROLES from the current planning view.
Private planning readers must not mutate the returned numeric snapshots."
  (let* ((cache ebox-incremental--mount-snapshot-cache)
         (key (and cache (list buffer region-id roles)))
         (cached (and cache (gethash key cache 'ebox/missing-mount-snapshot))))
    (if (and cache (not (eq cached 'ebox/missing-mount-snapshot))) cached
      (let ((mounts
             (funcall
              (ebox-incremental-context-port-region-mounts
               (ebox-incremental--require-context-port))
              buffer region-id roles)))
        (when cache (puthash key mounts cache))
        mounts))))

(defun ebox-incremental--cascade-local-owner-proof-p
    (state candidate-state dirty-set)
  "Return the port proof for STATE, CANDIDATE-STATE, and DIRTY-SET."
  (funcall
   (ebox-incremental-context-port-cascade-owner-proof-p
    (ebox-incremental--require-context-port))
   state candidate-state dirty-set))

(defun ebox-incremental--prepare-inline-candidate-styles
    (old-state candidate-index node-ids)
  "Prepare NODE-IDS in CANDIDATE-INDEX using OLD-STATE through the port."
  (funcall
   (ebox-incremental-context-port-prepare-inline-styles
    (ebox-incremental--require-context-port))
   old-state candidate-index node-ids))

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
(defvar ebox--layout-fragments-table)
(defvar ebox--layout-fragments-reuse-p)

;;; Render Cache

(defvar ebox--render-cache-table nil
  "Dynamic buffer-local render cache used during incremental rerenders.")

(defvar ebox-incremental--render-portals-p 'unknown
  "Whether the current candidate can produce root portal side effects.")

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

(defvar ebox-incremental--source-base-index nil
  "Transaction-local source facts transported by one canonical input.")

(defvar ebox-incremental--previous-source-base-index nil
  "Transaction-local previous source facts for one paired paint proof.")

(defvar ebox-incremental--candidate-incoming-source-indexes nil
  "Transaction-local handle to input-index map for one logical candidate.")

(defvar ebox-incremental--candidate-full-source-base-index nil
  "Transaction-local fact index for one broad candidate rebuild.")

(defun ebox-incremental--candidate-range-items-retainable-p
    (candidate items source-index reuse-map)
  "Return non-nil when ITEMS satisfy the candidate-owned retention proof.

The proof is deliberately narrow: every non-reused node must belong to the
incoming canonical source generation and carry no Ebox runtime identity.
Published reuse slots are skipped because they are replaced by their exact old
objects during canonical reuse.  Canonical input construction has already
checked node/handle uniqueness; this check adds the ownership boundary against
the published candidate base without scanning that base's full tree."
  (let* ((base-state (ebox-candidate--base-state candidate))
         (base-source-index (plist-get base-state :source-index))
         (seen (make-hash-table :test #'eq)))
    (and (ebox-source-index-p source-index)
         (not (eq source-index base-source-index))
         (cl-labels
             ((visit
               (node)
               (and (listp node)
                    (not (stringp node))
                    (not (ebox-child-range--descriptor-p node))
                    (not (gethash node seen))
                    (let ((handle (ebox-tree-node-source-handle node)))
                      (and (ebox-source-index-handle-member-p
                            source-index handle)
                           (not (and base-source-index
                                     (ebox-source-index-handle-member-p
                                      base-source-index handle)))
                           (null (plist-get node :node-id))
                           (null (plist-get node :region-id))
                           (null (plist-get node :surface-object))
                           (null (plist-get node :ebox-sequence-location))
                           (progn
                             (puthash node t seen)
                             (cl-every #'visit
                                       (ebox-tree--children-raw node))))))))
           (cl-loop for item in items for index from 0
                    unless (assq index reuse-map)
                    always (visit item))))))

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
  paint-patches
  range-replacements
  range-metrics
  sealed-p)

(cl-defstruct
    (ebox-incremental--candidate-replacement
     (:constructor ebox-incremental--make-candidate-replacement)
     (:conc-name ebox-incremental--candidate-replacement-))
  "One logical anchor replacement and its optional semantic transition."
  anchor-id
  subtree
  source-index
  old-semantic-key
  new-semantic-key)

(cl-defstruct
    (ebox-incremental--candidate-range-replacement
     (:constructor ebox-incremental--make-candidate-range-replacement)
     (:conc-name ebox-incremental--candidate-range-replacement-))
  "One base-addressed child Range payload replacement."
  ref items reuse-map source-indexes retain-item-identities-p)

(cl-defstruct
    (ebox-incremental--candidate-paint-patch
     (:constructor ebox-incremental--make-candidate-paint-patch)
     (:conc-name ebox-incremental--candidate-paint-patch-))
  "One base-addressed Host paint update without subtree replacement."
  anchor-id node source-index changed-keys)

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

(defun ebox-incremental--proof-base-state (buffer)
  "Return BUFFER's published state while candidate lookups are overridden."
  (or (and ebox-incremental--candidate-base-state
           (eq buffer (car ebox-incremental--candidate-base-state))
           (cdr ebox-incremental--candidate-base-state))
      (ebox--buffer-render-state buffer)))

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

(defvar ebox-incremental--candidate-range-index-deltas nil
  "Transaction-local Range parent and affected payload index deltas.")

(defvar ebox-incremental--candidate-state-for-slot-proof nil
  "Candidate runtime used by bounded allocated-slot impact proofs.")

(defvar ebox-incremental--allocated-slot-proof-cache nil
  "Transaction-local cache of candidate allocated-slot proof results.")

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
             (> (or (gethash 'flex type-counts) 0) 0))
        (and (ebox-runtime-index-like-p node-table)
             (>= (ebox-runtime-index-size node-table)
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

(defvar ebox--inline-auto-width-intrinsic-p)

(defvar ebox--viewport-height-dependent-subtree-cache nil
  "Dynamic render-pass cache for viewport-height dependency checks.")

(defvar ebox--render-cache-allow-viewport-dependent nil
  "Non-nil allows caching viewport-dependent nodes for the current context.")

(defvar ebox--css-viewport-dependent-subtree-cache nil
  "Render-local memo table for explicit CSS viewport dependencies.")
(defvar ebox--size-dependency-properties)

(defun ebox--css-viewport-dependent-subtree-p (node)
  "Return non-nil when NODE's subtree explicitly uses vw or vh.
A fixed containing block cannot isolate these units from the root viewport."
  (cl-labels
      ((value-p (value)
         (when (consp value)
           (if (ebox-size-value-p value t)
               (let ((deps (ebox-size-dependencies value)))
                 (or (memq 'viewport-width deps) (memq 'viewport-height deps)))
             (cl-some #'value-p value))))
       (props-p (props)
         (cl-some (lambda (property) (value-p (plist-get props property)))
                  ebox--size-dependency-properties))
       (compute ()
         (let ((config (plist-get node :ebox-layout-config)))
           (or (props-p node)
               (props-p (plist-get node :props))
               (props-p (plist-get node :raw-props))
               (and config (props-p (ebox-layout-config-props config)))
               (cl-some #'ebox--css-viewport-dependent-subtree-p
                        (ebox--node-children node))))))
    (when (listp node)
      (if (not ebox--css-viewport-dependent-subtree-cache)
          (compute)
        (let* ((missing (make-symbol "missing"))
               (cached (gethash node ebox--css-viewport-dependent-subtree-cache
                                missing)))
          (if (eq cached missing)
              (puthash node (compute) ebox--css-viewport-dependent-subtree-cache)
            cached))))))

(defun ebox--render-cache-contained-viewport-node-p (node)
  "Return non-nil when NODE bounds descendant viewport-dependent layout."
  (and (eq (and (listp node) (plist-get node :ebox-type)) 'box)
       (ebox--span-patch-definite-size-value-p (ebox-get node :width))
       (not (ebox--css-viewport-dependent-subtree-p node))))

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
   ((ebox-child-range--sequence-p value)
    (cons 'ebox-child-sequence
          (mapcar #'ebox--render-cache-value-signature
                  (ebox-child-range--flatten value))))
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
        ;; These fields are deterministic products of rendering the same
        ;; canonical node.  Including them makes the first render populate a
        ;; cache key that becomes unreachable as soon as that render records
        ;; its own proof, forcing every fixed descendant through layout again
        ;; on the first viewport update.
        (unless (memq key '(:render-cache :surface-object
                            :ebox-sequence-location
                            :ebox-content-width-exact-p
                            :ebox-content-layout-complete-p))
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
  ;; Cache signatures include rendered region identity because cached text
  ;; properties carry that identity.  Materialize both identity domains
  ;; before memoizing the body signature; otherwise the first cache probe can
  ;; run before `ebox--render-box' assigns :region-id and every later probe
  ;; misses solely because the same node has since been rendered.
  (when (listp node)
    (ebox--runtime-node-ids node)
    (ebox--node-all-region-ids node))
  (list (ebox--current-display-signature)
        (when (ebox--css-viewport-dependent-subtree-p node)
          (list ebox--css-viewport-width ebox--css-viewport-height))
        (when (and (ebox--viewport-dependent-subtree-p node)
                   (not (ebox--render-cache-contained-viewport-node-p
                         node)))
          ebox-viewport-width)
        (when (ebox--viewport-height-dependent-subtree-p node)
          ebox-viewport-height)
        ebox--intrinsic-layout-measurement
        ebox--inline-auto-width-intrinsic-p
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
  (when-let* ((metadata
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
      (setq rendered (ebox--render-node node)))
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
            (when-let* ((box (ebox--root-region-box node region-id)))
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
  (when-let* ((context
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
  (if (and ebox-incremental--render-portals-p
           (fboundp 'ebox-layer-visible-portals-p)
           (ebox-layer-visible-portals-p node))
      ;; Cached strings do not replay the candidate-local portal collector.
      (ebox--render-node node)
   (if-let* ((prepared (and force
                          (ebox--take-prepared-root-render node))))
      (prog1 prepared
        (ebox--replay-render-output-provenance prepared)
        (ebox--flex-recache-source-boxes node))
    (let ((probe (or cache-probe
                     (ebox--render-cache-probe node force))))
      (cond
       ((null probe)
        (ebox--render-node node))
       ((plist-member probe :rendered)
        (ebox--replay-render-output-provenance
         (plist-get probe :rendered)))
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
            (ebox--render-cache-store-context probe rendered metadata)
            (ebox--record-render-output-provenance rendered))
          rendered)))))))

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
    (or (and (buffer-live-p buffer)
             (ebox-incremental--buffer-state buffer))
        (gethash buffer ebox--buffer-render-state-table))))

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
  (when-let* ((root (ebox--buffer-root-node buffer)))
    (ebox--ensure-node-id root)))

(defun ebox--runtime-region-id-conflict (region-id-set target-buffer)
  "Return `(REGION-ID . BUFFER)' for REGION-ID-SET outside TARGET-BUFFER."
  (ebox--prune-dead-buffer-render-states)
  (let ((target (and target-buffer (get-buffer target-buffer))))
    (catch 'conflict
      (maphash
       (lambda (buffer state)
         (unless (eq buffer target)
           (when-let* ((owner-set (plist-get state :region-id-set)))
             (maphash
              (lambda (region-id _present)
                (when (gethash region-id owner-set)
                  (throw 'conflict (cons region-id buffer))))
              region-id-set))))
       ebox--buffer-render-state-table)
      nil)))


(defun ebox-incremental--adjust-runtime-type-count (table node delta)
  "Adjust NODE's raw selector-type count in TABLE by DELTA."
  (when-let* ((type (ebox-tree-node-selector-type node)))
    (let ((count (+ (or (gethash type table) 0) delta)))
      (cond
       ((< count 0)
        (error "Ebox runtime type count became negative: %S" type))
       ((= count 0) (remhash type table))
       (t (puthash type count table))))))

(defun ebox--runtime-index
    (root-node &optional collect-region-boxes source-index)
  "Return persistent runtime indexes for ROOT-NODE.
When COLLECT-REGION-BOXES is non-nil, collect `:region-box-table' during the
same traversal in complete-render overwrite order.  SOURCE-INDEX, when
supplied, is the candidate-owned source snapshot for ROOT-NODE."
  (let ((node-table (ebox-runtime-index-empty))
        (parent-table (ebox-runtime-index-empty))
        (region-id-set (make-hash-table :test 'equal))
        (region-node-table (ebox-runtime-index-empty))
        (region-box-table
         (and collect-region-boxes (make-hash-table :test 'equal)))
        (region-box-count-table (make-hash-table :test 'equal))
        (host-ref-table (make-hash-table :test 'equal))
        (range-ref-table (make-hash-table :test 'equal))
        (runtime-type-count-table (make-hash-table :test 'eq))
        native-node-postorder)
    (cl-labels ((index-host-ref (node node-id)
                  (when-let* ((handle (plist-get node :ebox-source-handle))
                              (host-ref (ebox-source--handle-id-view handle)))
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
                       (unless (ebox-runtime-index-get region-id region-node-table)
                         (setq region-node-table
                               (ebox-runtime-index-put
                                region-id node-id region-node-table)))))
                    ('flex
                     (when-let* ((box (plist-get node :box)))
                       (let ((region-id (ebox--ensure-region-id box)))
                         (puthash region-id t region-id-set)
                         ;; Preserve the recursive lookup's first-match
                         ;; semantics when malformed trees reuse a region id.
                         (unless (ebox-runtime-index-get region-id region-node-table)
                           (setq region-node-table
                                 (ebox-runtime-index-put
                                  region-id node-id
                                  region-node-table))))))))
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
                       (when-let* ((box (plist-get node :box)))
                         (puthash (ebox--ensure-region-id box)
                                  box region-box-table))))))
                (visit (node parent-id native-layout-p)
                  (when (and (listp node)
                             (not (stringp node)))
                    (let ((node-id (ebox--ensure-node-id node))
                          (type (plist-get node :ebox-type)))
                      (setq node-table
                            (ebox-runtime-index-put node-id node node-table))
                      (ebox-incremental--adjust-runtime-type-count
                       runtime-type-count-table node 1)
                      (when parent-id
                        (setq parent-table
                              (ebox-runtime-index-put
                               node-id parent-id parent-table)))
                      (index-region-id node node-id)
                      (index-host-ref node node-id)
                      (when-let* ((sequence (plist-get node :ebox-child-sequence)))
                        (dotimes
                            (segment-index
                             (ebox-child-range--sequence-count sequence))
                          (let ((payload
                                 (ebox-child-range--segment-payload
                                  (ebox-child-range--segment-at
                                   sequence segment-index))))
                            (dotimes (offset (length payload))
                              (let ((child (aref payload offset)))
                                (ebox--ensure-node-id child)
                                (plist-put child :ebox-sequence-location
                                           (list :parent-node-id node-id
                                                 :segment-index segment-index
                                                 :offset offset))))))
                        (dolist (record
                                 (ebox-child-range--range-records sequence))
                          (pcase-let ((`(,ref ,segment-index) record))
                            (when (gethash ref range-ref-table)
                              (error "Ebox child Range ref is not unique: %S" ref))
                            (puthash ref
                                     (list :parent-node-id node-id
                                           :segment-index segment-index)
                                     range-ref-table))))
                      (ebox-tree-for-each-direct-child
                       node
                       (lambda (child)
                         (visit
                          child node-id
                          (and native-layout-p
                               (not (and (eq type 'flex)
                                         (eq child
                                             (plist-get node :box))))))))
                      (index-region-box node)
                      ;; This is the same child-before-parent order used by
                      ;; the recursive Layout IR compiler.  Flex wrapper
                      ;; source boxes are indexed for ownership without adding
                      ;; duplicate compiler work.
                      (when native-layout-p
                        (push node-id native-node-postorder))))))
      (visit root-node nil t))
    (setq source-index (or source-index (ebox-tree-source-index root-node)))
    (setq source-index
          (ebox-source--with-runtime-hosts source-index host-ref-table))
    (let ((postorder (vconcat (nreverse native-node-postorder))))
      (list :node-table node-table
            :parent-table parent-table
            :region-id-set region-id-set
            :region-node-table region-node-table
            :region-box-table region-box-table
            :region-box-count-table region-box-count-table
            :range-ref-table range-ref-table
            :source-index source-index
            :selector-id-table
            (ebox-source--index-selector-table source-index 'id)
            :selector-class-table
            (ebox-source--index-selector-table source-index 'class)
            :selector-type-table
            (ebox-source--index-selector-table source-index 'type)
            :runtime-type-count-table runtime-type-count-table
            :native-node-postorder postorder
            :native-node-postorder-ids postorder))))

(defun ebox-incremental--ensure-buffer-selector-indexes (buffer)
  "Return BUFFER's state after materializing deferred selector indexes."
  (let ((state (ebox--buffer-render-state buffer)))
    (when (and state (plist-get state :selector-index-stale-p))
      (let* ((source-index
              (ebox-source--with-runtime-hosts
               (ebox-tree-source-index
                (plist-get state :root-node) nil nil
                (plist-get state :source-index))
               (ebox-source--index-host-ref-table-view
                (plist-get state :source-index))))
             (index
              (list :selector-id-table
                    (ebox-source--index-selector-table source-index 'id)
                    :selector-class-table
                    (ebox-source--index-selector-table source-index 'class)
                    :selector-type-table
                    (ebox-source--index-selector-table source-index 'type))))
        (setq state (plist-put state :source-index source-index))
        (dolist (key '(:selector-id-table
                       :selector-class-table
                       :selector-type-table))
          (setq state (plist-put state key (plist-get index key))))
        (setq state (plist-put state :selector-index-stale-p nil))
        (puthash buffer state ebox--buffer-render-state-table)))
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
        :layout-fragments (make-hash-table :test 'equal)
        :layout-fragments-reuse-p nil
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
                 :region-box-count-table :region-box-table
                 :range-ref-table :source-index
                 :selector-id-table :selector-class-table
                 :selector-type-table :runtime-type-count-table
                 :native-node-postorder :native-node-postorder-ids))
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

(defun ebox--buffer-source-index (buffer)
  "Return BUFFER's retained immutable source index."
  (plist-get (ebox--buffer-render-state buffer) :source-index))

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
  (when-let* ((index
               (plist-get (ebox--buffer-render-state buffer) :source-index)))
    (ebox-source--index-host-ref-table-view index)))

(defun ebox-incremental--range-ref-resolve (state ref)
  "Resolve REF in STATE to its parent, sequence, segment index, and rank."
  (when-let* ((record (gethash ref (plist-get state :range-ref-table)))
              (parent (ebox-runtime-index-get (plist-get record :parent-node-id)
                               (plist-get state :node-table)))
              (sequence (plist-get parent :ebox-child-sequence)))
    (list :parent parent :sequence sequence
          :segment-index (plist-get record :segment-index)
          :rank (ebox-child-range--rank
                 sequence (plist-get record :segment-index)))))

(defun ebox--buffer-region-render-owner-node-id (buffer region-id)
  "Return REGION-ID's smallest render-owner node id in BUFFER.
Use the persistent runtime index when available.  Legacy runtime states that
lack the index, or an indexed entry, fall back to a recursive tree lookup."
  (or (when-let* ((table (ebox--buffer-region-node-table buffer)))
        (ebox-runtime-index-get region-id table))
      (when-let* ((root (ebox--buffer-root-node buffer))
                  (path (ebox--node-path-to-region root region-id)))
        (ebox--ensure-node-id (car path)))))

(defun ebox--buffer-region-render-owner-node (buffer region-id)
  "Return REGION-ID's smallest render-owner node in BUFFER.
Use both persistent runtime indexes in the normal path.  Fall back to the
recursive region path only for legacy or incomplete runtime state."
  (when-let* ((node-id
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
  (when-let* ((state (ebox--buffer-render-state buffer)))
    (let ((revision
           (1+ (or (plist-get state :runtime-revision) 0))))
      (plist-put state :runtime-revision revision)
      (unless preserve-reflow-prewarm-scratch
        (plist-put state :reflow-prewarm-scratch nil))
      revision)))

(defun ebox--buffer-viewport-dependent-node-id-axes (buffer)
  "Return cached viewport-dependent node ids by axis for BUFFER."
  (when-let* ((state (ebox--buffer-render-state buffer)))
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
  (when-let* ((state (ebox--buffer-render-state buffer)))
    (ebox--buffer-viewport-dependent-node-id-axes buffer)
    (plist-get state :viewport-dependent-node-ids)))

(defun ebox--invalidate-buffer-viewport-dependencies (buffer)
  "Invalidate BUFFER's cached viewport dependency list."
  (when-let* ((state (ebox--buffer-render-state buffer)))
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

(defun ebox--layout-snapshot-buffer-spans-valid-p (buffer snapshot)
  "Return non-nil when SNAPSHOT spans still fit BUFFER's live range."
  (let ((spans (plist-get snapshot :buffer-spans)))
    (or (null spans)
        (and (buffer-live-p buffer)
             (let ((minimum (with-current-buffer buffer (point-min)))
                   (maximum (with-current-buffer buffer (point-max))))
               (cl-every
                (lambda (span)
                  (and (consp span)
                       (integerp (car span))
                       (integerp (cdr span))
                       (<= minimum (car span))
                       (<= (car span) (cdr span))
                       (<= (cdr span) maximum)))
                spans))))))

(defun ebox--buffer-layout-snapshot-detail-generation (buffer)
  "Return BUFFER's current layout snapshot detail generation."
  (or (plist-get (ebox--buffer-render-state buffer)
                 :layout-snapshot-detail-generation)
      0))

(defun ebox--layout-snapshot-details-current-p (buffer snapshot)
  "Return non-nil when SNAPSHOT's buffer-dependent detail fields are current."
  (or (not (cl-some (lambda (key) (plist-member snapshot key))
                    ebox--layout-snapshot-detail-keys))
      (and (= (or (plist-get snapshot :detail-generation) -1)
              (ebox--buffer-layout-snapshot-detail-generation buffer))
           (ebox--layout-snapshot-buffer-spans-valid-p buffer snapshot))))

(defun ebox--layout-snapshot (buffer node-id)
  "Return BUFFER's layout snapshot for NODE-ID."
  (when-let* ((snapshots (ebox--ensure-buffer-layout-snapshots buffer)))
    (let ((snapshot (or (gethash node-id snapshots)
                        (when-let* ((node (ebox--snapshot-published-node
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
  (when-let* ((state (ebox--buffer-render-state buffer)))
    (when (and (plist-get state :root-node)
               (not (plist-get state :layout-snapshots-complete-p)))
      (ebox--refresh-buffer-layout-snapshots buffer details)))
  (let ((copy (make-hash-table :test 'equal)))
    (when-let* ((snapshots (ebox--ensure-buffer-layout-snapshots buffer)))
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
  (when-let* ((state (ebox--buffer-render-state buffer)))
    (plist-put state :layout-snapshots-complete-p nil))
  (when-let* ((snapshots (ebox--ensure-buffer-layout-snapshots buffer)))
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
  (let* ((buffer (or buffer (current-buffer)))
         (state (gethash buffer ebox--buffer-render-state-table))
         (native-session (plist-get state :native-sync-session)))
    (when-let* ((cache (ebox--buffer-render-cache buffer)))
      (when-let* ((root-cache
                  (gethash cache ebox--render-root-cache-table-table)))
        (remhash root-cache ebox--render-cache-ring-table))
      (remhash cache ebox--render-root-cache-table-table)
      (remhash cache ebox--render-cache-ring-table))
    (remhash buffer ebox--buffer-render-state-table)
    (remhash buffer ebox-incremental--batch-table)
    (ebox-cache-discard-report buffer)
    (when (and native-session (require 'ebox-native-reflow nil t))
      (ebox-native-reflow-release-session native-session))))

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
      (when-let* ((region-id (get-text-property pos (cdr entry))))
        (cl-pushnew region-id ids :test #'equal)))
    ids))

(defun ebox--pos-region-role-ids (pos)
  "Return all ebox region role/id pairs present at POS."
  (let (role-ids)
    (dolist (entry ebox-region-types)
      (when-let* ((region-id (get-text-property pos (cdr entry))))
        (push (cons (car entry) region-id) role-ids)))
    role-ids))

(defun ebox--next-region-property-change (pos limit)
  "Return the next possible region boundary after POS, capped at LIMIT.
An unrelated property may split a region run; ownership indexes merge those
adjacent ranges.  One native interval lookup avoids searching the same string
separately for every role property."
  (or (next-property-change pos nil limit) limit))

(defun ebox--index-add-region-line-range
    (region-lines region-id line-number start end)
  "Record REGION-ID ownership from START to END on LINE-NUMBER."
  (let ((line-map (or (gethash region-id region-lines)
                      (let ((map (make-hash-table :test 'eql)))
                        (puthash region-id map region-lines)
                        map))))
    (if-let* ((range (gethash line-number line-map)))
        (setcdr range (max (cdr range) end))
      (puthash line-number (cons start end) line-map))))

(defun ebox--build-region-line-index (&optional include-owner-stacks-p)
  "Return a per-line index of ebox region ownership in the current buffer.
INCLUDE-OWNER-STACKS-P includes retained wrapper ownership in an unmounted
scroll cache, whose nested owners have no TP role mounts yet."
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
                           (append (mapcar #'cdr (copy-sequence role-ids))
                                   (and include-owner-stacks-p
                                        (copy-sequence (get-text-property pos 'ebox-content-owners))))))
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
      (when-let* ((line-map (gethash region-id region-lines)))
        (maphash
         (lambda (line-number range)
           (if-let* ((existing (gethash line-number candidate-lines)))
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
            (if-let* ((existing (gethash line-start line-ranges)))
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
               (ebox-incremental--region-mounts
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
                 (ebox-incremental--region-mounts buffer region-id roles))
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
        (ebox-runtime-index-get node-id node-table))
      (ebox--buffer-runtime-node buffer node-id)))

(defun ebox--ensure-layout-snapshot-spans (buffer node-id)
  "Ensure BUFFER's stored snapshot for NODE-ID has buffer span details."
  (when-let* ((snapshot (ebox--layout-snapshot buffer node-id)))
    (if (ebox--layout-snapshot-spans-p snapshot)
        snapshot
      (when-let* ((node (ebox--snapshot-published-node buffer node-id)))
        (let ((detailed
               (ebox--with-layout-snapshot-detail-context buffer
                 (ebox--complete-layout-snapshot-spans
                  buffer node snapshot))))
          (ebox--put-layout-snapshot buffer node-id detailed)
          detailed)))))

(defun ebox--ensure-layout-snapshot-details (buffer node-id)
  "Ensure BUFFER's stored snapshot for NODE-ID has expensive detail fields."
  (when-let* ((snapshot (ebox--layout-snapshot buffer node-id)))
    (if (ebox--layout-snapshot-detailed-p snapshot)
        snapshot
      (when-let* ((node (ebox--snapshot-published-node buffer node-id)))
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
  (when-let* ((root (ebox--buffer-root-node buffer)))
    (ebox--clear-layout-snapshots buffer)
    (let ((ebox--node-region-ids-cache (make-hash-table :test 'eq)))
      (if details
          (ebox--with-layout-snapshot-index-context buffer
            (ebox--capture-layout-snapshots buffer root t))
        (ebox--capture-layout-snapshots buffer root)))
    (when-let* ((state (ebox--buffer-render-state buffer)))
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
           (ebox-runtime-index-get node-id
                    (cdr ebox-incremental--candidate-proof-node-table)))
      (when-let* ((node-table (ebox--buffer-node-table buffer)))
        (ebox-runtime-index-get node-id node-table))
      (when-let* ((root (ebox--buffer-root-node buffer)))
        (ebox--runtime-node-by-id root node-id))))

(defun ebox--runtime-parent-id (buffer node-id)
  "Return NODE-ID's parent id in BUFFER runtime state."
  (when-let* ((parent-table (ebox--buffer-parent-table buffer)))
    (ebox-runtime-index-get node-id parent-table)))

(defun ebox--invalidate-runtime-render-signature-path
    (node-id node-table parent-table signature-cache height-cache)
  "Invalidate NODE-ID to root in explicit runtime structural caches."
  (if (null node-id)
      (progn
        (when signature-cache (clrhash signature-cache))
        (when height-cache (clrhash height-cache)))
    (while node-id
      (when-let* ((node (ebox-runtime-index-get node-id node-table)))
        (when signature-cache (remhash node signature-cache))
        (when height-cache (remhash node height-cache)))
      (setq node-id (ebox-runtime-index-get node-id parent-table)))))

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
    ('native-frame 4)
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
   (append (when-let* ((node-id (plist-get dirty :node-id)))
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
    (if-let* ((dominator
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
  "Return non-nil when VALUE has no external layout-size dependency.
Private used numbers and fixed CSS expressions admit local footprint proofs.
Keywords, percentages, and viewport units still require containing-layout
evidence rather than a value resolved in the current ambient viewport."
  (or (numberp value)
      (and (ebox-size-value-p value)
           (not (cl-intersection
                 '(percent viewport-width viewport-height)
                 (ebox-size-dependencies value))))))

(defun ebox--span-patch-used-size (node value axis)
  "Return fixed VALUE in NODE's used units on AXIS, or nil without proof.
Horizontal geometry uses pixels and vertical geometry uses text lines."
  (when (ebox--span-patch-definite-size-value-p value)
    (if (numberp value)
        value
      (when-let* ((pixels (ebox--size-pixels
                          value node (if (eq axis 'vertical) 'height 'width))))
        (if (eq axis 'vertical)
            (/ (max 0 pixels) (float (ebox--size-line-height node)))
          (max 0 pixels))))))

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
                         (memq key ebox--paint-style-signature-keys)
                         (memq key ebox--typography-style-signature-keys)))
                   changed-keys))))

(defun ebox--border-box-inline-content-fits-p (style-node)
  "Return non-nil when STYLE-NODE's inline chrome fits its fixed width."
  (let ((width (ebox--span-patch-used-size
                style-node (ebox-get style-node :width) 'horizontal)))
    (and (numberp width)
         (>= width
             (+ (ebox-get style-node :padding-left-pixel)
                (ebox-get style-node :padding-right-pixel)
                (ebox-get style-node :border-left-pixel)
                (ebox-get style-node :border-right-pixel))))))

(defun ebox--border-box-block-content-fits-p (style-node)
  "Return non-nil when STYLE-NODE's block padding leaves one content line."
  (let ((height (ebox--span-patch-used-size
                 style-node (ebox-get style-node :height) 'vertical)))
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
   ;; Typography is local to the rendered fragment but may change its pixel
   ;; footprint.  Authorize the same exact-footprint attempt as content;
   ;; Surface rejects wrapping or allocation changes before publication.
   ((memq key ebox--typography-style-signature-keys)
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
         (ebox--span-patch-definite-size-value-p
          (ebox-get style-node :height)))
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

(defun ebox--dirty-entry-geometry-owner-id (buffer entry)
  "Return ENTRY's node that owns geometry in BUFFER.
Text retains content identity and paint provenance, while its containing Box
owns the allocated layout slot.  Keep the dirty entry addressed to Text, but
classify and prove a Text content change against that parent Box."
  (let* ((source-node-id (plist-get entry :node-id))
         (source-node (and source-node-id
                           (ebox--buffer-runtime-node buffer source-node-id))))
    (if (and (eq (plist-get entry :dirty-kind) 'geometry)
             (eq (plist-get source-node :ebox-kind) 'text)
             (memq :content (plist-get entry :changed-keys)))
        (or (ebox--runtime-parent-id buffer source-node-id)
            source-node-id)
      source-node-id)))

(defun ebox--dirty-entry-impact-vector (buffer entry)
  "Return normalized impact vector for dirty ENTRY in BUFFER."
  (let* ((node-id (ebox--dirty-entry-geometry-owner-id buffer entry))
         (node (and node-id (ebox--buffer-runtime-node buffer node-id)))
         (style-node (and node (ebox-fragment-style-source-node node)))
         impacts)
    (dolist (key (plist-get entry :changed-keys))
      (dolist (impact (ebox--changed-key-impact key style-node))
        (cl-pushnew impact impacts)))
    ;; An auto-width content box contributes its intrinsic width to the
    ;; enclosing stack.  Its text change can therefore move every later
    ;; sibling even when the local box remains span-patchable.  Equal-length
    ;; candidates may reach the final footprint proof; that proof still
    ;; rejects pixel-width, wrapping, or unstable parent-allocation changes.
    (when (and style-node
               (memq :content (plist-get entry :changed-keys))
               (not (ebox--span-patch-definite-size-value-p
                     (ebox-get style-node :width)))
               (not (let ((old-content
                           (plist-get (plist-get entry :old-signature)
                                      :content))
                          (new-content
                           (plist-get (plist-get entry :new-signature)
                                      :content)))
                      (and (stringp old-content)
                           (stringp new-content)
                           (= (length old-content) (length new-content)))))
               (not (and ebox-incremental--candidate-state-for-slot-proof
                         (or
                          (ebox-incremental--fast-grid-slot-evidence
                           buffer entry
                           ebox-incremental--candidate-state-for-slot-proof)
                          (ebox-incremental--allocated-parent-slot-stable-p
                           buffer entry
                           ebox-incremental--candidate-state-for-slot-proof)))))
      (cl-pushnew 'parent-layout impacts))
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
         (geometry-owner-id
          (if (and buffer (eq dirty-kind 'geometry))
              (ebox--dirty-entry-geometry-owner-id buffer entry)
            node-id))
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
       (if-let* ((span-owner-id
                 (and buffer
                      (ebox--span-patch-owner-id-for-dirty-entry
                       entry buffer))))
           (ebox--patch-op 'span-patch span-owner-id
                           :dirty entry)
         (let ((fallback-owner-id
                (or (and buffer
                         requires-owned-overflow-coverage
                         (or (ebox--next-patchable-owner-ancestor
                              buffer geometry-owner-id dirty-kind t)
                             (ebox--buffer-root-node-id buffer)))
                    (and buffer
                         (or (memq 'size-interpretation impact-vector)
                             (not
                              (ebox--impact-vector-requires-conservative-owner-p
                               impact-vector)))
                         (ebox--promote-to-patchable-owner
                          buffer geometry-owner-id dirty-kind
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
          (max-height (ebox-get style-node :max-height))
          (auto-min-independent
           (let* ((parent-id (ebox--runtime-parent-id buffer node-id))
                  (parent (and parent-id
                               (ebox--buffer-runtime-node buffer parent-id))))
             (not (memq (and parent (ebox--display-inner parent)) '(flex grid))))))
      (and (ebox--definite-containment-inline-size-value-p
            (ebox-get style-node :width))
           (or (null min-width)
               (and auto-min-independent (eq min-width 'auto))
               (ebox--definite-containment-inline-size-value-p min-width))
           (or (null max-width)
               (eq max-width 'none)
               (ebox--definite-containment-inline-size-value-p max-width))
           (ebox--span-patch-definite-size-value-p (ebox-get style-node :height))
           (or (null min-height)
               (and auto-min-independent (eq min-height 'auto))
               (ebox--span-patch-definite-size-value-p min-height))
           (or (null max-height)
               (eq max-height 'none)
               (ebox--span-patch-definite-size-value-p max-height))
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
         (ebox--span-patch-definite-size-value-p
          (ebox-get style-node :height)))))

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
     (equal (plist-get child :node-id) node-id))
   (ebox-tree-layout-children flex-node)))

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
                    (ebox-style-no-soft-wrap-p
                     (ebox-get style-node :wrap-mode)))
               (ebox--with-buffer-render-context buffer
                 (ebox--render-node style-node))
             "")))
      (<= (ebox--flex-min-main style-node rendered axis)
          current-main))))

(defun ebox--flex-fixed-basis-content-allocation-stable-p
    (style-node item-props axis)
  "Return non-nil when content cannot affect a fixed-basis flex allocation.

A definite basis owns the item's base size.  An explicit zero main-axis
minimum removes the content-minimum clamp, so grow/shrink allocation depends
only on the stable container and sibling flex inputs.  Cross-axis compatibility
is still verified by the existing rendered slot-footprint proof."
  (let* ((size-axis (if (eq axis 'row) 'horizontal 'vertical))
         (basis (ebox--span-patch-used-size
                 style-node (plist-get item-props :flex-basis) size-axis))
         (minimum
          (ebox--span-patch-used-size
           style-node
           (ebox-get style-node (if (eq axis 'row) :min-width :min-height))
           size-axis)))
    (and (numberp basis) (>= basis 0)
         (numberp minimum) (= minimum 0))))

(defun ebox--flex-item-fixed-basis-content-allocation-stable-p
    (buffer node-id)
  "Return whether NODE-ID has a content-independent fixed flex basis."
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
              (parent-id (ebox--runtime-parent-id buffer node-id))
              (parent (ebox--buffer-runtime-node buffer parent-id))
              ((eq (ebox--display-inner parent) 'flex))
              (child (ebox--flex-child-for-source-node parent node-id))
              (style-node (ebox-fragment-style-source-node node)))
    (ebox--flex-fixed-basis-content-allocation-stable-p
     style-node (ebox--flex-item-props child) (ebox--flex-main-axis parent))))

(defun ebox--flex-slot-allocation-stable-p
    (buffer node child axis current-main changed-keys)
  "Return non-nil when CHANGED-KEYS preserve NODE's flex allocation.
Unknown changes fail closed.  A fixed outer size is insufficient for content
updates unless the auto flex basis stays fixed and the new minimum still fits
the already published slot."
  (when-let* ((style-node (ebox-fragment-style-source-node node)))
    (let* ((item-props (ebox--flex-item-props child))
           (fixed-basis-p
            (ebox--flex-fixed-basis-content-allocation-stable-p
             style-node item-props axis)))
      (and changed-keys
           ;; A fixed basis plus zero main minimum makes content independent
           ;; of main allocation.  Admit cross-axis content changes to the
           ;; retained-slot render; stretch sizes the candidate to the old
           ;; cross slot, while non-stretch items remain natural and fail the
           ;; final footprint comparison if their block size changed.
           (or fixed-basis-p
               (cl-every
                (lambda (key)
                  (and (not (ebox--flex-main-footprint-key-p
                             key axis style-node))
                       (not (ebox--flex-main-footprint-key-p
                             key (ebox--flex-cross-axis axis) style-node))))
                changed-keys))
           (or fixed-basis-p
               (not (cl-some #'ebox--flex-content-flow-main-key-p
                             changed-keys))
               (ebox--flex-content-allocation-stable-p
                buffer style-node item-props axis current-main))))))

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
        (ebox--render-node sized-node)
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
                  (ebox--render-node node)))
             (role-owned-lines-p
              (ebox--flex-item-fixed-basis-content-allocation-stable-p
               buffer node-id))
             (owned-rendered
              (if role-owned-lines-p
                  (ebox-buffer--rendered-owned-lines
                   rendered (plist-get snapshot :region-ids) (length spans))
                rendered))
             (owner-set (ebox--region-id-set
                         (plist-get snapshot :region-ids)))
             (slot-rendered
              (and owned-rendered
                   (with-current-buffer buffer
                     (ebox-buffer--rendered-in-existing-slots
                      spans owned-rendered
                      (and role-owned-lines-p owner-set)))))
             (final-rendered slot-rendered)
             (new-span-footprint
              (and final-rendered
                   (ebox--rendered-span-footprint-signature final-rendered)))
             (new-external-footprint
              (and new-span-footprint
                   (ebox--external-footprint-signature-from-span-footprint
                    new-span-footprint)))
             (new-parent-slot
              (and new-span-footprint
                   (ebox--project-parent-slot-signature
                    old-parent-slot new-span-footprint))))
        (and final-rendered
             (ebox--span-footprint-compatible-p
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
  (ignore own-change)
  (and (ebox--direct-flex-parent-p buffer node-id)
       (or (not (ebox--flex-item-footprint-keys-p
                 buffer node-id changed-keys))
           ;; A definite item whose published slot equals its declared main
           ;; size remains allocation-stable even when its own content changes.
           ;; The following slot-footprint proof still renders the candidate
           ;; in that size and rejects wrapping/overflow/parent-slot misses.
           (ebox--flex-item-slot-at-declared-main-p buffer node-id)
           (ebox--flex-item-fixed-basis-content-allocation-stable-p
            buffer node-id))
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
      (let* ((ebox--render-source-index
              (plist-get (ebox--buffer-render-state buffer) :source-index))
             (partial-slot (ebox--partial-slot-owner-p buffer node-id))
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
  (when-let* ((node (ebox--buffer-runtime-node buffer node-id)))
    (and ;; Planning only needs to reject an explicitly visible overflow
         ;; owner.  Content-dependent overflow remains part of the final
         ;; span/role validator; formatting it here for every ancestor made
         ;; owner selection pay the expensive proof twice.
         (not (eq (ebox-get node :overflow) 'visible))
         (or
          ;; Allocation shape is coordinate-independent and survives a
          ;; detail-generation bump.  The later owner/surface proof still
          ;; resolves exact current spans before publication.
          (when-let* ((snapshot (ebox--layout-snapshot buffer node-id)))
            (plist-get snapshot :allocation-shape))
          (when-let* ((snapshot
                       (ebox--ensure-layout-snapshot-spans buffer node-id))
                      (spans (plist-get snapshot :buffer-spans)))
            spans)))))

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

(defun ebox--span-patch-owner-id-for-dirty-entry (entry buffer)
  "Return a local span patch owner for ENTRY in BUFFER, or nil."
  (let* ((dirty-kind (plist-get entry :dirty-kind))
         (source-node-id (plist-get entry :node-id))
         (node-id (ebox--dirty-entry-geometry-owner-id buffer entry))
         (source-parent-id
          (and source-node-id
               (ebox--runtime-parent-id buffer source-node-id)))
         (source-parent
          (and source-parent-id
               (ebox--buffer-runtime-node buffer source-parent-id)))
         (source-parent-kind
          (and source-parent (ebox-tree-display-inner source-parent)))
         (fast-grid-evidence
          (and ebox-incremental--candidate-state-for-slot-proof
               (eq dirty-kind 'geometry)
               (memq :content (plist-get entry :changed-keys))
               (ebox-incremental--fast-grid-slot-evidence
                buffer entry
                ebox-incremental--candidate-state-for-slot-proof)))
         (impact-vector (or (plist-get entry :impact-vector)
                            (and (plist-get entry :changed-keys)
                                 (ebox--dirty-entry-impact-vector
                                  buffer entry)))))
    (unless (ebox--impact-vector-requires-conservative-owner-p impact-vector)
      (cond
       (fast-grid-evidence
        node-id)
       ((and ebox-incremental--candidate-state-for-slot-proof
             (eq dirty-kind 'geometry)
             (memq :content (plist-get entry :changed-keys))
             ;; The one-line source-slot proof only accepts Row/Column
             ;; parents.  Reject Flow/Flex/Grid here before it materializes
             ;; snapshots and walks an ancestor certificate that its own
             ;; final predicate would discard.
             (memq source-parent-kind '(row column))
             (ebox-incremental--content-slot-stable-p
              buffer entry
              ebox-incremental--candidate-state-for-slot-proof))
        source-node-id)
       ((and ebox-incremental--candidate-state-for-slot-proof
             (not (equal source-node-id node-id))
             (eq dirty-kind 'geometry)
             (memq :content (plist-get entry :changed-keys))
             (or (ebox-incremental--content-independent-allocation-p
                  (ebox--buffer-render-state buffer) node-id)
                 (cl-some
                  (lambda (signature)
                    (let ((content (plist-get signature :content)))
                      (and (stringp content) (string-match-p "\n" content))))
                  (list (plist-get entry :old-signature)
                        (plist-get entry :new-signature))))
             ;; Canonical Text owns the content identity; its Box owns the
             ;; allocated slot.  The same proof handles both one-line text
             ;; and bounded multiline content; source identity alone must
             ;; not promote a local text change to the parent layout.
             (ebox-incremental--content-slot-stable-p
              buffer (plist-put (copy-sequence entry) :node-id node-id)
              ebox-incremental--candidate-state-for-slot-proof))
        node-id)
       ((and (ebox--dirty-entry-span-patch-candidate-p buffer entry)
             (not (ebox--impact-vector-requires-parent-promotion-p
                   impact-vector))
             (not (cl-some
                   (lambda (key)
                     (memq key ebox--span-patch-border-box-block-keys))
                   (plist-get entry :changed-keys)))
             (ebox--cached-patchable-owner-p buffer node-id 'span)
             (or (not (ebox--direct-flex-parent-p buffer node-id))
                 (ebox--flex-item-slot-safe-p
                  buffer node-id (plist-get entry :changed-keys) t)
                 (ebox--flex-item-fixed-basis-content-allocation-stable-p
                  buffer node-id)
                 (and ebox-incremental--candidate-state-for-slot-proof
                      (ebox-incremental--allocated-parent-slot-stable-p
                       buffer entry
                       ebox-incremental--candidate-state-for-slot-proof))))
       node-id)
       ((and (eq dirty-kind 'geometry)
             (plist-get entry :changed-keys))
        (or (and (ebox--block-size-change-p
                  (plist-get entry :changed-keys))
                 (ebox--block-size-containment-owner-id buffer node-id))
            (ebox--promote-to-span-patchable-owner
             buffer node-id dirty-kind
             (plist-get entry :changed-keys))))))))

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
         (when-let* ((entry (gethash ancestor-id owner-table)))
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
               (eq (plist-get result :op) 'native-frame))
             results)
    'native-frame)
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
      (memq value '(stretch fit-content))
      (ebox--size-data-viewport-dependent-p value 'viewport-width)))

(defun ebox--size-data-viewport-dependent-p (value axis)
  "Return non-nil when size VALUE depends on viewport AXIS.
Descend through track and shorthand lists as well as size expressions.
Percentages conservatively depend on both axes: the containing block may
itself obtain either dimension through an aspect or cross-axis constraint."
  (when (consp value)
    (if (ebox-size-value-p value t)
        (let ((dependencies (ebox-size-dependencies value)))
          (or (memq axis dependencies) (memq 'percent dependencies)))
      (cl-some (lambda (item)
                 (ebox--size-data-viewport-dependent-p item axis))
               value))))

(defconst ebox--size-dependency-properties
  '(:width :height :min-width :min-height :max-width :max-height
    :padding :padding-top :padding-right :padding-bottom :padding-left
    :margin :margin-top :margin-right :margin-bottom :margin-left
    :padding-left-pixel :padding-right-pixel
    :padding-top-height :padding-bottom-height
    :margin-left-pixel :margin-right-pixel
    :margin-top-height :margin-bottom-height
    :border-left-pixel :border-right-pixel :border-top-pixel :border-bottom-pixel
    :border-top-width :border-right-width :border-bottom-width :border-left-width
    :flex-basis :gap :row-gap :column-gap :item-gap
    :grid-template-columns :grid-template-rows :grid-auto-columns :grid-auto-rows)
  "Own-node size fields inspected for retained viewport dependencies.")

(defun ebox--size-props-viewport-dependent-p (props axis)
  "Return non-nil when size fields in PROPS depend on viewport AXIS."
  (cl-some (lambda (property)
             (ebox--size-data-viewport-dependent-p
              (plist-get props property) axis))
           ebox--size-dependency-properties))

(defun ebox--node-size-viewport-dependent-p (node axis)
  "Inspect NODE's own size declarations and layout config for AXIS."
  (let ((config (plist-get node :ebox-layout-config)))
    (or (ebox--size-props-viewport-dependent-p node axis)
        (ebox--size-props-viewport-dependent-p (plist-get node :props) axis)
        (ebox--size-props-viewport-dependent-p (plist-get node :raw-props) axis)
        (and config
             (ebox--size-props-viewport-dependent-p
              (ebox-layout-config-props config) axis)))))

(defun ebox--viewport-dependent-height-value-p (value)
  "Return non-nil when vertical size VALUE depends on viewport height."
  (or (eq value 'stretch)
      (ebox--size-data-viewport-dependent-p value 'viewport-height)))

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
    (or (ebox--node-size-viewport-dependent-p node 'viewport-height)
        (pcase (plist-get node :ebox-type)
      ('box
       (ebox--viewport-dependent-height-props-p node))
      ('flex
       (or (ebox--viewport-dependent-height-props-p
            (plist-get node :props))
           (ebox--viewport-dependent-height-props-p
            (plist-get node :raw-props))))))))

(defun ebox--flex-participation-viewport-dependent-p (node)
  "Return non-nil when NODE's flex item metadata depends on viewport context."
  (when-let* ((participation (ebox--flex-participation-props node)))
    (ebox--viewport-dependent-size-value-p
     (plist-get participation :flex-basis))))

(defun ebox--node-direct-viewport-width-dependent-p (node)
  "Return non-nil when NODE's own layout depends on viewport width."
  (when (listp node)
    (and (not (eq (plist-get node :ebox-kind) 'text))
         (or (ebox--node-size-viewport-dependent-p node 'viewport-width)
             (ebox--flex-participation-viewport-dependent-p node)
             (cond
              ((eq (plist-get node :ebox-kind) 'box)
               (or (ebox--viewport-dependent-size-value-p
                    (plist-get node :width) t)
                   (ebox--viewport-dependent-size-value-p
                    (plist-get node :min-width))
                   (ebox--viewport-dependent-size-value-p
                    (plist-get node :max-width))))
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
  (when-let* ((axes (ebox--viewport-dependent-node-id-axes node)))
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
  (when-let* ((root (ebox--buffer-root-node buffer)))
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
                     :surface-source-base-index nil
                     :surface-publisher nil)))
    (puthash buffer state ebox-incremental--batch-table)
    state))

(defun ebox-incremental-pending-count (buffer)
  "Return the number of pending explicit batch changes for BUFFER."
  (length (plist-get (ebox-incremental--batch-state buffer) :pending)))

(defun ebox-incremental-surface-batch-root (buffer)
  "Return BUFFER's unpublished surface batch root, or nil."
  (let ((state (ebox-incremental--batch-state buffer)))
    (and (plist-get state :active)
         (plist-get state :surface-candidate-root))))

(defun ebox-incremental-surface-batch-source-index (buffer)
  "Return BUFFER's unpublished batch source index, or nil."
  (let ((state (ebox-incremental--batch-state buffer)))
    (and (plist-get state :active)
         (plist-get state :surface-source-base-index))))

(defun ebox-incremental-record-surface-region-change
    (buffer candidate-root region-id handle dirty-kind changed-keys
            old-style-values publisher)
  "Record one surface-scoped change for BUFFER's explicit batch.
CANDIDATE-ROOT is the accumulated unpublished tree.  REGION-ID and HANDLE
identify the logical target, DIRTY-KIND, CHANGED-KEYS, and OLD-STYLE-VALUES
describe the semantic change, and PUBLISHER commits the complete batch once
during `ebox-incremental-flush'."
  (ebox-incremental-record-surface-region-input-change
   buffer candidate-root nil region-id handle dirty-kind changed-keys
   old-style-values publisher))

(defun ebox-incremental-record-surface-region-input-change
    (buffer candidate-root source-base-index region-id handle dirty-kind
            changed-keys old-style-values publisher)
  "Record one batched region change and its candidate SOURCE-BASE-INDEX."
  (when (ebox-incremental-batching-p buffer)
    (let ((state (ebox-incremental--batch-state buffer)))
      (plist-put state :surface-candidate-root candidate-root)
      (when source-base-index
        (plist-put state :surface-source-base-index source-base-index))
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
  (when-let* ((root (ebox--buffer-root-node buffer)))
    (ebox--constraint-change
     'batch 'batch 'batch
     (ebox--ensure-node-id root)
     (ebox-incremental--batch-dirty-set buffer pending))))

(defun ebox-incremental--flush (buffer)
  "Flush BUFFER's explicit incremental update batch without observing it."
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
            (let ((ebox-incremental--source-base-index
                   (plist-get state :surface-source-base-index)))
              (setq report
                    (funcall
                     surface-publisher buffer
                     (plist-get state :surface-candidate-root) pending)))
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
     :paint-patches nil
     :range-replacements nil
     :range-metrics nil
     :sealed-p nil)))

(defun ebox-incremental-candidate-replace-range-ref
    (candidate ref next-items &optional reuse-map retain-item-identities-p)
  "Record a Range REF replacement using proven slot REUSE-MAP."
  (unless (ebox-candidate-p candidate)
    (error "Ebox Range replacement requires an Ebox candidate"))
  (when (ebox-candidate--sealed-p candidate)
    (error "Ebox candidate is already sealed"))
  (unless (proper-list-p next-items)
    (signal 'wrong-type-argument (list 'proper-list-p next-items)))
  (unless (proper-list-p reuse-map)
    (signal 'wrong-type-argument (list 'proper-list-p reuse-map)))
  (let* ((base-state (ebox-candidate--base-state candidate))
         (record (gethash ref (plist-get base-state :range-ref-table))))
    (unless record
      (error "Ebox candidate Range ref does not exist in its base: %S" ref))
    (let* ((retain-item-identities-p
            (and retain-item-identities-p
                 (ebox-incremental--candidate-range-items-retainable-p
                  candidate next-items ebox-incremental--source-base-index
                  reuse-map)))
           (parent (ebox-runtime-index-get (plist-get record :parent-node-id)
                            (plist-get base-state :node-table)))
           (sequence (and parent (plist-get parent :ebox-child-sequence)))
           (segment (and sequence (ebox-child-range--lookup-ref sequence ref)))
           (old-items (and segment
                           (append (ebox-child-range--segment-payload segment)
                                   nil)))
           (aligned-p (= (length old-items) (length next-items)))
           (reuse-by-new (make-hash-table :test #'eql))
           (seen-old (make-hash-table :test #'eql))
           (missing (make-symbol "ebox-range-reuse-missing"))
           owned)
      (when (and (eq (plist-get parent :ebox-kind) 'box)
                 (not (cl-every
                       (lambda (item)
                         (memq (plist-get item :ebox-kind) '(text box)))
                       next-items)))
        (error "Canonical Ebox Box Range accepts only Text/Box nodes: %S"
               next-items))
      (dolist (entry reuse-map)
        (let ((new-index (car-safe entry))
              (old-index (cdr-safe entry)))
          (unless (and (integerp new-index) (>= new-index 0)
                       (< new-index (length next-items))
                       (integerp old-index) (>= old-index 0)
                       (< old-index (length old-items))
                       (eq (gethash new-index reuse-by-new missing) missing)
                       (not (gethash old-index seen-old)))
            (error "Ebox Range reuse map is invalid: %S" entry))
          (puthash new-index (nth old-index old-items) reuse-by-new)
          (puthash old-index t seen-old)))
      (cl-labels
          ((validate-new
            (item)
            (unless (and (listp item) (not (stringp item)))
              (error "Ebox child Range item must be a declarative node"))
            (cl-labels
                ((reject-range
                  (node)
                  (when (ebox-child-range--descriptor-p node)
                    (error "Range replacement payload cannot introduce a Range"))
                  (when (and (listp node) (not (stringp node)))
                    (dolist (child (ebox-tree--children-raw node))
                      (reject-range child)))))
              (reject-range item))
            (let ((copy
                   (if retain-item-identities-p
                       item
                     (ebox-tree-clear-runtime-identities
                      (ebox-tree-copy-node-structure item)))))
              (unless retain-item-identities-p
                (ebox-tree-source-index
                 copy nil nil ebox-incremental--source-base-index t))
              copy)))
        (cl-loop
         for item in next-items
         for index from 0
         for reused = (gethash index reuse-by-new missing)
         for old = (if (eq reused missing)
                       (and aligned-p (nth index old-items))
                     reused)
         do (push (if (or (not (eq reused missing))
                          (and aligned-p (eq item old)))
                      old
                    (validate-new item))
                  owned)))
      (setq owned (nreverse owned))
      (let ((source-indexes (make-hash-table :test #'eq))
            (base-source-index (plist-get base-state :source-index)))
        (dolist (item owned)
          (let ((handle (ebox-tree-node-source-handle item)))
            (puthash
             handle
             (if (and handle
                      (ebox-source-index-handle-member-p
                       base-source-index handle))
                 base-source-index
               (if (and ebox-incremental--source-base-index
                        (ebox-source-index-handle-member-p
                         ebox-incremental--source-base-index handle))
                   ebox-incremental--source-base-index
                 (ebox-tree-source-index item)))
             source-indexes)))
        (setf (ebox-candidate--range-replacements candidate)
              (append
               (cl-remove
                ref (ebox-candidate--range-replacements candidate)
                :key #'ebox-incremental--candidate-range-replacement-ref
                :test #'equal)
               (list
                (ebox-incremental--make-candidate-range-replacement
                 :ref ref :items owned :reuse-map (copy-tree reuse-map)
                 :source-indexes source-indexes
                 :retain-item-identities-p retain-item-identities-p))))))
    candidate))

(defun ebox-incremental--candidate-ancestor-p
    (candidate ancestor-id descendant-id)
  "Return non-nil when ANCESTOR-ID contains DESCENDANT-ID in CANDIDATE's base."
  (let* ((state (ebox-candidate--base-state candidate))
         (parent-table (plist-get state :parent-table))
         (current (ebox-runtime-index-get descendant-id parent-table))
         found)
    (while (and current (not found))
      (if (equal current ancestor-id)
          (setq found t)
        (setq current (ebox-runtime-index-get current parent-table))))
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
    (unless (ebox-runtime-index-get node-id node-table)
      (error "Ebox candidate anchor does not exist: %S" node-id))
    (unless (and (listp next-subtree) (not (stringp next-subtree)))
      (error "Ebox candidate replacement must be an Ebox node"))
    (let* ((replacement
            (ebox-tree-clear-runtime-identities
             (ebox-tree-copy-node-structure next-subtree)))
           (source-index
            (ebox-tree-source-index
             replacement nil nil ebox-incremental--source-base-index)))
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
      (let* ((root-id (plist-get (ebox-candidate--base-root candidate)
                                 :node-id))
             (root-replaced-p
              (cl-find root-id (ebox-candidate--replacements candidate)
                       :key
                       #'ebox-incremental--candidate-replacement-anchor-id
                       :test #'equal)))
        (unless (and root-replaced-p (not (equal node-id root-id)))
          (setf (ebox-candidate--replacements candidate)
                (append
                 (nreverse retained)
                 (list
                  (ebox-incremental--make-candidate-replacement
                   :anchor-id node-id
                   :subtree replacement
                   :source-index source-index
                   :old-semantic-key old-semantic-key
                   :new-semantic-key new-semantic-key)))))))
    candidate))

(defun ebox-incremental-candidate-replace-root (candidate next-root)
  "Replace CANDIDATE's implicit base root with declarative NEXT-ROOT.
The root address is candidate-local and cannot collide with host references.
Root replacement is last-wins and absorbs every descendant replacement."
  (unless (ebox-candidate-p candidate)
    (error "Ebox root replacement requires an Ebox candidate"))
  (ebox-incremental-candidate-replace
   candidate
   (plist-get (ebox-candidate--base-root candidate) :node-id)
   next-root))

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
                   (ebox-source--index-host-ref-table-view
                    (plist-get (ebox-candidate--base-state candidate)
                               :source-index))
                   missing)))
    (when (eq node-id missing)
      (error "Ebox candidate host ref does not exist: %S" host-ref))
    (ebox-incremental-candidate-replace
     candidate node-id next-subtree
     old-semantic-key new-semantic-key)))

(defun ebox-incremental--find-host-ref-node (node host-ref)
  "Return the node below NODE that owns HOST-REF, or nil."
  (catch 'found
    (cl-labels
        ((visit
          (current)
          (when (and (listp current) (not (stringp current)))
            (when (equal (ebox-tree-node-source-identity current) host-ref)
              (throw 'found current))
            (dolist (child (ebox-tree--children-raw current))
              (visit child)))))
      (visit node))
    nil))

(defun ebox-incremental-candidate-patch-host-paint
    (candidate host-ref previous-subtree next-subtree)
  "Patch HOST-REF paint from declarative OLD/NEW subtrees.

PREVIOUS-SUBTREE and NEXT-SUBTREE may be complete Host outputs; only their
local nodes owning HOST-REF are compared.  Comparing declarative peers avoids
mistaking inherited/cascaded runtime values for explicit deltas.  The update
is accepted only when every changed field is paint-only.  Children and runtime
identities remain owned by the candidate base and are path-copied only along
the patched Host's ancestor chain."
  (unless (ebox-candidate-p candidate)
    (error "Ebox Host paint patch requires an Ebox candidate"))
  (when (ebox-candidate--sealed-p candidate)
    (error "Ebox candidate is already sealed"))
  (let* ((state (ebox-candidate--base-state candidate))
         (missing (make-symbol "ebox-missing-host-ref"))
         (node-id
          (gethash host-ref
                   (ebox-source--index-host-ref-table-view
                    (plist-get state :source-index))
                   missing)))
    (when (eq node-id missing)
      (error "Ebox candidate host ref does not exist: %S" host-ref))
    (catch 'unsupported
      (let* ((base-node (ebox-runtime-index-get node-id (plist-get state :node-table)))
             (previous-node
              (ebox-incremental--find-host-ref-node
               previous-subtree host-ref))
             (next-node
              (ebox-incremental--find-host-ref-node next-subtree host-ref)))
        (when
            (cl-some
             (lambda (replacement)
               (let ((anchor
                      (ebox-incremental--candidate-replacement-anchor-id
                       replacement)))
                 (or (equal anchor node-id)
                     (ebox-incremental--candidate-ancestor-p
                      candidate anchor node-id))))
             (ebox-candidate--replacements candidate))
          (throw 'unsupported nil))
        (unless (and previous-node next-node)
          (error "Ebox paint patch output lacks Host ref: %S" host-ref))
        (unless (and (eq (plist-get base-node :ebox-type)
                         (plist-get previous-node :ebox-type))
                     (eq (plist-get previous-node :ebox-type)
                         (plist-get next-node :ebox-type)))
          (throw 'unsupported nil))
        (let* ((previous-source-index
               (ebox-tree-source-index
                 previous-subtree nil nil
                 ebox-incremental--previous-source-base-index))
               (next-source-index
                (ebox-tree-source-index
                 next-subtree nil nil ebox-incremental--source-base-index))
               (changed-keys
                (ebox-incremental--candidate-local-changed-keys
                 previous-node previous-source-index
                 next-node next-source-index)))
          (unless (cl-every
                   (lambda (key)
                     (memq key ebox--paint-style-signature-keys))
                   changed-keys)
            (throw 'unsupported nil))
          (let ((patch
                 (list :ebox-type (plist-get next-node :ebox-type)
                       :ebox-source-handle
                       (ebox-tree-node-source-handle next-node))))
            (dolist (key changed-keys)
              (setq patch
                    (plist-put patch key
                               (copy-tree (plist-get next-node key)))))
            (dolist (key '(:ebox-style-overrides))
              (when (plist-member next-node key)
                (setq patch
                      (plist-put patch key
                                 (copy-tree (plist-get next-node key))))))
            (setf (ebox-candidate--paint-patches candidate)
                  (append
                   (cl-remove
                    node-id (ebox-candidate--paint-patches candidate)
                    :key
                    #'ebox-incremental--candidate-paint-patch-anchor-id
                    :test #'equal)
                   (list
                    (ebox-incremental--make-candidate-paint-patch
                     :anchor-id node-id :node patch
                     :source-index next-source-index
                     :changed-keys changed-keys))))))
        candidate))))

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
         (old-child (ebox-runtime-index-get node-id node-table))
         (new-child replacement)
         (parent-id (ebox-runtime-index-get node-id parent-table)))
    (unless old-child
      (error "Ebox candidate anchor is absent after an ancestor replacement: %S"
             node-id))
    (ebox-incremental--candidate-record-path-copy
     node-id replacement parent-id t
     (not (equal (plist-get old-child :node-id)
                 (plist-get replacement :node-id))))
    (while parent-id
      (let* ((current-parent-id parent-id)
             (old-parent (ebox-runtime-index-get current-parent-id node-table))
             (new-parent
              (ebox-tree-copy-with-direct-child-replacements
               old-parent (list (cons old-child new-child))))
             (grandparent-id
              (ebox-runtime-index-get current-parent-id parent-table)))
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

(defun ebox-incremental-surface-region-candidate-root
    (buffer region-id &optional isolate-owner-subtree-p)
  "Return a copy-on-write candidate root for REGION-ID in BUFFER.
Only the region owner and its ancestor path are copied; untouched runtime
subtrees remain shared with the published root.  Return nil when the retained
index cannot identify a directly replaceable region owner, leaving callers to
use their ordinary isolated-copy path.  ISOLATE-OWNER-SUBTREE-P additionally
copies the owner's descendants before mutation while retaining their ids.
Text regions use the same path-copy contract as Box regions."
  (let* ((state (ebox--buffer-render-state buffer))
         (root (plist-get state :root-node))
         (node-table (plist-get state :node-table))
         (parent-table (plist-get state :parent-table))
         (region-node-table (plist-get state :region-node-table))
         (owner-id (and (ebox-runtime-index-like-p region-node-table)
                        (ebox-runtime-index-get region-id region-node-table)))
         (owner (and (ebox-runtime-index-like-p node-table)
                     (ebox-runtime-index-get owner-id node-table)))
         (box
          (pcase (and owner (plist-get owner :ebox-type))
            ('box owner)
            ('flex (plist-get owner :box)))))
    (when (and root owner box
               (ebox-runtime-index-like-p parent-table)
               (equal (plist-get box :region-id) region-id))
      (let* ((candidate-box
              (if isolate-owner-subtree-p
                  (ebox-tree-copy-node-structure box)
                (copy-sequence box)))
             (replacement
              (if (eq owner box)
                  candidate-box
                (ebox-tree-copy-with-direct-child-replacements
                 owner (list (cons box candidate-box))))))
        (ebox-incremental--candidate-path-copy-one
         root owner-id replacement
         (list :node-table node-table :parent-table parent-table))))))

(defun ebox-incremental--candidate-path-copy-overlap-many
    (root index replacements)
  "Return ROOT with possibly nested node-id REPLACEMENTS merged bottom-up.
Unlike `ebox-incremental--candidate-path-copy-many', this helper accepts an
ancestor and its descendant in the same replacement set.  A node-local
replacement is applied first, then candidate-owned child paths are installed
into that local copy.  Consequently one copied ancestor contains both its own
mutation and every nested mutation, while untouched sibling subtrees remain
shared with the published generation."
  (let* ((node-table (plist-get index :node-table))
         (parent-table (plist-get index :parent-table))
         (affected (make-hash-table :test 'equal))
         (children (make-hash-table :test 'equal))
         affected-ids)
    (maphash
     (lambda (node-id _replacement)
       (unless (ebox-runtime-index-get node-id node-table)
         (error "Ebox candidate path-copy node is absent: %S" node-id))
       (let ((current node-id))
         (while current
           (unless (gethash current affected)
             (puthash current t affected)
             (push current affected-ids))
           (setq current (ebox-runtime-index-get current parent-table)))))
     replacements)
    (let ((depths (make-hash-table :test 'equal)))
      (cl-labels
          ((depth
            (node-id)
            (or (gethash node-id depths)
                (let ((current node-id) path (result -1))
                  (while (and current (not (gethash current depths)))
                    (push current path)
                    (setq current (ebox-runtime-index-get current parent-table)))
                  (when current
                    (setq result (gethash current depths)))
                  (dolist (path-id path)
                    (puthash path-id (cl-incf result) depths))
                  (gethash node-id depths)))))
        (setq affected-ids
              (sort affected-ids
                    (lambda (left right)
                      (> (depth left) (depth right)))))))
    (let (result)
      (dolist (node-id affected-ids)
        (let* ((old-node (ebox-runtime-index-get node-id node-table))
               (local (or (gethash node-id replacements) old-node))
               (child-replacements (gethash node-id children))
               (effective-child-replacements
                (if (or (null child-replacements) (eq local old-node))
                    child-replacements
                  (let ((local-children (make-hash-table :test 'equal)))
                    (ebox-tree-for-each-direct-child
                     local
                     (lambda (child)
                       (puthash (plist-get child :node-id) child
                                local-children)))
                    (mapcar
                     (lambda (replacement)
                       (let* ((old-child (car replacement))
                              (child-id (plist-get old-child :node-id))
                              (local-child (gethash child-id local-children)))
                         (unless local-child
                           (error
                            "Ebox candidate ancestor dropped nested anchor %S"
                            child-id))
                         (cons local-child (cdr replacement))))
                     child-replacements))))
               (candidate
                (if effective-child-replacements
                    (ebox-tree-copy-with-direct-child-replacements
                     local effective-child-replacements)
                  local))
               (parent-id (ebox-runtime-index-get node-id parent-table)))
          (ebox-incremental--candidate-record-path-copy
           node-id candidate parent-id (gethash node-id replacements) nil)
          (if parent-id
              (puthash parent-id
                       (cons (cons old-node candidate)
                             (gethash parent-id children))
                       children)
            (setq result candidate))))
      (or result root))))

(defun ebox-incremental-surface-scroll-offsets-candidate-root
    (buffer region-offsets)
  "Return one path-copied BUFFER root carrying REGION-OFFSETS.
REGION-OFFSETS is an alist of region ids and canonical numeric offsets.  The
regions may be nested; their owner paths are merged into one candidate root
without mutating the published generation.  Return nil when any region cannot
be resolved through the retained runtime indexes."
  (let* ((state (ebox--buffer-render-state buffer))
         (root (plist-get state :root-node))
         (node-table (plist-get state :node-table))
         (parent-table (plist-get state :parent-table))
         (region-node-table (plist-get state :region-node-table))
         (replacements (make-hash-table :test 'equal))
         valid)
    (setq valid (and root (ebox-runtime-index-like-p node-table)
                     (ebox-runtime-index-like-p parent-table)
                     (ebox-runtime-index-like-p region-node-table)))
    (dolist (entry region-offsets)
      (when valid
        (let* ((region-id (car entry))
               (offset (cdr entry))
               (owner-id (ebox-runtime-index-get region-id region-node-table))
               (owner (and owner-id (ebox-runtime-index-get owner-id node-table)))
               (box
                (pcase (and owner (plist-get owner :ebox-type))
                  ('box owner)
                  ((or 'flex 'grid) (plist-get owner :box)))))
          (if (and owner-id owner box
                   (numberp offset)
                   (equal (plist-get box :region-id) region-id)
                   (not (gethash owner-id replacements)))
              (let* ((candidate-box (copy-sequence box))
                     (_ (ebox-put candidate-box :scroll-offset offset))
                     (_ (plist-put candidate-box
                                   :ebox-scroll-offset-controlled-p t))
                     (replacement
                      (if (eq owner box)
                          candidate-box
                        (ebox-tree-copy-with-direct-child-replacements
                         owner (list (cons box candidate-box))))))
                (puthash owner-id replacement replacements))
            (setq valid nil)))))
    (when (and valid (> (hash-table-count replacements) 0))
      (ebox-incremental--candidate-path-copy-overlap-many
       root (list :node-table node-table :parent-table parent-table)
       replacements))))

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
       (let ((old-node (ebox-runtime-index-get node-id node-table))
             (parent-id (ebox-runtime-index-get node-id parent-table)))
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
           (setq parent-id (ebox-runtime-index-get parent-id parent-table)))))
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
                    (setq current (ebox-runtime-index-get current parent-table)))
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
               (old-parent (ebox-runtime-index-get parent-id node-table))
               (copy
                (ebox-tree-copy-with-direct-child-replacements
                 old-parent child-replacements))
               (grandparent-id (ebox-runtime-index-get parent-id parent-table)))
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
        (let ((current (ebox-runtime-index-get descendant-id parent-table))
              found)
          (while (and current (not found))
            (if (equal current ancestor-id)
                (setq found t)
              (setq current (ebox-runtime-index-get current parent-table))))
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
         (base-source-index (plist-get base-index :source-index))
         (host-ref-table
          (ebox-source--index-host-ref-table-view base-source-index))
         (replacement-host-refs (make-hash-table :test 'equal))
         (replacement-source-indexes (make-hash-table :test #'eq))
         (anchor-ids
          (mapcar
           #'ebox-incremental--candidate-replacement-anchor-id
           entries)))
    (cl-labels
        ((ancestor-p (ancestor descendant)
           (let ((walk descendant) found)
             (while (and walk (not found))
               (setq found (equal walk ancestor)
                     walk (and (not found) (ebox-runtime-index-get walk parent-table))))
             found))
         (inside-replaced-anchor-p (node-id)
           (let ((walk node-id))
             (while (and walk (not (member walk anchor-ids)))
               (setq walk (ebox-runtime-index-get walk parent-table)))
             walk))
         (collect-host-refs (node acc)
           (if (or (not (listp node)) (stringp node))
               acc
             (let ((ref (ebox-tree-node-source-identity node)))
               (when ref (push ref acc)))
             (dolist (child (ebox-tree--children-raw node) acc)
               (setq acc (collect-host-refs child acc))))))
      (dolist (entry entries)
        (let* ((node-id
                (ebox-incremental--candidate-replacement-anchor-id entry))
               (replacement
                (ebox-incremental--candidate-replacement-subtree entry))
               (replacement-source-index
                (or
                    (ebox-incremental--candidate-replacement-source-index entry)
                    (gethash replacement replacement-source-indexes)
                    (puthash replacement
                             (ebox-tree-source-index replacement)
                             replacement-source-indexes)))
               (replacement-key
                (ebox-tree-node-author-key
                 replacement-source-index replacement))
               (parent-id (ebox-runtime-index-get node-id parent-table))
               (parent (and parent-id (ebox-runtime-index-get parent-id node-table))))
          ;; Sibling keys stay unique under the anchor's parent.
          (when (and replacement-key parent)
            (dolist (sibling (ebox-tree--children-raw parent))
              (let ((sibling-id (plist-get sibling :node-id)))
                (when (and sibling-id
                           (not (equal sibling-id node-id))
                           (equal
                            (if-let*
                                ((sibling-replacement
                                  (ebox-incremental--candidate-replacement-for-anchor
                                   entries sibling-id)))
                                (let* ((subtree
                                        (ebox-incremental--candidate-replacement-subtree
                                         sibling-replacement))
                                       (index
                                        (or
                                         (ebox-incremental--candidate-replacement-source-index
                                          sibling-replacement)
                                         (gethash subtree
                                                  replacement-source-indexes)
                                         (puthash
                                          subtree
                                          (ebox-tree-source-index subtree)
                                          replacement-source-indexes))))
                                  (ebox-tree-node-author-key index subtree))
                              (ebox-tree-node-author-key
                               base-source-index sibling))
                                  replacement-key))
                  (error
                   "Ebox declarative sibling key %S is not unique"
                   replacement-key)))))
          ;; Host refs must be fresh or freed by this same commit.
          (when host-ref-table
            (dolist (ref (collect-host-refs replacement nil))
              (when-let* ((existing-anchor
                          (gethash ref replacement-host-refs)))
                (unless (or (ancestor-p existing-anchor node-id)
                            (ancestor-p node-id existing-anchor))
                  (error "Ebox declarative host reference %S is not unique"
                         ref)))
              (puthash ref node-id replacement-host-refs)
              (when-let* ((owner-id (gethash ref host-ref-table)))
                (unless (inside-replaced-anchor-p owner-id)
                  (error
                   "Ebox declarative host reference %S is not unique"
                   ref))))))))))

(defun ebox-incremental--copy-detached-history (state)
  "Return an unpublished detached identity history copied from STATE."
  (if-let* ((history (plist-get state :detached-identity-history)))
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
       (when (and (ebox-runtime-index-get node-id node-table)
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
         (old-source-index (plist-get state :source-index))
         (replacement-source-index
          (or (ebox-incremental--candidate-replacement-source-index entry)
              (ebox-tree-source-index replacement)))
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
        (ebox-tree-reconcile-runtime
         old-anchor old-source-index replacement replacement-source-index)
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
                 (plist-get historical :root)
                 (ebox-tree-source-index (plist-get historical :root))
                 replacement replacement-source-index)
                (ebox-tree-transfer-runtime-identity
                 old-anchor replacement))
            (ebox-tree-reconcile-runtime
             old-anchor old-source-index
             replacement replacement-source-index))))))
  (ebox-incremental--candidate-replacement-subtree entry))

(defun ebox-incremental--candidate-node-logical-root
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
                  :source-index (plist-get state :source-index)))
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
                      (ebox-runtime-index-get node-id (plist-get base-index :node-table))))
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
        ;; A descendant refines the candidate-owned ancestor in the same
        ;; bottom-up path copy.  Re-indexing the complete candidate after each
        ;; replacement repeats work and discards the overlap information that
        ;; the retained parent table already provides.
        (when (cl-some
               (lambda (entry)
                 (ebox-incremental--candidate-replacement-old-semantic-key
                  entry))
               entries)
          (error "Ebox semantic candidate replacements must be disjoint"))
        (let ((replacements (make-hash-table :test 'equal)))
          (ebox-incremental--validate-candidate-replacements
           base-index entries)
          (dolist (entry entries)
            (let* ((node-id
                    (ebox-incremental--candidate-replacement-anchor-id entry))
                   (old-anchor
                    (ebox-runtime-index-get node-id (plist-get base-index :node-table))))
              (unless old-anchor
                (error
                 "Ebox candidate anchor is absent: %S"
                 node-id))
              (puthash
               node-id
               (ebox-incremental--reconcile-detached-replacement
                candidate state entry old-anchor detached-history)
               replacements)))
          (ebox-incremental--candidate-path-copy-overlap-many
           root base-index replacements))))))

(defun ebox-incremental--candidate-reconcile-range-items
    (sequence ref items old-source-index item-source-indexes)
  "Reconcile ITEMS against REF using explicit generation source indexes."
  (let* ((segment (ebox-child-range--lookup-ref sequence ref))
         (old-payload (and segment (ebox-child-range--segment-payload segment)))
         (key-root (ebox-child-range--sequence-key-root sequence))
         (hash-function (ebox-child-range--sequence-hash-function sequence)))
    (cl-labels
        ((item-key
          (item)
          (let ((index
                 (gethash (ebox-tree-node-source-handle item)
                          item-source-indexes)))
            (unless index
              (error "Ebox Range item has no candidate source index"))
            (ebox-tree-node-author-key index item))))
      (cl-loop for item in items for offset from 0 do
             (let* ((key (item-key item))
                    (location
                     (and key
                          (ebox-child-range--hash-lookup
                           key-root key (funcall hash-function key))))
                    (old
                     (if location
                         (let ((peer (ebox-child-range--segment-at
                                      sequence (car location))))
                           (aref (ebox-child-range--segment-payload peer)
                                 (cdr location)))
                       (and old-payload (< offset (length old-payload))
                            (aref old-payload offset)))))
               (let ((old-key
                      (and old
                           (ebox-tree-node-author-key
                            old-source-index old))))
                 (when (and old key (null old-key)) (setq old nil))
                 (when (and old (null key) old-key) (setq old nil))
               ;; Positional fallback is valid only for unkeyed peers.  A
               ;; disappeared keyed item must never donate its runtime
               ;; identity to a newly introduced key at the same offset;
               ;; doing so leaves its old region properties in the candidate
               ;; output while the new region index has already retired them.
                 (when (and old key old-key (not (equal old-key key)))
                   (setq old nil)))
               (ebox-tree-reconcile-runtime
                old old-source-index item
                (gethash (ebox-tree-node-source-handle item)
                         item-source-indexes)))))
    items))

(defun ebox-incremental--candidate-canonical-range-reuse
    (sequence ref items reuse-map parent-id segment-index)
  "Return canonical ITEMS and effective REUSE-MAP for published SEQUENCE.
Only an item that keeps its exact sequence location may reuse the published
object.  A moved item retains semantic identity through ordinary reconcile,
but must re-enter the candidate indexes as a new object."
  (let* ((segment (ebox-child-range--lookup-ref sequence ref))
         (old-payload
          (and segment (ebox-child-range--segment-payload segment)))
         (result (vconcat items))
         effective)
    (dolist (pair reuse-map)
      (let ((new-index (car-safe pair))
            (old-index (cdr-safe pair)))
        (unless (and (integerp new-index) (>= new-index 0)
                     (< new-index (length result))
                     (integerp old-index) (>= old-index 0)
                     old-payload (< old-index (length old-payload)))
          (error "Ebox Range reuse map is out of bounds: %S" pair))
        (let* ((published (aref old-payload old-index))
               (target-location
                (list :parent-node-id parent-id
                      :segment-index segment-index :offset new-index)))
          (if (equal (plist-get published :ebox-sequence-location)
                     target-location)
              (progn
                (aset result new-index published)
                (push pair effective))
            ;; The producer may use the published object itself to describe
            ;; an unchanged keyed item.  Once that item moves, exact-slot
            ;; reuse is no longer authorized: leave a detached candidate for
            ;; ordinary runtime reconciliation, never the published object.
            (when (eq (aref result new-index) published)
              (aset result new-index
                    (ebox-tree-clear-runtime-identities
                     (ebox-tree-copy-node-structure published))))))))
    (list (append result nil) (nreverse effective))))

(defun ebox-incremental--candidate-current-node (state node-id)
  "Return current candidate NODE-ID from path trace or base STATE."
  (or (plist-get (gethash node-id ebox-incremental--candidate-path-copy-trace)
                 :node)
      (ebox-runtime-index-get node-id (plist-get state :node-table))))

(defun ebox-incremental--candidate-range-ref-overlay (old-state path-trace)
  "Return Range ref table updated only for node anchors in PATH-TRACE."
  (if (not (hash-table-p path-trace))
      (plist-get old-state :range-ref-table)
    (let ((parent-table (plist-get old-state :parent-table)) anchors)
      (maphash
       (lambda (base-id trace)
         (when (plist-get trace :anchor-p)
           (push (cons base-id (plist-get trace :node)) anchors)))
       path-trace)
      (let ((anchor-set (make-hash-table :test #'equal)))
        (dolist (anchor anchors) (puthash (car anchor) t anchor-set))
        (setq anchors
              (cl-delete-if
               (lambda (anchor)
                 (let ((walk (ebox-runtime-index-get (car anchor) parent-table)) found)
                   (while (and walk (not found))
                     (setq found (gethash walk anchor-set)
                           walk (and (not found) (ebox-runtime-index-get walk parent-table))))
                   found))
               anchors)))
      (if (null anchors)
          (plist-get old-state :range-ref-table)
        (let ((table (copy-hash-table (plist-get old-state :range-ref-table))))
          (cl-labels
              ((walk (node function)
                 (when-let* ((sequence (plist-get node :ebox-child-sequence)))
                   (dolist (record (ebox-child-range--range-records sequence))
                     (funcall function node record)))
                 (dolist (child (ebox-tree--children-raw node))
                   (walk child function))))
            (dolist (anchor anchors)
              (when-let* ((old (ebox-runtime-index-get (car anchor)
                                       (plist-get old-state :node-table))))
                (walk old
                      (lambda (_parent record)
                        (remhash (car record) table)))))
            (dolist (anchor anchors)
              (walk
               (cdr anchor)
               (lambda (parent record)
                 (let ((ref (car record)))
                   (when (gethash ref table)
                     (error "Ebox child Range ref is not unique: %S" ref))
                   (puthash ref
                            (list :parent-node-id (plist-get parent :node-id)
                                  :segment-index (nth 1 record))
                            table))))))
          table)))))

(defun ebox-incremental--candidate-path-copy-overlay
    (root node-id replacement state structure-p)
  "Path-copy NODE-ID in ROOT using STATE tables plus the candidate trace."
  (let* ((parent-table (plist-get state :parent-table))
         (old-child (ebox-incremental--candidate-current-node state node-id))
         (new-child replacement)
         (parent-id (ebox-runtime-index-get node-id parent-table)))
    (ebox-incremental--candidate-record-path-copy
     node-id replacement parent-id t structure-p)
    (while parent-id
      (let* ((current-parent-id parent-id)
             (old-parent
              (ebox-incremental--candidate-current-node state current-parent-id))
             (sequence (plist-get old-parent :ebox-child-sequence))
             (location (and sequence
                            (plist-get old-child :ebox-sequence-location)))
             (new-parent
              (if location
                  (let ((copy (copy-sequence old-parent)))
                    (ebox-tree--put-child-sequence
                     copy
                     (ebox-child-range--replace-item-at
                      sequence (plist-get location :segment-index)
                      (plist-get location :offset) old-child new-child
                      (let* ((handle
                              (ebox-tree-node-source-handle new-child))
                             (incoming
                              (and handle
                                   (hash-table-p
                                    ebox-incremental--candidate-incoming-source-indexes)
                                   (gethash
                                    handle
                                    ebox-incremental--candidate-incoming-source-indexes)))
                             (index
                              (or incoming (plist-get state :source-index))))
                        (ebox-tree-node-author-key index new-child))))
                    (when (eq (plist-get old-parent :ebox-kind) 'box)
                      (ebox-tree--set-author-style-count
                       copy
                       (+ (ebox-tree-author-style-count old-parent)
                          (- (ebox-tree-author-style-count new-child)
                             (ebox-tree-author-style-count old-child)))))
                    copy)
                (ebox-tree-copy-with-direct-child-replacements
                 old-parent (list (cons old-child new-child)))))
             (grandparent-id (ebox-runtime-index-get current-parent-id parent-table)))
        (ebox-incremental--candidate-record-path-copy
         current-parent-id new-parent grandparent-id nil
         (not (equal (plist-get old-child :node-id)
                     (plist-get new-child :node-id))))
        (setq old-child old-parent new-child new-parent
              parent-id grandparent-id)))
    (if (equal node-id (plist-get root :node-id)) replacement new-child)))

(defun ebox-incremental--candidate-apply-range-replacements (candidate root)
  "Apply CANDIDATE Range replacements to ROOT without flattening a parent."
  (let* ((entries (ebox-candidate--range-replacements candidate))
         (state (ebox-candidate--base-state candidate))
         (base-ranges (plist-get state :range-ref-table))
         (root-id (plist-get (ebox-candidate--base-root candidate) :node-id))
         (root-replaced
          (cl-find root-id (ebox-candidate--replacements candidate)
                   :key #'ebox-incremental--candidate-replacement-anchor-id
                   :test #'equal))
         metrics)
    (unless root-replaced
      (let ((groups (make-hash-table :test #'equal)) order)
        (dolist (entry entries)
          (let* ((record (gethash
                          (ebox-incremental--candidate-range-replacement-ref entry)
                          base-ranges))
                 (parent-id (plist-get record :parent-node-id))
                 (absorbed
                  (cl-some
                   (lambda (node-entry)
                     (let ((anchor
                            (ebox-incremental--candidate-replacement-anchor-id
                             node-entry)))
                       (or (equal anchor parent-id)
                           (ebox-incremental--candidate-ancestor-p
                            candidate anchor parent-id))))
                   (ebox-candidate--replacements candidate))))
            (unless absorbed
              (unless (gethash parent-id groups) (push parent-id order))
              (push entry (gethash parent-id groups)))))
        (dolist (parent-id (nreverse order))
          (let* ((parent (ebox-incremental--candidate-current-node
                          state parent-id))
                 (base-parent (ebox-runtime-index-get parent-id (plist-get state :node-table)))
                 (base-sequence
                  (and base-parent
                       (plist-get base-parent :ebox-child-sequence)))
                 (sequence (and parent (plist-get parent :ebox-child-sequence)))
                 replacements)
            ;; A node/Host ancestor replacement removes or supersedes the base
            ;; Range address and therefore wins coalescing.
            (when sequence
              (dolist (entry (nreverse (gethash parent-id groups)))
                (let ((ref
                       (ebox-incremental--candidate-range-replacement-ref entry)))
                  (when (ebox-child-range--lookup-ref sequence ref)
                    (let ((items
                           (ebox-incremental--candidate-range-replacement-items
                            entry))
                          (source-indexes
                           (ebox-incremental--candidate-range-replacement-source-indexes
                            entry))
                          (reuse-map
                           (ebox-incremental--candidate-range-replacement-reuse-map
                            entry))
                          (retain-item-identities-p
                           (ebox-incremental--candidate-range-replacement-retain-item-identities-p
                            entry)))
                      (let ((segment-index
                             (plist-get (gethash ref base-ranges)
                                        :segment-index)))
                        (pcase-let
                            ((`(,canonical-items ,effective-reuse-map)
                              (ebox-incremental--candidate-canonical-range-reuse
                               sequence ref items reuse-map parent-id
                               segment-index)))
                          (setq items canonical-items
                                reuse-map effective-reuse-map)))
                      (ebox-incremental--candidate-reconcile-range-items
                       sequence ref items
                       (plist-get state :source-index) source-indexes)
                      (cl-loop for item in items for offset from 0
                               for location =
                               (list :parent-node-id parent-id
                                     :segment-index
                                     (plist-get (gethash ref base-ranges)
                                                :segment-index)
                                     :offset offset)
                               unless (equal
                                       (plist-get item
                                                  :ebox-sequence-location)
                                       location)
                               do (plist-put item :ebox-sequence-location
                                             location))
                      (push (list ref items reuse-map source-indexes
                                  retain-item-identities-p)
                            replacements)))))
              (when replacements
                (let* ((ordered-replacements (nreverse replacements))
                       (range-pairs
                        (mapcar (lambda (replacement)
                                  (cons (nth 0 replacement)
                                        (nth 1 replacement)))
                                ordered-replacements))
                       (item-source-indexes
                        (make-hash-table :test #'eq))
                       (_item-source-indexes
                        (dolist (replacement ordered-replacements)
                          (maphash
                           (lambda (handle index)
                             (puthash handle index item-source-indexes))
                           (nth 3 replacement))))
                       (old-payloads
                        (mapcar
                         (lambda (replacement)
                           (append
                            (ebox-child-range--segment-payload
                             (ebox-child-range--lookup-ref
                              base-sequence (nth 0 replacement))) nil))
                         ordered-replacements))
                       (result (ebox-child-range--replace-many
                                sequence range-pairs
                                (lambda (item)
                                  (let ((index
                                         (gethash
                                          (ebox-tree-node-source-handle item)
                                          item-source-indexes)))
                                    (unless index
                                      (error
                                       "Ebox Range item has no source index"))
                                    (ebox-tree-node-author-key index item)))
                                (mapcar
                                 (lambda (replacement)
                                   (cons (nth 0 replacement)
                                         (nth 2 replacement)))
                                 ordered-replacements)
                                (cl-every
                                 (lambda (replacement)
                                   (nth 4 replacement))
                                 ordered-replacements)))
                       (new-payloads
                        (mapcar
                         (lambda (replacement)
                           (append
                            (ebox-child-range--segment-payload
                             (ebox-child-range--lookup-ref
                              (car result) (nth 0 replacement))) nil))
                         ordered-replacements))
                       (old-affected-payloads
                        (cl-mapcar
                         (lambda (replacement payload)
                           (let ((reused (mapcar #'cdr
                                                 (nth 2 replacement))))
                             (cl-loop for item in payload for index from 0
                                      unless (memq index reused)
                                      collect item)))
                         ordered-replacements old-payloads))
                       (new-affected-payloads
                        (cl-mapcar
                         (lambda (replacement payload)
                           (let ((reused (mapcar #'car
                                                 (nth 2 replacement))))
                             (cl-loop for item in payload for index from 0
                                      unless (memq index reused)
                                      collect item)))
                         ordered-replacements new-payloads))
                       (children-changed
                        (not
                         (cl-every
                          (lambda (pair)
                            (equal
                             (mapcar (lambda (node)
                                       (plist-get node :node-id))
                                     (car pair))
                             (mapcar (lambda (node)
                                       (plist-get node :node-id))
                                     (cdr pair))))
                          (cl-mapcar #'cons old-payloads new-payloads))))
                       (new-parent (copy-sequence parent)))
                  (ebox-tree--put-child-sequence new-parent (car result))
                  (when (eq (plist-get parent :ebox-kind) 'box)
                    (ebox-tree--set-author-style-count
                     new-parent
                     (+ (ebox-tree-author-style-count parent)
                        (- (cl-loop for payload in new-payloads
                                   sum (cl-loop for child in payload
                                                sum (ebox-tree-author-style-count
                                                     child)))
                           (cl-loop for payload in old-payloads
                                    sum (cl-loop for child in payload
                                                 sum (ebox-tree-author-style-count
                                                      child)))))))
                  (push (ebox-child-range--metrics-plist (cdr result)) metrics)
                  (setq root
                        (ebox-incremental--candidate-path-copy-overlay
                         root parent-id new-parent state children-changed))
                  (let ((trace (gethash parent-id
                                        ebox-incremental--candidate-path-copy-trace)))
                    (plist-put trace :anchor-p nil))
                  (push (list :old-parent base-parent :new-parent new-parent
                              :parent-id parent-id
                              :children-changed children-changed
                              :old-payloads old-affected-payloads
                              :new-payloads new-affected-payloads)
                        ebox-incremental--candidate-range-index-deltas))))))))
    (setf (ebox-candidate--range-metrics candidate) (nreverse metrics))
    root))

(defun ebox-incremental--candidate-paint-top-anchors
    (state patch-table patch-ids)
  "Return PATCH-IDS without a patched ancestor in STATE."
  (let ((parents (plist-get state :parent-table)) result)
    (dolist (node-id patch-ids (nreverse result))
      (let ((parent-id (ebox-runtime-index-get node-id parents)) found)
        (while (and parent-id (not found))
          (setq found (gethash parent-id patch-table)
                parent-id (and (not found) (ebox-runtime-index-get parent-id parents))))
        (unless found (push node-id result))))))

(defun ebox-incremental--candidate-apply-paint-patches (candidate root)
  "Apply CANDIDATE paint declarations and copy their dependency closure.
The candidate owns source declarations only.  When a patch changes any
schema-inherited or custom property, descendants are path-copied as pending
style consumers; the Style Adapter computes their values exactly once later."
  (let* ((state (ebox-candidate--base-state candidate))
         (parents (plist-get state :parent-table))
         (source-index (plist-get state :source-index))
         (patch-table (make-hash-table :test #'equal))
         (patch-paths (make-hash-table :test #'equal))
         patch-ids)
    (dolist (entry (ebox-candidate--paint-patches candidate))
      (let ((node-id
             (ebox-incremental--candidate-paint-patch-anchor-id entry)))
        (puthash node-id entry patch-table)
        (push node-id patch-ids)))
    (dolist (node-id patch-ids)
      (let ((current node-id))
        (while current
          (puthash current t patch-paths)
          (setq current (ebox-runtime-index-get current parents)))))
    (cl-labels
        ((rewrite
          (node inherited-input-changed-p)
          (if (or (not (listp node)) (stringp node))
              node
            (let* ((node-id (plist-get node :node-id))
                   (entry (and node-id (gethash node-id patch-table)))
                   (patch (and entry
                               (ebox-incremental--candidate-paint-patch-node
                                entry)))
                   (changed-keys
                    (and entry
                         (ebox-incremental--candidate-paint-patch-changed-keys
                          entry)))
                   (old-declarations
                    (ebox-style-node-declarations source-index node))
                   (next (if (or entry inherited-input-changed-p)
                             (copy-sequence node)
                           node)))
              (when entry
                (plist-put next :ebox-source-handle
                           (plist-get patch :ebox-source-handle))
                (dolist (key changed-keys)
                  (plist-put next key
                             (if (eq key :surface-properties)
                                 (tp-property-value-copy (plist-get patch key))
                               (copy-tree (plist-get patch key)))))
                (dolist (key '(:ebox-style-overrides))
                  (when (plist-member patch key)
                    (plist-put
                     next key
                     (ebox-style-merge-declarations
                      (copy-tree (plist-get node key))
                      (copy-tree (plist-get patch key)))))))
              (let* ((new-declarations
                      (ebox-style-node-declarations
                       (if entry
                           (ebox-incremental--candidate-paint-patch-source-index
                            entry)
                         source-index)
                       next))
                     (descendant-input-changed-p
                      (or inherited-input-changed-p
                          (and entry
                               (ebox-style--inherited-declarations-changed-p
                                old-declarations new-declarations)))))
                (when (or entry inherited-input-changed-p)
                  (ebox-tree--set-author-style-count next 1))
                (let (child-replacements)
                  (dolist (child (ebox-tree--children-raw next))
                    (when (or descendant-input-changed-p
                              (gethash (plist-get child :node-id) patch-paths))
                      (let ((replacement
                             (rewrite child descendant-input-changed-p)))
                        (unless (eq replacement child)
                          (push (cons child replacement)
                                child-replacements)))))
                  (when child-replacements
                    (setq next
                          (ebox-tree-copy-with-direct-child-replacements
                           next (nreverse child-replacements)))))
                next)))))
      (dolist
          (node-id
           (ebox-incremental--candidate-paint-top-anchors
            state patch-table patch-ids)
           root)
        (let ((current
               (ebox-incremental--candidate-current-node state node-id)))
          (unless current
            (error "Ebox paint patch anchor is absent: %S" node-id))
          (setq root
                (ebox-incremental--candidate-path-copy-overlay
                 root node-id
                 (rewrite current nil)
                 state nil)))))))

(defun ebox-incremental--candidate-logical-root
    (candidate &optional detached-history)
  "Return CANDIDATE root after node/Host and child Range coalescing."
  (let* ((original-nodes (ebox-candidate--replacements candidate))
         (original-ranges (ebox-candidate--range-replacements candidate))
         surviving-ranges absorbed)
    (dolist (range original-ranges)
      (let* ((record
              (gethash (ebox-incremental--candidate-range-replacement-ref range)
                       (plist-get (ebox-candidate--base-state candidate)
                                  :range-ref-table)))
             (parent-id (plist-get record :parent-node-id))
             (host-wins
              (cl-some
               (lambda (node-entry)
                 (let ((anchor
                        (ebox-incremental--candidate-replacement-anchor-id
                         node-entry)))
                   (or (equal anchor parent-id)
                       (ebox-incremental--candidate-ancestor-p
                        candidate anchor parent-id))))
               original-nodes)))
        (unless host-wins (push range surviving-ranges))))
    (setq surviving-ranges (nreverse surviving-ranges))
    (dolist (range surviving-ranges)
      (let* ((record
              (gethash (ebox-incremental--candidate-range-replacement-ref range)
                       (plist-get (ebox-candidate--base-state candidate)
                                  :range-ref-table)))
             (parent (ebox-runtime-index-get (plist-get record :parent-node-id)
                              (plist-get (ebox-candidate--base-state candidate)
                                         :node-table)))
             (segment (and parent
                           (ebox-child-range--segment-at
                            (plist-get parent :ebox-child-sequence)
                            (plist-get record :segment-index)))))
        (dolist (item (and segment
                           (append (ebox-child-range--segment-payload segment)
                                   nil)))
          (cl-labels ((collect (node)
                        (push (plist-get node :node-id) absorbed)
                        (dolist (child (ebox-tree--children-raw node))
                          (collect child))))
            (collect item)))))
    (setf (ebox-candidate--replacements candidate)
          (cl-remove-if
           (lambda (entry)
             (member (ebox-incremental--candidate-replacement-anchor-id entry)
                     absorbed))
           original-nodes)
          (ebox-candidate--range-replacements candidate) surviving-ranges)
    (unwind-protect
        (ebox-incremental--candidate-apply-paint-patches
         candidate
         (ebox-incremental--candidate-apply-range-replacements
          candidate
          (ebox-incremental--candidate-node-logical-root
           candidate detached-history)))
      (setf (ebox-candidate--replacements candidate) original-nodes
            (ebox-candidate--range-replacements candidate) original-ranges))))

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
  "Return the keys currently present in supported TABLE."
  (let (keys)
    (when (ebox-runtime-index-like-p table)
      (ebox-runtime-index-map
       (lambda (key _value) (push key keys)) table))
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
      (ebox-runtime-index-map
       (lambda (node-id _node)
         (when-let* ((snapshot (gethash node-id old-snapshots)))
           (puthash node-id (copy-sequence snapshot) snapshots)))
       candidate-node-table)
      ;; A root type replacement receives a fresh runtime id, but its patch
      ;; owner still covers the currently published complete-buffer geometry.
      (unless (equal old-root-id candidate-root-id)
        (when-let* ((snapshot (gethash old-root-id old-snapshots)))
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
  (when-let* ((owner (ebox--buffer-runtime-node buffer owner-id)))
    (pcase-let* ((old-ids (plist-get dirty :old-child-ids))
                 (new-ids (plist-get dirty :new-child-ids))
                 (`(,_old-middle ,new-middle)
                  (ebox-incremental--child-list-middle old-ids new-ids)))
      (and (eq (plist-get owner :ebox-type) 'stack)
           (eq (ebox-tree-display-inner owner) 'column)
           (when-let* ((snapshot
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
   ;; A local ECSS sheet can change paint, typography, geometry, or a
   ;; descendant selector match.  Treat its source mutation conservatively as
   ;; geometry so the normal owner planner recomputes the complete affected
   ;; subtree through the shared cascade path.
   ((memq :ecss changed-keys) 'geometry)
   (t 'geometry)))

(defun ebox-incremental--candidate-region-box-table (state)
  "Return STATE's buffer-owned region boxes from the active side table."
  (if-let* ((owned-table (plist-get state :region-box-table))
            ((hash-table-p owned-table)))
      (copy-hash-table owned-table)
    (let ((table (make-hash-table :test 'equal)))
      (when-let* ((region-id-set (plist-get state :region-id-set)))
        (maphash
         (lambda (region-id _present)
           (when-let* ((box (gethash region-id ebox--region-box-table)))
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
        :range-ref-table (plist-get state :range-ref-table)
        :source-index (plist-get state :source-index)
        :selector-id-table (plist-get state :selector-id-table)
        :selector-class-table (plist-get state :selector-class-table)
        :selector-type-table (plist-get state :selector-type-table)
        :runtime-type-count-table
        (plist-get state :runtime-type-count-table)
        :selector-index-stale-p
        (plist-get state :selector-index-stale-p)
        :native-node-postorder (plist-get state :native-node-postorder)
        :native-node-postorder-ids
        (plist-get state :native-node-postorder-ids)))

(defun ebox-incremental--candidate-copy-index-table (state key test)
  "Return STATE's persistent index under KEY or a fresh legacy table."
  (let ((table (plist-get state key)))
    (cond
     ((ebox-runtime-index-p table) table)
     ((hash-table-p table) (copy-hash-table table))
     (t (make-hash-table :test test)))))

(defun ebox-incremental--candidate-node-region-record (node)
  "Return NODE's `(REGION-ID OWNER-ID BOX)' record, or nil."
  (pcase (and (listp node) (plist-get node :ebox-type))
    ('box
     (list (ebox--ensure-region-id node)
           (ebox--ensure-node-id node)
           node))
    ('flex
     (when-let* ((box (plist-get node :box)))
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
     (setq region-node-table
           (ebox-runtime-index-delete region-id region-node-table))
     (remhash region-id region-box-table))
   region-ids)
  (cl-labels
      ((visit (node)
         (when (and (listp node) (not (stringp node)))
           (when-let* ((record
                       (ebox-incremental--candidate-node-region-record node)))
             (pcase-let ((`(,region-id ,owner-id ,_box) record))
               (when (gethash region-id region-ids)
                 (puthash region-id t region-id-set)
                 (unless (ebox-runtime-index-get region-id region-node-table)
                   (setq region-node-table
                         (ebox-runtime-index-put
                          region-id owner-id region-node-table))))))
           (dolist (child (ebox--node-children node))
             (visit child))
           (when-let* ((record
                       (ebox-incremental--candidate-node-region-record node)))
             (pcase-let ((`(,region-id ,_owner-id ,box) record))
               (when (gethash region-id region-ids)
                 (puthash region-id box region-box-table)))))))
    (visit root))
  (list region-id-set region-node-table region-box-table))

(defun ebox-incremental--candidate-native-postorder (root)
  "Return ROOT's native compiler postorder without building other indexes."
  (let (postorder)
    (cl-labels
        ((visit (node native-layout-p)
           (when (and (listp node) (not (stringp node)))
             (let ((type (plist-get node :ebox-type))
                   (node-id (plist-get node :node-id)))
               (ebox-tree-for-each-direct-child
                node
                (lambda (child)
                  (visit child
                         (and native-layout-p
                              (not (and (eq type 'flex)
                                        (eq child
                                            (plist-get node :box))))))))
               (when native-layout-p
                 (push node-id postorder))))))
      (visit root t))
    (vconcat (nreverse postorder))))

(defun ebox-incremental--candidate-retain-native-postorder
    (old-state candidate-node-table)
  "Return OLD-STATE's stable node-id postorder for CANDIDATE-NODE-TABLE.
The `:native-node-postorder-ids' slot binds the exact read-only vector built
from indexed node IDs.  Reuse that vector without enumeration.  Unmarked
vectors may contain legacy node plists or IDs; resolve every entry against
the candidate index before converting them.  This format marker supplies no
topology proof, and neither producers nor consumers may mutate its vector."
  (let ((old-postorder (plist-get old-state :native-node-postorder)))
    (when (vectorp old-postorder)
      (if (eq old-postorder (plist-get old-state :native-node-postorder-ids))
          old-postorder
        (vconcat
         (mapcar
          (lambda (entry)
            (let ((node-id (if (and (listp entry)
                                    (plist-member entry :node-id))
                               (plist-get entry :node-id)
                             entry)))
              (unless (ebox-runtime-index-get node-id candidate-node-table)
                (error "Ebox candidate lost a structurally retained native node"))
              node-id))
          old-postorder))))))

(defun ebox-incremental--candidate-range-created-node-ids (range-delta-table)
  "Return new node ids covered by structural RANGE-DELTA-TABLE entries."
  (let ((old-ids (make-hash-table :test 'equal))
        (owned (make-hash-table :test 'equal)))
    (when (hash-table-p range-delta-table)
      (cl-labels ((record
                   (node table)
                   (when (and (listp node) (not (stringp node)))
                     (puthash (plist-get node :node-id) t table)
                     (ebox-tree-for-each-direct-child
                      node (lambda (child) (record child table)))))
                  (record-new
                   (node)
                   (when (and (listp node) (not (stringp node)))
                     (unless (gethash (plist-get node :node-id) old-ids)
                       (puthash (plist-get node :node-id) t owned))
                     (ebox-tree-for-each-direct-child node #'record-new))))
        ;; Compare identities across the complete Range transaction.  A node
        ;; moved between two Range parents is retained, not removed plus
        ;; inserted merely because the two structural deltas have different
        ;; owners.
        (maphash
         (lambda (_parent-id delta)
           (when (plist-get delta :children-changed)
             (dolist (payload (plist-get delta :old-payloads))
               (dolist (node payload) (record node old-ids)))))
         range-delta-table)
        (maphash
         (lambda (_parent-id delta)
           (when (plist-get delta :children-changed)
             (dolist (payload (plist-get delta :new-payloads))
               (dolist (node payload) (record-new node)))))
         range-delta-table)))
    owned))

(defun ebox-incremental--candidate-dirty-set-from-touched
    (old-state candidate-root candidate-source-index touched
               &optional range-delta-table)
  "Return declarative dirty entries for path-local TOUCHED nodes."
  (let ((old-root (plist-get old-state :root-node))
        (range-created-node-ids
         (ebox-incremental--candidate-range-created-node-ids range-delta-table))
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
          (when (and old-node
                     (not (gethash (plist-get new-node :node-id)
                                   range-created-node-ids)))
            (let* ((changed-keys
                    (ebox-incremental--candidate-local-changed-keys
                     old-node (plist-get old-state :source-index)
                     new-node candidate-source-index))
                   (range-delta
                    (and range-delta-table
                         (gethash (plist-get new-node :node-id)
                                  range-delta-table)))
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
                        (if range-delta
                            (apply #'append
                                   (mapcar #'ebox--node-all-region-ids
                                           (apply #'append
                                                  (plist-get range-delta
                                                             :old-payloads))))
                          (ebox--node-all-region-ids old-node)))
                   :new-region-ids
                   (and children-changed
                        (if range-delta
                            (apply #'append
                                   (mapcar #'ebox--node-all-region-ids
                                           (apply #'append
                                                  (plist-get range-delta
                                                             :new-payloads))))
                          (ebox--node-all-region-ids new-node)))
                   :old-signature
                   (ebox-tree-node-local-source-signature old-node)
                   :new-signature
                   (ebox-tree-node-local-source-signature new-node))
                  (if range-delta
                      (list :range-delta range-delta)
                    (ebox-incremental--child-change-props
                     old-node new-node children-changed)))
                 dirty))))))
      (nreverse dirty))))

(defconst ebox-incremental--candidate-full-index-min-touched 64
  "Minimum touched nodes before a candidate may rebuild its complete index.")

(defun ebox-incremental--candidate-full-index-p (old-state touched)
  "Return non-nil when TOUCHED justifies rebuilding OLD-STATE's index."
  (let ((touched-count (length touched))
        (old-count (ebox-runtime-index-size (plist-get old-state :node-table))))
    (and (>= touched-count
             ebox-incremental--candidate-full-index-min-touched)
         (>= (* 2 touched-count) old-count))))

(defun ebox-incremental--candidate-full-index-preparation
    (old-state candidate-root touched removed)
  "Return broad candidate preparation from TOUCHED and REMOVED nodes."
  (let* ((source-index
          (ebox-tree-source-index
           candidate-root t nil
           ebox-incremental--candidate-full-source-base-index))
         (index (ebox--runtime-index candidate-root t source-index)))
    (setq index (plist-put index :selector-index-stale-p nil))
    (list :index index
          :dirty-set
          (ebox-incremental--candidate-dirty-set-from-touched
           old-state candidate-root (plist-get index :source-index) touched)
          :participation-node-ids
          (ebox-incremental--candidate-participation-node-ids touched)
          :touched-count (length touched)
          :removed-count (length removed))))

(defun ebox-incremental--candidate-participation-node-ids (touched)
  "Return final nodes whose participation context changed in TOUCHED."
  (let ((seen (make-hash-table :test 'equal)) result)
    (cl-labels ((record
                 (node)
                 (when-let* ((node-id (and node (plist-get node :node-id))))
                   (unless (gethash node-id seen)
                     (puthash node-id t seen)
                     (push node-id result)))))
      (dolist (entry touched)
        (pcase-let ((`(,old-node ,new-node ,_parent-id ,_children-changed)
                     entry))
          (record new-node)
          ;; Added/replaced children already occur in TOUCHED.  Revisit every
          ;; direct child only when the parent's layout role itself changed.
          (when (or (null old-node)
                    (not (eq (ebox-tree--child-layout-kind old-node 'parent)
                             (ebox-tree--child-layout-kind new-node 'parent))))
            (ebox-tree-for-each-direct-child new-node #'record))))
      (nreverse result))))

(defun ebox-incremental--candidate-local-index-delta
    (old-state candidate-root &optional path-copy-trace range-index-deltas)
  "Return local indexes and dirty entries for CANDIDATE-ROOT.

Traversal stops at every node that is `eq' to OLD-STATE's indexed node.  The
work is therefore bounded by copied ancestor paths plus added, removed, and
replacement subtrees.  Node, parent, and region-owner changes path-copy their
immutable radix indexes; unrelated runtime side tables retain their existing
candidate isolation contracts."
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
                      (old-node (ebox-runtime-index-get node-id old-node-table missing)))
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
          (dolist (delta range-index-deltas)
            (let* ((old-parent (plist-get delta :old-parent))
                   (new-parent (plist-get delta :new-parent))
                   (parent-id (plist-get delta :parent-id)))
              (puthash parent-id t visited-new)
              (record-touched old-parent new-parent
                              (ebox-runtime-index-get parent-id
                                       (plist-get old-state :parent-table))
                              (plist-get delta :children-changed))
              (dolist (payload (plist-get delta :old-payloads))
                (dolist (node payload) (remove-old-subtree node)))
              (dolist (payload (plist-get delta :new-payloads))
                (dolist (node payload) (visit-new node parent-id)))))
          (if (and (hash-table-p path-copy-trace)
                   (> (hash-table-count path-copy-trace) 0))
              (progn
                ;; Replacement anchors own their affected subtrees.  Visit
                ;; those first so descendant anchors are naturally deduped.
                (maphash
                 (lambda (base-node-id trace)
                   (when (plist-get trace :anchor-p)
                     (let* ((old-node (ebox-runtime-index-get base-node-id old-node-table))
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
                          (ebox-runtime-index-get base-node-id old-node-table)
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
        (if (and (null range-index-deltas)
                 (ebox-incremental--candidate-full-index-p old-state touched))
            (let ((ebox-incremental--candidate-full-source-base-index
                   (ebox-tree-source-fact-index-delta
                    (plist-get old-state :source-index)
                    touched removed
                    ebox-incremental--candidate-incoming-source-indexes)))
              (ebox-incremental--candidate-full-index-preparation
               old-state candidate-root touched removed))
          (progn
            ;; Local region owner repair needs ancestors before descendants.
            ;; A complete index rebuild already establishes that order itself.
            (let ((depth-table (make-hash-table :test 'equal))
                  (old-parent-table (plist-get old-state :parent-table)))
              (cl-labels
                  ((parent-id
                    (node-id)
                    (if (gethash node-id visited-new)
                        (ebox-runtime-index-get node-id touched-parent-table)
                      (ebox-runtime-index-get node-id old-parent-table)))
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
                (copy-hash-table
                 (ebox-source--index-host-ref-table-view
                  (plist-get old-state :source-index))))
               (runtime-type-count-table
                (ebox-incremental--candidate-copy-index-table
                 old-state :runtime-type-count-table 'eq))
               (affected-region-ids (make-hash-table :test 'equal))
               (ambiguous-region-ids (make-hash-table :test 'equal)))
          (dolist (node removed)
            (let ((node-id (plist-get node :node-id)))
              (ebox-incremental--adjust-runtime-type-count
               runtime-type-count-table node -1)
              (setq node-table
                    (ebox-runtime-index-delete node-id node-table))
              (setq parent-table
                    (ebox-runtime-index-delete node-id parent-table))
              (when-let* ((host-ref
                           (ebox-tree-node-source-identity node)))
                (when (equal (gethash host-ref host-ref-table) node-id)
                  (remhash host-ref host-ref-table)))
              (when-let* ((record
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
                        (old-host-ref
                         (ebox-tree-node-source-identity old-node)))
              (let* ((new-node (nth 1 entry))
                     (new-host-ref
                      (ebox-tree-node-source-identity new-node))
                     (node-id (plist-get old-node :node-id)))
                (unless (equal old-host-ref new-host-ref)
                  (when (equal (gethash old-host-ref host-ref-table) node-id)
                    (remhash old-host-ref host-ref-table))))))
          (dolist (entry touched)
            (pcase-let ((`(,old-node ,new-node ,parent-id ,_children-changed)
                         entry))
              (let* ((node-id (plist-get new-node :node-id))
                     (old-type (and old-node
                                    (plist-get old-node :ebox-type)))
                     (new-type (plist-get new-node :ebox-type))
                     (old-record
                      (and old-node
                           (ebox-incremental--candidate-node-region-record
                            old-node)))
                     (new-record
                      (ebox-incremental--candidate-node-region-record new-node))
                     (stable-unique-region-p
                      (and old-record new-record
                           (equal (car old-record) (car new-record))
                           (= (or (and old-region-box-count-table
                                      (gethash (car old-record)
                                               old-region-box-count-table))
                                  0)
                              1))))
                (when (and old-node (not (eq old-type new-type)))
                  (ebox-incremental--adjust-runtime-type-count
                   runtime-type-count-table old-node -1))
                (when (and old-record (not stable-unique-region-p))
                  (puthash (car old-record) t affected-region-ids)
                  (when (hash-table-p old-region-box-count-table)
                    (ebox-incremental--candidate-adjust-region-box-count
                     region-box-count-table old-node -1)))
                (setq node-table
                      (ebox-runtime-index-put node-id new-node node-table))
                (when (or (null old-node) (not (eq old-type new-type)))
                  (ebox-incremental--adjust-runtime-type-count
                   runtime-type-count-table new-node 1))
                (if parent-id
                    (setq parent-table
                          (ebox-runtime-index-put
                           node-id parent-id parent-table))
                  (setq parent-table
                        (ebox-runtime-index-delete node-id parent-table)))
                ;; Replacement subtrees were validated before recording and
                ;; checked against untouched Host refs before path copying.
                (when-let* ((new-host-ref
                             (ebox-tree-node-source-identity new-node)))
                  (unless (and old-node
                               (equal new-host-ref
                                      (ebox-tree-node-source-identity
                                       old-node)))
                    (puthash new-host-ref node-id host-ref-table)))
                (when (and new-record (not stable-unique-region-p))
                  (puthash (car new-record) t affected-region-ids))
                (when (and (hash-table-p old-region-box-count-table)
                           (not stable-unique-region-p))
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
             (setq region-node-table
                   (ebox-runtime-index-delete
                    region-id region-node-table))
             (remhash region-id region-box-table))
           affected-region-ids)
          ;; TOUCHED is preorder, matching `ebox--runtime-index' ownership:
          ;; a flex owner claims its wrapper before the wrapper box is visited.
          (dolist (entry touched)
            (when-let* ((record
                        (ebox-incremental--candidate-node-region-record
                         (nth 1 entry))))
              (pcase-let ((`(,region-id ,owner-id ,box) record))
                (puthash region-id t region-id-set)
                (unless (ebox-runtime-index-get region-id region-node-table)
                  (setq region-node-table
                        (ebox-runtime-index-put
                         region-id owner-id region-node-table)))
                (puthash region-id box region-box-table))))
          (when (> (hash-table-count ambiguous-region-ids) 0)
            (pcase-let
                ((`(,new-region-id-set ,new-region-node-table
                    ,new-region-box-table)
                  (ebox-incremental--candidate-recompute-regions
                   candidate-root ambiguous-region-ids
                   region-id-set region-node-table region-box-table)))
              (setq region-id-set new-region-id-set
                    region-node-table new-region-node-table
                    region-box-table new-region-box-table)))
          (let* ((range-delta-table (make-hash-table :test #'equal))
                 (_range-deltas
                  (dolist (delta range-index-deltas)
                    (puthash (plist-get delta :parent-id) delta
                             range-delta-table)))
                 (candidate-source-index
                  (let ((ebox-tree--incoming-source-indexes
                         ebox-incremental--candidate-incoming-source-indexes))
                    (ebox-source--with-runtime-hosts
                     (ebox-tree-source-index-delta
                      (plist-get old-state :source-index)
                      touched removed node-table parent-table candidate-root)
                     host-ref-table)))
                 (dirty-set
                  (ebox-incremental--candidate-dirty-set-from-touched
                   old-state candidate-root
                   candidate-source-index
                   touched range-delta-table))
                 (structure-p
                  (cl-some
                   (lambda (entry)
                     (eq (plist-get entry :dirty-kind) 'structure))
                   dirty-set))
                 (native-node-postorder
                  (if (or range-index-deltas structure-p)
                      (ebox-incremental--candidate-native-postorder
                       candidate-root)
                    (ebox-incremental--candidate-retain-native-postorder
                     old-state node-table)))
                 (index
                  (list :node-table node-table
                        :parent-table parent-table
                        :region-id-set region-id-set
                        :region-node-table region-node-table
                        :region-box-count-table region-box-count-table
                        :region-box-table region-box-table
                        :range-ref-table
                        (ebox-incremental--candidate-range-ref-overlay
                         old-state path-copy-trace)
                        :source-index candidate-source-index
                        :selector-id-table
                        (ebox-source--index-selector-table
                         candidate-source-index 'id)
                        :selector-class-table
                        (ebox-source--index-selector-table
                         candidate-source-index 'class)
                        :selector-type-table
                        (ebox-source--index-selector-table
                         candidate-source-index 'type)
                        :runtime-type-count-table runtime-type-count-table
                        :selector-index-stale-p t
                        :native-node-postorder native-node-postorder
                        :native-node-postorder-ids native-node-postorder)))
            (list :index index
                  :dirty-set dirty-set
                  :participation-node-ids
                  (ebox-incremental--candidate-participation-node-ids touched)
                  :touched-node-ids
                  (mapcar
                   (lambda (entry)
                     (plist-get (nth 1 entry) :node-id))
                   touched)
                  :removed-node-ids
                  (mapcar
                   (lambda (node) (plist-get node :node-id))
                   removed)
                  :touched-region-ids
                  (ebox-incremental--hash-keys affected-region-ids)
                  :touched-count (length touched)
                  :removed-count (length removed))))))))))

(defun ebox-incremental--candidate-shares-published-node-p
    (old-state candidate-root)
  "Return non-nil when CANDIDATE-ROOT shares a published runtime node.
The search stops at the first shared node, so a copy-on-write candidate is
recognized from its first untouched sibling without walking the whole tree."
  (let ((old-root (plist-get old-state :root-node))
        (old-node-table (plist-get old-state :node-table)))
    (and (ebox-runtime-index-like-p old-node-table)
         (catch 'shared
           (cl-labels
               ((visit (node)
                  (when (and (listp node) (not (stringp node)))
                    (let ((node-id (plist-get node :node-id)))
                      (when (and node-id
                                 (not (eq node old-root))
                                 (eq node (ebox-runtime-index-get node-id old-node-table)))
                        (throw 'shared t)))
                    (dolist (child (ebox-tree--children-raw node))
                      (visit child)))))
             (visit candidate-root)
             nil)))))

(defun ebox-incremental--plist-changed-keys (old new)
  "Return ordered keys whose presence or value differs in OLD and NEW plists."
  (let (seen changed)
    (dolist (source (list old new))
      (cl-loop for key in source by #'cddr
               unless (memq key seen)
               do (push key seen)
               do (let ((old-entry (plist-member old key))
                        (new-entry (plist-member new key)))
                    (unless (and (eq (not (null old-entry))
                                     (not (null new-entry)))
                                 (equal-including-properties
                                  (cadr old-entry) (cadr new-entry)))
                      (push key changed)))))
    (nreverse changed)))

(defun ebox-incremental--declaration-changed-keys (old new)
  "Return engine longhands changed between canonical OLD and NEW declarations."
  (delete-dups
   (cl-mapcan
    #'ebox-style--engine-projection-targets
    (ebox-incremental--plist-changed-keys old new))))

(defun ebox-incremental--candidate-source-record (source-index node)
  "Return NODE's borrowed immutable record from candidate SOURCE-INDEX.
Private generated layout nodes have no source handle.  A canonical node whose
handle is absent from its generation index violates the candidate boundary."
  (when-let* ((handle (ebox-tree-node-source-handle node)))
    (or (ebox-source--index-record source-index handle)
        (error "Ebox candidate source handle is absent from its index"))))

(defun ebox-incremental--candidate-local-changed-keys
    (old old-source-index new new-source-index)
  "Return real source changes between OLD and NEW generation facts.

Published nodes carry computed ECSS longhands while fresh candidate nodes are
still declaration-stage values.  Compare non-style facts directly and compare
canonical declarations only after expanding them to the engine longhands used
by impact classification; the declaration container itself is not geometry.
Each immutable source record is resolved once for this node pair."
  (let ((old-record
         (ebox-incremental--candidate-source-record old-source-index old))
        (new-record
         (ebox-incremental--candidate-source-record new-source-index new))
        seen changed source-changed)
    (dolist (source (list old new))
      (let ((plist source))
        (while plist
          (let ((key (pop plist)))
            (pop plist)
            (unless (or (memq key seen)
                        (memq key ebox-tree--excluded-source-keys)
                        (memq key '(:props :raw-props))
                        (ebox-style--property key))
              (push key seen)
              (let ((old-entry (plist-member old key))
                    (new-entry (plist-member new key)))
                (unless (and (eq (not (null old-entry))
                                 (not (null new-entry)))
                             (funcall (if (eq key :surface-properties)
                                          #'ebox-interaction-surface-equal-p
                                        #'equal-including-properties)
                                      (cadr old-entry) (cadr new-entry)))
                  (push key changed))))))))
    (setq changed (nreverse changed))
    (unless (eq old-record new-record)
      (cl-labels
          ((record-change
            (key old-value new-value)
            (unless (equal-including-properties old-value new-value)
              (push key source-changed))))
        (record-change
         :key (and old-record (ebox-source-record-key old-record))
         (and new-record (ebox-source-record-key new-record)))
        (record-change
         :id (and old-record (ebox-source-record-id old-record))
         (and new-record (ebox-source-record-id new-record)))
        (record-change
         :class (and old-record (ebox-source-record-classes old-record))
         (and new-record (ebox-source-record-classes new-record)))
        ;; ID and key are independent metadata fields above.  SourceRecord
        ;; attributes contain only the author's explicit selector attributes,
        ;; so their changes are neither recomputed nor reported twice.
        (record-change
         :selector-attributes
         (and old-record (ebox-source-record-attributes old-record))
         (and new-record (ebox-source-record-attributes new-record)))
        (record-change
         :selector-state
         (and old-record (ebox-source--record-selector-states old-record))
         (and new-record (ebox-source--record-selector-states new-record)))
        (record-change
         :ecss
         (and old-record (ebox-source-record-ecss old-record))
         (and new-record (ebox-source-record-ecss new-record)))
        (record-change
         :ecss-targets
         (and old-record (ebox-source-record-ecss-targets old-record))
         (and new-record (ebox-source-record-ecss-targets new-record)))
        (record-change
         :ecss-scopes
         (and old-record (ebox-source-record-ecss-scopes old-record))
         (and new-record (ebox-source-record-ecss-scopes new-record)))
        (record-change
         :ecss-scope-roots
         (and old-record (ebox-source-record-ecss-scope-roots old-record))
         (and new-record (ebox-source-record-ecss-scope-roots new-record)))))
    (setq changed (nconc changed (nreverse source-changed)))
    (let ((old-declarations
           (ebox-style--node-declarations-from-record old old-record))
          (new-declarations
           (ebox-style--node-declarations-from-record new new-record)))
      (unless (ebox-style-declarations-equal-p
               old-declarations new-declarations)
        (dolist (key (ebox-incremental--declaration-changed-keys
                      old-declarations new-declarations))
        (unless (memq key changed)
            (setq changed (append changed (list key)))))))
    changed))

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
      (dolist (node-id (ebox--runtime-node-ids candidate-root))
        (let ((new-node (ebox-runtime-index-get node-id new-table)))
          (when-let* ((old-node
                       (ebox-runtime-index-get node-id old-table)))
           (let* ((changed-keys
                   (ebox-incremental--candidate-local-changed-keys
                    old-node (plist-get old-state :source-index)
                    new-node (plist-get candidate-index :source-index)))
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
                dirty)))))))
    (nreverse dirty)))

(defun ebox-incremental--isolate-candidate-caches (state)
  "Copy mutable Ebox caches in unpublished STATE.
Candidate layout may replace entries while proving a publication.  Each
candidate therefore owns its cache tables until TP commits the generation."
  (dolist (entry '((:render-cache . equal)
                   (:layout-snapshots . equal)
                   (:layout-fragments . equal)
                   (:render-signature-cache . eq)
                   (:native-fragment-owner-cache . equal)
                   (:flex-content-min-widths . eq)
                   (:viewport-height-dependent-subtree-cache . eq)))
    (let ((key (car entry))
          (value (plist-get state (car entry))))
      (when (hash-table-p value)
        (plist-put state key (copy-hash-table value)))))
  state)

(defun ebox-incremental--candidate-state
    (old-state candidate-root candidate-index prepared)
  "Return unpublished runtime state for a prepared declarative root."
  ;; Every mutable cache is replaced below and isolated once after the
  ;; candidate fields are installed.  Copying OLD-STATE's cache tables here as
  ;; well only copied values that were immediately discarded.
  (let* ((source-index
          (or (plist-get candidate-index :source-index)
              (plist-get prepared :source-index)
              (ebox-tree-source-index candidate-root)))
         (state (copy-sequence old-state)))
    (dolist
        (entry
         `((:root-node ,candidate-root)
           (:logical-candidate-p
            ,(plist-get prepared :logical-candidate-p))
           (:layout-snapshots ,(plist-get prepared :layout-snapshots))
           (:layout-snapshots-complete-p nil)
           (:layout-snapshot-detail-generation
            ,(or (plist-get prepared :layout-snapshot-detail-generation)
                 (plist-get old-state :layout-snapshot-detail-generation)
                 0))
           ;; A candidate starts without publication authority.  A successful
           ;; span projection installs fresh allocation certificates after its
           ;; output footprint has been validated.
           (:retained-allocation-certificates nil)
           (:runtime-revision
            ,(1+ (or (plist-get old-state :runtime-revision) 0)))
           (:display-signature ,(plist-get prepared :display-signature))
           (:render-cache ,(plist-get prepared :render-cache))
           (:layout-fragments ,(plist-get prepared :layout-fragments))
           (:layout-fragments-reuse-p
            ,(plist-get prepared :layout-fragments-reuse-p))
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
           (:range-ref-table
            ,(plist-get candidate-index :range-ref-table))
           (:source-index ,source-index)
           (:selector-id-table
            ,(ebox-source--index-selector-table source-index 'id))
           (:selector-class-table
            ,(ebox-source--index-selector-table source-index 'class))
           (:selector-type-table
            ,(ebox-source--index-selector-table source-index 'type))
           (:runtime-type-count-table
            ,(plist-get candidate-index :runtime-type-count-table))
           (:selector-index-stale-p
            ,(plist-get candidate-index :selector-index-stale-p))
           (:native-node-postorder
            ,(plist-get candidate-index :native-node-postorder))
           (:native-node-postorder-ids
            ,(plist-get candidate-index :native-node-postorder-ids))))
      (setq state
            (plist-put state (car entry) (cadr entry))))
    (ebox-incremental--isolate-candidate-caches state)))

(defun ebox-incremental--seed-candidate-node-cache
    (old-cache old-node-table candidate-node-table)
  "Seed an eq-keyed candidate cache from OLD-CACHE by stable node identity."
  (let ((candidate-cache (make-hash-table :test 'eq))
        (missing (make-symbol "ebox-candidate-cache-missing")))
    (when (and (hash-table-p old-cache)
               (ebox-runtime-index-like-p old-node-table)
               (ebox-runtime-index-like-p candidate-node-table))
      (ebox-runtime-index-map
       (lambda (node-id candidate-node)
         (when-let* ((old-node (ebox-runtime-index-get node-id old-node-table)))
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
      (when-let* ((old-node (ebox-runtime-index-get node-id old-node-table)))
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

(defun ebox-incremental--computed-local-dirty-set
    (old-state candidate-index dirty-set)
  "Return DIRTY-SET expressed as locally computed render effects.
The Style Adapter has already consumed selector metadata and author
declarations for nodes marked `:ebox-candidate-computed-style-p'.  For those
nodes, retain ordinary source changes, record selector fields as metadata, and
derive render changes from the computed fragment style signatures."
  (let ((old-nodes (plist-get old-state :node-table))
        (new-nodes (plist-get candidate-index :node-table)))
    (mapcar
     (lambda (entry)
       (let* ((node-id (plist-get entry :node-id))
              (old-node (and node-id (ebox-runtime-index-get node-id old-nodes)))
              (new-node (and node-id (ebox-runtime-index-get node-id new-nodes))))
         (if (or (eq (plist-get entry :dirty-kind) 'structure)
                 (not old-node)
                 (not new-node)
                 (not (plist-get new-node :ebox-candidate-computed-style-p)))
             entry
           (let* (;; Source-stage dirty planning already materialized this
                  ;; exact node-local delta.  Computed projection consumes it;
                  ;; it must not resolve the same generation facts again.
                  (source-keys (plist-get entry :changed-keys))
                  (metadata-keys
                   (cl-remove-if-not
                    (lambda (key)
                      (memq key ebox-tree-metadata-source-keys))
                    source-keys))
                  (ordinary-keys
                   (cl-remove-if
                    (lambda (key)
                      (or (ebox-style--property key)
                          (memq key ebox-tree-metadata-source-keys)))
                    source-keys))
                  (style-keys
                   (ebox-fragment-plist-changed-keys
                    (ebox-fragment-node-style-signature old-node)
                    (ebox-fragment-node-style-signature new-node)))
                  (changed-keys
                   (delete-dups (append ordinary-keys style-keys)))
                  (next (copy-sequence entry)))
             (plist-put next :changed-keys changed-keys)
             (plist-put next :metadata-changed-keys metadata-keys)
             (plist-put next :dirty-kind
                        (if changed-keys
                            (ebox-incremental--declarative-dirty-kind
                             changed-keys)
                          'metadata))
             (plist-put next :old-signature
                        (ebox-tree-node-local-source-signature old-node))
             (plist-put next :new-signature
                        (ebox-tree-node-local-source-signature new-node))
             next))))
     dirty-set)))

(defun ebox-incremental--prepare-declarative-runtime
    (buffer old-state candidate-root &optional logical-candidate-p
            local-preparation scroll-patch-p source-index prepare-all-styles-p)
  "Prepare CANDIDATE-ROOT for BUFFER without mutating its published runtime.
When PREPARE-ALL-STYLES-P is non-nil, compute selector-local styles for every
candidate node so a topology-stable native publication has a complete style
certificate."
  (let* ((old-root (plist-get old-state :root-node))
         (render-cache
          (or (plist-get old-state :render-cache)
              (make-hash-table :test 'equal)))
         (layout-fragments
          (or (plist-get old-state :layout-fragments)
              (make-hash-table :test 'equal))))
    (let* ((candidate-index
            (or (plist-get local-preparation :index)
                (ebox--runtime-index candidate-root t source-index)))
           (candidate-source-index
            (or (plist-get candidate-index :source-index)
                (plist-get local-preparation :source-index)
                (ebox-tree-source-index candidate-root)))
           (focus-source-changed-p
            (let ((projected (ebox-interaction--candidate-focus-source
                              buffer old-state candidate-index candidate-source-index candidate-root)))
              (unless (eq projected candidate-source-index)
                (setq candidate-source-index
                      (ebox-tree-source-index candidate-root t nil projected))
                t)))
           (_source-index
            (progn
              (plist-put candidate-index :source-index
                         candidate-source-index)
              (plist-put candidate-index :selector-id-table
                         (ebox-source--index-selector-table
                          candidate-source-index 'id))
              (plist-put candidate-index :selector-class-table
                         (ebox-source--index-selector-table
                          candidate-source-index 'class))
              (plist-put candidate-index :selector-type-table
                         (ebox-source--index-selector-table
                          candidate-source-index 'type))))
           (candidate-region-box-table
            (plist-get candidate-index :region-box-table))
           (source-dirty-set
            (if (and local-preparation (not focus-source-changed-p))
                (plist-get local-preparation :dirty-set)
              ;; Focus can clear on an externally hidden sibling while the
              ;; caller updates a different owner.  Include that selector
              ;; delta before deciding which retained styles are reusable.
              (ebox-incremental--declarative-dirty-set
               old-state candidate-root candidate-index)))
           (style-node-ids
            (or (plist-get local-preparation :touched-node-ids)
                (and (or prepare-all-styles-p
                         ;; A fully copied region batch has no touched-node
                         ;; index.  Mixed projection retains the style tree,
                         ;; so prepare inherited consumers before proving or
                         ;; rendering either its paint or geometry owners.
                         (and (cl-some
                               (lambda (entry)
                                 (eq (plist-get entry :dirty-kind) 'paint))
                               source-dirty-set)
                              (cl-some
                               (lambda (entry)
                                 (memq (plist-get entry :dirty-kind)
                                       '(geometry structure)))
                               source-dirty-set)))
                     (ebox-incremental--hash-keys
                      (plist-get candidate-index :node-table)))))
           (candidate-subject-table
            (and style-node-ids
                 (ebox-incremental--prepare-inline-candidate-styles
                  old-state candidate-index style-node-ids)))
           (styles-prepared-p (hash-table-p candidate-subject-table))
           (axis-node-ids
            (unless (ebox-style-cascade-active-p)
              (cl-loop for entry in source-dirty-set
                       when (cl-intersection
                             (plist-get entry :changed-keys)
                             '(:flex :flex-basis :flex-direction :flex-flow))
                       collect (plist-get entry :node-id))))
           (dirty-set source-dirty-set)
           (current-display-signature (ebox--current-display-signature)))
      (when (or local-preparation prepare-all-styles-p axis-node-ids)
        ;; Participation depends on the final parent relation and, when the
        ;; local Style Adapter succeeded, on computed values.  Validate that
        ;; final contract once here; Surface consumes the resulting
        ;; certificate instead of repeating the same indexed walk.
        (ebox-tree-validate-indexed-participation
         (plist-get candidate-index :node-table)
         (plist-get candidate-index :parent-table)
         (append (or (plist-get local-preparation :participation-node-ids)
                     style-node-ids)
                 axis-node-ids)
         (if styles-prepared-p 'computed 'author)
         candidate-source-index))
      (when styles-prepared-p
        ;; The local style adapter has consumed every pending author fact on
        ;; the touched paths.  Clear the exact retained subtree counts before
        ;; owner planning so a computed local change cannot masquerade as an
        ;; unresolved cascade change and force root scope.
        (ebox-tree-clear-author-style-pending candidate-root))
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
            (when (ebox-runtime-index-get (plist-get entry :node-id)
                           (plist-get old-state :node-table))
              (ebox--ensure-layout-snapshot-spans
               buffer (plist-get entry :node-id)))))
        (unless (equal (plist-get old-root :node-id)
                       (plist-get candidate-root :node-id))
          (ebox--ensure-layout-snapshot-spans
           buffer (plist-get old-root :node-id))))
      (let* ((structural-caches
              (ebox-incremental--candidate-structural-caches
               old-state candidate-index dirty-set
               (or local-preparation
                   ;; Newly prepared inheritance changes descendants whose
                   ;; source declarations are unchanged.  Their retained
                   ;; render signatures must not survive the style refresh.
                   (and styles-prepared-p
                        (list :touched-node-ids style-node-ids)))))
             (render-signature-cache
              (plist-get structural-caches :render-signature-cache))
             (viewport-height-dependent-subtree-cache
              (plist-get structural-caches
                         :viewport-height-dependent-subtree-cache)))
        (let* ((candidate-scroll-state-table
                (ebox-incremental--candidate-scroll-state-table
                 buffer old-state candidate-index candidate-region-box-table))
               (layout-snapshots
                (if scroll-patch-p
                    ;; Scroll changes every buffer-dependent span coordinate.
                    ;; Keep the candidate snapshot table empty and let the
                    ;; next non-scroll proof lazily recapture only the nodes it
                    ;; needs; carrying old detail plists would make hidden
                    ;; descendants point past the new visible buffer.
                    (make-hash-table :test 'equal)
                  (ebox-incremental--candidate-layout-snapshots
                   old-state candidate-root candidate-index))))
          (list :root candidate-root
                :logical-candidate-p logical-candidate-p
                :touched-node-ids
                (plist-get local-preparation :touched-node-ids)
                :removed-node-ids
                (plist-get local-preparation :removed-node-ids)
                :range-metrics (plist-get local-preparation :range-metrics)
                :range-replacement-count
                (plist-get local-preparation :range-replacement-count)
                :runtime-index-complete-p
                (plist-get local-preparation :runtime-index-complete-p)
                :computed-participation-validated-p
                (and (or local-preparation prepare-all-styles-p)
                     styles-prepared-p)
                :styles-prepared-p styles-prepared-p
                :index candidate-index
                :dirty-set dirty-set
                :display-signature current-display-signature
                :render-cache render-cache
                :layout-fragments layout-fragments
                :layout-fragments-reuse-p nil
                :detached-identity-history
                (or (plist-get local-preparation
                               :detached-identity-history)
                    (plist-get old-state :detached-identity-history))
                :render-signature-cache render-signature-cache
                :viewport-height-dependent-subtree-cache
                viewport-height-dependent-subtree-cache
                :layout-snapshots layout-snapshots
                :layout-snapshot-detail-generation
                (and scroll-patch-p
                     (1+ (or (plist-get old-state
                                         :layout-snapshot-detail-generation)
                             0)))
                :scroll-state-table candidate-scroll-state-table))))))

(defun ebox-incremental--prepare-declarative-root
    (buffer old-state next-root)
  "Prepare newly built NEXT-ROOT for BUFFER without mutating publication."
  (unless (and (listp next-root) (not (stringp next-root)))
    (error "Ebox declarative root must be an Ebox node"))
  (let* ((candidate-root
          (ebox-tree-clear-runtime-identities
           (ebox-tree-copy-node-structure next-root)))
         (candidate-source-index
          (ebox-tree-source-index
           candidate-root t nil ebox-incremental--source-base-index))
         (old-root (plist-get old-state :root-node)))
    ;; Failed preparation may leave harmless allocator gaps, but cannot publish
    ;; duplicate runtime identities.
    (ebox-tree-reconcile-runtime
     old-root (plist-get old-state :source-index)
     candidate-root candidate-source-index)
    (ebox-incremental--prepare-declarative-runtime
     buffer old-state candidate-root nil nil nil candidate-source-index
     (eq (plist-get old-state :projection-kind) 'native-frame))))

(defun ebox-incremental--candidate-source-input-map (candidate)
  "Return exact source-handle inputs carried by CANDIDATE operations."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (replacement (ebox-candidate--replacements candidate))
      (let ((index
             (ebox-incremental--candidate-replacement-source-index
              replacement)))
        (dolist (handle (ebox-source-index-handles index))
          (puthash handle index table))))
    (dolist (replacement (ebox-candidate--range-replacements candidate))
      (maphash
       (lambda (_handle index)
         (dolist (handle (ebox-source-index-handles index))
           (puthash handle index table)))
       (ebox-incremental--candidate-range-replacement-source-indexes
        replacement)))
    (dolist (patch (ebox-candidate--paint-patches candidate))
      (let ((index
             (ebox-incremental--candidate-paint-patch-source-index patch)))
        (when index
          (dolist (handle (ebox-source-index-handles index))
            (puthash handle index table)))))
    table))

(defun ebox-incremental--prepare-logical-candidate
    (buffer old-state candidate)
  "Prepare CANDIDATE's path-copied logical root for BUFFER."
  (let* ((path-copy-trace (make-hash-table :test 'equal))
         (detached-history
          (ebox-incremental--copy-detached-history old-state))
         (incoming-source-indexes
          (ebox-incremental--candidate-source-input-map candidate))
         range-index-deltas
         (candidate-root
          (let ((ebox-incremental--candidate-path-copy-trace path-copy-trace)
                (ebox-incremental--candidate-range-index-deltas nil)
                (ebox-incremental--candidate-incoming-source-indexes
                 incoming-source-indexes))
            (prog1
                (ebox-incremental--candidate-logical-root
                 candidate detached-history)
              (setq range-index-deltas
                    ebox-incremental--candidate-range-index-deltas))))
         (local-preparation
          (let ((ebox-incremental--candidate-incoming-source-indexes
                 incoming-source-indexes))
            (ebox-incremental--candidate-local-index-delta
             old-state candidate-root path-copy-trace range-index-deltas))))
    ;; Replaced subtrees were validated when they were recorded; the
    ;; untouched published remainder was validated when it was itself
    ;; published, and path copying introduces no new sibling or ref
    ;; relations outside the replaced anchors.  Re-walking the whole
    ;; tree here made every commit pay one full-page validation.
    (setq local-preparation
          (plist-put local-preparation
                     :detached-identity-history detached-history))
    (setq local-preparation
          (plist-put local-preparation :range-metrics
                     (copy-tree (ebox-candidate--range-metrics candidate))))
    (setq local-preparation
          (plist-put local-preparation :range-replacement-count
                     (length (ebox-candidate--range-replacements candidate))))
    (when (ebox-candidate--range-replacements candidate)
      (setq local-preparation
            (plist-put local-preparation :runtime-index-complete-p t)))
    (ebox-incremental--prepare-declarative-runtime
     buffer old-state candidate-root t local-preparation)))

(defun ebox-incremental--declarative-tentative-op (buffer entry)
  "Return the smallest proof candidate for declarative dirty ENTRY."
  (let* ((entry (ebox--dirty-entry-with-impact-vector buffer entry))
         (node-id (plist-get entry :node-id))
         (dirty-kind (plist-get entry :dirty-kind)))
    (if (plist-get entry :range-delta)
        (ebox--patch-op 'span-patch node-id :dirty entry)
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
         (if-let* ((span-owner-id
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
           (ebox--patch-op 'owner-rerender node-id :dirty entry))))))))

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
                (cl-every
                 (lambda (op)
                   (null (cl-intersection
                          (plist-get (plist-get op :dirty) :changed-keys)
                          ebox--typography-style-signature-keys)))
                 group)
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

(defun ebox-incremental--formatting-context-reflow-node-p (node)
  "Return non-nil when NODE is a material local block context.
The first variable-line slice accepts a real column/stack node or a material
box whose child layout is a column.  Flex/Grid allocation contexts remain
outside this proof and continue through the ordinary conservative owner path."
  (or (eq (ebox-tree-display-inner node) 'column)
      (and (eq (plist-get node :ebox-type) 'box)
           (let ((children (ebox-tree-layout-children node)))
             (and (= (length children) 1)
                  (eq (ebox-tree-display-inner (car children))
                      'column))))))

(defun ebox-incremental--formatting-context-reflow-fast-eligible-p
    (buffer old-state _candidate-state candidate-id root-id)
  "Return non-nil when a whole-line context proof is worth entering.
Use the already-published snapshot shape as a cheap negative filter.  Partial
Grid/card slots are handled by the fixed-slot span proof; they must not pay
the expensive parent-context mount and role scan first."
  (let ((parents (plist-get old-state :parent-table))
        (node-id candidate-id)
        eligible)
    (while (and node-id (not (equal node-id root-id)) (not eligible))
      (let* ((node (ebox-runtime-index-get node-id (plist-get old-state :node-table)))
             (formatting-p
              (and node
                   (ebox-incremental--formatting-context-reflow-node-p node)))
             (snapshot
              (and formatting-p
                   ;; Eligibility only needs already-published text spans.
                   ;; Completing footprint/role details for every ancestor
                   ;; made a failed proof scan the buffer repeatedly before
                   ;; the real owner proof even started.
                   (ebox--ensure-layout-snapshot-spans buffer node-id)))
             (spans (and snapshot (plist-get snapshot :buffer-spans))))
        (if (not formatting-p)
            ;; A Grid/Flex/row allocator between the dirty LCA and a whole
            ;; line context is exactly the boundary this proof refuses.
            (setq node-id nil)
          (when (and spans
                     (with-current-buffer buffer
                       (ebox--line-spans-cover-whole-lines-p spans)))
            (setq eligible t))
          (unless eligible
            (setq node-id (ebox-runtime-index-get node-id parents)))))
      )
    eligible))

(defun ebox-incremental--formatting-context-reflow-proof
    (buffer old-state candidate-state prepared)
  "Return a strict parent-formatting-context proof for PREPARED.
The proof is intentionally narrow: multiple geometry/content owners, stable
topology and parent allocation, no scroll/cascade/overflow, and a whole-line
material block under normal column flow.  The returned owner may change block
line count; its outside siblings are shifted by the one scoped replacement."
  (let* ((dirty-set (plist-get prepared :dirty-set))
         (node-ids
          (delete-dups
           (cl-mapcan #'ebox--dirty-provenance-node-ids dirty-set)))
         (root-id (ebox--buffer-root-node-id buffer))
         (parents (plist-get old-state :parent-table))
         (candidate-parents (plist-get candidate-state :parent-table))
         (candidate-id
          (and (>= (length dirty-set) 2)
               (ebox-incremental--common-runtime-ancestor-id
                buffer node-ids)))
         proof)
    (when (and candidate-id
               (not (equal candidate-id root-id))
               (ebox-incremental--formatting-context-reflow-fast-eligible-p
                buffer old-state candidate-state candidate-id root-id)
               (null (plist-get old-state :scroll-region-ids))
               (not (plist-get old-state :cascade-active-p))
               (or (not (plist-get old-state :cascade-required-p))
                   (ebox-incremental--cascade-local-owner-proof-p
                    old-state candidate-state dirty-set))
               (cl-every
                (lambda (entry)
                  (and (eq (plist-get entry :dirty-kind) 'geometry)
                       (not (plist-get entry :children))
                       (null (plist-get entry :node-ids))
                       (cl-every
                        (lambda (key)
                          (or (eq key :content)
                              (eq key :surface-properties)
                              (memq key ebox--paint-style-signature-keys)))
                        (plist-get entry :changed-keys))))
                dirty-set))
      (while (and candidate-id (not proof)
                  (not (equal candidate-id root-id)))
        (let* ((old-node (ebox-runtime-index-get candidate-id
                                  (plist-get old-state :node-table)))
               (new-node (ebox-runtime-index-get candidate-id
                                  (plist-get candidate-state :node-table)))
               (parent-id (ebox-runtime-index-get candidate-id parents))
               (snapshot
                (and old-node
                     (ebox--ensure-layout-snapshot-details
                      buffer candidate-id)))
               (spans (and snapshot (plist-get snapshot :buffer-spans)))
               (block-span
                (when-let* ((object-table
                             (plist-get old-state
                                        :surface-node-object-table))
                            (object (gethash candidate-id object-table))
                            (mounts (tp-object-mounts object)))
                  (cons (apply #'min (mapcar (lambda (mount)
                                               (plist-get mount :start))
                                             mounts))
                        (apply #'max (mapcar (lambda (mount)
                                               (plist-get mount :end))
                                             mounts)))))
               (parent (and parent-id
                            (ebox-runtime-index-get parent-id
                                     (plist-get old-state :node-table))))
               (parent-new (and parent-id
                                (ebox-runtime-index-get parent-id
                                         (plist-get candidate-state :node-table))))
               (ancestors-stable-p t)
               (walk parent-id))
          (while (and walk ancestors-stable-p (not (equal walk root-id)))
            (let ((ancestor (ebox-runtime-index-get walk (plist-get old-state :node-table))))
              (when (or (not ancestor)
                        (memq (ebox-tree-display-inner ancestor) '(row flex grid))
                        (ebox-tree-node-visible-overflow-p ancestor))
                (setq ancestors-stable-p nil)))
            (setq walk (ebox-runtime-index-get walk parents)))
          (when (and old-node new-node parent parent-new
                     (ebox-incremental--formatting-context-reflow-node-p
                      old-node)
                     (equal (ebox-runtime-index-get candidate-id parents)
                            (ebox-runtime-index-get candidate-id candidate-parents))
                     (ebox-incremental--node-child-ids-equal-p
                      old-node new-node)
                     (equal (ebox-incremental--layout-slot-style-signature
                             old-node)
                            (ebox-incremental--layout-slot-style-signature
                             new-node))
                     (ebox--span-patch-definite-size-value-p
                      (ebox-get old-node :width))
                     (equal (ebox-get old-node :width)
                            (ebox-get new-node :width))
                     (eq (ebox-tree-display-inner parent) 'column)
                     (eq (ebox-tree-display-inner parent-new) 'column)
                     ancestors-stable-p
                     spans
                     block-span
                     (with-current-buffer buffer
                       (ebox--line-spans-cover-whole-lines-p spans))
                     (cl-every
                      (lambda (node-id)
                        (or (equal node-id candidate-id)
                            (ebox--cached-runtime-ancestor-id-p
                             buffer candidate-id node-id)))
                      node-ids))
            (setq proof
                  (list :owner-id candidate-id
                        :parent-id parent-id
                        :dirty-set (copy-sequence dirty-set)
                        :snapshot snapshot
                        :old-spans spans
                        :old-block-span block-span
                        :region-ids (plist-get snapshot :region-ids)
                        :allocated-width
                        (ebox--span-patch-used-size
                         old-node (ebox-get old-node :width) 'horizontal)
                        :layout-snapshot-detail-generation
                        (plist-get old-state
                                   :layout-snapshot-detail-generation))))
          (unless proof
            (setq candidate-id (ebox-runtime-index-get candidate-id parents))))))
    proof))

(defun ebox-incremental--two-owner-geometry-proof
    (buffer old-state candidate-state geometry-prepared)
  "Combine exact geometry proofs for two changes.
Changes sharing one safe owner reuse its grouped proof; separate owners retain
their disjoint span or allocation proofs.  Larger dirty sets keep coalescing."
  (let ((dirty-set (plist-get geometry-prepared :dirty-set))
        (root-id (ebox--buffer-root-node-id buffer))
        proofs owner-proofs valid allocation-p)
    (setq valid (= (length dirty-set) 2))
    ;; Prove definite-width local spans first.  Their snapshot proof warms the
    ;; shared ancestor facts subsequently consumed by an auto-width allocation
    ;; closure, avoiding the same cold ancestor scan in the wider proof.
    (dolist (dirty
             (sort
              (copy-sequence dirty-set)
              (lambda (left right)
                (let ((left-width
                       (plist-get (plist-get left :old-signature) :width))
                      (right-width
                       (plist-get (plist-get right :old-signature) :width)))
                  (and (ebox--span-patch-definite-size-value-p left-width)
                       (not (ebox--span-patch-definite-size-value-p
                             right-width)))))))
      (when valid
        (let* ((local-prepared (plist-put (copy-sequence geometry-prepared)
                                          :dirty-set (list dirty)))
               (plan
                ;; One dirty entry needs no dominance/coalescing pass.  Build
                ;; its tentative operation directly; the exact span or
                ;; allocation proof below still owns authorization.
                (when-let* ((op
                            (ebox-incremental--declarative-tentative-op
                             buffer dirty)))
                  (list op)))
               (allocation-first-p
                (let ((old-width
                       (plist-get (plist-get dirty :old-signature) :width))
                      (new-width
                       (plist-get (plist-get dirty :new-signature) :width)))
                  ;; A stable definite-width content slot is the cheap local
                  ;; span case.  Auto-width content must prove its allocator
                  ;; closure anyway, so do that before constructing the more
                  ;; expensive span-footprint proof that usually rejects it.
                  (or (eq (plist-get (car plan) :op) 'owner-rerender)
                      (not (and (ebox--span-patch-definite-size-value-p old-width)
                                (ebox--span-patch-definite-size-value-p new-width)
                                (equal old-width new-width))))))
               (early-allocation-proof
                (and allocation-first-p
                     (ebox-incremental--allocation-closure-proof
                      buffer old-state candidate-state local-prepared)))
               (span-proof
                (and (not early-allocation-proof) plan
                     (ebox-incremental--span-patch-projection-proof
                      buffer old-state local-prepared candidate-state plan)))
               (allocation-proof
                (or early-allocation-proof
                    (and (not span-proof)
                         (ebox-incremental--allocation-closure-proof
                          buffer old-state candidate-state local-prepared))))
               (proof (or span-proof allocation-proof))
               (ids (and proof
                         (or (plist-get proof :owner-ids)
                             (and (plist-get proof :owner-id)
                                  (list (plist-get proof :owner-id))))))
               (local-owner-proofs
                (and proof
                     (or (plist-get proof :owner-proofs)
                         (and (plist-get proof :owner-id) (list proof))))))
          (when (and span-proof
                     (not (plist-get span-proof :owner-proofs)))
            (setq proof
                  (plist-put (copy-sequence proof)
                             :retain-external-owner-suffix-p t)
                  local-owner-proofs (list proof)))
          (if (and proof ids
                   (not (member root-id ids))
                   local-owner-proofs)
              (progn
                (push proof proofs)
                (setq owner-proofs
                      (append owner-proofs
                              (copy-sequence local-owner-proofs)))
                (setq allocation-p (or allocation-p allocation-proof)))
            (setq valid nil)))))
    (when (and valid (= (length proofs) 2))
      (setq proofs (nreverse proofs))
      (let ((owner-ids
             (delete-dups
              (mapcar (lambda (proof) (plist-get proof :owner-id))
                      owner-proofs))))
        (if (= (length owner-ids) 1)
            (when-let* ((grouped
                         (ebox-incremental--grouped-owner-span-proof
                          buffer old-state geometry-prepared candidate-state
                          (list (ebox--patch-op 'span-patch (car owner-ids))))))
              (dolist (owner-proof (plist-get grouped :owner-proofs))
                (plist-put owner-proof :retain-external-owner-suffix-p t))
              grouped)
          (when (ebox-incremental--owner-proofs-disjoint-p buffer owner-proofs)
            (list :owner-id (car owner-ids)
                  :owner-ids owner-ids
                  :owner-proofs owner-proofs
                  :dirty-set (copy-sequence dirty-set)
                  :variable-content-p
                  (cl-some (lambda (proof)
                             (plist-get proof :variable-content-p))
                           proofs)
                  :ancestor-slot-signature
                  (cl-mapcan
                   (lambda (proof)
                     (copy-sequence
                      (plist-get proof :ancestor-slot-signature)))
                   proofs)
                  :layout-snapshot-detail-generation
                  (plist-get old-state :layout-snapshot-detail-generation)
                  :static-cascade-p
                  (cl-every (lambda (proof)
                              (plist-get proof :static-cascade-p))
                            proofs)
                  :contains-allocation-closure-p allocation-p)))))))

(defun ebox-incremental--mixed-owner-proof
    (buffer old-state candidate-state prepared owner-plan)
  "Return a strict mixed geometry/paint proof, or nil.
The geometry half reuses the existing variable-line formatting-context proof
with only geometry entries.  Paint owners must be disjoint, retain their
layout/topology facts, and change only the first-slice color declarations.
This function is deliberately proof-only: it never widens a scope or
suppresses the ordinary fallback when any fact is missing."
  (let* ((dirty-set (plist-get prepared :dirty-set))
         (geometry-dirty
          (mapcar
           (lambda (entry)
             ;; A merged provenance entry may carry sibling paint owners in
             ;; `:node-ids'.  Geometry proof must start from the geometry
             ;; entry's own node, otherwise a second selected row can lift
             ;; the LCA to the root and forfeit mixed-owner publication.
             (let ((copy (copy-sequence entry)))
               (plist-put copy :node-ids nil)
               copy))
           (cl-remove-if-not
            (lambda (entry)
              (or (eq (plist-get entry :dirty-kind) 'geometry)
                  (and (eq (plist-get entry :dirty-kind) 'structure)
                       (plist-get entry :range-delta))))
            dirty-set)))
         (paint-dirty
          (cl-remove-if-not
           (lambda (entry) (eq (plist-get entry :dirty-kind) 'paint))
           dirty-set))
         (geometry-prepared
          (and geometry-dirty
               (plist-put (copy-sequence prepared)
                          :dirty-set geometry-dirty)))
         (range-dirty
          (cl-remove-if-not (lambda (entry)
                              (plist-get entry :range-delta))
                            geometry-dirty))
         (ordinary-geometry-dirty
          (cl-remove-if (lambda (entry)
                          (plist-get entry :range-delta))
                        geometry-dirty))
         ;; Two independent content changes commonly arise from one semantic
         ;; action (for example a control label plus status text).  Try the
         ;; narrow per-owner allocation union before walking and completing a
         ;; broader common formatting context that will be discarded when the
         ;; two local proofs already close exactly.
         (geometry-two-owner-proof
          (and (= (length geometry-dirty) 2)
               (ebox-incremental--two-owner-geometry-proof
                buffer old-state candidate-state geometry-prepared)))
         (geometry-context-proof
          (and (not geometry-two-owner-proof)
               (null range-dirty)
               (>= (length geometry-dirty) 2)
               (ebox-incremental--formatting-context-reflow-proof
                buffer old-state candidate-state geometry-prepared)))
         (geometry-plan
          (and (not geometry-two-owner-proof)
               (not geometry-context-proof)
               geometry-dirty
               (let ((ebox-incremental--candidate-state-for-slot-proof
                      candidate-state))
                 (append
                  (mapcar
                   (lambda (entry)
                     (ebox--patch-op 'span-patch
                                     (plist-get entry :node-id)
                                     :dirty entry))
                   range-dirty)
                  (and ordinary-geometry-dirty
                       (ebox-incremental--layout-owner-plan
                        buffer old-state candidate-state
                        ordinary-geometry-dirty))))))
         (geometry-span-proof
          (and geometry-plan
               (ebox-incremental--span-patch-projection-proof
                buffer old-state geometry-prepared candidate-state
                geometry-plan)))
         (geometry-allocation-proof
          (and (= (length geometry-dirty) 1)
               (not geometry-context-proof)
               (not geometry-span-proof)
               (ebox-incremental--allocation-closure-proof
                buffer old-state candidate-state geometry-prepared)))
         (geometry-proof
          (or geometry-context-proof geometry-span-proof
              geometry-allocation-proof geometry-two-owner-proof))
         (geometry-kind (and geometry-proof
                             (if geometry-context-proof
                                 'formatting-context-reflow
                               'span-patch)))
         (geometry-owner-ids
          (cond
           (geometry-context-proof
            (list (plist-get geometry-context-proof :owner-id)))
           (geometry-span-proof
            (copy-sequence (plist-get geometry-span-proof :owner-ids)))
           (geometry-allocation-proof
            (copy-sequence
             (plist-get geometry-allocation-proof :owner-ids)))
           (geometry-two-owner-proof
            (copy-sequence
             (plist-get geometry-two-owner-proof :owner-ids)))))
         (geometry-owner-id (car geometry-owner-ids))
         (external-paint-dirty
          (and geometry-owner-ids
               (cl-remove-if
                (lambda (entry)
                  (cl-some
                   (lambda (geometry-id)
                     (let ((node-id (plist-get entry :node-id)))
                       (or (equal geometry-id node-id)
                           (ebox--cached-runtime-ancestor-id-p
                            buffer geometry-id node-id))))
                   geometry-owner-ids))
                paint-dirty)))
         (paint-owner-ids
          (delete-dups
           (cl-mapcan #'ebox--dirty-provenance-node-ids
                      external-paint-dirty)))
         (old-nodes (plist-get old-state :node-table))
         (new-nodes (plist-get candidate-state :node-table))
         (root-id (ebox--buffer-root-node-id buffer))
         (paint-valid-p
          (and external-paint-dirty
               (cl-every
                (lambda (entry)
                  (and (plist-get entry :node-id)
                       (cl-every (lambda (key)
                                   (memq key
                                         '(:color :bgcolor
                                           :border-left-color
                                           :border-right-color
                                           :border-top-color
                                           :border-bottom-color)))
                                 (plist-get entry :changed-keys))
                       (let* ((node-id (plist-get entry :node-id))
                              (old-node (ebox-runtime-index-get node-id old-nodes))
                              (new-node (ebox-runtime-index-get node-id new-nodes)))
                         (and old-node new-node
                              (ebox-incremental--node-child-ids-equal-p
                               old-node new-node)
                              (equal (ebox-runtime-index-get node-id
                                              (plist-get old-state :parent-table))
                                     (ebox-runtime-index-get node-id
                                              (plist-get candidate-state
                                                         :parent-table)))
                              ;; Paint consumes effective values.  Its newly
                              ;; computed style may explicitly store nil
                              ;; defaults that the retained node omitted.
                              (null
                               (ebox-fragment-plist-changed-keys
                                (ebox-incremental--layout-slot-style-signature
                                 old-node)
                                (ebox-incremental--layout-slot-style-signature
                                 new-node)))
                              (equal (ebox-get old-node :width)
                                     (ebox-get new-node :width))
                              (equal (ebox-get old-node :height)
                                     (ebox-get new-node :height))
                              (equal (plist-get
                                      (plist-get entry :old-signature)
                                      :content)
                                     (plist-get
                                      (plist-get entry :new-signature)
                                      :content))))))
                external-paint-dirty)))
         (disjoint-p
          (and geometry-owner-ids
               (not (cl-some (lambda (geometry-id)
                               (member geometry-id paint-owner-ids))
                             geometry-owner-ids))))
         (allocation-disjoint-p
          (or (not (or geometry-allocation-proof
                       geometry-two-owner-proof))
              (ebox-incremental--allocation-closure-paint-disjoint-p
               old-state geometry-owner-ids paint-owner-ids)))
         (cascade-safe-p
          (or (and (not (plist-get old-state :cascade-active-p))
                   (not (plist-get old-state :cascade-required-p))
                   (not (ebox-style-cascade-active-p)))
              (ebox-incremental--cascade-local-owner-proof-p
               old-state candidate-state dirty-set))))
    (when (and ebox-incremental--projection-rejections-enabled-p
               geometry-dirty paint-dirty)
      ;; Record evaluated capability boundaries, not timing guesses or private
      ;; runtime graphs.  Several independent boundaries can reject one union.
      (let (reasons)
        (unless geometry-proof (push 'geometry-allocation reasons))
        (when (and geometry-proof (not paint-valid-p))
          (push (if (cl-some
                     (lambda (entry)
                       (memq :surface-properties (plist-get entry :changed-keys)))
                     external-paint-dirty)
                    'native-property-composition
                  'paint-composition)
                reasons))
        (unless (plist-get prepared :styles-prepared-p)
          (push 'candidate-style-preparation reasons))
        (unless cascade-safe-p (push 'retained-style-closure reasons))
        (when (and geometry-owner-ids paint-owner-ids
                   (not (and disjoint-p allocation-disjoint-p)))
          (push 'overlapping-output reasons))
        (when reasons
          (push (list :projection 'mixed-owner-reflow :reasons (nreverse reasons))
                ebox-incremental--projection-rejections))))
    (when (and geometry-span-proof
               (not (plist-get geometry-span-proof :owner-proofs)))
      ;; A detached single owner is rendered outside its ancestor wrappers.
      ;; Preserve the committed external owner suffix when this proof joins a
      ;; mixed geometry/paint publication, just as the two-owner union does.
      (setq geometry-proof
            (plist-put (copy-sequence geometry-span-proof)
                       :retain-external-owner-suffix-p t)))
    (when (and geometry-proof paint-valid-p disjoint-p
               ;; Reusing the style tree is safe only after the candidate's
               ;; inherited paint closure was projected.  Tree-dependent
               ;; selectors keep the ordinary cascade/render fallback.
               (plist-get prepared :styles-prepared-p)
               allocation-disjoint-p cascade-safe-p
               ;; Both the rendered geometry and inherited paint must leave
               ;; every retained scroll producer outside their dependency scope.
               (cl-every
                (lambda (owner-id)
                  (ebox-incremental--owner-disjoint-from-scroll-p
                   buffer old-state prepared candidate-state owner-id))
                (append geometry-owner-ids paint-owner-ids))
               (not (plist-get prepared :scroll-state-transaction))
               (not (plist-get prepared :scroll-patch-fast-p))
               root-id
               (not (equal geometry-owner-id root-id))
               (> (ebox-runtime-index-size old-nodes)
                  (length (delete-dups (append geometry-owner-ids
                                               paint-owner-ids)))))
      (list :geometry-proof geometry-proof
            :geometry-kind geometry-kind
            :geometry-owner-ids geometry-owner-ids
            :geometry-owner-id geometry-owner-id
            :paint-owner-ids paint-owner-ids
            :owner-ids (append geometry-owner-ids paint-owner-ids)
            :dirty-set (copy-sequence dirty-set)
            :owner-plan (copy-tree owner-plan)
            :outside-complement-count
            (- (ebox-runtime-index-size old-nodes)
               (length (delete-dups (append geometry-owner-ids
                                            paint-owner-ids))))))))

(defun ebox-incremental--allocation-closure-paint-disjoint-p
    (state geometry-owner-ids paint-owner-ids)
  "Return non-nil when paint cannot overwrite geometry closure output.
Paint owned by an ancestor of a geometry closure is safe: mixed projection
recomposes that semantic contribution from the fragment baseline after the
closure is rendered.  Paint at the geometry owner or below it is rejected,
because it could address a run whose topology the closure just replaced."
  (let ((parents (plist-get state :parent-table))
        (geometry-set (make-hash-table :test 'equal))
        (valid t))
    (dolist (node-id geometry-owner-ids) (puthash node-id t geometry-set))
    (dolist (node-id paint-owner-ids)
      (let ((walk node-id))
        (while (and valid walk)
          (when (gethash walk geometry-set) (setq valid nil))
          (setq walk (and valid (ebox-runtime-index-get walk parents))))))
    valid))

(defun ebox-incremental--allocation-closure-ancestor-stable-p
    (old-state candidate-state owner-id)
  "Return non-nil when OWNER-ID's retained path through the root is stable."
  (let ((old-nodes (plist-get old-state :node-table))
        (new-nodes (plist-get candidate-state :node-table))
        (old-parents (plist-get old-state :parent-table))
        (new-parents (plist-get candidate-state :parent-table))
        (node-id owner-id)
        (valid t))
    (while (and valid node-id)
      (let* ((old-node (ebox-runtime-index-get node-id old-nodes))
             (new-node (ebox-runtime-index-get node-id new-nodes))
             (old-parent (ebox-runtime-index-get node-id old-parents)))
        (setq valid
              (and old-node new-node
                   (equal old-parent (ebox-runtime-index-get node-id new-parents))
                   (ebox-incremental--node-child-ids-equal-p
                    old-node new-node)
                   (equal
                    (ebox-incremental--layout-slot-style-signature old-node)
                    (ebox-incremental--layout-slot-style-signature new-node))
                   (not (eq (ebox-get
                             (ebox-fragment-style-source-node old-node)
                             :overflow)
                            'visible))
                   (not (eq (ebox-get
                             (ebox-fragment-style-source-node new-node)
                             :overflow)
                            'visible))
                   (not (ebox-tree-node-visible-overflow-p old-node))
                   (not (ebox-tree-node-visible-overflow-p new-node))))
        (setq node-id old-parent)))
    valid))

(defun ebox-incremental--allocation-closure-proof
    (buffer old-state candidate-state prepared)
  "Return a strict retained Flex allocation closure proof, or nil."
  (let* ((dirty-set (plist-get prepared :dirty-set))
         (dirty (and (= (length dirty-set) 1) (car dirty-set)))
         (dirty-id (and dirty (plist-get dirty :node-id)))
         (changed-keys (and dirty (plist-get dirty :changed-keys)))
         (old-nodes (plist-get old-state :node-table))
         (new-nodes (plist-get candidate-state :node-table))
         (parents (plist-get old-state :parent-table))
         (candidate-parents (plist-get candidate-state :parent-table))
         (objects (plist-get old-state :surface-node-object-table))
         (root-id (ebox--buffer-root-node-id buffer))
         (candidate-id dirty-id)
         (saw-flex-p nil)
         (path-valid-p t)
         proof)
    (when (and dirty dirty-id root-id
               (eq (plist-get dirty :dirty-kind) 'geometry)
               (memq :content changed-keys)
               (not (plist-get dirty :children))
               (null (plist-get dirty :node-ids))
               (cl-every
                (lambda (key)
                  (or (eq key :content)
                      (eq key :surface-properties)
                      (memq key ebox--paint-style-signature-keys)))
                changed-keys)
               (ebox-incremental--same-root-surface-identity-p
                old-state candidate-state)
               (ebox-incremental--span-patch-identity-stable-p
                buffer old-state candidate-state prepared dirty-id)
               (null (plist-get old-state :scroll-region-ids))
               (null (plist-get candidate-state :scroll-region-ids))
               (or (and (not (plist-get old-state :cascade-active-p))
                        (not (plist-get old-state :cascade-required-p))
                        (not (ebox-style-cascade-active-p)))
                   (ebox-incremental--cascade-local-owner-proof-p
                    old-state candidate-state dirty-set)))
      (while (and candidate-id path-valid-p (not proof)
                  (not (equal candidate-id root-id)))
        (let* ((old-node (ebox-runtime-index-get candidate-id old-nodes))
               (new-node (ebox-runtime-index-get candidate-id new-nodes))
               (parent-id (ebox-runtime-index-get candidate-id parents))
               (display (and old-node (ebox-tree-display-inner old-node))))
          (setq saw-flex-p (or saw-flex-p (eq display 'flex)))
          (setq path-valid-p
                (and old-node new-node
                     (equal parent-id
                            (ebox-runtime-index-get candidate-id candidate-parents))
                     (ebox-incremental--node-child-ids-equal-p
                      old-node new-node)
                     (equal
                      (ebox-incremental--layout-slot-style-signature old-node)
                      (ebox-incremental--layout-slot-style-signature new-node))
                     (not (eq (ebox-get
                               (ebox-fragment-style-source-node old-node)
                               :overflow)
                              'visible))
                     (not (eq (ebox-get
                               (ebox-fragment-style-source-node new-node)
                               :overflow)
                              'visible))
                     (not (ebox-tree-node-visible-overflow-p old-node))
                     (not (ebox-tree-node-visible-overflow-p new-node))))
          (when (and path-valid-p saw-flex-p
                     (hash-table-p objects) (gethash candidate-id objects))
            (let* ((snapshot
                    (ebox-incremental--cached-layout-snapshot-details
                     buffer candidate-id))
                   (spans (and snapshot (plist-get snapshot :buffer-spans)))
                   (ancestor-signature
                    (and spans
                         (ebox-incremental--ancestor-slot-signature
                          buffer old-state candidate-state candidate-id)))
                   (allocated-width
                    (and snapshot
                         (plist-get
                          (plist-get snapshot
                                     :external-footprint-signature)
                          :max-line-pixel-width)))
                   (content
                    (plist-get (plist-get dirty :new-signature) :content)))
              (when (and spans ancestor-signature allocated-width
                         (> allocated-width 0)
                         (stringp content)
                         (not (string-match-p "\n" content))
                         (<= (ebox--string-pixel-width content)
                             allocated-width)
                         (ebox--spans-contiguous-lines-p spans)
                         (with-current-buffer buffer
                           (ebox--line-spans-cover-whole-lines-p spans))
                         (ebox-incremental--allocation-closure-ancestor-stable-p
                          old-state candidate-state candidate-id))
                (let ((owner-proof
                       (list :owner-id candidate-id
                             :dirty-set (copy-sequence dirty-set)
                             :changed-keys (copy-sequence changed-keys)
                             :snapshot snapshot
                             :allocated-width allocated-width
                             :allocation-closure-p t
                             :ancestor-slot-signature ancestor-signature
                             :layout-snapshot-detail-generation
                             (plist-get old-state
                                        :layout-snapshot-detail-generation)
                             :static-cascade-p t)))
                  (setq proof
                        (list :owner-ids (list candidate-id)
                              :owner-proofs (list owner-proof)
                              :dirty-set (copy-sequence dirty-set)
                              :ancestor-slot-signature ancestor-signature
                              :layout-snapshot-detail-generation
                              (plist-get old-state
                                         :layout-snapshot-detail-generation)
                              :static-cascade-p t))))))
          (setq candidate-id parent-id))))
    proof))

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
             (or (= (length render-dirty-set) 2)
                 (not
                  (cl-every
                   (lambda (entry)
                     (equal (plist-get entry :changed-keys) '(:content)))
                   render-dirty-set)))
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

(defun ebox-incremental--nearest-fixed-basis-flex-item-owner-id
    (buffer node-id)
  "Return NODE-ID's nearest content-independent fixed-basis Flex item."
  (let ((candidate node-id)
        (root-id (ebox--buffer-root-node-id buffer))
        owner)
    (while (and candidate (not owner) (not (equal candidate root-id)))
      (if (ebox--flex-item-fixed-basis-content-allocation-stable-p
           buffer candidate)
          (setq owner candidate)
        (setq candidate (ebox--runtime-parent-id buffer candidate))))
    owner))

(defun ebox-incremental--fixed-basis-flex-local-op
  (buffer render-dirty-set &optional allow-single-p)
  "Return one tentative Flex-item op for related geometry RENDER-DIRTY-SET.

Multiple descendant content changes can share a fixed-basis, zero-minimum Flex
item without changing its main-axis allocation.  This planner only selects the
shared owner; grouped proof verifies topology and the retained ancestor slot,
then Surface performs the one actual candidate render and complete footprint,
role, overflow, and outside-complement validation.  ALLOW-SINGLE-P also selects
an owner for one descendant after its narrower projection proof has failed."
  (when (and (or (> (length render-dirty-set) 1)
                 (and allow-single-p (= (length render-dirty-set) 1)))
             (cl-every
              (lambda (entry)
                (and (eq (plist-get entry :dirty-kind) 'geometry)
                     (not (plist-get entry :children))))
              render-dirty-set))
    (let* ((owner-ids
            (delete-dups
             (mapcar
              (lambda (entry)
                (ebox-incremental--nearest-fixed-basis-flex-item-owner-id
                 buffer (plist-get entry :node-id)))
              render-dirty-set)))
           (owner-id (and (= (length owner-ids) 1) (car owner-ids))))
      (when (and owner-id
                 (not (equal owner-id (ebox--buffer-root-node-id buffer))))
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

(defvar ebox-incremental--patch-planner-route 'pure
  "Internal M2a patch planner route: `legacy', `pure', or `shadow'.")

(defun ebox-incremental--legacy-tentative-patch-set
    (buffer render-dirty-set)
  "Return legacy merged owner candidates for RENDER-DIRTY-SET in BUFFER."
  (let ((ebox--patchable-owner-cache (make-hash-table :test 'equal))
        (ebox--runtime-ancestor-cache (make-hash-table :test 'equal))
        (ebox--flex-slot-safety-cache
         (or ebox--flex-slot-safety-cache
             (make-hash-table :test 'equal)))
        (index (ebox--make-patch-op-merge-index))
        ops)
    (ebox--with-layout-snapshot-detail-context buffer
      (if-let* ((coalesced-op
                (and (not
                      (ebox-incremental--dirty-set-has-child-splice-p
                       buffer render-dirty-set))
                     (or (ebox-incremental--broad-dirty-op
                          buffer render-dirty-set)
                         (ebox-incremental--fixed-basis-flex-local-op
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

(defun ebox-incremental--pure-tentative-patch-set
    (buffer render-dirty-set)
  "Return pure-port merged owner candidates for RENDER-DIRTY-SET in BUFFER."
  (let ((ebox--patchable-owner-cache (make-hash-table :test 'equal))
        (ebox--runtime-ancestor-cache (make-hash-table :test 'equal))
        (ebox--flex-slot-safety-cache
         (or ebox--flex-slot-safety-cache
             (make-hash-table :test 'equal)))
        (parent-table
         (plist-get (ebox--buffer-render-state buffer) :parent-table))
        ops)
    (unless (ebox-runtime-index-like-p parent-table)
      (signal 'ebox-patch-plan-error
              (list :missing-parent-table buffer)))
    (ebox--with-layout-snapshot-detail-context buffer
      (if-let* ((coalesced-op
                (and (not
                      (ebox-incremental--dirty-set-has-child-splice-p
                       buffer render-dirty-set))
                     (or (ebox-incremental--broad-dirty-op
                          buffer render-dirty-set)
                         (ebox-incremental--fixed-basis-flex-local-op
                          buffer render-dirty-set)
                         (ebox-incremental--local-reflow-op
                          buffer render-dirty-set)))))
          (setq ops (list coalesced-op))
        (setq ops
              (mapcar
               (lambda (entry)
                 (ebox-incremental--declarative-tentative-op buffer entry))
               render-dirty-set))
        (setq ops (ebox-patch-plan-merge-ops parent-table ops))
        (setq ops
              (ebox-incremental--coalesce-sibling-line-span-ops
               buffer ops))))
    (ebox-patch-plan-merge-ops parent-table ops)))

(defun ebox-incremental--declarative-tentative-patch-set
    (buffer render-dirty-set)
  "Return route-selected smallest-owner candidates for RENDER-DIRTY-SET."
  (pcase ebox-incremental--patch-planner-route
    ('legacy
     (ebox-incremental--legacy-tentative-patch-set
      buffer render-dirty-set))
    ('pure
     (ebox-incremental--pure-tentative-patch-set
      buffer render-dirty-set))
    ('shadow
     (let ((legacy
            (ebox-incremental--legacy-tentative-patch-set
             buffer render-dirty-set))
           (pure
            (ebox-incremental--pure-tentative-patch-set
             buffer render-dirty-set)))
       (unless (equal legacy pure)
         (signal 'ebox-patch-plan-error
                 (list :shadow-artifact-mismatch
                       :legacy legacy :pure pure)))
       pure))
    (_
     (signal 'ebox-patch-plan-error
             (list :unknown-route ebox-incremental--patch-planner-route)))))

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
  (when-let* ((render-dirty-set
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

(defun ebox-incremental--layer-owner-plan
    (buffer old-state candidate-state dirty-set)
  "Promote DIRTY-SET to complete compositing owners when layers are affected.
BUFFER owns OLD-STATE; CANDIDATE-STATE supplies the next logical tree.
Ordinary mounted trees use their retained negative layer flag.  Introducing
layers only inspects changed declarations or replacement subtrees.  Nested
hosts promote through enclosing hosts because their upper siblings may hide
the inner host's output."
  (when (and (fboundp 'ebox-layer-host-p)
             (or (plist-get old-state :layered-p)
                 (cl-some
                  (lambda (dirty)
                    (cl-intersection (plist-get dirty :changed-keys)
                                     '(:position :layer :children)))
                  dirty-set)))
    (let ((old-nodes (plist-get old-state :node-table))
          (nodes (plist-get candidate-state :node-table))
          (parents (plist-get candidate-state :parent-table))
          (ebox-incremental--buffer-render-state-override
           (cons buffer candidate-state))
          (ebox-incremental--candidate-state-for-slot-proof candidate-state)
          affected operations)
      (dolist (dirty dirty-set)
        (unless (eq (plist-get dirty :dirty-kind) 'metadata)
          (let ((node-id (plist-get dirty :node-id)) owner)
            (while node-id
              (when (or (ebox-layer-host-p
                         (ebox-runtime-index-get node-id nodes))
                        (ebox-layer-host-p
                         (ebox-runtime-index-get node-id old-nodes)))
                (setq owner node-id))
              (setq node-id (ebox-runtime-index-get node-id parents)))
            ;; Paint or layout on an ordinary ancestor of a layer also
            ;; requires fresh composition, rather than a blind paint patch.
            (unless owner
              (let ((node (ebox-runtime-index-get
                           (plist-get dirty :node-id) nodes)))
                (when (and node (ebox-layer-subtree-p node))
                  (setq owner (plist-get dirty :node-id)))))
            (push (if owner
                      (progn
                        (setq affected t)
                        (ebox--patch-op 'owner-rerender owner :dirty dirty
                                        :layer-recompose-p t))
                    (ebox-incremental--declarative-tentative-op buffer dirty))
                  operations))))
      ;; A visible root portal can cover or anchor to nodes outside its host.
      ;; Test both snapshots so revealing and hiding keep root composition,
      ;; while hidden portals do not widen unrelated local updates.
      (when (or affected
                (and operations (plist-get old-state :root-portals-p)))
        (if (or (and (plist-get old-state :root-portals-p)
                     (ebox-layer-visible-portals-p
                      (plist-get old-state :root-node)))
                (ebox-layer-visible-portals-p
                 (plist-get candidate-state :root-node)))
            (list (ebox--patch-op
                   'owner-rerender
                   (plist-get (plist-get candidate-state :root-node) :node-id)
                   :dirty (ebox--merge-dirty-provenance-list dirty-set)
                   :layer-recompose-p t))
          (ebox-patch-plan-merge-ops parents (nreverse operations)))))))

(defun ebox-incremental--content-independent-allocation-p (state owner-id)
  "Return non-nil when STATE allocates OWNER-ID independently of its content.
Intrinsic widths must render naturally so the final footprint check can detect
growth.  Automatic widths are retained only through normal flow/Column parents;
row, Flex and Grid allocation require their own formatting-context proofs."
  (let ((nodes (plist-get state :node-table))
        (parents (plist-get state :parent-table))
        (id owner-id)
        (valid (and (plist-get state :node-table)
                    (plist-get state :parent-table))))
    (while (and valid id)
      (let* ((node (ebox-runtime-index-get id nodes))
             (parent-id (ebox-runtime-index-get id parents))
             (parent (and parent-id (ebox-runtime-index-get parent-id nodes)))
             (width (ebox-get node :width)))
        (setq valid
              (and node
                   (cl-every
                    (lambda (value)
                      (or (memq value '(nil auto stretch none))
                          (numberp value) (ebox-size-value-p value)))
                    (list width (ebox-get node :min-width)
                          (ebox-get node :max-width)))
                   (or (not (memq width '(nil auto stretch)))
                       (and parent
                            (eq (ebox-tree-display-outer node) 'block)
                            (memq (ebox-tree-display-inner parent)
                                  '(flow column)))))
              id parent-id)))
    valid))

(defun ebox-incremental--layer-span-proof
    (buffer old-state prepared candidate-state owner-plan path-copied-p)
  "Prove the stable outer allocation of one recomposed layer owner.
Compare BUFFER's OLD-STATE with CANDIDATE-STATE using PREPARED dirty facts
and OWNER-PLAN.  PATH-COPIED-P requires private nodes inside that owner.
Internal visibility and role topology may change.  The surface validates the
complete replacement footprint before publishing any resulting spans.  Freeze
the retained margin-box width only when the owner's layout style is unchanged."
  (when (and (= (length owner-plan) 1)
             (plist-get (car owner-plan) :layer-recompose-p))
    (let* ((owner-id (plist-get (car owner-plan) :owner-id))
           (old-node (ebox-runtime-index-get
                      owner-id (plist-get old-state :node-table)))
           (node (ebox-runtime-index-get
                  owner-id (plist-get candidate-state :node-table)))
           (snapshot (ebox-incremental--cached-layout-snapshot-details
                      buffer owner-id))
           (spans (plist-get snapshot :buffer-spans))
           (allocated-width
            (plist-get (plist-get snapshot :external-footprint-signature)
                       :max-line-pixel-width))
           (ancestors (ebox-incremental--ancestor-slot-signature
                       buffer old-state candidate-state owner-id)))
      (when (and old-node node snapshot spans ancestors
                 (numberp allocated-width)
                 (equal (ebox-incremental--layout-slot-style-signature old-node)
                        (ebox-incremental--layout-slot-style-signature node))
                 (ebox-incremental--same-root-surface-identity-p
                  old-state candidate-state)
                 (ebox-incremental--span-patch-identity-stable-p
                  buffer old-state candidate-state prepared owner-id)
                 (or (not path-copied-p)
                     (not (ebox-incremental--candidate-shares-published-node-p
                           old-state node)))
                 (not (ebox--node-visible-overflow-p node))
                 (not (ebox--ancestor-own-overflow-visible-p buffer owner-id))
                 (with-current-buffer buffer
                   (or (ebox-buffer--partial-line-slots-p spans)
                       (ebox--spans-contiguous-lines-p spans))))
        (list :owner-id owner-id :snapshot snapshot
              :allocated-width
              (and (ebox-incremental--content-independent-allocation-p
                    candidate-state owner-id)
                   allocated-width)
              :dirty-set (plist-get prepared :dirty-set)
              :layer-recompose-p t :ancestor-slot-signature ancestors
              :layout-snapshot-detail-generation
              (plist-get old-state :layout-snapshot-detail-generation))))))

(defun ebox-incremental--cascade-root-owner-plan-p
    (old-state candidate-state dirty-set)
  "Return non-nil when cascade makes a local proof unusable.
OLD-STATE and CANDIDATE-STATE bound the style evidence for DIRTY-SET.  Dynamic
or changed cascade dependencies cannot use a local owner; a static binding
closure may still plan one for a later owner-scoped surface projection."
  (let* ((objects (plist-get old-state :surface-node-object-table))
         (style-states (plist-get old-state :style-binding-states))
         (missing-structure-style-p
          (and (hash-table-p objects) (hash-table-p style-states)
               (cl-some
                (lambda (entry)
                  (and (eq (plist-get entry :dirty-kind) 'structure)
                       (when-let* ((object
                                   (gethash (plist-get entry :node-id)
                                            objects)))
                         (null (gethash object style-states)))))
                dirty-set))))
    (or
     (/= (ebox-tree-author-style-count (plist-get old-state :root-node))
         (ebox-tree-author-style-count
          (plist-get candidate-state :root-node)))
     (and
      (or (plist-get old-state :cascade-active-p)
         (plist-get old-state :cascade-required-p)
         (ebox-style-cascade-active-p))
      (cl-some (lambda (entry)
                (not (eq (plist-get entry :dirty-kind) 'paint)))
              dirty-set)
      (or missing-structure-style-p
          (not
           (ebox-incremental--cascade-local-owner-proof-p
            old-state candidate-state dirty-set)))))))

(defun ebox-incremental--root-owner-plan (buffer dirty-set)
  "Return one conservative root owner operation for DIRTY-SET."
  (when-let* ((root-id (ebox--buffer-root-node-id buffer)))
    (list
     (ebox--patch-op
      'owner-rerender root-id
      :dirty (ebox--merge-dirty-provenance-list dirty-set)
      :proof-skipped-p t))))

(defun ebox-incremental--native-frame-plan (buffer dirty-set)
  "Return the bounded publication plan for a complete native frame."
  (when-let* ((root-id (ebox--buffer-root-node-id buffer)))
    (list
     (ebox--patch-op
      'native-frame root-id
      :dirty (ebox--merge-dirty-provenance-list dirty-set)
      :proof-skipped-p t))))

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
                (plist-get (ebox-runtime-index-get single-owner node-table) :ebox-type)
                :span-count
                (cl-loop for owner-id in owner-ids
                         for snapshot = (and snapshots
                                             (gethash owner-id snapshots))
                         sum (length (plist-get snapshot :buffer-spans)))
                :publication-scope 'layout-owners))))
    (ebox-incremental--commit-report prepared report candidate-state)))

(defun ebox-incremental--paint-projection-p
    (buffer old-state prepared candidate-state owner-plan)
  "Return non-nil when OWNER-PLAN can reuse OLD-STATE spatial topology.
BUFFER, PREPARED and CANDIDATE-STATE prove independence from retained scroll."
  (and owner-plan
       (not (plist-get prepared :scroll-state-transaction))
       (not (plist-get prepared :scroll-patch-fast-p))
       (cl-every (lambda (op) (eq (plist-get op :op) 'paint-patch))
                 owner-plan)
       (cl-every
        (lambda (op)
          (ebox-incremental--owner-disjoint-from-scroll-p
           buffer old-state prepared candidate-state (plist-get op :owner-id)))
        owner-plan)
       (cl-every
        (lambda (dirty)
          (cl-every (lambda (key)
                      (memq key ebox--paint-style-signature-keys))
                    (plist-get dirty :changed-keys)))
        (plist-get prepared :dirty-set))))

(defun ebox-incremental--hash-key-set-equal-p (left right)
  "Return non-nil when supported indexes LEFT and RIGHT have the same keys."
  (ebox-runtime-index-key-set-equal-p left right))

(defun ebox-incremental--span-patch-identity-stable-p
    (buffer old-state candidate-state prepared owner-id)
  "Return non-nil when a span patch preserves candidate identity topology.
The candidate index is already the proof boundary for source identity.  This
check verifies its observable sets and the copied path's parent slots before
the surface is allowed to reuse retained TP objects."
  (let* ((partitioned-p (plist-get prepared :partitioned-owner-proof-p))
         (old-node-table (plist-get old-state :node-table))
         (new-node-table (plist-get candidate-state :node-table))
         (old-parent-table (plist-get old-state :parent-table))
         (new-parent-table (plist-get candidate-state :parent-table))
         (touched
          (if partitioned-p
              (let ((walk owner-id)
                    (ids
                     (mapcar (lambda (dirty) (plist-get dirty :node-id))
                             (plist-get prepared :dirty-set))))
                (while walk
                  (push walk ids)
                  (setq walk (ebox-runtime-index-get walk old-parent-table)))
                (delete-dups ids))
            (delete-dups
             (append (plist-get prepared :touched-node-ids)
                     (list owner-id (ebox--buffer-root-node-id buffer)))))))
    (and (or partitioned-p
             (ebox-incremental--hash-key-set-equal-p
              old-node-table new-node-table))
         (or partitioned-p
             (ebox-incremental--hash-key-set-equal-p
              (plist-get old-state :region-id-set)
              (plist-get candidate-state :region-id-set)))
         (cl-every
          (lambda (node-id)
            (let ((old-node (ebox-runtime-index-get node-id old-node-table))
                  (new-node (ebox-runtime-index-get node-id new-node-table)))
              (and old-node new-node
                   (eq (plist-get old-node :ebox-type)
                       (plist-get new-node :ebox-type))
                   (equal
                    (ebox-tree-node-author-key
                     (plist-get old-state :source-index) old-node)
                    (ebox-tree-node-author-key
                     (plist-get candidate-state :source-index) new-node))
                   (equal (ebox-runtime-index-get node-id old-parent-table)
                          (ebox-runtime-index-get node-id new-parent-table)))))
          (delq nil touched)))))

(defun ebox-incremental--path-span-line-count-stable-p
    (buffer node spans)
  "Return non-nil when path-copied NODE keeps the published line count."
  (and (eq (plist-get node :ebox-type) 'box)
       (ebox--span-patch-definite-size-value-p (ebox-get node :width))
       (null (ebox-tree-node-children node))
       (= (length spans)
          (with-current-buffer buffer
            (length (ebox-string-lines (ebox--format-content node)))))))

(defun ebox-incremental--layout-slot-style-signature (node)
  "Return NODE's layout-significant style, excluding paint-only fields.
Paint changes are validated by the static cascade proof; they must not make
an otherwise unchanged allocated ancestor look geometrically unstable."
  (let ((signature (copy-sequence
                    (ebox-fragment-node-style-signature node))))
    (dolist (key ebox--paint-style-signature-keys)
      (cl-remf signature key))
    signature))

(defun ebox-incremental--cached-layout-snapshot-details (buffer node-id)
  "Return transaction-local detailed layout snapshot for NODE-ID."
  (let* ((key (cons 'snapshot node-id))
         (missing (make-symbol "ebox-snapshot-proof-missing"))
         (cached (and ebox-incremental--allocated-slot-proof-cache
                      (gethash key ebox-incremental--allocated-slot-proof-cache
                               missing))))
    (if (and cached (not (eq cached missing)))
        (unless (eq cached 'no-snapshot) cached)
      (let ((snapshot (ebox--ensure-layout-snapshot-details buffer node-id)))
        (when ebox-incremental--allocated-slot-proof-cache
          (puthash key (or snapshot 'no-snapshot)
                   ebox-incremental--allocated-slot-proof-cache))
        snapshot))))

(defun ebox-incremental--cached-allocation-snapshot (buffer node-id)
  "Return lightweight allocation evidence for NODE-ID in BUFFER.
This path intentionally omits role topology, overflow, and mount scans; the
final owner output validator still requests the complete snapshot.  Allocation
facts are written back to the published snapshot after they have been derived
from the current buffer.  They are ordinary derived state, not authority: the
snapshot generation check in `ebox--layout-snapshot' strips them whenever
coordinates are invalidated, and the final owner validator still recomputes
the complete proof."
  (let* ((key (cons 'allocation-snapshot node-id))
         (missing (make-symbol "ebox-allocation-snapshot-missing"))
         (cached (and ebox-incremental--allocated-slot-proof-cache
                      (gethash key ebox-incremental--allocated-slot-proof-cache
                               missing))))
    (if (and cached (not (eq cached missing)))
        (unless (eq cached 'no-snapshot) cached)
      (let* ((snapshot (ebox--ensure-layout-snapshot-spans buffer node-id))
             (spans (and snapshot (plist-get snapshot :buffer-spans)))
             (footprint nil)
             (external nil)
             (parent-slot nil)
             (allocation-shape nil)
             (generation
              (ebox--buffer-layout-snapshot-detail-generation buffer)))
        ;; A previous proof may already have materialized these facts.
        ;; Reusing them avoids rescanning every character on each owner path.
        (setq footprint
              (or (and snapshot
                       (plist-get snapshot :span-footprint-signature))
                  (and spans
                       (with-current-buffer buffer
                         (ebox--spans-span-footprint-signature spans)))))
        (setq external
              (or (and snapshot
                       (plist-get snapshot :external-footprint-signature))
                  (and footprint
                       (ebox--external-footprint-signature-from-span-footprint
                        footprint))))
        (setq parent-slot
              (or (and snapshot
                       (plist-get snapshot :parent-slot-signature))
                  (and spans
                       (with-current-buffer buffer
                         (ebox--spans-parent-slot-signature spans)))))
        (setq allocation-shape
              (and footprint
                   (list :span-count (plist-get footprint :span-count)
                         :whole-line-flags
                         (plist-get footprint :whole-line-flags)
                         :contiguous-lines
                         (plist-get footprint :contiguous-lines))))
        (let ((allocation
               (and footprint
                    (list :buffer-spans spans
                          :span-footprint-signature footprint
                          :external-footprint-signature external
                          :parent-slot-signature parent-slot
                          :allocation-shape allocation-shape
                          :detail-generation generation))))
          ;; Keep the allocation facts with the snapshot table so the next
          ;; logical turn can consume them without repeating the scan.  These
          ;; are derived facts only; publication authority stays unchanged.
          (when (and snapshot allocation
                     (or (null (plist-get snapshot
                                          :span-footprint-signature))
                         (null (plist-get snapshot
                                          :external-footprint-signature))
                         (null (plist-get snapshot
                                          :parent-slot-signature))
                         (null (plist-get snapshot :allocation-shape))
                         (not (= (or (plist-get snapshot
                                                 :detail-generation)
                                     -1)
                                 generation))))
            (let ((updated (copy-sequence snapshot)))
              (dolist (entry `((:span-footprint-signature . ,footprint)
                               (:external-footprint-signature . ,external)
                               (:parent-slot-signature . ,parent-slot)
                               (:allocation-shape . ,allocation-shape)
                               (:detail-generation . ,generation)))
                (setq updated (plist-put updated (car entry) (cdr entry))))
              (ebox--put-layout-snapshot buffer node-id updated)))
          (when ebox-incremental--allocated-slot-proof-cache
            (puthash key (or allocation 'no-snapshot)
                     ebox-incremental--allocated-slot-proof-cache))
          allocation)))))

(defun ebox-incremental--retained-ancestor-slot-signature
    (old-state candidate-state owner-id)
  "Return a still-valid published allocation certificate for OWNER-ID."
  (let* ((certificates
          (plist-get old-state :retained-allocation-certificates))
         (certificate
          (and (hash-table-p certificates)
               (gethash owner-id certificates)))
         (signature (and certificate (plist-get certificate :signature)))
         (old-nodes (plist-get old-state :node-table))
         (new-nodes (plist-get candidate-state :node-table))
         (old-parents (plist-get old-state :parent-table))
         (new-parents (plist-get candidate-state :parent-table))
         (old-source-index (plist-get old-state :source-index))
         (new-source-index (plist-get candidate-state :source-index))
         (entries signature)
         (valid (and signature
                     (equal (plist-get certificate :root-id)
                            (plist-get (plist-get old-state :root-node)
                                       :node-id))
                     (equal (plist-get certificate :root-id)
                            (plist-get (plist-get candidate-state :root-node)
                                       :node-id))
                     (equal (plist-get certificate :viewport-width)
                            (plist-get old-state :viewport-width))
                     (equal (plist-get certificate :viewport-height)
                            (plist-get old-state :viewport-height))
                     (equal (plist-get certificate :display-signature)
                            (plist-get old-state :display-signature))
                     (equal (plist-get old-state :display-signature)
                            (plist-get candidate-state :display-signature)))))
    (while (and valid entries)
      (let* ((entry (car entries))
             (node-id (plist-get entry :node-id))
             (next-id (and (cdr entries)
                           (plist-get (cadr entries) :node-id)))
             (old-node (and node-id (ebox-runtime-index-get node-id old-nodes)))
             (new-node (and node-id (ebox-runtime-index-get node-id new-nodes)))
             (old-parent (and node-id (ebox-runtime-index-get node-id old-parents)))
             (new-parent (and node-id (ebox-runtime-index-get node-id new-parents)))
             (allocated-style (plist-get entry :allocated-style)))
        (setq valid
              (and old-node new-node allocated-style
                   (equal old-parent new-parent)
                   (or (null next-id) (equal old-parent next-id))
                   (eq (plist-get old-node :ebox-type)
                       (plist-get new-node :ebox-type))
                   (equal (ebox-tree-node-key old-source-index old-node)
                          (ebox-tree-node-key new-source-index new-node))
                   ;; This certificate describes OWNER-ID's allocation in its
                   ;; parent, not the contents it allocates internally.  A
                   ;; Range owner is expected to replace its children while
                   ;; retaining that external slot; the final rendered-span
                   ;; validator still proves its exact published footprint.
                   ;; Ancestors above the owner must retain child topology
                   ;; because it defines the certified sibling allocation.
                   (or (equal node-id owner-id)
                       (ebox-incremental--node-child-ids-equal-p
                        old-node new-node))
                   (equal allocated-style
                          (ebox-incremental--layout-slot-style-signature
                           old-node))
                   (equal allocated-style
                          (ebox-incremental--layout-slot-style-signature
                           new-node))
                   (or (not (equal node-id owner-id))
                       (and (equal (ebox-get old-node :width)
                                   (ebox-get new-node :width))
                            (equal (ebox-get old-node :height)
                                   (ebox-get new-node :height)))))))
      (setq entries (cdr entries)))
    (and valid (copy-tree signature))))

(defun ebox-incremental--compute-ancestor-slot-signature
    (buffer old-state candidate-state owner-id)
  "Return stable allocated-slot evidence from OWNER-ID through the root.
Every retained ancestor must keep its parent edge and computed layout style.
Published snapshot footprints make the allocation proof independent of the
candidate's unrendered caches."
  (let ((old-nodes (plist-get old-state :node-table))
        (new-nodes (plist-get candidate-state :node-table))
        (old-parents (plist-get old-state :parent-table))
        (new-parents (plist-get candidate-state :parent-table))
        (generation (plist-get old-state :layout-snapshot-detail-generation))
        (node-id owner-id)
        signature valid)
    (setq valid t)
    (while (and valid node-id)
      (let* ((old-node (ebox-runtime-index-get node-id old-nodes))
             (new-node (ebox-runtime-index-get node-id new-nodes))
             (old-parent (ebox-runtime-index-get node-id old-parents))
             (new-parent (ebox-runtime-index-get node-id new-parents))
             (snapshot (and old-node
                            (ebox-incremental--cached-allocation-snapshot
                             buffer node-id)))
             (old-style (and old-node
                             (ebox-incremental--layout-slot-style-signature
                              old-node)))
             (new-style (and new-node
                             (ebox-incremental--layout-slot-style-signature
                              new-node))))
        (if (and old-node new-node snapshot
                 (equal old-parent new-parent)
                 (if (equal node-id owner-id)
                     (and (equal (ebox-get old-node :width)
                                 (ebox-get new-node :width))
                          (equal (ebox-get old-node :height)
                                 (ebox-get new-node :height)))
                   (equal old-style new-style))
                 (plist-get snapshot :span-footprint-signature)
                 (plist-get snapshot :external-footprint-signature)
                 (or (null old-parent)
                     (plist-get snapshot :parent-slot-signature)))
            (push (list :node-id node-id
                        :allocated-style old-style
                        :parent-slot-signature
                        (plist-get snapshot :parent-slot-signature)
                        :external-footprint-signature
                        (plist-get snapshot :external-footprint-signature)
                        :span-footprint-signature
                        (plist-get snapshot :span-footprint-signature)
                        :detail-generation generation)
                  signature)
          (setq valid nil))
        (setq node-id old-parent)))
    (and valid (nreverse signature))))

(defun ebox-incremental--ancestor-slot-signature
  (buffer old-state candidate-state owner-id)
  "Return candidate-local cached ancestor allocation evidence for OWNER-ID."
  (let* ((key (cons 'ancestor owner-id))
         (missing (make-symbol "ebox-ancestor-proof-missing"))
         (cached (and ebox-incremental--allocated-slot-proof-cache
                      (gethash key ebox-incremental--allocated-slot-proof-cache
                               missing))))
    (if (and cached (not (eq cached missing)))
        (unless (eq cached 'no-signature) cached)
      (let ((signature
             (or (ebox-incremental--retained-ancestor-slot-signature
                  old-state candidate-state owner-id)
                 (ebox-incremental--compute-ancestor-slot-signature
                  buffer old-state candidate-state owner-id))))
        (when ebox-incremental--allocated-slot-proof-cache
          (puthash key (or signature 'no-signature)
                   ebox-incremental--allocated-slot-proof-cache))
        signature))))

(defun ebox-incremental--stable-grid-track-p (track)
  "Return non-nil when TRACK is fixed or a positive fractional track."
  (or (ebox--span-patch-definite-size-value-p track)
      (and (proper-list-p track)
           (memq (plist-get track :kind) '(fixed fr))
           (let ((value (if (eq (plist-get track :kind) 'fixed)
                            (plist-get track :size)
                          (plist-get track :factor))))
             (if (eq (plist-get track :kind) 'fixed)
                 (ebox--span-patch-definite-size-value-p value)
               (and (numberp value) (> value 0)))))
      (and (symbolp track)
           (string-match-p
            "\\`[0-9]+\\(?:\\.[0-9]+\\)?fr\\'" (symbol-name track)))
      (and (consp track) (eq (car track) 'fr)
           (numberp (cadr track)) (> (cadr track) 0)
           (null (cddr track)))))

(defun ebox-incremental--fixed-grid-track-p (track)
  "Return non-nil when TRACK has a definite fixed size.
The fast variable-content proof deliberately excludes fractional tracks; their
allocation remains on the full ancestor-slot proof path."
  (or (ebox--span-patch-definite-size-value-p track)
      (and (proper-list-p track)
           (eq (plist-get track :kind) 'fixed)
           (ebox--span-patch-definite-size-value-p (plist-get track :size)))))

(defun ebox-incremental--compute-allocated-parent-slot-stable-p
    (buffer entry candidate-state)
  "Return non-nil when ENTRY keeps a fixed parent allocation in CANDIDATE-STATE.
This bounded proof accepts an auto-width one-line child only when its nearest
unchanged Grid ancestor uses fixed or positive fractional columns and the
complete published ancestor slot chain remains identical."
  (let* ((old-state (ebox-incremental--proof-base-state buffer))
         (node-id (plist-get entry :node-id))
         (old-node (and node-id
                        (ebox-runtime-index-get node-id (plist-get old-state :node-table))))
         (new-node (and node-id
                        (ebox-runtime-index-get node-id
                                 (plist-get candidate-state :node-table))))
         (parent-table (plist-get old-state :parent-table))
         (candidate-parents (plist-get candidate-state :parent-table))
         (ancestor-id (and node-id (ebox-runtime-index-get node-id parent-table)))
         grid-id old-grid new-grid)
    (while (and ancestor-id (not grid-id))
      (let ((old-ancestor
             (ebox-runtime-index-get ancestor-id (plist-get old-state :node-table)))
            (new-ancestor
             (ebox-runtime-index-get ancestor-id (plist-get candidate-state :node-table))))
        (if (and old-ancestor new-ancestor
                 (equal (ebox-runtime-index-get ancestor-id parent-table)
                        (ebox-runtime-index-get ancestor-id candidate-parents))
                 (eq (ebox-tree-display-inner old-ancestor) 'grid)
                 (eq (ebox-tree-display-inner new-ancestor) 'grid))
            (setq grid-id ancestor-id
                  old-grid old-ancestor
                  new-grid new-ancestor)
          (setq ancestor-id (ebox-runtime-index-get ancestor-id parent-table)))))
    (let* ((old-props (and old-grid (ebox-tree-layout-props old-grid)))
           (new-props (and new-grid (ebox-tree-layout-props new-grid)))
         (tracks (and old-props
                        (plist-get old-props :grid-template-columns)))
           (owner-snapshot
            (and old-node
                 (ebox-incremental--cached-allocation-snapshot
                  buffer node-id)))
           (old-content (plist-get (plist-get entry :old-signature) :content))
           (new-content (plist-get (plist-get entry :new-signature) :content)))
      (and old-state old-node new-node old-grid new-grid
         (memq :content (plist-get entry :changed-keys))
         (or (and (ebox--span-patch-definite-size-value-p
                   (ebox-get old-node :height))
                  (equal (ebox-get old-node :height)
                         (ebox-get new-node :height)))
             (and (equal (plist-get
                          (plist-get owner-snapshot
                                     :external-footprint-signature)
                          :block-lines)
                         1)
                  (stringp old-content) (stringp new-content)
                  (not (string-match-p "\n" old-content))
                  (not (string-match-p "\n" new-content))))
         (equal old-props new-props)
         (proper-list-p tracks)
         tracks
         (cl-every #'ebox-incremental--stable-grid-track-p tracks)
         (ebox-incremental--ancestor-slot-signature
          buffer old-state candidate-state node-id)))))

(defun ebox-incremental--compute-content-slot-stable
    (buffer entry candidate-state)
  "Return strict evidence that an auto-width content owner is local.
The owner may have no declared width when its nearest unchanged formatting
context has a stable allocated slot.  A column parent is safe when its own
layout facts and child topology are unchanged; a row parent is accepted only
for the final child, so changing that child's intrinsic width cannot shift a
following sibling.  Multiline content additionally requires a definite,
unchanged height in a normal Column slot.  The surface footprint validator
remains the final gate."
  (let* ((old-state (ebox-incremental--proof-base-state buffer))
         (node-id (plist-get entry :node-id))
         (old-node (and node-id
                        (ebox-runtime-index-get node-id (plist-get old-state :node-table))))
         (new-node (and node-id
                        (ebox-runtime-index-get node-id (plist-get candidate-state :node-table))))
         (parents (plist-get old-state :parent-table))
         (candidate-parents (plist-get candidate-state :parent-table))
         (parent-id (and node-id (ebox-runtime-index-get node-id parents)))
         (old-parent (and parent-id
                          (ebox-runtime-index-get parent-id (plist-get old-state :node-table))))
         (new-parent (and parent-id
                          (ebox-runtime-index-get parent-id (plist-get candidate-state :node-table))))
         (old-children (and old-parent (ebox-tree--children-raw old-parent)))
         (position (and old-children
                        (cl-position-if
                         (lambda (child)
                           (= node-id (plist-get child :node-id)))
                         old-children)))
         (parent-kind (and old-parent (ebox-tree-display-inner old-parent)))
         (snapshot (and old-node
                        (ebox-incremental--cached-allocation-snapshot
                         buffer node-id)))
         (old-content (plist-get (plist-get entry :old-signature) :content))
         (new-content (plist-get (plist-get entry :new-signature) :content))
         (ancestor-signature
          (and node-id
               (ebox-incremental--ancestor-slot-signature
                buffer old-state candidate-state node-id))))
    (and old-state old-node new-node old-parent new-parent
         (equal (ebox-runtime-index-get parent-id parents)
                (ebox-runtime-index-get parent-id candidate-parents))
         (ebox-incremental--node-child-ids-equal-p old-parent new-parent)
         (equal (ebox-incremental--layout-slot-style-signature old-parent)
                (ebox-incremental--layout-slot-style-signature new-parent))
         (equal (ebox-get old-parent :width) (ebox-get new-parent :width))
         (equal (ebox-get old-parent :height) (ebox-get new-parent :height))
         (memq parent-kind '(row column))
         (or (eq parent-kind 'column)
             (and (integerp position)
                  (= position (1- (length old-children)))
                  (not (ebox-get old-node :flex-grow))
                  (not (ebox-get old-node :flex-shrink))))
         (memq :content (plist-get entry :changed-keys))
         (stringp old-content) (stringp new-content)
         snapshot
         (or (and (not (string-match-p "\n" old-content))
                  (not (string-match-p "\n" new-content))
                  (equal (plist-get
                          (plist-get snapshot :external-footprint-signature)
                          :block-lines)
                         1))
             (and (ebox--span-patch-definite-size-value-p
                   (ebox-get old-node :height))
                  (equal (ebox-get old-node :height)
                         (ebox-get new-node :height))
                  (ebox-incremental--owner-slot-stable-p
                   buffer old-state candidate-state node-id)))
         ancestor-signature)))

(defun ebox-incremental--content-slot-stable-p
    (buffer entry candidate-state)
  "Return cached content-slot evidence for ENTRY."
  (if (not ebox-incremental--allocated-slot-proof-cache)
      (ebox-incremental--compute-content-slot-stable
       buffer entry candidate-state)
    (let* ((old-signature (plist-get entry :old-signature))
           (new-signature (plist-get entry :new-signature))
           (key (list 'content-slot (plist-get entry :node-id)
                      (plist-get entry :changed-keys)
                      (plist-get old-signature :content)
                      (plist-get new-signature :content)))
           (missing (make-symbol "ebox-content-slot-proof-missing"))
           (cached (gethash key ebox-incremental--allocated-slot-proof-cache
                            missing)))
      (if (not (eq cached missing))
          (unless (eq cached 'no-evidence) cached)
        (let ((evidence
               (ebox-incremental--compute-content-slot-stable
                buffer entry candidate-state)))
          (puthash key (or evidence 'no-evidence)
                   ebox-incremental--allocated-slot-proof-cache)
          evidence)))))

(defun ebox-incremental--owner-slot-stable-p
    (buffer old-state candidate-state owner-id)
  "Return OWNER-ID's retained parent-slot certificate, or nil.
The owner and its parent must retain identity, child topology, layout style,
and a normal Column allocation.  Candidate rendering remains responsible for
proving that changed descendants still fit this slot exactly."
  (let* ((old-nodes (plist-get old-state :node-table))
         (new-nodes (plist-get candidate-state :node-table))
         (old-parents (plist-get old-state :parent-table))
         (new-parents (plist-get candidate-state :parent-table))
         (old-node (and owner-id (ebox-runtime-index-get owner-id old-nodes)))
         (new-node (and owner-id (ebox-runtime-index-get owner-id new-nodes)))
         (parent-id (and owner-id (ebox-runtime-index-get owner-id old-parents)))
         (old-parent (and parent-id (ebox-runtime-index-get parent-id old-nodes)))
         (new-parent (and parent-id (ebox-runtime-index-get parent-id new-nodes)))
         (snapshot
          (and old-node
               (ebox-incremental--cached-allocation-snapshot
                buffer owner-id))))
    (and old-node new-node old-parent new-parent snapshot
         (equal parent-id (ebox-runtime-index-get owner-id new-parents))
         (eq (ebox-tree-display-inner old-parent) 'column)
         (eq (ebox-tree-display-inner new-parent) 'column)
         (ebox-incremental--node-child-ids-equal-p old-node new-node)
         (ebox-incremental--node-child-ids-equal-p old-parent new-parent)
         (equal (ebox-incremental--layout-slot-style-signature old-node)
                (ebox-incremental--layout-slot-style-signature new-node))
         (equal (ebox-incremental--layout-slot-style-signature old-parent)
                (ebox-incremental--layout-slot-style-signature new-parent))
         (not (ebox-tree-node-visible-overflow-p old-node))
         (not (ebox-tree-node-visible-overflow-p new-node))
         (ebox-incremental--ancestor-slot-signature
          buffer old-state candidate-state owner-id))))

(defun ebox-incremental--allocated-parent-slot-stable-p
    (buffer entry candidate-state)
  "Return cached allocated-slot evidence for ENTRY in CANDIDATE-STATE."
  (let* ((key (cons 'allocated (plist-get entry :node-id)))
         (missing (make-symbol "ebox-slot-proof-missing"))
         (cached (and ebox-incremental--allocated-slot-proof-cache
                      (gethash key ebox-incremental--allocated-slot-proof-cache
                               missing))))
    (if (and cached (not (eq cached missing)))
        (eq cached 'stable)
      (let ((stable
             (ebox-incremental--compute-allocated-parent-slot-stable-p
              buffer entry candidate-state)))
        (when ebox-incremental--allocated-slot-proof-cache
          (puthash key (if stable 'stable 'unstable)
                   ebox-incremental--allocated-slot-proof-cache))
        stable))))

(defun ebox-incremental--fixed-content-slot-stable-p
    (buffer entry candidate-state)
  "Return strict evidence for one-line content in a definite flex/row slot.
Unlike the auto-width row proof, a definite non-growing child cannot change
its parent's allocation when its glyph string changes.  Parent topology,
style, and the published ancestor slot chain remain mandatory."
  (let* ((old-state (ebox-incremental--proof-base-state buffer))
         (node-id (plist-get entry :node-id))
         (old-node (and node-id
                        (ebox-runtime-index-get node-id (plist-get old-state :node-table))))
         (new-node (and node-id
                        (ebox-runtime-index-get node-id (plist-get candidate-state
                                                    :node-table))))
         (parents (plist-get old-state :parent-table))
         (candidate-parents (plist-get candidate-state :parent-table))
         (parent-id (and node-id (ebox-runtime-index-get node-id parents)))
         (old-parent (and parent-id
                          (ebox-runtime-index-get parent-id (plist-get old-state :node-table))))
         (new-parent (and parent-id
                          (ebox-runtime-index-get parent-id
                                   (plist-get candidate-state :node-table))))
         (snapshot (and old-node
                        (ebox-incremental--cached-allocation-snapshot
                         buffer node-id)))
         (old-content (plist-get (plist-get entry :old-signature) :content))
         (new-content (plist-get (plist-get entry :new-signature) :content)))
    (and old-node new-node old-parent new-parent
         (eq (ebox-tree-display-inner old-parent)
             (ebox-tree-display-inner new-parent))
         (memq (ebox-tree-display-inner old-parent) '(row flex))
         (equal (ebox-runtime-index-get parent-id parents)
                (ebox-runtime-index-get parent-id candidate-parents))
         (ebox-incremental--node-child-ids-equal-p old-parent new-parent)
         (equal (ebox-incremental--layout-slot-style-signature old-parent)
                (ebox-incremental--layout-slot-style-signature new-parent))
         (ebox--span-patch-definite-size-value-p (ebox-get old-node :width))
         (equal (ebox-get old-node :width) (ebox-get new-node :width))
         (not (ebox-get old-node :flex-grow))
         (not (ebox-get old-node :flex-shrink))
         (memq :content (plist-get entry :changed-keys))
         (stringp old-content) (stringp new-content)
         (not (string-match-p "\n" old-content))
         (not (string-match-p "\n" new-content))
         snapshot
         (equal (plist-get
                 (plist-get snapshot :external-footprint-signature)
                 :block-lines)
                1)
         (ebox-incremental--ancestor-slot-signature
  buffer old-state candidate-state node-id))))

(defun ebox-incremental--stable-grid-ancestor-slot-proof-p
    (old-state candidate-state grid-id)
  "Return non-nil for a stable fractional GRID allocation context.
This proof is deliberately narrower than a general ancestor snapshot proof:
GRID must be nested below at least one unchanged normal-flow ancestor, every
ancestor above it must remain a column/box flow with the same layout style and
parent edge, and no ancestor may expose visible overflow.  Auto-sized
formatting contexts, row/flex/grid ancestors, and a root GRID continue through
the complete snapshot proof."
  (let* ((old-nodes (plist-get old-state :node-table))
         (new-nodes (plist-get candidate-state :node-table))
         (old-parents (plist-get old-state :parent-table))
         (new-parents (plist-get candidate-state :parent-table))
         (node-id (ebox-runtime-index-get grid-id old-parents))
         (seen nil)
         (valid (and node-id t)))
    (while (and valid node-id)
      (if (memq node-id seen)
          (setq valid nil)
        (push node-id seen)
        (let* ((old-node (ebox-runtime-index-get node-id old-nodes))
               (new-node (ebox-runtime-index-get node-id new-nodes))
               (old-parent (ebox-runtime-index-get node-id old-parents))
               (new-parent (ebox-runtime-index-get node-id new-parents))
               (display (and old-node
                             (ebox-tree-display-inner old-node)))
               (old-width (and old-node (ebox-get old-node :width)))
               (new-width (and new-node (ebox-get new-node :width))))
          (unless (and old-node new-node
                       (equal old-parent new-parent)
                       (equal (ebox-incremental--layout-slot-style-signature
                               old-node)
                              (ebox-incremental--layout-slot-style-signature
                               new-node))
                       (memq display '(column box flow))
                       (not (ebox-tree-node-visible-overflow-p old-node))
                       (not (ebox-tree-node-visible-overflow-p new-node))
                       ;; A normal-flow column/box may inherit its width from
                       ;; its stable parent.  Intrinsic width keywords are not
                       ;; allocation certificates and remain conservative.
                       (equal old-width new-width)
                       (not (memq old-width '(max-content min-content
                                               fit-content auto))))
            (setq valid nil))
          (setq node-id old-parent))))
    valid))

(defun ebox-incremental--compute-fast-grid-slot-evidence
    (buffer entry candidate-state)
  "Return minimal stable Grid-slot evidence for one variable owner.
This intentionally stops at the nearest unchanged Grid instead of rebuilding
every ancestor snapshot.  The full proof remains available for all other
projection kinds and the surface output validator remains authoritative."
  (let* ((old-state (ebox-incremental--proof-base-state buffer))
         (node-id (plist-get entry :node-id))
         (old-node (and node-id
                        (ebox-runtime-index-get node-id (plist-get old-state :node-table))))
         (new-node (and node-id
                        (ebox-runtime-index-get node-id
                                 (plist-get candidate-state :node-table))))
         (parents (plist-get old-state :parent-table))
         (candidate-parents (plist-get candidate-state :parent-table))
         (ancestor-id (and node-id (ebox-runtime-index-get node-id parents)))
         (child-id node-id)
         grid-id old-grid new-grid)
    (while (and ancestor-id (not grid-id))
      (let* ((old-ancestor (ebox-runtime-index-get ancestor-id
                                    (plist-get old-state :node-table)))
             (new-ancestor (ebox-runtime-index-get ancestor-id
                                    (plist-get candidate-state :node-table)))
             (parent-id (ebox-runtime-index-get ancestor-id parents))
             (new-parent-id (ebox-runtime-index-get ancestor-id candidate-parents)))
        (if (and old-ancestor new-ancestor
                 (equal parent-id new-parent-id)
                 (not (ebox-tree-node-visible-overflow-p old-ancestor)))
            (pcase (ebox-tree-display-inner old-ancestor)
              ('grid
               (setq grid-id ancestor-id
                     old-grid old-ancestor
                     new-grid new-ancestor))
              ('flex
               (let* ((children (ebox-tree--children-raw old-ancestor))
                      (last-child (car (last children)))
                      (props (plist-get old-ancestor :props)))
                 (if (and last-child
                          (= child-id (plist-get last-child :node-id))
                          (eq (plist-get props :flex-wrap) 'nowrap)
                          (not (ebox-get last-child :flex-grow))
                          (not (ebox-get last-child :flex-shrink))
                          (equal (ebox-incremental--layout-slot-style-signature
                                  old-ancestor)
                                 (ebox-incremental--layout-slot-style-signature
                                  new-ancestor)))
                     (setq grid-id ancestor-id
                           old-grid old-ancestor
                           new-grid new-ancestor
                           ancestor-id nil)
                   (setq ancestor-id nil))))
              (_
               (setq child-id ancestor-id
                     ancestor-id parent-id)))
          (setq ancestor-id nil))))
    (let* ((old-props (and old-grid (ebox-tree-layout-props old-grid)))
           (new-props (and new-grid (ebox-tree-layout-props new-grid)))
           (context-kind (and old-grid (ebox-tree-display-inner old-grid)))
           (tracks (and old-props
                        (plist-get old-props :grid-template-columns)))
           (snapshot (and old-node
                          (ebox-incremental--cached-allocation-snapshot
                           buffer node-id)))
           (grid-snapshot (and grid-id
                               (ebox-incremental--cached-allocation-snapshot
                                buffer grid-id)))
           (old-content
            (plist-get (plist-get entry :old-signature) :content))
           (new-content
            (plist-get (plist-get entry :new-signature) :content)))
      (when (and old-node new-node old-grid new-grid
                 (equal old-props new-props)
                 (or (eq context-kind 'flex)
                     (and (eq context-kind 'grid)
                          (proper-list-p tracks) tracks
                          (cl-every #'ebox-incremental--stable-grid-track-p
                                    tracks)))
                 snapshot grid-snapshot
                 (= 1 (plist-get
                       (plist-get snapshot :external-footprint-signature)
                       :block-lines))
                 (stringp old-content) (stringp new-content)
                 (not (string-match-p "\n" old-content))
                 (not (string-match-p "\n" new-content)))
        (list :owner-id node-id :grid-id grid-id
              :needs-full-ancestor-proof
              (and (eq context-kind 'grid)
                   (not (cl-every #'ebox-incremental--fixed-grid-track-p
                                  tracks))
                   (not (ebox-incremental--stable-grid-ancestor-slot-proof-p
                         old-state candidate-state grid-id)))
              :grid-snapshot grid-snapshot
              :owner-snapshot snapshot)))))

(defun ebox-incremental--fast-grid-slot-evidence
    (buffer entry candidate-state)
  "Return cached minimal Grid-slot evidence for ENTRY in CANDIDATE-STATE."
  (if (not ebox-incremental--allocated-slot-proof-cache)
      (ebox-incremental--compute-fast-grid-slot-evidence
       buffer entry candidate-state)
    (let* ((old-signature (plist-get entry :old-signature))
           (new-signature (plist-get entry :new-signature))
           (key (list 'fast-grid (plist-get entry :node-id)
                      (plist-get entry :changed-keys)
                      (plist-get old-signature :content)
                      (plist-get new-signature :content)))
           (missing (make-symbol "ebox-fast-grid-proof-missing"))
           (cached (gethash key ebox-incremental--allocated-slot-proof-cache
                            missing)))
      (if (not (eq cached missing))
          (unless (eq cached 'no-evidence) cached)
        (let ((evidence
               (ebox-incremental--compute-fast-grid-slot-evidence
                buffer entry candidate-state)))
          (puthash key (or evidence 'no-evidence)
                   ebox-incremental--allocated-slot-proof-cache)
          evidence)))))

(defun ebox-incremental--variable-content-fits-slot-p
    (snapshot content)
  "Return non-nil when one-line CONTENT fits the retained owner slot.
This is a conservative pre-render guard for variable-content span patches;
the surface renderer and role/overflow validators remain the final proof."
  (let ((slots (plist-get (plist-get snapshot :parent-slot-signature)
                          :slots)))
    (and (stringp content)
         (not (string-match-p "\n" content))
         slots
         (<= (ebox--string-pixel-width content)
             (apply #'min
                    (mapcar (lambda (slot)
                              (- (plist-get slot :end-pixel)
                                 (plist-get slot :start-pixel)))
                            slots))))))

(defun ebox-incremental--owner-disjoint-from-scroll-p
    (buffer old-state prepared candidate-state owner-id)
  "Return non-nil when OWNER-ID cannot change any retained scroll content.
The active scroll set and each scroll box identity must survive preparation.
An ancestor or descendant scroll box still requires the ordinary renderer to
regenerate its cached lines; only separate branches may keep those lines."
  (let* ((regions (plist-get old-state :scroll-region-ids))
         (next-table (plist-get prepared :scroll-state-table)))
    (and (= (length regions)
            (if (hash-table-p next-table) (hash-table-count next-table) 0))
         (cl-every
          (lambda (region)
            (let* ((old-scroll (gethash region ebox--scroll-global-state))
                   (next-scroll (and next-table (gethash region next-table)))
                   (old-box (plist-get old-scroll :box))
                   (next-box (plist-get next-scroll :box))
                   (scroll-id (plist-get old-box :node-id)))
              (and scroll-id next-box
                   (eq (plist-get old-scroll :buffer) buffer)
                   (equal scroll-id (plist-get next-box :node-id))
                   (eq old-box (ebox-runtime-index-get scroll-id (plist-get old-state :node-table)))
                   (eq old-box (gethash region (plist-get old-state :region-box-table)))
                   (eq next-box (ebox-runtime-index-get scroll-id (plist-get candidate-state :node-table)))
                   (eq next-box (gethash region (plist-get candidate-state :region-box-table)))
                   (not (equal scroll-id owner-id))
                   (let ((ebox-incremental--buffer-render-state-override
                          (cons buffer old-state)))
                     (and (not (ebox--runtime-ancestor-id-p buffer scroll-id owner-id))
                          (not (ebox--runtime-ancestor-id-p buffer owner-id scroll-id))))
                   (let ((ebox-incremental--buffer-render-state-override
                          (cons buffer candidate-state)))
                     (and (not (ebox--runtime-ancestor-id-p buffer scroll-id owner-id))
                          (not (ebox--runtime-ancestor-id-p buffer owner-id scroll-id)))))))
          regions))))

(defun ebox-incremental--single-span-patch-projection-proof
    (buffer old-state prepared candidate-state owner-plan
             &optional path-copied-p)
  "Return strict span projection metadata, or nil when it is unsafe.
This first slice deliberately accepts only one fixed-footprint content owner.
The surface still performs the output and text-property proof before using the
metadata; this predicate only authorizes the local attempt."
  (when (and (= (length owner-plan) 1)
             (= (length (plist-get prepared :dirty-set)) 1))
    (let* ((operation (car owner-plan))
           (dirty (car (plist-get prepared :dirty-set)))
           (owner-id (plist-get operation :owner-id))
           (changed-keys (plist-get dirty :changed-keys))
           (old-node (ebox-runtime-index-get owner-id (plist-get old-state :node-table)))
           (new-node (ebox-runtime-index-get owner-id (plist-get candidate-state :node-table)))
           (slot-dirty
            (plist-put (copy-sequence dirty) :node-id owner-id))
           (snapshot
            (and old-node
                 (ebox-incremental--cached-layout-snapshot-details
                  buffer owner-id)))
           (variable-grid-evidence
            (and (memq :content changed-keys)
                 (ebox-incremental--fast-grid-slot-evidence
                  buffer slot-dirty candidate-state)))
           (fixed-content-evidence
            (and (memq :content changed-keys)
                 (ebox-incremental--fixed-content-slot-stable-p
                  buffer slot-dirty candidate-state)))
           (content-slot-evidence
            (and (memq :content changed-keys)
                 (ebox-incremental--content-slot-stable-p
                  buffer slot-dirty candidate-state)))
           (allocated-content-box-p
            (and content-slot-evidence
                 (eq (plist-get old-node :ebox-kind) 'box)
                 (ebox-incremental--content-independent-allocation-p
                  candidate-state owner-id)))
           (local-typography-p
            (and (not (memq :content changed-keys))
                 (cl-some
                  (lambda (key)
                    (memq key ebox--typography-style-signature-keys))
                  changed-keys)
                 (cl-every
                  (lambda (key)
                    (or (memq key ebox--paint-style-signature-keys)
                        (memq key ebox--typography-style-signature-keys)))
                  changed-keys)))
           (fixed-flex-evidence
            (and (memq :content changed-keys)
                 (ebox--flex-item-fixed-basis-content-allocation-stable-p
                  buffer owner-id)))
           (spans (and snapshot (plist-get snapshot :buffer-spans)))
           (impact-vector
            (let ((ebox-incremental--candidate-state-for-slot-proof
                   candidate-state))
              (plist-get
               (ebox--dirty-entry-with-impact-vector buffer dirty)
               :impact-vector)))
           (ancestor-slot-signature
            (if (and variable-grid-evidence
                     (not (plist-get variable-grid-evidence
                                     :needs-full-ancestor-proof)))
                (list (list :node-id owner-id
                            :variable-grid-id
                            (plist-get variable-grid-evidence :grid-id)
                            :parent-slot-signature
                            (plist-get snapshot :parent-slot-signature)
                            :external-footprint-signature
                            (plist-get snapshot
                                       :external-footprint-signature)
                            :span-footprint-signature
                            (plist-get snapshot :span-footprint-signature)
                            :detail-generation
                            (plist-get old-state
                                       :layout-snapshot-detail-generation)))
              (or content-slot-evidence
                  (ebox-incremental--ancestor-slot-signature
                   buffer old-state candidate-state owner-id))))
           (allocated-width
            (let* ((owner-slot
                    (if (and content-slot-evidence
                             (eq (plist-get old-node :ebox-kind) 'text))
                        (or (cadr content-slot-evidence)
                            (car content-slot-evidence))
                      (car ancestor-slot-signature)))
                   (slots (plist-get
                           (plist-get owner-slot :parent-slot-signature)
                           :slots))
                   (widths
                    (mapcar
                     (lambda (slot)
                       (- (plist-get slot :end-pixel)
                          (plist-get slot :start-pixel)))
                     slots)))
              (and widths (apply #'min widths)))))
      (when (and (or (eq (plist-get operation :op) 'span-patch)
                     (and (eq (plist-get operation :op) 'owner-rerender)
                          (or local-typography-p
                              (and (memq :content changed-keys)
                                   variable-grid-evidence))))
                 (eq (plist-get dirty :dirty-kind) 'geometry)
                 ;; A declarative content update may also carry paint keys
                 ;; (for example a stylesheet-computed :color) in the dirty
                 ;; signature.  The static cascade proof below establishes
                 ;; that those extra keys cannot affect geometry.  Other
                 ;; local style keys remain on their existing conservative
                 ;; path.
                 (or (memq :content changed-keys) local-typography-p)
                 (cl-every
                  (lambda (key)
                    (or (eq key :content)
                        (eq key :surface-properties)
                        (memq key ebox--paint-style-signature-keys)
                        (memq key ebox--typography-style-signature-keys)))
                  changed-keys)
                 (not (plist-get dirty :children))
                 (null (plist-get dirty :node-ids))
                 (or local-typography-p
                     (not (memq 'parent-layout impact-vector))
                     content-slot-evidence
                     fixed-content-evidence
                     fixed-flex-evidence
                     variable-grid-evidence
                     (ebox-incremental--allocated-parent-slot-stable-p
                      buffer slot-dirty candidate-state))
                 ancestor-slot-signature
                 (or (and (not (plist-get old-state :cascade-active-p))
                          (not (plist-get old-state :cascade-required-p))
                          (not (ebox-style-cascade-active-p)))
                     (and (or (memq :content changed-keys)
                              local-typography-p)
                          (ebox-incremental--cascade-local-owner-proof-p
                           old-state candidate-state (list dirty))))
                 (ebox-incremental--owner-disjoint-from-scroll-p
                  buffer old-state prepared candidate-state owner-id)
                 ;; An allocated Box owns its changing line filler.  Other
                 ;; owners beside retained scroll content still need an exact
                 ;; raw extent, because ancestor filler can lie outside their
                 ;; local spans.  Scroll dependency/binding proof above and
                 ;; final slot validation remain mandatory in both cases.
                 (or (null (plist-get old-state :scroll-region-ids))
                     allocated-content-box-p
                     (let ((before (plist-get (plist-get dirty :old-signature)
                                             :content))
                           (after (plist-get (plist-get dirty :new-signature)
                                            :content)))
                       (and (stringp before) (stringp after)
                            (not (cl-intersection
                                  changed-keys ebox--typography-style-signature-keys))
                            (= (length before) (length after))
                            (= (ebox--string-pixel-width before)
                               (ebox--string-pixel-width after)))))
                 ;; The ancestor allocation proof is tied to the published
                 ;; viewport slot.  A declarative commit does not alter that
                 ;; context; final footprint validation still rejects a miss.
                 old-node new-node
                 (eq (plist-get old-node :ebox-type)
                     (plist-get new-node :ebox-type))
                 (equal
                  (ebox-tree-node-author-key
                   (plist-get old-state :source-index) old-node)
                  (ebox-tree-node-author-key
                   (plist-get candidate-state :source-index) new-node))
                 (ebox-incremental--node-child-ids-equal-p
                  old-node new-node)
                 (or local-typography-p
                     (equal (ebox-incremental--layout-slot-style-signature
                             old-node)
                            (ebox-incremental--layout-slot-style-signature
                             new-node)))
                 (ebox-incremental--same-root-surface-identity-p
                  old-state candidate-state)
                 (ebox-incremental--span-patch-identity-stable-p
                  buffer old-state candidate-state prepared owner-id)
                 (ebox--layout-snapshot-detailed-p snapshot)
                 spans
                 (or local-typography-p
                     (not path-copied-p)
                     ;; A copied owner subtree has the same mutation
                     ;; isolation as the ordinary full-copy candidate.
                     ;; Its shared siblings are outside this render, and
                     ;; the final slot footprint still proves geometry.
                     (not (ebox-incremental--candidate-shares-published-node-p
                           old-state new-node))
                     (ebox-incremental--path-span-line-count-stable-p
                     buffer new-node spans)
                     content-slot-evidence
                     fixed-flex-evidence
                     variable-grid-evidence
                     (ebox-incremental--allocated-parent-slot-stable-p
                      buffer slot-dirty candidate-state))
                 (plist-get snapshot :span-footprint-signature)
                 (plist-get snapshot :external-footprint-signature)
                 (plist-get snapshot :parent-slot-signature)
                 (plist-get snapshot :role-topology-signature)
                 (plist-get snapshot :overflow-signature)
                 ;; Partial row slots are disjoint by design; the backend
                 ;; shapes each slot independently before the replacement.
                 (with-current-buffer buffer
                   (or (ebox-buffer--partial-line-slots-p spans)
                       (ebox--spans-contiguous-lines-p spans)))
                 (not (ebox--node-visible-overflow-p old-node))
                 (not (ebox--ancestor-own-overflow-visible-p buffer owner-id)))
        (list :owner-id owner-id :dirty-set (list dirty)
              :snapshot snapshot
              :ancestor-slot-signature ancestor-slot-signature
              :variable-content-p
              (and snapshot
                   ;; Only a content-independent Box owns all filler affected
                   ;; by its changing text beside retained scroll siblings.
                   (or (null (plist-get old-state :scroll-region-ids))
                       allocated-content-box-p)
                   (memq :content changed-keys)
                   (stringp
                    (plist-get (plist-get dirty :new-signature) :content))
                   (not (string-match-p
                         "\n"
                         (plist-get (plist-get dirty :new-signature)
                                    :content)))
                   (or variable-grid-evidence fixed-content-evidence
                       fixed-flex-evidence content-slot-evidence))
              :variable-content-max-width
              (or (and content-slot-evidence allocated-width)
                  (and snapshot
                       (plist-get
                        (plist-get snapshot :external-footprint-signature)
                        :max-line-pixel-width)))
              :allocated-width allocated-width
              :layout-snapshot-detail-generation
              (plist-get old-state :layout-snapshot-detail-generation)
              :static-cascade-p
              (and (or (memq :content changed-keys) local-typography-p)
                   (or (plist-get old-state :cascade-active-p)
                       (plist-get old-state :cascade-required-p))
                   (ebox-incremental--cascade-local-owner-proof-p
                    old-state candidate-state (list dirty))))))))

(defun ebox-incremental--owner-proofs-disjoint-p (buffer proofs)
  "Return non-nil when PROOFS own pairwise-disjoint published spans."
  (let ((spans
         (sort
          (cl-mapcan
           (lambda (proof)
             (copy-sequence
              (plist-get
               (ebox-incremental--cached-layout-snapshot-details
                buffer (plist-get proof :owner-id))
               :buffer-spans)))
           proofs)
          (lambda (left right) (< (car left) (car right)))))
        valid previous-end)
    (setq valid t)
    (dolist (span spans)
      (when (and previous-end (< (car span) previous-end))
        (setq valid nil))
      (setq previous-end (cdr span)))
    valid))

(defun ebox-incremental--variable-span-proofs-safe-p
    (_buffer proofs)
  "Return non-nil when every variable owner fits its retained slot capacity."
  (let (valid)
    (setq valid t)
    (dolist (proof proofs)
      (when (and valid (plist-get proof :variable-content-p))
        (let ((snapshot (plist-get proof :snapshot))
              (allocated-width (plist-get proof :allocated-width)))
          (dolist (dirty (plist-get proof :dirty-set))
            (when valid
              (let ((content (plist-get (plist-get dirty :new-signature)
                                        :content)))
                (when (and (stringp content)
                           (not
                            (if (and (numberp allocated-width)
                                     (not (string-match-p "\n" content)))
                                (<= (ebox--string-pixel-width content)
                                    allocated-width)
                              (ebox-incremental--variable-content-fits-slot-p
                               snapshot content))))
                  (setq valid nil))))))))
    valid))

(defun ebox-incremental--grouped-owner-span-proof
    (buffer old-state prepared candidate-state owner-plan)
  "Return a single-owner proof for grouped descendants in one stable slot.

The layout owner plan may supply either a content-independent fixed Flex basis
or a retained content-slot certificate.  The surface still renders the whole
candidate owner into its published slot and verifies exact footprint, overflow,
role, and outside-complement compatibility before publication."
  (when (and (= (length owner-plan) 1)
             (or (> (length (plist-get prepared :dirty-set)) 1)
                 ;; A single leaf may need its allocator's filler to change.
                 ;; Only a proper, content-independent Flex ancestor closes
                 ;; that envelope; the ordinary leaf proof stays stricter.
                 (and (= (length (plist-get prepared :dirty-set)) 1)
                      (not (equal
                            (plist-get (car owner-plan) :owner-id)
                            (plist-get (car (plist-get prepared :dirty-set))
                                       :node-id)))
                      (ebox--flex-item-fixed-basis-content-allocation-stable-p
                       buffer (plist-get (car owner-plan) :owner-id)))))
    (let* ((operation (car owner-plan))
           (owner-id (plist-get operation :owner-id))
           (dirty-set (plist-get prepared :dirty-set))
           (root-id (ebox--buffer-root-node-id buffer))
           (old-node (ebox-runtime-index-get owner-id (plist-get old-state :node-table)))
           (new-node (ebox-runtime-index-get owner-id
                              (plist-get candidate-state :node-table)))
           (fixed-flex-slot-p
            (ebox--flex-item-fixed-basis-content-allocation-stable-p
             buffer owner-id))
           (snapshot
            (and old-node
                 (if fixed-flex-slot-p
                     (ebox-incremental--cached-allocation-snapshot
                      buffer owner-id)
                   (ebox-incremental--cached-layout-snapshot-details
                    buffer owner-id))))
           (changed-keys
            (delete-dups
             (cl-mapcan
              (lambda (entry)
                (copy-sequence (plist-get entry :changed-keys)))
              dirty-set)))
           (fixed-flex-ancestor-proof
            (and fixed-flex-slot-p
                 (ebox-incremental--ancestor-slot-signature
                  buffer old-state candidate-state owner-id)))
           (owner-slot-proof
            (and (not fixed-flex-ancestor-proof)
                 (ebox-incremental--owner-slot-stable-p
                  buffer old-state candidate-state owner-id)))
           ;; A grouped patch publishes the owner as one unit.  Its retained
           ;; external allocation is therefore the canonical certificate;
           ;; probing each changed leaf repeats the same ancestor walk and
           ;; produces a certificate for an identity that is not published as
           ;; the group owner.  Leaf evidence is only the fallback when the
           ;; owner has no retained slot certificate yet.
           (content-slot-proof
            (and (not owner-slot-proof)
                 (not fixed-flex-ancestor-proof)
                 (cl-loop
                  for entry in dirty-set
                  for proof = (and (memq :content
                                         (plist-get entry :changed-keys))
                                   (ebox-incremental--content-slot-stable-p
                                    buffer entry candidate-state))
                  when proof return proof)))
           (allocation-stable-p
            (or owner-slot-proof fixed-flex-ancestor-proof
                content-slot-proof))
           (ancestor-slot-signature
            (or owner-slot-proof fixed-flex-ancestor-proof content-slot-proof
                (and snapshot
                     (list (list :node-id owner-id
                                 :parent-slot-signature
                                 (plist-get snapshot
                                            :parent-slot-signature))))))
           (allocated-width
            (or
             (when-let* ((capacity-proof
                         (or owner-slot-proof fixed-flex-ancestor-proof
                             content-slot-proof))
                         (slot-owner
                          (or (cadr capacity-proof)
                              (car capacity-proof)))
                         (slots
                          (plist-get
                           (plist-get slot-owner :parent-slot-signature)
                           :slots)))
               (apply #'min
                      (mapcar
                       (lambda (slot)
                         (- (plist-get slot :end-pixel)
                            (plist-get slot :start-pixel)))
                       slots)))
             (and snapshot
                  (plist-get
                   (plist-get snapshot :external-footprint-signature)
                   :max-line-pixel-width))))
           (cascade-safe-p
            (or (and (not (plist-get old-state :cascade-active-p))
                     (not (plist-get old-state :cascade-required-p))
                     (not (ebox-style-cascade-active-p)))
                (ebox-incremental--cascade-local-owner-proof-p
                 old-state candidate-state dirty-set))))
      (let ((ebox-incremental--buffer-render-state-override
             (cons buffer candidate-state))
            (ebox-incremental--candidate-base-state
             (cons buffer old-state)))
        (when (and owner-id old-node new-node snapshot allocated-width
                   (not (equal owner-id root-id))
                   (memq (plist-get operation :op)
                         '(span-patch owner-rerender))
                   (cl-every
                    (lambda (entry)
                      (and (eq (plist-get entry :dirty-kind) 'geometry)
                           (not (plist-get entry :children))
                           (ebox--runtime-ancestor-id-p
                            buffer owner-id (plist-get entry :node-id))
                           (cl-every
                            (lambda (key)
                              (or (eq key :content)
                                  (eq key :surface-properties)
                                  (memq key ebox--paint-style-signature-keys)
                                  (memq key
                                        ebox--typography-style-signature-keys)
                                  (memq key '(:font-family :font-size
                                              :font-weight :font-style))))
                            (plist-get entry :changed-keys))))
                    dirty-set)
                   allocation-stable-p
                   ;; Fixed-basis allocation is content-independent on the
                   ;; flex main axis.  The surface performs the one canonical
                   ;; candidate render and exact old-slot footprint check, so
                   ;; a second proof render here would only duplicate work.
                   (or owner-slot-proof fixed-flex-ancestor-proof
                       content-slot-proof)
                   (equal (ebox-runtime-index-get owner-id
                                   (plist-get old-state :parent-table))
                          (ebox-runtime-index-get owner-id
                                   (plist-get candidate-state :parent-table)))
                   (ebox-incremental--node-child-ids-equal-p
                    old-node new-node)
                   (equal (ebox-incremental--layout-slot-style-signature
                           old-node)
                          (ebox-incremental--layout-slot-style-signature
                           new-node))
                   (ebox-incremental--same-root-surface-identity-p
                    old-state candidate-state)
                   (ebox-incremental--owner-disjoint-from-scroll-p
                    buffer old-state prepared candidate-state owner-id)
                   (not (ebox--node-visible-overflow-p old-node))
                   (not (ebox--node-visible-overflow-p new-node))
                   ancestor-slot-signature
                   cascade-safe-p)
          (let* ((owner-proof
                  (list :owner-id owner-id
                        :dirty-set (copy-sequence dirty-set)
                        :changed-keys (copy-sequence changed-keys)
                        :snapshot snapshot
                        :allocated-width allocated-width
                        :variable-content-p
                        (and (null (plist-get old-state :scroll-region-ids))
                             allocated-width
                             (cl-some
                              (lambda (entry)
                                (memq :content
                                      (plist-get entry :changed-keys)))
                              dirty-set))
                        :variable-content-max-width allocated-width
                        :role-owned-lines-p t
                        :retain-external-owner-suffix-p t
                        :ancestor-slot-signature ancestor-slot-signature
                        :layout-snapshot-detail-generation
                        (plist-get old-state
                                   :layout-snapshot-detail-generation)
                        :static-cascade-p cascade-safe-p))
                 (owner-proofs (list owner-proof)))
            (list :owner-ids (list owner-id)
                  :owner-proofs owner-proofs
                  :dirty-set (copy-sequence dirty-set)
                  :ancestor-slot-signature
                  (copy-sequence
                   (plist-get owner-proof :ancestor-slot-signature))
                  :layout-snapshot-detail-generation
                  (plist-get old-state :layout-snapshot-detail-generation)
                  :static-cascade-p cascade-safe-p)))))))

(defun ebox-incremental--range-span-proof
    (buffer old-state prepared candidate-state owner-plan)
  "Return a strict equal-cardinality Range replacement proof, or nil."
  (when (and (= (length owner-plan) 1)
             (= (length (plist-get prepared :dirty-set)) 1))
    (let* ((operation (car owner-plan))
           (dirty (car (plist-get prepared :dirty-set)))
           (delta (plist-get dirty :range-delta))
           (owner-id (plist-get operation :owner-id))
           (old-node (ebox-runtime-index-get owner-id (plist-get old-state :node-table)))
           (new-node (ebox-runtime-index-get owner-id
                              (plist-get candidate-state :node-table)))
           (old-items (and delta (apply #'append
                                       (plist-get delta :old-payloads))))
           (new-items (and delta (apply #'append
                                       (plist-get delta :new-payloads))))
           (snapshot
            (and old-node
                 (ebox-incremental--cached-layout-snapshot-details
                  buffer owner-id)))
           (spans (and snapshot (plist-get snapshot :buffer-spans)))
           (ancestor-slot-signature
            (and owner-id
                 (ebox-incremental--ancestor-slot-signature
                  buffer old-state candidate-state owner-id)))
           (cascade-safe-p
            (or (and (not (plist-get old-state :cascade-active-p))
                     (not (plist-get old-state :cascade-required-p))
                     (not (ebox-style-cascade-active-p)))
                (ebox-incremental--cascade-local-owner-proof-p
                 old-state candidate-state (list dirty)))))
      (when (and delta old-node new-node snapshot spans ancestor-slot-signature
                 (eq (plist-get operation :op) 'span-patch)
                 (eq (plist-get dirty :dirty-kind) 'structure)
                 (equal (plist-get dirty :changed-keys) '(:children))
                 old-items new-items
                 (= (length old-items) (length new-items))
                 (= (length spans) (length old-items))
                 (cl-every (lambda (item)
                             (eq (plist-get item :ebox-kind) 'box))
                           new-items)
                 (equal (ebox-runtime-index-get owner-id (plist-get old-state :parent-table))
                        (ebox-runtime-index-get owner-id
                                 (plist-get candidate-state :parent-table)))
                 (equal (ebox-incremental--layout-slot-style-signature old-node)
                        (ebox-incremental--layout-slot-style-signature new-node))
                 (equal (ebox-tree-display-inner old-node) 'column)
                 (ebox-incremental--same-root-surface-identity-p
                  old-state candidate-state)
                 (null (plist-get old-state :scroll-region-ids))
                 (not (ebox-tree-node-visible-overflow-p old-node))
                 (not (ebox-tree-node-visible-overflow-p new-node))
                 cascade-safe-p)
        (list :owner-id owner-id
              :owner-ids (list owner-id)
              :dirty-set (list dirty)
              :snapshot snapshot
              :old-spans spans
              :allocated-width
              (plist-get
               (plist-get snapshot :external-footprint-signature)
               :max-line-pixel-width)
              :ancestor-slot-signature ancestor-slot-signature
              :layout-snapshot-detail-generation
              (plist-get old-state :layout-snapshot-detail-generation)
              :static-cascade-p cascade-safe-p
              :range-splice-p t)))))

(defun ebox-incremental--span-patch-projection-proof
    (buffer old-state prepared candidate-state owner-plan
             &optional path-copied-p)
  "Return one atomic single- or multi-owner projection proof, or nil."
  (if (= (length owner-plan) 1)
      (when-let* ((proof
                  (or (ebox-incremental--layer-span-proof
                       buffer old-state prepared candidate-state owner-plan
                       path-copied-p)
                      (ebox-incremental--single-span-patch-projection-proof
                       buffer old-state prepared candidate-state owner-plan
                       path-copied-p)
                      (ebox-incremental--grouped-owner-span-proof
                       buffer old-state prepared candidate-state owner-plan)
                      (ebox-incremental--range-span-proof
                       buffer old-state prepared candidate-state owner-plan)
                      ;; Preserve a successful narrow proof.  Only its miss
                      ;; justifies trying the complete allocated Flex owner.
                      (when-let* ((operation
                                   (and (= (length (plist-get prepared :dirty-set)) 1)
                                        (ebox-incremental--fixed-basis-flex-local-op
                                         buffer (plist-get prepared :dirty-set) t))))
                        (ebox-incremental--grouped-owner-span-proof
                         buffer old-state prepared candidate-state
                         (list operation))))))
        (unless (plist-get proof :owner-ids)
          (setq proof
                (plist-put proof :owner-ids
                           (list (plist-get proof :owner-id)))))
        proof)
    (let ((remaining (copy-sequence (plist-get prepared :dirty-set)))
          proofs
          valid)
      (setq valid (and owner-plan t))
      (dolist (operation owner-plan)
        (when valid
          (let* ((owned
                  (cl-remove-if-not
                   (lambda (dirty)
                     (ebox--patch-op-covers-node-p
                      buffer operation (plist-get dirty :node-id)
                      (if (eq (plist-get dirty :dirty-kind) 'paint)
                          'paint-patch
                        'span-patch)))
                   remaining))
                 (local-prepared (copy-sequence prepared))
                 proof)
            (dolist (dirty owned)
              (setq remaining (delq dirty remaining)))
            (setq local-prepared
                  (plist-put local-prepared :dirty-set owned))
            ;; Each local proof owns only its assigned identity partition.
            ;; Other disjoint operations in the same atomic projection may
            ;; legitimately add or remove identities (notably a Range), so a
            ;; per-owner proof must not demand global node-set equality.  The
            ;; aggregate branch still requires every dirty entry to be owned
            ;; and every resulting owner footprint to be disjoint.
            (setq local-prepared
                  (plist-put local-prepared :partitioned-owner-proof-p t))
            (setq proof
                  (and owned
                       (ebox-incremental--span-patch-projection-proof
                        buffer old-state local-prepared candidate-state
                        (list operation) path-copied-p)))
            (if proof
                (dolist (owner-proof
                         (or (plist-get proof :owner-proofs)
                             (list proof)))
                  (push owner-proof proofs))
              (setq valid nil)))))
      (setq valid (and valid (null remaining)))
      (setq proofs (nreverse proofs))
      (when (and valid
                 ;; Variable content is admitted only when every owner has a
                 ;; stable allocated slot proof.  The surface will shape the
                 ;; new line back into that retained slot before TP sees it;
                 ;; raw string length is not the geometry proof.
                 (cl-every (lambda (proof)
                             (or (plist-get proof :layer-recompose-p)
                                 (plist-get proof :variable-content-p)
                                 (let* ((dirty (car (plist-get proof :dirty-set)))
                                        (old-content
                                         (plist-get
                                          (plist-get dirty :old-signature)
                                          :content))
                                        (new-content
                                         (plist-get
                                          (plist-get dirty :new-signature)
                                          :content)))
                                   (and (stringp old-content)
                                        (stringp new-content)
                                        (= (length old-content)
                                           (length new-content))))))
                           proofs)
                 (ebox-incremental--variable-span-proofs-safe-p
                  buffer proofs)
                 (ebox-incremental--owner-proofs-disjoint-p buffer proofs))
        (let* ((owner-ids (mapcar (lambda (proof)
                                    (plist-get proof :owner-id))
                                  proofs))
               (variable-p
                (cl-some (lambda (proof)
                           (plist-get proof :variable-content-p))
                         proofs))
               (capacities
                (delq nil
                      (mapcar
                       (lambda (proof)
                         (plist-get proof :variable-content-max-width))
                       proofs)))
               (common-max (and capacities (apply #'max capacities))))
          (list :owner-ids owner-ids
              :owner-proofs proofs
              :variable-content-p
              variable-p
              :variable-content-max-width
              (and variable-p common-max)
              :dirty-set (copy-sequence (plist-get prepared :dirty-set))
              :ancestor-slot-signature
              (cl-mapcan
               (lambda (proof)
                 (copy-sequence
                  (plist-get proof :ancestor-slot-signature)))
               proofs)
              :layout-snapshot-detail-generation
              (plist-get old-state :layout-snapshot-detail-generation)
              :static-cascade-p
              (cl-every (lambda (proof)
                          (plist-get proof :static-cascade-p))
                        proofs)))))))

(defun ebox-incremental--owner-proof-list (proof)
  "Return PROOF as one uniform list of leaf owner proofs."
  (or (plist-get proof :owner-proofs)
      (and (plist-get proof :owner-id) (list proof))))

(defun ebox-incremental--native-runtime-overrides (state)
  "Return the retained native runtime facts owned by STATE."
  (list :native-buffer-scroll-p
        (plist-get state :native-buffer-scroll-p)
        :native-root-scroll-producer (plist-get state :native-root-scroll-producer)
        :native-root-scroll-offset-dirty (plist-get state :native-root-scroll-offset-dirty)
        :native-sync-session
        (plist-get state :native-sync-session)
        :native-sync-pending
        (plist-get state :native-sync-pending)
        :native-sync-confirmed-p
        (plist-get state :native-sync-confirmed-p)
        :native-committed-rendered
        (plist-get state :native-committed-rendered)
        :native-committed-fragment-template
        (plist-get state :native-committed-fragment-template)
        :native-committed-owned-ranges
        (plist-get state :native-committed-owned-ranges)
        :native-fragment-owner-cache
        (plist-get state :native-fragment-owner-cache)))

(defun ebox-incremental--surface-state-overrides
    (old-state prepared candidate-state projection-kind
             &optional span-proof source-path-copied-p formatting-proof)
  "Return surface overrides for PREPARED CANDIDATE-STATE."
  (let* ((scroll-fast-p
         (and (eq projection-kind 'scroll-patch)
              (plist-get prepared :scroll-patch-fast-p)))
        (certificate-proof
         (cond
          ((memq projection-kind '(span-patch owner-scoped)) span-proof)
          ((and (eq projection-kind 'mixed-owner-reflow)
                (eq (plist-get (plist-get prepared :mixed-owner-proof)
                               :geometry-kind)
                    'span-patch))
           (plist-get (plist-get prepared :mixed-owner-proof)
                      :geometry-proof))))
        (certificate-proofs
         (and certificate-proof
              ;; Cache coordinates must never become buffer allocation
              ;; certificates.  Visible snapshots are installed separately.
              (not (plist-get certificate-proof :scroll-content-proof))
              (ebox-incremental--owner-proof-list certificate-proof)))
        (overrides
         (append
          (list :viewport-width (plist-get old-state :viewport-width)
                :viewport-height (plist-get old-state :viewport-height)
                :layer-recompose-p
                (and (fboundp 'ebox-layer-host-p)
                     (cl-some (lambda (proof)
                                (plist-get proof :layer-recompose-p))
                              (ebox-incremental--owner-proof-list span-proof)))
                :runtime-revision
                (plist-get candidate-state :runtime-revision)
                :display-signature (plist-get prepared :display-signature)
                :source-index (plist-get candidate-state :source-index)
                :scroll-state-table (plist-get prepared :scroll-state-table)
                :previous-layer-composition-cache
                (plist-get old-state :layer-composition-cache)
                :layer-composition-cache (make-hash-table :test 'equal)
                :layer-composition-context
                (list (plist-get candidate-state :viewport-width)
                      (plist-get candidate-state :viewport-height)
                      (plist-get prepared :display-signature)))
          (ebox-incremental--native-runtime-overrides candidate-state)
          (list :source-path-copied-p source-path-copied-p
                :runtime-index-prepared-p
                (or (plist-get prepared :runtime-index-complete-p)
                    (memq projection-kind
                          '(span-patch owner-scoped scroll-patch
                            formatting-context-reflow mixed-owner-reflow
                            viewport-reflow native-frame)))
                :logical-candidate-p
                (plist-get prepared :logical-candidate-p)
                :computed-participation-validated-p
                (plist-get prepared :computed-participation-validated-p)
                :detached-identity-history
                (plist-get prepared :detached-identity-history)))))
    (setq overrides
          (plist-put overrides :native-touched-node-ids
                     (or (plist-get candidate-state
                                    :native-touched-node-ids)
                         (plist-get prepared :touched-node-ids))))
    (setq overrides
          (plist-put overrides :native-removed-node-ids
                     (plist-get prepared :removed-node-ids)))
    (setq overrides
          (plist-put overrides :native-inherited-dirty-node-ids
                     (plist-get candidate-state
                                :native-inherited-dirty-node-ids)))
    (setq overrides
          (plist-put overrides :native-local-dirty-entries
                     (plist-get candidate-state
                                :native-local-dirty-entries)))
    (setq overrides
          (plist-put
           overrides :native-topology-stable-p
           (plist-get candidate-state :native-topology-stable-p)))
    (if (and (not (memq projection-kind
                         '(paint span-patch owner-scoped scroll-patch
                           formatting-context-reflow mixed-owner-reflow
                           native-frame)))
             (not (plist-get prepared :runtime-index-complete-p)))
        overrides
      (append
       overrides
       (list :layout-snapshots
             (cond
              ((eq projection-kind 'owner-scoped)
               (copy-hash-table (plist-get old-state :layout-snapshots)))
              ((and scroll-fast-p
                    (eq projection-kind 'scroll-patch))
               ;; The candidate already owns a hash-spine copy.  Its detail
               ;; generation was advanced during preparation, so old buffer
               ;; spans become lazily stale without copying 512 snapshot
               ;; plists on every wheel event.
               (plist-get candidate-state :layout-snapshots))
              (t (plist-get candidate-state :layout-snapshots)))
             :layout-snapshots-complete-p
             (and (not scroll-fast-p)
                  (plist-get candidate-state :layout-snapshots-complete-p))
             :layout-snapshot-detail-generation
             (plist-get candidate-state :layout-snapshot-detail-generation)
             :render-cache (plist-get candidate-state :render-cache)
             :render-signature-cache
             (plist-get candidate-state :render-signature-cache)
             :flex-content-min-widths
             (if (or (memq projection-kind
                           '(span-patch owner-scoped))
                     scroll-fast-p)
                 (plist-get candidate-state :flex-content-min-widths)
               (plist-get old-state :flex-content-min-widths))
             :viewport-height-dependent-subtree-cache
             (plist-get candidate-state
                        :viewport-height-dependent-subtree-cache)
             :viewport-dependent-node-ids-ready
             (plist-get candidate-state :viewport-dependent-node-ids-ready)
             :viewport-dependent-node-ids
             (plist-get candidate-state :viewport-dependent-node-ids)
             :viewport-dependent-node-id-axes
             (plist-get candidate-state :viewport-dependent-node-id-axes)
             :scroll-region-ids (plist-get candidate-state :scroll-region-ids)
             :node-table (plist-get candidate-state :node-table)
             :parent-table (plist-get candidate-state :parent-table)
             :region-id-set (plist-get candidate-state :region-id-set)
             :region-node-table (plist-get candidate-state :region-node-table)
             :region-box-count-table
             (plist-get candidate-state :region-box-count-table)
             :region-box-table (plist-get candidate-state :region-box-table)
             :range-ref-table (plist-get candidate-state :range-ref-table)
             :source-index (plist-get candidate-state :source-index)
             :selector-id-table (plist-get candidate-state :selector-id-table)
             :selector-class-table
             (plist-get candidate-state :selector-class-table)
             :selector-type-table
             (plist-get candidate-state :selector-type-table)
             :runtime-type-count-table
             (plist-get candidate-state :runtime-type-count-table)
             :selector-index-stale-p
             (plist-get candidate-state :selector-index-stale-p)
             :native-node-postorder
             (plist-get candidate-state :native-node-postorder)
             :native-node-postorder-ids
             (plist-get candidate-state :native-node-postorder-ids)
             :surface-node-object-table
             (and (memq projection-kind
                        '(span-patch owner-scoped scroll-patch
                          formatting-context-reflow mixed-owner-reflow))
                  (plist-get old-state :surface-node-object-table))
             :region-surface-object-table
             (and scroll-fast-p
                  (plist-get old-state :region-surface-object-table))
             :surface-object-region-table
             (and scroll-fast-p
                  (plist-get old-state :surface-object-region-table))
             :logical-id-region-table
             (and scroll-fast-p
                  (plist-get old-state :logical-id-region-table))
             :paint-dirty-set
             (and (eq projection-kind 'paint)
                  (plist-get prepared :dirty-set))
             :span-patch-owner-id
             (or (and span-proof (plist-get span-proof :owner-id))
                 (and formatting-proof
                      (plist-get formatting-proof :owner-id))
                 (and (plist-get prepared :mixed-owner-proof)
                      (plist-get
                       (plist-get (plist-get prepared :mixed-owner-proof)
                                  :geometry-proof)
                       :owner-id)))
             :span-patch-dirty-set
             (or (and span-proof (plist-get span-proof :dirty-set))
                 (and (eq projection-kind 'mixed-owner-reflow)
                      (plist-get (plist-get prepared :mixed-owner-proof)
                                 :dirty-set)))
             :owner-scoped-allocated-width
             (and (eq projection-kind 'owner-scoped)
                  (plist-get span-proof :allocated-width))
             :owner-scoped-proofs
             (or (and (memq projection-kind '(span-patch owner-scoped scroll-patch))
                      (ebox-incremental--owner-proof-list span-proof))
                 (and (eq projection-kind 'mixed-owner-reflow)
                      (eq (plist-get (plist-get prepared
                                                :mixed-owner-proof)
                                    :geometry-kind)
                          'span-patch)
                      (ebox-incremental--owner-proof-list
                       (plist-get (plist-get prepared :mixed-owner-proof)
                                  :geometry-proof))))
             :scroll-content-proof (plist-get span-proof :scroll-content-proof)
             :formatting-context-reflow-proof
             (and (or (eq projection-kind 'formatting-context-reflow)
                      (and (eq projection-kind 'mixed-owner-reflow)
                           (eq (plist-get (plist-get prepared
                                                     :mixed-owner-proof)
                                         :geometry-kind)
                               'formatting-context-reflow)))
                  (or formatting-proof
                      (plist-get (plist-get prepared :mixed-owner-proof)
                                 :geometry-proof)))
             :mixed-owner-proof
             (and (eq projection-kind 'mixed-owner-reflow)
                  (plist-get prepared :mixed-owner-proof))
             :allocation-certificate-proofs certificate-proofs
             :scroll-patch-region-id nil
             :scroll-state-transaction nil)))))

(defun ebox-incremental--same-root-surface-identity-p
    (old-state candidate-state)
  "Return non-nil when OLD-STATE and CANDIDATE-STATE retain one TP root."
  (let ((old-root (plist-get old-state :root-node))
        (new-root (plist-get candidate-state :root-node)))
    (and (eq (plist-get old-root :ebox-type)
             (plist-get new-root :ebox-type))
         (equal
          (ebox-tree-node-key (plist-get old-state :source-index) old-root)
          (ebox-tree-node-key
           (plist-get candidate-state :source-index) new-root)))))

(defun ebox-incremental--surface-commit-input
    (buffer old-state prepared)
  "Return TP surface input for BUFFER from OLD-STATE and PREPARED runtime."
  (let* ((ebox-incremental--projection-rejections nil)
         (ebox-incremental--mount-snapshot-cache (make-hash-table :test #'equal))
         (ebox-incremental--allocated-slot-proof-cache
          (make-hash-table :test 'equal))
         (ebox--flex-slot-safety-cache (make-hash-table :test 'equal))
         (ebox--runtime-ancestor-cache (make-hash-table :test 'equal))
         (candidate-state
          (ebox-incremental--candidate-state
           old-state (plist-get prepared :root)
           (plist-get prepared :index) prepared))
         (ebox--render-source-index
          (plist-get candidate-state :source-index))
         (ebox--render-source-generations
          (list (plist-get candidate-state :source-index)
                (plist-get old-state :source-index)))
         (ebox--render-source-states (list candidate-state old-state))
         (_selector-index-stale
          (when (and (plist-get candidate-state :source-index)
                     (ebox-source--index-derived-stale-p
                      (plist-get candidate-state :source-index)))
            (plist-put candidate-state :selector-index-stale-p t)))
         (structural-dirty-p
          (cl-some (lambda (entry)
                     (eq (plist-get entry :dirty-kind) 'structure))
                   (plist-get prepared :dirty-set)))
         (range-structural-p
          (and structural-dirty-p
               (cl-every
                (lambda (entry)
                  (or (not (eq (plist-get entry :dirty-kind) 'structure))
                      (plist-get entry :range-delta)))
                (plist-get prepared :dirty-set))))
         (native-program-p
          (and (or (eq (plist-get old-state :projection-kind) 'native-frame)
                   (>= (length (plist-get prepared :dirty-set)) 3)
                   structural-dirty-p
                   (> (or (plist-get prepared :range-replacement-count) 0) 0))
               (zerop (ebox-tree-author-style-count
                       (plist-get old-state :root-node)))
               (zerop (ebox-tree-author-style-count
                       (plist-get candidate-state :root-node)))
               (require 'ebox-native-commit nil t)
               (ebox-native-commit-plan-eligible-p
                old-state candidate-state prepared)))
         (_normalize-local-dirty
          (when (and (not native-program-p)
                     (plist-get prepared :styles-prepared-p))
            (setq prepared
                  (plist-put
                   prepared :dirty-set
                   (ebox-incremental--computed-local-dirty-set
                    old-state (plist-get prepared :index)
                    (plist-get prepared :dirty-set))))
            (setq structural-dirty-p
                  (cl-some
                   (lambda (entry)
                     (eq (plist-get entry :dirty-kind) 'structure))
                   (plist-get prepared :dirty-set)))
            (setq range-structural-p
                  (and structural-dirty-p
                       (cl-every
                        (lambda (entry)
                          (or (not (eq (plist-get entry :dirty-kind)
                                       'structure))
                              (plist-get entry :range-delta)))
                        (plist-get prepared :dirty-set))))))
         (unprepared-style-p
          (/= (ebox-tree-author-style-count (plist-get old-state :root-node))
              (ebox-tree-author-style-count (plist-get candidate-state :root-node))))
         ;; Resolve the mandatory cascade boundary before any local layout probe.
         ;; Such probes cannot render detached nodes with pending author styles.
         (layer-owner-plan
          (and (not unprepared-style-p)
               (ebox-incremental--layer-owner-plan
                buffer old-state candidate-state (plist-get prepared :dirty-set))))
         (formatting-proof
          (and (not unprepared-style-p) (not layer-owner-plan) (not native-program-p)
               (not (cl-some
                     (lambda (entry)
                       (eq (plist-get entry :dirty-kind) 'paint))
                     (plist-get prepared :dirty-set)))
               (ebox-incremental--formatting-context-reflow-proof
                buffer old-state candidate-state prepared)))
         (mixed-shape-p
          (and (not unprepared-style-p) (not layer-owner-plan) (not native-program-p)
               (or (not structural-dirty-p) range-structural-p)
               (cl-some
                (lambda (entry)
                  (eq (plist-get entry :dirty-kind) 'paint))
                (plist-get prepared :dirty-set))
               (>= (cl-count-if
                    (lambda (entry)
                      (or (eq (plist-get entry :dirty-kind) 'geometry)
                          (and (eq (plist-get entry :dirty-kind) 'structure)
                               (plist-get entry :range-delta))))
                    (plist-get prepared :dirty-set))
                   1)))
         (mixed-proof
          (and mixed-shape-p
               (ebox-incremental--mixed-owner-proof
                buffer old-state candidate-state prepared nil)))
         (mixed-owner-plan
          (and mixed-proof
               ;; The proof already owns the exact geometry/paint union.
               ;; These lightweight ops feed the generic report and scope
               ;; builders; they never re-run layout ownership planning.
               (append
                (mapcar
                 (lambda (owner-id)
                   (ebox--patch-op
                    (if (eq (plist-get mixed-proof :geometry-kind)
                            'formatting-context-reflow)
                        'formatting-context-reflow
                      'span-patch)
                    owner-id))
                 (plist-get mixed-proof :geometry-owner-ids))
                (mapcar (lambda (owner-id)
                          (ebox--patch-op 'paint-patch owner-id))
                        (plist-get mixed-proof :paint-owner-ids)))))
         (owner-plan
          (cond
           (unprepared-style-p
            (ebox-incremental--root-owner-plan
             buffer (plist-get prepared :dirty-set)))
           (layer-owner-plan layer-owner-plan)
           (native-program-p
            (ebox-incremental--native-frame-plan
             buffer (plist-get prepared :dirty-set)))
           (mixed-owner-plan mixed-owner-plan)
           (formatting-proof
              (list
               (ebox--patch-op
                'formatting-context-reflow
                (plist-get formatting-proof :owner-id)
                :dirty (plist-get formatting-proof :dirty-set)
                :proof formatting-proof)))
           (t
            (let ((ebox-incremental--candidate-state-for-slot-proof
                   candidate-state))
              (if (ebox-incremental--cascade-root-owner-plan-p
                   old-state candidate-state
                   (plist-get prepared :dirty-set))
                  (ebox-incremental--root-owner-plan
                   buffer (plist-get prepared :dirty-set))
                (ebox-incremental--layout-owner-plan
                 buffer old-state candidate-state
                 (plist-get prepared :dirty-set)))))))
         (same-root-identity-p
          (ebox-incremental--same-root-surface-identity-p
           old-state candidate-state))
         (scope-node-ids
          (and same-root-identity-p
               (delete-dups
                (or (mapcar (lambda (op) (plist-get op :owner-id)) owner-plan)
                    (mapcar (lambda (entry) (plist-get entry :node-id))
                            (plist-get prepared :dirty-set))))))
         (report
          (ebox-incremental--layout-owner-report
           prepared owner-plan candidate-state))
         (paint-p
          (and (not native-program-p)
               (ebox-incremental--paint-projection-p
                buffer old-state prepared candidate-state owner-plan)))
         (span-proof
          (unless (or native-program-p
                      (and structural-dirty-p (not layer-owner-plan))
                      paint-p mixed-proof)
            (ebox-incremental--span-patch-projection-proof
             buffer old-state prepared candidate-state owner-plan)))
         (projection-kind
         (cond
           (native-program-p 'native-frame)
           (mixed-proof 'mixed-owner-reflow)
           (formatting-proof 'formatting-context-reflow)
           (paint-p 'paint)
           ((and span-proof
                 (plist-get span-proof :static-cascade-p)
                 (not (plist-get span-proof :variable-content-p)))
            'owner-scoped)
           (span-proof 'span-patch))))
    (when projection-kind
      (setq report (plist-put report :projection-kind projection-kind)))
    (when ebox-incremental--projection-rejections
      (setq report
            (plist-put report :projection-rejections
                       (nreverse ebox-incremental--projection-rejections))))
    (when layer-owner-plan
      (setq report (plist-put report :layer-recompose-p t)))
    (when mixed-proof
      (setq prepared (plist-put prepared :mixed-owner-proof mixed-proof))
      (setq report
            (ebox-incremental--plist-overlay
             report
             (list :strategy 'mixed-owner-reflow
                   :owner-ids (plist-get mixed-proof :owner-ids)
                   :patch-count (length (plist-get mixed-proof :owner-ids))
                   :publication-scope 'mixed-owner-union
                   :render-scope 'mixed-owner-union))))
    (when span-proof
      (setq report
            (plist-put report :ancestor-slot-count
                       (length (plist-get span-proof
                                          :ancestor-slot-signature))))
      (setq report
            (plist-put report :ancestor-slot-generation
                       (plist-get span-proof
                                  :layout-snapshot-detail-generation))))
    (unless same-root-identity-p
      (setq report (plist-put report :strategy 'root-rerender))
      (setq report (plist-put report :publication-scope 'root))
      (setq report (plist-put report :root-rerender t)))
    (when (> (or (plist-get prepared :range-replacement-count) 0) 0)
      (let* ((range-metrics (copy-tree (plist-get prepared :range-metrics)))
             (applied (cl-loop for entry in range-metrics
                               sum (plist-get entry :ref-index-visits)))
             (requested (plist-get prepared :range-replacement-count)))
        (setq report
              (plist-put report :range-metrics
                         (list :parents range-metrics
                               :replacement-count requested
                               :applied-count applied
                               :coalesced-count (- requested applied))))))
    (list :root (plist-get prepared :root)
          :scope-node-ids scope-node-ids
          :report-base report
          ;; A child Range replacement can legitimately change the separator
          ;; owned by an adjacent sibling when its item count changes.  Keep
          ;; the fast scoped proof for stable topology, but let the surface
          ;; publisher use its exact root fallback when that proof cannot
          ;; establish the outside text invariant.
          :on-mismatch
          (and (or (> (or (plist-get prepared :range-replacement-count) 0)
                      0)
                   (not
                    (let ((old-ranges (plist-get old-state :range-ref-table))
                          (new-ranges
                           (plist-get candidate-state :range-ref-table)))
                      (or (and (null old-ranges) (null new-ranges))
                          (ebox-incremental--hash-key-set-equal-p
                           old-ranges new-ranges)))))
               'root)
          :projection-kind projection-kind
          :preserve-identities-p t
          :state-overrides
           (ebox-incremental--surface-state-overrides
            old-state prepared candidate-state projection-kind span-proof
            nil formatting-proof))))

(defun ebox-incremental--plist-overlay (base overrides)
  "Return BASE with every property in OVERRIDES replaced."
  (setq base (copy-sequence base))
  (while overrides
    (setq base (plist-put base (pop overrides) (pop overrides))))
  base)

(defun ebox-incremental--scroll-content-span-proof
    (buffer old-state prepared candidate-state &optional scroll-owner-id)
  "Prove one content owner in a retained root scroll's content coordinates.
The visible buffer may contain only part of the scroll content.  Its cached
lines are a separate coordinate space, so run the ordinary owner and footprint
proofs there rather than treating invisible owners as zero-sized.  Nested
scrolls, non-content changes and uncached/partial owners retain their ordinary
fallback.  The surface must still validate the complete cached replacement and
the visible replacement independently before publishing either one.
SCROLL-OWNER-ID instead proves one nested scroll viewport in that root cache;
other scroll owners must be disjoint from the target."
  (let* ((regions (plist-get old-state :scroll-region-ids))
         (root (plist-get old-state :root-node))
         (region (if scroll-owner-id (plist-get root :region-id)
                   (and (= (length regions) 1) (car regions))))
         (scroll (and region (gethash region (plist-get old-state :scroll-state-table))))
         (next-scroll (and region (gethash region
                                          (plist-get prepared :scroll-state-table))))
         (dirty-set (plist-get prepared :dirty-set))
         (lines (plist-get scroll :content-lines)))
    (when (and region scroll next-scroll lines
               (eq (plist-get scroll :buffer) buffer)
               (eq (plist-get scroll :box) root)
               (eq (plist-get next-scroll :box)
                   (plist-get candidate-state :root-node))
               (if scroll-owner-id
                   (and (not (equal scroll-owner-id (plist-get root :node-id)))
                        (cl-every
                         (lambda (id)
                           (let ((owner (ebox--buffer-region-render-owner-node-id buffer id)))
                             (or (equal id region) (equal owner scroll-owner-id)
                                 (and owner
                                      (not (ebox--runtime-ancestor-id-p buffer owner scroll-owner-id))
                                      (not (ebox--runtime-ancestor-id-p buffer scroll-owner-id owner))))))
                         regions))
                 (= (hash-table-count (plist-get prepared :scroll-state-table)) 1))
               (= (length dirty-set) 1)
               (if scroll-owner-id
                   (and (equal scroll-owner-id (plist-get (car dirty-set) :node-id))
                        (cl-every (lambda (key)
                                    (memq key '(:scroll-offset :ebox-scroll-offset-controlled-p)))
                                  (plist-get (car dirty-set) :changed-keys)))
                 (equal (plist-get (car dirty-set) :changed-keys) '(:content)))
               (not (plist-get (car dirty-set) :children))
               (not (plist-get scroll :lazy-scroll-prefix-dirty))
               (equal (plist-get scroll :scroll-offset)
                      (plist-get next-scroll :scroll-offset)))
      (with-temp-buffer
        (insert (ebox-lines-join lines))
        (let* ((base (copy-sequence old-state))
               (candidate (copy-sequence candidate-state))
               (input (copy-sequence prepared))
               (ebox-incremental--allocated-slot-proof-cache
                (make-hash-table :test 'equal)))
          (dolist (state (list base candidate))
            (plist-put state :surface nil)
            (plist-put state :scroll-region-ids nil)
            (plist-put state :scroll-state-table (make-hash-table :test 'equal))
            (plist-put state :layout-snapshots (make-hash-table :test 'equal)))
          (plist-put input :scroll-state-table (make-hash-table :test 'equal))
          (let* ((ebox-incremental--buffer-render-state-override
                  (cons (current-buffer) base))
                 (ebox-incremental--candidate-base-state
                  (cons (current-buffer) base))
                 (ebox-incremental--candidate-state-for-slot-proof candidate)
                 (ebox--region-line-index (ebox--build-region-line-index scroll-owner-id))
                 (ebox--region-line-index-buffer (current-buffer))
                 (plan (if scroll-owner-id
                           (list (ebox--patch-op 'span-patch scroll-owner-id :dirty dirty-set))
                         (ebox-incremental--layout-owner-plan
                          (current-buffer) base candidate dirty-set)))
                 (proof
                  (if scroll-owner-id
                      (when-let* ((snapshot (ebox--ensure-layout-snapshot-details
                                            (current-buffer) scroll-owner-id))
                                  ((plist-get snapshot :buffer-spans))
                                  (width (plist-get (plist-get snapshot :external-footprint-signature)
                                                    :max-line-pixel-width)))
                        (list :owner-id scroll-owner-id :snapshot snapshot
                              :allocated-width width :nested-scroll-patch-p t
                              :scroll-content-coordinate-p t))
                    (ebox-incremental--span-patch-projection-proof
                     (current-buffer) base input candidate plan))))
            (when proof
              (plist-put proof :scroll-content-proof
                         (list :region-id region :lines lines :owner-plan plan
                               :snapshots (plist-get base :layout-snapshots)
                               :line-index ebox--region-line-index))
              proof)))))))

(defun ebox-incremental--layer-root-scroll-p
    (old-state candidate-state prepared owner-id)
  "Prove OWNER-ID only scrolls a retained composed root between both states.
OLD-STATE and CANDIDATE-STATE must share the complete cached content; PREPARED
must contain no source, geometry, paint, or display change besides its offset."
  (let* ((old-root (plist-get old-state :root-node))
         (root (plist-get candidate-state :root-node))
         (region-id (plist-get root :region-id))
         (old-scroll (gethash region-id (plist-get old-state :scroll-state-table)))
         (scroll (gethash region-id (plist-get candidate-state :scroll-state-table))))
    (and owner-id
         (equal owner-id (plist-get old-root :node-id))
         (equal owner-id (plist-get root :node-id))
         (equal (plist-get old-state :display-signature)
                (plist-get candidate-state :display-signature))
         (cl-every (lambda (entry)
                     (and (equal owner-id (plist-get entry :node-id))
                          (cl-every (lambda (key)
                                      (memq key '(:scroll-offset
                                                  :ebox-scroll-offset-controlled-p)))
                                    (plist-get entry :changed-keys))))
                   (plist-get prepared :dirty-set))
         (eq (plist-get old-scroll :content-lines)
             (plist-get scroll :content-lines))
         (ebox-layer-cached-root-scroll-p root scroll))))

(defun ebox-incremental--prepare-scoped-candidate
    (buffer old-state next-root isolated-candidate-p
            &optional skip-span-proof-p scroll-transaction-p scroll-owner-id)
  "Prepare NEXT-ROOT and its scoped owner plan for BUFFER.
OLD-STATE provides the published inputs.  ISOLATED-CANDIDATE-P marks a private
logical tree.  SKIP-SPAN-PROOF-P permits the retained scroll fast path;
SCROLL-TRANSACTION-P and SCROLL-OWNER-ID identify the changing scroll owner.
Return the intermediate candidate state, owner plan, projection proof, and
whether NEXT-ROOT shares untouched published nodes."
  (let* ((ebox-incremental--projection-rejections nil)
         (ebox-incremental--allocated-slot-proof-cache
          (make-hash-table :test 'equal))
         (source-base-index
          (or ebox-incremental--source-base-index
              (and isolated-candidate-p
                   (plist-get old-state :source-index))))
         (path-copied-p
          (and isolated-candidate-p
               (ebox-incremental--candidate-shares-published-node-p
                old-state next-root)))
         (incoming-source-indexes
          (when ebox-incremental--source-base-index
            (let ((table (make-hash-table :test #'eq)))
              (dolist (handle
                       (ebox-source--index-local-handles
                        ebox-incremental--source-base-index))
                (puthash handle ebox-incremental--source-base-index table))
              table)))
         (local-preparation
          (and path-copied-p
               (let ((ebox-incremental--candidate-incoming-source-indexes
                      incoming-source-indexes))
                 (ebox-incremental--candidate-local-index-delta
                  old-state next-root))))
         (source-index
          (and source-base-index
               (not local-preparation)
               (if (ebox-source--index-node-subjects source-base-index)
                   ;; Region/property candidates preserve validated topology;
                   ;; their source rebind already patches the one exact subject
                   ;; handle, so rebuilding every tree-derived subject would
                   ;; turn an O(changed) update back into O(all).
                   source-base-index
                 (ebox-tree-source-index
                  next-root nil nil source-base-index))))
         (prepared
          (if isolated-candidate-p
              (ebox-incremental--prepare-declarative-runtime
               buffer old-state next-root nil local-preparation
               skip-span-proof-p source-index)
            (ebox-incremental--prepare-declarative-root
             buffer old-state next-root)))
         (candidate-state
          (ebox-incremental--candidate-state
           old-state (plist-get prepared :root)
           (plist-get prepared :index) prepared))
         (ebox--render-source-index
          (plist-get candidate-state :source-index))
         (ebox--render-source-generations
          (list (plist-get candidate-state :source-index)
                (plist-get old-state :source-index)))
         (ebox--render-source-states (list candidate-state old-state))
         (_selector-index-stale
          (when (and (plist-get candidate-state :source-index)
                     (ebox-source--index-derived-stale-p
                      (plist-get candidate-state :source-index)))
            (plist-put candidate-state :selector-index-stale-p t)))
         (layer-owner-plan
          (unless (and scroll-transaction-p
                       (plist-get old-state :layered-p)
                       (ebox-incremental--layer-root-scroll-p
                        old-state candidate-state prepared scroll-owner-id))
            (ebox-incremental--layer-owner-plan
             buffer old-state candidate-state
             (or (plist-get prepared :dirty-set)
                 (and scroll-transaction-p scroll-owner-id
                      (list (list :node-id scroll-owner-id
                                  :dirty-kind 'geometry
                                  :changed-keys '(:scroll-offset))))))))
         (formatting-proof
          (and (not layer-owner-plan) (not scroll-transaction-p)
               (not (cl-some
                     (lambda (entry)
                       (eq (plist-get entry :dirty-kind) 'paint))
                     (plist-get prepared :dirty-set)))
               (ebox-incremental--formatting-context-reflow-proof
                buffer old-state candidate-state prepared)))
         (owner-plan
          (if layer-owner-plan layer-owner-plan
           (if formatting-proof
              (list
               (ebox--patch-op
                'formatting-context-reflow
                (plist-get formatting-proof :owner-id)
                :dirty (plist-get formatting-proof :dirty-set)
                :proof formatting-proof))
            (unless scroll-transaction-p
              (let ((ebox-incremental--candidate-state-for-slot-proof
                     candidate-state))
                (ebox-incremental--layout-owner-plan
                 buffer old-state candidate-state
                 (plist-get prepared :dirty-set)))))))
         (mixed-proof
          (and (not layer-owner-plan) (not scroll-transaction-p)
               (ebox-incremental--mixed-owner-proof
                buffer old-state candidate-state prepared owner-plan)))
         (scope-node-ids
          (delete-dups
           (or (mapcar (lambda (op) (plist-get op :owner-id)) owner-plan)
               (mapcar (lambda (entry) (plist-get entry :node-id))
                       (plist-get prepared :dirty-set)))))
         (paint-p
          (ebox-incremental--paint-projection-p
           buffer old-state prepared candidate-state owner-plan))
         (span-proof
          (if (and scroll-transaction-p skip-span-proof-p (not layer-owner-plan))
              (ebox-incremental--scroll-content-span-proof
               buffer old-state prepared candidate-state scroll-owner-id)
            (unless (or paint-p mixed-proof)
             (or (ebox-incremental--span-patch-projection-proof
                 buffer old-state prepared candidate-state owner-plan
                 path-copied-p)
                (ebox-incremental--scroll-content-span-proof
                 buffer old-state prepared candidate-state)))))
         (projection-kind
         (cond
           (mixed-proof 'mixed-owner-reflow)
           (formatting-proof 'formatting-context-reflow)
           (paint-p 'paint)
           ((and span-proof
                 (plist-get span-proof :static-cascade-p)
                 (not (plist-get span-proof :variable-content-p)))
            'owner-scoped)
           (span-proof 'span-patch))))
    (when-let* ((scroll-proof (plist-get span-proof :scroll-content-proof)))
      (setq owner-plan (plist-get scroll-proof :owner-plan)
            scope-node-ids (mapcar (lambda (op) (plist-get op :owner-id))
                                  owner-plan)))
    (setq prepared (plist-put prepared :scroll-patch-fast-p
                              (and skip-span-proof-p (not layer-owner-plan))))
    (when mixed-proof
      (setq prepared (plist-put prepared :mixed-owner-proof mixed-proof)))
    (list :prepared prepared
          :projection-rejections (nreverse ebox-incremental--projection-rejections)
          :candidate-state candidate-state
          :owner-plan owner-plan
          :scope-node-ids scope-node-ids
          :span-proof span-proof
          :mixed-proof mixed-proof
          :formatting-proof formatting-proof
          :layer-recompose-p (and layer-owner-plan t)
          :projection-kind projection-kind
          :path-copied-p path-copied-p)))

(defun ebox-incremental-prepare-scoped-commit
    (buffer next-root report-overrides &optional isolated-candidate-p)
  "Prepare NEXT-ROOT for object-scoped TP publication in BUFFER.
REPORT-OVERRIDES replaces Ebox semantic report fields.  The returned plist
contains the isolated candidate root, Ebox node identities, report, and
runtime overrides; the surface layer resolves identities to opaque TP objects.
When ISOLATED-CANDIDATE-P is non-nil, NEXT-ROOT is an internally copied
runtime candidate whose identities already match the published root."
  (let ((old-state (ebox--buffer-render-state buffer))
        (scroll-transaction-p
         (plist-get report-overrides :scroll-state-transaction))
        (scroll-patch-fast-p
         (plist-get report-overrides :scroll-patch-fast-p)))
    (unless old-state
      (error "Ebox buffer has no rendered runtime: %S" buffer))
    (let* ((candidate
            (ebox-incremental--prepare-scoped-candidate
             buffer old-state next-root isolated-candidate-p
             scroll-patch-fast-p scroll-transaction-p
             (plist-get report-overrides :owner-id))))
      ;; A path-copied candidate is safe to render in place only after the
      ;; strict span proof succeeds.  Widened projection would mutate shared
      ;; layout nodes, so promote it to a private copy before the surface sees
      ;; it.  The ordinary full-copy path remains the correctness fallback.
      (when (and (plist-get candidate :path-copied-p)
                 (or (not scroll-patch-fast-p)
                     (plist-get candidate :layer-recompose-p))
                 (not (memq (plist-get candidate :projection-kind)
                            '(span-patch owner-scoped scroll-patch
                              mixed-owner-reflow))))
        (setq candidate
              (ebox-incremental--prepare-scoped-candidate
               buffer old-state
               (ebox-tree-copy-node-structure
                (plist-get (plist-get candidate :prepared) :root))
               isolated-candidate-p scroll-patch-fast-p
               scroll-transaction-p (plist-get report-overrides :owner-id))))
      (let* ((prepared (plist-get candidate :prepared))
             (scroll-transaction-p
              (and scroll-transaction-p
                   (not (plist-get candidate :layer-recompose-p))))
             (candidate-state (plist-get candidate :candidate-state))
             (owner-plan
              (or (plist-get candidate :owner-plan)
                  (and scroll-transaction-p
                       (list
                        (ebox--patch-op
                         'span-patch
                         (plist-get report-overrides :owner-id)
                         :dirty (plist-get prepared :dirty-set)
                         :proof-skipped-p t)))))
             (scope-node-ids
              (if scroll-transaction-p
                  (list (plist-get report-overrides :owner-id))
                (plist-get candidate :scope-node-ids)))
             (span-proof (plist-get candidate :span-proof))
             (formatting-proof (plist-get candidate :formatting-proof))
             (projection-kind (plist-get candidate :projection-kind))
             (report
              (ebox-incremental--plist-overlay
               (ebox-incremental--layout-owner-report
                prepared owner-plan candidate-state)
               report-overrides)))
        (when (plist-get candidate :projection-rejections)
          (setq report
                (plist-put report :projection-rejections
                           (plist-get candidate :projection-rejections))))
        (when scroll-transaction-p
          ;; A complete native producer must advance its confirmed visible
          ;; frame on scroll as well.  Ordinary scroll states publish their
          ;; already staged window through the retained object scope.
          (setq projection-kind
                (if (and (require 'ebox-native-commit nil t)
                         (ebox-native-commit-root-scroll-continuation-p old-state)
                         (equal (plist-get report-overrides :region-id)
                                (plist-get (ebox-native-commit--root-box
                                            (plist-get old-state :root-node))
                                           :region-id))
                         (ebox-native-commit-plan-eligible-p
                          old-state candidate-state prepared))
                    'native-frame
                  'scroll-patch))
          (setq report (plist-put report :projection-kind projection-kind)))
        (when projection-kind
          (setq report (plist-put report :projection-kind projection-kind)))
        (when (plist-get candidate :layer-recompose-p)
          (setq report (plist-put report :layer-recompose-p t)))
        (when span-proof
          (setq report
                (plist-put report :ancestor-slot-count
                           (length (plist-get span-proof
                                              :ancestor-slot-signature))))
          (setq report
                (plist-put report :ancestor-slot-generation
                           (plist-get span-proof
                                      :layout-snapshot-detail-generation))))
        (let ((state-overrides
             (ebox-incremental--surface-state-overrides
                old-state prepared candidate-state projection-kind span-proof
                (plist-get candidate :path-copied-p) formatting-proof)))
          (when scroll-transaction-p
            (setq state-overrides
                  (plist-put state-overrides :scroll-state-transaction t))
            (setq state-overrides
                  (plist-put state-overrides :scroll-patch-region-id
                             (plist-get report-overrides :region-id)))
            (setq state-overrides
                  (plist-put state-overrides :span-patch-owner-id
                             (or (plist-get state-overrides :span-patch-owner-id)
                                 (plist-get report-overrides :owner-id))))
            (setq state-overrides
                  (plist-put state-overrides :scroll-fast-window-p
                             (and (eq projection-kind 'scroll-patch)
                                  scroll-patch-fast-p))))
          (list :root (plist-get prepared :root)
              :scope-node-ids scope-node-ids
              :report-base report
              :projection-kind projection-kind
              :preserve-identities-p t
              :state-overrides state-overrides))))))

(defun ebox-incremental--viewport-state-overrides
    (state &optional retain-native-p)
  "Return surface overrides from viewport candidate STATE.
When RETAIN-NATIVE-P is non-nil, preserve its committed native frame bases."
  (append
   (list :viewport-width (plist-get state :viewport-width)
        :viewport-height (plist-get state :viewport-height)
        ;; Candidate runtime revisions are the TP base revision for the
        ;; upcoming viewport transaction; the published TP revision is
        ;; advanced by the transaction and recorded after publication.
        :runtime-revision (plist-get state :runtime-revision)
        :display-signature (plist-get state :display-signature)
        :render-cache (plist-get state :render-cache)
        :layout-fragments (plist-get state :layout-fragments)
        :layout-fragments-reuse-p
        (plist-get state :layout-fragments-reuse-p)
        :render-signature-cache (plist-get state :render-signature-cache)
        :previous-layer-composition-cache
        (plist-get state :layer-composition-cache)
        :layer-composition-cache (make-hash-table :test 'equal)
        :layer-composition-context
        (list (plist-get state :viewport-width)
              (plist-get state :viewport-height)
              (plist-get state :display-signature))
        :flex-content-min-widths (plist-get state :flex-content-min-widths)
        :viewport-height-dependent-subtree-cache
        (plist-get state :viewport-height-dependent-subtree-cache)
        :viewport-dependent-node-ids-ready
        (plist-get state :viewport-dependent-node-ids-ready)
        :viewport-dependent-node-ids
        (plist-get state :viewport-dependent-node-ids)
        :viewport-dependent-node-id-axes
        (plist-get state :viewport-dependent-node-id-axes)
        ;; A viewport commit never changes the declarative node topology.
        ;; Preserve the prepared indexes so the surface layer does not walk
        ;; the complete runtime tree again after rendering the new geometry.
        :node-table (plist-get state :node-table)
        :parent-table (plist-get state :parent-table)
        :region-id-set (plist-get state :region-id-set)
        :region-node-table (plist-get state :region-node-table)
        :region-box-count-table (plist-get state :region-box-count-table)
        :source-index (plist-get state :source-index)
        :range-ref-table (plist-get state :range-ref-table)
        :selector-id-table (plist-get state :selector-id-table)
        :selector-class-table (plist-get state :selector-class-table)
        :selector-type-table (plist-get state :selector-type-table)
        :runtime-type-count-table (plist-get state :runtime-type-count-table)
        :native-node-postorder (plist-get state :native-node-postorder)
        :native-node-postorder-ids (plist-get state :native-node-postorder-ids)
        :runtime-index-prepared-p t
        :scroll-state-table (plist-get state :scroll-state-table)
        :detached-identity-history
        (plist-get state :detached-identity-history))
   (and retain-native-p
        (ebox-incremental--native-runtime-overrides state))))

(defun ebox-incremental--viewport-root-proof-p
    (old-state candidate-state dirty-set owner-plan style-context-stable-p)
  "Return non-nil when a retained viewport root proof can begin."
  (let* ((old-root (plist-get old-state :root-node))
         (candidate-root (plist-get candidate-state :root-node))
         (root-id (and old-root (plist-get old-root :node-id)))
         (operation (and (= (length owner-plan) 1) (car owner-plan)))
         (objects (plist-get old-state :surface-node-object-table)))
    (and old-root candidate-root
         (eq old-root candidate-root)
         (eq (plist-get operation :op) 'owner-rerender)
         (equal (plist-get operation :owner-id) root-id)
         (cl-every (lambda (dirty)
                     (and (eq (plist-get dirty :dirty-kind) 'geometry)
                          (not (plist-get dirty :children))))
                   dirty-set)
         (or (and (not (plist-get old-state :cascade-active-p))
                  (not (ebox-style-cascade-active-p)))
             style-context-stable-p)
         (zerop (ebox-tree-author-style-count old-root))
         (zerop (ebox-tree-author-style-count candidate-root))
         (not (ebox-tree-node-visible-overflow-p old-root))
         (hash-table-p objects)
         (> (hash-table-count objects) 0)
         (ebox-incremental--hash-key-set-equal-p
          (plist-get old-state :node-table)
          (plist-get candidate-state :node-table))
         (ebox-incremental--hash-key-set-equal-p
          (plist-get old-state :region-id-set)
          (plist-get candidate-state :region-id-set))
         (ebox-incremental--hash-key-set-equal-p
          (plist-get old-state :parent-table)
          (plist-get candidate-state :parent-table)))))

(defun ebox-incremental--viewport-reflow-safe-p
    (old-state candidate-state dirty-set owner-plan style-context-stable-p)
  "Return non-nil when a viewport reflow can reuse the retained node tree.
Scroll producer and spatial reuse require their own independent proofs."
  (ebox-incremental--viewport-root-proof-p
   old-state candidate-state dirty-set owner-plan style-context-stable-p))

(defun ebox-incremental--viewport-root-scroll-reflow-proof-p
    (old-state candidate-state style-context-stable-p)
  "Return non-nil for one resizable root scroll owner.
The root itself is the only scroll producer, so its viewport-dependent
content is exactly the formatting context being reflowed.  This spatial reuse
proof does not authorize nested scroll owners, visible overflow, cascade
changes, or topology changes."
  (let* ((old-root (plist-get old-state :root-node))
         (candidate-root (plist-get candidate-state :root-node))
         (root-id (and old-root (plist-get old-root :node-id)))
         (scroll-ids (plist-get old-state :scroll-region-ids))
         (region-node-table (plist-get old-state :region-node-table))
         (scroll-table (plist-get old-state :scroll-state-table))
         (region-id (and (= (length scroll-ids) 1)
                         (car scroll-ids)))
         (region-node-id (and region-id region-node-table
                              (ebox-runtime-index-get region-id region-node-table)))
         (candidate-scroll-table
          (plist-get candidate-state :scroll-state-table)))
    (and old-root candidate-root
         (eq old-root candidate-root)
         root-id region-id
         (equal region-node-id root-id)
         (hash-table-p scroll-table)
         (gethash region-id scroll-table)
         (hash-table-p candidate-scroll-table)
         (ebox-incremental--hash-key-set-equal-p
          scroll-table candidate-scroll-table)
         (not (ebox-tree-node-visible-overflow-p old-root))
         (or (and (not (plist-get old-state :cascade-active-p))
                  (not (ebox-style-cascade-active-p)))
             style-context-stable-p)
         (zerop (ebox-tree-author-style-count old-root))
         (zerop (ebox-tree-author-style-count candidate-root))
         (ebox-incremental--hash-key-set-equal-p
          (plist-get old-state :node-table)
          (plist-get candidate-state :node-table))
         (ebox-incremental--hash-key-set-equal-p
          (plist-get old-state :region-id-set)
          (plist-get candidate-state :region-id-set))
         (ebox-incremental--hash-key-set-equal-p
          (plist-get old-state :parent-table)
          (plist-get candidate-state :parent-table)))))

(defun ebox-incremental--viewport-scroll-partition (state)
  "Partition STATE scroll owners into stable and viewport-affected sets.
A producer is stable only when its own subtree is independent of both
viewport axes and has no visible overflow; an affected producer is rendered
fresh regardless of whether any stable producers exist."
  (let ((region-node-table (plist-get state :region-node-table))
        (node-table (plist-get state :node-table))
        (scroll-state-table (plist-get state :scroll-state-table))
        (stable nil)
        (affected nil))
    (if (not (and (ebox-runtime-index-like-p region-node-table)
                  (ebox-runtime-index-like-p node-table)
                  (hash-table-p scroll-state-table)))
        (setq affected (reverse (plist-get state :scroll-region-ids)))
      (let ((ebox--viewport-dependent-node-ids-cache
             (make-hash-table :test #'eq))
            (ebox--viewport-dependent-subtree-cache
             (make-hash-table :test #'eq))
            (ebox--viewport-height-dependent-subtree-cache
             (make-hash-table :test #'eq)))
        (dolist (region-id (plist-get state :scroll-region-ids))
          (let* ((node-id (ebox-runtime-index-get region-id region-node-table))
                 (node (and node-id (ebox-runtime-index-get node-id node-table)))
                 (scroll-state (gethash region-id scroll-state-table))
                 (stable-p
                  (and node scroll-state
                       (not (ebox--viewport-dependent-subtree-p node))
                       (not (ebox--viewport-height-dependent-subtree-p node))
                       (not (ebox-tree-node-visible-overflow-p node)))))
            (if stable-p
                (push region-id stable)
              (push region-id affected))))))
    (setq stable (nreverse stable)
          affected (nreverse affected))
    (list :stable stable
          :affected affected
          :all (append stable affected))))

(defun ebox-incremental--viewport-reflow-state-overrides
    (old-state candidate-state &optional scroll-partition)
  "Return candidate STATE overrides for a retained viewport reflow."
  (append
   (ebox-incremental--viewport-state-overrides candidate-state)
   (list
    :preserve-scroll-producer-region-ids
    (plist-get scroll-partition :stable)
    :scroll-region-ids (plist-get candidate-state :scroll-region-ids)
    :node-table (plist-get candidate-state :node-table)
    :parent-table (plist-get candidate-state :parent-table)
    :region-id-set (plist-get candidate-state :region-id-set)
    :region-node-table (plist-get candidate-state :region-node-table)
    :region-box-count-table (plist-get candidate-state :region-box-count-table)
    :region-box-table (plist-get candidate-state :region-box-table)
    :range-ref-table (plist-get candidate-state :range-ref-table)
    :selector-id-table (plist-get candidate-state :selector-id-table)
    :selector-class-table (plist-get candidate-state :selector-class-table)
    :selector-type-table (plist-get candidate-state :selector-type-table)
    :runtime-type-count-table
    (plist-get candidate-state :runtime-type-count-table)
    :selector-index-stale-p
    (plist-get candidate-state :selector-index-stale-p)
    :native-node-postorder
    (plist-get candidate-state :native-node-postorder)
    :native-node-postorder-ids
    (plist-get candidate-state :native-node-postorder-ids)
    :runtime-index-prepared-p t
    :surface-node-object-table
    (plist-get old-state :surface-node-object-table))))

(defun ebox-incremental-prepare-viewport-commit
    (buffer viewport-width viewport-height axes display-signature
            style-context-stable-p)
  "Prepare BUFFER for VIEWPORT-WIDTH, VIEWPORT-HEIGHT, AXES, and DISPLAY-SIGNATURE."
  (let* ((old-state (ebox--buffer-render-state buffer))
         (ebox--render-source-index (plist-get old-state :source-index))
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
                     :host-context-changed display-changed
                     :target-viewport-width viewport-width
                     :target-viewport-height target-height))
              :state-overrides
              (list :viewport-width viewport-width
                    :viewport-height target-height
                    :display-signature display-signature))
      (let* ((candidate-scroll-table
              (ebox-incremental--candidate-scroll-state-table
               buffer old-state old-state
               (plist-get old-state :region-box-table)))
             (candidate-state
              (let ((state (copy-sequence old-state)))
                ;; EQ memo keys belong to one node generation.  Start fresh
                ;; before isolation can copy historical node keys.
                (dolist (key '(:render-signature-cache
                               :viewport-height-dependent-subtree-cache
                               :flex-content-min-widths))
                  (plist-put state key (make-hash-table :test 'eq)))
                (ebox-incremental--isolate-candidate-caches state)))
             (prepared
              (list :root (plist-get old-state :root-node)
                    :dirty-set dirty-set
                    :display-signature display-signature
                    :scroll-state-table candidate-scroll-table))
             (report-overrides
              (append (ebox--constraint-change-report-props change)
                      (list :viewport-axes axes
                            :host-context-changed display-changed
                            :target-viewport-width viewport-width
                            :target-viewport-height target-height)))
             owner-plan report projection-kind scroll-partition
             viewport-reflow-safe-p spatial-reuse-safe-p native-continuity-p)
        (plist-put candidate-state :viewport-width viewport-width)
        (plist-put candidate-state :viewport-height target-height)
        (plist-put candidate-state :display-signature display-signature)
        ;; Retaining logical objects does not authorize spatial reuse.
        ;; Affected producers still own fresh geometry and scroll effects.
        (plist-put candidate-state :layout-fragments-reuse-p nil)
        (plist-put candidate-state :runtime-revision
                   (1+ (or (plist-get old-state :runtime-revision) 0)))
        (plist-put candidate-state :region-box-table
                   (copy-hash-table
                    (plist-get old-state :region-box-table)))
        (plist-put candidate-state :scroll-state-table candidate-scroll-table)
        (setq owner-plan
              (if (or display-changed (not style-context-stable-p))
                  ;; Old overflow and intrinsic-size facts cannot prove a
                  ;; local owner after the display or cascade changed.
                  ;; Recompute through the complete canonical root instead
                  ;; of measuring a detached subtree against stale ancestry.
                  (ebox-incremental--root-owner-plan buffer dirty-set)
                (ebox-incremental--layout-owner-plan
                 buffer old-state candidate-state dirty-set))
              report
              (ebox-incremental--plist-overlay
               (ebox-incremental--layout-owner-report
                prepared owner-plan candidate-state)
               report-overrides))
        (setq viewport-reflow-safe-p
              (and (not display-changed)
                   (ebox-incremental--viewport-reflow-safe-p
                    old-state candidate-state dirty-set owner-plan
                    style-context-stable-p)))
        (when viewport-reflow-safe-p
          (setq scroll-partition
                (ebox-incremental--viewport-scroll-partition candidate-state)
                spatial-reuse-safe-p
                (or (null (plist-get scroll-partition :affected))
                    (ebox-incremental--viewport-root-scroll-reflow-proof-p
                     old-state candidate-state style-context-stable-p))))
        (setq native-continuity-p
              (and viewport-reflow-safe-p spatial-reuse-safe-p
                   (require 'ebox-native-commit nil t)
                   (ebox-native-commit-prepare-viewport-continuity
                    old-state candidate-state)))
        (setq projection-kind
              (cond
               (native-continuity-p 'native-frame)
               (viewport-reflow-safe-p
                (if (and (plist-get scroll-partition :stable)
                         (plist-get scroll-partition :affected))
                    'viewport-reflow-mixed-scroll
                  'viewport-reflow))))
        (when native-continuity-p
          (plist-put candidate-state :native-topology-stable-p t)
          (plist-put candidate-state :native-touched-node-ids nil)
          (plist-put candidate-state :native-removed-node-ids nil)
          (setq owner-plan
                (ebox-incremental--native-frame-plan buffer dirty-set)
                report
                (ebox-incremental--plist-overlay
                 (ebox-incremental--layout-owner-report
                  prepared owner-plan candidate-state)
                 report-overrides)))
        (when (and (memq projection-kind
                         '(viewport-reflow viewport-reflow-mixed-scroll))
                   ;; Preserve the prior spatial permissions: all-stable,
                   ;; sole root scroll, or mixed stable/affected producers.
                   ;; Newly admitted all-affected topology gets none of these.
                   (or spatial-reuse-safe-p
                       (plist-get scroll-partition :stable)))
          (plist-put candidate-state :layout-fragments-reuse-p t))
        (when projection-kind
          (setq report (plist-put report :projection-kind projection-kind))
          (setq report
                (plist-put report :viewport-style-context-stable-p
                           style-context-stable-p))
          (when scroll-partition
            (setq report
                  (plist-put report :viewport-scroll-stable-ids
                             (plist-get scroll-partition :stable)))
            (setq report
                  (plist-put report :viewport-scroll-affected-ids
                             (plist-get scroll-partition :affected)))))
        (list :root (plist-get candidate-state :root-node)
              :scope-node-ids
              (delete-dups
               (or (mapcar (lambda (op) (plist-get op :owner-id)) owner-plan)
                   (mapcar (lambda (entry) (plist-get entry :node-id))
                           dirty-set)))
              :report-base report
              :projection-kind projection-kind
              :state-overrides
              (cond
               ((eq projection-kind 'native-frame)
                (append
                 (ebox-incremental--viewport-state-overrides
                 candidate-state t)
                 (list :native-topology-stable-p t
                       :native-touched-node-ids nil
                       :native-local-dirty-entries nil
                       :native-removed-node-ids nil)))
               ((memq projection-kind
                      '(viewport-reflow viewport-reflow-mixed-scroll))
                (ebox-incremental--viewport-reflow-state-overrides
                 old-state candidate-state scroll-partition))
               (t
                (ebox-incremental--viewport-state-overrides
                 candidate-state))))))))

(defun ebox-incremental--finalize-declarative-scroll-publication
    (scroll-keys &optional prefetch-delay)
  "Retire stale scroll work and resume committed SCROLL-KEYS.
PREFETCH-DELAY is forwarded when a live, inactive scroll region needs warming."
  (let (diagnostics)
    (cl-labels
        ((run (region-id action function)
           (let ((inhibit-quit t)
                 (quit-flag nil))
             (condition-case failure
                 (funcall function)
               ((error quit)
                (push (list :region-id region-id :phase 'scroll-finalization
                            :action action
                            :condition failure)
                      diagnostics))))))
      (dolist (region-id scroll-keys)
        (run region-id 'cancel-prefetch
             (lambda () (ebox--scroll-cancel-idle-prefetch region-id)))
        (if (gethash region-id ebox--scroll-global-state)
            (unless (gethash region-id ebox--smooth-scroll-state-table)
              (run region-id 'schedule-prefetch
                   (lambda ()
                     (ebox--scroll-schedule-idle-prefetch
                      region-id prefetch-delay))))
          (run region-id 'stop-smooth-scroll
               (lambda () (ebox--smooth-scroll-stop region-id))))))
    (nreverse diagnostics)))

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
