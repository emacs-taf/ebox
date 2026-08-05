;;; ebox-buffer-backend.el --- Emacs buffer backend for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns text insertion, text properties, spans, markers, buffer modes, and
;; backend patch primitives.  It does not own computed style semantics.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-fragment)
(require 'ebox-render-context)

(defvar ebox-region-types)
(defvar ebox--box-extents)
(defvar ebox--defer-scroll-content-index)
(defvar ebox--region-box-table)
(defvar ebox--propertize-private-content-line-p nil
  "Non-nil allows ownership to be added to fresh content lines in place.")
(declare-function ebox--buffer-region-role-span-table
                  "ebox-incremental" (buffer))
(declare-function ebox--clear-buffer-extents
                  "ebox" (&optional buffer preserve-template))
(declare-function ebox--install-box-extent-template
                  "ebox" (buffer template start))
(declare-function ebox--preflight-scroll-content-span-template
                  "ebox" (buffer template start target-length))
(declare-function ebox--refresh-patched-scroll-markers
                  "ebox"
                  (buffer affected-region-ids published-spans
                          &optional scroll-content-template root-start))
(declare-function ebox--register-box-extents-in-range
                  "ebox" (start end))
(declare-function ebox--set-box-extents
                  "ebox" (region-id start end))
(declare-function ebox--ensure-node-id
                  "ebox" (node))
(declare-function ebox--region-id-set
                  "ebox" (region-ids))
(declare-function ebox--maplines
                  "ebox" (function string))
(declare-function ebox--string-repeat-lines
                  "ebox" (string count))
(declare-function ebox-render
                  "ebox" (node))
(declare-function ebox-lines-join
                  "ebox" (lines))
(declare-function ebox-string-height
                  "ebox" (string))
(declare-function ebox-string-lines
                  "ebox" (string))
(declare-function ebox--set-buffer-region-role-span-table
                  "ebox-incremental" (buffer table))
(declare-function ebox--external-footprint-compatible-p
                  "ebox-incremental" (old new))
(declare-function ebox--external-footprint-signature-from-span-footprint
                  "ebox-incremental" (signature))
(declare-function ebox--parent-slot-compatible-p
                  "ebox-incremental" (old new))
(declare-function ebox--project-parent-slot-signature
                  "ebox-incremental" (old-parent-slot new-span-footprint))
(declare-function ebox--rendered-span-footprint-signature
                  "ebox-incremental" (rendered))
(declare-function ebox--span-footprint-compatible-p
                  "ebox-incremental" (old new))
(declare-function ebox--runtime-child-under-ancestor
                  "ebox-incremental" (buffer ancestor-id node-id))
(declare-function ebox--dirty-provenance-node-ids
                  "ebox-incremental" (dirty))
(declare-function ebox--buffer-runtime-node
                  "ebox-incremental" (buffer node-id))
(declare-function ebox--buffer-render-state
                  "ebox-incremental" (buffer))
(declare-function ebox--buffer-root-node
                  "ebox-incremental" (buffer))
(declare-function ebox--buffer-root-node-id
                  "ebox-incremental" (buffer))
(declare-function ebox--refresh-buffer-layout-snapshots
                  "ebox-incremental" (buffer &optional details))
(declare-function ebox--ensure-layout-snapshot-details
                  "ebox-incremental" (buffer node-id))
(declare-function ebox--ensure-layout-snapshot-spans
                  "ebox-incremental" (buffer node-id))
(declare-function ebox--runtime-parent-id
                  "ebox-incremental" (buffer node-id))
(declare-function ebox--viewport-height-dependent-subtree-p
                  "ebox-incremental" (node))
(declare-function ebox--owned-overflow-coverage-wrapper-node-p
                  "ebox-incremental" (buffer node-id))
(declare-function ebox--contained-partial-flex-owner-p
                  "ebox-incremental" (buffer node-id))
(declare-function ebox--definite-containment-formatting-context-p
                  "ebox-incremental" (buffer node-id))
(declare-function ebox--render-node-in-current-flex-slot
                  "ebox-incremental"
                  (buffer node-id snapshot &optional changed-keys))
(declare-function ebox--render-cache-probe
                  "ebox-incremental"
                  (node &optional force external-signature))
(declare-function ebox--render-cache-store-context
                  "ebox-incremental" (context rendered &optional metadata))
(declare-function ebox--render-with-cache
                  "ebox-incremental"
                  (node &optional force cache-probe))
(declare-function ebox--flex-render-row-line-for-child
                  "ebox-flex" (node child-id))
(declare-function ebox--flex-render-row-line-for-child-ids
                  "ebox-flex" (node child-ids &optional min-item-main))
(declare-function ebox--flex-item-source-node
                  "ebox-flex" (item))
(declare-function ebox--flex-box-main-constraint
                  "ebox-flex" (box axis property))
(declare-function ebox--wrapper-content-viewport-pixel
                  "ebox-layout" (props))
(declare-function ebox--apply-surface-properties
                  "ebox-layout" (rendered properties))
(declare-function ebox--layout-children "ebox-tree" (node))
(declare-function ebox-get "ebox" (box property))
(declare-function ebox--refresh-buffer-scroll-content-markers
                  "ebox" (buffer))

(defvar ebox-incremental--declarative-commit-buffer)
(defvar ebox--prepared-root-render)
(defvar ebox--scroll-global-state)
(defvar ebox--box-extent-template)
(defvar ebox-viewport-height)
(defvar ebox-viewport-width)

(defvar ebox-buffer-owner-proof-renderer nil
  "Optional renderer used to prepare one owner proof.
The function receives NODE, SNAPSHOT, DIRTY, and a normalized CONTEXT plist.
CONTEXT exposes `:root-owner-p' immediately, a
`:parent-content-width-function' thunk for containing geometry, and a
`:details-function' thunk for the remaining expensive runtime facts.  The
function returns an exact propertized render string when it owns the proof, or
nil when the ordinary Ebox renderer should handle that owner.  This is the
single backend boundary for optional render accelerators; publication and
buffer mutation remain owned by this module.")

(defun ebox-buffer--owner-proof-parent-content-width
    (buffer owner-id viewport-width)
  "Return OWNER-ID's proven containing-box content width in BUFFER."
  (let ((parent-id (ebox--runtime-parent-id buffer owner-id))
        boxes blocked anchor-width)
    (while (and parent-id (not blocked) (not anchor-width))
      (let* ((parent (ebox--buffer-runtime-node buffer parent-id))
             (type (and parent (plist-get parent :ebox-type))))
        (pcase type
          ('stack nil)
          ('box
           (if (memq (ebox-get parent :width)
                     '(min-content max-content))
               (setq blocked t)
             (push parent boxes)
             (let ((ebox-viewport-width nil))
               (setq anchor-width
                     (ebox--wrapper-content-viewport-pixel parent)))))
          (_ (setq blocked t)))
        (setq parent-id (ebox--runtime-parent-id buffer parent-id))))
    (when (and boxes (not blocked))
      (let ((content-width viewport-width))
        (dolist (box boxes content-width)
          (let ((ebox-viewport-width content-width))
            (setq content-width
                  (ebox--wrapper-content-viewport-pixel box))))))))

(defun ebox-buffer--owner-proof-side-effects-safe-p (node)
  "Return non-nil when proof rendering NODE cannot mutate scroll state."
  (cl-labels
      ((safe-p
        (current)
        (and
         (or (not (eq (and (listp current)
                           (plist-get current :ebox-type))
                      'box))
             (let ((region-id (plist-get current :region-id)))
               (and
                (not (and region-id
                          (hash-table-p ebox--scroll-global-state)
                          (gethash region-id ebox--scroll-global-state)))
                (not
                 (and (eq (ebox-get current :overflow) 'scroll)
                      (or (ebox-get current :height)
                          (ebox-get current :max-height)
                          (not (zerop
                                (or (ebox-get current :scroll-offset)
                                    0)))))))))
         (cl-every #'safe-p (ebox--layout-children current)))))
    (safe-p node)))

(defun ebox-buffer--owner-proof-slot-width-placeholder (buffer snapshot)
  "Return a positive non-semantic slot width for SNAPSHOT in BUFFER.
The result is derived only from published buffer spans.  It may carry an
unknown-width native proof frame, but must never become a containing-block
constraint."
  (when (and (buffer-live-p buffer)
             (plist-get snapshot :buffer-spans))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (let ((widths
               (cl-loop for span in (plist-get snapshot :buffer-spans)
                        for width = (ebox-buffer--span-slot-width span)
                        when (> width 0)
                        collect width)))
          (when widths
            (truncate (apply #'min widths))))))))

(defun ebox-buffer--owner-proof-context-details
    (buffer owner-id node snapshot)
  "Return expensive normalized proof facts for OWNER-ID in BUFFER."
  (let* ((state (ebox--buffer-render-state buffer))
         (viewport-width
          (or (and state (plist-get state :viewport-width))
              ebox-viewport-width))
         (viewport-height
          (or (and state (plist-get state :viewport-height))
              ebox-viewport-height))
         (parent-content-width
          (ebox-buffer--owner-proof-parent-content-width
           buffer owner-id viewport-width)))
    (list :viewport-width viewport-width
          :viewport-height viewport-height
          :runtime-revision
          (or (and state (plist-get state :runtime-revision)) 0)
          :viewport-height-dependent-p
          (ebox--viewport-height-dependent-subtree-p node)
          :parent-content-width parent-content-width
          :slot-width-placeholder
          (unless (and (numberp parent-content-width)
                       (> parent-content-width 0))
            (ebox-buffer--owner-proof-slot-width-placeholder buffer snapshot))
          :side-effects-safe-p
          (ebox-buffer--owner-proof-side-effects-safe-p node))))

(defun ebox-buffer--owner-proof-context
    (buffer owner-id node snapshot root-owner-p)
  "Return lazy normalized accelerator context for OWNER-ID in BUFFER."
  (let (details details-ready-p parent-width parent-width-ready-p)
    (list
     :root-owner-p root-owner-p
     :parent-content-width-function
     (lambda ()
       (unless parent-width-ready-p
         (let* ((state (ebox--buffer-render-state buffer))
                (viewport-width
                 (or (and state (plist-get state :viewport-width))
                     ebox-viewport-width)))
           (setq parent-width
                 (ebox-buffer--owner-proof-parent-content-width
                  buffer owner-id viewport-width)
                 parent-width-ready-p t)))
       parent-width)
     :details-function
     (lambda ()
       (unless details-ready-p
         (setq details
               (ebox-buffer--owner-proof-context-details
                buffer owner-id node snapshot)
               parent-width (plist-get details :parent-content-width)
               parent-width-ready-p t
               details-ready-p t))
       details))))

(defun ebox-buffer--owner-cache-probe (node context)
  "Return NODE's ordinary or exact owner cache probe using CONTEXT."
  (let ((ordinary (ebox--render-cache-probe node)))
    (if (and ordinary (plist-member ordinary :rendered))
        ordinary
      (let* ((details
              (funcall (plist-get context :details-function)))
             (parent-width (plist-get details :parent-content-width)))
        (if (and (numberp parent-width) (> parent-width 0))
            (let ((exact
                   (ebox--render-cache-probe
                    node nil (list 'owner-context parent-width))))
              (if (and exact (plist-member exact :rendered))
                  exact
                (or ordinary exact)))
          ordinary)))))

(defun ebox-buffer--render-owner-for-rerender
    (buffer owner-id node snapshot dirty root-owner-p)
  "Render OWNER-ID for rerender through the single owner proof boundary."
  (if (ebox--definite-containment-formatting-context-p buffer owner-id)
      (ebox-render node)
    (or (ebox--render-node-in-current-flex-slot
         buffer owner-id snapshot (plist-get dirty :changed-keys))
      (let* ((context
              (and (not root-owner-p)
                   (ebox-buffer--owner-proof-context
                    buffer owner-id node snapshot nil)))
             (probe
              (if root-owner-p
                  (and (null ebox--prepared-root-render)
                       (ebox--render-cache-probe node t))
                (ebox-buffer--owner-cache-probe node context))))
        (if (and probe (plist-member probe :rendered))
            (plist-get probe :rendered)
          (let* ((context
                  (or context
                      (and ebox-buffer-owner-proof-renderer
                           (ebox-buffer--owner-proof-context
                            buffer owner-id node snapshot t))))
                 (rendered
                  (and ebox-buffer-owner-proof-renderer
                       context
                       (funcall ebox-buffer-owner-proof-renderer
                                node snapshot dirty context))))
            (if (not rendered)
                (let* ((parent-width
                        (and context
                             (funcall
                              (plist-get
                               context
                               :parent-content-width-function))))
                       (ebox-viewport-width
                        (if (and (numberp parent-width)
                                 (> parent-width 0))
                            parent-width
                          ebox-viewport-width)))
                  (ebox--render-with-cache node root-owner-p probe))
              (when (and probe
                         (plist-get
                          (funcall (plist-get context :details-function))
                          :side-effects-safe-p))
                (ebox--render-cache-store-context probe rendered))
              rendered)))))))

;;; Window State

(defvar ebox-buffer--window-state-preserved-buffer nil
  "Buffer whose point and windows are preserved by the outer transaction.")

(defun ebox--content-owner-ids-at (pos)
  "Return Ebox content owners at POS, ordered from inner to outer.
When POS is an unowned boundary such as `point-max', inspect the preceding
character so a point at the end of owned content keeps its stable anchor."
  (let* ((pos (min (max pos (point-min)) (point-max)))
         (owners-at
          (lambda (position)
            (let ((owners
                   (copy-sequence
                    (or (get-text-property
                         position 'ebox-content-owners)
                        nil)))
                  (owner
                   (get-text-property position 'ebox-content-owner)))
              (when (and owner (not (member owner owners)))
                (setq owners (append owners (list owner))))
              owners))))
    (or (funcall owners-at pos)
        (when (> pos (point-min))
          (funcall owners-at (1- pos))))))

(defun ebox--position-owned-by-content-region-p (pos region-id)
  "Return non-nil when the content at POS is owned by REGION-ID."
  (or (equal (get-text-property pos 'ebox-content-owner) region-id)
      (member region-id
              (get-text-property pos 'ebox-content-owners))))

(defvar ebox--content-owner-runs-cache nil
  "Per-transaction cache of content owner runs, or nil when inactive.
When non-nil, a hash table keyed by region id.  Each entry records the
buffer, its `buffer-modified-tick', and the restriction it was computed
under, so any text or property edit invalidates the entry without
explicit bookkeeping.  Bound by
`ebox--with-preserved-buffer-window-state' so one capture/restore pass
walks each owner's runs at most once per buffer state.")

(defun ebox--next-content-ownership-change (position limit)
  "Return the next position before LIMIT where content ownership can change."
  (min (or (next-single-property-change
            position 'ebox-content-owner nil limit)
           limit)
       (or (next-single-property-change
            position 'ebox-content-owners nil limit)
           limit)))

(defun ebox--compute-content-owner-runs (region-id)
  "Compute maximal buffer runs owned by content REGION-ID."
  (let ((position (point-min))
        (limit (point-max))
        run-start runs)
    (while (< position limit)
      (let ((next (ebox--next-content-ownership-change position limit))
            (owned-p
             (ebox--position-owned-by-content-region-p position region-id)))
        (cond
         ((and owned-p (null run-start))
          (setq run-start position))
         ((and (not owned-p) run-start)
          (push (cons run-start position) runs)
          (setq run-start nil)))
        (setq position next)))
    (when run-start
      (push (cons run-start limit) runs))
    (nreverse runs)))

(defun ebox--content-owner-runs (region-id)
  "Return maximal buffer runs owned by content REGION-ID.
Callers must not mutate the returned list: it may be shared through
`ebox--content-owner-runs-cache' within one preservation transaction."
  (let ((cache ebox--content-owner-runs-cache))
    (if (null cache)
        (ebox--compute-content-owner-runs region-id)
      (let ((entry (gethash region-id cache)))
        (if (and entry
                 (eq (nth 0 entry) (current-buffer))
                 (= (nth 1 entry) (buffer-modified-tick))
                 (= (nth 2 entry) (point-min))
                 (= (nth 3 entry) (point-max)))
            (nth 4 entry)
          (let ((runs (ebox--compute-content-owner-runs region-id)))
            (puthash region-id
                     (list (current-buffer) (buffer-modified-tick)
                           (point-min) (point-max) runs)
                     cache)
            runs))))))

(defun ebox--content-owner-run-anchor-at (region-id pos)
  "Return REGION-ID run ordinal and intra-run offset for POS."
  (let* ((pos (min (max pos (point-min)) (point-max)))
         (probe
          (if (ebox--position-owned-by-content-region-p pos region-id)
              pos
            (and (> pos (point-min)) (1- pos))))
         (runs (ebox--content-owner-runs region-id))
         (index 0)
         found)
    (while (and probe runs (not found))
      (let ((run (pop runs)))
        (if (and (<= (car run) probe) (< probe (cdr run)))
            (setq found (list index (- pos (car run))))
          (cl-incf index))))
    found))

(defun ebox--resolve-content-owner-run-anchor (region-id run-index offset)
  "Resolve REGION-ID RUN-INDEX and intra-run OFFSET in the current buffer."
  (when-let ((run (nth run-index (ebox--content-owner-runs region-id))))
    (min (+ (car run) offset) (cdr run))))

(defun ebox--line-occurrence-before (line line-start)
  "Count full lines equal to LINE that begin before position LINE-START."
  (let ((regexp (concat "^" (regexp-quote line) "$"))
        (case-fold-search nil)
        (search-spaces-regexp nil)
        (occurrence 0))
    (save-excursion
      (goto-char (point-min))
      (while (and (< (point) line-start)
                  (re-search-forward regexp line-start t)
                  (< (match-beginning 0) line-start))
        (cl-incf occurrence)
        (forward-line 1)))
    occurrence))

(defun ebox--line-anchor-at (pos)
  "Return a stable owner-first line anchor for POS in the current buffer.
The `:occurrence' index is captured only when POS yields no owner-run
anchor, because a captured owner run resolves without consulting the
line-text fallback; when an owner run is captured but later fails to
resolve, the fallback targets the first matching line."
  (save-restriction
    (widen)
    (let* ((pos (min (max pos (point-min)) (point-max)))
           (line-start (save-excursion
                         (goto-char pos)
                         (line-beginning-position)))
           (line-end (save-excursion
                       (goto-char pos)
                       (line-end-position)))
           (line (buffer-substring-no-properties line-start line-end))
           (column (- pos line-start))
           (owner-run-anchors
            (delq
             nil
             (mapcar
              (lambda (region-id)
                (when-let ((run-anchor
                            (ebox--content-owner-run-anchor-at
                             region-id pos)))
                  (list region-id
                        (car run-anchor)
                        (cadr run-anchor))))
              (ebox--content-owner-ids-at pos)))))
      (list :position pos
            :owner-run-anchors owner-run-anchors
            :line line
            :column column
            :occurrence (if owner-run-anchors
                            0
                          (ebox--line-occurrence-before line line-start))))))

(defun ebox--resolve-line-anchor (anchor)
  "Resolve ANCHOR in the current buffer after text replacement."
  (save-restriction
    (widen)
    (let ((line (plist-get anchor :line))
          (occurrence (plist-get anchor :occurrence))
          (column (plist-get anchor :column))
          (seen 0)
          found)
      (dolist (owner-anchor (plist-get anchor :owner-run-anchors))
        (unless found
          (setq found
                (ebox--resolve-content-owner-run-anchor
                 (nth 0 owner-anchor)
                 (nth 1 owner-anchor)
                 (nth 2 owner-anchor)))))
      (unless found
        (save-excursion
          (goto-char (point-min))
          (while (and (not found) (not (eobp)))
            (when (equal (buffer-substring-no-properties
                          (line-beginning-position)
                          (line-end-position))
                         line)
              (if (= seen occurrence)
                  (setq found (min (+ (line-beginning-position) column)
                                   (line-end-position)))
                (cl-incf seen)))
            (forward-line 1))))
      (or found
          (min (max (plist-get anchor :position) (point-min))
               (point-max))))))

(defun ebox--capture-buffer-window-state (buffer)
  "Capture point, start, and horizontal scroll for live windows showing BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (mapcar (lambda (window)
                (list :window window
                      :point (ebox--line-anchor-at (window-point window))
                      :start (ebox--line-anchor-at (window-start window))
                      :hscroll (window-hscroll window)))
              (get-buffer-window-list buffer nil t)))))

(defun ebox--restore-buffer-window-state (buffer states)
  "Restore captured window STATES for BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (dolist (state states)
        (let ((window (plist-get state :window)))
          (when (and (window-live-p window)
                     (eq (window-buffer window) buffer))
            (set-window-start
             window (ebox--resolve-line-anchor (plist-get state :start)) t)
            (set-window-point
             window (ebox--resolve-line-anchor (plist-get state :point)))
            (set-window-hscroll window (plist-get state :hscroll))))))))

(defmacro ebox--with-preserved-buffer-window-state (buffer &rest body)
  "Evaluate BODY while preserving BUFFER point and showing windows."
  (declare (indent 1) (debug t))
  `(let ((ebox--window-state-buffer ,buffer))
     (if (eq ebox-buffer--window-state-preserved-buffer
             ebox--window-state-buffer)
         (progn ,@body)
       (let* ((ebox--content-owner-runs-cache (make-hash-table :test #'equal))
              (ebox--window-states
               (ebox--capture-buffer-window-state ebox--window-state-buffer))
              (ebox--buffer-point-anchor
               (when (buffer-live-p ebox--window-state-buffer)
                 (with-current-buffer ebox--window-state-buffer
                   (ebox--line-anchor-at (point)))))
              (ebox--selected-window (selected-window))
              (ebox--current-buffer (current-buffer)))
         (let ((ebox-buffer--window-state-preserved-buffer
                ebox--window-state-buffer))
           (unwind-protect
               (progn ,@body)
             (when (and (buffer-live-p ebox--window-state-buffer)
                        ebox--buffer-point-anchor)
               (with-current-buffer ebox--window-state-buffer
                 (goto-char
                  (ebox--resolve-line-anchor ebox--buffer-point-anchor))))
             (ebox--restore-buffer-window-state
              ebox--window-state-buffer ebox--window-states)
             (when (window-live-p ebox--selected-window)
               (select-window ebox--selected-window))
             (when (buffer-live-p ebox--current-buffer)
               (set-buffer ebox--current-buffer))))))))

(defun ebox-buffer--native-root-patch-map-offset (offset patches)
  "Map root-relative old OFFSET through native PATCHES."
  (let ((delta 0)
        mapped)
    (catch 'mapped
      (dolist (patch patches)
        (let* ((old-start (plist-get patch :old-start))
               (old-end (plist-get patch :old-end))
               (new-start (plist-get patch :new-start))
               (new-end (plist-get patch :new-end)))
          (cond
           ((< offset old-start)
            (setq mapped (+ offset delta))
            (throw 'mapped nil))
           ((<= offset old-end)
            (setq mapped
                  (if (= offset old-end)
                      new-end
                    (+ new-start
                       (min (max 0 (- offset old-start))
                            (- new-end new-start)))))
            (throw 'mapped nil))
           (t
            (setq delta (+ delta (- (- new-end new-start)
                                    (- old-end old-start))))))))
      (setq mapped (+ offset delta)))
    mapped))

(defun ebox-buffer--role-span-containing-position
    (spans pos &optional left-edge-p)
  "Return the indexed role span in SPANS containing POS.
When LEFT-EDGE-P is non-nil, allow POS at a span end."
  (let ((index 0)
        found)
    (while (and spans (not found))
      (let* ((span (ebox-buffer--numeric-role-span (car spans)))
             (start (car-safe span))
             (end (cdr-safe span)))
        (when (and span
                   (or (and (<= start pos) (< pos end))
                       (and left-edge-p (> pos start) (= pos end))))
          (setq found (list :run-index index
                            :start start
                            :end end
                            :offset (- pos start))))
        (setq spans (cdr spans)
              index (1+ index))))
    found))

(defun ebox-buffer--native-root-patch-anchor (pos plan)
  "Return a prepared native patch window anchor for POS."
  (let* ((root-start (plist-get plan :start))
         (root-end (plist-get plan :end))
         (clamped (min (max pos root-start) root-end))
         (probe (if (and (= clamped root-end) (> clamped root-start))
                    (1- clamped)
                  clamped))
         (left-edge-p (or (= clamped root-end)
                          (not (ebox--content-owner-ids-at clamped))))
         (table (ebox-buffer--region-role-span-table))
         owner owner-anchor)
    (when table
      (dolist (region-id (ebox--content-owner-ids-at probe))
        (unless owner-anchor
          (when-let ((span-anchor
                      (ebox-buffer--role-span-containing-position
                       (gethash
                        (ebox-buffer--region-role-key region-id 'content-owner)
                        table)
                       clamped left-edge-p)))
            (setq owner region-id
                  owner-anchor span-anchor)))))
    (list :position clamped
          :root-offset (- clamped root-start)
          :owner owner
          :run-index (plist-get owner-anchor :run-index)
          :owner-offset (plist-get owner-anchor :offset))))

(defun ebox-buffer--resolve-native-root-patch-anchor (anchor plan)
  "Resolve prepared native patch ANCHOR after PLAN has been published."
  (let* ((root-start (plist-get plan :start))
         (target-count (plist-get plan :target-character-count))
         (owner (plist-get anchor :owner))
         (run-index (plist-get anchor :run-index))
         (owner-offset (plist-get anchor :owner-offset))
         (target-table (plist-get plan :prepared-role-table))
         (target-spans
          (and owner (hash-table-p target-table)
               (gethash
                (ebox-buffer--region-role-key owner 'content-owner)
                target-table)))
         (target-span (and (natnump run-index)
                           (nth run-index target-spans))))
    (if-let ((span (and target-span
                        (ebox-buffer--numeric-role-span target-span))))
        (min (+ (car span) owner-offset) (cdr span))
      (+ root-start
         (min (max 0
                   (ebox-buffer--native-root-patch-map-offset
                    (plist-get anchor :root-offset)
                    (plist-get plan :patches)))
              target-count)))))

(defun ebox-buffer--capture-native-root-patch-window-state (buffer plan)
  "Capture BUFFER point and live windows for native patch PLAN."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((capture
             (lambda (window)
               (list :window window
                     :point (ebox-buffer--native-root-patch-anchor
                             (window-point window) plan)
                     :start (ebox-buffer--native-root-patch-anchor
                             (window-start window) plan)
                     :hscroll (window-hscroll window)))))
        (list :point (ebox-buffer--native-root-patch-anchor (point) plan)
              :windows (mapcar capture
                               (get-buffer-window-list buffer nil t)))))))

(defun ebox-buffer--restore-native-root-patch-window-state (buffer plan state)
  "Restore native patch window STATE for BUFFER after PLAN publication."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (goto-char
       (ebox-buffer--resolve-native-root-patch-anchor
        (plist-get state :point) plan))
      (dolist (window-state (plist-get state :windows))
        (let ((window (plist-get window-state :window)))
          (when (and (window-live-p window)
                     (eq (window-buffer window) buffer))
            (set-window-start
             window
             (ebox-buffer--resolve-native-root-patch-anchor
              (plist-get window-state :start) plan)
             t)
            (set-window-point
             window
             (ebox-buffer--resolve-native-root-patch-anchor
              (plist-get window-state :point) plan))
            (set-window-hscroll window
                                (plist-get window-state :hscroll))))))))

(defun ebox-buffer--resolve-source-window-anchor (anchor)
  "Resolve source-state ANCHOR after rollback."
  (min (max (plist-get anchor :position) (point-min)) (point-max)))

(defun ebox-buffer--restore-source-window-state (buffer state)
  "Restore BUFFER window STATE in the original source buffer coordinates."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (goto-char (ebox-buffer--resolve-source-window-anchor
                  (plist-get state :point)))
      (dolist (window-state (plist-get state :windows))
        (let ((window (plist-get window-state :window)))
          (when (and (window-live-p window)
                     (eq (window-buffer window) buffer))
            (set-window-start
             window
             (ebox-buffer--resolve-source-window-anchor
              (plist-get window-state :start))
             t)
            (set-window-point
             window
             (ebox-buffer--resolve-source-window-anchor
              (plist-get window-state :point)))
            (set-window-hscroll window
                                (plist-get window-state :hscroll))))))))

(defmacro ebox-buffer--with-native-root-patch-window-state
    (buffer plan &rest body)
  "Evaluate BODY while preserving BUFFER windows through native root PLAN."
  (declare (indent 2) (debug t))
  `(let ((ebox-buffer--native-window-buffer ,buffer))
     (if (eq ebox-buffer--window-state-preserved-buffer
             ebox-buffer--native-window-buffer)
         (progn ,@body)
       (let ((ebox-buffer--native-window-plan ,plan)
             (ebox-buffer--selected-window (selected-window))
             (ebox-buffer--current-buffer (current-buffer))
             (ebox-buffer--native-window-completed-p nil))
         (let ((ebox-buffer--native-window-state
                (ebox-buffer--capture-native-root-patch-window-state
                 ebox-buffer--native-window-buffer
                 ebox-buffer--native-window-plan))
               (ebox-buffer--window-state-preserved-buffer
                ebox-buffer--native-window-buffer))
           (unwind-protect
               (prog1 (progn ,@body)
                 (setq ebox-buffer--native-window-completed-p t))
             (if ebox-buffer--native-window-completed-p
                 (ebox-buffer--restore-native-root-patch-window-state
                  ebox-buffer--native-window-buffer
                  ebox-buffer--native-window-plan
                  ebox-buffer--native-window-state)
               (ebox-buffer--restore-source-window-state
                ebox-buffer--native-window-buffer
                ebox-buffer--native-window-state))
             (when (window-live-p ebox-buffer--selected-window)
               (select-window ebox-buffer--selected-window))
             (when (buffer-live-p ebox-buffer--current-buffer)
               (set-buffer ebox-buffer--current-buffer))))))))

;;; Render Transaction

(defvar ebox-render-gc-cons-threshold (* 128 1024 1024)
  "Temporary `gc-cons-threshold' used during Ebox render transactions.
Set this to nil to leave `gc-cons-threshold' unchanged.")

(defvar ebox-deferred-render-gc-cons-threshold 'auto
  "Temporary `gc-cons-threshold' used across interactive render bursts.
The default `auto' uses a bounded fraction of physical memory so visible frames
can favor throughput without assuming every machine has the same headroom.
Set this to a byte count for a fixed budget, or nil to leave the setting alone.")

(defvar ebox-deferred-render-gc-auto-min-threshold (* 128 1024 1024)
  "Minimum interactive render allocation budget selected by `auto'.")

(defvar ebox-deferred-render-gc-auto-max-threshold (* 512 1024 1024)
  "Maximum interactive render allocation budget selected by `auto'.")

(defvar ebox-deferred-render-gc-auto-memory-fraction (/ 1.0 32.0)
  "Fraction of physical memory available to an interactive render burst.")

(defvar ebox--physical-memory-bytes 'unknown
  "Cached physical memory size used by automatic render GC tuning.")

(defun ebox--darwin-physical-memory-bytes ()
  "Return macOS physical memory in bytes, or nil when unavailable."
  (when (eq system-type 'darwin)
    (when-let ((sysctl (executable-find "sysctl")))
      (with-temp-buffer
        (when (zerop (call-process sysctl nil t nil "-n" "hw.memsize"))
          (goto-char (point-min))
          (when (looking-at "[0-9]+")
            (string-to-number (match-string 0))))))))

(defun ebox--physical-memory-bytes ()
  "Return local physical memory in bytes, or nil when unavailable."
  (when (eq ebox--physical-memory-bytes 'unknown)
    (setq ebox--physical-memory-bytes
          (or (when-let ((info
                          (and (fboundp 'memory-info)
                               (let ((default-directory
                                      temporary-file-directory))
                                 (memory-info)))))
                (* 1024 (car info)))
              (ebox--darwin-physical-memory-bytes)
              'unavailable)))
  (unless (eq ebox--physical-memory-bytes 'unavailable)
    ebox--physical-memory-bytes))

(defun ebox--effective-deferred-render-gc-cons-threshold ()
  "Return the byte threshold for the current interactive render burst."
  (pcase ebox-deferred-render-gc-cons-threshold
    ('auto
     (let* ((minimum (max 1 ebox-deferred-render-gc-auto-min-threshold))
            (maximum
             (max minimum ebox-deferred-render-gc-auto-max-threshold))
            (physical-memory (ebox--physical-memory-bytes))
            (scaled
             (and physical-memory
                  (floor (* physical-memory
                            ebox-deferred-render-gc-auto-memory-fraction)))))
       (max minimum (min maximum (or scaled minimum)))))
    ((pred numberp) ebox-deferred-render-gc-cons-threshold)
    (_ nil)))

(defvar ebox-render-gc-cons-percentage 0.6
  "Temporary `gc-cons-percentage' used during Ebox render transactions.
Set this to nil to leave `gc-cons-percentage' unchanged.")

(defmacro ebox--with-render-gc (&rest body)
  "Evaluate BODY with GC tuned for one Ebox render transaction."
  (declare (indent 0) (debug t))
  `(let ((gc-cons-threshold
          (if (numberp ebox-render-gc-cons-threshold)
              (max gc-cons-threshold ebox-render-gc-cons-threshold)
            gc-cons-threshold))
         (gc-cons-percentage
          (if (numberp ebox-render-gc-cons-percentage)
              (max gc-cons-percentage ebox-render-gc-cons-percentage)
            gc-cons-percentage)))
     ,@body))

(defvar ebox--deferred-render-gc-state nil
  "Saved GC settings while an interactive render transaction is settling.")

(defvar ebox--deferred-render-gc-timer nil
  "Timer used to restore GC settings after interactive rendering settles.")

(defvar ebox--deferred-render-gc-depth 0
  "Number of overlapping interactive render bursts that still own GC defer.")

(defun ebox--deferred-render-gc-restore ()
  "Restore GC settings saved by `ebox--with-deferred-render-gc'."
  (let ((state ebox--deferred-render-gc-state))
    (setq ebox--deferred-render-gc-state nil)
    (setq ebox--deferred-render-gc-timer nil)
    (setq ebox--deferred-render-gc-depth 0)
    (when state
      (setq gc-cons-threshold
            (plist-get state :gc-cons-threshold))
      (setq gc-cons-percentage
            (plist-get state :gc-cons-percentage))
      (garbage-collect))))

(defun ebox--deferred-render-gc-enter ()
  "Raise GC settings for an interactive render transaction."
  (cl-incf ebox--deferred-render-gc-depth)
  (unless ebox--deferred-render-gc-state
    (setq ebox--deferred-render-gc-state
          (list :gc-cons-threshold gc-cons-threshold
                :gc-cons-percentage gc-cons-percentage)))
  (when-let ((threshold
              (ebox--effective-deferred-render-gc-cons-threshold)))
    (setq gc-cons-threshold threshold))
  (when (numberp ebox-render-gc-cons-percentage)
    (setq gc-cons-percentage
          (max gc-cons-percentage ebox-render-gc-cons-percentage)))
  (when (timerp ebox--deferred-render-gc-timer)
    (cancel-timer ebox--deferred-render-gc-timer)
    (setq ebox--deferred-render-gc-timer nil)))

(defun ebox--deferred-render-gc-raise-threshold (threshold)
  "Raise an active interactive burst allocation budget to THRESHOLD."
  (when (and ebox--deferred-render-gc-state
             (numberp threshold))
    (setq gc-cons-threshold (max gc-cons-threshold threshold))))

(defun ebox--deferred-render-gc-set-threshold (threshold)
  "Set the active burst budget to THRESHOLD without lowering its saved value."
  (when (and ebox--deferred-render-gc-state
             (numberp threshold))
    (setq gc-cons-threshold
          (max (plist-get ebox--deferred-render-gc-state :gc-cons-threshold)
               threshold))))

(defun ebox--deferred-render-gc-schedule-restore ()
  "Restore deferred GC settings after a short settling delay."
  (when (> ebox--deferred-render-gc-depth 0)
    (cl-decf ebox--deferred-render-gc-depth))
  (when (and (zerop ebox--deferred-render-gc-depth)
             ebox--deferred-render-gc-state)
    (when (timerp ebox--deferred-render-gc-timer)
      (cancel-timer ebox--deferred-render-gc-timer))
    (setq ebox--deferred-render-gc-timer
          (run-at-time 0.2 nil #'ebox--deferred-render-gc-restore))))

(defmacro ebox--with-deferred-render-gc (&rest body)
  "Evaluate BODY with render GC settings restored after idle redisplay.
This is for interactive UI commands where restoring the default GC threshold
immediately after BODY can trigger GC before the updated buffer is visible."
  (declare (indent 0) (debug t))
  `(progn
     (ebox--deferred-render-gc-enter)
     (unwind-protect
         (progn ,@body)
       (ebox--deferred-render-gc-schedule-restore))))

;;; Paint Mapping

(defun ebox-buffer--paint-color (style role)
  "Return the foreground paint color for STYLE and ROLE."
  (or (plist-get style :color)
      (and (memq role '(border border-top border-right border-bottom border-left))
           (or (plist-get style :border-color)
               (plist-get style :border-top-color)
               (plist-get style :border-right-color)
               (plist-get style :border-bottom-color)
               (plist-get style :border-left-color)))))

(defun ebox-buffer--paint-background-color (style role)
  "Return the background paint color for STYLE and ROLE."
  (unless (memq role '(border border-top border-right border-bottom border-left))
    (or (plist-get style :background-color)
        (plist-get style :bgcolor))))

(defun ebox-buffer-paint-text-properties (style role)
  "Return Emacs text properties for computed STYLE in paint ROLE.
This backend mapper intentionally accepts computed style facts and emits only
buffer-facing paint properties.  Layout-only properties never pass through."
  (let ((face nil))
    (when-let ((foreground (ebox-buffer--paint-color style role)))
      (setq face (plist-put face :foreground foreground)))
    (when-let ((background (ebox-buffer--paint-background-color style role)))
      (setq face (plist-put face :background background)))
    (when face
      (list 'face face))))

;;; Text Property Helpers

(defun ebox-buffer-side-border-face (color)
  "Return the canonical Emacs face for a side border with COLOR."
  (if color
      `(:background ,color)
    '(:inverse-video t)))

(defun ebox--pixel-border (pixel-width height &optional color)
  "Generate a border line of PIXEL-WIDTH and HEIGHT."
  (when (and pixel-width height (> pixel-width 0) (> height 0))
    (let ((line (propertize " "
                            'face (ebox-buffer-side-border-face color)
                            'display `(space :width (,pixel-width)))))
      (ebox--string-repeat-lines line height))))

(defun ebox--propertize-bgcolor (string bgcolor)
  "Apply background color BGCOLOR to STRING."
  (let* ((string (copy-sequence string))
         (length (length string)))
    (add-face-text-property 0 length `(:background ,bgcolor) t string)
    string))

(defun ebox--propertize-color (string color)
  "Apply foreground COLOR to STRING."
  (let* ((string (copy-sequence string))
         (length (length string)))
    (add-face-text-property 0 length `(:foreground ,color) t string)
    string))

(defun ebox--propertize-colors (string color bgcolor)
  "Apply foreground COLOR and background BGCOLOR to one copy of STRING."
  (let* ((string (copy-sequence string))
         (length (length string)))
    (when color
      (add-face-text-property 0 length `(:foreground ,color) t string))
    (when bgcolor
      (add-face-text-property 0 length `(:background ,bgcolor) t string))
    string))

(defun ebox--propertize-overline (string &optional color)
  "Apply overline to STRING with optional COLOR."
  (let ((string (copy-sequence string)))
    (add-face-text-property
     0 (length string) `(:overline ,(or color t)) t string)
    string))

(defun ebox--propertize-underline (string &optional color)
  "Apply underline to STRING with optional COLOR."
  (let ((string (copy-sequence string)))
    (add-face-text-property
     0 (length string)
     `(:underline (:position t ,@(when color `(:color ,color))))
     t string)
    string))

(defun ebox--propertize-region (string property region-id)
  "Add PROPERTY with REGION-ID to each line of STRING."
  (when string
    (ebox--maplines
     (lambda (line) (propertize line property region-id))
     string)))

(defun ebox--content-owner-stack-at (string pos)
  "Return the existing owner stack in STRING at POS, inner to outer."
  (let ((owners (copy-sequence
                 (or (get-text-property pos 'ebox-content-owners string)
                     nil)))
        (owner (get-text-property pos 'ebox-content-owner string)))
    (if (and owner (not (member owner owners)))
        (append owners (list owner))
      owners)))

(defun ebox--next-content-owner-property-change
    (pos string limit &optional complete-stack-p)
  "Return next owner metadata change in STRING after POS before LIMIT.
When COMPLETE-STACK-P is non-nil, `ebox-content-owners' already contains the
current direct owner, so only a stack change can affect the next output run."
  (let ((next limit))
    (dolist (prop (if complete-stack-p
                      '(ebox-content-owners)
                    '(ebox-content-owner ebox-content-owners)))
      (let ((change (next-single-property-change pos prop string limit)))
        (when (and change (< change next))
          (setq next change))))
    next))

(defun ebox--add-content-owner! (string region-id)
  "Destructively append REGION-ID to STRING's content owner stack."
  (let ((length (length string)))
    (unless (= length 0)
      (let ((owner (get-text-property 0 'ebox-content-owner string))
            (owners-prop (get-text-property 0 'ebox-content-owners string)))
        (if (and (not (text-property-not-all
                       0 length 'ebox-content-owner owner string))
                 (not (text-property-not-all
                       0 length 'ebox-content-owners owners-prop string)))
            (let ((owners (copy-sequence (or owners-prop nil))))
              (when (and owner (not (member owner owners)))
                (setq owners (append owners (list owner))))
              (unless (member region-id owners)
                (setq owners (append owners (list region-id))))
              (add-text-properties
               0 length
               (list 'ebox-content-owner region-id
                     'ebox-content-owners owners)
               string))
          (let ((pos 0)
                next owners)
            (while (< pos length)
              (let* ((owner (get-text-property
                             pos 'ebox-content-owner string))
                     (owners-prop (get-text-property
                                   pos 'ebox-content-owners string))
                     (complete-stack-p
                      (and owners-prop (member owner owners-prop))))
                (setq next (ebox--next-content-owner-property-change
                            pos string length complete-stack-p))
                (setq owners
                      (if complete-stack-p
                          owners-prop
                        (ebox--content-owner-stack-at string pos))))
              (unless (member region-id owners)
                (setq owners (append owners (list region-id))))
              (add-text-properties pos next
                                   (list 'ebox-content-owner region-id
                                         'ebox-content-owners owners)
                                   string)
              (setq pos next))))))
    string))

(defun ebox--add-content-owner (string region-id)
  "Return a copy of STRING with REGION-ID appended to its owner stack."
  (ebox--add-content-owner! (copy-sequence string) region-id))

(defun ebox--add-content-owners (string owners)
  "Return STRING with OWNERS appended to its content owner stack."
  (let ((result (copy-sequence string))
        (length (length string)))
    (when (and owners (> length 0))
      (let ((position 0)
            (final-owner (car (last owners))))
        (while (< position length)
          (let* ((owner (get-text-property
                         position 'ebox-content-owner result))
                 (stack (get-text-property
                         position 'ebox-content-owners result))
                 (complete-stack-p (and stack (member owner stack)))
                 (next (ebox--next-content-owner-property-change
                        position result length complete-stack-p)))
            (unless complete-stack-p
              (setq stack
                    (ebox--content-owner-stack-at result position)))
            (dolist (new-owner owners)
              (unless (member new-owner stack)
                (setq stack (append stack (list new-owner)))))
            (add-text-properties
             position next
             (list 'ebox-content-owner final-owner
                   'ebox-content-owners stack)
             result)
            (setq position next)))))
    result))

(defun ebox--propertize-content-line (line region-id idx fallback)
  "Return LINE with region ownership for REGION-ID at content index IDX.
Preserve child `ebox-content' properties and add wrapper ownership through
`ebox-content-owner'.  If LINE has no child content region, use REGION-ID as
the line's direct `ebox-content' owner.  When the current render context marks
LINE as a fresh private allocation, ownership may be added in place."
  (let* ((empty-line-p (string-empty-p line))
         (source (if empty-line-p fallback line))
         (mutate-p (and ebox--propertize-private-content-line-p
                        (not empty-line-p)))
         (line
          (if (and (not (text-property-not-all
                         0 (length source)
                         'ebox-content-owner nil source))
                   (not (text-property-not-all
                         0 (length source)
                         'ebox-content-owners nil source)))
              (let ((copy (if mutate-p source (copy-sequence source))))
                (add-text-properties
                 0 (length copy)
                 (list 'ebox-content-owner region-id
                       'ebox-content-owners (list region-id))
                 copy)
                copy)
            (if mutate-p
                (ebox--add-content-owner! source region-id)
              (ebox--add-content-owner source region-id)))))
    (unless (text-property-not-all 0 (length line)
                                   'ebox-content nil line)
      (add-text-properties 0 (length line)
                           (list 'ebox-content region-id
                                 'ebox-content-idx idx)
                           line))
    line))

;;; Span and Buffer Patch Execution

(defun ebox--copy-string-text-properties-to-buffer (string start)
  "Copy text properties from STRING to buffer text starting at START."
  (dotimes (index (length string))
    (set-text-properties
     (+ start index) (+ start index 1)
     (text-properties-at index string))))

(defconst ebox-buffer--remove-face-key (make-symbol "ebox-remove-face-key")
  "Sentinel used to remove a single face plist key.")

(defun ebox-buffer--face-plist-remove (plist key)
  "Return PLIST without KEY and its value."
  (let (result)
    (while plist
      (let ((current-key (pop plist))
            (current-value (pop plist)))
        (unless (eq current-key key)
          (push current-key result)
          (push current-value result))))
    (nreverse result)))

(defun ebox-buffer--face-put (face key value)
  "Return FACE with KEY set to VALUE, preserving nested face specs."
  (cond
   ((null face)
    (unless (eq value ebox-buffer--remove-face-key)
      (list key value)))
   ((and (listp face) (keywordp (car face)))
    (let ((face (copy-sequence face)))
      (if (eq value ebox-buffer--remove-face-key)
          (ebox-buffer--face-plist-remove face key)
        (plist-put face key value))))
   ((listp face)
    (delq nil
          (mapcar (lambda (item)
                    (ebox-buffer--face-put item key value))
                  face)))
   (t
    (list face (list key value)))))

(defun ebox--patch-face-key-in-span (start end key value)
  "Set FACE KEY to VALUE in START..END without touching other properties."
  (let ((pos start))
    (while (< pos end)
      (let* ((next (or (next-single-property-change pos 'face nil end)
                       end))
             (face (get-text-property pos 'face)))
        (put-text-property pos next 'face
                           (ebox-buffer--face-put face key value))
        (setq pos next)))))

(defun ebox--patch-horizontal-border-face-in-span (start end key value)
  "Set horizontal border FACE KEY to VALUE in START..END.
Enabled horizontal borders are one visual surface over the whole span, so they
can be applied as one high-priority face spec.  Removal still uses the precise
face-key patcher so raw face properties do not retain stale border keys."
  (if (eq value ebox-buffer--remove-face-key)
      (ebox--patch-face-key-in-span start end key value)
    (add-face-text-property start end (list key value) nil)))

(defconst ebox--paint-content-region-roles
  '(content content-owner pt pb pl pr)
  "Region roles whose faces receive content paint properties.")

(defconst ebox--horizontal-border-anchor-roles
  '(content content-owner pt pb pl pr bl br)
  "Region roles that define the box edge excluding margins.")

(defconst ebox-buffer--role-span-table-marker-key
  (make-symbol "ebox-role-span-table-marker-backed")
  "Internal hash key marking role span tables whose spans use markers.")

(defconst ebox-buffer--role-span-table-template-key
  (make-symbol "ebox-role-span-table-prepared-template")
  "Internal hash key marking immutable prepared root role span tables.")

(defun ebox-buffer--role-property (role)
  "Return the text property that stores ROLE ownership."
  (or (alist-get role ebox-region-types)
      (error "Unknown region role: %S" role)))

(defun ebox-buffer--region-role-key (region-id role)
  "Return the runtime span index key for REGION-ID and ROLE."
  (list region-id role))

(defun ebox-buffer--region-role-span-table ()
  "Return the current buffer's runtime region role span table."
  (and (buffer-live-p (current-buffer))
       (ebox--buffer-region-role-span-table (current-buffer))))

(defun ebox-buffer--put-region-role-spans (region-id role spans)
  "Store SPANS for REGION-ID and ROLE in the current buffer span index."
  (when-let ((table (ebox-buffer--region-role-span-table)))
    (when (gethash ebox-buffer--role-span-table-template-key table)
      (ebox-buffer-materialize-region-role-spans (current-buffer))))
  (when-let ((table (ebox-buffer--region-role-span-table)))
    (let ((key (ebox-buffer--region-role-key region-id role)))
      (if spans
          (puthash key
                   (mapcar (lambda (span)
                             (ebox-buffer--make-role-span
                              (car span) (cdr span)))
                           spans)
                   table)
        (remhash key table)))))

(defun ebox-buffer--scan-region-role-spans (region-id role)
  "Scan current buffer for ROLE spans owned by REGION-ID."
  (let ((prop (ebox-buffer--role-property role))
        spans)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (when (equal (get-text-property (point) prop) region-id)
          (let ((start (point))
                (end (next-single-property-change
                      (point) prop nil (point-max))))
            (push (cons start end) spans)
            (goto-char end)))
        (goto-char (next-single-property-change
                    (point) prop nil (point-max)))))
    (nreverse spans)))

(defun ebox-buffer--record-role-span (table region-id role start end)
  "Record START..END for REGION-ID ROLE in TABLE."
  (let ((key (ebox-buffer--region-role-key region-id role)))
    (puthash key
             (cons (ebox-buffer--make-role-span start end)
                   (gethash key table))
             table)))

(defun ebox-buffer--make-role-span (start end)
  "Return a marker-backed role span for START..END."
  (cons (copy-marker start nil)
        (copy-marker end t)))

(defun ebox-buffer--role-keys-in-range (start end)
  "Return distinct region-role keys touching START..END in the current buffer."
  (let (keys)
    (dolist (entry ebox-region-types)
      (let ((role (car entry))
            (property (cdr entry))
            (position start))
        ;; Marker endpoints at either edge move during delete/insert even when
        ;; their property byte is immediately outside the replaced interval.
        (dolist (boundary (delq nil
                                (list (and (> start (point-min))
                                           (1- start))
                                      (and (< end (point-max)) end))))
          (when-let ((region-id
                      (get-text-property boundary property)))
            (cl-pushnew (ebox-buffer--region-role-key region-id role)
                        keys :test #'equal)))
        (while (< position end)
          (when-let ((region-id (get-text-property position property)))
            (cl-pushnew (ebox-buffer--region-role-key region-id role)
                        keys :test #'equal))
          (setq position
                (or (next-single-property-change
                     position property nil end)
                    end)))))
    keys))

(defun ebox-buffer--string-role-keys (string)
  "Return distinct region-role keys present in STRING."
  (let ((limit (length string))
        keys)
    (dolist (entry ebox-region-types)
      (let ((role (car entry))
            (property (cdr entry))
            (position 0))
        (while (< position limit)
          (when-let ((region-id
                      (get-text-property position property string)))
            (cl-pushnew (ebox-buffer--region-role-key region-id role)
                        keys :test #'equal))
          (setq position
                (or (next-single-property-change
                     position property string limit)
                    limit)))))
    keys))

(defun ebox-buffer--region-ids-in-range (start end)
  "Return distinct Ebox region ids touching START..END in the current buffer."
  (let ((position start)
        ids)
    (dolist (boundary (delq nil
                            (list (and (> start (point-min)) (1- start))
                                  (and (< end (point-max)) end))))
      (dolist (region-id (ebox-buffer--region-ids-at boundary))
        (cl-pushnew region-id ids :test #'equal)))
    (while (< position end)
      (dolist (region-id (ebox-buffer--region-ids-at position))
        (cl-pushnew region-id ids :test #'equal))
      (setq position (or (next-property-change position nil end) end)))
    ids))

(defun ebox-buffer--region-ids-at (position)
  "Return role and wrapper-owner region ids at buffer POSITION."
  (let ((ids
         (append
          (get-text-property position 'ebox-content-owners)
          (when-let ((owner
                      (get-text-property position 'ebox-content-owner)))
            (list owner)))))
    (dolist (entry ebox-region-types)
      (when-let ((region-id (get-text-property position (cdr entry))))
        (cl-pushnew region-id ids :test #'equal)))
    ids))

(defun ebox-buffer--string-all-region-ids (string)
  "Return distinct Ebox role and wrapper-owner ids present in STRING."
  (let ((position 0)
        (limit (length string))
        ids)
    (while (< position limit)
      (dolist (region-id
               (append
                (get-text-property position 'ebox-content-owners string)
                (when-let ((owner
                            (get-text-property
                             position 'ebox-content-owner string)))
                  (list owner))))
        (cl-pushnew region-id ids :test #'equal))
      (dolist (entry ebox-region-types)
        (when-let ((region-id
                    (get-text-property position (cdr entry) string)))
          (cl-pushnew region-id ids :test #'equal)))
      (setq position (or (next-property-change position string limit)
                         limit)))
    ids))

(defun ebox-buffer--replacement-region-ids (spans rendered)
  "Return region ids affected by replacing SPANS with RENDERED."
  (let ((region-ids (ebox-buffer--string-all-region-ids rendered)))
    (dolist (span spans)
      (dolist (region-id
               (ebox-buffer--region-ids-in-range (car span) (cdr span)))
        (cl-pushnew region-id region-ids :test #'equal)))
    region-ids))

(defun ebox-buffer--range-text-equal-string-p (start end string)
  "Return non-nil when START..END has the same characters as STRING."
  (and (= (- end start) (length string))
       (let ((position start)
             (index 0)
             (equal-p t))
         (while (and equal-p (< position end))
           (unless (= (char-after position) (aref string index))
             (setq equal-p nil))
           (setq position (1+ position)
                 index (1+ index)))
         equal-p)))

(defun ebox-buffer--range-properties-equal-string-p
    (start end string properties)
  "Return non-nil when PROPERTIES match between START..END and STRING."
  (and (= (- end start) (length string))
       (let ((offset 0)
             (limit (length string))
             (equal-p t))
         (while (and equal-p (< offset limit))
           (dolist (property properties)
             (unless (equal (get-text-property (+ start offset) property)
                            (get-text-property offset property string))
               (setq equal-p nil)))
           (setq offset (1+ offset)))
         equal-p)))

(defun ebox-buffer--in-place-property-patch-p (root-start patch)
  "Return non-nil when PATCH can update properties without replacing text."
  (let ((old-start (+ root-start (plist-get patch :old-start)))
        (old-end (+ root-start (plist-get patch :old-end)))
        (replacement (plist-get patch :replacement)))
    (ebox-buffer--range-text-equal-string-p old-start old-end replacement)))

(defun ebox-buffer--role-neutral-property-patch-p (root-start patch)
  "Return non-nil when in-place PATCH preserves every runtime owner role."
  (let ((old-start (+ root-start (plist-get patch :old-start)))
        (old-end (+ root-start (plist-get patch :old-end)))
        (replacement (plist-get patch :replacement)))
    (and (ebox-buffer--range-text-equal-string-p
          old-start old-end replacement)
         (ebox-buffer--range-properties-equal-string-p
          old-start old-end replacement
          (delete-dups
           (append (mapcar #'cdr ebox-region-types)
                   '(ebox-content-owners)))))))

(defun ebox-buffer--apply-string-properties-in-place (start string)
  "Replace only text properties at START with those carried by STRING."
  (let ((position 0)
        (limit (length string)))
    (while (< position limit)
      (let ((next (or (next-property-change position string limit) limit)))
        (set-text-properties
         (+ start position) (+ start next)
        (text-properties-at position string))
        (setq position next)))))

(defun ebox-buffer--role-context-in-range (start end &optional string)
  "Return role keys in START..END of the current buffer or STRING.
Buffer ranges include their immediate boundaries because delete/insert marker
motion can affect a role span whose property byte is just outside the patch."
  (let ((positions nil)
        keys)
    (unless string
      (when (> start (point-min))
        (push (1- start) positions))
      (when (< end (point-max))
        (push end positions)))
    (let ((position start))
      (while (< position end)
        (push position positions)
        (setq position
              (or (next-property-change position string end) end))))
    (dolist (position positions)
      (dolist (entry ebox-region-types)
        (when-let ((region-id
                    (get-text-property position (cdr entry) string)))
          (cl-pushnew
           (ebox-buffer--region-role-key region-id (car entry))
           keys :test #'equal))))
    keys))

(defun ebox-buffer--numeric-span-touches-range-p (span range)
  "Return non-nil when numeric SPAN touches numeric RANGE."
  (and (<= (car span) (cdr range))
       (>= (cdr span) (car range))))

(defun ebox-buffer--numeric-role-span (span)
  "Return marker-backed or integer SPAN as an integer pair."
  (let ((start (if (markerp (car span))
                   (marker-position (car span))
                 (car span)))
        (end (if (markerp (cdr span))
                 (marker-position (cdr span))
                 (cdr span))))
    (and start end (< start end) (cons start end))))

(defun ebox-buffer--copy-frozen-region-role-span-table (table)
  "Return an independent integer-coordinate copy of role span TABLE."
  (when (hash-table-p table)
    (let ((copy (make-hash-table :test 'equal)))
      (maphash
       (lambda (key spans)
         (when (consp key)
           (puthash key
                    (delq nil
                          (mapcar (lambda (span)
                                    (when-let ((numeric
                                                (ebox-buffer--numeric-role-span
                                                 span)))
                                      (copy-tree numeric)))
                                  spans))
                    copy)))
       table)
      copy)))

(defun ebox-buffer--capture-role-delta (root-start patches)
  "Capture the role-index delta for PATCHES rooted at ROOT-START.
Only keys touching replaced bytes or insertion boundaries are retained."
  (when-let ((table (ebox-buffer--region-role-span-table)))
    (when (gethash ebox-buffer--role-span-table-template-key table)
      (ebox-buffer-materialize-region-role-spans (current-buffer))
      (setq table (ebox-buffer--region-role-span-table)))
    (when (ebox-buffer--marker-role-span-table-p table)
      (let ((entries-by-key (make-hash-table :test 'equal)))
        (dolist (patch patches)
          ;; Display and face changes dominate resize animation tapes.  When
          ;; their characters, role owners, and coordinates are unchanged,
          ;; the existing marker index is already the exact target index.
          (if (ebox-buffer--role-neutral-property-patch-p root-start patch)
              nil
            (let* ((old-start (+ root-start (plist-get patch :old-start)))
                   (old-end (+ root-start (plist-get patch :old-end)))
                   (new-start (+ root-start (plist-get patch :new-start)))
                   (new-end (+ root-start (plist-get patch :new-end)))
                   (replacement (plist-get patch :replacement))
                   (old-context
                    (ebox-buffer--role-context-in-range old-start old-end))
                   (new-context
                    (ebox-buffer--role-context-in-range
                     0 (length replacement) replacement))
                   (keys
                    (delete-dups
                     (append old-context new-context)))
                   (old-range (cons old-start old-end))
                   (new-range (cons new-start new-end)))
              (dolist (key keys)
                (let ((entry (gethash key entries-by-key)))
                  (unless entry
                    (setq entry (list :key key)))
                  (plist-put entry :old-ranges
                             (cons old-range
                                   (plist-get entry :old-ranges)))
                  (plist-put entry :new-ranges
                             (cons new-range
                                   (plist-get entry :new-ranges)))
                  (puthash key entry entries-by-key))))))
        (let (entries)
          (maphash
           (lambda (key entry)
             (let* ((old-ranges
                     (ebox-buffer--merge-numeric-spans
                      (plist-get entry :old-ranges)))
                    (old-spans
                     (cl-remove-if-not
                      (lambda (span)
                        (when-let ((numeric
                                    (ebox-buffer--numeric-role-span span)))
                          (cl-some
                           (lambda (range)
                             (ebox-buffer--numeric-span-touches-range-p
                              numeric range))
                           old-ranges)))
                      (gethash key table))))
               (plist-put entry :old-spans old-spans)
               (plist-put entry :new-ranges
                          (ebox-buffer--merge-numeric-spans
                           (plist-get entry :new-ranges)))
               (push entry entries)))
           entries-by-key)
          (list :entries entries))))))

(defun ebox-buffer--role-span-outside-replacements (span replacements)
  "Translate the parts of old SPAN outside REPLACEMENTS to new coordinates."
  (let ((cursor (car span))
        (end (cdr span))
        (delta 0)
        translated)
    (catch 'done
      (dolist (replacement replacements)
        (let ((old-start (plist-get replacement :old-start))
              (old-end (plist-get replacement :old-end))
              (replacement-delta (plist-get replacement :delta)))
          (cond
           ((<= old-end cursor)
            (setq delta (+ delta replacement-delta)))
           ((>= old-start end)
            (throw 'done nil))
           (t
            (let ((left-end (min end old-start)))
              (when (< cursor left-end)
                (push (cons (+ cursor delta) (+ left-end delta))
                      translated)))
            (setq cursor (max cursor (min end old-end))
                  delta (+ delta replacement-delta)))))))
    (when (< cursor end)
      (push (cons (+ cursor delta) (+ end delta)) translated))
    (nreverse translated)))

(defun ebox-buffer--role-spans-for-key-in-ranges (key ranges)
  "Return exact current spans for role KEY inside buffer RANGES."
  (let ((region-id (car key))
        (property (ebox-buffer--role-property (cadr key)))
        spans)
    (dolist (range ranges)
      (let ((position (car range))
            (end (cdr range)))
        (while (< position end)
          (let ((next (or (next-single-property-change
                           position property nil end)
                          end)))
            (when (equal (get-text-property position property) region-id)
              (push (cons position next) spans))
            (setq position next)))))
    spans))

(defun ebox-buffer--merge-numeric-spans (spans)
  "Return sorted, coalesced numeric SPANS."
  (let (merged)
    (dolist (span (sort (delq nil spans)
                        (lambda (left right)
                          (< (car left) (car right)))))
      (if (and merged (<= (car span) (cdar merged)))
          (setcdr (car merged) (max (cdar merged) (cdr span)))
        (push (copy-tree span) merged)))
    (nreverse merged)))

(defun ebox-buffer--detach-role-spans (spans)
  "Detach marker endpoints in SPANS."
  (dolist (span spans)
    (when (markerp (car span))
      (set-marker (car span) nil))
    (when (markerp (cdr span))
      (set-marker (cdr span) nil))))

(defun ebox-buffer--detach-region-role-span-table (buffer)
  "Detach BUFFER's marker-backed role table before replacing it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((table (ebox-buffer--region-role-span-table)))
        (when (ebox-buffer--marker-role-span-table-p table)
          (maphash
           (lambda (key spans)
             (when (consp key)
               (ebox-buffer--detach-role-spans spans)))
           table)
          (ebox--set-buffer-region-role-span-table buffer nil)
          t)))))

(defun ebox-buffer--detach-role-span-table-markers (table)
  "Detach marker endpoints in marker-backed role span TABLE."
  (when (and (hash-table-p table)
             (ebox-buffer--marker-role-span-table-p table))
    (maphash
     (lambda (key spans)
       (when (consp key)
         (ebox-buffer--detach-role-spans spans)))
     table)))

(defun ebox-buffer--merge-role-markers-with-numeric-spans
    (marker-spans numeric-spans)
  "Merge exact NUMERIC-SPANS into sorted existing MARKER-SPANS.
Markers outside the changed ranges are retained rather than recreated."
  (let ((result (copy-sequence marker-spans)))
    (dolist (numeric (ebox-buffer--merge-numeric-spans numeric-spans))
      (let (touching untouched)
        (dolist (span result)
          (if (ebox-buffer--numeric-span-touches-range-p
               (cons (marker-position (car span))
                     (marker-position (cdr span)))
               numeric)
              (push span touching)
            (push span untouched)))
        (if touching
            (let* ((touching (nreverse touching))
                   (primary (car touching))
                   (start
                    (min (car numeric)
                         (cl-loop for span in touching
                                  minimize (marker-position (car span)))))
                   (end
                    (max (cdr numeric)
                         (cl-loop for span in touching
                                  maximize (marker-position (cdr span))))))
              (set-marker (car primary) start)
              (set-marker (cdr primary) end)
              (ebox-buffer--detach-role-spans (cdr touching))
              (setq result (cons primary untouched)))
          (setq result
                (cons (ebox-buffer--make-role-span
                       (car numeric) (cdr numeric))
                      untouched)))))
    (sort result
          (lambda (left right)
            (< (marker-position (car left))
               (marker-position (car right)))))))

(defun ebox-buffer-apply-role-delta (buffer delta)
  "Apply captured role-index DELTA after exact root patches changed BUFFER."
  (when (and (buffer-live-p buffer) delta)
    (with-current-buffer buffer
      (when-let ((table (ebox-buffer--region-role-span-table)))
        (dolist (entry (plist-get delta :entries))
          (let* ((key (plist-get entry :key))
                 (old-spans (plist-get entry :old-spans))
                 (current-spans (gethash key table))
                 (preserved-spans
                  (cl-remove-if
                   (lambda (span) (memq span old-spans))
                   current-spans))
                 (dirty-ranges
                  (append
                   (plist-get entry :new-ranges)
                   (delq nil
                         (mapcar #'ebox-buffer--numeric-role-span
                                 old-spans))))
                 (replacement-spans
                  (ebox-buffer--role-spans-for-key-in-ranges
                   key (ebox-buffer--merge-numeric-spans dirty-ranges)))
                 (merged
                  (ebox-buffer--merge-role-markers-with-numeric-spans
                   preserved-spans replacement-spans)))
            (ebox-buffer--detach-role-spans old-spans)
            (if merged
                (puthash key
                         merged
                         table)
              (remhash key table))))
        t))))

(defun ebox-buffer--current-region-role-span-p (span region-id role)
  "Return non-nil when SPAN still carries REGION-ID for ROLE.
Marker survival alone is insufficient: scroll-window replacement can leave a
nonempty marker range at coordinates now owned by a different region."
  (let* ((start (car-safe span))
         (end (cdr-safe span))
         (start-pos (if (markerp start) (marker-position start) start))
         (end-pos (if (markerp end) (marker-position end) end)))
    (and (number-or-marker-p start)
         (number-or-marker-p end)
         (or (not (markerp start))
             (eq (marker-buffer start) (current-buffer)))
         (or (not (markerp end))
             (eq (marker-buffer end) (current-buffer)))
         start-pos end-pos (< start-pos end-pos)
         (not (text-property-not-all
               start-pos end-pos
               (ebox-buffer--role-property role) region-id)))))

(defun ebox-buffer--marker-role-span-table-p (table)
  "Return non-nil when TABLE stores marker-backed role spans."
  (gethash ebox-buffer--role-span-table-marker-key table))

(defun ebox-buffer--build-region-role-span-table ()
  "Build a role span index for the current buffer."
  (let ((table (make-hash-table :test 'equal)))
    (puthash ebox-buffer--role-span-table-marker-key t table)
    (dolist (entry ebox-region-types)
      (let ((role (car entry))
            (prop (cdr entry)))
        (save-excursion
          (goto-char (point-min))
          (while (< (point) (point-max))
            (let* ((region-id (get-text-property (point) prop))
                   (next (or (next-single-property-change
                              (point) prop nil (point-max))
                             (point-max))))
              (when region-id
                (ebox-buffer--record-role-span
                 table region-id role (point) next))
              (goto-char (max next (1+ (point)))))))))
    (maphash (lambda (key spans)
               (when (consp key)
                 (puthash key (nreverse spans) table)))
             table)
    table))

(defvar ebox-buffer--region-property-role-table-cache nil
  "Cached property-to-role lookup for `ebox-region-types'.")

(defvar ebox-buffer--region-property-role-table-source nil
  "The `ebox-region-types' object used to build the role lookup cache.")

(defun ebox-buffer--region-property-role-table ()
  "Return an eq table mapping Ebox text properties to region roles."
  (unless (and ebox-buffer--region-property-role-table-cache
               (eq ebox-buffer--region-property-role-table-source
                   ebox-region-types))
    (let ((table (make-hash-table :test 'eq)))
      (dolist (entry ebox-region-types)
        (puthash (cdr entry) (car entry) table))
      (setq ebox-buffer--region-property-role-table-cache table
            ebox-buffer--region-property-role-table-source
            ebox-region-types)))
  ebox-buffer--region-property-role-table-cache)

(defun ebox-buffer--build-region-role-span-template (string)
  "Build an immutable point-min-based role span template from STRING."
  (let ((table (make-hash-table :test 'equal))
        (property-roles (ebox-buffer--region-property-role-table))
        (limit (length string))
        (position 0))
    (puthash ebox-buffer--role-span-table-template-key t table)
    ;; Role properties share the same interval tree.  Walking each role over
    ;; the whole output multiplies root-prewarm work by `ebox-region-types'.
    ;; Visit every text-property interval once, then coalesce boundaries caused
    ;; only by unrelated properties back into the role's maximal span.
    (while (< position limit)
      (let* ((properties (text-properties-at position string))
             (next (or (next-property-change position string limit) limit))
             (start (1+ position))
             (end (1+ next)))
        (while properties
          (let* ((property (pop properties))
                 (region-id (pop properties))
                 (role (gethash property property-roles)))
            (when (and role region-id)
              (let* ((key (ebox-buffer--region-role-key region-id role))
                     (spans (gethash key table)))
                (if (and spans (= (cdar spans) start))
                    (setcdr (car spans) end)
                  (puthash key (cons (cons start end) spans) table))))))
        (setq position (max next (1+ position)))))
    (maphash (lambda (key spans)
               (when (consp key)
                 (puthash key (nreverse spans) table)))
             table)
    table))

(defun ebox-buffer--install-region-role-span-template
    (buffer template start)
  "Install prepared TEMPLATE in BUFFER at root START."
  (when (and (buffer-live-p buffer) (hash-table-p template))
    (with-current-buffer buffer
      (ebox-buffer--detach-region-role-span-table buffer)
      (let ((table
             (if (= start (point-min))
                 (progn
                   (puthash ebox-buffer--role-span-table-template-key
                            t template)
                   template)
               (let ((translated (make-hash-table :test 'equal))
                     (delta (- start (point-min))))
                 (puthash ebox-buffer--role-span-table-template-key
                          t translated)
                 (maphash
                  (lambda (key spans)
                    (when (consp key)
                      (puthash
                       key
                       (mapcar (lambda (span)
                                 (cons (+ delta (car span))
                                       (+ delta (cdr span))))
                               spans)
                       translated)))
                  template)
                 translated))))
        (ebox--set-buffer-region-role-span-table buffer table)
        table))))

(defun ebox-buffer--region-role-span-table-from-template (template start)
  "Return a buffer-coordinate role span table from TEMPLATE at START."
  (when (hash-table-p template)
    (if (= start (point-min))
        (let ((table (copy-hash-table template)))
          (puthash ebox-buffer--role-span-table-template-key t table)
          table)
      (let ((translated (make-hash-table :test 'equal))
            (delta (- start (point-min))))
        (puthash ebox-buffer--role-span-table-template-key t translated)
        (maphash
         (lambda (key spans)
           (when (consp key)
             (puthash
              key
              (mapcar (lambda (span)
                        (cons (+ delta (car span))
                              (+ delta (cdr span))))
                      spans)
              translated)))
         template)
        translated))))

(defun ebox-buffer--target-span-valid-p (span start end)
  "Return non-nil when SPAN is an integer range inside START..END."
  (and (consp span)
       (integerp (car span))
       (integerp (cdr span))
       (<= start (car span))
       (< (car span) (cdr span))
       (<= (cdr span) end)))

(defun ebox-buffer--validate-role-span-template (table start target-length)
  "Validate translated role span TABLE inside START plus TARGET-LENGTH."
  (let ((end (+ start target-length)))
    (unless (hash-table-p table)
      (error "Native root patch has invalid role indexes"))
    (maphash
     (lambda (key spans)
       (when (consp key)
         (dolist (span spans)
           (unless (ebox-buffer--target-span-valid-p span start end)
             (error "Native root patch has invalid role index span")))))
     table)
    t))

(defun ebox-buffer--validate-box-extent-template
    (template start target-length)
  "Return validated buffer-coordinate extents for target TEMPLATE."
  (let ((end (+ start target-length))
        (delta (- start (point-min)))
        (translated-table (make-hash-table :test 'equal)))
    (unless (hash-table-p template)
      (error "Native root patch has invalid extent indexes"))
    (maphash
     (lambda (region-id span)
       (let ((translated (cons (+ delta (car span))
                               (+ delta (cdr span)))))
         (unless (ebox-buffer--target-span-valid-p translated start end)
           (error "Native root patch has invalid extent index span"))
         (puthash region-id translated translated-table)))
     template)
    translated-table))

(defun ebox-buffer-materialize-region-role-spans (buffer)
  "Convert BUFFER's current integer role span table to marker-backed spans."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((current (ebox-buffer--region-role-span-table)))
        (unless (ebox-buffer--marker-role-span-table-p current)
          (let ((table (make-hash-table :test 'equal)))
            (puthash ebox-buffer--role-span-table-marker-key t table)
            (maphash
             (lambda (key spans)
               (when (consp key)
                 (puthash key
                          (mapcar (lambda (span)
                                    (ebox-buffer--make-role-span
                                     (car span) (cdr span)))
                                  spans)
                          table)))
             current)
            (ebox--set-buffer-region-role-span-table buffer table)))
        (ebox-buffer--region-role-span-table)))))

(defun ebox-buffer-refresh-region-role-spans (buffer)
  "Refresh BUFFER's region role span index from current text properties."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (ebox--set-buffer-region-role-span-table
       buffer (ebox-buffer--build-region-role-span-table)))))

(defun ebox-buffer--span-overlaps-p (left right)
  "Return non-nil when LEFT and RIGHT buffer spans overlap."
  (and (< (car left) (cdr right))
       (> (cdr left) (car right))))

(defun ebox-buffer--role-span-replacements (old-spans new-spans)
  "Return OLD-SPANS to NEW-SPANS replacement maps, or nil if ambiguous."
  (when (= (length old-spans) (length new-spans))
    (cl-loop for old in old-spans
             for new in new-spans
             collect (list :old-start (car old)
                           :old-end (cdr old)
                           :new-start (car new)
                           :new-end (cdr new)
                           :delta (- (- (cdr new) (car new))
                                     (- (cdr old) (car old)))))))

(defun ebox-buffer--role-span-replacement-index (replacements)
  "Return a binary-search index with cumulative deltas for REPLACEMENTS."
  (let ((delta 0))
    (vconcat
     (mapcar
      (lambda (replacement)
        (cl-incf delta (plist-get replacement :delta))
        (vector (plist-get replacement :old-start)
                (plist-get replacement :old-end)
                delta))
      replacements))))

(defun ebox-buffer--translate-position-through-replacement-index
    (pos index &optional end-boundary-p)
  "Translate old POS through replacement INDEX, or return nil if ambiguous."
  (let ((low 0)
        (high (length index)))
    (while (< low high)
      (let* ((middle (/ (+ low high) 2))
             (old-start (aref (aref index middle) 0)))
        (if (if end-boundary-p (< old-start pos) (<= old-start pos))
            (setq low (1+ middle))
          (setq high middle))))
    (if (zerop low)
        pos
      (let ((replacement (aref index (1- low))))
        (unless (if end-boundary-p
                    (<= pos (aref replacement 1))
                  (< pos (aref replacement 1)))
          (+ pos (aref replacement 2)))))))

(defun ebox-buffer--translate-role-span-through-replacements
    (span replacements &optional replacement-index)
  "Translate SPAN through REPLACEMENTS, or return nil if ambiguous."
  (let* ((index (or replacement-index
                    (ebox-buffer--role-span-replacement-index replacements)))
         (start (ebox-buffer--translate-position-through-replacement-index
                 (car span) index))
         (end (ebox-buffer--translate-position-through-replacement-index
               (cdr span) index t)))
    (and start end (<= start end) (cons start end))))

(defun ebox-buffer--translate-region-role-span-table
    (table region-ids old-spans new-spans)
  "Translate untouched TABLE entries after replacing OLD-SPANS with NEW-SPANS.
Return non-nil when the existing table remains valid after translation.
Return nil when an untouched role span crosses replaced text; callers must
discard the table so later lookups rescan current text properties."
  (let ((replacements (ebox-buffer--role-span-replacements
                       old-spans new-spans)))
    (and replacements
         (let ((region-set (ebox--region-id-set region-ids))
               (replacement-index
                (ebox-buffer--role-span-replacement-index replacements)))
           (catch 'unsafe
             (maphash
              (lambda (key spans)
                (when (and (consp key)
                           (not (gethash (car key) region-set)))
                  (let (translated)
                    (dolist (span spans)
                      (if-let ((new-span
                                (ebox-buffer--translate-role-span-through-replacements
                                 span replacements replacement-index)))
                          (push new-span translated)
                        (throw 'unsafe nil)))
                    (puthash key (nreverse translated) table))))
              table)
             t)))))

(defun ebox-buffer--same-role-span-bounds-p (old-spans new-spans)
  "Return non-nil when OLD-SPANS and NEW-SPANS occupy the same coordinates."
  (and (= (length old-spans) (length new-spans))
       (cl-every
        (lambda (pair)
          (let ((old (car pair))
                (new (cdr pair)))
            (and (= (car old) (car new))
                 (= (cdr old) (cdr new)))))
        (cl-mapcar #'cons old-spans new-spans))))

(defun ebox-buffer--rendered-line-bounds (rendered)
  "Return 0-based content bounds for each line in RENDERED."
  (let ((start 0)
        bounds)
    (while (<= start (length rendered))
      (let ((newline (string-match-p "\n" rendered start)))
        (push (cons start (or newline (length rendered))) bounds)
        (if newline
            (setq start (1+ newline))
          (setq start (1+ (length rendered))))))
    (vconcat (nreverse bounds))))

(defun ebox-buffer--rendered-line-index-at (line-bounds position)
  "Return the LINE-BOUNDS index containing rendered POSITION."
  (let ((index 0)
        found)
    (while (and (< index (length line-bounds)) (not found))
      (let ((bounds (aref line-bounds index)))
        (if (and (<= (car bounds) position)
                 (< position (cdr bounds)))
            (setq found index)
          (setq index (1+ index)))))
    found))

(defun ebox-buffer--numeric-span-start (span)
  "Return SPAN's numeric start coordinate."
  (let ((start (car-safe span)))
    (if (markerp start) (marker-position start) start)))

(defun ebox-buffer--record-active-extent-segment
    (segments-by-region region-set region-id start end)
  "Record REGION-ID START..END in SEGMENTS-BY-REGION when active."
  (when (and segments-by-region
             (gethash region-id region-set)
             (< start end))
    (puthash region-id
             (cons (cons start end)
                   (gethash region-id segments-by-region))
             segments-by-region)))

(defun ebox-buffer--record-rendered-active-extent-segments
    (segments-by-region region-set owners line-bounds spans start end)
  "Record active extent OWNERS from rendered START..END in buffer SPANS."
  (when (and segments-by-region owners)
    (let ((segment-start start))
      (while (< segment-start end)
        (if-let* ((line-index
                   (ebox-buffer--rendered-line-index-at
                    line-bounds segment-start))
                  ((< line-index (length spans)))
                  (line-bounds-entry
                   (aref line-bounds line-index))
                  (span-start
                   (ebox-buffer--numeric-span-start
                    (nth line-index spans))))
            (let* ((segment-end (min end (cdr line-bounds-entry)))
                   (buffer-start
                    (+ span-start (- segment-start
                                     (car line-bounds-entry))))
                   (buffer-end
                    (+ span-start (- segment-end
                                     (car line-bounds-entry)))))
              (dolist (owner owners)
                (ebox-buffer--record-active-extent-segment
                 segments-by-region region-set owner
                 buffer-start buffer-end))
              (setq segment-start
                    (if (< segment-end end)
                        (1+ segment-end)
                      segment-end)))
          (setq segment-start end))))))

(defun ebox-buffer--record-rendered-role-spans
    (table region-set rendered spans &optional touched-keys active-segments)
  "Record role spans from RENDERED into TABLE translated through SPANS."
  (let ((property-roles (ebox-buffer--region-property-role-table))
        (line-bounds (ebox-buffer--rendered-line-bounds rendered))
        (limit (length rendered))
        (position 0))
    (while (< position limit)
      (let* ((properties (text-properties-at position rendered))
             (next (or (next-property-change position rendered limit)
                       limit)))
        (ebox-buffer--record-rendered-active-extent-segments
         active-segments region-set
         (get-text-property position 'ebox-content-owners rendered)
         line-bounds spans position next)
        (while properties
          (let* ((property (pop properties))
                 (region-id (pop properties))
                 (role (gethash property property-roles)))
            (when (and role region-id (gethash region-id region-set))
              (let ((segment-start position))
                (while (< segment-start next)
                  (if-let* ((line-index
                             (ebox-buffer--rendered-line-index-at
                              line-bounds segment-start))
                            ((< line-index (length spans)))
                            (line-bounds-entry
                             (aref line-bounds line-index))
                            (span-start
                             (ebox-buffer--numeric-span-start
                              (nth line-index spans))))
                      (let* ((segment-end
                              (min next (cdr line-bounds-entry)))
                             (buffer-start
                              (+ span-start
                                 (- segment-start
                                    (car line-bounds-entry))))
                             (buffer-end
                              (+ span-start
                                 (- segment-end
                                     (car line-bounds-entry)))))
                        (when (and role region-id
                                   (gethash region-id region-set))
                          (ebox-buffer--record-role-span
                           table region-id role buffer-start buffer-end))
                        (unless (eq role 'content-owner)
                          (ebox-buffer--record-active-extent-segment
                           active-segments region-set region-id
                           buffer-start buffer-end))
                        (when (and role region-id touched-keys)
                          (puthash
                           (ebox-buffer--region-role-key region-id role)
                           t touched-keys))
                        (setq segment-start
                              (if (< segment-end next)
                                  (1+ segment-end)
                                segment-end)))
                    (setq segment-start next)))))))
        (setq position (max next (1+ position)))))
    t))

(defun ebox-buffer-refresh-region-role-spans-for-region-ids
    (buffer region-ids spans &optional old-spans rendered-spans)
  "Refresh role span table entries for REGION-IDS inside SPANS in BUFFER.
When OLD-SPANS is non-nil, translate untouched integer span coordinates from
OLD-SPANS to SPANS before rebuilding REGION-IDS entries.  RENDERED-SPANS,
when non-nil, is a list of (RENDERED . SPANS) pairs used to rebuild touched
entries without rescanning BUFFER text properties."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((table (ebox-buffer--region-role-span-table)))
        (if (and old-spans
                 (not (ebox-buffer--same-role-span-bounds-p
                       old-spans spans))
                 (not (ebox-buffer--marker-role-span-table-p table))
                 (not (ebox-buffer--translate-region-role-span-table
                       table region-ids old-spans spans)))
            (ebox--set-buffer-region-role-span-table
             buffer (ebox-buffer--build-region-role-span-table))
          (let ((region-set (ebox--region-id-set region-ids))
                (touched-keys (make-hash-table :test 'equal))
                (active-segments (make-hash-table :test 'equal)))
            (dolist (region-id region-ids)
              (dolist (entry ebox-region-types)
                (remhash
                 (ebox-buffer--region-role-key region-id (car entry))
                 table)))
            (if rendered-spans
                (dolist (entry rendered-spans)
                  (ebox-buffer--record-rendered-role-spans
                   table region-set (car entry) (cdr entry)
                   touched-keys active-segments))
              (dolist (span spans)
                (dolist (entry ebox-region-types)
                  (let ((role (car entry))
                        (prop (cdr entry))
                        (pos (car span)))
                    (while (< pos (cdr span))
                      (let* ((region-id (get-text-property pos prop))
                             (next (or (next-single-property-change
                                        pos prop nil (cdr span))
                                       (cdr span))))
                        (when (gethash region-id region-set)
                          (let ((key (ebox-buffer--region-role-key
                                      region-id role)))
                            (puthash key t touched-keys)
                            (ebox-buffer--record-role-span
                             table region-id role pos next)
                            (unless (eq role 'content-owner)
                              (ebox-buffer--record-active-extent-segment
                               active-segments region-set
                               region-id pos next))))
                        (setq pos (max next (1+ pos))))))))
              (dolist (span spans)
                (let ((pos (car span)))
                  (while (< pos (cdr span))
                    (let* ((owners (get-text-property
                                    pos 'ebox-content-owners))
                           (next (or (next-single-property-change
                                      pos 'ebox-content-owners nil
                                      (cdr span))
                                     (cdr span))))
                      (dolist (owner owners)
                        (ebox-buffer--record-active-extent-segment
                         active-segments region-set owner pos next))
                      (setq pos (max next (1+ pos))))))))
            (maphash
             (lambda (key _)
               (when-let ((spans (gethash key table)))
                 (puthash key
                          (sort spans (lambda (left right)
                                        (< (car left) (car right))))
                          table)))
             touched-keys)
            (list :active-segments active-segments)))))))

(defun ebox-buffer--horizontal-border-anchor-spans (region-id role)
  "Infer a top or bottom border span for REGION-ID from existing box anchors."
  (let ((line-ranges (make-hash-table :test 'eql))
        line-keys)
    (save-excursion
      (dolist (anchor-role ebox--horizontal-border-anchor-roles)
        (dolist (span (ebox--region-find region-id anchor-role))
          (goto-char (car span))
          (let* ((line-start (line-beginning-position))
                 (range (gethash line-start line-ranges)))
            (if range
                (progn
                  (setcar range (min (car range) (car span)))
                  (setcdr range (max (cdr range) (cdr span))))
              (push line-start line-keys)
              (puthash line-start (copy-tree span) line-ranges))))))
    (when line-keys
      (let* ((line (if (eq role 'bt)
                       (apply #'min line-keys)
                     (apply #'max line-keys)))
             (span (gethash line line-ranges)))
        (and span (list span))))))

(defun ebox-buffer--horizontal-border-face-value (box role)
  "Return the face value for BOX horizontal border ROLE."
  (pcase role
    ('bt
     (or (ebox-get box :border-top-color) t))
    ('bb
     (let ((color (ebox-get box :border-bottom-color)))
       (if color
           (list :position t :color color)
         (list :position t))))))

(defun ebox-buffer--horizontal-border-enabled-p (box role)
  "Return non-nil when BOX should display horizontal border ROLE."
  (pcase role
    ('bt (ebox-get box :border-top-p))
    ('bb (ebox-get box :border-bottom-p))))

(defun ebox--paint-horizontal-border-surface (box role)
  "Return a paint-surface spec for BOX horizontal border ROLE."
  (let ((enabled (ebox-buffer--horizontal-border-enabled-p box role)))
    (list :role role
          :face-key (if (eq role 'bt) :overline :underline)
          :face-value (if enabled
                          (ebox-buffer--horizontal-border-face-value box role)
                        ebox-buffer--remove-face-key)
          :missing (if enabled 'infer 'noop)
          :remove-role (not enabled))))

(defun ebox-buffer--paint-side-border-surfaces (box role color-key)
  "Return paint specs for BOX side ROLE using COLOR-KEY."
  (let ((color (ebox-get box color-key)))
    (list
     (list :role role
           :face-key :background
           :face-value (or color ebox-buffer--remove-face-key)
           :missing 'noop
           :own-region-only t)
     (list :role role
           :face-key :inverse-video
           :face-value (if color ebox-buffer--remove-face-key t)
           :missing 'noop
           :own-region-only t))))

(defun ebox--paint-text-property-patches (box changed-key)
  "Return text-property patch specs for BOX CHANGED-KEY, or nil.
Each result is a backend paint-surface plist."
  (pcase changed-key
    (:color
     (mapcar (lambda (role)
               (list :role role
                     :face-key :foreground
                     :face-value (or (ebox-get box :color)
                                     ebox-buffer--remove-face-key)
                     :missing 'noop
                     :paint-prop :color))
             ebox--paint-content-region-roles))
    (:bgcolor
     (mapcar (lambda (role)
               (list :role role
                     :face-key :background
                     :face-value (or (ebox-get box :bgcolor)
                                     ebox-buffer--remove-face-key)
                     :missing 'noop
                     :paint-prop :bgcolor))
             ebox--paint-content-region-roles))
    (:border-left-color
     (ebox-buffer--paint-side-border-surfaces
      box 'bl :border-left-color))
    (:border-right-color
     (ebox-buffer--paint-side-border-surfaces
      box 'br :border-right-color))
    (:border-top-color
     (list (append (ebox--paint-horizontal-border-surface box 'bt)
                   '(:own-region-only t))))
    (:border-bottom-color
     (list (append (ebox--paint-horizontal-border-surface box 'bb)
                   '(:own-region-only t))))
    (:border-top-p
     (list (append (ebox--paint-horizontal-border-surface box 'bt)
                   '(:own-region-only t))))
    (:border-bottom-p
     (list (append (ebox--paint-horizontal-border-surface box 'bb)
                   '(:own-region-only t))))
    (_ nil)))

(defun ebox-buffer--paint-surface-key (spec)
  "Return the deduplication key for paint-surface SPEC."
  (list (plist-get spec :role)
        (plist-get spec :face-key)))

(defun ebox--paint-text-property-surfaces (box changed-keys)
  "Return deduplicated paint surfaces for BOX CHANGED-KEYS.
Return nil when any changed key is not a direct text-property paint surface."
  (let ((table (make-hash-table :test 'equal))
        keys
        supported)
    (setq supported t)
    (dolist (changed-key changed-keys)
      (if-let ((specs (ebox--paint-text-property-patches
                       box changed-key)))
          (dolist (spec specs)
            (let ((key (ebox-buffer--paint-surface-key spec)))
              (unless (gethash key table)
                (push key keys))
              (puthash key spec table)))
        (setq supported nil)))
    (when supported
      (mapcar (lambda (key)
                (gethash key table))
              (nreverse keys)))))

(defun ebox-buffer--surface-spans (region-id spec)
  "Return patch spans for REGION-ID and paint-surface SPEC."
  (let* ((role (plist-get spec :role))
         (spans (ebox--region-find region-id role)))
    (cond
     (spans spans)
     ((eq (plist-get spec :missing) 'infer)
      (let ((inferred
             (ebox-buffer--horizontal-border-anchor-spans region-id role)))
        (when inferred
          (let ((prop (ebox-buffer--role-property role)))
            (dolist (span inferred)
              (put-text-property (car span) (cdr span) prop region-id)))
          (ebox-buffer--put-region-role-spans region-id role inferred)
          inferred)))
     (t nil))))

(defun ebox-buffer--patch-surface (region-id spec)
  "Apply paint-surface SPEC to REGION-ID and return patched span count."
  (let ((spans (ebox-buffer--surface-spans region-id spec))
        (role (plist-get spec :role))
        (face-key (plist-get spec :face-key))
        (face-value (plist-get spec :face-value))
        (remove-role (plist-get spec :remove-role))
        (count 0))
    (dolist (span spans)
      (if (memq role '(bt bb))
          (ebox--patch-horizontal-border-face-in-span
           (car span) (cdr span) face-key face-value)
        (ebox--patch-face-key-in-span
         (car span) (cdr span) face-key face-value))
      (when remove-role
        (remove-text-properties
         (car span) (cdr span)
         (list (ebox-buffer--role-property
                role)
               nil)))
      (cl-incf count))
    (when remove-role
      (ebox-buffer--put-region-role-spans region-id role nil))
    count))

(defun ebox-buffer--paint-surfaces-safe-for-node-p (node surfaces)
  "Return non-nil when SURFACES can be face-patched across NODE's spans.
Content paint follows nearest-declaration semantics, but the owner's
content-owner spans cover every descendant character and anonymous
face entries carry no ownership, so the cheap face patch cannot skip a
descendant's own entry.  When any descendant declares the same paint
property, decline; callers fall back to an exact owner render."
  (cl-every (lambda (spec)
              (let ((paint-prop (plist-get spec :paint-prop)))
                (or (null paint-prop)
                    (not (ebox--node-paint-conflict-p node paint-prop)))))
            surfaces))

(defun ebox--execute-text-property-paint-patch (buffer op node)
  "Execute OP as direct text-property edits for NODE when possible."
  (let* ((dirty (plist-get op :dirty))
         (changed-keys (plist-get dirty :changed-keys))
         (region-ids (or (plist-get dirty :region-ids)
                         (ebox--node-all-region-ids node)))
         (surfaces (and changed-keys
                        (not (and (memq :color changed-keys)
                                  (ebox--node-visible-overflow-p node)))
                        (ebox--paint-text-property-surfaces
                         node changed-keys)))
         (patched 0))
    (when (and surfaces
               (ebox-buffer--paint-surfaces-safe-for-node-p node surfaces))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (with-silent-modifications
            (dolist (spec surfaces)
              ;; Border surfaces belong to the owner's own chrome: a
              ;; full render never propagates an ancestor's border
              ;; color into a descendant's border runs, so the cheap
              ;; face patch must not either (issue014).
              (dolist (region-id
                       (if (plist-get spec :own-region-only)
                           (let ((own (ebox-get node :region-id)))
                             (and own (memq own region-ids) (list own)))
                         region-ids))
                (cl-incf patched
                         (ebox-buffer--patch-surface
                          region-id spec)))))))
      (list :owner-id (plist-get op :owner-id)
            :op 'paint-patch
            :owner-type (plist-get node :ebox-type)
            :span-count patched
            :text-property-patch t))))

(defun ebox--line-spans-contiguous-p (spans)
  "Return non-nil when SPANS cover adjacent whole buffer lines."
  (or (null spans)
      (cl-loop for rest on spans
               while (cdr rest)
               always (= (caadr rest) (1+ (cdar rest))))))

(defun ebox--buffer-line-spans-between (start end)
  "Return actual buffer line spans between START and END."
  (if (= start end)
      (list (cons start end))
    (let (spans)
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (push (cons (point) (min (line-end-position) end)) spans)
          (forward-line 1)))
      (nreverse spans))))

(defun ebox--span-wrapper-owners (span)
  "Return SPAN's wrapper owner stack, inner to outer."
  (or (get-text-property (car span) 'ebox-content-owners)
      (when-let ((owner (get-text-property (car span) 'ebox-content-owner)))
        (list owner))))

(defun ebox--common-wrapper-owners (owner-stacks)
  "Return owner ids common to every stack in OWNER-STACKS.
The returned order follows the first stack, preserving inner-to-outer order."
  (when owner-stacks
    (let ((common (copy-sequence (car owner-stacks))))
      (dolist (owners (cdr owner-stacks))
        (setq common
              (cl-remove-if-not
               (lambda (owner) (member owner owners))
               common)))
      common)))

(defun ebox--spans-wrapper-owners (spans)
  "Return outer wrapper owners shared by every nonempty SPAN.
When a replacement covers sibling boxes, child-specific owners from the first
line must not be copied into all new lines."
  (let (owner-stacks)
    (dolist (span spans)
      (when (< (car span) (cdr span))
        (push (ebox--span-wrapper-owners span) owner-stacks)))
    (ebox--common-wrapper-owners (nreverse owner-stacks))))

(defun ebox--string-content-owner-set (string)
  "Return a set of content owner ids present anywhere in STRING."
  (let ((pos 0)
        (limit (length string))
        (owners (make-hash-table :test 'equal)))
    (while (< pos limit)
      (dolist (owner (ebox--content-owner-stack-at string pos))
        (puthash owner t owners))
      (setq pos (ebox--next-content-owner-property-change
                 pos string limit)))
    owners))

(defun ebox-buffer--replacement-owner-set
    (rendered dirty &optional replaced-owner-ids)
  "Return RENDERED owners plus replaced history from DIRTY and OWNER-IDS."
  (let ((owners (ebox--string-content-owner-set rendered)))
    ;; Structural replacement must suppress removed child owners inherited
    ;; from the old lines.  They are replacement-owned history, not wrappers.
    (dolist (owner (plist-get dirty :old-region-ids))
      (puthash owner t owners))
    (dolist (owner replaced-owner-ids)
      (puthash owner t owners))
    owners))

(defun ebox-buffer--owners-inside-replacement-boundary
    (spans boundary-owner-ids)
  "Return old SPANS owners at or inside BOUNDARY-OWNER-IDS."
  (let ((boundary-set (make-hash-table :test 'equal))
        replaced)
    (dolist (owner boundary-owner-ids)
      (puthash owner t boundary-set))
    (dolist (span spans)
      (let ((position (car span))
            (limit (cdr span)))
        (while (< position limit)
          (let* ((owners (ebox--content-owner-stack-at nil position))
                 (boundary
                  (cl-position-if
                   (lambda (owner) (gethash owner boundary-set))
                   owners :from-end t)))
            (when boundary
              (setq replaced
                    (nconc (cl-subseq owners 0 (1+ boundary)) replaced))))
          (setq position
                (ebox--next-content-owner-property-change
                 position nil limit)))))
    (delete-dups replaced)))

(defun ebox--string-with-preserved-horizontal-border
    (string span owner box &optional edge)
  "Return STRING with OWNER's horizontal EDGE from SPAN and BOX.
Nil EDGE preserves both outer edges."
  (let ((result string))
    (when (and span (< (car span) (cdr span)))
      (when (and (memq edge '(nil top))
                 (equal (get-text-property (car span) 'ebox-bt) owner))
        (setq result
              (ebox--propertize-overline
               result (ebox-get box :border-top-color)))
        (add-text-properties 0 (length result) `(ebox-bt ,owner) result))
      (when (and (memq edge '(nil bottom))
                 (equal (get-text-property (car span) 'ebox-bb) owner))
        (setq result
              (ebox--propertize-underline
               result (ebox-get box :border-bottom-color)))
        (add-text-properties 0 (length result) `(ebox-bb ,owner) result)))
    result))

(defun ebox--string-with-preserved-wrapper-context
    (string owners rendered-owner-set &optional span horizontal-edge)
  "Return STRING with missing outer OWNERS restored.
RENDERED-OWNER-SET identifies already-owned content.  SPAN supplies old paint;
HORIZONTAL-EDGE limits restored border paint to `top', `bottom', or neither."
  (let* ((missing (cl-remove-if (lambda (owner)
                                  (gethash owner rendered-owner-set))
                                owners))
         (result (copy-sequence string)))
    (dolist (owner missing)
      (when-let ((box (gethash owner ebox--region-box-table)))
        (when-let ((color (ebox-get box :color)))
          (setq result (ebox--propertize-color result color)))
        (when-let ((bgcolor (ebox-get box :bgcolor)))
          (setq result (ebox--propertize-bgcolor result bgcolor)))
        (when-let ((properties (ebox-get box :surface-properties)))
          (setq result
                (ebox--apply-surface-properties result properties)))
        (setq result
              (ebox--string-with-preserved-horizontal-border
               result span owner box horizontal-edge))))
    (ebox--add-content-owners result missing)))

(defun ebox--string-with-preserved-wrapper-owners (spans string)
  "Return STRING preserving SPANS' outer wrapper ownership and paint."
  (let ((rendered-owner-set (ebox--string-content-owner-set string)))
    (if-let ((owners (ebox--spans-wrapper-owners spans)))
        (let* ((lines (ebox-string-lines string))
               (last-index (1- (length lines)))
               (last-span (car (last spans)))
               (interior-limit (1- (length spans))))
          (ebox-lines-join
           (cl-loop
            for line in lines
            for index from 0
            for span = (cond
                        ((zerop index) (car spans))
                        ((= index last-index) last-span)
                        ((< index interior-limit) (nth index spans)))
            for horizontal-edge = (cond
                                   ((zerop last-index) nil)
                                   ((zerop index) 'top)
                                   ((= index last-index) 'bottom)
                                   (t 'none))
            collect
            (ebox--string-with-preserved-wrapper-context
             line owners rendered-owner-set span horizontal-edge))))
      string)))

(defun ebox--replace-contiguous-line-spans
    (spans rendered &optional skip-wrapper-context)
  "Replace contiguous SPANS with RENDERED and return new spans on success.
When SKIP-WRAPPER-CONTEXT is non-nil, RENDERED already covers the complete
runtime root and therefore needs no ownership recovered from the old text."
  (when (and spans (ebox--line-spans-contiguous-p spans))
    (ebox--with-preserved-buffer-window-state (current-buffer)
      (let* ((inhibit-read-only t)
             (point-marker (copy-marker (point) t))
             (start (caar spans))
             (end (cdar (last spans)))
             (inserted
              (if skip-wrapper-context
                  rendered
                (ebox--string-with-preserved-wrapper-owners
                 spans rendered)))
             (start-marker (copy-marker start nil))
             (end-marker nil))
        (save-excursion
          (goto-char start)
          (delete-region start end)
          (insert inserted)
          (setq end-marker (copy-marker (point) t)))
        (goto-char (min (marker-position point-marker) (point-max)))
        (prog1
            (ebox--buffer-line-spans-between
             (marker-position start-marker)
             (marker-position end-marker))
          (set-marker point-marker nil)
          (set-marker start-marker nil)
          (set-marker end-marker nil))))))

(defun ebox-buffer--canonical-property-alist (properties)
  "Return text PROPERTIES in semantic key order.
Text-property plists are unordered maps even though their cons order can
change when strings cross the native module boundary."
  (sort (cl-loop for (key value) on properties by #'cddr
                 collect (cons key value))
        (lambda (left right)
          (string< (symbol-name (car left))
                   (symbol-name (car right))))))

(defun ebox-buffer--property-maps-equal-p (old-properties new-properties)
  "Return non-nil when two unordered property plists are semantically equal."
  (or (equal old-properties new-properties)
      (equal (ebox-buffer--canonical-property-alist old-properties)
             (ebox-buffer--canonical-property-alist new-properties))))

(defun ebox-buffer--myers-trace-value (trace distance diagonal)
  "Return TRACE's furthest position for DISTANCE and DIAGONAL."
  (if (or (< diagonal (- distance)) (> diagonal distance))
      -1
    (aref trace (+ diagonal distance))))

(defvar ebox-buffer--myers-maximum-edit-distance 128
  "Maximum exact edit distance used by root property diffing.")

(defvar ebox-buffer--myers-maximum-trace-cells 20000
  "Maximum retained Myers frontier cells for one root property diff.")

(defvar ebox-buffer--myers-maximum-work 250000
  "Maximum frontier and character-comparison work for one Myers diff.")

(defconst ebox-buffer--myers-budget-exceeded :budget-exceeded
  "Sentinel returned when exact root alignment exceeds its fixed budget.")

(defvar ebox-buffer--last-myers-stats nil
  "Diagnostic facts from the most recent bounded Myers alignment.")

(defvar ebox-buffer--last-property-patch-plan nil
  "Diagnostic facts from the most recent root property patch plan.")

(defun ebox-buffer--myers-text-matches (old new)
  "Return ordered equal runs from a bounded shortest-edit OLD/NEW alignment.
Each result is (OLD-START NEW-START LENGTH).  Text properties are checked
after textual alignment so large property-only geometry changes do not
inflate the edit-search frontier.  Return
`ebox-buffer--myers-budget-exceeded' when the deterministic edit, trace, or
work budget is exhausted."
  (let* ((old-length (length old))
         (new-length (length new))
         (maximum (+ old-length new-length))
         (distance-limit
          (min maximum (max 0 ebox-buffer--myers-maximum-edit-distance)))
         (traces (make-vector (1+ distance-limit) nil))
         (work 0)
         (trace-cells 0)
         final-distance stop-reason)
    (cl-labels
        ((consume-work
          ()
          (if (>= work (max 1 ebox-buffer--myers-maximum-work))
              (progn
                (setq stop-reason 'work-budget)
                (throw 'stop nil))
            (cl-incf work))))
      (catch 'stop
        (cl-loop
         for distance from 0 to distance-limit
         do
         (let ((current-cells (1+ (* 2 distance))))
           (when (> (+ trace-cells current-cells)
                    (max 1 ebox-buffer--myers-maximum-trace-cells))
             (setq stop-reason 'trace-budget)
             (throw 'stop nil))
           (cl-incf trace-cells current-cells)
           (let* ((previous (and (> distance 0)
                                 (aref traces (1- distance))))
                  (current (make-vector current-cells -1))
                  complete-p)
             (cl-loop
              for diagonal from (- distance) to distance by 2
              until complete-p
              do
              (consume-work)
              (let* ((down
                      (and previous
                           (ebox-buffer--myers-trace-value
                            previous (1- distance) (1+ diagonal))))
                     (right
                      (and previous
                           (ebox-buffer--myers-trace-value
                            previous (1- distance) (1- diagonal))))
                     (old-position
                      (cond
                       ((zerop distance) 0)
                       ((= diagonal (- distance)) down)
                       ((= diagonal distance) (1+ right))
                       ((< right down) down)
                       (t (1+ right))))
                     (new-position (- old-position diagonal)))
                (while (and (< old-position old-length)
                            (< new-position new-length)
                            (= (aref old old-position)
                               (aref new new-position)))
                  (consume-work)
                  (cl-incf old-position)
                  (cl-incf new-position))
                (aset current (+ diagonal distance) old-position)
                (when (and (>= old-position old-length)
                           (>= new-position new-length))
                  (setq complete-p t))))
             (aset traces distance current)
             (when complete-p
               (setq final-distance distance
                     stop-reason 'complete)
               (throw 'stop t)))))
        (setq stop-reason
              (if (< distance-limit maximum)
                  'edit-distance-budget
                'incomplete))))
    (setq ebox-buffer--last-myers-stats
          (list :status stop-reason
                :work work
                :trace-cells trace-cells
                :distance final-distance
                :maximum-distance maximum))
    (if (null final-distance)
        ebox-buffer--myers-budget-exceeded
      (let ((old-position old-length)
            (new-position new-length)
            matches)
        (cl-loop
         for distance from final-distance downto 1
         do
         (let* ((previous-distance (1- distance))
                (previous (aref traces previous-distance))
                (diagonal (- old-position new-position))
                (previous-diagonal
                 (if (or (= diagonal (- distance))
                         (and (/= diagonal distance)
                              (< (ebox-buffer--myers-trace-value
                                  previous previous-distance
                                  (1- diagonal))
                                 (ebox-buffer--myers-trace-value
                                  previous previous-distance
                                  (1+ diagonal)))))
                     (1+ diagonal)
                   (1- diagonal)))
                (previous-old
                 (ebox-buffer--myers-trace-value
                  previous previous-distance previous-diagonal))
                (previous-new (- previous-old previous-diagonal)))
           (when (and (> old-position previous-old)
                      (> new-position previous-new))
             (let ((length
                    (min (- old-position previous-old)
                         (- new-position previous-new))))
               (push (list (- old-position length)
                           (- new-position length)
                           length)
                     matches)))
           (setq old-position previous-old
                 new-position previous-new)))
        (when (and (> old-position 0) (> new-position 0))
          (let ((length (min old-position new-position)))
            (push (list (- old-position length)
                        (- new-position length)
                        length)
                  matches)))
        matches))))

(defun ebox-buffer--common-text-edges (old new)
  "Return non-overlapping common prefix and suffix lengths for OLD and NEW."
  (let* ((old-length (length old))
         (new-length (length new))
         (shared-limit (min old-length new-length))
         (prefix 0)
         (suffix 0))
    (while (and (< prefix shared-limit)
                (= (aref old prefix) (aref new prefix)))
      (cl-incf prefix))
    (while (and (< suffix (- old-length prefix))
                (< suffix (- new-length prefix))
                (= (aref old (- old-length suffix 1))
                   (aref new (- new-length suffix 1))))
      (cl-incf suffix))
    (cons prefix suffix)))

(defun ebox-buffer--push-property-patch
    (patches old-start old-end new-start new-end)
  "Add one changed range to reverse-order PATCHES, coalescing adjacency."
  (if (and (= old-start old-end) (= new-start new-end))
      patches
    (let ((previous (car patches)))
      (if (and previous
               (= (plist-get previous :old-end) old-start)
               (= (plist-get previous :new-end) new-start))
          (progn
            (plist-put previous :old-end old-end)
            (plist-put previous :new-end new-end)
            patches)
        (cons (list :old-start old-start :old-end old-end
                    :new-start new-start :new-end new-end)
              patches)))))

(defun ebox-buffer--property-interval-index (string)
  "Return a position index over STRING's compact property intervals."
  (let* ((length (length string))
         (index (make-vector length (list 0 length nil))))
    (dolist (interval (object-intervals string))
      (let ((position (nth 0 interval))
            (end (nth 1 interval)))
        (while (< position end)
          (aset index position interval)
          (cl-incf position))))
    index))

(defun ebox-buffer--property-run-patches
    (old-index new-index old-start new-start length patches)
  "Add property changes inside one aligned text run to PATCHES.
OLD-START and NEW-START begin an equal-character run of LENGTH.  Properties
are compared once per property interval instead of once per character."
  (let ((old-position old-start)
        (new-position new-start)
        (old-limit (+ old-start length))
        (new-limit (+ new-start length)))
    (while (< old-position old-limit)
      (let* ((old-interval (aref old-index old-position))
             (new-interval (aref new-index new-position))
             (old-change (min old-limit (nth 1 old-interval)))
             (new-change (min new-limit (nth 1 new-interval)))
             (segment-length
              (min (- old-change old-position)
                   (- new-change new-position))))
        (unless (ebox-buffer--property-maps-equal-p
                 (nth 2 old-interval)
                 (nth 2 new-interval))
          (setq patches
                (ebox-buffer--push-property-patch
                 patches
                 old-position (+ old-position segment-length)
                 new-position (+ new-position segment-length))))
        (setq old-position (+ old-position segment-length)
              new-position (+ new-position segment-length))))
    patches))

(defun ebox-buffer--aligned-property-patches
    (old new old-index new-index matches)
  "Return property-aware patches for OLD, NEW, and textual MATCHES."
  (let ((old-position 0)
        (new-position 0)
        patches)
    (dolist (match matches)
      (let ((matched-old (nth 0 match))
            (matched-new (nth 1 match))
            (run-length (nth 2 match)))
        (when (or (< old-position matched-old)
                  (< new-position matched-new))
          (setq patches
                (ebox-buffer--push-property-patch
                 patches old-position matched-old
                 new-position matched-new)))
        (setq patches
              (ebox-buffer--property-run-patches
               old-index new-index
               matched-old matched-new run-length patches))
        (setq old-position (+ matched-old run-length)
              new-position (+ matched-new run-length))))
    (setq patches
          (ebox-buffer--push-property-patch
           patches old-position (length old)
           new-position (length new)))
    (nreverse patches)))

(defun ebox-buffer--minimal-property-patches (old new)
  "Return bounded property-aware replacement patches from OLD to NEW.
Text-equal strings produce one patch per disjoint property change.  Text
changes retain exact common edges and use a shortest edit alignment while it
fits a deterministic budget.  When the middle exceeds that budget, one
correct middle replacement is used instead of blocking Emacs on an unbounded
quadratic trace.  Patch coordinates are zero-based half-open offsets in OLD
and NEW."
  (setq ebox-buffer--last-myers-stats nil)
  (let ((old-length (length old)))
    (if (equal old new)
        (let ((old-index (ebox-buffer--property-interval-index old))
              (new-index (ebox-buffer--property-interval-index new)))
          (setq ebox-buffer--last-property-patch-plan
                (list :strategy 'property-only
                      :work 0 :trace-cells 0))
          (nreverse
           (ebox-buffer--property-run-patches
            old-index new-index 0 0 old-length nil)))
      (let* ((new-length (length new))
             (edges (ebox-buffer--common-text-edges old new))
             (prefix (car edges))
             (suffix (cdr edges))
             (old-middle-end (- old-length suffix))
             (new-middle-end (- new-length suffix))
             (old-middle-length (- old-middle-end prefix))
             (new-middle-length (- new-middle-end prefix))
             (middle-matches
              (if (or (zerop old-middle-length)
                      (zerop new-middle-length))
                  nil
                (ebox-buffer--myers-text-matches
                 (substring old prefix old-middle-end)
                 (substring new prefix new-middle-end))))
             (fallback-p
              (eq middle-matches ebox-buffer--myers-budget-exceeded))
             (matches
              (append
               (when (> prefix 0)
                 (list (list 0 0 prefix)))
               (unless fallback-p
                 (mapcar
                  (lambda (match)
                    (list (+ prefix (nth 0 match))
                          (+ prefix (nth 1 match))
                          (nth 2 match)))
                  middle-matches))
               (when (> suffix 0)
                 (list (list (- old-length suffix)
                             (- new-length suffix)
                             suffix)))))
             (stats ebox-buffer--last-myers-stats)
             (strategy
              (cond
               (fallback-p 'bounded-fallback)
               ((or (zerop old-middle-length)
                    (zerop new-middle-length))
                'exact-edges)
               (t 'exact-myers)))
             (old-index
              (and matches (ebox-buffer--property-interval-index old)))
             (new-index
              (and matches (ebox-buffer--property-interval-index new))))
        (setq ebox-buffer--last-property-patch-plan
              (list :strategy strategy
                    :common-prefix prefix
                    :common-suffix suffix
                    :myers-status (plist-get stats :status)
                    :work (or (plist-get stats :work) 0)
                    :trace-cells (or (plist-get stats :trace-cells) 0)
                    :distance (plist-get stats :distance)))
        (ebox-buffer--aligned-property-patches
         old new old-index new-index matches)))))

(defun ebox-buffer--prepare-root-property-patches (spans rendered)
  "Prepare a property-aware root replacement for SPANS and RENDERED.
This function reads the current buffer but does not modify it."
  (when (and spans (ebox--line-spans-contiguous-p spans))
    (let* ((start (caar spans))
           (end (cdar (last spans)))
           (old (buffer-substring start end))
           (patches (ebox-buffer--minimal-property-patches old rendered))
           (diff-plan ebox-buffer--last-property-patch-plan))
      (list :start start
            :end end
            :base old
            :rendered rendered
            :patches patches
            :diff-strategy (plist-get diff-plan :strategy)
            :diff-work (plist-get diff-plan :work)
            :diff-trace-cells (plist-get diff-plan :trace-cells)
            :full-root-required-p
            (and (= (length patches) 1)
                 (let ((patch (car patches)))
                   (and (zerop (plist-get patch :old-start))
                        (= (plist-get patch :old-end) (length old))
                        (zerop (plist-get patch :new-start))
                        (= (plist-get patch :new-end)
                           (length rendered)))))))))

(defun ebox-buffer--publish-prepared-root-property-patches (prepared)
  "Publish PREPARED root property patches and return publication metadata."
  (let* ((start (plist-get prepared :start))
         (end (plist-get prepared :end))
         (base (plist-get prepared :base))
         (rendered (plist-get prepared :rendered))
         (patches (plist-get prepared :patches)))
    (when (and (integer-or-marker-p start)
               (integer-or-marker-p end)
               (stringp base)
               (stringp rendered)
               (= (- end start) (length base))
               (equal (buffer-substring start end) base))
      (ebox--with-preserved-buffer-window-state (current-buffer)
        (let ((inhibit-read-only t)
              (root-start-marker (copy-marker start nil))
              (root-end-marker (copy-marker end t))
              published-markers)
          (unwind-protect
              (progn
                (atomic-change-group
                  (dolist (patch (reverse patches))
                    (let* ((old-start (+ start (plist-get patch :old-start)))
                           (old-end (+ start (plist-get patch :old-end)))
                           (new-start (plist-get patch :new-start))
                           (new-end (plist-get patch :new-end))
                           (published-start (copy-marker old-start nil)))
                      (goto-char old-start)
                      (delete-region old-start old-end)
                      (insert (substring rendered new-start new-end))
                      (push (cons published-start (copy-marker (point) t))
                            published-markers))))
                (list
                 :new-buffer-spans
                 (ebox--buffer-line-spans-between
                  (marker-position root-start-marker)
                  (marker-position root-end-marker))
                 :published-buffer-spans
                 (mapcar (lambda (span)
                           (cons (marker-position (car span))
                                 (marker-position (cdr span))))
                         published-markers)
                 :patches patches
                 :diff-strategy (plist-get prepared :diff-strategy)
                 :diff-work (plist-get prepared :diff-work)
                 :diff-trace-cells (plist-get prepared :diff-trace-cells)
                 :full-root-required-p
                 (plist-get prepared :full-root-required-p)))
            (set-marker root-start-marker nil)
            (set-marker root-end-marker nil)
            (dolist (span published-markers)
              (set-marker (car span) nil)
              (set-marker (cdr span) nil))))))))

(defun ebox-buffer--replace-root-with-property-patches (spans rendered)
  "Replace root SPANS with RENDERED through bounded property-aware writes.
Return the resulting root line spans, the actually published buffer spans,
and whether correctness required replacing the complete root."
  (when-let ((prepared
              (ebox-buffer--prepare-root-property-patches spans rendered)))
    (ebox-buffer--publish-prepared-root-property-patches prepared)))

(defun ebox-buffer-publish-prepared-root (buffer rendered)
  "Publish prepared root string RENDERED into BUFFER.

This function owns only the property-aware buffer write.  Declarative tree
validation, candidate rendering, and runtime state publication belong to the
incremental transaction layer.  The caller may wrap this function in a wider
`atomic-change-group' that includes its own publication work."
  (unless (buffer-live-p buffer)
    (error "Ebox cannot publish into dead buffer %S" buffer))
  (unless (stringp rendered)
    (error "Ebox prepared root must be a string"))
  (with-current-buffer buffer
    (let ((spans (ebox--buffer-line-spans-between (point-min) (point-max))))
      (or (ebox-buffer--replace-root-with-property-patches spans rendered)
          (error "Ebox could not publish the prepared root")))))

(defun ebox-buffer--role-delta-region-ids (role-delta)
  "Return region ids affected by ROLE-DELTA."
  (delete-dups
   (delq nil
         (mapcar
          (lambda (entry)
            (car-safe (plist-get entry :key)))
          (plist-get role-delta :entries)))))

(defun ebox-buffer--preflight-native-root-property-patches
    (spans native-patch)
  "Return a validated text publication plan for Rust NATIVE-PATCH.
The plan validates current root SPANS, source/target counts, patch ordering,
replacement payloads, and complete prepared root metadata.  It translates the
prepared role table and preflights extent and scroll target ranges without
publishing text, role tables, extent templates, scroll state, or markers."
  (when (and spans
             (ebox--line-spans-contiguous-p spans)
             (plist-get native-patch :native-patch)
             (eq (plist-get native-patch :patch-origin) 'rust))
    (let* ((start (caar spans))
           (end (cdar (last spans)))
           (base-character-count
            (plist-get native-patch :base-character-count))
           (target-character-count
            (plist-get native-patch :target-character-count))
           (target-line-count (plist-get native-patch :target-line-count))
           (patches (plist-get native-patch :patches))
           (root-render-metadata
            (plist-get native-patch :root-render-metadata))
           (prepared-metadata-p
            (plist-get root-render-metadata :prepared-p))
           (role-template
            (and prepared-metadata-p
                 (plist-get root-render-metadata :role-span-template)))
           (extent-template
            (and prepared-metadata-p
                 (plist-get root-render-metadata :box-extent-template)))
           (scroll-template
            (and prepared-metadata-p
                 (plist-get root-render-metadata
                            :scroll-content-span-template)))
           (prepared-role-table
            (and (hash-table-p role-template)
                 (ebox-buffer--region-role-span-table-from-template
                  role-template start)))
           prepared-extent-table
           scroll-preflight
           role-delta
           (previous-old-end 0)
           (previous-new-end 0))
      (unless (and (integerp base-character-count)
                   (= base-character-count (- end start))
                   (integerp target-character-count)
                   (>= target-character-count 0)
                   (integerp target-line-count)
                   (> target-line-count 0)
                   (listp patches))
        (error "Native root patch does not match the current buffer"))
      (dolist (patch patches)
        (let ((old-start (plist-get patch :old-start))
              (old-end (plist-get patch :old-end))
              (new-start (plist-get patch :new-start))
              (new-end (plist-get patch :new-end))
              (replacement (plist-get patch :replacement)))
          (unless (and (integerp old-start) (integerp old-end)
                       (integerp new-start) (integerp new-end)
                       (<= previous-old-end old-start old-end
                           base-character-count)
                       (<= previous-new-end new-start new-end
                           target-character-count)
                       (= (- old-start previous-old-end)
                          (- new-start previous-new-end))
                       (stringp replacement)
                       (= (length replacement) (- new-end new-start)))
            (error "Native root patch contains invalid ranges"))
          (setq previous-old-end old-end
                previous-new-end new-end)))
      (unless (= (- base-character-count previous-old-end)
                 (- target-character-count previous-new-end))
        (error "Native root patch has an inconsistent target length"))
      (when (and prepared-metadata-p
                 (not (and (hash-table-p role-template)
                           (hash-table-p extent-template)
                           (hash-table-p scroll-template))))
        (error "Native root patch lacks prepared target indexes"))
      (when prepared-role-table
        (ebox-buffer--validate-role-span-template
         prepared-role-table start target-character-count))
      (when (hash-table-p extent-template)
        (setq prepared-extent-table
              (ebox-buffer--validate-box-extent-template
               extent-template start target-character-count)))
      (when (hash-table-p scroll-template)
        (setq scroll-preflight
              (ebox--preflight-scroll-content-span-template
               (current-buffer) scroll-template start target-character-count)))
      (unless prepared-role-table
        (setq role-delta
              (ebox-buffer--capture-role-delta start patches)))
      (list
       :start start
       :end end
       :base-character-count base-character-count
       :target-character-count target-character-count
       :target-line-count target-line-count
       :patches patches
       :patch-plan
       (mapcar
        (lambda (patch)
          (cons patch
                (ebox-buffer--in-place-property-patch-p start patch)))
        patches)
       :root-render-metadata root-render-metadata
       :prepared-role-table prepared-role-table
       :prepared-extent-table prepared-extent-table
       :role-delta role-delta
       :scroll-preflight scroll-preflight
       :replacement-bytes
       (or (plist-get native-patch :replacement-bytes)
           (cl-loop for patch in patches
                    sum (string-bytes
                         (plist-get patch :replacement))))))))

(defun ebox-buffer--publish-native-root-property-patch-text (plan)
  "Apply validated native root text PLAN and return publication metadata.
The caller owns the surrounding `atomic-change-group' and all runtime index
publication.  This function mutates only buffer text and text properties."
  (let* ((start (plist-get plan :start))
         (end (plist-get plan :end))
         (target-character-count
          (plist-get plan :target-character-count))
         (target-line-count (plist-get plan :target-line-count))
         (patches (plist-get plan :patches))
         (root-start-marker (copy-marker start nil))
         (root-end-marker (copy-marker end t))
         published-spans)
    (unwind-protect
        (progn
          (dolist (planned (reverse (plist-get plan :patch-plan)))
            (let* ((patch (car planned))
                   (in-place-p (cdr planned))
                   (old-start (+ start (plist-get patch :old-start)))
                   (old-end (+ start (plist-get patch :old-end)))
                   (replacement (plist-get patch :replacement)))
              (if in-place-p
                  (ebox-buffer--apply-string-properties-in-place
                   old-start replacement)
                (goto-char old-start)
                (delete-region old-start old-end)
                (insert replacement))
              ;; Rust already supplied validated target coordinates.  Recording
              ;; them directly avoids allocating and moving two temporary
              ;; markers for every minimal property span.
              (push (cons (+ start (plist-get patch :new-start))
                          (+ start (plist-get patch :new-end)))
                    published-spans)))
          (unless (= (- (marker-position root-end-marker)
                        (marker-position root-start-marker))
                     target-character-count)
            (error "Native root patch published the wrong target length"))
          (let ((new-spans
                 (ebox--buffer-line-spans-between
                  (marker-position root-start-marker)
                  (marker-position root-end-marker))))
            (unless (= (length new-spans) target-line-count)
              (error "Native root patch published the wrong line count"))
            (let* ((role-delta (plist-get plan :role-delta))
                   (scroll-preflight (plist-get plan :scroll-preflight))
                   (scroll-region-ids
                    (plist-get scroll-preflight :scroll-region-ids)))
              (list
               :new-buffer-spans new-spans
               :published-buffer-spans published-spans
               :patches patches
               :role-delta role-delta
               :affected-region-ids
               (or scroll-region-ids
                   (ebox-buffer--role-delta-region-ids role-delta))
               :patch-origin 'rust
               :full-frame-bytes 0
               :replacement-bytes
               (plist-get plan :replacement-bytes)
               :full-root-required-p
               (and (= (length patches) 1)
                    (let ((patch (car patches)))
                      (and (zerop (plist-get patch :old-start))
                           (= (plist-get patch :old-end)
                              (plist-get plan :base-character-count))
                           (zerop (plist-get patch :new-start))
                           (= (plist-get patch :new-end)
                              target-character-count))))))))
      (set-marker root-start-marker nil)
      (set-marker root-end-marker nil))))

(defun ebox-buffer--apply-root-property-patches (spans native-patch)
  "Apply Rust-origin NATIVE-PATCH directly inside contiguous root SPANS.
No complete old or target string is allocated.  The native tape parser has
already validated semantic patch ordering; this compatibility boundary repeats
the buffer-relative length and replacement checks before one atomic write."
  (when-let ((plan
              (ebox-buffer--preflight-native-root-property-patches
               spans native-patch)))
    (ebox--with-preserved-buffer-window-state (current-buffer)
      (let ((inhibit-read-only t))
        (atomic-change-group
          (ebox-buffer--publish-native-root-property-patch-text plan))))))

(defun ebox--line-with-preserved-wrapper-owner
    (span line rendered-owner-set)
  "Return LINE preserving SPAN's outer wrapper ownership and paint."
  (let ((owners (or (get-text-property (car span) 'ebox-content-owners)
                    (when-let ((owner (get-text-property
                                       (car span)
                                       'ebox-content-owner)))
                      (list owner)))))
    (if owners
        (ebox--string-with-preserved-wrapper-context
         line owners rendered-owner-set span)
      line)))

(defun ebox--paint-line-spans (spans rendered)
  "Copy RENDERED paint over SPANS while retaining wrapper context."
  (let ((lines (ebox-string-lines rendered))
        (owner-set (ebox--string-content-owner-set rendered)))
    (when (and (= (length spans) (length lines))
               (cl-loop for span in spans
                        for line in lines
                        always
                        (and (= (- (cdr span) (car span)) (length line))
                             (string=
                              (buffer-substring-no-properties
                               (car span) (cdr span))
                              (substring-no-properties line)))))
      (let ((inhibit-read-only t))
        (cl-loop for span in spans
                 for line in lines
                 do (ebox--copy-string-text-properties-to-buffer
                     (ebox--line-with-preserved-wrapper-owner
                      span line owner-set)
                     (car span))))
      t)))

(defun ebox-buffer--external-extent-boundaries (span)
  "Return live extent markers immediately outside SPAN.
The car contains left-side end markers; the cdr contains right-side start
markers.  These markers must stay outside a replacement inserted at SPAN."
  (let ((buffer (current-buffer))
        (start (car span))
        (end (cdr span))
        (region-ids
         (delete-dups
          (append
           (and (> (car span) (point-min))
                (ebox-buffer--region-ids-at (1- (car span))))
           (and (< (cdr span) (point-max))
                (ebox-buffer--region-ids-at (cdr span))))))
        left right)
    (dolist (region-id region-ids)
      (when-let ((extents (gethash region-id ebox--box-extents)))
        (let ((extent-start (car extents))
              (extent-end (cdr extents)))
          (when (and (eq (marker-buffer extent-start) buffer)
                     (eq (marker-buffer extent-end) buffer))
            (cond
             ((and (< (marker-position extent-start) start)
                   (= (marker-position extent-end) start))
              (push extent-end left))
             ((and (= (marker-position extent-start) end)
                   (> (marker-position extent-end) end))
              (push extent-start right)))))))
    (cons left right)))

(defun ebox--replace-line-spans
    (spans rendered &optional rendered-owner-set skip-wrapper-context)
  "Replace SPANS with RENDERED lines and return new spans on success.
RENDERED-OWNER-SET avoids rescanning an already inspected replacement.
When SKIP-WRAPPER-CONTEXT is non-nil, the replacement is the complete runtime
root and no ownership may exist outside it."
  (if (and skip-wrapper-context
           (ebox--line-spans-contiguous-p spans))
      (ebox--replace-contiguous-line-spans spans rendered t)
    (ebox--with-preserved-buffer-window-state (current-buffer)
      (let ((lines (ebox-string-lines rendered))
            (rendered-owner-set
             (or rendered-owner-set
                 (ebox--string-content-owner-set rendered))))
        (if (= (length spans) (length lines))
            (let (new-span-markers)
              (let ((inhibit-read-only t)
                    (point-marker (copy-marker (point) t)))
                (save-excursion
                  (cl-loop for span in (reverse spans)
                           for line in (reverse lines)
                           do (progn
                                (let* ((start (car span))
                                       (extent-boundaries
                                        (ebox-buffer--external-extent-boundaries
                                         span)))
                                  (goto-char start)
                                  (setq line
                                        (ebox--line-with-preserved-wrapper-owner
                                         span line rendered-owner-set))
                                  (delete-region start (cdr span))
                                  (insert line)
                                  (dolist (marker (car extent-boundaries))
                                    (set-marker marker start))
                                  (dolist (marker (cdr extent-boundaries))
                                    (set-marker marker (point)))
                                  (push (cons (copy-marker start nil)
                                              (copy-marker (point) t))
                                        new-span-markers)))))
                (goto-char (min (marker-position point-marker) (point-max)))
                (set-marker point-marker nil))
              (prog1
                  (mapcar (lambda (span)
                            (cons (marker-position (car span))
                                  (marker-position (cdr span))))
                          new-span-markers)
                (dolist (span new-span-markers)
                  (set-marker (car span) nil)
                  (set-marker (cdr span) nil))))
          (ebox--replace-contiguous-line-spans spans rendered))))))

(defun ebox-buffer--span-slot-width (span)
  "Return SPAN's visual slot width in its current buffer line."
  (save-excursion
    (goto-char (car span))
    (let ((line-start (line-beginning-position)))
      (- (ebox--string-pixel-width
          (buffer-substring line-start (cdr span)))
         (ebox--string-pixel-width
         (buffer-substring line-start (car span)))))))

(defun ebox-buffer--partial-line-slots-p (spans)
  "Return non-nil when SPANS are parent-owned partial line slots."
  (cl-some (lambda (span)
             (save-excursion
               (goto-char (car span))
               (not (and (= (car span) (line-beginning-position))
                         (= (cdr span) (line-end-position))))))
           spans))

(defun ebox-buffer--pad-line-to-slot-width (line width)
  "Return LINE padded to visual slot WIDTH, or nil if LINE is wider."
  (let* ((line-width (ebox--string-pixel-width line))
         (extra (- width line-width)))
    (when (>= extra 0)
      (concat line (ebox-pixel-space extra)))))

(defun ebox-buffer--slots-require-wrapper-side-border-p (spans owner-set)
  "Return non-nil when SPANS contain side borders absent from OWNER-SET."
  (cl-some
   (lambda (span)
     (cl-some
      (lambda (property)
        (let ((position (car span))
              (limit (cdr span))
              owner)
          (while (and (< position limit)
                      (progn
                        (setq owner (get-text-property position property))
                        (or (not owner)
                            (and owner-set (gethash owner owner-set)))))
            (setq position
                  (or (next-single-property-change
                       position property nil limit)
                      limit)))
          (and owner (< position limit))))
      '(ebox-bl ebox-br)))
   spans))

(defun ebox-buffer--rendered-in-existing-slots
    (spans rendered &optional owner-set require-exact-width-p)
  "Return RENDERED padded to fit SPANS' safe old parent slots.
Return nil when RENDERED needs more lines or width than the old slots provide.
When REQUIRE-EXACT-WIDTH-P is non-nil, decline padding that would hide a
parent layout change."
  (let* ((lines (ebox-string-lines rendered))
         (slot-count (length spans))
         (slot-widths (mapcar #'ebox-buffer--span-slot-width spans))
         (line-widths (mapcar #'ebox--string-pixel-width lines)))
    (when (and (or (null owner-set)
                   (not
                    (ebox-buffer--slots-require-wrapper-side-border-p
                     spans owner-set)))
               (ebox-buffer--partial-line-slots-p spans)
               (<= (length lines) slot-count)
               (or (not require-exact-width-p)
                   (cl-loop for width in line-widths
                            for slot-width in slot-widths
                            always (= width slot-width))))
      (let (padded ok)
        (setq ok t)
        (cl-loop for width in slot-widths
                 for line = (or (pop lines) (ebox-pixel-space 0))
                 do (if-let ((padded-line
                              (ebox-buffer--pad-line-to-slot-width
                               line width)))
                        (push padded-line padded)
                      (setq ok nil)))
        (when ok
          (ebox-lines-join (nreverse padded)))))))

(defun ebox-buffer--inline-slot-span-patch-op-p (op)
  "Return non-nil when OP may use old slot padding as an L2 span patch."
  (let ((changed-keys (plist-get (plist-get op :dirty) :changed-keys)))
    (and changed-keys
         (cl-every (lambda (key)
                     (memq key '(:margin-left-pixel :margin-right-pixel)))
                   changed-keys))))

(defun ebox--execute-paint-patch (buffer op)
  "Execute paint patch OP in BUFFER and return patch metadata."
  (let* ((owner-id (plist-get op :owner-id))
         (node (ebox--buffer-runtime-node buffer owner-id)))
    (when node
      (or (ebox--execute-text-property-paint-patch buffer op node)
          (let* ((dirty (plist-get op :dirty))
                 (old (or (ebox--ensure-layout-snapshot-spans
                           buffer owner-id)
                          (plist-get dirty :old)))
                 (spans (plist-get old :buffer-spans)))
            (and spans
                 (ebox--with-buffer-render-context buffer
                   (let* ((ebox--defer-scroll-content-index t)
                          (rendered (ebox-render node)))
                     (when (with-current-buffer buffer
                             (ebox--paint-line-spans spans rendered))
                       (list :owner-id owner-id
                             :op 'paint-patch
                             :owner-type (plist-get node :ebox-type)
                             :span-count (length spans)))))))))))

(defun ebox-buffer--span-line-range (spans)
  "Return inclusive line range covered by SPANS in the current buffer."
  (when spans
    (let (lines)
      (dolist (span spans)
        (save-excursion
          (goto-char (car span))
          (push (line-number-at-pos (car span) t) lines)))
      (cons (apply #'min lines) (apply #'max lines)))))

(defun ebox-buffer--line-range-overlap-p (left right)
  "Return non-nil when inclusive line ranges LEFT and RIGHT overlap."
  (and left right
       (<= (car left) (cdr right))
       (<= (car right) (cdr left))))

(defun ebox-buffer--line-span-at-number (line-number)
  "Return whole-line span at LINE-NUMBER in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line-number))
    (cons (line-beginning-position) (line-end-position))))

(defun ebox-buffer--position-after-pixel-width (start pixel-width)
  "Return position after PIXEL-WIDTH pixels from START on the same line."
  (save-excursion
    (goto-char start)
    (let ((end (line-end-position))
          (pos start)
          (width 0)
          found)
      (while (and (< pos end) (not found))
        (let* ((next (1+ pos))
               (char-width (ebox--substring-pixel-width
                            (buffer-substring pos next) 0 1)))
          (setq width (+ width char-width))
          (setq pos next)
          (when (= width pixel-width)
            (setq found pos))))
      found)))

(defun ebox-buffer--foreign-content-owner-in-range-p
    (start end owned-region-ids)
  "Return non-nil when START..END crosses content outside OWNED-REGION-IDS."
  (let ((owned (ebox--region-id-set owned-region-ids))
        (position start)
        foreign)
    (while (and (< position end) (not foreign))
      (let ((region-id (get-text-property position 'ebox-content)))
        (when (and region-id (not (gethash region-id owned)))
          (setq foreign t)))
      (setq position
            (or (next-single-property-change
                 position 'ebox-content nil end)
                end)))
    foreign))

(defun ebox-buffer--contained-flex-fixed-slot-size (node)
  "Return NODE's fixed outer `(WIDTH . HEIGHT)' slot size, or nil."
  (when-let ((style-node (ebox-fragment-style-source-node node)))
    (let ((width (ebox--flex-box-main-constraint style-node 'row :width))
          (height
           (ebox--flex-box-main-constraint style-node 'column :height)))
      (when (and (integerp width) (> width 0)
                 (integerp height) (> height 0)
                 (zerop (ebox-get style-node :margin-left-pixel))
                 (zerop (ebox-get style-node :margin-right-pixel))
                 (zerop (ebox-get style-node :margin-top-height))
                 (zerop (ebox-get style-node :margin-bottom-height)))
        (cons width height)))))

(defun ebox-buffer--contained-flex-publication-spans
    (buffer node-id node spans &optional replaced-region-ids)
  "Return fixed-slot publication spans for contained partial flex NODE-ID."
  (when-let* (((ebox--contained-partial-flex-owner-p buffer node-id))
              ((ebox--definite-containment-formatting-context-p
                buffer node-id))
              (size (ebox-buffer--contained-flex-fixed-slot-size node))
              ((= (length spans) (cdr size)))
              (owned-region-ids
               (append (ebox--node-all-region-ids node)
                       replaced-region-ids)))
    (catch 'unsafe
      (let ((expected-line
             (line-number-at-pos (caar spans) t))
            expanded)
        (dolist (span spans (nreverse expanded))
          (unless (= (line-number-at-pos (car span) t) expected-line)
            (throw 'unsafe nil))
          (let ((end (ebox-buffer--position-after-pixel-width
                      (car span) (car size))))
            (unless (and end (<= (cdr span) end)
                         (not
                          (ebox-buffer--foreign-content-owner-in-range-p
                           (car span) end owned-region-ids)))
              (throw 'unsafe nil))
            (push (cons (car span) end) expanded))
          (setq expected-line (1+ expected-line)))))))

(defun ebox-buffer--node-role-spans (node)
  "Return role spans for NODE and descendants in the current buffer."
  (when-let ((region-ids (ebox--node-all-region-ids node)))
    (unless (ebox-buffer--region-role-span-table)
      (ebox-buffer-refresh-region-role-spans (current-buffer)))
    (when-let ((table (ebox-buffer--region-role-span-table)))
      (let (spans)
        (dolist (region-id region-ids)
          (dolist (entry ebox-region-types)
            (setq spans
                  (append (copy-sequence
                           (gethash
                            (ebox-buffer--region-role-key
                             region-id (car entry))
                            table))
                          spans))))
        spans))))

(defun ebox-buffer--spans-line-range (spans)
  "Return inclusive line range covered by SPANS in the current buffer."
  (let (start-line end-line)
    (dolist (span spans)
      (when (< (car span) (cdr span))
        (let ((first-line (line-number-at-pos (car span) t))
              (last-line (line-number-at-pos (1- (cdr span)) t)))
          (setq start-line (if start-line
                               (min start-line first-line)
                             first-line))
          (setq end-line (if end-line
                             (max end-line last-line)
                           last-line)))))
    (and start-line end-line (cons start-line end-line))))

(defun ebox-buffer--node-line-range (buffer node)
  "Return NODE's current buffer line range without completing snapshots."
  (with-current-buffer buffer
    (ebox-buffer--spans-line-range
     (ebox-buffer--node-role-spans node))))

(defun ebox-buffer--node-line-pixel-width (node line-span)
  "Return NODE's covered pixel width on LINE-SPAN in the current buffer."
  (let (start end)
    (dolist (span (ebox-buffer--node-role-spans node))
      (when (and (< (car span) (cdr line-span))
                 (> (cdr span) (car line-span)))
        (setq start (if start
                        (min start (max (car span) (car line-span)))
                      (max (car span) (car line-span))))
        (setq end (if end
                      (max end (min (cdr span) (cdr line-span)))
                    (min (cdr span) (cdr line-span))))))
    (when (and start end (< start end))
      (ebox--substring-pixel-width
       (buffer-substring start end) 0 (- end start)))))

(defun ebox-buffer--child-line-item-main-footprint
    (buffer child-ids line-number)
  "Return summed child item width for CHILD-IDS on LINE-NUMBER."
  (with-current-buffer buffer
    (let ((line-span (ebox-buffer--line-span-at-number line-number))
          widths)
      (dolist (child-id child-ids)
        (when-let* ((node (ebox--buffer-runtime-node buffer child-id))
                    (width (ebox-buffer--node-line-pixel-width
                            node line-span)))
          (push width widths)))
      (when (= (length widths) (length child-ids))
        (apply #'+ widths)))))

(defun ebox-buffer--child-line-ranges (buffer flex-node)
  "Return direct child line ranges for FLEX-NODE in BUFFER."
  (let (ranges)
    (dolist (child (plist-get flex-node :children))
      (let* ((source (ebox--flex-item-source-node child))
             (child-id (plist-get source :node-id))
             (range (and child-id
                         (ebox-buffer--node-line-range buffer source))))
        (when range
          (push (cons child-id range) ranges))))
    (nreverse ranges)))

(defun ebox-buffer--child-content-start-on-line (buffer child-ids line-number)
  "Return minimum child span start for CHILD-IDS on LINE-NUMBER."
  (let (starts)
    (with-current-buffer buffer
      (let ((line-span (ebox-buffer--line-span-at-number line-number)))
        (dolist (child-id child-ids)
          (when-let ((node (ebox--buffer-runtime-node buffer child-id)))
            (dolist (span (ebox-buffer--node-role-spans node))
              (when (and (< (car span) (cdr line-span))
                         (> (cdr span) (car line-span)))
                (push (max (car span) (car line-span)) starts)))))))
    (and starts (apply #'min starts))))

(defun ebox-buffer--rendered-flex-row-lines
    (buffer line-spans start-line child-ids rendered-content main-size)
  "Return full replacement lines for LINE-SPANS using RENDERED-CONTENT."
  (catch 'failed
    (let ((content-lines (ebox-string-lines rendered-content))
          full-lines)
      (with-current-buffer buffer
        (cl-loop for span in line-spans
                 for line-number from start-line
                 for content-line in content-lines
                 do (let* ((line-start (car span))
                           (line-end (cdr span))
                           (content-start
                            (ebox-buffer--child-content-start-on-line
                             buffer child-ids line-number))
                           suffix-start prefix suffix)
                      (unless content-start
                        (throw 'failed nil))
                      (setq suffix-start
                            (ebox-buffer--position-after-pixel-width
                             content-start main-size))
                      (unless suffix-start
                        (setq suffix-start line-end))
                      (setq prefix (buffer-substring line-start content-start)
                            suffix (buffer-substring suffix-start line-end))
                      (push (concat prefix content-line suffix) full-lines))))
      (nreverse full-lines))))

(defun ebox--execute-flex-line-rerender (buffer op)
  "Try to rerender only the affected row line for flex owner OP."
  (let* ((owner-id (plist-get op :owner-id))
         (dirty (plist-get op :dirty))
         (dirty-node-ids (ebox--dirty-provenance-node-ids dirty))
         (dirty-node-id (and (= (length dirty-node-ids) 1)
                             (car dirty-node-ids)))
         (node (ebox--buffer-runtime-node buffer owner-id))
         (child-id (and dirty-node-id
                        (ebox--runtime-child-under-ancestor
                         buffer owner-id dirty-node-id))))
    (when (and node child-id
               (eq (plist-get node :ebox-type) 'flex))
      (let* ((child-ranges (ebox-buffer--child-line-ranges buffer node))
             (dirty-range (cdr (assq child-id child-ranges)))
             (old-line-ids
              (mapcar #'car
                      (cl-remove-if-not
                       (lambda (entry)
                         (ebox-buffer--line-range-overlap-p
                          dirty-range (cdr entry)))
                       child-ranges)))
             (old-item-main
              (and dirty-range old-line-ids
                   (ebox-buffer--child-line-item-main-footprint
                    buffer old-line-ids (car dirty-range))))
             (line-render
              (ebox--with-buffer-render-context buffer
                (or (ebox--flex-render-row-line-for-child-ids
                     node old-line-ids old-item-main)
                    (ebox--flex-render-row-line-for-child node child-id))))
             (new-line-ids (plist-get line-render :item-ids))
             (rendered (plist-get line-render :rendered))
             (rendered-owner-set
              (and rendered
                   (ebox-buffer--replacement-owner-set rendered dirty)))
             (main-size (plist-get line-render :main)))
        (when (and dirty-range
                   line-render
                   rendered
                   main-size
                   (equal old-line-ids new-line-ids)
                   (= (ebox-string-height rendered)
                      (1+ (- (cdr dirty-range) (car dirty-range)))))
          (with-current-buffer buffer
            (let* ((line-spans
                    (cl-loop for line from (car dirty-range)
                             to (cdr dirty-range)
                             collect (ebox-buffer--line-span-at-number line)))
                   (replacement-lines
                    (ebox-buffer--rendered-flex-row-lines
                     buffer line-spans (car dirty-range) old-line-ids
                     rendered main-size)))
              (when (and replacement-lines
                         (= (length replacement-lines)
                            (length line-spans)))
                (when-let ((new-spans
                            (ebox--replace-line-spans
                             line-spans
                             (ebox-lines-join replacement-lines)
                             rendered-owner-set)))
                  (list :owner-id owner-id
                        :op 'owner-rerender
                        :owner-type (plist-get node :ebox-type)
                        :span-count (length line-spans)
                        :flex-line-rerender t
                        :old-buffer-spans line-spans
                        :new-buffer-spans new-spans))))))))))

(defun ebox-buffer--line-replacement-feasible-p (spans rendered)
  "Return non-nil when RENDERED can replace line SPANS without mutation."
  (let ((line-count (length (ebox-string-lines rendered))))
    (or (= (length spans) line-count)
        (ebox--line-spans-contiguous-p spans))))

(defun ebox-buffer--paint-lines-compatible-p (spans rendered)
  "Return non-nil when RENDERED may update only properties in SPANS."
  (let ((lines (ebox-string-lines rendered)))
    (and (= (length spans) (length lines))
         (cl-loop for span in spans
                  for line in lines
                  always
                  (and (= (- (cdr span) (car span)) (length line))
                       (string=
                        (buffer-substring-no-properties
                         (car span) (cdr span))
                        (substring-no-properties line)))))))

(defun ebox-buffer-prepare-paint-patch (buffer op)
  "Prepare paint OP for BUFFER without modifying buffer text or properties."
  (let* ((owner-id (plist-get op :owner-id))
         (node (ebox--buffer-runtime-node buffer owner-id))
         (snapshot (and node
                        (ebox--ensure-layout-snapshot-spans
                         buffer owner-id)))
         (spans (and snapshot (plist-get snapshot :buffer-spans))))
    (when (and node spans)
      (ebox--with-buffer-render-context buffer
        (let ((ebox--defer-scroll-content-index t)
              (rendered (ebox-render node)))
          (when (with-current-buffer buffer
                  (ebox-buffer--paint-lines-compatible-p spans rendered))
            (list :op 'paint-patch
                  :owner-id owner-id
                  :owner-type (plist-get node :ebox-type)
                  :spans spans
                  :rendered rendered)))))))

(defun ebox-buffer-publish-prepared-paint-patch (buffer prepared)
  "Publish PREPARED paint patch into BUFFER."
  (with-current-buffer buffer
    (let ((spans (plist-get prepared :spans))
          (rendered (plist-get prepared :rendered)))
      (when (and (ebox-buffer--paint-lines-compatible-p spans rendered)
                 (ebox--paint-line-spans spans rendered))
        (list :owner-id (plist-get prepared :owner-id)
              :op 'paint-patch
              :owner-type (plist-get prepared :owner-type)
              :span-count (length spans))))))

(defun ebox-buffer--child-reorder-middle (old-ids new-ids)
  "Return the minimal changed middle ranges of OLD-IDS and NEW-IDS."
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

(defun ebox-buffer--child-list-window (old-ids new-ids)
  "Return changed child window for OLD-IDS and NEW-IDS."
  (let* ((old (vconcat old-ids))
         (new (vconcat new-ids))
         (start 0)
         (old-end (length old))
         (new-end (length new)))
    (while (and (< start old-end) (< start new-end)
                (equal (aref old start) (aref new start)))
      (cl-incf start))
    (while (and (> old-end start) (> new-end start)
                (equal (aref old (1- old-end))
                       (aref new (1- new-end))))
      (cl-decf old-end)
      (cl-decf new-end))
    (list :prefix-count start
          :old-middle (append (cl-subseq old start old-end) nil)
          :new-middle (append (cl-subseq new start new-end) nil))))

(defun ebox-buffer--child-reorder-span-groups (buffer child-ids)
  "Return CHILD-IDS' published span groups in BUFFER."
  (catch 'unsafe
    (let ((groups (make-hash-table :test 'equal)))
      (dolist (child-id child-ids)
        (let* ((snapshot
                (ebox--ensure-layout-snapshot-spans buffer child-id))
               (spans (and snapshot (plist-get snapshot :buffer-spans))))
          (unless spans
            (throw 'unsafe nil))
          (puthash child-id (copy-tree spans) groups)))
      groups)))

(defun ebox-buffer--vertical-slot-spans-p (spans)
  "Return non-nil when SPANS occupy one fixed slot on consecutive lines."
  (let (first-start first-width previous-line valid)
    (setq valid t)
    (dolist (span spans valid)
      (save-excursion
        (goto-char (car span))
        (let* ((line (line-number-at-pos (car span) t))
               (line-start (line-beginning-position))
               (start (ebox--string-pixel-width
                       (buffer-substring line-start (car span))))
               (width (ebox-buffer--span-slot-width span)))
          (if previous-line
              (unless (and (= line (1+ previous-line))
                           (= start first-start)
                           (= width first-width))
                (setq valid nil))
            (setq first-start start
                  first-width width))
          (setq previous-line line))))))

(defun ebox-buffer--child-reorder-rendered (segments spans dirty)
  "Return SEGMENTS in SPANS with published wrapper context from DIRTY."
  (let ((lines
         (cl-loop for segment in segments
                  append
                  (mapcar (lambda (span)
                            (buffer-substring (car span) (cdr span)))
                          segment))))
    (ebox-lines-join
     (cl-loop for line in lines
              for span in spans
              collect
              (ebox--line-with-preserved-wrapper-owner
               span line
               (ebox-buffer--replacement-owner-set line dirty))))))

(defun ebox-buffer--child-reorder-segments-fit-p (segments spans)
  "Return non-nil when SEGMENTS fit the published destination SPANS."
  (let ((lines
         (cl-loop for segment in segments
                  append
                  (mapcar (lambda (span)
                            (buffer-substring (car span) (cdr span)))
                          segment))))
    (and (= (length lines) (length spans))
         (cl-loop for line in lines
                  for span in spans
                  always
                  (= (ebox--string-pixel-width line)
                     (ebox-buffer--span-slot-width span))))))

(defun ebox-buffer--child-reorder-candidate-p
    (owner snapshot dirty old-ids new-ids)
  "Return non-nil when OWNER can reorder OLD-IDS into NEW-IDS."
  (and owner snapshot old-ids new-ids
       (plist-get dirty :pure-child-reorder-p)
       (equal (plist-get dirty :changed-keys) '(:children))
       (equal (plist-get snapshot :child-ids) old-ids)
       (equal (mapcar #'ebox--ensure-node-id
                      (ebox-tree-node-children owner))
              new-ids)
       (eq (plist-get owner :ebox-type) 'stack)
       (not (ebox-tree-node-visible-overflow-p owner))))

(defun ebox-buffer--child-reorder-publication
    (buffer owner snapshot dirty old-middle new-middle groups)
  "Return prepared BUFFER publication for OWNER's changed child middle."
  (ebox--with-buffer-render-context buffer
    (let* ((ebox--defer-scroll-content-index t)
           (old-groups (mapcar (lambda (id) (gethash id groups)) old-middle))
           (spans (apply #'append (mapcar #'copy-sequence old-groups)))
           (owner-spans (plist-get snapshot :buffer-spans))
           (segments (mapcar (lambda (id) (gethash id groups)) new-middle)))
      (when (and spans
                 (cl-every #'identity segments)
                 (cl-every (lambda (span) (member span owner-spans)) spans)
                 (with-current-buffer buffer
                   (and (ebox-buffer--vertical-slot-spans-p spans)
                        (ebox-buffer--child-reorder-segments-fit-p
                         segments spans))))
        (list :op 'child-reorder
              :owner-id (plist-get owner :node-id)
              :owner-type (plist-get owner :ebox-type)
              :dirty dirty
              :spans spans
              :segments segments)))))

(defun ebox-buffer-prepare-child-reorder (buffer op)
  "Prepare one vertical keyed child reorder OP for BUFFER."
  (let* ((owner-id (plist-get op :owner-id))
         (dirty (plist-get op :dirty))
         (owner (ebox--buffer-runtime-node buffer owner-id))
         (snapshot (ebox--ensure-layout-snapshot-spans buffer owner-id))
         (old-ids (plist-get dirty :old-child-ids))
         (new-ids (plist-get dirty :new-child-ids))
         (middle (ebox-buffer--child-reorder-middle old-ids new-ids))
         (old-middle (car middle))
         (new-middle (cadr middle))
         (groups (ebox-buffer--child-reorder-span-groups buffer old-middle)))
    (when (and groups old-middle new-middle
               (ebox-buffer--child-reorder-candidate-p
                owner snapshot dirty old-ids new-ids))
      (ebox-buffer--child-reorder-publication
       buffer owner snapshot dirty old-middle new-middle groups))))

(defun ebox-buffer--child-splice-candidate-p
    (owner snapshot dirty old-ids new-ids)
  "Return non-nil when OWNER can splice OLD-IDS into NEW-IDS."
  (and owner snapshot old-ids new-ids
       (plist-get dirty :child-splice-p)
       (equal (plist-get dirty :changed-keys) '(:children))
       (equal (plist-get snapshot :child-ids) old-ids)
       (equal (mapcar #'ebox--ensure-node-id
                      (ebox-tree-node-children owner))
              new-ids)
       (eq (plist-get owner :ebox-type) 'stack)
       (eq (ebox-tree-display-inner owner) 'column)
       (not (ebox-tree-node-visible-overflow-p owner))))

(defun ebox-buffer--child-by-id (owner child-id)
  "Return OWNER's direct child with runtime CHILD-ID."
  (cl-find-if
   (lambda (child)
     (equal (ebox--ensure-node-id child) child-id))
   (ebox-tree-node-children owner)))

(defun ebox-buffer--child-splice-simple-new-children-p (owner child-ids)
  "Return non-nil when OWNER's new CHILD-IDS are simple boxes."
  (cl-every
   (lambda (child-id)
     (let ((child (ebox-buffer--child-by-id owner child-id)))
       (and child (eq (plist-get child :ebox-type) 'box))))
   child-ids))

(defun ebox-buffer--child-splice-rendered (owner child-ids)
  "Return rendered CHILD-IDS from OWNER as one vertical string."
  (when child-ids
    (ebox-lines-join
     (cl-loop for child-id in child-ids
              for child = (ebox-buffer--child-by-id owner child-id)
              unless child
              do (cl-return nil)
              collect (ebox-render child)))))

(defun ebox-buffer--child-splice-bounds (old-spans before-span after-span)
  "Return deletion bounds around OLD-SPANS, BEFORE-SPAN, and AFTER-SPAN."
  (cond
   (old-spans
    (let ((start (caar old-spans))
          (end (cdar (last old-spans))))
      (cond
       ((and before-span (not after-span) (> start (point-min)))
        (cons (1- start) end))
       (after-span
        (cons start (min (point-max) (1+ end))))
       (t (cons start end)))))
   (before-span
    (cons (cdr before-span) (cdr before-span)))
   (after-span
    (cons (car after-span) (car after-span)))))

(defun ebox-buffer--child-splice-insert-text
    (rendered old-spans before-span after-span)
  "Return insertion text for RENDERED at the splice boundary."
  (cond
   ((not rendered) "")
   (old-spans
    (if after-span (concat rendered "\n") rendered))
   (before-span (concat "\n" rendered))
   (after-span (concat rendered "\n"))
   (t rendered)))

(defun ebox-buffer--child-splice-context (owner dirty window groups)
  "Return OWNER child splice publication context."
  (let* ((old-ids (plist-get dirty :old-child-ids))
         (new-ids (plist-get dirty :new-child-ids))
         (old-middle (plist-get window :old-middle))
         (new-middle (plist-get window :new-middle))
         (prefix (plist-get window :prefix-count))
         (before-id (and (> prefix 0) (nth (1- prefix) old-ids)))
         (after-id (nth prefix old-ids))
         (old-spans (apply #'append (mapcar (lambda (id)
                                              (gethash id groups))
                                            old-middle)))
         (before-span (car (last (gethash before-id groups))))
         (after-span (car (gethash after-id groups)))
         (rendered (ebox-buffer--child-splice-rendered owner new-middle)))
    (list :old-spans old-spans
          :old-child-ids old-ids
          :new-child-ids new-ids
          :before-span before-span
          :after-span after-span
          :rendered rendered)))

(defun ebox-buffer--child-splice-wrapper-span
    (old-spans before-span after-span)
  "Return a neighboring span that carries splice wrapper context."
  (or (car old-spans) before-span after-span))

(defun ebox-buffer--child-splice-rendered-with-wrapper-context
    (owner rendered old-child-ids new-child-ids old-spans before-span after-span)
  "Return RENDERED with outer wrapper context restored."
  (if-let* ((span
             (ebox-buffer--child-splice-wrapper-span
              old-spans before-span after-span))
            (owners (ebox--span-wrapper-owners span))
            (child-id-set
             (ebox--region-id-set
              (append old-child-ids new-child-ids)))
            (splice-owner-id (plist-get owner :node-id))
            (context-owners
             (cl-remove-if-not
              (lambda (candidate-owner-id)
                (and (not (equal candidate-owner-id splice-owner-id))
                     (not (gethash candidate-owner-id child-id-set))))
              owners)))
      (ebox--string-with-preserved-wrapper-context
       rendered
       context-owners
       (ebox--string-content-owner-set rendered)
       span)
    rendered))

(defun ebox-buffer--child-splice-prepared (owner dirty context)
  "Return prepared child splice plist for OWNER from CONTEXT."
  (let* ((old-spans (plist-get context :old-spans))
         (raw-rendered (plist-get context :rendered))
         (old-child-ids (plist-get context :old-child-ids))
         (new-child-ids (plist-get context :new-child-ids))
         (before-span (plist-get context :before-span))
         (after-span (plist-get context :after-span))
         (rendered
          (and raw-rendered
               (ebox-buffer--child-splice-rendered-with-wrapper-context
                owner raw-rendered old-child-ids new-child-ids
                old-spans before-span after-span)))
         (bounds (ebox-buffer--child-splice-bounds
                  old-spans before-span after-span))
         (insert (ebox-buffer--child-splice-insert-text
                  rendered old-spans before-span after-span)))
    (when (and bounds (or old-spans rendered))
      (list :op 'child-splice
            :owner-id (plist-get owner :node-id)
            :owner-type (plist-get owner :ebox-type)
            :dirty dirty
            :spans old-spans
            :bounds bounds
            :insert insert
            :rendered rendered
            :old-refresh-spans (list bounds)
            :new-refresh-spans
            (list (cons (car bounds)
                        (+ (car bounds) (length insert))))))))

(defun ebox-buffer--child-splice-publication
    (buffer owner dirty window groups)
  "Return prepared BUFFER splice publication for OWNER child ranges."
  (ebox--with-buffer-render-context buffer
    (with-current-buffer buffer
      (let* ((ebox--defer-scroll-content-index t)
             (old-middle (plist-get window :old-middle))
             (context
              (ebox-buffer--child-splice-context
               owner dirty window groups)))
        (when (cl-every #'identity (mapcar (lambda (id)
                                             (gethash id groups))
                                           old-middle))
          (ebox-buffer--child-splice-prepared
           owner dirty context))))))

(defun ebox-buffer-prepare-child-splice (buffer op)
  "Prepare one vertical keyed child splice OP for BUFFER."
  (let* ((owner-id (plist-get op :owner-id))
         (dirty (plist-get op :dirty))
         (owner (ebox--buffer-runtime-node buffer owner-id))
         (snapshot (ebox--ensure-layout-snapshot-spans buffer owner-id))
         (old-ids (plist-get dirty :old-child-ids))
         (new-ids (plist-get dirty :new-child-ids))
         (window (ebox-buffer--child-list-window old-ids new-ids))
         (old-middle (plist-get window :old-middle))
         (new-middle (plist-get window :new-middle))
         (groups (ebox-buffer--child-reorder-span-groups buffer old-ids)))
    (when (and groups
               (or old-middle new-middle)
               (not (and old-middle new-middle))
               (ebox-buffer--child-splice-candidate-p
                owner snapshot dirty old-ids new-ids))
      (unless (with-current-buffer buffer
                (ebox-buffer--partial-line-slots-p
                 (plist-get snapshot :buffer-spans)))
        (when (ebox-buffer--child-splice-simple-new-children-p
               owner new-middle)
          (ebox-buffer--child-splice-publication
           buffer owner dirty window groups))))))

(defun ebox-buffer-publish-prepared-child-reorder (buffer prepared)
  "Publish PREPARED child reorder into BUFFER."
  (with-current-buffer buffer
    (let* ((spans (plist-get prepared :spans))
           (rendered
            (ebox-buffer--child-reorder-rendered
             (plist-get prepared :segments)
             spans
             (plist-get prepared :dirty)))
           (owner-set
            (ebox-buffer--replacement-owner-set
             rendered (plist-get prepared :dirty)))
           (new-spans
            (ebox--replace-line-spans spans rendered owner-set)))
      (when new-spans
        (list :owner-id (plist-get prepared :owner-id)
              :op 'child-reorder
              :owner-type (plist-get prepared :owner-type)
              :span-count (length spans)
              :affected-region-ids
              (ebox-buffer--replacement-region-ids spans rendered)
              :old-buffer-spans spans
              :new-buffer-spans new-spans)))))

(defun ebox-buffer--inserted-rendered-spans (start rendered insert)
  "Return actual rendered spans from START after inserting INSERT."
  (let* ((prefix (- (length insert) (length rendered)))
         (render-start (if (and (> prefix 0)
                                (= (aref insert 0) ?\n))
                           (1+ start)
                         start))
         (render-end (+ render-start (length rendered))))
    (ebox--buffer-line-spans-between render-start render-end)))

(defun ebox-buffer--publish-child-splice-text (prepared)
  "Publish PREPARED splice text and return inserted rendered spans."
  (let ((bounds (plist-get prepared :bounds))
        (insert (plist-get prepared :insert))
        (rendered (plist-get prepared :rendered))
        inserted-spans)
    (ebox--with-preserved-buffer-window-state (current-buffer)
      (let ((inhibit-read-only t)
            (point-marker (copy-marker (point) t)))
        (save-excursion
          (goto-char (car bounds))
          (delete-region (car bounds) (cdr bounds))
          (insert insert)
          (when rendered
            (setq inserted-spans
                  (ebox-buffer--inserted-rendered-spans
                   (car bounds) rendered insert))))
        (goto-char (min (marker-position point-marker) (point-max)))
        (set-marker point-marker nil)))
    inserted-spans))

(defun ebox-buffer--child-splice-result
    (prepared affected-region-ids inserted-spans)
  "Return publication result for PREPARED child splice."
  (let ((dirty (plist-get prepared :dirty)))
    (list :owner-id (plist-get prepared :owner-id)
          :op 'child-splice
          :owner-type (plist-get prepared :owner-type)
          :span-count (length (plist-get prepared :old-refresh-spans))
          :rendered (plist-get prepared :rendered)
          :rendered-buffer-spans inserted-spans
          :affected-region-ids affected-region-ids
          :old-owner-region-ids (plist-get dirty :old-region-ids)
          :new-owner-region-ids (plist-get dirty :new-region-ids)
          :old-buffer-spans (plist-get prepared :spans)
          :new-buffer-spans inserted-spans
          :old-refresh-spans (plist-get prepared :old-refresh-spans)
          :new-refresh-spans (plist-get prepared :new-refresh-spans))))

(defun ebox-buffer-publish-prepared-child-splice (buffer prepared)
  "Publish PREPARED child splice into BUFFER."
  (with-current-buffer buffer
    (when (plist-get prepared :bounds)
        (let* ((affected-region-ids
                (ebox-buffer--replacement-region-ids
                 (plist-get prepared :spans)
                 (or (plist-get prepared :rendered) "")))
               (inserted-spans
                (ebox-buffer--publish-child-splice-text prepared)))
          (ebox-buffer--child-splice-result
           prepared affected-region-ids inserted-spans)))))

(defun ebox-buffer-prepare-owner-rerender (buffer op)
  "Prepare owner rerender OP for BUFFER without modifying the buffer."
  (let* ((owner-id (plist-get op :owner-id))
         (dirty (plist-get op :dirty))
         (snapshot (ebox--ensure-layout-snapshot-spans buffer owner-id))
         (node (ebox--buffer-runtime-node buffer owner-id))
         (snapshot-spans (plist-get snapshot :buffer-spans))
         (spans
          (or (and node snapshot-spans
                   (with-current-buffer buffer
                     (ebox-buffer--contained-flex-publication-spans
                      buffer owner-id node snapshot-spans
                      (append (plist-get dirty :old-region-ids)
                              (plist-get op :old-owner-region-ids)))))
              snapshot-spans))
         (replaced-owner-ids
          (with-current-buffer buffer
            (ebox-buffer--owners-inside-replacement-boundary
             spans (plist-get op :old-owner-region-ids))))
         (requires-owned-overflow-coverage
          (plist-get dirty :requires-owned-overflow-coverage))
         (coverage-owner-proven
          (or (not requires-owned-overflow-coverage)
              (equal owner-id (ebox--buffer-root-node-id buffer))
              (ebox--owned-overflow-coverage-wrapper-node-p
               buffer owner-id)))
         (partial-slot
          (and spans
               (with-current-buffer buffer
                 (ebox-buffer--partial-line-slots-p spans))))
         (coverage-partial-slot-eligible
          (or (not requires-owned-overflow-coverage)
              (not partial-slot)
              (equal (plist-get dirty :changed-keys) '(:overflow))))
         (root-owner-p
          (equal owner-id (ebox--buffer-root-node-id buffer))))
    (when (and node spans coverage-owner-proven
               coverage-partial-slot-eligible)
      (ebox--with-buffer-render-context buffer
        (with-current-buffer buffer
          (let* ((ebox--defer-scroll-content-index t)
                 (rendered
                  (ebox-buffer--render-owner-for-rerender
                   buffer owner-id node snapshot dirty root-owner-p))
                 (root-render-metadata
                  (and root-owner-p
                       (fboundp 'ebox--rendered-root-metadata)
                       (ebox--rendered-root-metadata rendered nil)))
                 (rendered-owner-set
                  (and (not root-owner-p)
                       (ebox-buffer--replacement-owner-set
                        rendered dirty replaced-owner-ids)))
                 (slot-rendered
                  (and partial-slot
                       (ebox-buffer--rendered-in-existing-slots
                        spans rendered rendered-owner-set t)))
                 (partial-slot-compatible
                  (or (not partial-slot) slot-rendered))
                 (coverage-partial-slot-safe
                  (or (not requires-owned-overflow-coverage)
                      (not partial-slot)
                      (and slot-rendered
                           (equal (plist-get dirty :changed-keys)
                                  '(:overflow))
                           (= (ebox-string-height rendered)
                              (length spans)))))
                 (slot-preserving (not (null slot-rendered)))
                 (patched-rendered (or slot-rendered rendered))
                 (root-publication
                  (and root-owner-p
                       partial-slot-compatible
                       coverage-partial-slot-safe
                       (ebox-buffer--prepare-root-property-patches
                        spans patched-rendered)))
                 (publishable-p
                  (and partial-slot-compatible
                       coverage-partial-slot-safe
                       (if root-owner-p
                           root-publication
                         (ebox-buffer--line-replacement-feasible-p
                          spans patched-rendered)))))
            (when publishable-p
              (list :op 'owner-rerender
                    :owner-id owner-id
                    :owner-type (plist-get node :ebox-type)
                    :dirty dirty
                    :spans spans
                    :rendered patched-rendered
                    :raw-rendered rendered
                    :rendered-owner-set rendered-owner-set
                    :old-owner-region-ids
                    (plist-get op :old-owner-region-ids)
                    :new-owner-region-ids
                    (ebox--node-all-region-ids node)
                    :affected-region-ids
                    (ebox-buffer--replacement-region-ids
                     spans patched-rendered)
                    :slot-preserving slot-preserving
                    :root-owner-p root-owner-p
                    :root-render-metadata root-render-metadata
                    :root-publication root-publication))))))))

(defun ebox-buffer-publish-prepared-owner-rerender (buffer prepared)
  "Publish PREPARED owner rerender into BUFFER."
  (with-current-buffer buffer
    (let* ((owner-id (plist-get prepared :owner-id))
           (spans (plist-get prepared :spans))
           (root-owner-p (plist-get prepared :root-owner-p))
           (root-publication
            (and root-owner-p
                 (ebox-buffer--publish-prepared-root-property-patches
                  (plist-get prepared :root-publication))))
           (new-spans
            (if root-owner-p
                (plist-get root-publication :new-buffer-spans)
              (ebox--replace-line-spans
               spans
               (plist-get prepared :rendered)
               (plist-get prepared :rendered-owner-set)))))
      (when new-spans
        (list :owner-id owner-id
              :op 'owner-rerender
              :owner-type (plist-get prepared :owner-type)
              :span-count (length spans)
              :rendered (plist-get prepared :rendered)
              :slot-preserving (plist-get prepared :slot-preserving)
              :root-render-metadata
              (plist-get prepared :root-render-metadata)
              :root-rendered
              (and root-owner-p (plist-get prepared :raw-rendered))
              :affected-region-ids
              (plist-get prepared :affected-region-ids)
              :old-owner-region-ids
              (plist-get prepared :old-owner-region-ids)
              :new-owner-region-ids
              (plist-get prepared :new-owner-region-ids)
              :publication-scope
              (and root-owner-p
                   (if (plist-get root-publication
                                  :full-root-required-p)
                       'full-root
                     'minimal-spans))
              :published-buffer-spans
              (and root-owner-p
                   (plist-get root-publication
                              :published-buffer-spans))
              :full-root-required-p
              (and root-owner-p
                   (plist-get root-publication
                              :full-root-required-p))
              :old-buffer-spans spans
              :new-buffer-spans new-spans)))))

(defun ebox-buffer-prepare-span-patch (buffer op)
  "Prepare verified span OP for BUFFER without modifying the buffer."
  (let* ((owner-id (plist-get op :owner-id))
         (dirty (plist-get op :dirty))
         (snapshot (ebox--ensure-layout-snapshot-details buffer owner-id))
         (spans (plist-get snapshot :buffer-spans))
         (old-span-footprint
          (plist-get snapshot :span-footprint-signature))
         (old-external-footprint
          (plist-get snapshot :external-footprint-signature))
         (old-parent-slot
          (plist-get snapshot :parent-slot-signature))
         (node (ebox--buffer-runtime-node buffer owner-id)))
    (when (and node spans old-span-footprint old-external-footprint
               old-parent-slot
               (not (ebox--node-visible-overflow-p node)))
      (ebox--with-buffer-render-context buffer
        (let* ((ebox--defer-scroll-content-index t)
               (rendered
                (or (ebox--render-node-in-current-flex-slot
                     buffer owner-id snapshot
                     (plist-get dirty :changed-keys))
                    (ebox-render node)))
               (rendered-owner-set
                (ebox-buffer--replacement-owner-set rendered dirty))
               (slot-rendered
                (and (ebox-buffer--inline-slot-span-patch-op-p op)
                     (with-current-buffer buffer
                       (ebox-buffer--rendered-in-existing-slots
                        spans rendered))))
               (candidate-rendered (or slot-rendered rendered))
               (new-span-footprint
                (ebox--rendered-span-footprint-signature rendered))
               (candidate-span-footprint
                (and slot-rendered
                     (ebox--rendered-span-footprint-signature
                      candidate-rendered)))
               (new-external-footprint
                (ebox--external-footprint-signature-from-span-footprint
                 new-span-footprint))
               (candidate-external-footprint
                (and candidate-span-footprint
                     (ebox--external-footprint-signature-from-span-footprint
                      candidate-span-footprint)))
               (new-parent-slot
                (ebox--project-parent-slot-signature
                 old-parent-slot new-span-footprint))
               (candidate-parent-slot
                (and candidate-span-footprint
                     (ebox--project-parent-slot-signature
                      old-parent-slot candidate-span-footprint)))
               (use-slot
                (and candidate-span-footprint
                     (not (and (ebox--span-footprint-compatible-p
                                old-span-footprint new-span-footprint)
                               (ebox--external-footprint-compatible-p
                                old-external-footprint new-external-footprint)
                               (ebox--parent-slot-compatible-p
                                old-parent-slot new-parent-slot)))
                     (ebox--span-footprint-compatible-p
                      old-span-footprint candidate-span-footprint)
                     (ebox--external-footprint-compatible-p
                      old-external-footprint candidate-external-footprint)
                     (ebox--parent-slot-compatible-p
                      old-parent-slot candidate-parent-slot)))
               (final-span-footprint
                (if use-slot candidate-span-footprint new-span-footprint))
               (final-external-footprint
                (if use-slot candidate-external-footprint
                  new-external-footprint))
               (final-parent-slot
                (if use-slot candidate-parent-slot new-parent-slot))
               (final-rendered
                (if use-slot candidate-rendered rendered))
               (compatible-p
                (or use-slot
                    (and (ebox--span-footprint-compatible-p
                          old-span-footprint new-span-footprint)
                         (ebox--external-footprint-compatible-p
                          old-external-footprint new-external-footprint)
                         (ebox--parent-slot-compatible-p
                          old-parent-slot new-parent-slot)))))
          (when (and compatible-p
                     (ebox-buffer--line-replacement-feasible-p
                      spans final-rendered))
            (list :op 'span-patch
                  :owner-id owner-id
                  :owner-type (plist-get node :ebox-type)
                  :dirty dirty
                  :spans spans
                  :rendered final-rendered
                  :rendered-owner-set rendered-owner-set
                  :old-owner-region-ids
                  (plist-get op :old-owner-region-ids)
                  :new-owner-region-ids
                  (ebox--node-all-region-ids node)
                  :affected-region-ids
                  (ebox-buffer--replacement-region-ids
                   spans final-rendered)
                  :slot-preserving use-slot
                  :old-span-footprint-signature old-span-footprint
                  :new-span-footprint-signature final-span-footprint
                  :old-external-footprint-signature old-external-footprint
                  :new-external-footprint-signature final-external-footprint
                  :old-parent-slot-signature old-parent-slot
                  :new-parent-slot-signature final-parent-slot)))))))

(defun ebox-buffer-publish-prepared-span-patch (buffer prepared)
  "Publish PREPARED verified span patch into BUFFER."
  (with-current-buffer buffer
    (let* ((spans (plist-get prepared :spans))
           (new-spans
            (ebox--replace-line-spans
             spans
             (plist-get prepared :rendered)
             (plist-get prepared :rendered-owner-set))))
      (when new-spans
        (list :owner-id (plist-get prepared :owner-id)
              :op 'span-patch
              :owner-type (plist-get prepared :owner-type)
              :span-count (length spans)
              :rendered (plist-get prepared :rendered)
              :slot-preserving (plist-get prepared :slot-preserving)
              :affected-region-ids
              (plist-get prepared :affected-region-ids)
              :old-owner-region-ids
              (plist-get prepared :old-owner-region-ids)
              :new-owner-region-ids
              (plist-get prepared :new-owner-region-ids)
              :old-buffer-spans spans
              :new-buffer-spans new-spans
              :old-signature
              (plist-get
               (plist-get prepared :old-span-footprint-signature)
               :line-pixel-widths)
              :new-signature
              (plist-get
               (plist-get prepared :new-span-footprint-signature)
               :line-pixel-widths)
              :old-span-footprint-signature
              (plist-get prepared :old-span-footprint-signature)
              :new-span-footprint-signature
              (plist-get prepared :new-span-footprint-signature)
              :old-external-footprint-signature
              (plist-get prepared :old-external-footprint-signature)
              :new-external-footprint-signature
              (plist-get prepared :new-external-footprint-signature)
              :old-parent-slot-signature
              (plist-get prepared :old-parent-slot-signature)
              :new-parent-slot-signature
              (plist-get prepared :new-parent-slot-signature))))))

(defun ebox--execute-owner-rerender (buffer op)
  "Execute owner rerender OP in BUFFER and return patch metadata."
  (let* ((owner-id (plist-get op :owner-id))
         (dirty (plist-get op :dirty))
         (snapshot (ebox--ensure-layout-snapshot-spans buffer owner-id))
         (spans (plist-get snapshot :buffer-spans))
         (node (ebox--buffer-runtime-node buffer owner-id))
         (requires-owned-overflow-coverage
          (plist-get dirty :requires-owned-overflow-coverage))
         (coverage-owner-proven
          (or (not requires-owned-overflow-coverage)
              (equal owner-id (ebox--buffer-root-node-id buffer))
              (ebox--owned-overflow-coverage-wrapper-node-p
               buffer owner-id)))
         (root-owner-p
          (equal owner-id (ebox--buffer-root-node-id buffer))))
    (when (and node spans)
      (ebox--with-buffer-render-context buffer
        (with-current-buffer buffer
          (let* ((ebox--defer-scroll-content-index t)
                 (prepared-root-patch
                  (and root-owner-p
                       (fboundp 'ebox--take-prepared-root-patch)
                       (ebox--take-prepared-root-patch node)))
                 (rendered
                  (unless prepared-root-patch
                    (ebox-buffer--render-owner-for-rerender
                     buffer owner-id node snapshot dirty root-owner-p)))
                 (root-render-metadata
                  (and root-owner-p
                       (if prepared-root-patch
                           (plist-get prepared-root-patch
                                      :root-render-metadata)
                         (and
                          (fboundp 'ebox--rendered-root-metadata)
                          ;; Cold visible output starts with a lightweight
                          ;; descriptor.  Scroll roots that cannot use
                          ;; marker-only recovery upgrade it on demand;
                          ;; prewarming prepares it before publication.  A
                          ;; declarative candidate has no complete pre-render,
                          ;; so its root owner prepares exact indexes from the
                          ;; one root string it already had to render.
                          (ebox--rendered-root-metadata
                           rendered
                           (not
                            (eq ebox-incremental--declarative-commit-buffer
                                buffer)))))))
                 (rendered-owner-set
                  (and (not root-owner-p)
                       (ebox-buffer--replacement-owner-set rendered dirty)))
                 (partial-slot
                  (ebox-buffer--partial-line-slots-p spans))
                 (slot-rendered
                  (and (not prepared-root-patch) partial-slot
                       (ebox-buffer--rendered-in-existing-slots
                        spans rendered rendered-owner-set t)))
                 (partial-slot-compatible
                  (or (not partial-slot) slot-rendered))
                 (coverage-partial-slot-safe
                  (or (not requires-owned-overflow-coverage)
                      (not partial-slot)
                      (and slot-rendered
                           (equal (plist-get dirty :changed-keys)
                                  '(:overflow))
                           (= (ebox-string-height rendered)
                              (length spans)))))
                 (slot-preserving (not (null slot-rendered)))
                 (patched-rendered (or slot-rendered rendered))
                 (root-publication
                  (and root-owner-p
                       coverage-owner-proven
                       partial-slot-compatible
                       coverage-partial-slot-safe
                       (if prepared-root-patch
                           (ebox-buffer--apply-root-property-patches
                            spans prepared-root-patch)
                         (ebox-buffer--replace-root-with-property-patches
                          spans patched-rendered))))
                 (new-spans
                  (and coverage-owner-proven
                       partial-slot-compatible
                       coverage-partial-slot-safe
                       (if root-owner-p
                           (plist-get root-publication :new-buffer-spans)
                         (ebox--replace-line-spans
                          spans patched-rendered rendered-owner-set)))))
            (when new-spans
              (list :owner-id owner-id
                    :op 'owner-rerender
                    :owner-type (plist-get node :ebox-type)
                    :span-count (length spans)
                    :slot-preserving slot-preserving
                    :root-render-metadata root-render-metadata
                    :root-rendered
                    (and root-owner-p (not prepared-root-patch) rendered)
                    :patch-origin
                    (and prepared-root-patch
                         (plist-get root-publication :patch-origin))
                    :full-frame-bytes
                    (and prepared-root-patch
                         (plist-get root-publication :full-frame-bytes))
                    :replacement-bytes
                    (and prepared-root-patch
                         (plist-get root-publication :replacement-bytes))
                    :role-delta
                    (and prepared-root-patch
                         (plist-get root-publication :role-delta))
                    :affected-region-ids
                    (and prepared-root-patch
                         (plist-get root-publication
                                    :affected-region-ids))
                    :publication-scope
                    (and root-owner-p
                         (if (plist-get root-publication
                                        :full-root-required-p)
                             'full-root
                           'minimal-spans))
                    :published-buffer-spans
                    (and root-owner-p
                         (plist-get root-publication
                                    :published-buffer-spans))
                    :full-root-required-p
                    (and root-owner-p
                         (plist-get root-publication
                                    :full-root-required-p))
                    :old-buffer-spans spans
                    :new-buffer-spans new-spans))))))))

(defun ebox--execute-span-patch
    (buffer op &optional pre-rendered pre-rendered-owner-set)
  "Execute signature-stable span patch OP in BUFFER and return metadata.
PRE-RENDERED and PRE-RENDERED-OWNER-SET reuse an equivalent render already
produced by the caller."
  (let* ((owner-id (plist-get op :owner-id))
         (dirty (plist-get op :dirty))
         (snapshot (ebox--ensure-layout-snapshot-details buffer owner-id))
         (spans (plist-get snapshot :buffer-spans))
         (old-span-footprint
          (plist-get snapshot :span-footprint-signature))
         (old-external-footprint
          (plist-get snapshot :external-footprint-signature))
         (old-parent-slot
          (plist-get snapshot :parent-slot-signature))
         (node (ebox--buffer-runtime-node buffer owner-id)))
    (when (and node spans old-span-footprint old-external-footprint
               old-parent-slot
               (not (ebox--node-visible-overflow-p node)))
      (ebox--with-buffer-render-context buffer
        (let* ((ebox--defer-scroll-content-index t)
               (rendered
                (or pre-rendered
                    (ebox--render-node-in-current-flex-slot
                     buffer owner-id snapshot
                     (plist-get dirty :changed-keys))
                    (ebox-render node)))
               (rendered-owner-set
                (or pre-rendered-owner-set
                    (ebox-buffer--replacement-owner-set rendered dirty)))
               (slot-rendered
                (and (ebox-buffer--inline-slot-span-patch-op-p op)
                     (with-current-buffer buffer
                       (ebox-buffer--rendered-in-existing-slots
                        spans rendered))))
               (candidate-rendered (or slot-rendered rendered))
               (new-span-footprint
                (ebox--rendered-span-footprint-signature rendered))
               (candidate-span-footprint
                (and slot-rendered
                     (ebox--rendered-span-footprint-signature
                      candidate-rendered)))
               (new-external-footprint
                (ebox--external-footprint-signature-from-span-footprint
                 new-span-footprint))
               (candidate-external-footprint
                (and candidate-span-footprint
                     (ebox--external-footprint-signature-from-span-footprint
                      candidate-span-footprint)))
               (new-parent-slot
                (ebox--project-parent-slot-signature
                 old-parent-slot new-span-footprint))
               (candidate-parent-slot
                (and candidate-span-footprint
                     (ebox--project-parent-slot-signature
                      old-parent-slot candidate-span-footprint)))
               (use-slot
                (and candidate-span-footprint
                     (not (and (ebox--span-footprint-compatible-p
                                old-span-footprint new-span-footprint)
                               (ebox--external-footprint-compatible-p
                                old-external-footprint new-external-footprint)
                               (ebox--parent-slot-compatible-p
                                old-parent-slot new-parent-slot)))
                     (ebox--span-footprint-compatible-p
                      old-span-footprint candidate-span-footprint)
                     (ebox--external-footprint-compatible-p
                      old-external-footprint candidate-external-footprint)
                     (ebox--parent-slot-compatible-p
                      old-parent-slot candidate-parent-slot)))
               (final-span-footprint
                (if use-slot candidate-span-footprint new-span-footprint))
               (final-external-footprint
                (if use-slot candidate-external-footprint
                  new-external-footprint))
               (final-parent-slot
                (if use-slot candidate-parent-slot new-parent-slot))
               (final-rendered
                (if use-slot candidate-rendered rendered)))
          (when (or use-slot
                    (and (ebox--span-footprint-compatible-p
                          old-span-footprint new-span-footprint)
                         (ebox--external-footprint-compatible-p
                          old-external-footprint new-external-footprint)
                         (ebox--parent-slot-compatible-p
                          old-parent-slot new-parent-slot)))
            (with-current-buffer buffer
              (when-let ((new-spans
                          (ebox--replace-line-spans
                           spans final-rendered rendered-owner-set)))
                (list :owner-id owner-id
                      :op 'span-patch
                      :owner-type (plist-get node :ebox-type)
                      :span-count (length spans)
                      :slot-preserving use-slot
                      :old-buffer-spans spans
                      :new-buffer-spans new-spans
                      :old-signature
                      (plist-get old-span-footprint :line-pixel-widths)
                      :new-signature
                      (plist-get final-span-footprint :line-pixel-widths)
                      :old-span-footprint-signature old-span-footprint
                      :new-span-footprint-signature final-span-footprint
                      :old-external-footprint-signature old-external-footprint
                      :new-external-footprint-signature
                      final-external-footprint
                      :old-parent-slot-signature old-parent-slot
                      :new-parent-slot-signature
                      final-parent-slot)))))))))

(defun ebox-buffer-apply-paint-patch (buffer op)
  "Apply paint patch OP to BUFFER."
  (ebox--execute-paint-patch buffer op))

(defun ebox-buffer-apply-span-patch
    (buffer op &optional pre-rendered pre-rendered-owner-set)
  "Apply signature-stable span patch OP to BUFFER.
PRE-RENDERED and PRE-RENDERED-OWNER-SET avoid repeating caller-owned render
work when they describe the same owner and render context as OP."
  (ebox--execute-span-patch
   buffer op pre-rendered pre-rendered-owner-set))

(defun ebox-buffer-apply-owner-rerender (buffer op)
  "Apply owner rerender OP to BUFFER."
  (or (and (not (plist-get (plist-get op :dirty)
                            :requires-owned-overflow-coverage))
           (ebox--execute-flex-line-rerender buffer op))
      (ebox--execute-owner-rerender buffer op)))

(defun ebox--region-find (region-id type)
  "Find all regions of TYPE for REGION-ID in current buffer.
TYPE is a symbol: content, pt, pb, pl, pr, mt, mb, ml, mr, bt, bb, bl, br.
Returns list of (start . end) cons cells."
  (if-let ((table (ebox-buffer--region-role-span-table)))
      (copy-sequence
       (gethash (ebox-buffer--region-role-key region-id type) table))
    (ebox-buffer--scan-region-role-spans region-id type)))

(defun ebox--patch-region-props (region-id type fn)
  "Call FN on every buffer span of TYPE belonging to REGION-ID.
FN receives (start end) and should update text properties in place.
Runs inside `save-excursion' with `inhibit-read-only' set."
  (let ((spans (ebox--region-find region-id type))
        (inhibit-read-only t))
    (save-excursion
      (dolist (span spans)
        (funcall fn (car span) (cdr span))))))

(defun ebox--region-replace-line (region-id idx string)
  "Replace content at line IDX in REGION-ID with STRING.
Internal primitive used by the scroll fast-path."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (catch 'done
        (while (< (point) (point-max))
          (when (and (eql (get-text-property (point) 'ebox-content) region-id)
                     (eql (get-text-property (point) 'ebox-content-idx) idx))
            (let ((end (next-single-property-change
                        (point) 'ebox-content nil (point-max)))
                  (start (point))
                  (props (copy-sequence (text-properties-at (point)))))
              (setq props (plist-put props 'ebox-content region-id))
              (setq props (plist-put props 'ebox-content-idx idx))
              (delete-region (point) end)
              (insert (apply #'propertize string props))
              (throw 'done (cons start (point)))))
          (goto-char (next-single-property-change
                      (point) 'ebox-content nil (point-max))))))))

(defun ebox--full-rerender-buffer (buffer)
  "Re-render BUFFER from the root node stored in its render state.
Called after any geometry change so that stack row-pads are recalculated
against the new box sizes."
  (ebox--with-render-gc
    (when-let ((root (ebox--buffer-root-node buffer)))
      (ebox--with-buffer-render-context buffer
        (ebox--with-preserved-buffer-window-state buffer
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (ebox--clear-buffer-extents buffer)
              (erase-buffer)
              (let ((start (point)))
                (insert (ebox-render root))
                (ebox--register-box-extents-in-range start (point))
                (when (fboundp 'ebox--refresh-buffer-scroll-content-markers)
                  (ebox--refresh-buffer-scroll-content-markers buffer))
                (ebox-buffer-refresh-region-role-spans buffer)
                (ebox--refresh-buffer-layout-snapshots buffer))
              (goto-char (point-min)))))))))

(defun ebox-buffer-apply-root-rerender (buffer)
  "Apply a root rerender to BUFFER."
  (ebox--full-rerender-buffer buffer))

(defun ebox--rerender-box (region-id)
  "Rerender REGION-ID by replacing its whole contiguous buffer slice.
Currently this only works for boxes whose rendered output is contiguous in the
buffer, e.g. standalone boxes or purely vertical stacks."
  (let* ((box (or (gethash region-id ebox--region-box-table)
                  (error "No box found for region %S" region-id)))
         (extents (or (gethash region-id ebox--box-extents)
                      (error "No contiguous extents found for region %S" region-id)))
         (start-marker (car extents))
         (end-marker (cdr extents))
         (buffer (marker-buffer start-marker)))
    (unless (and buffer (eq buffer (marker-buffer end-marker)))
      (error "Dead extents for region %S" region-id))
    (with-current-buffer buffer
      (ebox--with-preserved-buffer-window-state buffer
        (let* ((start (marker-position start-marker))
               (end (marker-position end-marker))
               (inhibit-read-only t)
               (pt (point))
               (pt-offset (when (and (>= pt start) (< pt end))
                            (- pt start)))
               rendered)
          (ebox--with-render-gc
            (save-excursion
              (goto-char start)
              (delete-region start end)
              ;; BOX already owns its stable :region-id.  A dynamic override
              ;; here would leak through recursive child rendering and assign
              ;; every descendant border/content span to REGION-ID.
              (setq rendered (ebox-render box))
              (insert rendered)
              (ebox--set-box-extents region-id start (point)))
            (when pt-offset
              (goto-char (min (+ start pt-offset) (point-max))))
            rendered))))))

(provide 'ebox-buffer-backend)

;;; ebox-buffer-backend.el ends here
