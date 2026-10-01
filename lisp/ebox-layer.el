;;; ebox-layer.el --- Retained box placement and text composition -*- lexical-binding: t; -*-

;;; Commentary:
;; Compose visible pieces without changing the logical tree.  Horizontal
;; coordinates are pixels; vertical coordinates share the host's text rows.
;; This module never writes a buffer or owns application state.

;;; Code:

(require 'cl-lib)
(require 'ebox-tree)
(require 'ebox-composite)

(declare-function ebox-get "ebox" (box property))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--substring-pixel-width "ebox-measure" (string start end))
(declare-function ebox--string-pixel-width "ebox-measure" (string))
(declare-function ebox--display-space-width "ebox-measure" (display))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox--render-with-cache "ebox" (node &optional width probe))
(declare-function ebox--call-with-box-content-context "ebox-layout" (box function))
(declare-function ebox--wrapper-content-viewport-pixel "ebox-layout" (box))
(declare-function ebox--content-height "ebox-layout" (box height &optional rendered))
(declare-function ebox--size-pixels "ebox-layout" (value &optional box axis percent-base))
(declare-function ebox--size-line-height "ebox-layout" (&optional box))
(declare-function ebox--record-rendered-uniform-width "ebox-layout" (rendered width))
(declare-function ebox--record-rendered-intrinsic-size "ebox-layout" (rendered width height))
(declare-function ebox-pixel-space "ebox" (pixels))
(declare-function ebox-native-reflow-layout-ready-p "ebox-native-reflow" ())
(declare-function ebox-native--module-create-compositor "ebox_native_reflow"
                  (count height width))
(declare-function ebox-native--module-compose-rows "ebox_native_reflow"
                  (handle changes count order dirty output))
(declare-function ebox-native--module-release-compositor "ebox_native_reflow" (handle))
(defvar ebox-region-types)
(defvar ebox--intrinsic-layout-measurement)
(defvar ebox--render-source-index)

(defconst ebox-layer--parked-row -1000000
  "Row of a retained primitive that must not paint.
Hidden panels and released footprints park here.  The offset is far enough
below any canvas that prepared translations can never bring a parked record
back into the visible rows; only a footprint replacement re-places it.")

(defvar ebox-layer--render-root nil
  "Root of this spatial materialization, never a live buffer root.")

(defvar ebox-layer--retained-root-input nil
  "One candidate's proved panel replacement and current runtime state.")
(defvar ebox-layer--portals nil
  "Candidate-local absolute nodes awaiting root composition.")

(defvar ebox-layer--piece-width-cache nil
  "Original row prefix widths scoped to one host composition.
Keys are source strings by identity.  Never retained between renders.")

(defvar ebox-layer--active-p 'unknown
  "Whether the current candidate contains layered layout.
Retained publication supplies a known boolean; isolated rendering resolves
the fact once for its spatial root.")

(defvar ebox-layer--previous-composition-cache nil
  "Read-only retained host composition ledger for the current candidate.
The ledger is an opaque hash table owned by the Surface runtime.  Entries are
keyed by host identity and composition phase and contain immutable row
signatures plus their already composed rows.  A missing ledger disables reuse.")

(defvar ebox-layer--composition-cache nil
  "Candidate-local host composition ledger populated during rendering.
Callers should bind this to a fresh hash table for one candidate; this module
never mutates `ebox-layer--previous-composition-cache'.  Use an `equal' hash
table because ledger keys are freshly allocated HOST/PHASE cons cells.")

(defvar ebox-layer--composition-context nil
  "Immutable context token for host composition reuse.
The Surface runtime should include every display and allocation fact that can
change pixel measurement.  Reuse is disabled when this token is nil.")

(defvar ebox-layer--composition-phase 'final
  "Composition phase used as the default host ledger key.
Anchor prepasses and final paints must use distinct phase values.")

(cl-defstruct (ebox-layer--raster
               (:constructor ebox-layer--make-raster))
  "Prepared opaque panel pixels, independent of their placement.
TEXT and its derived LINES, PIECES and WIDTH are immutable after preparation.
The containing display CONTEXT bounds reuse across mounted generations."
  text context lines pieces width)

(cl-defstruct (ebox-layer--program
               (:constructor ebox-layer--make-program))
  "Prepared imperative composition storage for a stable containing plane.
RECORDS contain reusable placement primitives.  ORDER, Z-VALUES, row list
spines and dirty flags are allocated at preparation, never by translation.
Published and pending rows use separate vectors so rejection restores pixels
without rendering the former geometry again."
  width height records order z-values document-order targets
  base-lines rows saved-rows row-spines row-heads row-tails dirty output-spine
  pending batch-open order-dirty order-changed saved-texts modified-texts
  saved-coordinates saved-z modified-geometry saved-records saved-targets saved-count
  saved-ends modified-ends slice-indexes native native-dirty)

(defun ebox-layer--native-prepare (count height width)
  "Prepare optional numeric composition storage for COUNT records and HEIGHT.
WIDTH is the fixed pixel allocation.  Text and publication stay Elisp-owned."
  (when (and (require 'ebox-native-reflow nil t)
             (ebox-native-reflow-layout-ready-p)
             (fboundp 'ebox-native--module-create-compositor))
    (when-let* ((handle (ebox-native--module-create-compositor count height (float width))))
      (vector handle (make-vector (* 5 count) 0)
              (make-vector (* 4 (+ (* 2 count) height)) 0)
              (make-list (1+ (* 2 count)) nil)
              (make-list (1+ (* 4 count)) nil)))))

(defun ebox-layer--native-join (parts stop storage)
  "Join prepared PARTS through STOP, using reusable STORAGE at fixed spaces.
A replacement space separates shaping contexts.  Equal nonzero display spaces
still need the ordinary joiner's zero-pixel separator to prevent coalescing.
Any unproved boundary uses the ordinary measured join, preserving its output."
  (let ((source parts) (tail storage) previous last-cell result unsupported)
    (unwind-protect
        (progn
          (while (and source (not (eq source stop)) (not unsupported))
            (let ((part (car source)))
              (unless (equal part "")
                (when previous
                  (let* ((left (get-text-property (1- (length previous)) 'display previous))
                         (right (get-text-property 0 'display part))
                         (left-width (ebox--display-space-width left))
                         (right-width (ebox--display-space-width right)))
                    (if (not (or left-width right-width))
                        (setq unsupported t)
                      (when (and left-width (eq left right) (/= left-width 0))
                        (setcar tail (propertize " " 'display '(space :width (0))))
                        (setq tail (cdr tail))))))
                (setcar tail part)
                (setq last-cell tail tail (cdr tail) previous part)))
            (setq source (cdr source)))
          (setq result
                (if unsupported
                    (ebox-composite--join parts stop)
                  (if (null last-cell) ""
                    (setcdr last-cell nil)
                    (unwind-protect (apply #'concat storage)
                      (setcdr last-cell tail))))))
      (let ((clear storage))
        (while (not (eq clear tail)) (setcar clear nil) (setq clear (cdr clear)))))
    result))

(defun ebox-layer--program-disable-native (program)
  "Keep PROGRAM's ordinary compositor when a numeric capability is exceeded."
  (setf (ebox-layer--program-native program) nil)
  (unless (ebox-layer--program-row-spines program)
    (let ((spines (make-vector (ebox-layer--program-height program) nil)))
      (dotimes (row (length spines))
        (aset spines row (make-list (length (ebox-layer--program-records program)) nil)))
      (setf (ebox-layer--program-row-spines program) spines)))
  nil)

(defun ebox-layer--program-render-native (program)
  "Compose PROGRAM's dirty intervals with its optional retained native kernel.
The module retains only a numeric cache and bounded scratch arrays.  Source
strings, glyph fitting and property values never cross that boundary."
  (catch 'ebox-layer-native-declined
    (when-let* ((native (ebox-layer--program-native program)))
      (let* ((records (ebox-layer--program-records program))
             (changed (ebox-layer--program-native-dirty program))
             (input (aref native 1)) (output (aref native 2))
             (dirty (ebox-layer--program-dirty program))
             (rows (ebox-layer--program-rows program))
             (saved (ebox-layer--program-saved-rows program))
             (ebox-composite--prepared-lines (ebox-layer--program-slice-indexes program))
             (count 0) (cursor 0))
        (dotimes (index (length records))
          (when (aref changed index)
            (let* ((record (aref records index)) (offset (* count 5))
                   (row (plist-get record :y))
                   (x (plist-get record :x))
                   (start (or (plist-get record :source-start) 0))
                   (end (or (plist-get record :source-end)
                            (ebox--string-pixel-width (plist-get record :text)))))
              ;; Larger exact Lisp integers must not be rounded through doubles.
              (unless (and (<= (abs x) 9007199254740991)
                           (<= 0 start end 9007199254740991)
                           (<= (abs (+ x (- end start))) 9007199254740991)
                           (<= (abs (- x start)) 9007199254740991))
                (throw 'ebox-layer-native-declined
                       (ebox-layer--program-disable-native program)))
              (aset input offset index)
              (aset input (+ offset 1) (float x))
              (aset input (+ offset 2)
                    (if (and (integerp row) (<= 0 row) (< row (length rows))) row -1))
              (aset input (+ offset 3) (float start))
              (aset input (+ offset 4) (float end))
              (setq count (1+ count)))))
        (let ((end (* 4 (ebox-native--module-compose-rows
                         (aref native 0) input count
                         (ebox-layer--program-order program) dirty output))))
          (dotimes (row (length rows))
            (when (aref dirty row)
              (let* ((parts (aref native 3)) (tail parts)
                     (baseline (aref saved row)))
                (unwind-protect
                    (progn
                      (while (and (< cursor end) (= (aref output cursor) row))
                        (let ((index (aref output (+ cursor 1)))
                              (left (aref output (+ cursor 2)))
                              (right (aref output (+ cursor 3))))
                          (setcar tail
                                  (if (< index 0)
                                      (ebox-pixel-space (- right left))
                                    (ebox-composite-slice
                                     (plist-get (aref records index) :text) left right)))
                          (setq tail (cdr tail) cursor (+ cursor 4))))
                      (let ((rendered (ebox-layer--native-join parts tail (aref native 4))))
                        (if (and baseline (equal-including-properties rendered baseline))
                            (progn (aset rows row baseline) (aset saved row nil) (aset dirty row nil))
                          (aset rows row rendered))))
                  ;; Failed glyph fitting must not retain transient property graphs.
                  (let ((clear parts))
                    (while (not (eq clear tail)) (setcar clear nil) (setq clear (cdr clear)))))))))
        (fillarray changed nil)
        t))))

(defun ebox-layer--program-prepare (entry host)
  "Compile retained composition ENTRY into a private primitive program.
HOST supplies logical document order at this control-plane boundary.
This operation does not publish or change ENTRY."
  (when (and (listp entry) (vectorp (plist-get entry :rows)))
    (let* ((base (plist-get entry :base-lines))
           ;; A prepared z slot can cross the normal-flow plane.  Expand that
           ;; bottom-plane optimization once during compilation, so a later
           ;; negative z value never needs tree discovery or special policy.
           (source
            (if base
                (ebox-layer--ordered-records
                 host
                 (append
                  (plist-get entry :records)
                  (ebox-layer--flow-records
                   host
                   (cl-remove-if
                    (lambda (child) (eq (plist-get child :position) 'absolute))
                    (ebox-tree-layout-children host))
                   base (plist-get entry :width) (plist-get entry :height))))
              (plist-get entry :records)))
           (count (length source))
           (height (plist-get entry :height))
           (native (ebox-layer--native-prepare count height (plist-get entry :width)))
           (records (make-vector count nil))
           (order (make-vector count 0))
           (z-values (make-vector count 0))
           (document-order (make-vector count 0))
           (targets (make-hash-table :test #'equal))
           (row-spines (unless native (make-vector height nil)))
           (ordinal 0)
           (node-order (make-hash-table :test #'equal))
           (strings (make-hash-table :test #'eq))
           (slice-indexes (make-hash-table :test #'eq)))
      (cl-labels ((visit (node)
                    (puthash (ebox-layer--stable-node-id node)
                             (hash-table-count node-order) node-order)
                    (mapc #'visit (ebox-tree-node-children node))))
        (visit host))
      (dolist (record source)
        (let* ((node (plist-get record :node))
               (id (ebox-layer--stable-node-id node))
               (rank (gethash id node-order 0))
               (copy (copy-sequence record))
               (text (plist-get record :text)))
          (plist-put copy :text
                     (or (gethash text strings)
                         (puthash text (copy-sequence text) strings)))
          (aset records ordinal copy)
          (aset order ordinal ordinal)
          (aset z-values ordinal (or (plist-get node :z-index) 0))
          (aset document-order ordinal rank)
          (puthash id (cons ordinal (gethash id targets)) targets)
          (setq ordinal (1+ ordinal))))
      (maphash (lambda (id indexes)
                 (puthash id (vconcat (nreverse indexes)) targets)) targets)
      (unless native
        (dotimes (row height)
          (aset row-spines row (make-list count nil))))
      (ebox-layer--make-program
       :width (plist-get entry :width) :height height
       :records records :order order :z-values z-values
       :document-order document-order :targets targets
       :base-lines []
       :rows (vconcat (mapcar #'copy-sequence
                              (append (plist-get entry :rows) nil)))
       :saved-rows (make-vector height nil)
       :row-spines row-spines :row-heads (make-vector height nil)
       :row-tails (make-vector height nil) :dirty (make-vector height nil)
       :saved-texts (make-vector count nil) :modified-texts (make-vector count nil)
       :saved-coordinates (make-vector (* 2 count) 0)
       :saved-z (make-vector count 0) :modified-geometry (make-vector count nil)
       :saved-records (make-vector count nil)
       :saved-ends (make-vector count 0) :modified-ends (make-vector count nil)
       :slice-indexes slice-indexes
       :native native
       :native-dirty (make-vector count t)
       :output-spine (make-list height nil)))))

(defun ebox-layer--program-strings (program)
  "Return PROGRAM's private raster strings for cold ownership compilation."
  (let ((strings (append (ebox-layer--program-base-lines program)
                         (append (ebox-layer--program-rows program) nil))))
    (dotimes (index (length (ebox-layer--program-records program)))
      (push (plist-get (aref (ebox-layer--program-records program) index) :text)
            strings))
    (cl-delete-duplicates strings :test #'eq)))

(defun ebox-layer--program-record-less-p (program left right)
  "Return whether PROGRAM primitive LEFT paints below RIGHT."
  (let ((zs (ebox-layer--program-z-values program))
        (ranks (ebox-layer--program-document-order program))
        (records (ebox-layer--program-records program)))
    (cond
     ((/= (aref zs left) (aref zs right))
      (< (aref zs left) (aref zs right)))
     ((not (eq (and (ebox-layer-positioned-p
                    (plist-get (aref records left) :node)) t)
               (and (ebox-layer-positioned-p
                    (plist-get (aref records right) :node)) t)))
      (not (ebox-layer-positioned-p
            (plist-get (aref records left) :node))))
     (t (< (aref ranks left) (aref ranks right))))))

(defun ebox-layer--program-sort (program)
  "Update PROGRAM's preallocated stacking order in place."
  (let ((order (ebox-layer--program-order program)) (index 1))
    (while (< index (length order))
      (let ((value (aref order index)) (cursor index))
        (while (and (> cursor 0)
                    (ebox-layer--program-record-less-p
                     program value (aref order (1- cursor))))
          (aset order cursor (aref order (1- cursor)))
          (setq cursor (1- cursor)))
        (aset order cursor value))
      (setq index (1+ index)))))

(defun ebox-layer--program-mark-row (program row)
  "Mark one visible ROW in PROGRAM's retained damage storage.
Save its accepted pixels only at first damage, before rendering or mutation
of any other record can overwrite this publication's rollback baseline."
  (when (and (integerp row) (<= 0 row)
             (< row (ebox-layer--program-height program)))
    (unless (aref (ebox-layer--program-dirty program) row)
      (aset (ebox-layer--program-saved-rows program) row
            (aref (ebox-layer--program-rows program) row)))
    (aset (ebox-layer--program-dirty program) row t)))

(defun ebox-layer--program-batch-begin (program)
  "Open PROGRAM's fixed primitive storage for one atomic update batch.
Several translations and raster replacements may accumulate until
`ebox-layer--program-batch-end'.  Settle accepts or restores the whole batch."
  (when (ebox-layer--program-pending program)
    (error "Ebox composition program already has pending changes"))
  (setf (ebox-layer--program-pending program) t
        (ebox-layer--program-batch-open program) t)
  program)

(defun ebox-layer--program-batch-end (program)
  "Close PROGRAM's batch and prepare its final stacking order for rendering.
The updates remain pending until `ebox-layer--program-settle' accepts or
restores them; closing a batch does not publish or change rollback storage."
  (unless (ebox-layer--program-batch-open program)
    (error "Ebox composition program has no open batch"))
  (when (ebox-layer--program-order-dirty program)
    (ebox-layer--program-sort program)
    (setf (ebox-layer--program-order-dirty program) nil))
  (setf (ebox-layer--program-batch-open program) nil)
  program)

(defun ebox-layer--program-translate (program target dx dy z)
  "Stage TARGET's DX/DY translation and absolute Z in PROGRAM's numeric slots.
TARGET is a cold-resolved primitive-index vector.  An open batch accumulates
translations relative to the latest staged coordinates, preserving each
record's original coordinates and stacking once.  Otherwise only one pending
translation is allowed.  No component or Box traversal is needed."
  (when (and (ebox-layer--program-pending program)
             (not (ebox-layer--program-batch-open program)))
    (error "Ebox composition program already has a pending translation"))
  (setf (ebox-layer--program-pending program) t)
  (let ((records (ebox-layer--program-records program))
        (zs (ebox-layer--program-z-values program))
        (saved (ebox-layer--program-saved-coordinates program))
        (saved-z (ebox-layer--program-saved-z program))
        (modified (ebox-layer--program-modified-geometry program)))
    (dotimes (offset (length target))
      (let* ((index (aref target offset))
             (record (aref records index))
             (old-x (plist-get record :x))
             (old-y (plist-get record :y))
             (old-z (aref zs index)))
        (unless (and (= dx 0) (= dy 0) (= z old-z))
          (unless (aref modified index)
            (aset saved (* 2 index) old-x)
            (aset saved (1+ (* 2 index)) old-y)
            (aset saved-z index old-z)
            (aset modified index t))
          (ebox-layer--program-mark-row program old-y)
          (plist-put record :x (+ old-x dx))
          (plist-put record :y (+ old-y dy))
          (aset zs index z)
          (aset (ebox-layer--program-native-dirty program) index t)
          (ebox-layer--program-mark-row program (+ old-y dy))
          (unless (= z old-z)
            (setf (ebox-layer--program-order-dirty program) t
                  (ebox-layer--program-order-changed program) t)))))
    (when (and (ebox-layer--program-order-dirty program)
               (not (ebox-layer--program-batch-open program)))
      (ebox-layer--program-sort program)
      (setf (ebox-layer--program-order-dirty program) nil)))
  program)

(defun ebox-layer--program-crop (program target width height)
  "Stage WIDTH and HEIGHT of TARGET's preallocated opaque row records.
Each record has an immutable maximum-width source row.  Changing its source
end clips pixels; zero-width records retain invisible rows for later growth.
Coordinates, native ownership and rollback stay with the same program."
  (setf (ebox-layer--program-pending program) t)
  (dotimes (offset (length target))
    (let* ((index (aref target offset))
           (record (aref (ebox-layer--program-records program) index))
           (old (plist-get record :source-end))
           (end (if (< (plist-get record :source-row) height) width 0)))
      (unless (= old end)
        (unless (aref (ebox-layer--program-modified-ends program) index)
          (aset (ebox-layer--program-saved-ends program) index old)
          (aset (ebox-layer--program-modified-ends program) index t))
        (ebox-layer--program-mark-row program (plist-get record :y))
        (aset (ebox-layer--program-native-dirty program) index t)
        (plist-put record :source-end end))))
  program)

(defun ebox-layer--program-replace-text (program record-index text)
  "Stage owned row TEXT for PROGRAM's primitive RECORD-INDEX.
TEXT must be a single-line string and remains immutable until settlement.
The caller proves its fixed pixel interval; placement, source bounds and
record identity do not change.  Original text and accepted row pixels are
saved once even when the same record changes repeatedly in one batch."
  (unless (and (integerp record-index) (<= 0 record-index)
               (< record-index (length (ebox-layer--program-records program))))
    (error "Invalid Ebox prepared raster record index: %S" record-index))
  (unless (and (stringp text) (not (string-match-p "\n" text)))
    (error "Ebox prepared raster replacement must be a single-line string"))
  (let* ((record (aref (ebox-layer--program-records program) record-index))
         (old (plist-get record :text)))
    (setf (ebox-layer--program-pending program) t)
    (unless (eq old text)
      (unless (aref (ebox-layer--program-modified-texts program) record-index)
        (aset (ebox-layer--program-saved-texts program) record-index old)
        (aset (ebox-layer--program-modified-texts program) record-index t))
      (ebox-layer--program-mark-row program (plist-get record :y))
      (aset (ebox-layer--program-native-dirty program) record-index t)
      (plist-put record :text text)))
  program)

(defun ebox-layer--program-grow (program count)
  "Extend PROGRAM's primitive storage to COUNT records, preserving indexes."
  (let ((old (length (ebox-layer--program-records program))))
    (when (> count old)
      (cl-flet ((grow (vector fill) (vconcat vector (make-vector (- count old) fill))))
        (setf (ebox-layer--program-records program) (grow (ebox-layer--program-records program) nil)
              (ebox-layer--program-order program)
              (vconcat (ebox-layer--program-order program) (number-sequence old (1- count)))
              (ebox-layer--program-z-values program) (grow (ebox-layer--program-z-values program) 0)
              (ebox-layer--program-document-order program)
              (grow (ebox-layer--program-document-order program) 0)
              (ebox-layer--program-saved-texts program) (grow (ebox-layer--program-saved-texts program) nil)
              (ebox-layer--program-modified-texts program)
              (grow (ebox-layer--program-modified-texts program) nil)
              (ebox-layer--program-saved-coordinates program)
              (vconcat (ebox-layer--program-saved-coordinates program) (make-vector (* 2 (- count old)) 0))
              (ebox-layer--program-saved-z program) (grow (ebox-layer--program-saved-z program) 0)
              (ebox-layer--program-modified-geometry program)
              (grow (ebox-layer--program-modified-geometry program) nil)
              (ebox-layer--program-saved-records program)
              (grow (ebox-layer--program-saved-records program) nil)
              (ebox-layer--program-saved-ends program)
              (grow (ebox-layer--program-saved-ends program) 0)
              (ebox-layer--program-modified-ends program)
              (grow (ebox-layer--program-modified-ends program) nil)))
      (setf (ebox-layer--program-native program)
            (ebox-layer--native-prepare count (ebox-layer--program-height program)
                                        (ebox-layer--program-width program))
            (ebox-layer--program-native-dirty program) (make-vector count t))
      (let ((spines (ebox-layer--program-row-spines program)))
        (if spines
            (dotimes (row (length spines))
              (aset spines row (nconc (aref spines row) (make-list (- count old) nil))))
          (unless (ebox-layer--program-native program)
            (setq spines (make-vector (ebox-layer--program-height program) nil))
            (dotimes (row (length spines)) (aset spines row (make-list count nil)))
            (setf (ebox-layer--program-row-spines program) spines)))))
    program))

(defun ebox-layer--program-replace-target (program id pieces x y)
  "Stage ID's placed PIECES at origin X, Y as PROGRAM's complete footprint.
PIECES are `ebox-layer--pieces' intervals of one positioned panel whose
geometry does not participate in normal flow.  Existing primitive indexes
are reused in order; missing ones are appended once and surplus ones stop
painting.  Record identity, stacking and document order are preserved, and
settlement restores the previous records and target vector on rejection."
  (let* ((targets (ebox-layer--program-targets program))
         (target (gethash id targets))
         (count (length pieces))
         (needed (max 0 (- count (length target))))
         (first (length (ebox-layer--program-records program))))
    (unless (and target (> (length target) 0))
      (error "Ebox prepared panel has no primitive target: %S" id))
    (setf (ebox-layer--program-pending program) t)
    (when (> needed 0)
      (unless (ebox-layer--program-saved-count program)
        (setf (ebox-layer--program-saved-count program) first))
      (ebox-layer--program-grow program (+ first needed))
      (let* ((records (ebox-layer--program-records program))
             (template (aref records (aref target 0)))
             (z (aref (ebox-layer--program-z-values program) (aref target 0)))
             (rank (aref (ebox-layer--program-document-order program) (aref target 0)))
             (indexes (make-vector (+ (length target) needed) 0)))
        (dotimes (offset (length target)) (aset indexes offset (aref target offset)))
        (dotimes (offset needed)
          (let ((index (+ first offset)))
            (aset records index (list :node (plist-get template :node) :x 0
                                      :y ebox-layer--parked-row :text ""
                                      :source-start 0 :source-end 0 :source-row 0))
            (aset (ebox-layer--program-z-values program) index z)
            (aset (ebox-layer--program-document-order program) index rank)
            (aset indexes (+ (length target) offset) index)))
        (unless (assoc id (ebox-layer--program-saved-targets program))
          (push (cons id target) (ebox-layer--program-saved-targets program)))
        (puthash id indexes targets)
        (setq target indexes)
        (setf (ebox-layer--program-order-dirty program) t
              (ebox-layer--program-order-changed program) t)))
    (let ((records (ebox-layer--program-records program)) (tail pieces))
      (dotimes (offset (length target))
        (let* ((index (aref target offset))
               (record (aref records index))
               (piece (pop tail)))
          (unless (aref (ebox-layer--program-saved-records program) index)
            (aset (ebox-layer--program-saved-records program) index (copy-sequence record)))
          (ebox-layer--program-mark-row program (plist-get record :y))
          (aset (ebox-layer--program-native-dirty program) index t)
          (if (null piece)
              (plist-put record :y ebox-layer--parked-row)
            (plist-put record :text (plist-get piece :line))
            (plist-put record :source-start (plist-get piece :start))
            (plist-put record :source-end (plist-get piece :end))
            (plist-put record :source-row (plist-get piece :y))
            (plist-put record :x (+ x (plist-get piece :start)))
            (plist-put record :y (+ y (plist-get piece :y)))
            (ebox-layer--program-mark-row program (plist-get record :y))))))
    target))

(defun ebox-layer--program-render (program &optional rows-only)
  "Render PROGRAM's damaged rows using prepared numeric or placement storage.
The row compositor still creates output strings and pixel clipping artifacts;
those primitive costs remain measurable independently from preparation.
A batch must be closed before rendering; repeated renders preserve the first
accepted row baseline until settlement."
  (when (ebox-layer--program-batch-open program)
    (error "Ebox composition batch must be closed before rendering"))
  (let* ((height (ebox-layer--program-height program))
         (records (ebox-layer--program-records program))
         (order (ebox-layer--program-order program))
         (heads (ebox-layer--program-row-heads program))
         (tails (ebox-layer--program-row-tails program))
         (spines (ebox-layer--program-row-spines program))
         (dirty (ebox-layer--program-dirty program))
         (base (ebox-layer--program-base-lines program))
         (rows (ebox-layer--program-rows program))
         (ebox-composite--prepared-lines (ebox-layer--program-slice-indexes program)))
    (unless (ebox-layer--program-render-native program)
      (setq spines (ebox-layer--program-row-spines program))
      (dotimes (row height)
        (when (aref dirty row)
          (aset heads row nil)
          (aset tails row (aref spines row))))
      (dotimes (offset (length order))
        (let* ((record (aref records (aref order offset)))
               (row (plist-get record :y)))
          (when (and (integerp row) (<= 0 row) (< row height)
                     (aref dirty row))
            (let ((tail (aref tails row)))
              (setcar tail record)
              (unless (aref heads row) (aset heads row tail))
              (aset tails row (cdr tail))))))
      (let ((saved (ebox-layer--program-saved-rows program)))
        (dotimes (row height)
          (when (aref dirty row)
            ;; Keep the allocated spine intact.  The compositor receives the
            ;; bounded prefix length rather than severing a reusable list tail.
            (let ((rendered (ebox-composite-line
                             (if (< row (length base)) (aref base row) "")
                             (aref heads row) (ebox-layer--program-width program)
                             (aref tails row)))
                  (baseline (aref saved row)))
              ;; Restacking or moving a record often leaves a row's accepted
              ;; pixels identical.  Settle such rows here so wrappers, enclosing
              ;; programs and the buffer never revisit them.
              (if (and baseline (equal-including-properties rendered baseline))
                  (progn (aset rows row baseline)
                         (aset saved row nil)
                         (aset dirty row nil))
                (aset rows row rendered)))))))
    (unless rows-only
      (let ((tail (ebox-layer--program-output-spine program)))
        (dotimes (row height)
          (setcar tail (aref rows row))
          (setq tail (cdr tail))))
      (ebox-lines-join (ebox-layer--program-output-spine program)))))

(defun ebox-layer--program-replace-rows
    (program target lines first-row dirty content-offset)
  "Stage prepared TARGET raster LINES into enclosing PROGRAM.
FIRST-ROW is the source-row origin established at compilation.  DIRTY is the
child plane's damage vector; CONTENT-OFFSET locates that plane in its wrapper.
Every target piece retains its pixel interval and placement."
  (setf (ebox-layer--program-pending program) t)
  (dotimes (offset (length target))
    (let* ((index (aref target offset))
           (record (aref (ebox-layer--program-records program) index))
           (row (- (plist-get record :source-row) first-row))
           (content-row (- row content-offset)))
      (unless (and (<= 0 row) (< row (length lines)))
        (error "Ebox prepared enclosing raster changed its row topology"))
      (when (and (<= 0 content-row) (< content-row (length dirty))
                 (aref dirty content-row))
        (ebox-layer--program-replace-text program index (aref lines row))))))

(defun ebox-layer--program-settle (program accepted)
  "Accept or restore all PROGRAM's pending primitive changes as one unit.
Rejection also handles an open batch or a failure before the first render."
  (when (ebox-layer--program-pending program)
    ;; A rejected candidate cannot become the module's next source baseline.
    ;; Refresh its numeric cache from restored authoritative records on next use.
    (unless accepted (fillarray (ebox-layer--program-native-dirty program) t))
    (let ((records (ebox-layer--program-records program))
          (zs (ebox-layer--program-z-values program))
          (coordinates (ebox-layer--program-saved-coordinates program))
          (saved-z (ebox-layer--program-saved-z program))
          (geometry (ebox-layer--program-modified-geometry program))
          (texts (ebox-layer--program-modified-texts program))
          (saved-texts (ebox-layer--program-saved-texts program)))
      (dotimes (index (length records))
        ;; A footprint snapshot follows any translation in the same batch.
        (when-let* ((saved (aref (ebox-layer--program-saved-records program) index)))
          (unless accepted
            (let ((record (aref records index)))
              (setcar record (car saved))
              (setcdr record (cdr saved))))
          (aset (ebox-layer--program-saved-records program) index nil))
        (when (aref (ebox-layer--program-modified-ends program) index)
          (unless accepted
            (plist-put (aref records index) :source-end
                       (aref (ebox-layer--program-saved-ends program) index)))
          (aset (ebox-layer--program-modified-ends program) index nil))
        (when (aref geometry index)
          (unless accepted
            (let ((record (aref records index)))
              (plist-put record :x (aref coordinates (* 2 index)))
              (plist-put record :y (aref coordinates (1+ (* 2 index))))
              (aset zs index (aref saved-z index))))
          (aset geometry index nil))
        (when (aref texts index)
          (unless accepted
            (plist-put (aref records index) :text (aref saved-texts index)))
          (aset saved-texts index nil)
          (aset texts index nil)))
      (unless accepted
        (dolist (entry (ebox-layer--program-saved-targets program))
          (puthash (car entry) (cdr entry) (ebox-layer--program-targets program)))
        ;; Appended primitives stay allocated but can no longer paint.
        (when-let* ((count (ebox-layer--program-saved-count program)))
          (cl-loop for index from count below (length records)
                   do (plist-put (aref records index) :y ebox-layer--parked-row))))
      (setf (ebox-layer--program-saved-targets program) nil
            (ebox-layer--program-saved-count program) nil))
    (when (if accepted (ebox-layer--program-order-dirty program)
            (ebox-layer--program-order-changed program))
      (ebox-layer--program-sort program))
    (dotimes (row (ebox-layer--program-height program))
      (when (aref (ebox-layer--program-dirty program) row)
        (unless accepted
          (aset (ebox-layer--program-rows program) row
                (aref (ebox-layer--program-saved-rows program) row)))
        (aset (ebox-layer--program-saved-rows program) row nil)
        (aset (ebox-layer--program-dirty program) row nil)))
    (setf (ebox-layer--program-pending program) nil
          (ebox-layer--program-batch-open program) nil
          (ebox-layer--program-order-dirty program) nil
          (ebox-layer--program-order-changed program) nil)))

(defun ebox-layer--prepare-raster (node text)
  "Return prepared local pixels for NODE's rendered TEXT.
Placement is deliberately absent from this artifact: moving or restacking a
panel does not split, measure or rediscover the ownership of its rows.  The
ordinary rendering path still establishes TEXT; prepared geometry operations
can consume the same artifact directly after their dependency validation."
  (let* ((key (ebox-layer--compose-cache-key node 'raster))
         (previous (and key ebox-layer--composition-context
                        (hash-table-p ebox-layer--previous-composition-cache)
                        (gethash key ebox-layer--previous-composition-cache)))
         (raster
          (if (and (ebox-layer--raster-p previous)
                   (equal ebox-layer--composition-context
                          (ebox-layer--raster-context previous))
                   (equal-including-properties
                    text (ebox-layer--raster-text previous)))
              previous
            (let ((lines (and text (ebox-string-lines text))))
              (ebox-layer--make-raster
               :text text :context ebox-layer--composition-context
               :lines lines :pieces (ebox-layer--pieces lines node)
               :width (if lines
                          (apply #'max
                                 (mapcar #'ebox--string-pixel-width lines))
                        0))))))
    (when (and key ebox-layer--composition-context
               (hash-table-p ebox-layer--composition-cache))
      (puthash key raster ebox-layer--composition-cache))
    raster))

(defun ebox-layer-active-p (&optional node)
  "Return the current candidate's layer capability without repeated scans."
  (if (eq ebox-layer--active-p 'unknown)
      (if ebox-layer--render-root
          (setq ebox-layer--active-p
                (ebox-layer-subtree-p ebox-layer--render-root))
        (ebox-layer-subtree-p node))
    ebox-layer--active-p))

(defun ebox-layer-positioned-p (node)
  "Return non-nil when NODE opts into positioned box painting."
  (memq (plist-get node :position) '(relative absolute)))

(defun ebox-layer-absolute-subtree-p (node)
  "Return non-nil when NODE's subtree contains an absolutely positioned box.
A base-size measurement renders only flow children, so its output omits these
boxes and must never be reused as final paint."
  (and (listp node)
       (or (eq (plist-get node :position) 'absolute)
           (cl-some #'ebox-layer-absolute-subtree-p
                    (ebox-tree-node-children node)))))

(defun ebox-layer-host-p (node)
  "Return non-nil when NODE composes positioned direct children."
  (and (eq (plist-get node :ebox-kind) 'box)
       (cl-some #'ebox-layer-positioned-p
                (ebox-tree-layout-children node))))

(defun ebox-layer-subtree-p (node)
  "Return non-nil when NODE's logical subtree contains positioned painting."
  (and (listp node)
       (or (ebox-layer-host-p node)
           (ebox-layer-positioned-p node)
           (cl-some #'ebox-layer-subtree-p (ebox-tree-node-children node)))))

(defun ebox-layer-portals-p (node)
  "Return non-nil when NODE's subtree projects content to its render root."
  (and (listp node)
       (or (eq (plist-get node :layer) 'root)
           (cl-some #'ebox-layer-portals-p (ebox-tree-node-children node)))))

(defun ebox-layer-visible-portals-p (node)
  "Return non-nil when NODE can paint an absolute root projection.
Hidden owners suppress their complete logical subtree.  Keep this visible
dependency separate from structural portal detection: hidden portals remain
in the retained input and can become visible in a later candidate."
  (and (listp node)
       (not (eq (plist-get node :visibility) 'hidden))
       (or (and (eq (plist-get node :position) 'absolute)
                (eq (plist-get node :layer) 'root))
           (cl-some #'ebox-layer-visible-portals-p
                    (ebox-tree-node-children node)))))

(defun ebox-layer--owned-p (line position region)
  "Whether LINE at POSITION visibly belongs to REGION, excluding margins."
  (and (not (cl-some (lambda (role)
                       (equal region (get-text-property position role line)))
                     '(ebox-ml ebox-mr ebox-mt ebox-mb)))
       (or (member region (get-text-property position 'ebox-content-owners line))
           (equal region (get-text-property position 'ebox-content-owner line))
           (cl-some (lambda (role)
                      (equal region (get-text-property position (cdr role) line)))
                    ebox-region-types))))

(defun ebox-layer-cached-root-scroll-p (root state)
  "Return non-nil when ROOT can slice STATE's complete composed content.
This proves only the cached content geometry.  Callers must separately prove
a pure root scroll transaction with unchanged source and display context.
Root projections and anchored provider chains are already composed in this
content coordinate system, before the root wrapper applies its scroll offset.
Nested scroll changes and source updates cannot use this root-only proof."
  (and root state
       (equal (plist-get root :node-id)
              (plist-get (plist-get state :box) :node-id))
       (eq (ebox-get root :overflow) 'scroll)
       (plist-get state :content-lines)
       (or (plist-get state :content-lines-complete-p)
           (and (not (plist-get state :render-content-prefix))
                (not (plist-get state :materialize-content-lines))))
       (not (plist-get state :lazy-scroll-prefix-dirty))
       (not (plist-get state :lazy-scroll-window-refresh-required))))

(defun ebox-layer--prefix-width (line end)
  "Return LINE's original prefix width at END within this composition."
  (if (zerop end) 0
    (let ((widths (or (gethash line ebox-layer--piece-width-cache)
                      (puthash line (make-hash-table :test #'eql)
                               ebox-layer--piece-width-cache))))
      (or (gethash end widths)
          (puthash end (ebox--substring-pixel-width line 0 end) widths)))))

(defun ebox-layer--pieces (lines node)
  "Return NODE's visible source intervals in LINES, before positioning."
  (let ((region (ebox--ensure-region-id node))
        (ebox-layer--piece-width-cache
         (or ebox-layer--piece-width-cache (make-hash-table :test #'eq)))
        pieces)
    ;; Measure only the edges of maximal owned character runs.  Adjacent
    ;; runs separated by zero-width foreign text merge below, as before.
    (cl-loop for line in lines for row from 0 do
             (let ((start 0) (limit (length line)) run)
               (while (<= start limit)
                 (let* ((end (and (< start limit) (next-property-change start line limit)))
                        (owned (and end (ebox-layer--owned-p line start region))))
                   (cond
                    ((and owned (null run)) (setq run start))
                    ((and run (not owned))
                     (let ((x (ebox-layer--prefix-width line run))
                           (right (ebox-layer--prefix-width line start)))
                       (when (> right x)
                         ;; Keep the full row as source so shaping and shared
                         ;; display objects are measured in their own context.
                         (push (list :line line :start x :end right :y row)
                               pieces)))
                     (setq run nil)))
                   (setq start (or end (1+ limit)))))))
    ;; Property boundaries must not become artificial glyph clipping edges.
    (let (merged)
      (dolist (piece (nreverse pieces))
        (let ((last (car merged)))
          (if (and last (= (plist-get last :y) (plist-get piece :y))
                   (= (plist-get last :end) (plist-get piece :start)))
              (plist-put last :end (plist-get piece :end))
            (push piece merged))))
      (nreverse merged))))

(defun ebox-layer--bounds (pieces)
  "Return (X Y WIDTH HEIGHT) covering nonempty PIECES, or nil."
  (when pieces
    (let ((left (apply #'min (mapcar (lambda (p) (plist-get p :start)) pieces)))
          (right (apply #'max (mapcar (lambda (p) (plist-get p :end)) pieces)))
          (top (apply #'min (mapcar (lambda (p) (plist-get p :y)) pieces)))
          (bottom (apply #'max (mapcar (lambda (p) (plist-get p :y)) pieces))))
      (list left top (- right left) (1+ (- bottom top))))))

(defun ebox-layer--offset (node property host extent)
  "Resolve NODE's PROPERTY against HOST and containing axis EXTENT."
  (let* ((vertical (eq property :top))
         (value (or (plist-get node property) (if vertical '(lh 0) '(px 0))))
         (pixels (ebox--size-pixels value host (if vertical 'height 'width)
                                   (if vertical
                                       (* extent (ebox--size-line-height host))
                                     extent))))
    (unless (numberp pixels)
      (error "Ebox layer offset has no definite containing size: %S" value))
    (if vertical (floor (/ pixels (float (ebox--size-line-height host)))) pixels)))

(defun ebox-layer--validate-child (node host)
  "Check text backend placement contracts for NODE inside HOST."
  (ebox-layer-validate-node node)
  (when (ebox-layer-positioned-p node)
    (let ((limit (ebox--size-line-height host)))
      (cl-labels ((check (child)
                    ;; Ordinary descendants still paint on the containing
                    ;; plane's physical text rows.  A larger descendant font
                    ;; would stretch every sibling layer on the same row.
                    (let ((height (ebox--size-line-height child)))
                      (when (> height limit)
                        (error "Ebox layered content exceeds its plane's line height (node=%S height=%s limit=%s)"
                               (plist-get child :ebox-type) height limit)))
                    (mapc #'check (ebox-tree-node-children child))))
        (check node)))))

(defun ebox-layer-validate-node (node)
  "Validate NODE's placement combinations independently of visibility."
  (when (and (or (plist-get node :anchor)
                 (eq (plist-get node :layer) 'root))
             (not (eq (plist-get node :position) 'absolute)))
    (error "Ebox :anchor and :layer root require :position absolute")))

(defun ebox-layer--ordered-records (host records)
  "Sort candidate RECORDS by layer and HOST logical document order."
  (let ((order (make-hash-table :test #'eq)) (index 0))
    (cl-labels ((visit (node)
                  (puthash node (cl-incf index) order)
                  (mapc #'visit (ebox-tree-node-children node))))
      (visit host))
    (cl-stable-sort
     (copy-sequence records)
     (lambda (a b)
       (let* ((an (plist-get a :node)) (bn (plist-get b :node))
              (az (or (plist-get an :z-index) 0))
              (bz (or (plist-get bn :z-index) 0)))
         (cond
          ((/= az bz) (< az bz))
          ((not (eq (and (ebox-layer-positioned-p an) t)
                    (and (ebox-layer-positioned-p bn) t)))
           (not (ebox-layer-positioned-p an)))
          (t (< (gethash an order 0) (gethash bn order 0)))))))))

(defun ebox-layer--stable-node-id (node)
  "Return NODE's retained identity, or nil when it cannot be proven stable."
  (or (plist-get node :node-id)
      (and ebox--render-source-index
           (ebox-tree-node-id ebox--render-source-index node))))

(defun ebox-layer--record-signature (record)
  "Return immutable comparison facts for one paint RECORD.
Do not retain NODE itself: copied candidate nodes can have mutable transient
attachments.  Compare the source interval and original row with its complete
text properties, without materializing a slice before the reuse decision."
  (let ((node (plist-get record :node)))
    (list :node-id (ebox-layer--stable-node-id node)
          :x (plist-get record :x)
          :y (plist-get record :y)
          :z-index (or (plist-get node :z-index) 0)
          :positioned (and (ebox-layer-positioned-p node) t)
          :source-start (plist-get record :source-start)
          :source-end (plist-get record :source-end)
          :text (plist-get record :text))))

(defun ebox-layer--compose-cache-key (host phase)
  "Return the retained-ledger key for HOST and composition PHASE.
Use the retained node id so copied candidate nodes can reuse their prior
host's rows; an unidentifiable host disables the cache."
  (when-let* ((id (ebox-layer--stable-node-id host)))
    (cons id phase)))

(defun ebox-layer--compose-native-rows (ordered width height base-lines rows dirty)
  "Compose candidate ORDERED intervals into dirty ROWS with the shared kernel.
WIDTH, HEIGHT and BASE-LINES describe the candidate plane.  Ordinary rendering
owns this scratch program for one evaluation; no published cache is mutated."
  (let ((count (+ (length ordered) (length base-lines))))
    (when-let* ((native (and ordered (cl-position t dirty)
                            (ebox-layer--native-prepare count height width))))
      (let* ((bases (cl-loop for text in base-lines for row from 0
                             collect (list :x 0 :y row :text text
                                           :source-start 0 :source-end width)))
             (program (ebox-layer--make-program
                       :width width :height height
                       :records (vconcat bases ordered)
                       :order (vconcat (number-sequence 0 (1- count)))
                       :rows rows :dirty dirty :saved-rows (make-vector height nil)
                       :native native :native-dirty (make-vector count t)
                       :slice-indexes (make-hash-table :test #'eq))))
        (unwind-protect (ebox-layer--program-render-native program)
          (ebox-native--module-release-compositor (aref native 0)))))))

(defun ebox-layer--compose-rows (host records width height &optional phase base-lines)
  "Compose HOST's visible RECORDS in a WIDTH by HEIGHT content canvas.
When the caller binds the retained and candidate ledgers and an immutable
composition context, rows whose ordered record signatures are unchanged are
returned directly without calling `ebox-composite-line'.  PHASE separates
anchor prepasses from final composition so neither can reuse the other.
BASE-LINES, when present, are completed flow rows below every paint record."
  (let* ((phase (or phase ebox-layer--composition-phase))
         (ordered (ebox-layer--ordered-records host records))
         (rows (make-vector height nil))
         (dirty (make-vector height nil))
         (signatures (make-vector height nil))
         (key (ebox-layer--compose-cache-key host phase))
         (previous (and ebox-layer--composition-context
                        (hash-table-p ebox-layer--previous-composition-cache)
                        (gethash key ebox-layer--previous-composition-cache)))
         (old-context (and previous (plist-get previous :context)))
         (old-signatures (and previous (plist-get previous :signatures)))
         (old-rows (and previous (plist-get previous :rows)))
         (cacheable-p (and key ebox-layer--composition-context
                           (hash-table-p ebox-layer--composition-cache)))
         (retained-base-lines base-lines))
    (dolist (record ordered)
      (let ((row (plist-get record :y)))
        (when (and (integerp row) (>= row 0) (< row height))
          (push record (aref rows row)))))
    (dotimes (row height)
      (let* ((placements (nreverse (aref rows row)))
             (base-row (or (pop base-lines) ""))
             (placement-signatures (mapcar #'ebox-layer--record-signature placements))
             (signature (cons base-row placement-signatures))
             (reusable-p
              (and cacheable-p previous
                   (equal old-context ebox-layer--composition-context)
                   (= width (plist-get previous :width))
                   (= height (plist-get previous :height))
                   (vectorp old-signatures) (vectorp old-rows)
                   (= (length old-rows) height)
                   (cl-every (lambda (entry)
                               (plist-get entry :node-id))
                             placement-signatures)
                   (= (length old-signatures) height)
                   (equal-including-properties
                    signature (aref old-signatures row)))))
        (aset signatures row signature)
        (if reusable-p
            (aset rows row (aref old-rows row))
          (aset dirty row t)
          (aset rows row placements))))
    (unless (ebox-layer--compose-native-rows ordered width height retained-base-lines rows dirty)
      (let ((bases retained-base-lines))
        (dotimes (row height)
          (let ((base (or (pop bases) "")))
            (when (aref dirty row)
              (aset rows row (ebox-composite-line base (aref rows row) width)))))))
    (when cacheable-p
      (puthash key (list :context ebox-layer--composition-context
                         :width width :height height
                         :signatures signatures :rows rows
                         :records ordered :base-lines retained-base-lines)
               ebox-layer--composition-cache))
    (append rows nil)))

(defun ebox-layer--anchor-node (host id)
  "Find one logical anchor ID under HOST, rejecting ambiguous IDs."
  (let ((name (format "%s" id)) matches)
    (cl-labels ((visit (node)
                  (when (equal name (ebox-tree-node-id ebox--render-source-index node))
                    (push node matches))
                  (mapc #'visit (ebox-tree-node-children node))))
      (visit host))
    (when (cdr matches) (error "Ebox layer anchor is ambiguous: %s" name))
    (car matches)))

(defun ebox-layer--absolute-origin (node host bounds width height layer-width layer-height)
  "Resolve NODE's origin in HOST, or nil for an invisible anchor.
BOUNDS is the already resolved anchor rectangle, or nil.
WIDTH and HEIGHT bound the host; LAYER-WIDTH and LAYER-HEIGHT bound the panel."
  (let ((x (ebox-layer--offset node :left host width))
        (y (ebox-layer--offset node :top host height))
        (anchor (plist-get node :anchor)))
    (if (not anchor) (list x y)
      (when bounds
          (let* ((placement (or (plist-get node :placement) 'bottom-start))
                 (above (memq placement '(top-start top-end)))
                 (left (+ (car bounds) x
                          (if (memq placement '(bottom-end top-end))
                              (- (nth 2 bounds) layer-width) 0)))
                 (top (+ y (nth 1 bounds)
                         (if above (- layer-height) (nth 3 bounds))))
                 (other (+ y (nth 1 bounds)
                           (if above (nth 3 bounds) (- layer-height)))))
            (when (and (or (< top 0) (> (+ top layer-height) height))
                       (>= other 0) (<= (+ other layer-height) height))
              (setq top other))
            (list (max 0 (min left (max 0 (- width layer-width))))
                  (max 0 (min top (max 0 (- height layer-height))))))))))

(defun ebox-layer--visible-bounds (bounds origin width height)
  "Translate BOUNDS by ORIGIN and intersect the WIDTH by HEIGHT canvas."
  (when (and bounds origin)
    (let* ((x (+ (car bounds) (car origin)))
           (y (+ (cadr bounds) (cadr origin)))
           (left (max 0 x)) (top (max 0 y))
           (right (min width (+ x (nth 2 bounds))))
           (bottom (min height (+ y (nth 3 bounds)))))
      (when (and (> right left) (> bottom top))
        (list left top (- right left) (- bottom top))))))

(defun ebox-layer--absolute-records (host nodes base width height)
  "Resolve HOST's absolute NODES and return opaque paint records.
BASE supplies normal-flow anchor fragments.  Anchor dependencies are resolved
before painting, so source order and z order never select the geometry.
Missing or clipped anchors suppress their dependents; cycles signal before
publication.  Nested root projections join this same candidate-local pass."
  (let ((panels (make-hash-table :test #'eq))
        (parents (make-hash-table :test #'eq))
        (status (make-hash-table :test #'eq))
        (queue (copy-sequence nodes)) order records)
    (cl-labels
        ((index (node)
           (dolist (child (ebox-tree-node-children node))
             (puthash child node parents)
             (index child)))
         (panel-owner (node)
           (while (and node (not (gethash node panels)))
             (setq node (gethash node parents)))
           node)
         (resolve (node)
           (pcase (gethash node status)
             ('visiting (error "Ebox layer anchor dependency is cyclic"))
             ('done (plist-get (gethash node panels) :origin))
             (_
              (puthash node 'visiting status)
              (let* ((panel (gethash node panels))
                     (anchor (plist-get node :anchor))
                     (target (and anchor (ebox-layer--anchor-node host anchor)))
                     (provider (and target (panel-owner target)))
                     (bounds
                      (when (and target (not (eq (plist-get target :visibility) 'hidden)))
                        (if provider
                            (let ((origin (resolve provider)))
                              (ebox-layer--visible-bounds
                               (ebox-layer--bounds
                                (ebox-layer--pieces
                                 (plist-get (gethash provider panels) :lines) target))
                               origin width height))
                          (ebox-layer--bounds (ebox-layer--pieces base target)))))
                     (origin
                      (unless (eq (plist-get node :visibility) 'hidden)
                        (ebox-layer--absolute-origin
                         node host bounds width height
                         (plist-get panel :width) (length (plist-get panel :lines))))))
                (plist-put panel :origin origin)
                (puthash node 'done status)
                origin)))))
      (index host)
      (while queue
        (let ((node (pop queue)))
          (unless (gethash node panels)
            (ebox-layer--validate-child node host)
            ;; A hidden panel still renders so its rows compile ownership
            ;; roles; its records park below the canvas and never paint.
            (let* ((text (ebox--call-with-box-content-context
                          host (lambda () (ebox--render-with-cache node))))
                   (raster (ebox-layer--prepare-raster node text)))
              (puthash node
                       (list :raster raster
                             :lines (ebox-layer--raster-lines raster)
                             :origin nil
                             :width (ebox-layer--raster-width raster))
                       panels)
              (push node order)
              (when (eq host ebox-layer--render-root)
                (dolist (portal ebox-layer--portals)
                  (unless (or (gethash portal panels) (memq portal queue))
                    (setq queue (append queue (list portal))))))))))
      (dolist (node (nreverse order))
        (let ((origin (resolve node))
              (hidden (eq (plist-get node :visibility) 'hidden)))
          (when (or origin hidden)
            (dolist (piece (ebox-layer--raster-pieces
                            (plist-get (gethash node panels) :raster)))
              (push (list :node node
                          :x (if hidden 0 (+ (car origin) (plist-get piece :start)))
                          :y (if hidden ebox-layer--parked-row
                               (+ (cadr origin) (plist-get piece :y)))
                          :text (plist-get piece :line)
                          :source-start (plist-get piece :start)
                          :source-end (plist-get piece :end)
                          :source-row (plist-get piece :y)) records))))))
    records))

(defun ebox-layer--flow-records (host flow lines width height)
  "Extract positioned paint records only when FLOW needs restacking in HOST."
  (let (records)
    (dolist (child flow)
      (unless (eq (plist-get child :visibility) 'hidden)
        (let ((dx (if (eq (plist-get child :position) 'relative)
                      (ebox-layer--offset child :left host width) 0))
              (dy (if (eq (plist-get child :position) 'relative)
                      (ebox-layer--offset child :top host height) 0)))
          (dolist (piece (ebox-layer--pieces lines child))
            (push (list :node child :y (+ dy (plist-get piece :y))
                        :x (+ dx (plist-get piece :start))
                        :text (plist-get piece :line)
                        :source-start (plist-get piece :start)
                        :source-end (plist-get piece :end)
                        :source-row (plist-get piece :y)) records)))))
    records))

(defun ebox-layer--render-retained-root (host)
  "Recompose HOST from a proved changed panel and immutable prior rasters."
  (when-let* (((eq host ebox-layer--render-root))
              ((not ebox--intrinsic-layout-measurement))
              (proof (car ebox-layer--retained-root-input))
              ((equal (plist-get host :node-id) (plist-get proof :root-id)))
              (state (cadr ebox-layer--retained-root-input))
              (nodes (plist-get state :node-table))
              (panel (ebox-runtime-index-get (plist-get proof :panel-id) nodes))
              (entry (plist-get proof :entry))
              ((equal (plist-get entry :context) ebox-layer--composition-context))
              (flow (or (plist-get entry :flow-output)
                        (and (plist-get entry :base-lines)
                             (ebox-lines-join (plist-get entry :base-lines)))))
              (flow-height (or (plist-get entry :flow-height)
                               (length (plist-get entry :base-lines))))
              (width (ebox--wrapper-content-viewport-pixel host))
              ((= width (plist-get entry :width)))
              (height (max flow-height
                           (ceiling (ebox--content-height host flow-height flow))))
              ((= height (plist-get entry :height))))
    (let ((ebox-layer--retained-root-input nil)
          (ebox-layer--piece-width-cache (make-hash-table :test #'eq))
          (discard (plist-get proof :discard))
          records)
      ;; Keep prior entries only outside the replacement and its copied
      ;; ancestors.  Every retained value is immutable; new entries belong
      ;; exclusively to this candidate and disappear on rejection.
      (maphash (lambda (key value)
                 (unless (gethash (car key) discard)
                   (puthash key value ebox-layer--composition-cache)))
               (plist-get proof :cache))
      (dolist (record (plist-get entry :records))
        (unless (equal (plist-get (plist-get record :node) :node-id)
                       (plist-get proof :panel-id))
          (let ((copy (copy-sequence record)))
            (plist-put copy :node
                       (ebox-runtime-index-get
                        (plist-get (plist-get record :node) :node-id) nodes))
            (push copy records))))
      (ebox-layer--validate-child panel host)
      (let* ((text (ebox--call-with-box-content-context
                    host (lambda () (ebox--render-with-cache panel))))
             (raster (ebox-layer--prepare-raster panel text))
             (origin (ebox-layer--absolute-origin
                      panel host nil width height
                      (ebox-layer--raster-width raster)
                      (length (ebox-layer--raster-lines raster))))
             (hidden (eq (plist-get panel :visibility) 'hidden)))
        (dolist (piece (ebox-layer--raster-pieces raster))
          (push (list :node panel
                      :x (if hidden 0 (+ (car origin) (plist-get piece :start)))
                      :y (if hidden ebox-layer--parked-row
                           (+ (cadr origin) (plist-get piece :y)))
                      :text (plist-get piece :line)
                      :source-start (plist-get piece :start)
                      :source-end (plist-get piece :end)
                      :source-row (plist-get piece :y))
                records)))
      (let* ((output (ebox-lines-join
                      (ebox-layer--compose-rows
                       host records width height nil (plist-get entry :base-lines))))
             (next (gethash (ebox-layer--compose-cache-key host 'final)
                            ebox-layer--composition-cache)))
        (plist-put next :flow-output flow)
        (plist-put next :flow-height flow-height)
        (ebox--record-rendered-intrinsic-size
         (ebox--record-rendered-uniform-width output width)
         width flow-height)))))

(defun ebox-layer-render-children (host children renderer)
  "Compose HOST's CHILDREN using ordinary flow RENDERER.
RENDERER accepts a child list.  Logical nodes are never reordered or removed.
Only candidate-local lists of visible paint records are sorted."
  (or (ebox-layer--render-retained-root host)
      (let* ((flow (cl-remove-if (lambda (child)
                               (eq (plist-get child :position) 'absolute)) children))
         (base (funcall renderer flow)))
    (if ebox--intrinsic-layout-measurement base
      (let* ((ebox-layer--piece-width-cache (make-hash-table :test #'eq))
             (lines (ebox-string-lines base))
             (width (or (ebox--wrapper-content-viewport-pixel host)
                        (if lines (apply #'max (mapcar #'ebox--string-pixel-width lines)) 0)))
             (flow-height (length lines))
             (height (max flow-height (ceiling (ebox--content-height host flow-height base))))
             (absolute (cl-remove-if-not (lambda (child)
                                          (eq (plist-get child :position) 'absolute)) children))
             (relative-p (cl-some (lambda (child) (eq (plist-get child :position) 'relative)) flow))
             (flow-z (apply #'max 0 (mapcar (lambda (child) (or (plist-get child :z-index) 0)) flow)))
             (flow-records (and relative-p (ebox-layer--flow-records host flow lines width height)))
             records base-lines)
        (dolist (child children) (ebox-layer--validate-child child host))
        (unless (eq host ebox-layer--render-root)
          (dolist (child absolute)
            (when (and (eq (plist-get child :layer) 'root)
                       (not (eq (plist-get child :visibility) 'hidden)))
              (cl-pushnew child ebox-layer--portals :test #'eq)))
          (setq absolute (cl-remove-if (lambda (child)
                                        (eq (plist-get child :layer) 'root)) absolute)))
        (when (eq host ebox-layer--render-root)
          (setq absolute (append absolute (reverse ebox-layer--portals))))
        (when (and relative-p (cl-some (lambda (child) (plist-get child :anchor)) absolute))
          ;; Anchor geometry follows relative movement and visible clipping,
          ;; not the original flow slot.  This extra composition is needed
          ;; only by anchored panels.
          (setq lines (ebox-layer--compose-rows host flow-records width height
                                                'anchor-prepass)))
        (setq records (ebox-layer--absolute-records host absolute lines width height))
        (if (and (not relative-p)
                 (cl-every (lambda (record)
                             (>= (or (plist-get (plist-get record :node) :z-index) 0) flow-z))
                           records))
            ;; Ordinary flow is already composed. Retain it as the bottom
            ;; plane instead of disassembling every child and composing it
            ;; again. Only overlay intersections now require source slicing.
            (setq base-lines lines)
          (setq records (nconc records (or flow-records
                                          (ebox-layer--flow-records host flow lines width height)))))
        (let* ((output (ebox-lines-join
                        (ebox-layer--compose-rows host records width height nil base-lines)))
               (entry (and (hash-table-p ebox-layer--composition-cache)
                           (gethash (ebox-layer--compose-cache-key host 'final)
                                    ebox-layer--composition-cache))))
          (when entry
            (plist-put entry :flow-output base)
            (plist-put entry :flow-height flow-height))
          (ebox--record-rendered-intrinsic-size
           (ebox--record-rendered-uniform-width output width)
           width flow-height)))))))

(provide 'ebox-layer)

;;; ebox-layer.el ends here
