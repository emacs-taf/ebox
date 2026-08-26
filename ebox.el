;;; ebox.el --- Pixel-perfect box model renderer -*- lexical-binding: t -*-

;; Author: ebox contributors
;; Version: 2.0.0
;; Package-Requires: ((emacs "29.1") (ecss "0.1.0") (tp "1.0.0"))
;; Keywords: ui, graphics, convenience
;; URL: https://github.com/ginqi7/ebox

;;; Commentary:

;; Ebox provides a high-performance, CSS-like box model implementation for Emacs.
;; It renders text content with padding, borders, margins, and background colors
;; using pixel-precise alignment.
;;
;; This file is the public facade and current implementation host.  Internal
;; model modules are loaded here first; behavior moves into them through staged
;; extraction commits while this feature name remains the user-facing entry.

;;; Code:

(defconst ebox--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the active Ebox Lisp sources.")

(defconst ebox--compile-sources
  '("ebox-cache.el" "ebox-style.el" "ebox-node-factory.el"
    "ebox-child-range.el" "ebox-tree.el" "ebox-measure.el"
    "ebox-fragment.el" "ebox-render-context.el" "ebox-layout.el"
    "ebox-flex.el" "ebox-grid.el" "ebox-canonical.el"
    "ebox-buffer-backend.el" "ebox-incremental.el"
    "ebox-native-commit.el" "ebox-surface.el" "ebox-viewport.el"
    "ebox-dsl.el" "ebox-selector.el" "ebox.el"
    "ebox-native-reflow.el")
  "Active Ebox Lisp sources compiled by `ebox-byte-compile'.")

(add-to-list 'load-path ebox--directory)

(require 'cl-lib)
(require 'mwheel)
(require 'seq)
(require 'subr-x)
(require 'ebox-cache)
(require 'ebox-style)
(require 'ebox-node-factory)
(require 'ebox-child-range)
(require 'ebox-tree)
(require 'ebox-measure)
(require 'ebox-fragment)
(require 'ebox-render-context)
(require 'ebox-layout)
(require 'ebox-flex)
(require 'ebox-grid)
(require 'ebox-canonical)
(require 'ebox-buffer-backend)
(require 'ebox-incremental)
(require 'ebox-surface)
(require 'ebox-viewport)
(require 'ebox-dsl)
(require 'ebox-selector)

(declare-function ebox--buffer-update-report "ebox-incremental" (buffer))
(declare-function ebox--set-buffer-update-report
                  "ebox-incremental" (buffer report))
(declare-function ebox--scroll-rendered-content-lines
                  "ebox-layout" (box lines region-id &optional start-index))

(unless (fboundp 'ebox-native-build)
  (autoload 'ebox-native-build "ebox-native-reflow" nil t))
(unless (fboundp 'ebox-native-status)
  (autoload 'ebox-native-status "ebox-native-reflow" nil t))
(defalias 'ebox-select-all #'ebox-selector-query-buffer)
(defalias 'ebox-update-selector #'ebox-selector-update-buffer)

(defgroup ebox nil
  "Pixel-perfect box model renderer for Emacs buffers."
  :group 'applications
  :prefix "ebox-")

;;;###autoload
(defun ebox-byte-compile ()
  "Recompile every active Ebox Lisp source into a neighboring `.elc' file.
The command is safe to run repeatedly after updating Ebox source.  Exact
compiler output is written to `*Ebox Byte Compile*'.  Restart Emacs after a
successful build so the current process loads the new bytecode.  This command
does not compile the optional Rust module."
  (interactive)
  (require 'bytecomp)
  (let* ((sources
          (mapcar (lambda (file) (expand-file-name file ebox--directory))
                  ebox--compile-sources))
         (missing (cl-remove-if #'file-readable-p sources))
         (byte-compile-log-buffer "*Ebox Byte Compile*")
         (log (get-buffer-create byte-compile-log-buffer))
         (load-prefer-newer t)
         failures)
    (when missing
      (user-error "Ebox byte compilation blocked; missing source: %s"
                  (mapconcat #'file-name-nondirectory missing ", ")))
    (unless (file-writable-p ebox--directory)
      (user-error "Ebox byte compilation blocked; directory is not writable: %s"
                  ebox--directory))
    (with-current-buffer log
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Ebox byte compilation\n\nSource: %s\nFiles: %d\n\n"
                        ebox--directory (length sources)))))
    (dolist (source sources)
      (message "Ebox byte-compiling %s..." (file-name-nondirectory source))
      (condition-case err
          (unless (byte-compile-file source)
            (push (file-name-nondirectory source) failures))
        (error
         (push (file-name-nondirectory source) failures)
         (with-current-buffer log
           (let ((inhibit-read-only t))
             (goto-char (point-max))
             (insert (format "\n[%s] %s\n"
                             (file-name-nondirectory source)
                             (error-message-string err))))))))
    (if failures
        (progn
          (display-buffer log)
          (user-error "Ebox byte compilation failed for: %s"
                      (mapconcat #'identity (nreverse failures) ", ")))
      (message "Ebox byte compilation succeeded for %d files; restart Emacs to use the new .elc files"
               (length sources))
      t)))

(defcustom ebox-render-cache-max-entries 2048
  "Maximum persistent rendered-body cache entries retained per buffer.
Continuous viewport and ordinary box resizing can create a distinct rendered
value for every width.  Ebox keeps the newest entries in insertion order and
evicts older entries above this soft bound.  The larger default retains a full
responsive flex resize working set; `ebox-render-cache-max-bytes' remains the
harder memory guard for property-rich natural-height renders."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-render-cache-max-bytes (* 32 1024 1024)
  "Approximate persistent rendered-body cache byte budget per buffer.
Ebox strings store pixel geometry and ownership mainly in text properties, so
an entry-count limit alone cannot bound memory for natural-height documents.
Values above this insertion-order budget evict older entries; one value larger
than the complete budget is rendered normally but is not retained."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-render-root-cache-max-entries 16
  "Maximum complete root-width outputs retained per buffer.
The default retains one maintained manual-resize round trip, including its
predicted widths.  The separate byte budget remains the hard guard for these
large, property-rich strings, so they cannot crowd reusable subtree and flex
measurements or grow with an unbounded resize history."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-render-root-cache-max-bytes (* 8 1024 1024)
  "Approximate byte budget for complete root-width outputs per buffer.
This budget complements `ebox-render-root-cache-max-entries'; oversized root
outputs remain correct but are not retained after rendering."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-scroll-step 1
  "Default number of lines moved by ebox scroll commands."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-wheel-scroll-step 1
  "Default number of lines moved by one vertical mouse wheel event.
Ebox follows ordinary document scrolling by default: one input moves one line
through the scroll owner chain.  Users who prefer larger wheel jumps may
customize this independently from `ebox-scroll-step'."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-wheel-smooth-scroll nil
  "When non-nil, animate mouse wheel scrolling over several short steps."
  :type 'boolean
  :group 'ebox)

(defcustom ebox-wheel-smooth-scroll-interval 0.016
  "Seconds between animated mouse wheel scroll steps."
  :type 'number
  :group 'ebox)

(defcustom ebox-wheel-smooth-scroll-lines-per-tick 4
  "Number of content lines moved by each animated mouse wheel tick."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-wheel-smooth-scroll-target-ticks 8
  "Approximate maximum number of timer ticks used to drain pending wheel input."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-scroll-lazy-prefix-lookahead-lines 8
  "Extra lines rendered ahead when extending lazy scroll prefixes.
This keeps repeated fine scroll steps on the retained viewport path without
materializing the whole scroll source."
  :type 'natnum
  :group 'ebox)

(defcustom ebox-scroll-lazy-idle-prefetch-lines 128
  "Extra lazy scroll lines rendered while Emacs is idle.
This warms the same scroll content cache used by wheel/key scrolling, so deep
scrolling can replace already-rendered line strings instead of producing
hidden rows inside a wheel tick.  Set to 0 to disable idle prefetch."
  :type 'natnum
  :group 'ebox)

(defcustom ebox-scroll-lazy-idle-prefetch-slice-lines 16
  "Maximum lazy scroll lines rendered by one idle prefetch callback.
Idle prefetch may need a larger total lookahead, but each callback stays
bounded so resize-time warming does not monopolize the GUI event loop.  Set to
0 to allow one callback to fill the full lookahead target."
  :type 'natnum
  :group 'ebox)

(defcustom ebox-scroll-lazy-idle-prefetch-delay 0.15
  "Idle seconds to wait before warming lazy scroll prefixes."
  :type 'number
  :group 'ebox)

(defcustom ebox-runtime-idle-prewarm t
  "When non-nil, prepare shared incremental-update state while Emacs is idle.
Prewarming is buffer-runtime scoped and never materializes complete lazy scroll
content.  It prepares indexes only for scroll lines that are already cached."
  :type 'boolean
  :group 'ebox)

(defcustom ebox-runtime-idle-prewarm-delay 0.1
  "Idle seconds to wait before preparing shared incremental-update state."
  :type 'number
  :group 'ebox)

(defcustom ebox-runtime-idle-prewarm-prefix-resume-delay 2.0
  "Idle seconds reserved for interaction before lazy prefix prefetch resumes.
This delay is used only when runtime prewarming has already made prefix
prefetch yield; ordinary prefix scheduling keeps its own configured delay."
  :type 'number
  :group 'ebox)

(defcustom ebox-runtime-idle-prewarm-slice-size 32
  "Maximum nodes or cached scroll lines processed by one prewarm callback."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-native-buffer-scroll t
  "When non-nil, use native-window scrolling for eligible root owners.
The native path is admitted only for an interactive buffer with one complete,
chrome-free root scroll owner and no nested scroll owner.  Its one-time idle
materialization is scheduled for initial display or an explicit visible-window
handoff; ordinary incremental updates and resizes use the retained scroll
patch and never start a second native publication.  Nested or lazy surfaces
keep the transactional retained-window path."
  :type 'boolean
  :group 'ebox)

(defcustom ebox-runtime-idle-reflow-cache-prewarm t
  "When non-nil, predict and cache the next steady viewport reflow.
Each completed nonzero viewport-width delta predicts one following width.  The
predicted render runs after an input-free idle interval and publishes no
buffer or runtime state; it populates the same persistent render cache used by
viewport and ordinary root-width owner rerenders.  Nonpositive predictions
are skipped."
  :type 'boolean
  :group 'ebox)

(defcustom ebox-runtime-idle-reflow-cache-prewarm-delay 0.15
  "Idle seconds before a predicted viewport reflow warms render caches.
User input resets the idle period, so wheel scrolling and editing cannot be
overtaken by a full invisible layout.  Large Playground resize animations use
their bounded native preparation pool instead of this main-thread timer."
  :type 'number
  :group 'ebox)

(defcustom ebox-reflow-cache-prewarm-gc-cons-threshold 'auto
  "Allocation budget used while an idle reflow is being prepared.
The default `auto' learns from measured allocation per predicted layout and
its GC-free duration.  It aims to keep collections uncommon during expensive
resize sequences while retaining smaller heaps for inexpensive pages.  This
is a pressure threshold, not a retained RSS cap.  Set it to a byte count for a
fixed budget, or nil to inherit the surrounding `gc-cons-threshold'."
  :type '(choice (const :tag "Adapt to measured layout cost" auto)
                 (const :tag "Inherit surrounding value" nil)
                 positive-integer)
  :group 'ebox)

(defcustom ebox-reflow-cache-prewarm-gc-auto-frame-budget 0.2
  "Target seconds available for one predicted layout and optional GC.
Automatic reflow GC tuning compares measured GC-free layout time with this
budget.  It never delays or drops a render; it only selects the allocation
threshold used by later invisible prewarms."
  :type 'number
  :group 'ebox)

(defcustom ebox-reflow-cache-prewarm-gc-auto-min-threshold (* 64 1024 1024)
  "Minimum allocation threshold selected for expensive predicted layouts."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-reflow-cache-prewarm-gc-auto-max-threshold (* 1024 1024 1024)
  "Maximum allocation threshold selected for predicted layouts."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-reflow-cache-prewarm-gc-auto-initial-threshold
  (* 512 1024 1024)
  "Initial allocation threshold before a predicted layout has been measured."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-reflow-cache-prewarm-gc-auto-target-layouts 24
  "Target expensive predicted layouts between automatic collections.
Automatic tuning multiplies this horizon by measured allocation per layout.
Faster layouts use a shorter horizon because their collections consume less
of the resize cadence."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-reflow-cache-prewarm-gc-cons-percentage 0.1
  "Heap-relative allocation budget used during idle reflow preparation.
Emacs combines this with `ebox-reflow-cache-prewarm-gc-cons-threshold', so the
effective budget grows with the live working set while garbage collection is
kept inside invisible preparation rather than visible buffer publication.
Set it to nil to inherit the surrounding `gc-cons-percentage'."
  :type '(choice (const :tag "Inherit surrounding value" nil) number)
  :group 'ebox)

;;; ============================================================
;;; Core: Data Structures & String Utils
;;; ============================================================

(defvar ebox--region-id-counter 0
  "Global counter for generating unique box region IDs.")

(defvar ebox--runtime-node-id-counter 0
  "Global counter for internal runtime node IDs.")

(defvar ebox--render-region-id nil
  "Dynamically bound region ID reused during whole-box rerender.")

(defvar ebox-viewport-width nil
  "Dynamically bound horizontal viewport width in pixels.
DSL width values may use `(viewport)' to resolve to this value while a
caller, such as the Playground preview, renders against a concrete window.")

(defvar ebox-viewport-height nil
  "Dynamically bound vertical viewport height in lines.
DSL height values may use `(viewport-height)' to resolve to this value while a
caller, such as the Playground preview, renders against a concrete window.")

(defvar ebox--region-box-table)
(defconst ebox-region-types
  '((content . ebox-content)
    (content-owner . ebox-content-owner)
    (pt . ebox-pt) (pb . ebox-pb) (pl . ebox-pl) (pr . ebox-pr)
    (mt . ebox-mt) (mb . ebox-mb) (ml . ebox-ml) (mr . ebox-mr)
    (bt . ebox-bt) (bb . ebox-bb) (bl . ebox-bl) (br . ebox-br))
  "Mapping from Ebox region roles to rendered text properties.")

(defconst ebox--horizontal-border-anchor-roles
  '(content content-owner pt pb pl pr bl br)
  "Region roles defining a box edge while excluding its margins.")
(defvar ebox--scroll-global-state)
(defvar ebox--smooth-scroll-state-table)
(defvar ebox--render-cache-scroll-state-region-ids nil
  "Dynamically bound set of scroll regions touched by one cached render.")
(defvar ebox--scroll-idle-prefetch-timers (make-hash-table :test 'equal)
  "Region-keyed idle timers that warm lazy scroll prefix caches.")
(defvar ebox--scroll-idle-prefetch-inhibited-buffers
  (make-hash-table :test 'eq)
  "Buffers whose active foreground animation owns idle render time.")
(defvar ebox--scroll-allow-noninteractive-prefetch nil
  "Non-nil lets tests schedule lazy scroll prefetch timers in batch Emacs.")
(defvar ebox--runtime-prewarm-allow-noninteractive nil
  "Non-nil lets tests run buffer runtime prewarming in batch Emacs.")
(defvar ebox--runtime-prewarm-jobs (make-hash-table :test 'eq)
  "Buffer-keyed incremental-update prewarm jobs.")
(defvar ebox--runtime-prewarm-timers (make-hash-table :test 'eq)
  "Buffer-keyed idle timers for incremental-update prewarming.")

(defvar ebox--native-scroll-prewarm-in-progress nil
  "Non-nil while idle native-scroll materialization publishes its candidate.")
(defvar ebox--reflow-cache-prewarm-timers (make-hash-table :test 'eq)
  "Buffer-keyed idle timers for predicted reflow-cache warming.")
(defvar ebox--scroll-prefetch-delay-override nil
  "Dynamically bound delay for scroll prefix prefetch scheduling.")
(defsubst ebox--next-region-id ()
  "Generate next unique region ID."
  (cl-incf ebox--region-id-counter))

(defsubst ebox-get (box property)
  "Retrieve PROPERTY from BOX."
  (plist-get box property))

(defun ebox-put (box property value)
  "Set PROPERTY to VALUE in BOX and return the modified box.
Registered style properties also update BOX's canonical ECSS declarations so a
later cascade computes from the public mutation instead of stale source data."
  (when-let* ((declaration
              (ebox-style-compile-declarations (list property value))))
    (plist-put
     box :ebox-style-declarations
     (ebox-style-merge-declarations
      (plist-get box :ebox-style-declarations) declaration))
    (when (plist-get box :ebox-style-wrapper)
      (plist-put
       box :ebox-style-overrides
       (ebox-style-merge-declarations
        (plist-get box :ebox-style-overrides) declaration))))
  (plist-put box property value))

;;;###autoload
(defun ebox-buffer-update-report (buffer-or-name)
  "Return BUFFER-OR-NAME's stored update report.
The returned plist is a defensive copy of the report owned by the live rendered
buffer.  Signal `user-error' when the target is missing, dead, or has no Ebox
runtime.  A freshly rendered buffer returns nil until its first update
publication."
  (let ((buffer (and buffer-or-name (get-buffer buffer-or-name))))
    (unless (buffer-live-p buffer)
      (user-error "Ebox report target is not a live buffer: %S"
                  buffer-or-name))
    (unless (ebox--buffer-render-state buffer)
      (user-error "Ebox report target has no rendered runtime: %S"
                  buffer-or-name))
    (copy-tree (ebox--buffer-update-report buffer))))

(defun ebox--ensure-region-id (box)
  "Return BOX's stable region id, creating one if needed."
  (or (ebox-get box :region-id)
      (let ((id (ebox--next-region-id)))
        (ebox-put box :region-id id)
        id)))

(defun ebox--next-runtime-node-id ()
  "Return the next internal runtime node id."
  (cl-incf ebox--runtime-node-id-counter))

(defun ebox--ensure-node-id (node)
  "Return NODE's stable internal node id, assigning one when needed."
  (unless (and (listp node) (plist-get node :node-id))
    (plist-put node :node-id (ebox--next-runtime-node-id)))
  (plist-get node :node-id))

(defsubst ebox-string-lines (string)
  "Split STRING into a list of lines, preserving text properties."
  (when string
    (let ((start 0)
          (lines nil))
      (while (string-match "\n" string start)
        (push (substring string start (match-beginning 0)) lines)
        (setq start (match-end 0)))
      (push (substring string start) lines)
      (nreverse lines))))

(defsubst ebox-string-height (string)
  "Return the number of lines in STRING.
Optimized: Counts newlines directly to avoid list allocation."
  (1+ (cl-count ?\n string)))

(defsubst ebox-lines-join (lines)
  "Join a list of LINES into a single string."
  (string-join lines "\n"))

(defun ebox--string-repeat-lines (string count)
  "Repeat a single line STRING for COUNT times."
  (when (and string (> count 0))
    (ebox-lines-join (make-list count string))))

(defun ebox--maplines (function string)
  "Apply FUNCTION to each line of STRING and return the new string."
  (ebox-lines-join (mapcar function (ebox-string-lines string))))

(defun ebox--apply-hidden-visibility (string)
  "Return STRING with all ink suppressed and the footprint intact.
Runs that already render as display specs keep their spec and lose
face color.  Glyph runs are measured with their faces still applied
and then covered by one pixel-exact display space, so line widths are
identical in fixed and variable pitch while nothing is drawn.  Buffer
text and every other text property (region, content, and owner
metadata, event surfaces) stay untouched, which keeps spans, markers,
and incremental diffs byte-compatible with the visible rendering."
  (ebox--maplines
   (lambda (line)
     (if (string-empty-p line)
         line
       ;; Measure the complete visible line first (faces still applied,
       ;; display specs included), then cover every character with its
       ;; own blank display space.  Per-character specs follow the
       ;; engine's measurement convention, and the integer widths sum
       ;; exactly to the visible line's width by construction.
       (let* ((width (ebox--string-pixel-width line))
              (line (copy-sequence line))
              (length (length line))
              (base (/ width length))
              (remainder (- width (* base length))))
         (remove-text-properties
          0 length '(face nil mouse-face nil) line)
         (dotimes (index length)
           (put-text-property
            index (1+ index) 'display
            `(space :width (,(if (< index remainder) (1+ base) base)))
            line))
         line)))
   string))

(defun ebox--maplines-list (function lines)
  "Apply FUNCTION to each line in the list LINES and return a new list."
  (mapcar function lines))

(defun ebox--line-has-non-content-properties-p (line)
  "Return non-nil when LINE carries properties other than content markers."
  (catch 'found
    (let ((pos 0)
          (len (length line)))
      (while (< pos len)
        (let ((props (text-properties-at pos line)))
          (while props
            (let ((prop (pop props)))
              (pop props)
              (unless (memq prop '(display
                                    ebox-content ebox-content-idx
                                    ebox-content-owner
                                    ebox-content-owners))
                (throw 'found t)))))
        (setq pos (or (next-property-change pos line) len))))
    nil))

(defun ebox--lines-pad-vertical (string height &optional offset padding-string)
  "Extend STRING to HEIGHT lines.
OFFSET controls content shift: positive (top), negative (bottom).
PADDING-STRING is used to fill empty lines, defaults to empty string."
  (let* ((lines (ebox-string-lines string))
         (line-count (length lines))
         (padding-string (or padding-string
                             (ebox--pixel-blank
                              (ebox--string-pixel-width string) 1))))
    (when (> height line-count)
      (let* ((rest (- height line-count))
             (offset (or offset 0))
             (top-pad (cond ((>= offset 0) (min offset rest))
                            (t (max 0 (+ offset rest)))))
             (bottom-pad (- rest top-pad))
             (pad-lines (make-list top-pad padding-string))
             (bottom-lines (make-list bottom-pad padding-string)))
        (setq lines (append pad-lines lines bottom-lines))))
    (ebox-lines-join (seq-take lines height))))

(defun ebox--lines-align-vertical (string height align)
  "Align STRING to HEIGHT lines.
ALIGN can be `top', `center', or `bottom'."
  (let* ((line-count (ebox-string-height string))
         (offset (pcase align
                   ('top 0)
                   ('bottom (- height line-count))
                   ('center (/ (- height line-count) 2))
                   (_ 0))))
    (ebox--lines-pad-vertical string height offset)))

(defun ebox--string-lines-pad-bottom (string height)
  "Return STRING lines padded at the bottom to HEIGHT."
  (let* ((lines (ebox-string-lines string))
         (line-count (length lines))
         (extra (- height line-count)))
    (if (<= extra 0)
        lines
      (let* ((blank-width (ebox--string-pixel-width string))
             (blank (or (ebox--pixel-blank blank-width 1) "")))
        (append lines (make-list extra blank))))))

(defun ebox--lines-concat-horizontal (&rest strings)
  "Concatenate STRINGS horizontally, aligning to the tallest string."
  (setq strings (delq nil strings))
  (when strings
    (let* ((heights (mapcar #'ebox-string-height strings))
           (max-height (apply #'max heights))
           (line-lists
            (mapcar (lambda (string)
                      (ebox--string-lines-pad-bottom string max-height))
                    strings)))
      (ebox-lines-join
       (apply #'cl-mapcar #'concat line-lists)))))

(defun ebox--lines-stack-vertical (&rest strings)
  "Stack STRINGS vertically."
  (setq strings (delq nil strings))
  (ebox-lines-join strings))

(defsubst ebox-default-foreground ()
  "Return the default face foreground color."
  (face-attribute 'default :foreground nil t))

(defsubst ebox-default-background ()
  "Return the default face background color."
  (face-attribute 'default :background nil t))


;;; ============================================================
;;; Tree Identity And DSL Helpers
;;; ============================================================
(defun ebox--extract-region-id (string)
  "Extract region-id from rendered box STRING by finding first ebox-content."
  (let ((pos 0)
        (len (length string)))
    (catch 'found
      (while (< pos len)
        (when-let* ((id (get-text-property pos 'ebox-content string)))
          (throw 'found id))
        (setq pos (or (next-single-property-change
                       pos 'ebox-content string)
                      len))))))

(defun ebox--string-region-ids (string)
  "Return all distinct region-ids found in STRING, preserving first-seen order."
  (let ((pos 0)
        (len (length string))
        ids)
    (while (< pos len)
      (when-let* ((id (get-text-property pos 'ebox-content string)))
        (unless (memq id ids)
          (setq ids (append ids (list id)))))
      (setq pos (1+ pos)))
    ids))

;;;###autoload
(defun ebox-region-ids (node)
  "Return NODE's region ids in document order.
NODE can be an unrendered layout tree or an already-rendered string.
For layout trees, missing ids are assigned to box plists and remain stable
for later renders and dynamic updates.

Use this to capture ids *before* inserting into a buffer:

  (let* ((layout (ebox-stack info-box (ebox-concat left right)))
         (ids    (ebox-region-ids layout))
         (info-id (nth 0 ids))
         (left-id (nth 1 ids))
         (right-id (nth 2 ids)))
    (ebox-render-to-buffer \"*my-ui*\" layout)
    ;; now use info-id / left-id / right-id for dynamic updates
    )"
  (cond
   ((stringp node)
    (ebox--string-region-ids node))
   ((not (listp node)) nil)
   (t
    (let ((type (plist-get node :ebox-type)))
      (cond
       ((eq type 'box)
        (cons
         (ebox--ensure-region-id node)
         (apply #'append
                (mapcar #'ebox-region-ids
                        (ebox-tree-node-children node)))))
       ((eq type 'concat)
        (apply #'append
               (mapcar #'ebox-region-ids
                       (ebox--layout-children node))))
       ((eq type 'stack)
        (apply #'append
               (mapcar #'ebox-region-ids
                       (ebox--layout-children node))))
       ((eq type 'flex)
        (if-let* ((box (plist-get node :box)))
            (list (ebox--ensure-region-id box))
          (apply #'append
                 (mapcar #'ebox-region-ids
                         (ebox-tree-layout-children node)))))
       ((eq type 'grid)
        (if-let* ((box (plist-get node :box)))
            (list (ebox--ensure-region-id box))
          (apply #'append
                 (mapcar #'ebox-region-ids
                         (ebox-tree-layout-children node)))))
       ((eq type 'flex-item)
        (ebox-region-ids (plist-get node :node)))
       (t nil))))))

(defun ebox--runtime-node-ids (node)
  "Return internal runtime node ids for NODE and its children."
  (cond
   ((or (stringp node) (not (listp node))) nil)
   (t
    (cons (ebox--ensure-node-id node)
          (apply #'append
                 (mapcar #'ebox--runtime-node-ids
                         (ebox--node-children node)))))))

(defun ebox--runtime-tree (node)
  "Return NODE after assigning runtime ids to every renderable node."
  (ebox--runtime-node-ids node)
  node)

(defun ebox--runtime-node-key (node)
  "Return NODE's explicit runtime key, or nil."
  (when (and (listp node)
             (plist-member node :key))
    (plist-get node :key)))

(defun ebox--runtime-same-type-p (old new)
  "Return non-nil when OLD and NEW have the same runtime node type."
  (and (listp old)
       (listp new)
       (eq (plist-get old :ebox-type)
           (plist-get new :ebox-type))))

(defun ebox--runtime-node-id-by-key (node key)
  "Return the first runtime node id under NODE whose :key equals KEY."
  (when (and key
             (listp node)
             (not (stringp node)))
    (or (when (equal (ebox--runtime-node-key node) key)
          (ebox--ensure-node-id node))
        (cl-some (lambda (child)
                   (ebox--runtime-node-id-by-key child key))
                 (ebox--node-children node)))))

(defun ebox--keyed-runtime-children (children)
  "Return a KEY -> child hash table for explicitly keyed CHILDREN."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (child children)
      (when-let* ((key (ebox--runtime-node-key child)))
        (puthash key child table)))
    table))

(defun ebox--runtime-positional-match (old-child new-child)
  "Return OLD-CHILD when NEW-CHILD can reuse its positional identity."
  (when (and (not (ebox--runtime-node-key old-child))
             (not (ebox--runtime-node-key new-child))
             (ebox--runtime-same-type-p old-child new-child))
    old-child))

(defun ebox--runtime-keyed-match (old-keyed new-child)
  "Return the keyed old child that should match NEW-CHILD."
  (when-let* ((key (ebox--runtime-node-key new-child)))
    (let ((old-child (gethash key old-keyed)))
      (when (ebox--runtime-same-type-p old-child new-child)
        old-child))))

(defun ebox--assign-runtime-node-id-from-match (old new)
  "Assign NEW retained runtime identity from OLD when possible."
  (ebox-tree-transfer-runtime-identity old new))

(defun ebox--reconcile-runtime-tree (old new)
  "Transfer stable runtime identities from OLD to matching nodes in NEW.

Matching rules are deliberately small: a child with an explicit :key only
matches an old sibling with the same key and node type; unkeyed children may
reuse same-position ids when their node type is unchanged.  Retained boxes
also keep their region ids so buffer properties remain aligned with runtime
indexes.  This prepares component identity without exposing a component API."
  (ebox-tree-reconcile-runtime old new))

;;;###autoload
(defun ebox-build (dsl)
  "Build an Ebox node from an ETML-style list DSL."
  (ebox-dsl-build dsl))

;;; ============================================================
;;; Property Rules: 配置驱动的 Shorthand/Longhand 映射
;;; ============================================================
;;
;; 规则格式自描述，无需 type 标记：
;; - 值是 list → shorthand，展开到列表中的属性
;; - 值是 (keyword . converter) → longhand，转换后写入目标
;; - 值是 keyword → 直通，属性名不变

(defconst ebox-property-rules ebox-style-ebox-property-rules
  "Compatibility alias for Ebox public property expansion rules.")

;;; --- 值转换器 ---

(defun ebox--convert (value converter)
  "Convert VALUE using CONVERTER."
  (ebox-style--convert value converter))

;;; --- 值拆分器 ---

(defun ebox--split-trbl (value)
  "Split VALUE using CSS TRBL rules → (top right bottom left)."
  (ebox-style--split-trbl value))

(defun ebox--split-pair (value)
  "Split VALUE into pair → (start end)."
  (ebox-style--split-pair value))

(defconst ebox--border-styles
  '(none hidden dotted dashed solid double groove ridge inset outset)
  "Valid CSS border-style keywords.")

(defun ebox--wsc-classify (item)
  "Classify ITEM as width, style, or color. Returns (type . value)."
  (ebox-style--wsc-classify item))

(defun ebox--split-wsc (value)
  "Split VALUE into (width style color) using CSS type-based parsing.
Values can appear in any order; each is identified by type."
  (ebox-style--split-wsc value))

(defun ebox--split-value (value mode n)
  "Split VALUE according to MODE for N targets."
  (ebox-style--split-value value mode n))

;;; --- 核心展开函数 ---

(defun ebox--get-rule (property)
  "Get rule for PROPERTY from `ebox-property-rules'."
  (ebox-style--get-ebox-rule property))

(defun ebox--expand-property (property value)
  "Expand PROPERTY with VALUE according to rules. Returns a plist."
  (ebox-style-expand-ebox-property property value))

;;; --- 辅助函数 ---

(defun ebox--atom-consp (list)
  "Check if LIST is a strict dotted pair (atom . atom)."
  (ebox-style--atom-consp list))

(defun ebox--parse-color (color)
  "Parse COLOR to a real color string.
Supports: t (default fg), nil, string, (light . dark) cons."
  (ebox-style--parse-color color))

(defun ebox--expand-plist (plist)
  "Expand PLIST using `ebox-property-rules'."
  (ebox-style-expand-ebox-plist plist))

;;; --- 核心 API ---

;;; ============================================================
;;; Buffer Runtime State & Scroll State
;;; ============================================================

;; Incremental runtime model boundaries:
;; - Source Tree Model: user/DSL plists with stable :region-id and :node-id.
;; - Render Context Model: dynamic bindings such as `ebox-viewport-width'.
;; - Buffer Runtime Model: per-buffer root node, viewport, and node indexes.
;; - Layout Snapshot Model: derived render facts used for diffing.
;; - Dirty/Owner Model: semantic update impact and minimal layout owners.
;;
;; Dynamic render-local, flex-local, and snapshot-detail-local caches are
;; optimizations.  Do not make them public API or component-owned state.

(defvar ebox--region-box-table (make-hash-table :test 'equal)
  "Maps region-id to its box definition for dynamic content updates.")

(defvar ebox--defer-scroll-content-index nil
  "Non-nil means full scroll content indexes are built lazily.")

(defun ebox--scroll-get-state (region-id)
  "Get scroll state for REGION-ID."
  (gethash region-id ebox--scroll-global-state))

(defun ebox--scroll-cancel-idle-prefetch (region-id)
  "Cancel any pending idle prefix prefetch for REGION-ID."
  (when-let* ((timer (gethash region-id ebox--scroll-idle-prefetch-timers)))
    (when (timerp timer)
      (cancel-timer timer))
    (remhash region-id ebox--scroll-idle-prefetch-timers)))

(defun ebox--scroll-inhibit-idle-prefetch-for-buffer (buffer)
  "Pause lazy scroll prefix work while BUFFER has a foreground animation."
  (when (buffer-live-p buffer)
    (puthash buffer t ebox--scroll-idle-prefetch-inhibited-buffers)
    (maphash
     (lambda (region-id state)
       (when (eq buffer (ebox--scroll-state-buffer state))
         (ebox--scroll-cancel-idle-prefetch region-id)))
     ebox--scroll-global-state)
    t))

(defun ebox--scroll-resume-idle-prefetch-for-buffer (buffer)
  "Resume useful lazy scroll prefix work after BUFFER's animation."
  (when buffer
    (remhash buffer ebox--scroll-idle-prefetch-inhibited-buffers)
    (let (region-ids)
      (maphash
       (lambda (region-id state)
         (when (and (eq buffer (ebox--scroll-state-buffer state))
                    (ebox--scroll-idle-prefetch-needed-p state))
           (push region-id region-ids)))
       ebox--scroll-global-state)
      (dolist (region-id region-ids)
        (ebox--scroll-schedule-idle-prefetch region-id)))))

(defun ebox--scroll-idle-prefetch-needed-p (state)
  "Return non-nil when STATE can benefit from idle prefix prefetch."
  (and (> (or ebox-scroll-lazy-idle-prefetch-lines 0) 0)
       (plist-get state :render-content-prefix)
       (not (plist-get state :content-lines-complete-p))))

(defun ebox--idle-continuation-delay (delay)
  "Return an idle-timer threshold one fresh DELAY beyond current idle time."
  (+ (or (when-let* ((idle (current-idle-time)))
           (float-time idle))
         0)
     (max 0 (or delay 0))))

(defun ebox--scroll-schedule-idle-prefetch (region-id &optional delay)
  "Schedule input-yielding lazy prefix prefetch for REGION-ID when useful."
  (ebox--scroll-cancel-idle-prefetch region-id)
  (when-let* ((state (and (or (not noninteractive)
                             ebox--scroll-allow-noninteractive-prefetch)
                         (ebox--scroll-get-state region-id))))
    (when (and (ebox--scroll-idle-prefetch-needed-p state)
               (let ((buffer (ebox--scroll-state-buffer state)))
                 (not (and buffer
                           (gethash
                            buffer
                            ebox--scroll-idle-prefetch-inhibited-buffers)))))
      (puthash
       region-id
       (run-with-idle-timer
        (max 0 (or delay ebox-scroll-lazy-idle-prefetch-delay 0))
        nil #'ebox--scroll-idle-prefetch region-id)
       ebox--scroll-idle-prefetch-timers))))

(defun ebox--scroll-prefetch-slice-lines ()
  "Return a bounded urgent lazy prefetch slice size in lines."
  (max 1
       (or ebox-scroll-step 1)
       (or ebox-wheel-smooth-scroll-lines-per-tick 1)
       (or ebox-wheel-scroll-step 1)))

(defun ebox--scroll-sync-prefix-render-p ()
  "Return non-nil when scroll input may synchronously render lazy prefixes."
  (or noninteractive
      (not (display-graphic-p))))

(defun ebox--scroll-schedule-cache-miss-prefetch (region-id state)
  "Schedule a bounded urgent prefetch for lazy scroll STATE."
  (if (ebox--scroll-idle-prefetch-needed-p state)
      (let* ((current-lines (length (plist-get state :content-lines)))
             (target-lines
              (+ current-lines (ebox--scroll-prefetch-slice-lines))))
        (setq state
              (plist-put state :cache-miss-prefetch-target-lines
                         target-lines))
        (puthash region-id state ebox--scroll-global-state)
        (ebox--scroll-schedule-idle-prefetch region-id 0)
        state)
    state))

(defun ebox--scroll-idle-prefetch-slice-lines (&optional state)
  "Return STATE's bounded idle prefetch slice, or nil for unbounded.
Composite rows can hide expensive flex work.  Limit latency-sensitive buffers
to one newly requested line per idle turn so one generic slice cannot cross
several costly rows before yielding back to input."
  (let* ((slice (max 0 (or ebox-scroll-lazy-idle-prefetch-slice-lines 0)))
         (buffer (and state (ebox--scroll-state-buffer state))))
    (when (and (> slice 0)
               buffer
               (ebox--buffer-latency-sensitive-scroll-prefix-p buffer))
      (setq slice 1))
    (and (> slice 0) slice)))

(defun ebox--scroll-ensure-bounded-prefix-for-offset
    (region-id state desired-offset &optional budget-lines)
  "Extend lazy scroll STATE just enough to approach DESIRED-OFFSET.

This is the synchronous edge of the lazy scroll model: visible scrolling can
only replace cached line strings after those strings exist.  When the user
reaches the current lazy prefix boundary, render at most one configured
interactive slice instead of pausing for an idle timer or materializing the
entire source.  BUDGET-LINES caps how many new source lines this call may
request; callers that represent GUI animation ticks pass their tick size."
  (let* ((content-lines (plist-get state :content-lines))
         (content-height (or (plist-get state :content-height) 0))
         (current-lines (length content-lines))
         (max-offset (max 0 (- current-lines content-height))))
    (if (or (<= desired-offset max-offset)
            (not (plist-get state :render-content-prefix))
            (plist-get state :content-lines-complete-p))
        state
      (let* ((visible-end (+ (max 0 desired-offset) content-height))
             (slice-lines (max 1 (or budget-lines ebox-scroll-step 1)))
             (slice-end (+ current-lines slice-lines))
             (required-lines (max current-lines
                                  (min visible-end slice-end)))
             (ebox-scroll-lazy-prefix-lookahead-lines 0))
        (ebox--scroll-state-ensure-prefix-lines
         region-id state required-lines t)))))

(defun ebox--smooth-scroll-active-p (region-id)
  "Return non-nil when REGION-ID has an active smooth scroll timer."
  (when-let* ((entry (gethash region-id ebox--smooth-scroll-state-table)))
    (and (timerp (plist-get entry :timer))
         (not (plist-get entry :waiting-prefetch)))))

(defun ebox--smooth-scroll-resume-after-prefetch (region-id)
  "Resume REGION-ID smooth scrolling after a paused lazy prefetch."
  (when-let* ((entry (gethash region-id ebox--smooth-scroll-state-table)))
    (when (plist-get entry :waiting-prefetch)
      (plist-put entry :waiting-prefetch nil)
      (unless (timerp (plist-get entry :timer))
        (plist-put
         entry :timer
         (run-at-time ebox-wheel-smooth-scroll-interval
                      ebox-wheel-smooth-scroll-interval
                      #'ebox--smooth-scroll-tick region-id)))
      (puthash region-id entry ebox--smooth-scroll-state-table))))

(defun ebox--scroll-idle-prefetch (region-id)
  "Warm REGION-ID's lazy scroll prefix cache while Emacs is idle."
  (remhash region-id ebox--scroll-idle-prefetch-timers)
  (if (ebox--smooth-scroll-active-p region-id)
      (ebox--scroll-schedule-idle-prefetch
       region-id
       (ebox--idle-continuation-delay
        ebox-scroll-lazy-idle-prefetch-delay))
    (when-let* ((state (ebox--scroll-get-state region-id)))
      (let ((buffer (ebox--scroll-state-buffer state))
            (cache-miss-target
             (plist-get state :cache-miss-prefetch-target-lines)))
        (if (and buffer
                 (not cache-miss-target)
                 (gethash buffer ebox--runtime-prewarm-jobs))
            (ebox--scroll-schedule-idle-prefetch
             region-id
             (ebox--idle-continuation-delay
              ebox-runtime-idle-prewarm-prefix-resume-delay))
          (when (ebox--scroll-idle-prefetch-needed-p state)
            (let* ((defer-gc
                    (and buffer
                         (cl-some
                          (lambda (window)
                            (display-graphic-p (window-frame window)))
                          (get-buffer-window-list buffer nil t))))
                   (current-lines (length (plist-get state :content-lines)))
                   (prefetch-lines
                    (max 0 ebox-scroll-lazy-idle-prefetch-lines))
                   (visible-target-lines
                    (+ (or (plist-get state :scroll-offset) 0)
                       (or (plist-get state :content-height) 0)
                       prefetch-lines))
                   (target-lines
                    (if cache-miss-target
                        (max current-lines cache-miss-target)
                      (max (+ current-lines prefetch-lines)
                           visible-target-lines)))
                   (slice-lines (ebox--scroll-idle-prefetch-slice-lines state))
                   (bounded-target-lines
                    (if slice-lines
                        (min target-lines (+ current-lines slice-lines))
                      target-lines)))
              (when defer-gc
                (ebox--deferred-render-gc-enter))
              (unwind-protect
                  (progn
                    ;; A configured slice is the complete hidden-work budget
                    ;; for this idle turn.  The generic prefix helper normally
                    ;; adds a completion sentinel and smooth-scroll lookahead;
                    ;; exact mode defers both so a one-line slice cannot turn
                    ;; back into a multi-row render and reintroduce input
                    ;; stalls.
                    (let ((ebox-scroll-lazy-prefix-lookahead-lines
                           (if slice-lines
                               0
                             ebox-scroll-lazy-prefix-lookahead-lines))
                          (ebox--scroll-window-yielding-prewarm-p
                           (and slice-lines (= slice-lines 1))))
                      (setq state
                            (ebox--scroll-state-ensure-prefix-lines
                             region-id state bounded-target-lines
                             (and slice-lines t))))
                    (when (and cache-miss-target
                               (>= (length (plist-get state :content-lines))
                                   cache-miss-target))
                      (setq state (ebox--plist-remove
                                   state :cache-miss-prefetch-target-lines))
                      (puthash region-id state ebox--scroll-global-state))
                    (let ((prefix-still-needed-p
                           (ebox--scroll-idle-prefetch-needed-p state)))
                      (when prefix-still-needed-p
                        (ebox--scroll-schedule-idle-prefetch
                         region-id
                         (ebox--idle-continuation-delay
                          ebox-scroll-lazy-idle-prefetch-delay)))
                      ;; Restart the shared tree/index prewarm once after the
                      ;; lazy prefix settles.  Restarting it after every
                      ;; one-line slice makes each following slice yield for
                      ;; the full priority delay and can starve idle prefix
                      ;; progress indefinitely.
                      (when (and buffer (not prefix-still-needed-p))
                        (ebox--schedule-buffer-runtime-prewarm buffer)))
                    (ebox--smooth-scroll-resume-after-prefetch region-id))
                (when defer-gc
                  (ebox--deferred-render-gc-schedule-restore))))))))))

(defun ebox--scroll-state-buffer (state)
  "Return the buffer associated with scroll STATE, or nil."
  (plist-get state :buffer))

;;;###autoload
(defun ebox-scroll-state (region-id)
  "Return the scroll state plist for REGION-ID, or nil.
The plist is read-only API for consumers that need to map visible scroll
content back to their own source model."
  (ebox--scroll-get-state region-id))

(defconst ebox--scroll-cache-transient-state-keys
  '(:buffer
    :content-region-id-set
    :region-line-bounds-index
    :region-line-span-index
    :region-line-span-index-deferred
    :rendered-region-line-span-index
    :rendered-region-line-span-index-deferred
    :region-line-span-hints
    :lazy-scroll-prefix-dirty
    :lazy-scroll-window-refresh-required
    :native-reflow-target-prefix-p
    :native-reflow-prefix-reset-p
    :native-reflow-visible-offset
    :native-reflow-visible-lines)
  "Scroll state fields rebuilt when cached rendered output is published.")

(defvar ebox--render-cache-scroll-state-retained-cost-cache nil)

(defun ebox--scroll-cache-state-template (state)
  "Return a markerless shallow template for cached scroll STATE.
Content line conses and the prefix renderer remain shared because that closure
owns the exact continuation cache for the captured viewport context."
  (let ((plist state)
        template)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (unless (memq key ebox--scroll-cache-transient-state-keys)
          (push key template)
          (push value template))))
    (nreverse template)))

(defun ebox--scroll-cache-line-list-retained-cost (lines)
  "Return a cheap retained-byte estimate for cached scroll LINES."
  (let ((total 0))
    (dolist (line lines total)
      (cl-incf total 16)
      (when (stringp line)
        (cl-incf total (+ 64 (string-bytes line)
                            (* 16 (length line))))))))

(defun ebox--scroll-cache-state-template-retained-cost (template)
  "Return retained bytes charged to cached scroll state TEMPLATE."
  (+ (* 16 (length template))
     (ebox--scroll-cache-line-list-retained-cost
      (plist-get template :content-lines))
     (ebox--scroll-cache-line-list-retained-cost
      (plist-get template :rendered-content-lines))
     (if (plist-get template :render-content-prefix) 512 0)
     (if (plist-get template :materialize-content-lines) 256 0)))

(defun ebox--scroll-cache-side-effects-for-region-ids (region-id-set)
  "Return cached scroll actions and their retained cost for REGION-ID-SET."
  (let ((retained-cost 64)
        actions)
    (when (hash-table-p region-id-set)
      (maphash
       (lambda (region-id _)
         (cl-incf retained-cost 48)
         (if-let* ((state (ebox--scroll-get-state region-id)))
             (let ((template (ebox--scroll-cache-state-template state)))
               (cl-incf
                retained-cost
                (or (and (hash-table-p
                          ebox--render-cache-scroll-state-retained-cost-cache)
                         (gethash
                          state
                          ebox--render-cache-scroll-state-retained-cost-cache))
                    (let ((cost
                           (ebox--scroll-cache-state-template-retained-cost
                            template)))
                      (when (hash-table-p
                             ebox--render-cache-scroll-state-retained-cost-cache)
                        (puthash
                         state cost
                         ebox--render-cache-scroll-state-retained-cost-cache))
                      cost)))
               (push (list 'set region-id template) actions))
           (push (list 'clear region-id) actions)))
       region-id-set))
    (list :scroll-actions actions :retained-cost retained-cost)))

(defun ebox--record-render-cache-scroll-region (region-id)
  "Record REGION-ID in the active rendered-node side-effect collector."
  (when (hash-table-p ebox--render-cache-scroll-state-region-ids)
    (puthash region-id t ebox--render-cache-scroll-state-region-ids)))

(defun ebox--scroll-cache-actions-portable-p (actions)
  "Return non-nil when ACTIONS can move from an isolated to a live tree.
Complete scroll templates contain no continuation closures and can therefore
be rebound by node id.  Lazy prefix closures retain their source tree and must
remain transaction-local."
  (cl-every
   (lambda (action)
     (pcase action
       (`(set ,_region-id ,template)
        (and (null (plist-get template :render-content-prefix))
             (null (plist-get template :materialize-content-lines))))
       (`(clear ,_region-id) t)
       (_ nil)))
   actions))

(defun ebox--scroll-cache-live-box (region-id template)
  "Return REGION-ID's live box corresponding to cached TEMPLATE."
  (let* ((template-box (plist-get template :box))
         (node-id (and template-box (ebox--ensure-node-id template-box)))
         (node-table (ebox--buffer-node-table (current-buffer))))
    (or (and node-table node-id (gethash node-id node-table))
        (plist-get (ebox--scroll-get-state region-id) :box)
        (gethash region-id ebox--region-box-table))))

(defun ebox--scroll-cache-actions-replayable-p (actions &optional portable)
  "Return non-nil when cached scroll ACTIONS still match the live runtime."
  (let ((node-table (ebox--buffer-node-table (current-buffer))))
    (cl-every
     (lambda (action)
       (pcase action
         (`(set ,region-id ,template)
         (let* ((box (plist-get template :box))
                 (node-id (and box (ebox--ensure-node-id box)))
                 (live-state (ebox--scroll-get-state region-id))
                 (effective-box
                  (if portable
                      (ebox--scroll-cache-live-box region-id template)
                    box)))
            (and effective-box
                 (equal (or (plist-get template :scroll-offset) 0)
                        (or (ebox-get effective-box :scroll-offset) 0))
                 (or portable
                     (null node-table)
                     (eq box (gethash node-id node-table)))
                 (or (null live-state)
                     (eq effective-box (plist-get live-state :box)))
                 (not (plist-get live-state :lazy-scroll-prefix-dirty))
                 (not (plist-get
                       live-state :lazy-scroll-window-refresh-required)))))
         (`(clear ,_region-id) t)
         (_ nil)))
     actions)))

(defun ebox--replay-scroll-cache-actions (actions &optional portable)
  "Replay cached scroll ACTIONS into the current render runtime."
  (dolist (action actions)
    (pcase action
      (`(set ,region-id ,template)
       (let ((state (copy-sequence template)))
         (when portable
           (plist-put state :box
                      (ebox--scroll-cache-live-box region-id template)))
         (ebox--scroll-set-state region-id state)))
      (`(clear ,region-id)
       (ebox--scroll-clear-state region-id))
      (_
       (error "Invalid cached scroll action: %S" action))))
  t)

(defun ebox--scroll-set-state (region-id state)
  "Set scroll STATE for REGION-ID."
  (when (bound-and-true-p
         ebox--collect-rebuilt-scroll-state-region-ids)
    (cl-pushnew region-id ebox--rebuilt-scroll-state-region-ids
                :test #'equal))
  (when-let* ((content-lines (plist-get state :content-lines)))
    (let ((ebox--defer-scroll-content-index
           (or ebox--defer-scroll-content-index
               (plist-get state :render-content-prefix)
               (plist-get state :materialize-content-lines))))
      (setq state
            (ebox--scroll-state-set-lines
             state content-lines
             (plist-get state :rendered-content-lines)))))
  (puthash region-id state ebox--scroll-global-state)
  (ebox--record-render-cache-scroll-region region-id)
  (ebox--scroll-schedule-idle-prefetch
   region-id ebox--scroll-prefetch-delay-override))

(defun ebox--scroll-clear-state (region-id)
  "Remove scroll state for REGION-ID."
  (let ((had-state (gethash region-id ebox--scroll-global-state)))
    (ebox--scroll-cancel-idle-prefetch region-id)
    (remhash region-id ebox--scroll-global-state)
    ;; A clear of an already-empty slot has no candidate-visible effect and
    ;; must not make an otherwise pure fragment look generation-sensitive.
    (when had-state
      (ebox--record-render-cache-scroll-region region-id))))

(defun ebox--scroll-state-rendered-visible-window (state)
  "Return STATE's current rendered visible slice, including text properties."
  (let* ((content-height (plist-get state :content-height))
         (offset (or (plist-get state :scroll-offset) 0))
         (native-offset (plist-get state :native-reflow-visible-offset))
         (native-lines (plist-get state :native-reflow-visible-lines)))
    (cond
     ((and (integerp content-height)
           (>= content-height 0)
           (equal native-offset offset)
           (= (length native-lines) content-height))
      (list offset native-lines))
     ((and (integerp content-height) (>= content-height 0))
      (when-let* ((lines (plist-get state :rendered-content-lines)))
        (let* ((max-offset (max 0 (- (length lines) content-height)))
               (offset (max 0 (min max-offset offset)))
               (end (min (+ offset content-height) (length lines))))
          (list offset (seq-subseq lines offset end))))))))

(defun ebox--scroll-state-retained-window-ready-p (state)
  "Return non-nil when STATE can publish its cached visible window directly.
The proof is deliberately limited to a top-aligned, chrome-free scroll box;
the cached rendered prefix may remain incomplete as long as it covers the
current visible slice.  Prefix misses continue through the normal renderer."
  (let ((box (plist-get state :box))
        (visible (ebox--scroll-state-rendered-visible-window state)))
    (and box visible
         (= (or (ebox-get box :padding-left-pixel) 0) 0)
         (= (or (ebox-get box :padding-right-pixel) 0) 0)
         (= (or (ebox-get box :padding-top-height) 0) 0)
         (= (or (ebox-get box :padding-bottom-height) 0) 0)
         (= (or (ebox-get box :margin-left-pixel) 0) 0)
         (= (or (ebox-get box :margin-right-pixel) 0) 0)
         (= (or (ebox-get box :margin-top-height) 0) 0)
         (= (or (ebox-get box :margin-bottom-height) 0) 0)
         (= (or (ebox-get box :border-left-pixel) 0) 0)
         (= (or (ebox-get box :border-right-pixel) 0) 0)
         (not (ebox-get box :border-top-p))
         (not (ebox-get box :border-bottom-p))
         (eq (ebox-get box :vertical-align) 'top)
         (null (ebox-get box :surface-properties))
         visible)))

(defun ebox--native-buffer-scroll-root-proof-p
    (buffer region-id &optional render-state)
  "Return non-nil when REGION-ID can use native BUFFER line scrolling.
This is intentionally stricter than the retained-window proof: native
scrolling requires one root owner, a live displaying window, and no sibling or
nested scroll state.  The full content is materialized separately before the
proof becomes usable for an input event."
  (let* ((state (or render-state (ebox--buffer-render-state buffer)))
         (root (and state (plist-get state :root-node)))
         (root-id (and root (plist-get root :node-id)))
         (region-ids (and state (plist-get state :scroll-region-ids)))
         (owner-id (and (buffer-live-p buffer)
                        (ebox--buffer-region-render-owner-node-id
                         buffer region-id)))
         (scroll-state
          (and state
               (gethash region-id (plist-get state :scroll-state-table))))
         (box (and scroll-state (plist-get scroll-state :box)))
         (window (and (not noninteractive)
                      (get-buffer-window buffer t))))
    (and ebox-native-buffer-scroll
         (buffer-live-p buffer)
         (window-live-p window)
         root root-id scroll-state box
         (memq region-id region-ids)
         (= root-id owner-id)
         ;; A native full-content buffer is a valid presentation only while
         ;; the formatting context is independent of the viewport.  If the
         ;; root or any descendant reads viewport width/height, a later
         ;; resize must be able to reflow from the retained window state; do
         ;; not let idle materialization turn that resize into a full-content
         ;; publication.
         (ebox--native-buffer-scroll-viewport-independent-p state root)
         ;; Native scrolling presents the complete root surface in the
         ;; ordinary Emacs window.  Any chrome or surface decoration needs the
         ;; retained Ebox projection so its geometry remains transactional.
         (= (or (ebox-get box :padding-left-pixel) 0) 0)
         (= (or (ebox-get box :padding-right-pixel) 0) 0)
         (= (or (ebox-get box :padding-top-height) 0) 0)
         (= (or (ebox-get box :padding-bottom-height) 0) 0)
         (= (or (ebox-get box :margin-left-pixel) 0) 0)
         (= (or (ebox-get box :margin-right-pixel) 0) 0)
         (= (or (ebox-get box :margin-top-height) 0) 0)
         (= (or (ebox-get box :margin-bottom-height) 0) 0)
         (= (or (ebox-get box :border-left-pixel) 0) 0)
         (= (or (ebox-get box :border-right-pixel) 0) 0)
         (not (ebox-get box :border-top-p))
         (not (ebox-get box :border-bottom-p))
         (eq (ebox-get box :vertical-align) 'top)
         (null (ebox-get box :surface-properties)))))

(defun ebox--native-buffer-scroll-viewport-independent-p (state root)
  "Return non-nil when ROOT has no viewport-dependent descendant.
Use the published dependency axes when available so native scroll hit-tests
remain O(1); the subtree predicates are only a conservative initialization
fallback for legacy states without a completed axis index."
  (let ((axes (plist-get state :viewport-dependent-node-id-axes)))
    (if (plist-get state :viewport-dependent-node-ids-ready)
        (and (null (car axes))
             (null (cdr axes)))
      (and (not (ebox--viewport-dependent-subtree-p root))
           (not (ebox--viewport-height-dependent-subtree-p root))))))

(defun ebox--native-buffer-scroll-root-region-id (buffer state)
  "Return the outer root scroll owner id for BUFFER STATE, if eligible."
  (let* ((root (plist-get state :root-node))
         (root-id (and root (plist-get root :node-id))))
    (cl-loop for region-id in (plist-get state :scroll-region-ids)
             when (and root-id
                       (= root-id
                          (ebox--buffer-region-render-owner-node-id
                           buffer region-id)))
             return region-id)))

(defun ebox--native-buffer-scroll-position (buffer offset)
  "Return BUFFER position at logical line OFFSET from its root start."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (max 0 offset))
      (point))))

(defun ebox--native-buffer-scroll-by (buffer region-id delta)
  "Scroll eligible root REGION-ID by DELTA using the native window.
Return the signed consumed distance, zero at a boundary, or the sentinel
`native-unavailable' when the strict proof does not hold."
  (let* ((render-state (ebox--buffer-render-state buffer))
         (state (and render-state
                     (gethash region-id
                              (plist-get render-state :scroll-state-table)))))
    (if (not (and state
                  (plist-get render-state :native-buffer-scroll-p)
                  (plist-get state :content-lines-complete-p)
                  (ebox--native-buffer-scroll-root-proof-p
                   buffer region-id render-state)))
        'native-unavailable
      (let* ((lines (plist-get state :rendered-content-lines))
             (height (max 0 (or (plist-get state :content-height) 0)))
             (old-offset (or (plist-get state :scroll-offset) 0))
             (maximum (max 0 (- (length lines) height)))
             (new-offset (max 0 (min maximum (+ old-offset delta)))))
        (if (= new-offset old-offset)
            0
          (let* ((window (get-buffer-window buffer t))
                 (old-window-start (window-start window))
                 (old-window-point (window-point window))
                 (old-box-offset (ebox-get (plist-get state :box)
                                           :scroll-offset))
                 (old-report (plist-get render-state :last-update-report))
                 (new-position
                  (ebox--native-buffer-scroll-position buffer new-offset))
                 (report
                  (or (plist-get render-state :native-scroll-report)
                      (ebox--update-report
                       region-id 'native-buffer-scroll
                       :constraint-source 'scroll
                       :constraint-owner-id region-id
                       :constraint-owner-type 'box
                       :dirty-kinds '(geometry)
                       :dirty-count 1 :patch-count 1
                       :patch-ops '(native-window-scroll)
                       :owner-ids (list region-id)
                       :owner-id region-id
                       :projection-kind 'native-buffer-scroll
                       :runtime-published t
                       :scroll-patch-fast-p t
                       :tp-full-root nil :tp-scope-fallback nil
                       :tp-operation-count 0 :tp-text-operations 0
                       :tp-property-operations 0 :created-objects 0
                       :removed-objects 0 :moved-objects 0
                       :reconciled-objects 0))))
            ;; Native root scrolling is a presentation-only state transition:
            ;; it touches no signal, binding, candidate, or TP surface.  Keep
            ;; the same atomic rollback contract locally, but do not allocate
            ;; a full TP transaction (hash tables, journals, and participant
            ;; records) for every ordinary document line.
            (unless (plist-get render-state :native-scroll-report)
              (plist-put render-state :native-scroll-report report))
            (condition-case condition
                (progn
                  (set-window-start window new-position t)
                  (set-window-point window new-position)
                  (ebox-put (plist-get state :box)
                            :scroll-offset new-offset)
                  (plist-put state :scroll-offset new-offset)
                  (puthash region-id state ebox--scroll-global-state)
                  (plist-put render-state :last-update-report report)
                  (- new-offset old-offset))
              ((error quit)
               (condition-case nil
                   (progn
                     (set-window-start window old-window-start t)
                     (set-window-point window old-window-point)
                     (ebox-put (plist-get state :box)
                               :scroll-offset old-box-offset)
                     (plist-put state :scroll-offset old-offset)
                     (puthash region-id state ebox--scroll-global-state)
                     (plist-put render-state :last-update-report old-report))
                 ((error quit) nil))
               (signal (car condition) (cdr condition))))))))))

(defun ebox--native-buffer-scroll-at-position (buffer position delta)
  "Try the native root scroll owner at BUFFER POSITION by DELTA.
Return a signed consumed distance, zero at a boundary, or
`native-unavailable' / `native-not-applicable'.  The fast path only admits a
single root owner whose text properties prove that POSITION is not inside a
nested scroll owner; all other positions remain on the semantic intent
coordinator."
  (let* ((render-state (ebox--buffer-render-state buffer))
         (root-region-id
          (and render-state
               (ebox--native-buffer-scroll-root-region-id
                buffer render-state))))
    (if (not (and root-region-id
                  (integer-or-marker-p position)))
        'native-not-applicable
      (with-current-buffer buffer
        (let* ((position
                (min (max (if (markerp position)
                              (marker-position position)
                            position)
                          (point-min))
                     (1- (point-max))))
               (content-region-id
                (get-text-property position 'ebox-content))
               (owners
                (get-text-property position 'ebox-content-owners)))
          (if (and (equal content-region-id root-region-id)
                   (or (null owners)
                       (and (null (cdr owners))
                            (equal (car owners) root-region-id))))
              (ebox--native-buffer-scroll-by
               buffer root-region-id delta)
            'native-not-applicable))))))

(defun ebox--native-buffer-scroll-at-point (delta)
  "Try native root scrolling for the current buffer's point by DELTA."
  (ebox--native-buffer-scroll-at-position
   (current-buffer) (point) delta))

(defun ebox--native-buffer-scroll-at-event (event delta)
  "Try native root scrolling at EVENT's window position by DELTA."
  (when-let* ((start (ignore-errors (event-start event)))
              (window (posn-window start))
              ((window-live-p window))
              (buffer (window-buffer window))
              (position (posn-point start)))
    (ebox--native-buffer-scroll-at-position buffer position delta)))

(defun ebox--scroll-box-contains-grid-p (box)
  "Return non-nil when BOX's retained scroll source contains a Grid node."
  (catch 'found
    (cl-labels ((visit (node)
                  (when (and (listp node) (not (stringp node)))
                    (when (eq (plist-get node :ebox-type) 'grid)
                      (throw 'found t))
                    (dolist (child (ebox-tree--children-raw node))
                      (visit child)))))
      (visit box)
      nil)))

(defun ebox--scroll-rendered-visible-windows-equal-p (left right)
  "Return non-nil when LEFT and RIGHT have identical text and properties."
  (and left right
       (= (car left) (car right))
       (= (length (cadr left)) (length (cadr right)))
       (cl-every #'equal-including-properties (cadr left) (cadr right))))

(defun ebox--scroll-state-set-visible-refresh-requirement
    (state old-visible old-refresh-required)
  "Return STATE with an exact visible-window refresh requirement.
OLD-VISIBLE is the rendered window before rebuilding cached lines.  Preserve an
existing OLD-REFRESH-REQUIRED request, otherwise require a refresh only when
the currently displayed rendered slice actually changed."
  (let ((new-visible (ebox--scroll-state-rendered-visible-window state)))
    (if (or old-refresh-required
            (not (ebox--scroll-rendered-visible-windows-equal-p
                  old-visible new-visible)))
        (plist-put state :lazy-scroll-window-refresh-required t)
      (ebox--plist-remove state :lazy-scroll-window-refresh-required))))

(defun ebox--scroll-state-materialize-lines (region-id state)
  "Return STATE after materializing lazy scroll content for REGION-ID."
  (if-let* ((materialize (plist-get state :materialize-content-lines)))
      (let* ((old-visible
              (ebox--scroll-state-rendered-visible-window state))
             (old-refresh-required
              (plist-get state :lazy-scroll-window-refresh-required))
             (buffer (ebox--scroll-state-buffer state))
             (materialized
              (if (and buffer (ebox--buffer-render-state buffer))
                  (ebox--with-buffer-render-context buffer
                    (ebox--with-validated-display-cache
                      (funcall materialize state region-id)))
                (ebox--with-validated-display-cache
                  (funcall materialize state region-id))))
             (content-lines (plist-get materialized :content-lines))
             (rendered-lines (plist-get materialized :rendered-content-lines)))
        (if (not content-lines)
            state
          (let ((ebox--defer-scroll-content-index t))
            (setq state
                  (ebox--scroll-state-set-lines
                   state content-lines rendered-lines)))
          (setq state (plist-put state :content-height
                                 (plist-get materialized :content-height)))
          (setq state (plist-put state :box
                                 (or (plist-get materialized :box)
                                     (plist-get state :box))))
          (setq state (plist-put state :content-lines-complete-p t))
          (setq state (ebox--plist-remove state :materialize-content-lines))
          (setq state (ebox--plist-remove state
                                          :native-reflow-materialize-p))
          (dolist (key '(:native-reflow-target-prefix-p
                         :native-reflow-prefix-reset-p
                         :native-reflow-visible-offset
                         :native-reflow-visible-lines))
            (setq state (ebox--plist-remove state key)))
          (setq state (ebox--plist-remove state :render-content-prefix))
          (setq state (ebox--plist-remove state :lazy-scroll-prefix-dirty))
          (setq state
                (ebox--scroll-state-set-visible-refresh-requirement
                 state old-visible old-refresh-required))
          (ebox--scroll-cancel-idle-prefetch region-id)
          (puthash region-id state ebox--scroll-global-state)
          state))
    state))

(defun ebox--scroll-state-ensure-prefix-lines
    (region-id state required-lines &optional exact-prefix)
  "Return STATE after rendering lazy scroll content through REQUIRED-LINES.
This preserves the lazy scroll contract: scroll input should extend only the
prefix needed by the target visible window, not materialize the whole source.
When EXACT-PREFIX is non-nil, do not render the extra completion sentinel;
interactive callers can publish an already-cached visible prefix without
probing source completion, while idle prefetch retains the sentinel."
  (let* ((required-lines (max 0 (or required-lines 0)))
         (old-visible
          (ebox--scroll-state-rendered-visible-window state))
         (old-refresh-required
          (plist-get state :lazy-scroll-window-refresh-required))
         (native-target-p
          (plist-get state :native-reflow-target-prefix-p))
         (native-reset-p
          (plist-get state :native-reflow-prefix-reset-p))
         (content-lines (plist-get state :content-lines))
         (current-lines (length content-lines))
         (prefix-dirty
          (or (plist-get state :lazy-scroll-prefix-dirty)
              native-target-p))
         (render-prefix (plist-get state :render-content-prefix))
         (extension-lines (max 0 (- required-lines current-lines)))
         (interactive-step
          (max 1
               (or ebox-scroll-step 1)
               (or ebox-wheel-smooth-scroll-lines-per-tick 1)))
         (lookahead-lines
          (if (<= extension-lines
                  interactive-step)
              (max 0 ebox-scroll-lazy-prefix-lookahead-lines)
            0))
         (sentinel-lines
          (if (and (> extension-lines 0) (not exact-prefix)) 1 0))
         (render-target-lines
          (+ required-lines sentinel-lines lookahead-lines)))
    (if (or (and (not prefix-dirty)
                 (<= required-lines current-lines))
            (plist-get state :content-lines-complete-p)
            (not render-prefix))
        state
      (let* ((buffer (ebox--scroll-state-buffer state))
             (render-state
              (if native-reset-p
                  (plist-put (copy-sequence state)
                             :lazy-scroll-prefix-dirty t)
                state))
             (rendered
              (if (and buffer (ebox--buffer-render-state buffer))
                  (ebox--with-buffer-render-context buffer
                    (ebox--with-validated-display-cache
                      (funcall render-prefix render-state region-id
                               render-target-lines)))
                (ebox--with-validated-display-cache
                  (funcall render-prefix render-state region-id
                           render-target-lines))))
             (prefix-lines (plist-get rendered :content-lines))
             (rendered-lines (plist-get rendered :rendered-content-lines)))
        (if (not prefix-lines)
            state
          (let ((ebox--defer-scroll-content-index t))
            (setq state
                  (ebox--scroll-state-set-lines
                   state prefix-lines rendered-lines)))
          (setq state
                (plist-put state :content-height
                           (or (plist-get rendered :content-height)
                               (plist-get state :content-height))))
          (setq state (plist-put state :box
                                 (or (plist-get rendered :box)
                                     (plist-get state :box))))
          (setq state
                (plist-put state :content-lines-complete-p
                           (plist-get rendered :complete)))
          (setq state
                (ebox--plist-remove state :native-reflow-prefix-reset-p))
          (setq state (ebox--plist-remove
                       state :lazy-scroll-prefix-dirty))
          (when (and native-target-p
                     (>= (length prefix-lines)
                         (+ (or (plist-get state :scroll-offset) 0)
                            (or (plist-get state :content-height) 0))))
            (setq state
                  (ebox--plist-remove
                   state :native-reflow-target-prefix-p))
            (setq state
                  (ebox--plist-remove
                   state :native-reflow-visible-offset))
            (setq state
                  (ebox--plist-remove
                   state :native-reflow-visible-lines)))
          ;; A clean extension normally appends only offscreen lines.  Avoid a
          ;; needless stop-and-refresh when the exact visible rendered slice is
          ;; unchanged, but retain the atomic refresh gate when rebuilt text or
          ;; redisplay properties differ.
          (setq state
                (ebox--scroll-state-set-visible-refresh-requirement
                 state old-visible old-refresh-required))
          (when (plist-get rendered :complete)
            (setq state (ebox--plist-remove
                         state :materialize-content-lines))
            (setq state (ebox--plist-remove
                         state :render-content-prefix))
            (ebox--scroll-cancel-idle-prefetch region-id))
          (puthash region-id state ebox--scroll-global-state)
          state)))))

(defun ebox--scroll-state-owned-by-buffer-p (buffer state)
  "Return non-nil when scroll STATE belongs to BUFFER's runtime tree.
An explicit buffer association is authoritative.  A render-only pass can
temporarily replace a live state with an ownerless state for the exact same
runtime box, so accept that state only when BUFFER indexes the identical box
object.  Unrelated ownerless and foreign-buffer states remain isolated."
  (let ((state-buffer (ebox--scroll-state-buffer state)))
    (or (eq state-buffer buffer)
        (and (null state-buffer)
             (when-let* ((box (plist-get state :box))
                         (box-id (ebox--ensure-node-id box)))
               (eq (ebox--buffer-runtime-node buffer box-id) box))))))

(defun ebox--scroll-state-covers-node-p (buffer state node)
  "Return non-nil when lazy scroll STATE owns NODE in BUFFER."
  (and (ebox--scroll-state-owned-by-buffer-p buffer state)
       (when-let* ((box (plist-get state :box))
                   (box-id (ebox--ensure-node-id box))
                   (node-id (plist-get node :node-id)))
         (or (equal box-id node-id)
             (ebox--runtime-ancestor-id-p buffer box-id node-id)))))

(defun ebox--scroll-state-region-ids-containing-node-ids
    (buffer node-ids)
  "Return BUFFER scroll region ids containing any runtime NODE-IDS."
  (let ((buffer-region-ids
         (plist-get (ebox--buffer-render-state buffer) :scroll-region-ids))
        region-ids)
    (dolist (node-id node-ids)
      (when-let* ((node (ebox--buffer-runtime-node buffer node-id)))
        (dolist (region-id buffer-region-ids)
          (when-let* ((state (ebox--scroll-get-state region-id)))
            (when (ebox--scroll-state-covers-node-p buffer state node)
              (cl-pushnew region-id region-ids :test #'equal))))))
    (nreverse region-ids)))

(defun ebox--region-ids-visible-in-buffer-p (buffer region-ids)
  "Return non-nil when REGION-IDS currently have visible spans in BUFFER."
  (and buffer
       region-ids
       (buffer-live-p buffer)
       (cl-some (lambda (region-id)
                  (ebox-surface-region-mounts buffer region-id))
                region-ids)))

(defun ebox--string-region-role-ids-at (string pos)
  "Return ebox role/id pairs at POS in STRING."
  (let (role-ids)
    (dolist (entry ebox-region-types)
      (when-let* ((region-id (get-text-property pos (cdr entry) string)))
        (push (cons (car entry) region-id) role-ids)))
    role-ids))

(defun ebox--string-region-ids-at (string pos)
  "Return all ebox region ids present at POS in STRING."
  (let (ids)
    (dolist (region-id (get-text-property pos 'ebox-content-owners string))
      (cl-pushnew region-id ids :test #'equal))
    (dolist (entry ebox-region-types)
      (when-let* ((region-id (get-text-property pos (cdr entry) string)))
        (cl-pushnew region-id ids :test #'equal)))
    ids))

(defun ebox--string-next-region-property-change (string pos limit)
  "Return next ebox region property change in STRING after POS, capped at LIMIT."
  (let ((next limit))
    (dolist (entry ebox-region-types)
      (let ((change (next-single-property-change
                     pos (cdr entry) string limit)))
        (when (and change (< change next))
          (setq next change))))
    next))

(defun ebox--string-region-role-ids-compatible-p (role-ids region-set)
  "Return non-nil when ROLE-IDS do not cross foreign direct content owners."
  (cl-every (lambda (role-id)
              (or (not (eq (car role-id) 'content))
                  (gethash (cdr role-id) region-set)))
            role-ids))

(defun ebox--scroll-line-region-span (line region-set)
  "Return LINE span owned by REGION-SET, or nil when absent/incompatible."
  (let ((pos 0)
        (limit (length line))
        span-start span-end patchable seen)
    (setq patchable t)
    (while (and patchable (< pos limit))
      (let* ((next (ebox--string-next-region-property-change line pos limit))
             (ids (ebox--string-region-ids-at line pos)))
        (when (cl-some (lambda (region-id) (gethash region-id region-set))
                       ids)
          (setq seen t)
          (unless span-start
            (setq span-start pos))
          (setq span-end next)
          (unless (ebox--string-region-role-ids-compatible-p
                   (ebox--string-region-role-ids-at line pos)
                   region-set)
            (setq patchable nil)))
        (setq pos (max next (1+ pos)))))
    (and seen patchable span-start span-end (cons span-start span-end))))

(defun ebox--scroll-line-region-present-p (line region-ids)
  "Return non-nil when LINE has any direct role for REGION-IDS."
  (let ((limit (length line)))
    (and (> limit 0)
         (cl-some
          (lambda (region-id)
            (cl-some
             (lambda (entry)
               (text-property-any 0 limit (cdr entry) region-id line))
             ebox-region-types))
          region-ids))))

(defun ebox--scroll-state-region-line-spans (lines region-ids)
  "Return cached line spans in LINES owned by REGION-IDS."
  (let ((region-set (ebox--region-id-set region-ids))
        spans)
    (cl-loop for line in lines
             for idx from 0
             do (when (ebox--scroll-line-region-present-p line region-ids)
                  (when-let* ((span (ebox--scroll-line-region-span
                                    line region-set)))
                    (push (cons idx span) spans))))
    (nreverse spans)))

(defun ebox--scroll-line-region-ids (line)
  "Return all ebox region ids present in LINE."
  (let ((pos 0)
        (limit (length line))
        ids)
    (while (< pos limit)
      (dolist (region-id (ebox--string-region-ids-at line pos))
        (cl-pushnew region-id ids :test #'equal))
      (setq pos (max (ebox--string-next-region-property-change line pos limit)
                     (1+ pos))))
    (nreverse ids)))

(defun ebox--scroll-line-content-region-ids (line)
  "Return LINE's content-topology region ids through the cheap owner fields.
Decoration-only legacy lines fall back to the complete role scanner."
  (let ((pos 0)
        (limit (length line))
        ids
        topology-seen)
    (while (< pos limit)
      (dolist (region-id (get-text-property pos 'ebox-content-owners line))
        (setq topology-seen t)
        (cl-pushnew region-id ids :test #'equal))
      (dolist (property '(ebox-content ebox-content-owner))
        (when-let* ((region-id (get-text-property pos property line)))
          (setq topology-seen t)
          (cl-pushnew region-id ids :test #'equal)))
      (setq pos
            (max
             (1+ pos)
             (min
              (or (next-single-property-change
                   pos 'ebox-content-owners line limit)
                  limit)
              (or (next-single-property-change
                   pos 'ebox-content line limit)
                  limit)
              (or (next-single-property-change
                   pos 'ebox-content-owner line limit)
                  limit)))))
    (if topology-seen
        (nreverse ids)
      (ebox--scroll-line-region-ids line))))

(defun ebox--scroll-line-direct-content-region-ids (line)
  "Return direct `ebox-content' region ids in LINE.
Ancestor content-owner ids are intentionally excluded: adapter containers such
as flex wrappers do not own a concrete line span, and selector planning already
uses their rendered descendants."
  (let ((pos 0)
        (limit (length line))
        ids)
    (while (< pos limit)
      (when-let* ((region-id (get-text-property pos 'ebox-content line)))
        (cl-pushnew region-id ids :test #'equal))
      (setq pos
            (max (1+ pos)
                 (or (next-single-property-change
                      pos 'ebox-content line limit)
                     limit))))
    (nreverse ids)))

(defun ebox--scroll-line-bounds-index-add (index line-index line)
  "Add LINE at LINE-INDEX to lightweight region bounds INDEX."
  (dolist (region-id (ebox--scroll-line-direct-content-region-ids line))
    (if-let* ((bounds (gethash region-id index)))
        (setcdr bounds line-index)
      (puthash region-id (cons line-index line-index) index)))
  index)

(defun ebox--scroll-build-region-line-bounds-index (lines)
  "Return a lightweight region id to inclusive line bounds index for LINES."
  (let ((index (make-hash-table :test 'equal)))
    (cl-loop for line in lines
             for line-index from 0
             do (ebox--scroll-line-bounds-index-add
                 index line-index line))
    index))

(defun ebox--scroll-lines-prefix-equal-p (prefix lines)
  "Return non-nil when PREFIX is an exact property-preserving prefix of LINES."
  (and (<= (length prefix) (length lines))
       (cl-loop for old-line in prefix
                for new-line in lines
                always (equal-including-properties old-line new-line))))

(defun ebox--scroll-update-region-line-bounds-index
    (state old-lines new-lines)
  "Return STATE's lightweight bounds index updated for NEW-LINES."
  (let ((index (plist-get state :region-line-bounds-index)))
    (if (and index
             old-lines
             (ebox--scroll-lines-prefix-equal-p old-lines new-lines))
        (progn
          (cl-loop for line in (nthcdr (length old-lines) new-lines)
                   for line-index from (length old-lines)
                   do (ebox--scroll-line-bounds-index-add
                       index line-index line))
          index)
      (ebox--scroll-build-region-line-bounds-index new-lines))))

(defun ebox--scroll-build-region-line-span-index (lines)
  "Return an index mapping region ids to cached line spans in LINES."
  (let ((index (make-hash-table :test 'equal)))
    (cl-loop for line in lines
             for line-index from 0
             do
             (dolist (region-id (ebox--scroll-line-region-ids line))
               (when-let* ((span (ebox--scroll-line-region-span
                                 line (ebox--region-id-set
                                       (list region-id)))))
                 (puthash region-id
                          (cons (cons line-index span)
                                (gethash region-id index))
                          index))))
    (maphash (lambda (region-id spans)
               (puthash region-id (nreverse spans) index))
             index)
    index))

(defun ebox--scroll-build-content-region-id-set (lines)
  "Return a set of every content-topology region id represented in LINES.
Normal Ebox lines expose each box through `ebox-content',
`ebox-content-owner', or `ebox-content-owners'.  Decoration-only legacy lines
fall back to the complete role scanner."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (line lines)
      (dolist (region-id (ebox--scroll-line-content-region-ids line))
        (puthash region-id t set)))
    set))

(defun ebox--scroll-state-ensure-content-region-id-set (state)
  "Return STATE's cached content region-id membership set."
  (or (plist-get state :content-region-id-set)
      (let ((set (ebox--scroll-build-content-region-id-set
                  (plist-get state :content-lines))))
        (plist-put state :content-region-id-set set)
        set)))

(defun ebox--scroll-region-id-set-intersects-p (set region-ids)
  "Return non-nil when SET contains at least one of REGION-IDS."
  (catch 'present
    (dolist (region-id region-ids)
      (when (gethash region-id set)
        (throw 'present t)))
    nil))

(defun ebox--scroll-index-line-spans (index region-ids)
  "Return merged line spans for REGION-IDS from INDEX."
  (let ((by-line (make-hash-table :test 'eql))
        spans)
    (dolist (region-id region-ids)
      (dolist (entry (gethash region-id index))
        (let* ((line-index (car entry))
               (span (cdr entry))
               (existing (gethash line-index by-line)))
          (if existing
              (progn
                (setcar existing (min (car existing) (car span)))
                (setcdr existing (max (cdr existing) (cdr span))))
            (puthash line-index (copy-tree entry) by-line)))))
    (maphash (lambda (_line-index entry)
               (push entry spans))
             by-line)
    (sort spans (lambda (left right) (< (car left) (car right))))))

(defun ebox--scroll-index-add-line (index line-index line)
  "Add LINE at LINE-INDEX to INDEX."
  (dolist (region-id (ebox--scroll-line-region-ids line))
    (when-let* ((span (ebox--scroll-line-region-span
                      line (ebox--region-id-set (list region-id)))))
      (puthash region-id
               (cons (cons line-index span)
                     (gethash region-id index))
               index))))

(defun ebox--scroll-sort-line-index (index)
  "Sort INDEX entries by line number."
  (maphash
   (lambda (region-id entries)
     (puthash region-id
              (sort entries
                    (lambda (left right)
                      (< (car left) (car right))))
              index))
   index)
  index)

(defun ebox--scroll-state-set-lines
    (state content-lines &optional rendered-lines)
  "Return STATE with CONTENT-LINES and derived span indexes installed."
  (let ((old-lines (plist-get state :content-lines)))
    (setq state
          (plist-put
           state :region-line-bounds-index
           (ebox--scroll-update-region-line-bounds-index
            state old-lines content-lines))))
  (setq state (plist-put state :content-lines content-lines))
  (setq state (ebox--plist-remove state :content-region-id-set))
  (setq state (ebox--plist-remove state :region-line-span-hints))
  (if ebox--defer-scroll-content-index
      (progn
        (setq state (plist-put state :region-line-span-index nil))
        (setq state (plist-put state :region-line-span-index-deferred t)))
    (setq state
          (plist-put state :region-line-span-index
                     (ebox--scroll-build-region-line-span-index
                      content-lines)))
    (setq state (plist-put state :region-line-span-index-deferred nil)))
  (if rendered-lines
      (progn
        (setq state (plist-put state :rendered-content-lines rendered-lines))
        (if ebox--defer-scroll-content-index
            (progn
              (setq state
                    (plist-put state :rendered-region-line-span-index nil))
              (setq state
                    (plist-put
                     state :rendered-region-line-span-index-deferred t)))
          (setq state
                (plist-put state :rendered-region-line-span-index
                           (ebox--scroll-build-region-line-span-index
                            rendered-lines)))
          (setq state
                (plist-put
                 state :rendered-region-line-span-index-deferred nil))))
    (setq state (ebox--plist-remove state :rendered-content-lines))
    (setq state (ebox--plist-remove state :rendered-region-line-span-index))
    (setq state
          (ebox--plist-remove state
                              :rendered-region-line-span-index-deferred)))
  state)


(defun ebox--scroll-hot-content-line-spans (state region-ids)
  "Return content spans for REGION-IDS without building a deferred full index.
Dynamic updates reuse an already prepared index.  When no ready index exists,
scan for only REGION-IDS; building the all-region index synchronously is much
more expensive than the targeted fallback on a long lazy prefix."
  (if-let* ((index (plist-get state :region-line-span-index)))
      ;; A ready exact index already proves both membership and spans.  Building
      ;; the prefix-wide membership set first adds an O(prefix) tax to visible
      ;; updates after scrolling.
      (ebox--scroll-index-line-spans index region-ids)
    (let ((content-region-id-set
           (ebox--scroll-state-ensure-content-region-id-set state)))
      (when (ebox--scroll-region-id-set-intersects-p
             content-region-id-set region-ids)
        (let ((hints (plist-get state :region-line-span-hints)))
          (if-let* ((hint-spans
                    (and hints
                         (cl-loop for region-id in region-ids
                                  for spans = (gethash region-id hints)
                                  unless spans return nil
                                  append spans))))
              (ebox--scroll-line-spans-at-index-hints
               (plist-get state :content-lines)
               region-ids
               hint-spans)
            (ebox--scroll-state-region-line-spans
             (plist-get state :content-lines) region-ids)))))))

(defun ebox--scroll-line-spans-at-index-hints
    (lines region-ids index-hints)
  "Return REGION-IDS spans in LINES limited to INDEX-HINTS line numbers.
INDEX-HINTS use the same `(LINE-INDEX . SPAN)' shape as the scroll indexes.
Content and rendered scroll lines share line numbering, so a content hit can
bound rendered-line inspection without scanning or indexing the whole prefix."
  (let ((region-set (ebox--region-id-set region-ids))
        (indices (delete-dups (mapcar #'car index-hints)))
        spans)
    (setq indices (sort indices #'<))
    (cl-loop for line in lines
             for line-index from 0
             while indices
             do
             (cond
              ((< line-index (car indices)))
              ((= line-index (car indices))
               (when (ebox--scroll-line-region-present-p line region-ids)
                 (when-let* ((span (ebox--scroll-line-region-span
                                   line region-set)))
                   (push (cons line-index span) spans)))
               (setq indices (cdr indices)))))
    (nreverse spans)))


(defun ebox--cancel-buffer-reflow-cache-prewarm (buffer)
  "Cancel pending predicted reflow-cache warming for BUFFER."
  (when-let* ((timer (gethash buffer ebox--reflow-cache-prewarm-timers)))
    (when (timerp timer)
      (cancel-timer timer)))
  (remhash buffer ebox--reflow-cache-prewarm-timers))

(defun ebox--cancel-buffer-runtime-prewarm (buffer)
  "Cancel and discard pending runtime prewarming for BUFFER."
  (ebox--cancel-buffer-reflow-cache-prewarm buffer)
  (when-let* ((timer (gethash buffer ebox--runtime-prewarm-timers)))
    (when (timerp timer)
      (cancel-timer timer)))
  (remhash buffer ebox--runtime-prewarm-timers)
  (remhash buffer ebox--runtime-prewarm-jobs))

(defun ebox--runtime-prewarm-enabled-p ()
  "Return non-nil when runtime prewarming may run in this Emacs."
  (and ebox-runtime-idle-prewarm
       (or (not noninteractive)
           ebox--runtime-prewarm-allow-noninteractive)))

(defun ebox--reflow-cache-prewarm-enabled-p ()
  "Return non-nil when predicted reflow-cache warming may run."
  (and ebox-runtime-idle-reflow-cache-prewarm
       (or (not noninteractive)
           ebox--runtime-prewarm-allow-noninteractive)))

(defun ebox--reflow-cache-prewarm-auto-maximum-threshold ()
  "Return the memory-aware maximum automatic prewarm allocation threshold."
  (let* ((minimum (max 1 ebox-reflow-cache-prewarm-gc-auto-min-threshold))
         (maximum
          (max minimum ebox-reflow-cache-prewarm-gc-auto-max-threshold))
         (physical-memory (ebox--physical-memory-bytes))
         (memory-limit
          (and physical-memory (floor (/ physical-memory 16.0)))))
    (max minimum (min maximum (or memory-limit maximum)))))

(defun ebox--reflow-cache-prewarm-auto-layout-horizon (seconds)
  "Return the target collection-free layout count for SECONDS."
  (let* ((target (max 1 ebox-reflow-cache-prewarm-gc-auto-target-layouts))
         (budget (max 0.001 ebox-reflow-cache-prewarm-gc-auto-frame-budget)))
    (cond
     ((or (not (numberp seconds)) (>= seconds (* budget 0.65))) target)
     ((>= seconds (* budget 0.30))
      (max 1 (ceiling (/ (* target 2.0) 3.0))))
     (t (max 1 (ceiling (/ target 3.0)))))))

(defun ebox--reflow-cache-prewarm-auto-threshold-for-allocation
    (allocated-bytes seconds)
  "Return an automatic threshold for ALLOCATED-BYTES and layout SECONDS."
  (let* ((minimum (max 1 ebox-reflow-cache-prewarm-gc-auto-min-threshold))
         (maximum (ebox--reflow-cache-prewarm-auto-maximum-threshold))
         (horizon (ebox--reflow-cache-prewarm-auto-layout-horizon seconds))
         (quantum (* 16 1024 1024))
         (raw (* (max 1 allocated-bytes) horizon))
         (rounded (* quantum (ceiling (/ raw (float quantum))))))
    (max
     minimum
     (min maximum rounded))))

(defun ebox--memory-use-count-delta (before after)
  "Return one wrapping `memory-use-counts' delta from BEFORE to AFTER."
  (if (>= after before)
      (- after before)
    (+ (- most-positive-fixnum before) after 1)))

(defun ebox--memory-use-counts-estimated-bytes (before after)
  "Estimate allocation bytes between memory count lists BEFORE and AFTER."
  (let ((deltas
         (cl-mapcar #'ebox--memory-use-count-delta before after)))
    ;; Emacs reports object counts rather than bytes.  These 64-bit object
    ;; sizes deliberately include headers for the allocation-pressure signal;
    ;; the 16 MiB quantization absorbs allocator and platform variation.
    (+ (* (or (nth 0 deltas) 0) 16) ; conses
       (* (or (nth 1 deltas) 0) 16) ; floats
       (* (or (nth 2 deltas) 0) 8)  ; vector cells
       (* (or (nth 3 deltas) 0) 48) ; symbols
       (or (nth 4 deltas) 0)        ; string characters
       (* (or (nth 5 deltas) 0) 40) ; intervals
       (* (or (nth 6 deltas) 0) 32)))) ; string headers

(defun ebox--reflow-cache-prewarm-effective-threshold (state)
  "Return the configured allocation threshold for predicted render STATE."
  (pcase ebox-reflow-cache-prewarm-gc-cons-threshold
    ('auto
     (or (and state (plist-get state :reflow-prewarm-gc-threshold))
         (min (ebox--reflow-cache-prewarm-auto-maximum-threshold)
              (max ebox-reflow-cache-prewarm-gc-auto-min-threshold
                   ebox-reflow-cache-prewarm-gc-auto-initial-threshold))))
    ((pred numberp) ebox-reflow-cache-prewarm-gc-cons-threshold)
    (_ nil)))

(defun ebox--record-reflow-cache-prewarm-cost
    (state elapsed-seconds gc-count threshold allocated-bytes)
  "Record predicted layout cost in STATE after ELAPSED-SECONDS and GC-COUNT.
THRESHOLD is the allocation budget used for the completed prewarm, and
ALLOCATED-BYTES is its estimated allocation pressure."
  (when state
    (plist-put state :reflow-prewarm-last-seconds elapsed-seconds)
    (plist-put state :reflow-prewarm-last-gc-count gc-count)
    (plist-put state :reflow-prewarm-last-gc-threshold threshold)
    (plist-put state :reflow-prewarm-last-allocation-bytes allocated-bytes)
    ;; A GC-contaminated sample measures heap scanning, not layout complexity.
    ;; Keep the previous learned value until one clean prewarm is available.
    (when (= gc-count 0)
      (let* ((previous
              (plist-get state :reflow-prewarm-layout-seconds))
             (smoothed
              (if (numberp previous)
                  (+ (* previous 0.75) (* elapsed-seconds 0.25))
                elapsed-seconds)))
        (plist-put state :reflow-prewarm-layout-seconds smoothed)))
    ;; Allocation counters are monotonic across collection, so every completed
    ;; prewarm can improve the pressure estimate even when its time was noisy.
    (when (and (numberp allocated-bytes) (> allocated-bytes 0))
      (let* ((previous
              (plist-get state :reflow-prewarm-allocation-bytes))
             (smoothed
              (if (numberp previous)
                  (floor (+ (* previous 0.75) (* allocated-bytes 0.25)))
                allocated-bytes)))
        (plist-put state :reflow-prewarm-allocation-bytes smoothed)
        (plist-put
         state :reflow-prewarm-gc-threshold
         (ebox--reflow-cache-prewarm-auto-threshold-for-allocation
          smoothed (plist-get state :reflow-prewarm-layout-seconds)))))))

(defun ebox--call-with-reflow-cache-prewarm-gc
    (state function &rest arguments)
  "Call FUNCTION with ARGUMENTS under idle reflow GC pressure settings.
Automatic collection may run while the predicted render is invisible.  The
surrounding interactive burst settings are restored before the cached result
can be published by a visible resize frame.  Timer errors remain isolated from
ordinary editing; `quit' still propagates so C-g stays responsive."
  (let* ((threshold (ebox--reflow-cache-prewarm-effective-threshold state))
         (percentage ebox-reflow-cache-prewarm-gc-cons-percentage)
         (gc-cons-threshold
          (if (numberp threshold) threshold gc-cons-threshold))
         (gc-cons-percentage
          (if (numberp percentage) percentage gc-cons-percentage))
         ;; Predicted rendering enters `ebox--with-render-gc' internally.  Use
         ;; the same pressure values there instead of raising them back to the
         ;; visible-transaction defaults.
         (ebox-render-gc-cons-threshold threshold)
         (ebox-render-gc-cons-percentage percentage)
         (gcs-before gcs-done)
         (counts-before (memory-use-counts))
         (started (float-time))
         result)
    (setq result
          (condition-case nil
              (apply function arguments)
            (error nil)))
    (when result
      (ebox--record-reflow-cache-prewarm-cost
       state (- (float-time) started) (- gcs-done gcs-before) threshold
       (ebox--memory-use-counts-estimated-bytes
       counts-before (memory-use-counts))))
    result))

(defun ebox--make-reflow-prewarm-scratch (state revision)
  "Create one isolated live-tree copy for render STATE at REVISION."
  (let ((root (plist-get state :root-node)))
    (when root
      (list :source-root root
            :tree (ebox-tree-copy-node-structure root)
            :live-revision revision
            :predicted-region-id nil
            :predicted-width nil
            :predicted-revision nil
            :render-signature-cache (make-hash-table :test 'eq)
            :viewport-dependent-node-ids-cache
            (make-hash-table :test 'eq)
            :viewport-dependent-subtree-cache
            (make-hash-table :test 'eq)
            :viewport-height-dependent-subtree-cache
            (make-hash-table :test 'eq)))))

(defun ebox--live-reflow-prewarm-scratch (state revision)
  "Return STATE's isolated tree at live REVISION, recreating it if needed.
An unconfirmed ordinary-width prediction is never treated as the live tree."
  (let* ((root (plist-get state :root-node))
         (scratch (plist-get state :reflow-prewarm-scratch)))
    (unless (and scratch
                 (eq (plist-get scratch :source-root) root)
                 (equal (plist-get scratch :live-revision) revision)
                 (null (plist-get scratch :predicted-revision)))
      (setq scratch (ebox--make-reflow-prewarm-scratch state revision))
      (plist-put state :reflow-prewarm-scratch scratch))
    scratch))

(defun ebox--discard-reflow-prewarm-scratch (state scratch)
  "Discard SCRATCH when it is still STATE's active isolated tree."
  (when (eq scratch (plist-get state :reflow-prewarm-scratch))
    (plist-put state :reflow-prewarm-scratch nil)))

(defun ebox--render-reflow-prewarm-scratch
    (buffer state revision scratch viewport-width viewport-height)
  "Render SCRATCH offscreen for BUFFER under the supplied viewport context."
  (with-current-buffer buffer
    (let ((ebox-viewport-width viewport-width)
          (ebox-viewport-height viewport-height)
          (ebox--render-runtime-revision revision)
          (ebox--render-cache-table (plist-get state :render-cache))
          (ebox--render-cache-signature-cache
           (plist-get scratch :render-signature-cache))
          (ebox--viewport-dependent-node-ids-cache
           (plist-get scratch :viewport-dependent-node-ids-cache))
          (ebox--viewport-dependent-subtree-cache
           (plist-get scratch :viewport-dependent-subtree-cache))
          (ebox--viewport-height-dependent-subtree-cache
           (plist-get scratch :viewport-height-dependent-subtree-cache))
          (ebox--render-cache-scroll-state-restorable-p nil)
          (ebox--scroll-window-initial-lookahead-lines-override 0)
          (ebox--defer-scroll-content-index t)
          (ebox--scroll-global-state (make-hash-table :test 'equal))
          (ebox--region-box-table (make-hash-table :test 'equal))
          (ebox--scroll-idle-prefetch-timers
           (make-hash-table :test 'equal))
          (ebox-cache-report-buffer nil)
          (ebox--render-region-id nil))
      (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                 (lambda (&rest _) nil)))
        (ebox--with-render-gc
          (ebox--render-with-cache (plist-get scratch :tree) t))))))

(defun ebox--prewarm-buffer-render-cache-at-context
    (buffer state revision source-width viewport-width viewport-height)
  "Warm BUFFER's render cache for a predicted viewport context.
STATE and REVISION identify the runtime that scheduled the work.
SOURCE-WIDTH must remain BUFFER's published viewport width.  VIEWPORT-WIDTH
and VIEWPORT-HEIGHT are used only in an isolated render; the buffer, runtime
tree, scroll state, region table, report, and body-signature cache are not
published or mutated.  Return non-nil when the isolated render ran."
  (when (and (buffer-live-p buffer)
             (eq state (ebox--buffer-render-state buffer))
             (= revision (or (plist-get state :runtime-revision) 0))
             (= source-width (or (plist-get state :viewport-width) -1))
             (numberp viewport-width)
             (> viewport-width 0)
             (plist-get state :root-node))
    (let ((scratch (ebox--live-reflow-prewarm-scratch state revision))
          completed)
      (when scratch
        (unwind-protect
            (progn
              (ebox--render-reflow-prewarm-scratch
               buffer state revision scratch viewport-width viewport-height)
              (setq completed t))
          (unless completed
            (ebox--discard-reflow-prewarm-scratch state scratch))))
      completed)))

(defun ebox--root-region-box (root region-id)
  "Return ROOT's box carrying REGION-ID, including a flex wrapper box."
  (when-let* ((owner (car (ebox--node-path-to-region root region-id))))
    (cond
     ((eq (plist-get owner :ebox-type) 'box) owner)
     ((and (eq (plist-get owner :ebox-type) 'flex)
           (equal (ebox-get (plist-get owner :box) :region-id) region-id))
      (plist-get owner :box)))))

(defun ebox--literal-root-pixel-width (box)
  "Return BOX's demo-compatible literal pixel width, or nil."
  (let ((width (and box (ebox-get box :width))))
    (cond
     ((numberp width) width)
     ((and (consp width) (null (cdr width)) (numberp (car width)))
      (car width)))))

(defun ebox--invalidate-reflow-prewarm-scratch-signatures
    (scratch region-id)
  "Invalidate REGION-ID's path in SCRATCH's recursive signature cache."
  (let* ((root (plist-get scratch :tree))
         (cache (plist-get scratch :render-signature-cache))
         (box (ebox--root-region-box root region-id)))
    (when cache
      (dolist (node (ebox--node-path-to-region root region-id))
        (remhash node cache))
      ;; A flex wrapper's editable box is nested in the owner node and can have
      ;; its own memoized signature.
      (when box
        (remhash box cache)))))

(defun ebox--confirm-reflow-prewarm-scratch
    (buffer region-id revision)
  "Confirm BUFFER's predicted root REGION-ID at the new REVISION.
Return non-nil only when both live and isolated trees reached the exact width;
otherwise discard the isolated tree."
  (when-let* ((state (ebox--buffer-render-state buffer))
              (scratch (plist-get state :reflow-prewarm-scratch)))
    (let* ((root (plist-get state :root-node))
           (scratch-root (plist-get scratch :tree))
           (live-box (ebox--root-region-box root region-id))
           (scratch-box (ebox--root-region-box scratch-root region-id))
           (live-width (ebox--literal-root-pixel-width live-box))
           (scratch-width (ebox--literal-root-pixel-width scratch-box))
           (predicted-width (plist-get scratch :predicted-width))
           (matched
            (and (eq (plist-get scratch :source-root) root)
                 (equal (plist-get scratch :predicted-region-id) region-id)
                 (equal (plist-get scratch :predicted-revision) revision)
                 (numberp predicted-width)
                 (numberp live-width)
                 (numberp scratch-width)
                 (= predicted-width live-width)
                 (= predicted-width scratch-width))))
      (if matched
          (progn
            (plist-put scratch :live-revision revision)
            (plist-put scratch :predicted-region-id nil)
            (plist-put scratch :predicted-width nil)
            (plist-put scratch :predicted-revision nil)
            t)
        (ebox--discard-reflow-prewarm-scratch state scratch)
        nil))))

(defun ebox--prewarm-buffer-render-cache-at-root-width
    (buffer state revision region-id source-width target-width)
  "Warm BUFFER cache for REGION-ID's predicted ordinary root TARGET-WIDTH.
STATE and REVISION guard the published runtime.  SOURCE-WIDTH must still match
the live root constraint.  Rendering mutates only an isolated tree copy and
publishes the prepared rendered-body entry plus its derived root templates."
  (when (and (buffer-live-p buffer)
             (eq state (ebox--buffer-render-state buffer))
             (= revision (or (plist-get state :runtime-revision) 0))
             (numberp source-width)
             (numberp target-width)
             (> target-width 0)
             (let ((box (ebox--root-region-box
                         (plist-get state :root-node) region-id)))
               (and box
                    (= source-width
                       (or (ebox--literal-root-pixel-width box) -1)))))
    (let* ((scratch (ebox--live-reflow-prewarm-scratch state revision))
           (box-copy
            (and scratch
                 (ebox--root-region-box
                  (plist-get scratch :tree) region-id)))
           completed)
      (if (not box-copy)
          (ebox--discard-reflow-prewarm-scratch state scratch)
        (unwind-protect
            (progn
              (ebox--invalidate-reflow-prewarm-scratch-signatures
               scratch region-id)
              (plist-put box-copy :width target-width)
              (ebox--render-reflow-prewarm-scratch
               buffer state revision scratch
               (plist-get state :viewport-width)
               (plist-get state :viewport-height))
              (plist-put scratch :predicted-region-id region-id)
              (plist-put scratch :predicted-width target-width)
              (plist-put scratch :predicted-revision (1+ revision))
              (setq completed t))
          (unless completed
            (ebox--discard-reflow-prewarm-scratch state scratch))))
      completed)))

(defun ebox--run-root-width-cache-prewarm
    (buffer state revision region-id source-width target-width)
  "Run one scheduled ordinary root width cache warm."
  (remhash buffer ebox--reflow-cache-prewarm-timers)
  (prog1
      (ebox--call-with-reflow-cache-prewarm-gc
       state
       #'ebox--prewarm-buffer-render-cache-at-root-width
       buffer state revision region-id source-width target-width)
    (ebox--deferred-render-gc-raise-threshold
     (plist-get state :reflow-prewarm-gc-threshold))))

(defun ebox--schedule-buffer-root-width-cache-prewarm
    (buffer region-id source-width target-width)
  "Schedule isolated cache warming for an ordinary root TARGET-WIDTH."
  (when-let* ((state (and (ebox--reflow-cache-prewarm-enabled-p)
                          (buffer-live-p buffer)
                          (ebox--buffer-render-state buffer)))
              (box (ebox--root-region-box
                    (plist-get state :root-node) region-id)))
    (when (and (numberp source-width) (numberp target-width)
               (> target-width 0) (/= source-width target-width)
               (= source-width
                  (or (ebox--literal-root-pixel-width box) -1)))
      (ebox--cancel-buffer-reflow-cache-prewarm buffer)
      (let ((revision (or (plist-get state :runtime-revision) 0)))
        (puthash
         buffer
         (run-with-idle-timer
          (max 0 ebox-runtime-idle-reflow-cache-prewarm-delay)
          nil #'ebox--run-root-width-cache-prewarm
          buffer state revision region-id source-width target-width)
         ebox--reflow-cache-prewarm-timers)))))

(defun ebox--run-reflow-cache-prewarm
    (buffer state revision source-width viewport-width viewport-height)
  "Run one scheduled predicted reflow-cache warm for BUFFER."
  (remhash buffer ebox--reflow-cache-prewarm-timers)
  (prog1
      (ebox--call-with-reflow-cache-prewarm-gc
       state
       #'ebox--prewarm-buffer-render-cache-at-context
       buffer state revision source-width viewport-width viewport-height)
    (ebox--deferred-render-gc-raise-threshold
     (plist-get state :reflow-prewarm-gc-threshold))))

(defun ebox--schedule-buffer-reflow-cache-prewarm
    (buffer old-viewport-width viewport-width)
  "Predict BUFFER's next steady viewport width and warm its render cache.
OLD-VIEWPORT-WIDTH and VIEWPORT-WIDTH describe the completed reflow.  One job
is scheduled for the next width at the same nonzero delta; invalid nonpositive
predictions are skipped."
  (ebox--cancel-buffer-reflow-cache-prewarm buffer)
  (when-let* ((state (and (ebox--reflow-cache-prewarm-enabled-p)
                         (buffer-live-p buffer)
                         (ebox--buffer-render-state buffer))))
    (let* ((delta (and (numberp old-viewport-width)
                       (numberp viewport-width)
                       (- viewport-width old-viewport-width)))
           (target-width (and delta (+ viewport-width delta))))
      (plist-put state :last-viewport-width-delta
                 (and delta (/= delta 0) delta))
      (when (and delta
                 (/= delta 0)
                 (numberp target-width)
                 (> target-width 0))
        (let ((revision (or (plist-get state :runtime-revision) 0))
              (viewport-height (plist-get state :viewport-height)))
          (puthash
           buffer
           (run-with-idle-timer
            (max 0 ebox-runtime-idle-reflow-cache-prewarm-delay)
            nil #'ebox--run-reflow-cache-prewarm
            buffer state revision viewport-width target-width viewport-height)
           ebox--reflow-cache-prewarm-timers))))))

(defun ebox--runtime-prewarm-new-job
    (buffer state &optional retained-only-p)
  "Return a new runtime prewarm job for BUFFER's render STATE.
RETAINED-ONLY-P is true for ordinary update/resize follow-up work; those
transactions only warm retained indexes and must not publish a second native
scroll surface."
  (let* ((native-prewarm-p (and (not retained-only-p)
                                ebox-native-buffer-scroll))
         (native-scroll-region-id
          (and native-prewarm-p
               ebox-native-buffer-scroll
               (not (plist-get state :native-buffer-scroll-p))
               (ebox--native-buffer-scroll-root-region-id buffer state)))
         ;; Once a live window exists, native root scrolling has a stronger
         ;; latency contract than the general shared-index prewarm: it needs
         ;; only one complete content materialization and one publication.
         ;; Start that job directly instead of spending several idle slices
         ;; walking snapshots and line indexes first.  Off-window buffers keep
         ;; the ordinary snapshot job and are re-armed by
         ;; `ebox--window-buffer-change' when they become visible.
         (native-ready-p
          (and native-scroll-region-id
               (not noninteractive)
               (ebox--native-buffer-scroll-root-proof-p
                buffer native-scroll-region-id state))))
    (list :render-state state
          :runtime-revision (or (plist-get state :runtime-revision) 0)
          :phase (if native-ready-p 'native-scroll 'snapshots)
          :snapshot-stack
          (unless native-ready-p
            (when-let* ((root (plist-get state :root-node)))
              (list (vector root :uninitialized t t))))
          :node-region-ids-cache (make-hash-table :test 'eq)
          :viewport-width-ids-rev nil
          :viewport-height-ids-rev nil
          :scroll-region-ids (plist-get state :scroll-region-ids)
          :native-scroll-region-id native-scroll-region-id
          :native-prewarm-allowed-p native-prewarm-p
          :scroll-sources nil
          :scroll-task nil)))

(defun ebox--runtime-prewarm-schedule-timer (buffer &optional delay)
  "Schedule BUFFER's next runtime prewarm slice after DELAY."
  (when (and (buffer-live-p buffer)
             (gethash buffer ebox--runtime-prewarm-jobs))
    (when-let* ((old (gethash buffer ebox--runtime-prewarm-timers)))
      (when (timerp old)
        (cancel-timer old)))
    (puthash buffer
             (run-with-idle-timer
              (max 0 (or delay ebox-runtime-idle-prewarm-delay))
              nil #'ebox--runtime-prewarm-timer buffer)
             ebox--runtime-prewarm-timers)))

(defun ebox--schedule-buffer-runtime-prewarm
    (buffer &optional delay retained-only-p)
  "Schedule shared runtime prewarming for BUFFER.
RETAINED-ONLY-P is deliberately true after ordinary commits and resizes; the
initial mount and visible-window handoff leave it nil."
  (ebox--cancel-buffer-runtime-prewarm buffer)
  (when-let* ((state (and (ebox--runtime-prewarm-enabled-p)
                         (buffer-live-p buffer)
                         (ebox--buffer-render-state buffer))))
    (puthash buffer (ebox--runtime-prewarm-new-job
                     buffer state retained-only-p)
             ebox--runtime-prewarm-jobs)
    (ebox--runtime-prewarm-schedule-timer buffer delay)))

(defun ebox--window-buffer-change (window)
  "Re-arm visible BUFFER's native-scroll prewarm after WINDOW changes.

`ebox-render-to-buffer' may be called before its result is displayed.  In
that case the initial idle job quite correctly avoids native window scrolling
because no live window exists, but the old job used to finish permanently
before the caller installed the buffer in a window.  Re-arm only this
buffer's shared prewarm when a later window attachment exposes a root
candidate; the strict proof is rechecked when the new job starts, while
unrelated buffers and already-native runtimes stay inert."
  (when (and (not noninteractive)
             (window-live-p window))
    (let ((buffer (window-buffer window)))
      (when (and (buffer-live-p buffer)
                 (ebox--buffer-render-state buffer)
                 ebox-native-buffer-scroll)
        (let* ((state (ebox--buffer-render-state buffer))
               (region-id
                (ebox--native-buffer-scroll-root-region-id buffer state)))
          (when (and region-id
                     (not (plist-get state :native-buffer-scroll-p))
                     (ebox--native-buffer-scroll-root-proof-p
                      buffer region-id state)
                     (not (eq (plist-get (gethash buffer
                                           ebox--runtime-prewarm-jobs)
                                         :phase)
                              'native-scroll)))
            (ebox--schedule-buffer-runtime-prewarm buffer 0 nil)))))))

(when (boundp 'window-buffer-change-functions)
  (add-hook 'window-buffer-change-functions #'ebox--window-buffer-change))

(defun ebox--window-state-change (frame)
  "Re-arm visible Ebox buffers after FRAME's windows settle.

Some Emacs builds dispatch `window-buffer-change-functions' before the new
buffer is observable through `get-buffer-window'.  The state-change hook is
the post-redisplay boundary; inspect each live window once there so a buffer
that was rendered off-window cannot miss the native-scroll handoff."
  (when (frame-live-p frame)
    (dolist (window (window-list frame 'no-minibuf))
      (ebox--window-buffer-change window))))

(when (boundp 'window-state-change-functions)
  (add-hook 'window-state-change-functions #'ebox--window-state-change))

(defun ebox--runtime-prewarm-record-viewport-node
    (job node width-allowed)
  "Record NODE's direct viewport dependencies in JOB.
Return non-nil when descendant width dependencies remain relevant."
  (let ((width-direct (ebox--node-direct-viewport-width-dependent-p node))
        (vertical (ebox--node-direct-viewport-height-dependent-p node)))
    (when (and width-direct width-allowed)
      (plist-put job :viewport-width-ids-rev
                 (cons (ebox--ensure-node-id node)
                       (plist-get job :viewport-width-ids-rev))))
    (when vertical
      (plist-put job :viewport-height-ids-rev
                 (cons (ebox--ensure-node-id node)
                       (plist-get job :viewport-height-ids-rev))))
    (and width-allowed
         (not (ebox--render-cache-contained-viewport-node-p node)))))

(defun ebox--runtime-prewarm-snapshot-slice (buffer job)
  "Advance BUFFER's post-order lightweight snapshot frontier for JOB."
  (let ((limit (max 1 ebox-runtime-idle-prewarm-slice-size))
        (count 0)
        (ebox--node-region-ids-cache
         (plist-get job :node-region-ids-cache)))
    (while (and (< count limit) (plist-get job :snapshot-stack))
      (let* ((stack (plist-get job :snapshot-stack))
             (frame (car stack))
             (node (aref frame 0))
             (children (aref frame 1))
             (width-allowed (aref frame 2)))
        (cond
         ((eq children :uninitialized)
          (aset frame 1 (ebox-tree--children-raw node))
          (aset frame 3
                (ebox--runtime-prewarm-record-viewport-node
                 job node width-allowed)))
         (children
          (aset frame 1 (cdr children))
          (plist-put job :snapshot-stack
                     (cons (vector (car children) :uninitialized
                                   (aref frame 3) (aref frame 3))
                           stack)))
         (t
          (plist-put job :snapshot-stack (cdr stack))
          (when (and (listp node) (not (stringp node)))
            (let ((node-id (ebox--ensure-node-id node)))
              (ebox--put-layout-snapshot
               buffer node-id
               (ebox--node-layout-snapshot buffer node nil))))))
        (setq count (1+ count))))
    (unless (plist-get job :snapshot-stack)
      (when-let* ((state (ebox--buffer-render-state buffer)))
        (let ((width-ids (nreverse
                          (plist-get job :viewport-width-ids-rev)))
              (height-ids (nreverse
                           (plist-get job :viewport-height-ids-rev))))
          (plist-put state :layout-snapshots-complete-p t)
          (plist-put state :viewport-dependent-node-id-axes
                     (cons width-ids height-ids))
          (plist-put state :viewport-dependent-node-ids
                     (delete-dups
                      (copy-sequence (append width-ids height-ids)))))
        (plist-put state :viewport-dependent-node-ids-ready t))
      (plist-put job :phase 'scroll))))

(defun ebox--runtime-prewarm-add-line (task line)
  "Add LINE to TASK's index without a later whole-index sort."
  (let ((index (plist-get task :index))
        (tails (plist-get task :tails))
        (line-index (plist-get task :line-index)))
    (dolist (region-id (ebox--scroll-line-region-ids line))
      (when-let* ((span (ebox--scroll-line-region-span
                        line (ebox--region-id-set (list region-id)))))
        (let* ((cell (list (cons line-index span)))
               (tail (gethash region-id tails)))
          (if tail
              (setcdr tail cell)
            (puthash region-id cell index))
          (puthash region-id cell tails))))
    (plist-put task :line-index (1+ line-index))))

(defun ebox--runtime-prewarm-scroll-source-task (buffer source)
  "Return a bounded line-index task for SOURCE owned by BUFFER."
  (let* ((region-id (plist-get source :region-id))
         (state (plist-get source :state))
         (lines-key (plist-get source :lines-key))
         (lines (plist-get state lines-key)))
    (when (and (eq (ebox--scroll-get-state region-id) state)
               (eq (ebox--scroll-state-buffer state) buffer)
               (plist-get state (plist-get source :deferred-key))
               lines)
      (list :region-id region-id
            :state state
            :index-key (plist-get source :index-key)
            :deferred-key (plist-get source :deferred-key)
            :lines-key lines-key
            :lines lines
            :remaining-lines lines
            :line-index 0
            :index (make-hash-table :test 'equal)
            :tails (make-hash-table :test 'equal)))))

(defun ebox--runtime-prewarm-scroll-sources (region-id state)
  "Return the two cached-line index sources for REGION-ID and STATE."
  (list
   (list :region-id region-id
         :state state
         :index-key :region-line-span-index
         :deferred-key :region-line-span-index-deferred
         :lines-key :content-lines)
   (list :region-id region-id
         :state state
         :index-key :rendered-region-line-span-index
         :deferred-key :rendered-region-line-span-index-deferred
         :lines-key :rendered-content-lines)))

(defun ebox--runtime-prewarm-scroll-slice (buffer job)
  "Prepare one cached scroll-line index slice for BUFFER's JOB."
  (let ((limit (max 1 ebox-runtime-idle-prewarm-slice-size))
        (count 0))
    (while (and (< count limit)
                (not (memq (plist-get job :phase) '(done native-scroll))))
      (cond
       ((plist-get job :scroll-task)
        (let* ((task (plist-get job :scroll-task))
               (state (plist-get task :state))
               (lines (plist-get task :lines))
               (remaining (plist-get task :remaining-lines)))
          (cond
           ((or (not (eq (ebox--scroll-get-state
                          (plist-get task :region-id))
                         state))
                (not (eq lines
                         (plist-get state (plist-get task :lines-key)))))
            (plist-put job :scroll-task nil))
           (remaining
            (ebox--runtime-prewarm-add-line task (car remaining))
            (plist-put task :remaining-lines (cdr remaining))
            (unless (cdr remaining)
              (plist-put state (plist-get task :index-key)
                         (plist-get task :index))
              (plist-put state (plist-get task :deferred-key) nil)
              (plist-put job :scroll-task nil)))
           (t
            (plist-put job :scroll-task nil))))
        (setq count (1+ count)))
       ((plist-get job :scroll-sources)
        (let* ((sources (plist-get job :scroll-sources))
               (source (car sources)))
          (plist-put job :scroll-sources (cdr sources))
          (when-let* ((task
                      (ebox--runtime-prewarm-scroll-source-task
                       buffer source)))
            (plist-put job :scroll-task task)))
        (setq count (1+ count)))
       ((plist-get job :scroll-region-ids)
        (let* ((region-ids (plist-get job :scroll-region-ids))
               (region-id (car region-ids))
               (state (ebox--scroll-get-state region-id)))
          (plist-put job :scroll-region-ids (cdr region-ids))
          (when (and state (eq (ebox--scroll-state-buffer state) buffer))
            (plist-put job :scroll-sources
                       (ebox--runtime-prewarm-scroll-sources
                        region-id state))))
        (setq count (1+ count)))
       (t
        (plist-put job :phase
                       (if (and (not noninteractive)
                            (plist-get job :native-prewarm-allowed-p)
                            ebox-native-buffer-scroll
                            (ebox--native-buffer-scroll-root-proof-p
                             buffer
                             (plist-get job :native-scroll-region-id)))
                       'native-scroll
                     'done)))))))

(defun ebox--runtime-prewarm-native-scroll (buffer job)
  "Materialize and publish an eligible root scroll surface for BUFFER.
The one-time publication runs only from the idle prewarm job; visible scroll
events use the native window afterwards and never enter the TP surface plan."
  (let* ((region-id (plist-get job :native-scroll-region-id))
         (render-state (ebox--buffer-render-state buffer)))
    (when (and region-id
               (ebox--native-buffer-scroll-root-proof-p
                buffer region-id render-state))
      (let* ((old-state (ebox--scroll-get-state region-id))
             (materialized
              (ebox--scroll-state-materialize-lines region-id old-state)))
        (unless (plist-get materialized :rendered-content-lines)
          (let ((box (plist-get materialized :box))
                (lines (plist-get materialized :content-lines)))
            (when (and box lines)
              (setq materialized (copy-sequence materialized))
              (plist-put materialized :rendered-content-lines
                         (ebox--scroll-rendered-content-lines
                          box lines region-id 0)))))
        (when (plist-get materialized :content-lines-complete-p)
          (puthash region-id materialized ebox--scroll-global-state)
          (let* ((runtime (ebox--surface-scroll-runtime buffer region-id))
                 (table (plist-get runtime :scroll-table))
                 (state (copy-sequence materialized))
                 (candidate-box
                  (ebox--root-region-box
                   (plist-get runtime :root) region-id))
                 (old-point (with-current-buffer buffer (point))))
            (plist-put state :box (or candidate-box (plist-get state :box)))
            (puthash region-id state table)
            (let ((ebox--native-scroll-prewarm-in-progress t))
              (ebox--surface-publish-scroll
               buffer region-id runtime
               (list :result 0 :state state
                     :offset (or (plist-get state :scroll-offset) 0)
                     :native-materialize-p t)))
            (when-let* ((window (get-buffer-window buffer t)))
              (with-current-buffer buffer
                (goto-char (min old-point (point-max))))
              (set-window-point window (point))
              (let ((position
                     (ebox--native-buffer-scroll-position
                      buffer (or (plist-get state :scroll-offset) 0))))
                (set-window-start window position t)
                (set-window-point window position))))))))
  (plist-put job :phase 'done))

(defun ebox--runtime-prewarm-step (buffer)
  "Run one bounded runtime prewarm slice for BUFFER.
Return non-nil while more work remains."
  (when-let* ((job (gethash buffer ebox--runtime-prewarm-jobs)))
    (let ((state (ebox--buffer-render-state buffer)))
      (if (or (not (buffer-live-p buffer))
              (not (eq state (plist-get job :render-state)))
              (/= (or (plist-get state :runtime-revision) 0)
                  (plist-get job :runtime-revision)))
          (ebox--cancel-buffer-runtime-prewarm buffer)
        (pcase (plist-get job :phase)
          ('snapshots
           (ebox--runtime-prewarm-snapshot-slice buffer job))
          ('scroll
           (ebox--runtime-prewarm-scroll-slice buffer job))
          ('native-scroll
           (ebox--runtime-prewarm-native-scroll buffer job)))
        (if (eq (plist-get job :phase) 'done)
            (progn
              (remhash buffer ebox--runtime-prewarm-jobs)
              nil)
          t)))))

(defun ebox--runtime-prewarm-timer (buffer)
  "Run BUFFER's scheduled runtime prewarm slice."
  (remhash buffer ebox--runtime-prewarm-timers)
  (when (ebox--runtime-prewarm-step buffer)
    ;; A newly registered idle timer is measured from the beginning of the
    ;; current idle period.  Scheduling it with zero (or only the base delay)
    ;; makes every remaining slice immediately ripe once the first slice runs,
    ;; monopolizing redisplay until a large runtime is fully prewarmed.
    (ebox--runtime-prewarm-schedule-timer
     buffer
     (ebox--idle-continuation-delay ebox-runtime-idle-prewarm-delay))))

(defun ebox--runtime-prewarm-drain (buffer)
  "Synchronously drain BUFFER's scheduled prewarm job for tests and profiling."
  (when-let* ((timer (gethash buffer ebox--runtime-prewarm-timers)))
    (when (timerp timer)
      (cancel-timer timer))
    (remhash buffer ebox--runtime-prewarm-timers))
  (let ((limit 100000)
        completed)
    (while (and (> limit 0) (not completed))
      (unless (gethash buffer ebox--runtime-prewarm-jobs)
        (when-let* ((state (and (buffer-live-p buffer)
                               (ebox--buffer-render-state buffer))))
          (puthash buffer (ebox--runtime-prewarm-new-job buffer state)
                   ebox--runtime-prewarm-jobs)))
      (if (ebox--runtime-prewarm-step buffer)
          (setq limit (1- limit))
        (setq completed t)))
    (when (not completed)
      (error "Runtime prewarm did not converge for %S" buffer))))

(defun ebox--region-id-at-point ()
  "Get region-id at current point by checking ebox-content property."
  (get-text-property (point) 'ebox-content))

(defun ebox--scroll-region-ids-in-mounts-at-pos (pos)
  "Return scroll region ids whose TP mounts contain POS, inner first."
  (let (candidates)
    (maphash
     (lambda (region-id _state)
       (when-let* ((bounds
                   (ebox-surface-region-bounds
                    (current-buffer) region-id)))
         (when (and (<= (car bounds) pos) (< pos (cdr bounds)))
           (push (cons region-id
                       (ebox--scroll-region-semantic-depth region-id))
                 candidates))))
     ebox--scroll-global-state)
    (mapcar #'car
            (sort candidates
                  (lambda (a b)
                    (if (= (cdr a) (cdr b))
                        (string< (format "%S" (car a))
                                 (format "%S" (car b)))
                      (> (cdr a) (cdr b))))))))

(defun ebox--scroll-region-semantic-depth (region-id)
  "Return REGION-ID's runtime owner depth in the current buffer.
Scroll routing uses semantic ancestry rather than mount span length because
nested owners may render equal-sized clipped spans."
  (let* ((state (ebox--buffer-render-state (current-buffer)))
         (region-nodes (plist-get state :region-node-table))
         (node-id (and region-nodes (gethash region-id region-nodes))))
    (if node-id (ebox-surface--node-depth state node-id) -1)))

(defun ebox--scroll-region-ids-in-buffer-outer-first ()
  "Return scroll region ids in the current buffer from outer to inner."
  (let (candidates)
    (maphash
     (lambda (region-id _state)
       (when-let* ((bounds
                   (ebox-surface-region-bounds
                    (current-buffer) region-id)))
         (push (cons region-id
                     (ebox--scroll-region-semantic-depth region-id))
               candidates)))
     ebox--scroll-global-state)
    (mapcar #'car
            (sort candidates
                  (lambda (a b)
                    (if (= (cdr a) (cdr b))
                        (string< (format "%S" (car a))
                                 (format "%S" (car b)))
                      (< (cdr a) (cdr b))))))))

(defun ebox--scroll-region-ids-at-pos (pos)
  "Return scroll candidate region ids at POS from inner to outer."
  (let (ids)
    (cl-labels ((add (region-id)
                  (when (and region-id
                             (not (member region-id ids)))
                    (setq ids (append ids (list region-id))))))
      (add (get-text-property pos 'ebox-content))
      (dolist (region-id (get-text-property pos 'ebox-content-owners))
        (add region-id))
      (add (get-text-property pos 'ebox-content-owner))
      (dolist (entry ebox-region-types)
        (unless (memq (cdr entry) '(ebox-content ebox-content-owner))
          (add (get-text-property pos (cdr entry)))))
      (unless (cl-some #'ebox--scroll-get-state ids)
        (dolist (region-id (ebox--scroll-region-ids-in-mounts-at-pos pos))
          (add region-id))))
    (sort ids
          (lambda (a b)
            (let ((a-depth (ebox--scroll-region-semantic-depth a))
                  (b-depth (ebox--scroll-region-semantic-depth b)))
              (if (= a-depth b-depth)
                  (string< (format "%S" a) (format "%S" b))
                (> a-depth b-depth)))))))

(defun ebox--scroll-region-ids-at-point ()
  "Return scroll candidate region ids at point from inner to outer."
  (when (< (point-min) (point-max))
    (ebox--scroll-region-ids-at-pos
     (min (max (point) (point-min))
          (1- (point-max))))))

(defun ebox--scroll-refresh-dirty-prefix-for-offset
    (region-id state desired-offset)
  "Refresh dirty lazy STATE through REGION-ID's next visible window.
Geometry updates can invalidate cached prefix lines without changing their
length.  Refresh them before any scroll, even when DESIRED-OFFSET remains
inside the old prefix, so a line-slide never mixes two layout versions."
  (if (not (plist-get state :lazy-scroll-prefix-dirty))
      state
    (let* ((scroll-offset (or (plist-get state :scroll-offset) 0))
           (content-height (max 0 (or (plist-get state :content-height) 0)))
           (required-lines
            (+ (max 0 scroll-offset desired-offset) content-height)))
      (ebox--scroll-state-ensure-prefix-lines
       region-id state required-lines t))))

(defun ebox--surface-scroll-runtime (buffer region-id)
  "Return isolated scroll candidate runtime for BUFFER and REGION-ID."
  (let* ((old-state (ebox--buffer-render-state buffer))
         (old-root (plist-get old-state :root-node))
         (owner-id (ebox--buffer-region-render-owner-node-id
                    buffer region-id))
         ;; Scrolling changes one box property and never changes the logical
         ;; tree.  Copy only that owner path when it is the published root;
         ;; nested scroll owners retain the old conservative isolated-copy
         ;; path until their ancestor publication contract is proven.  The
         ;; previous implementation copied and indexed the complete gallery
         ;; for every wheel event, which made a 512-node grid visibly stall.
         (path-root
          (and owner-id old-root
               (equal owner-id (plist-get old-root :node-id))
               (ebox-incremental-surface-region-candidate-root
                buffer region-id)))
         (root (or path-root
                   (ebox-tree-copy-node-structure old-root)))
         ;; All runtime index keys remain stable for a scroll-only path copy.
         ;; Rebind just the affected region box; the incremental commit will
         ;; derive its local index delta from the shared candidate path.
         (region-box-table
          (copy-hash-table (plist-get old-state :region-box-table)))
         (candidate-box (ebox--root-region-box root region-id))
         (_ (when candidate-box
              (puthash region-id candidate-box region-box-table)))
         (index
          (list :region-id-set (plist-get old-state :region-id-set)
                :region-box-table region-box-table))
         (scroll-table
          (ebox-incremental--candidate-scroll-state-table
           buffer old-state index region-box-table))
         (old-scroll-state (ebox--scroll-get-state region-id))
         (candidate-scroll-state (gethash region-id scroll-table))
         (state (copy-sequence old-state)))
    (dolist (key '(:render-content-prefix :materialize-content-lines))
      (when (plist-member old-scroll-state key)
        (setq candidate-scroll-state
              (plist-put candidate-scroll-state key
                         (plist-get old-scroll-state key)))))
    (puthash region-id candidate-scroll-state scroll-table)
    (setq state (ebox--render-state-install-index state index))
    (plist-put state :root-node root)
    (plist-put state :scroll-state-table scroll-table)
    (unless (gethash region-id scroll-table)
      (error "Ebox scroll region has no candidate state: %S" region-id))
    (list :root root :state state :scroll-table scroll-table
          :base-state old-state)))

(defun ebox--surface-scroll-target (region-id state delta prefix-budget-lines)
  "Return REGION-ID STATE staged by DELTA within PREFIX-BUDGET-LINES."
  (catch 'result
    (when (and (plist-get state :native-reflow-materialize-p)
               (plist-get state :materialize-content-lines))
      (setq state (ebox--scroll-state-materialize-lines region-id state)))
    (when (and (plist-get state :native-reflow-target-prefix-p)
               (not (ebox--scroll-sync-prefix-render-p)))
      (let* ((offset (or (plist-get state :scroll-offset) 0))
             (height (or (plist-get state :content-height) 0))
             (required (+ (max 0 offset (+ offset delta)) height)))
        (setq state
              (plist-put state :cache-miss-prefetch-target-lines required))
        (throw 'result
               (list :result 'pending :state state :offset offset
                     :schedule-prefetch t))))
    (let* ((old-offset (or (plist-get state :scroll-offset) 0))
           (desired (+ old-offset delta))
           (refresh-p (or (plist-get state :lazy-scroll-prefix-dirty)
                          (plist-get state
                                     :lazy-scroll-window-refresh-required))))
      (setq state
            (ebox--scroll-refresh-dirty-prefix-for-offset
             region-id state desired))
      (when (plist-get state :lazy-scroll-prefix-dirty)
        (throw 'result (list :result 'pending)))
      (when (and (> delta 0)
                 (or prefix-budget-lines
                     (and (ebox--scroll-sync-prefix-render-p)
                          (<= delta (ebox--scroll-prefetch-slice-lines)))))
        (setq state
              (ebox--scroll-ensure-bounded-prefix-for-offset
               region-id state desired prefix-budget-lines)))
      (let* ((lines (plist-get state :content-lines))
             (height (or (plist-get state :content-height) 0))
             (maximum (max 0 (- (length lines) height)))
             (new-offset (max 0 (min maximum desired)))
             (cache-miss-p
              (and (> delta 0) (> desired maximum)
                   (plist-get state :render-content-prefix)
                   (not (plist-get state :content-lines-complete-p)))))
        (when cache-miss-p
          (setq state
                (ebox--scroll-schedule-cache-miss-prefetch
                 region-id state)))
        (cond
         ((and (= new-offset old-offset) refresh-p)
          (list :result 'refreshed :state state :offset new-offset))
         ((= new-offset old-offset)
          (if cache-miss-p
              (list :result 'pending :state state :offset new-offset
                    :schedule-prefetch t)
            (list :result nil)))
         (t
          (list :result (- new-offset old-offset)
                :state state :offset new-offset
                :schedule-prefetch cache-miss-p)))))))

(defun ebox--surface-publish-scroll
    (buffer region-id runtime transition)
  "Publish BUFFER scroll TRANSITION for REGION-ID from isolated RUNTIME."
  (let* ((root (plist-get runtime :root))
         (root-id (and root (plist-get root :node-id)))
         (base-state (plist-get runtime :base-state))
         (table (plist-get runtime :scroll-table))
         (state (plist-get transition :state))
         (offset (plist-get transition :offset))
         (box (or (ebox--root-region-box root region-id)
                  (error "Ebox scroll candidate lost region %S" region-id)))
         (owner-id
          (ebox--buffer-region-render-owner-node-id buffer region-id)))
    (ebox-put box :scroll-offset offset)
    (plist-put box :ebox-scroll-offset-controlled-p t)
    (setq state (plist-put state :scroll-offset offset))
    (setq state (plist-put state :box box))
    (setq state (ebox--plist-remove
                 state :lazy-scroll-window-refresh-required))
    (puthash region-id state table)
    (ebox--cancel-buffer-runtime-prewarm buffer)
    (ebox-incremental--notify-before-runtime-mutation buffer 'scroll)
    (unless (eq base-state (ebox--buffer-render-state buffer))
      (error "Ebox runtime changed during scroll update notification"))
    (let* ((staged-scroll-state (copy-sequence state))
           (scroll-patch-fast-p
           (and (ebox--scroll-state-retained-window-ready-p
                  staged-scroll-state)
                 t))
           (commit-input
            (let ((ebox--scroll-global-state table))
              (ebox-incremental-prepare-scoped-commit
               buffer root
               (append
                (ebox--constraint-change-report-props
                 (ebox--region-constraint-change
                  buffer region-id 'geometry '(:scroll-offset)))
                (list :region-id region-id
                      :constraint-source 'scroll
                      :strategy 'span-patch
                      :patch-count 1
                      :patch-ops '(span-patch)
                      :owner-id owner-id
                      :owner-ids (list owner-id)
                      :scroll-state-transaction t
                      :scroll-patch-fast-p scroll-patch-fast-p
                      :native-scroll-materialize-p
                      (plist-get transition :native-materialize-p)))
               t)))
           (_staged-cache
            (ebox--surface-restore-staged-scroll-cache
             commit-input region-id staged-scroll-state))
           (scope-node-ids
            (or (plist-get commit-input :scope-node-ids)
                (list owner-id)))
           (state-overrides
            (let ((value (plist-get commit-input :state-overrides)))
              (setq value
                    (plist-put
                     value :preserve-scroll-producer-region-ids
                     (list region-id)))
              (setq value
                    (plist-put
                     value :native-buffer-scroll-p
                     (and (plist-get transition :native-materialize-p) t)))
              (setq value
                    (plist-put
                     value :retained-scroll-content-p
                     (and scroll-patch-fast-p root-id owner-id
                          (= root-id owner-id))))
              (if (plist-get transition :native-materialize-p)
                  (plist-put value :native-scroll-materialize-p t)
                value)))
           (surface
            (ebox-surface-update-buffer-scoped
             buffer
             (plist-get commit-input :root)
             scope-node-ids
             (plist-get commit-input :report-base)
             state-overrides nil nil
             (and (plist-get transition :schedule-prefetch) 0)
             (plist-get commit-input :projection-kind)
             t)))
      (ignore surface)
      (plist-get transition :result))))

(defun ebox--surface-restore-staged-scroll-cache
    (commit-input region-id staged-state)
  "Restore REGION-ID STAGED-STATE cache fields in COMMIT-INPUT."
  (let* ((overrides (plist-get commit-input :state-overrides))
         (table (plist-get overrides :scroll-state-table))
         (state (gethash region-id table)))
    (dolist (key '(:content-lines :rendered-content-lines
                   :content-lines-complete-p :render-content-prefix
                   :materialize-content-lines :content-region-id-set
                   :region-line-bounds-index :region-line-span-index
                   :region-line-span-index-deferred
                   :rendered-region-line-span-index
                   :rendered-region-line-span-index-deferred
                   :region-line-span-hints :cache-miss-prefetch-target-lines
                   :native-reflow-target-prefix-p
                   :native-reflow-prefix-reset-p
                   :native-reflow-visible-offset
                   :native-reflow-visible-lines))
      (if (plist-member staged-state key)
          (setq state (plist-put state key (plist-get staged-state key)))
        (setq state (ebox--plist-remove state key))))
    (puthash region-id state table)
    commit-input))

(defun ebox--surface-scroll-region-by
    (buffer region-id delta prefix-budget-lines)
  "Scroll mounted BUFFER REGION-ID by DELTA within PREFIX-BUDGET-LINES."
  (let* ((runtime (ebox--surface-scroll-runtime buffer region-id))
         (table (plist-get runtime :scroll-table))
         (candidate-state (plist-get runtime :state))
         (transition
          (let ((ebox--scroll-global-state table)
                (ebox--scroll-idle-prefetch-timers
                 (make-hash-table :test 'equal))
                (ebox--smooth-scroll-state-table
                 (make-hash-table :test 'equal))
                (ebox-incremental--buffer-render-state-override
                 (cons buffer candidate-state)))
            (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch)
                       (lambda (&rest _) nil)))
              (ebox--surface-scroll-target
               region-id (gethash region-id table)
               delta prefix-budget-lines)))))
    (if (plist-member transition :state)
        (ebox--surface-publish-scroll buffer region-id runtime transition)
      (plist-get transition :result))))

(defun ebox--surface-scroll-to-offset (buffer region-id offset)
  "Set mounted BUFFER REGION-ID to absolute scroll OFFSET through TP."
  (let* ((state (ebox--buffer-render-state buffer))
         (table (plist-get state :scroll-state-table))
         (scroll-state (and table (gethash region-id table)))
         (current (and scroll-state
                       (or (plist-get scroll-state :scroll-offset) 0))))
    (unless scroll-state
      (user-error "Ebox region is not scrollable: %S" region-id))
    (unless (numberp offset)
      (user-error "Ebox scroll offset is not numeric: %S" offset))
    (if (= offset current)
        (ebox--surface-region-no-op-report state region-id nil)
      (ebox--surface-scroll-region-by
       buffer region-id (- offset current) nil)
      (ebox--buffer-update-report buffer))))

(defun ebox--scroll-region-by (region-id delta &optional prefix-budget-lines)
  "Scroll REGION-ID by DELTA through its runtime using PREFIX-BUDGET-LINES."
  (let ((run
         (lambda ()
           (when-let* ((state (and region-id (ebox--scroll-get-state region-id)))
                       (buffer (ebox--scroll-state-buffer state)))
             (unless (ebox-surface-buffer-mounted-p buffer)
               (error "Ebox scroll update requires a mounted TP surface"))
             (ebox--surface-scroll-region-by
              buffer region-id delta prefix-budget-lines)))))
    ;; Scroll publication allocates a short-lived candidate text/ownership
    ;; plan.  Keep GC out of the visible event and let the existing deferred
    ;; render-GC lease collect after the interaction burst; batch tests keep
    ;; their deterministic threshold and never install a timer.
    (let ((native
           (when-let* ((state (and region-id
                                   (ebox--scroll-get-state region-id)))
                       (buffer (ebox--scroll-state-buffer state)))
             (ebox--native-buffer-scroll-by buffer region-id delta))))
      (if (not (eq native 'native-unavailable))
          native
        (if noninteractive
            (funcall run)
          (ebox--with-deferred-render-gc
            (funcall run)))))))

(defun ebox--scroll-progress-p (result)
  "Return non-nil when RESULT represents consumed or pending scroll work."
  (or (eq result 'pending)
      (and (numberp result)
           (/= result 0))))

(defun ebox--scroll-intent-create (delta chain)
  "Create a signed line scroll intent for inner-to-outer owner CHAIN.
DELTA is the requested document-line distance.  The returned plist is the
single allocation record used by keyboard, page, and wheel input."
  (unless (and (integerp delta) (/= delta 0))
    (error "Ebox scroll intent delta must be a non-zero integer: %S" delta))
  (list :requested delta
        :direction (if (> delta 0) 1 -1)
        :chain (delete-dups (copy-sequence chain))
        :index 0
        :remaining delta
        :consumption nil
        :ebox-consumed 0
        :native-residual 0))

(defun ebox--scroll-intent-at-point (delta)
  "Create keyboard scroll intent DELTA anchored at current point."
  (ebox--scroll-intent-create
   delta (ebox--scroll-region-ids-at-point)))

(defun ebox--scroll-intent-at-event (event delta)
  "Create wheel scroll intent DELTA anchored at EVENT position."
  (ebox--scroll-intent-create delta (ebox--wheel-region-ids event)))

(defun ebox--scroll-consumed-delta (requested result)
  "Normalize scroll RESULT to actual signed consumption of REQUESTED.
Publication results such as `pending' and `refreshed' moved no lines and
therefore consume nothing.  Numeric region results must preserve direction
and cannot exceed the remaining request."
  (let ((consumed (if (numberp result) result 0)))
    (unless (or (= consumed 0)
                (and (= (if (> consumed 0) 1 -1)
                        (if (> requested 0) 1 -1))
                     (<= (abs consumed) (abs requested))))
      (error "Invalid Ebox scroll consumption %S for request %S"
             consumed requested))
    consumed))

(defun ebox--scroll-consume-intent (intent &optional native-consumer)
  "Allocate INTENT from inner owners outward, then to NATIVE-CONSUMER.
Each owner receives only the signed residual left by its child.  The returned
intent records the exact invariant REQUESTED = EBOX-CONSUMED +
NATIVE-RESIDUAL; refresh-only publication never consumes user input."
  (let ((remaining (plist-get intent :requested))
        (chain (plist-get intent :chain))
        consumption
        (index 0))
    (while (and chain (/= remaining 0))
      (let* ((region-id (pop chain))
             (result (ebox--scroll-region-by region-id remaining))
             (consumed (ebox--scroll-consumed-delta remaining result)))
        (push (cons region-id consumed) consumption)
        (setq remaining (- remaining consumed))
        (setq index (1+ index))))
    ;; Preserve zero-capacity owners in the allocation record.  This makes
    ;; boundary behavior inspectable and keeps the chain/index contract stable
    ;; for a future deferred smooth tick.
    (dolist (region-id chain)
      (push (cons region-id 0) consumption)
      (setq index (1+ index)))
    (let ((ebox-consumed (- (plist-get intent :requested) remaining)))
      (plist-put intent :index index)
      (plist-put intent :remaining remaining)
      (plist-put intent :consumption (nreverse consumption))
      (plist-put intent :ebox-consumed ebox-consumed)
      (plist-put intent :native-residual remaining)
      (when (and native-consumer (/= remaining 0))
        (funcall native-consumer remaining))
      intent)))

(defun ebox--scroll-redisplay-after-tick ()
  "Flush GUI redisplay after an asynchronous scroll tick."
  (unless noninteractive
    (redisplay t)))

(defun ebox--scroll-first-region-by (region-ids delta)
  "Scroll the first region in REGION-IDS that can consume DELTA."
  (catch 'scrolled
    (dolist (region-id region-ids)
      (when (ebox--scroll-progress-p
             (ebox--scroll-region-by region-id delta))
        (throw 'scrolled t)))
    nil))

(defvar ebox--smooth-scroll-state-table (make-hash-table :test 'equal)
  "Region-keyed pending smooth wheel scroll state.")

(defun ebox--scrollable-region-p (region-id delta)
  "Return non-nil when REGION-ID can consume DELTA lines."
  (when-let* ((state (and region-id (ebox--scroll-get-state region-id))))
    (let* ((scroll-offset (or (plist-get state :scroll-offset) 0))
           (content-lines (plist-get state :content-lines))
           (content-height (plist-get state :content-height))
           (max-offset (max 0 (- (length content-lines) content-height)))
           (new-offset (max 0 (min max-offset (+ scroll-offset delta)))))
      (or (and (/= delta 0)
               (plist-get state :native-reflow-target-prefix-p))
          (and (> delta 0)
               (plist-get state :render-content-prefix)
               (not (plist-get state :content-lines-complete-p)))
          (and (> max-offset 0)
               (/= new-offset scroll-offset))))))

(defun ebox--first-scrollable-region (region-ids delta)
  "Return the first region in REGION-IDS that can consume DELTA."
  (cl-find-if (lambda (region-id)
                (ebox--scrollable-region-p region-id delta))
              region-ids))

(defun ebox--smooth-scroll-stop (region-id)
  "Stop pending smooth wheel scroll animation for REGION-ID."
  (when-let* ((entry (gethash region-id ebox--smooth-scroll-state-table)))
    (when-let* ((timer (plist-get entry :timer)))
      (cancel-timer timer))
    (remhash region-id ebox--smooth-scroll-state-table)
    (ebox--deferred-render-gc-schedule-restore)
    (ebox--scroll-schedule-idle-prefetch region-id)))

(defun ebox--smooth-scroll-pause-for-prefetch
    (region-id entry pending)
  "Pause REGION-ID smooth scroll ENTRY until lazy prefetch extends the cache."
  (when-let* ((timer (plist-get entry :timer)))
    (when (timerp timer)
      (cancel-timer timer)))
  (plist-put entry :timer nil)
  (plist-put entry :pending pending)
  (plist-put entry :waiting-prefetch t)
  (puthash region-id entry ebox--smooth-scroll-state-table))

(defun ebox--smooth-scroll-clamp-pending (region-id pending)
  "Clamp PENDING lines to REGION-ID's remaining scrollable range."
  (if-let* ((state (and region-id (ebox--scroll-get-state region-id))))
      (let* ((scroll-offset (or (plist-get state :scroll-offset) 0))
             (lazy-forward
              (and (> pending 0)
                   (plist-get state :render-content-prefix)
                   (not (plist-get state :content-lines-complete-p))))
             (content-line-count (length (plist-get state :content-lines)))
             (content-height (plist-get state :content-height))
             (max-offset (max 0 (- content-line-count content-height))))
        (if lazy-forward
            pending
          (max (- scroll-offset)
               (min (- max-offset scroll-offset)
                    pending))))
    0))

(defun ebox--smooth-scroll-tick-magnitude (pending)
  "Return how many lines one smooth tick should consume from PENDING."
  (let* ((pending (abs pending))
         (base (max 1 ebox-wheel-smooth-scroll-lines-per-tick))
         (target (max 1 ebox-wheel-smooth-scroll-target-ticks))
         (adaptive (ceiling pending target)))
    (min pending (max base adaptive))))

(defun ebox--smooth-scroll-lazy-boundary-p (region-id delta)
  "Return non-nil when DELTA would cross REGION-ID's lazy prefix boundary."
  (when-let* ((state (and (> delta 0)
                         (ebox--scroll-get-state region-id))))
    (let* ((scroll-offset (or (plist-get state :scroll-offset) 0))
           (content-lines (plist-get state :content-lines))
           (content-height (or (plist-get state :content-height) 0))
           (max-offset (max 0 (- (length content-lines) content-height))))
      (and (> (+ scroll-offset delta) max-offset)
           (plist-get state :render-content-prefix)
           (not (plist-get state :content-lines-complete-p))))))

(defun ebox--smooth-scroll-tick (region-id)
  "Run one smooth wheel scroll tick for REGION-ID."
  (let* ((entry (gethash region-id ebox--smooth-scroll-state-table))
         (pending (and entry
                       (ebox--smooth-scroll-clamp-pending
                        region-id
                        (or (plist-get entry :pending) 0)))))
    (cond
     ((or (not entry) (= pending 0) (not (ebox--scroll-get-state region-id)))
      (ebox--smooth-scroll-stop region-id))
     (t
      (let* ((magnitude (ebox--smooth-scroll-tick-magnitude pending))
             (delta (if (> pending 0) magnitude (- magnitude))))
        (when (ebox--smooth-scroll-lazy-boundary-p region-id delta)
          (setq magnitude
                (min magnitude
                     (max 1 ebox-wheel-smooth-scroll-lines-per-tick)))
          (setq delta (if (> pending 0) magnitude (- magnitude))))
        (let* ((state-before (ebox--scroll-get-state region-id))
               (offset-before (or (plist-get state-before :scroll-offset) 0))
               (result (ebox--scroll-region-by region-id delta magnitude))
               (state-after (ebox--scroll-get-state region-id))
               (offset-after (or (plist-get state-after :scroll-offset)
                                 offset-before))
               (consumed (- offset-after offset-before)))
          (cond
           ((and (ebox--scroll-progress-p result)
                 (/= consumed 0))
            (ebox--scroll-redisplay-after-tick)
            (let ((remaining (- pending consumed)))
              (if (= remaining 0)
                  (ebox--smooth-scroll-stop region-id)
                (plist-put entry :pending remaining)
                (puthash region-id entry ebox--smooth-scroll-state-table))))
           ((eq result 'pending)
            (ebox--smooth-scroll-pause-for-prefetch
             region-id entry pending))
           (t
            (ebox--smooth-scroll-stop region-id)))))))))

(defun ebox--smooth-scroll-region-by
    (region-id delta &optional chain index residual)
  "Animate wheel scroll REGION-ID by DELTA lines.
CHAIN, INDEX, and RESIDUAL retain the owner-allocation position when this
animation was admitted because one owner can consume the complete intent."
  (let* ((existing (gethash region-id ebox--smooth-scroll-state-table))
         (entry (or existing
                    (list :pending 0 :timer nil
                          :chain (or chain (list region-id))
                          :index (or index 0)
                          :direction (if (> delta 0) 1 -1)
                          :residual (or residual 0))))
         (had-timer (timerp (plist-get entry :timer)))
         (pending (ebox--smooth-scroll-clamp-pending
                   region-id
                   (+ (or (plist-get entry :pending) 0) delta))))
    (if (= pending 0)
        (progn
          (ebox--smooth-scroll-stop region-id)
          nil)
      ;; Enter the deferred-GC lease once per animation: entry insertion
      ;; below pairs with the single schedule-restore in
      ;; `ebox--smooth-scroll-stop'.  Wheel events that only add distance
      ;; to an active animation must not deepen the lease, or the depth
      ;; never returns to zero and the raised GC thresholds leak for the
      ;; rest of the session.
      (unless existing
        (ebox--deferred-render-gc-enter))
      (ebox--scroll-cancel-idle-prefetch region-id)
      (plist-put entry :pending pending)
      (when chain (plist-put entry :chain chain))
      (when index (plist-put entry :index index))
      (plist-put entry :direction (if (> pending 0) 1 -1))
      (plist-put entry :residual (or residual 0))
      (puthash region-id entry ebox--smooth-scroll-state-table)
      ;; Move the first tick immediately so the UI responds to the initial
      ;; event.  While a timer is already active, new wheel events only update
      ;; pending distance; the timer coalesces them into frame-sized edits.
      (unless had-timer
        (ebox--smooth-scroll-tick region-id))
      (when-let* ((entry (gethash region-id ebox--smooth-scroll-state-table)))
        (unless (timerp (plist-get entry :timer))
          (plist-put
           entry :timer
           (run-at-time ebox-wheel-smooth-scroll-interval
                        ebox-wheel-smooth-scroll-interval
                        #'ebox--smooth-scroll-tick region-id))
          (puthash region-id entry ebox--smooth-scroll-state-table)))
      t)))

(defun ebox--smooth-scroll-clear-regions (region-ids)
  "Stop smooth wheel scroll timers for REGION-IDS."
  (dolist (region-id region-ids)
    (ebox--smooth-scroll-stop region-id)))

(defun ebox--scroll-by (delta fallback)
  "Scroll box content by DELTA lines.  Positive = down, negative = up.
FALLBACK is the Emacs scroll command to call when ebox cannot scroll."
  (let ((native (ebox--native-buffer-scroll-at-point delta)))
    (if (not (memq native '(native-not-applicable native-unavailable)))
        (if (and (numberp native) (= native 0))
            (funcall fallback (abs delta))
          native)
      (ebox--scroll-consume-intent
       (ebox--scroll-intent-at-point delta)
       (lambda (residual)
         (funcall fallback (abs residual)))))))

(defun ebox--scroll-page-lines (&optional arg)
  "Return the number of content lines to move for a page scroll ARG."
  (if arg
      (prefix-numeric-value arg)
    (max ebox-scroll-step
         (- (window-body-height nil) next-screen-context-lines))))

(defun ebox--wheel-region-ids (event)
  "Return ebox scroll candidate region ids under mouse wheel EVENT."
  (when-let* ((start (ignore-errors (event-start event)))
              (window (posn-window start))
              ((window-live-p window)))
    (with-current-buffer (window-buffer window)
      (let* ((position (posn-point start))
             (ids
              (when (and (integer-or-marker-p position)
                         (< (point-min) (point-max)))
                (let ((pos (if (markerp position)
                               (marker-position position)
                             position)))
                  (ebox--scroll-region-ids-at-pos
                   (min (max pos (point-min))
                        (1- (point-max))))))))
        (or ids
            (ebox--scroll-region-ids-in-buffer-outer-first))))))

(defun ebox--wheel-region-id (event)
  "Return the innermost ebox region id under mouse wheel EVENT, or nil."
  (car (ebox--wheel-region-ids event)))

(defun ebox--scroll-region-can-consume-complete-p (region-id delta)
  "Return non-nil when REGION-ID can consume all signed DELTA now."
  (when-let* ((state (and region-id (ebox--scroll-get-state region-id))))
    (let* ((offset (or (plist-get state :scroll-offset) 0))
           (height (or (plist-get state :content-height) 0))
           (maximum (max 0 (- (length (plist-get state :content-lines))
                              height)))
           (available (if (> delta 0) (- maximum offset) offset)))
      ;; An incomplete lazy prefix is not proof of total capacity.  Route that
      ;; case through the synchronous chain allocator so any clamped movement
      ;; leaves an exact residual for the parent or native buffer.
      (>= available (abs delta)))))

(defun ebox--wheel-native-residual (event residual requested arg)
  "Send wheel RESIDUAL to ordinary buffer scrolling for EVENT.
When no ebox owner consumed REQUESTED, preserve Emacs' native wheel command.
For a partial residual, scroll its exact signed line count so the original
wheel event is not applied twice."
  (if (= residual requested)
      (mwheel-scroll event arg)
    (when-let* ((start (ignore-errors (event-start event)))
                (window (posn-window start))
                ((window-live-p window)))
      (with-selected-window window
        (condition-case nil
            (if (> residual 0)
                (scroll-up residual)
              (scroll-down (- residual)))
          ((beginning-of-buffer end-of-buffer) nil))))))

(defun ebox--wheel-scroll (event delta &optional arg smooth)
  "Scroll an ebox region under EVENT by DELTA, or delegate to `mwheel-scroll'.
When SMOOTH is non-nil, animate the scroll over short line steps."
  (let ((native
         (and (not (and smooth ebox-wheel-smooth-scroll))
              (ebox--native-buffer-scroll-at-event event delta))))
    (if (and native
             (not (memq native '(native-not-applicable native-unavailable))))
        (if (and (numberp native) (= native 0))
            (ebox--wheel-native-residual event delta delta arg)
          native)
      (let* ((intent (ebox--scroll-intent-at-event event delta))
             (region-ids (plist-get intent :chain))
             (region-id (and smooth
                             ebox-wheel-smooth-scroll
                             (ebox--first-scrollable-region
                              region-ids delta)))
             (smooth-index (and region-id (cl-position region-id region-ids
                                                       :test #'equal))))
        ;; Smooth animation is admitted only when one owner can consume the
        ;; whole intent.  Boundary-crossing input takes the synchronous chain
        ;; allocator, preserving residual distance instead of dropping it in
        ;; a region timer.
        (if (and region-id
                 (ebox--scroll-region-can-consume-complete-p
                  region-id delta))
            (ebox--smooth-scroll-region-by
             region-id delta region-ids smooth-index 0)
          (ebox--scroll-consume-intent
           intent
           (lambda (residual)
             (ebox--wheel-native-residual event residual delta arg))))))))

(defun ebox-wheel-scroll-down (event &optional arg)
  "Handle mouse wheel down EVENT in an ebox buffer.
Scrollable ebox content under the mouse consumes the event; otherwise delegate
to Emacs' normal `mwheel-scroll' so preview buffers keep native wheel speed."
  (interactive "e\nP")
  (ebox--wheel-scroll event ebox-wheel-scroll-step arg t))

(defun ebox-wheel-scroll-up (event &optional arg)
  "Handle mouse wheel up EVENT in an ebox buffer.
Scrollable ebox content under the mouse consumes the event; otherwise delegate
to Emacs' normal `mwheel-scroll' so preview buffers keep native wheel speed."
  (interactive "e\nP")
  (ebox--wheel-scroll event (- ebox-wheel-scroll-step) arg t))

;;;###autoload
(defun ebox-scroll-down (&optional n)
  "Scroll box content down by N lines.
When called from Lisp with nil N, use `ebox-scroll-step'."
  (interactive "p")
  (ebox--scroll-by (or n ebox-scroll-step) #'scroll-up))

;;;###autoload
(defun ebox-scroll-up (&optional n)
  "Scroll box content up by N lines.
When called from Lisp with nil N, use `ebox-scroll-step'."
  (interactive "p")
  (ebox--scroll-by (- (or n ebox-scroll-step)) #'scroll-down))

;;;###autoload
(defun ebox-scroll-page-down (&optional arg)
  "Scroll ebox content down by a page.
With prefix ARG, scroll by that many content lines."
  (interactive "P")
  (let ((delta (ebox--scroll-page-lines arg)))
    (ebox--scroll-by
     delta
     (lambda (n)
       (scroll-up-command n)))))

;;;###autoload
(defun ebox-scroll-page-up (&optional arg)
  "Scroll ebox content up by a page.
With prefix ARG, scroll by that many content lines."
  (interactive "P")
  (let ((delta (- (ebox--scroll-page-lines arg))))
    (ebox--scroll-by
     delta
     (lambda (n)
       (scroll-down-command n)))))

(defun ebox--region-id-at-pos (pos)
  "Return the owning ebox region-id at POS, if any."
  (cl-loop for (_type . prop) in ebox-region-types
           for region-id = (get-text-property pos prop)
           when region-id return region-id))

(defun ebox--clear-region-runtime-caches (region-ids)
  "Remove region-scoped runtime cache entries for REGION-IDS."
  (ebox--smooth-scroll-clear-regions region-ids)
  (dolist (region-id region-ids)
    (remhash region-id ebox--region-box-table)
    (ebox--scroll-clear-state region-id)))

(defun ebox--clear-buffer-runtime-state (&optional buffer)
  "Remove all runtime caches owned by BUFFER.
Defaults to the current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (ebox--cancel-buffer-runtime-prewarm buffer)
    (when-let* ((root (ebox--buffer-root-node buffer)))
      (ebox--clear-region-runtime-caches
       (ebox--node-all-region-ids root)))
    (ebox--clear-buffer-render-state buffer)))

(defun ebox--cleanup-current-buffer ()
  "Remove Ebox runtime state owned by the current buffer."
  (ebox--clear-buffer-runtime-state (current-buffer))
  (setq-local ebox-surface--buffer-surface nil))

(defun ebox--box-visible-overflow-p (box)
  "Return non-nil when BOX renders unowned visible overflow lines."
  (and (eq (ebox-get box :overflow) 'visible)
       (let* ((formatted-content (ebox--format-content box))
              (text-height (ebox-string-height formatted-content)))
         (> text-height (ebox--content-height box text-height)))))

(defun ebox--plist-remove (plist key)
  "Remove KEY and its value from PLIST, return new plist."
  (let ((result nil))
    (while plist
      (unless (eq (car plist) key)
        (push (car plist) result)
        (push (cadr plist) result))
      (setq plist (cddr plist)))
    (nreverse result)))

(defconst ebox--region-update-longhand-props
  '(:box-sizing
    :width :min-width :max-width
    :height :min-height :max-height
    :padding-left-pixel :padding-right-pixel
    :padding-top-height :padding-bottom-height
    :margin-left-pixel :margin-right-pixel
    :margin-top-height :margin-bottom-height
    :border-left-pixel :border-left-color
    :border-right-pixel :border-right-color
    :border-top-p :border-top-color
    :border-bottom-p :border-bottom-color
    :color :bgcolor
    :text-align :vertical-align
    :overflow :wrap-mode
    :scroll-offset :visibility)
  "Longhand box properties accepted by `ebox-region-update'.")

(defun ebox--region-update-normalize-property (property)
  "Return the box longhand field for region-update PROPERTY."
  (pcase property
    (:background-color :bgcolor)
    (_ property)))

(defun ebox--region-update-analysis (box expanded declarations)
  "Return change analysis for BOX, EXPANDED fields, and DECLARATIONS."
  (let (content-seen
        content-value
        style-changed-p
        unknown-keys)
    (cl-loop for (key value) on expanded by #'cddr
             for target-key = (ebox--region-update-normalize-property key)
             do
             (cond
              ((eq target-key :content)
               (setq content-seen t
                     content-value value))
              ((memq target-key ebox--region-update-longhand-props)
               (when (not (equal (ebox-get box target-key) value))
                 (setq style-changed-p t)))
              (t
               (push key unknown-keys))))
    (list :changed-p
          (or (not (equal declarations
                          (plist-get box :ebox-style-declarations)))
              style-changed-p
              (and content-seen
                   (not (equal (ebox-get box :content) content-value))))
          :unknown-keys (nreverse unknown-keys))))

(defun ebox--schedule-runtime-prewarm-after-batch-flush
    (buffer _pending _report)
  "Schedule shared runtime prewarming after BUFFER's batch flush."
  (unless ebox--native-scroll-prewarm-in-progress
    ;; The update already published its one allowed candidate.  Warm only
    ;; retained indexes here; native materialization belongs to the initial
    ;; display/visible-window handoff and would otherwise add a second
    ;; publication before the next input.
    (ebox--schedule-buffer-runtime-prewarm buffer nil t)))

(add-hook 'ebox-incremental--after-successful-batch-flush-hook
          #'ebox--schedule-runtime-prewarm-after-batch-flush t)


(defun ebox--surface-region-candidate-root
    (buffer state region-id &optional path-copy-p)
  "Return BUFFER's candidate root for REGION-ID.
Use a narrow copy-on-write path when PATH-COPY-P is proven safe; active batch
candidates are copied again before a second mutation so shared published nodes
cannot be changed through the unpublished batch root."
  (let ((batch-root (ebox-incremental-surface-batch-root buffer)))
    (or (and batch-root
             (ebox-tree-copy-node-structure batch-root))
        (and path-copy-p
             (ebox-incremental-surface-region-candidate-root
              buffer region-id))
        (ebox-tree-copy-node-structure (plist-get state :root-node)))))

(defun ebox--surface-region-apply-props
    (root region-id expanded declarations)
  "Apply DECLARATIONS then EXPANDED fields to REGION-ID in ROOT."
  (let ((box (ebox--root-region-box root region-id)) changed-keys)
    (unless box
      (user-error "Ebox region handle no longer resolves to a box"))
    (let ((declarations-changed
           (not (equal declarations
                       (plist-get box :ebox-style-declarations)))))
      (when declarations-changed
        (plist-put box :ebox-style-declarations declarations))
    (cl-loop for (key value) on expanded by #'cddr
             for target-key = (ebox--region-update-normalize-property key)
             when (or (eq target-key :content)
                      (memq target-key ebox--region-update-longhand-props))
             when (or (not (equal (ebox-get box target-key) value))
                      (and declarations-changed
                           (ebox-style-property key)))
             do (plist-put box target-key value)
             and do (push target-key changed-keys)))
    (nreverse changed-keys)))

(defun ebox--surface-region-no-op-report (state region-id handle)
  "Return and store a no-op report for STATE, REGION-ID, and HANDLE."
  (let ((report
         (ebox--update-report
          region-id 'no-op :region-handle handle :constraint-source 'region
          :runtime-published nil :runtime-revision
          (plist-get state :runtime-revision)
          :surface-revision
          (tp-surface-revision (plist-get state :surface))
          :dirty-count 0 :patch-count 0 :patch-ops nil)))
    (plist-put state :last-update-report report)
    report))

(defun ebox--surface-region-scroll-context (buffer region-id)
  "Return read-only scroll publication context for REGION-ID in BUFFER."
  (when-let* ((node (ebox--buffer-region-render-owner-node buffer region-id)))
    (let ((region-ids (ebox--node-all-region-ids node))
          states)
      (maphash
       (lambda (scroll-region-id state)
         (when (ebox--scroll-state-covers-node-p buffer state node)
           (push (cons scroll-region-id state) states)))
       ebox--scroll-global-state)
      (when states
        (let* ((visible (ebox--region-ids-visible-in-buffer-p
                         buffer region-ids))
               (deferred
                (and (not visible)
                     (cl-some
                      (lambda (entry)
                        (let ((state (cdr entry)))
                          (and (plist-get state :materialize-content-lines)
                               (not (ebox--scroll-hot-content-line-spans
                                     state region-ids)))))
                      states))))
          (list :node node :states states :visible visible
                :deferred deferred))))))

(defun ebox--surface-region-scroll-report (context changed-keys)
  "Return TP-era scroll report fields for CONTEXT and CHANGED-KEYS."
  (when-let* ((node (plist-get context :node)))
    (let* ((count (length (plist-get context :states)))
           (paint-p
           (eq (ebox--region-update-dirty-kind changed-keys) 'paint))
           (content-p (memq :content changed-keys))
           (deferred (plist-get context :deferred)))
      (cond
       (paint-p
        (list :strategy 'paint-patch
              :patch-ops '(paint-patch)
              :owner-id (plist-get node :node-id)
              :owner-ids (list (plist-get node :node-id))
              :lazy-scroll-deferred-patch nil
              :scroll-state-paint-sync t
              :scroll-state-sync-count count
              :scroll-state-index-preserved t))
       ((or content-p deferred)
        (list :strategy 'span-patch
              :patch-count (if deferred 0 1)
              :patch-ops (and (not deferred) '(span-patch))
              :owner-id (plist-get node :node-id)
              :owner-ids (list (plist-get node :node-id))
              :scroll-state-patch t
              :lazy-scroll-deferred-patch (and deferred t)))
       (t
        (list :scroll-state-sync t
              :scroll-state-sync-count count
              :scroll-state-sync-refreshed
              (and (plist-get context :visible) t)
              :scroll-state-sync-refreshed-count
              (if (plist-get context :visible) count 0)
              :scroll-state-sync-deferred nil
              :scroll-state-sync-deferred-count 0
              :scroll-state-patch
              (and (not (plist-get context :visible)) t)))))))

(defun ebox--surface-prepare-scroll-candidate (commit-input context)
  "Apply scroll CONTEXT state to isolated COMMIT-INPUT and return it."
  (when (plist-get context :deferred)
    (let ((table
           (plist-get (plist-get commit-input :state-overrides)
                      :scroll-state-table)))
      (dolist (entry (plist-get context :states))
        (when-let* ((state (gethash (car entry) table)))
          (plist-put state :lazy-scroll-prefix-dirty t)
          (puthash (car entry) state table)))))
  commit-input)

(defun ebox--surface-scroll-scope-node-ids
    (buffer context changed-keys)
  "Return BUFFER scroll owner ids required by CHANGED-KEYS in CONTEXT."
  (unless (eq (ebox--region-update-dirty-kind changed-keys) 'paint)
    (delete-dups
     (delq nil
           (mapcar
            (lambda (entry)
              (ebox--buffer-region-render-owner-node-id buffer (car entry)))
            (plist-get context :states))))))

(defun ebox--surface-scroll-changes (buffer pending)
  "Return scroll publication contexts for PENDING entries in BUFFER."
  (mapcar
   (lambda (entry)
     (list :region-id (plist-get entry :region-id)
           :changed-keys (plist-get entry :changed-keys)
           :context
           (ebox--surface-region-scroll-context
            buffer (plist-get entry :region-id))))
   pending))

(defun ebox--surface-prepare-scroll-changes (commit-input entries)
  "Apply every item in ENTRIES to isolated COMMIT-INPUT and return it."
  (dolist (change entries commit-input)
    (ebox--surface-prepare-scroll-candidate
     commit-input (plist-get change :context))))

(defun ebox--surface-scroll-change-scope-node-ids (buffer entries)
  "Return enclosing scroll owner ids for BUFFER using ENTRIES."
  (delete-dups
   (cl-loop for change in entries
            append
            (ebox--surface-scroll-scope-node-ids
             buffer (plist-get change :context)
             (plist-get change :changed-keys)))))

(defun ebox--surface-overflow-scope-node-ids (buffer node-ids entries)
  "Return BUFFER ancestors needed for NODE-IDS using overflow ENTRIES."
  (when (cl-some (lambda (change)
                   (memq :overflow (plist-get change :changed-keys)))
                 entries)
    (let ((parents (ebox--buffer-parent-table buffer)) ancestors)
      (dolist (node-id node-ids)
        (while (setq node-id (gethash node-id parents))
          (push node-id ancestors)))
      (delete-dups ancestors))))

(defun ebox--surface-content-scope-node-ids (buffer node-ids entries)
  "Return BUFFER parents needed for NODE-IDS using content ENTRIES."
  (when (cl-some (lambda (change)
                   (memq :content (plist-get change :changed-keys)))
                 entries)
    (let ((parents (ebox--buffer-parent-table buffer)))
      (delete-dups
       (delq nil
             (mapcar (lambda (node-id) (gethash node-id parents))
                     node-ids))))))

(defun ebox--publish-scoped-region-candidate
    (buffer candidate-root region-id changed-keys report-overrides
            &optional changes)
  "Publish BUFFER CANDIDATE-ROOT with REPORT-OVERRIDES.
REGION-ID and CHANGED-KEYS describe one update; CHANGES describes a batch."
  (let* ((state (ebox--buffer-render-state buffer)))
    (ebox--cancel-buffer-runtime-prewarm buffer)
    (ebox-incremental--notify-before-runtime-mutation buffer 'region-update)
    (unless (eq state (ebox--buffer-render-state buffer))
      (error "Ebox runtime changed during region update notification"))
    (let* ((ebox-viewport-width (plist-get state :viewport-width))
           (ebox-viewport-height (plist-get state :viewport-height))
           (scroll-context
            (and region-id
                 (ebox--surface-region-scroll-context buffer region-id)))
           (changes
            (or changes
                (and region-id
                     (list (list :region-id region-id
                                 :changed-keys changed-keys
                                 :context scroll-context)))))
           (report-overrides
            (append report-overrides
                    (ebox--surface-region-scroll-report
                     scroll-context changed-keys)))
           (commit-input
           (ebox--surface-prepare-scroll-changes
             (ebox-incremental-prepare-scoped-commit
              buffer candidate-root report-overrides t)
             changes))
           (scope-node-ids
            (let* ((planned
                    (copy-sequence (plist-get commit-input :scope-node-ids)))
                   (scroll
                    (ebox--surface-scroll-change-scope-node-ids
                     buffer changes)))
              (delete-dups
               (append planned scroll
                       (ebox--surface-content-scope-node-ids
                        buffer planned changes)
                       (ebox--surface-overflow-scope-node-ids
                        buffer planned changes)))))
           (surface
            (ebox-surface-update-buffer-scoped
             buffer
             (plist-get commit-input :root)
             scope-node-ids
             (plist-get commit-input :report-base)
             (plist-get commit-input :state-overrides)
             nil nil nil
             (plist-get commit-input :projection-kind)
             t)))
      (plist-get (tp-surface-client-state surface) :last-update-report))))

(defun ebox--publish-surface-region-batch (buffer candidate-root pending)
  "Publish BUFFER's accumulated CANDIDATE-ROOT for entries in PENDING."
  (let ((change (ebox-incremental--batch-change buffer pending)))
    (ebox--publish-scoped-region-candidate
     buffer candidate-root nil nil
     (append
      (ebox--constraint-change-report-props change)
      (list :region-ids
            (mapcar (lambda (entry) (plist-get entry :region-id)) pending)
            :region-handles
            (delq nil
                  (mapcar (lambda (entry)
                            (plist-get entry :region-handle))
                          pending))))
     (ebox--surface-scroll-changes buffer pending))))

(defun ebox--surface-region-update-target (buffer region-id handle props)
  "Apply PROPS to BUFFER REGION-ID through TP for optional HANDLE."
  (let* ((state (ebox--buffer-render-state buffer))
         (published-root (plist-get state :root-node))
         (candidate-box
          (or (ebox--root-region-box published-root region-id)
              (user-error "Ebox region handle no longer resolves to a box")))
         (expanded (ebox--expand-plist props))
         (declarations
          (ebox-style-merge-declarations
           (plist-get candidate-box :ebox-style-declarations)
           (ebox-style-compile-declarations props)))
         (old-style-values
          (and (plist-member expanded :overflow)
               (list :overflow (ebox-get candidate-box :overflow))))
         (analysis
          (ebox--region-update-analysis candidate-box expanded declarations)))
    (dolist (key (plist-get analysis :unknown-keys))
      (message "ebox-region-update: unknown key %S (ignored)" key))
    (if (not (plist-get analysis :changed-p))
        (unless (ebox-incremental-batching-p buffer)
          (ebox--surface-region-no-op-report state region-id handle))
      (if (and (not (ebox-incremental-batching-p buffer))
               (= (length expanded) 2)
               (eq (ebox--region-update-normalize-property (car expanded))
                   :scroll-offset))
          (ebox--surface-scroll-to-offset buffer region-id (cadr expanded))
        (let* ((content-only-p
                (and (= (length expanded) 2)
                     (eq (ebox--region-update-normalize-property
                          (car expanded))
                         :content)
                     (stringp (cadr expanded))
                     (numberp (ebox-get candidate-box :width))
                     (null (ebox-tree-node-children candidate-box))
                     (not (ebox-style-cascade-active-p))
                     (not (plist-get state :cascade-required-p))
                     (null (plist-get state :scroll-region-ids))))
               (candidate-root
                (ebox--surface-region-candidate-root
                 buffer state region-id content-only-p))
               (changed-keys
                (ebox--surface-region-apply-props
                 candidate-root region-id expanded declarations))
               (dirty-kind
                (ebox--region-update-dirty-kind changed-keys))
               (constraint-change
                (ebox--region-constraint-change
                 buffer region-id dirty-kind changed-keys)))
          (if (ebox-incremental-record-surface-region-change
               buffer candidate-root region-id handle dirty-kind
               changed-keys old-style-values
               #'ebox--publish-surface-region-batch)
              (progn
                (ebox--cancel-buffer-runtime-prewarm buffer)
                nil)
            (ebox--publish-scoped-region-candidate
             buffer candidate-root region-id changed-keys
             (append (if handle
                         (list :region-handle handle)
                       (list :region-id region-id))
                     (ebox--constraint-change-report-props
                      constraint-change)))))))))

(defun ebox--surface-region-update (handle props)
  "Apply PROPS to surface-scoped region HANDLE through one TP commit."
  (pcase-let ((`(,buffer . ,region-id)
               (ebox-selector--region-target handle)))
    (ebox--surface-region-update-target buffer region-id handle props)))

;;;###autoload
(defun ebox-region-update (handle &rest props)
  "Update the box identified by surface-scoped HANDLE with PROPS.
HANDLE must come from ebox-region-resolve or an Ebox selector result.  PROPS
accepts mutable content, style, and scroll keywords supported by the target;
it does not add children or mutate selector metadata.  The update builds an
isolated candidate, runs the Ebox owner planner, and publishes once through the
mounted TP surface.  Return nil while queued in an explicit batch; otherwise
return the committed update report.

Examples:
  (ebox-region-update (ebox-region-resolve buffer \"status\")
                      :content \"Ready\")
  (ebox-region-update handle :padding (list 1 2)
                      :border-color \"red\")"
  (unless (ebox-region-handle-p handle)
    (signal (quote wrong-type-argument)
            (list (quote ebox-region-handle-p) handle)))
  (ebox--with-render-gc
    (ebox--surface-region-update handle props)))

(defvar ebox-scroll-map nil
  "Keymap for scroll interaction within ebox.")

(setq ebox-scroll-map
      (let ((map (make-sparse-keymap)))
        (dolist (area '(nil right-fringe left-fringe right-margin left-margin
                            vertical-scroll-bar horizontal-scroll-bar
                            mode-line header-line tool-bar))
          (let ((prefix (if area (vector area) [])))
            (dolist (event '(wheel-down double-wheel-down triple-wheel-down
                             mouse-5))
              (define-key map (vconcat prefix (vector event))
                          #'ebox-wheel-scroll-down))
            (dolist (event '(wheel-up double-wheel-up triple-wheel-up
                             mouse-4))
              (define-key map (vconcat prefix (vector event))
                          #'ebox-wheel-scroll-up))))
        (define-key map [remap scroll-up-command] #'ebox-scroll-page-down)
        (define-key map [remap scroll-down-command] #'ebox-scroll-page-up)
        (define-key map (kbd "n") #'ebox-scroll-down)
        (define-key map (kbd "p") #'ebox-scroll-up)
        (dolist (key '("C-v" "<next>" "<kp-next>" "SPC"))
          (define-key map (kbd key) #'ebox-scroll-page-down))
        (dolist (key '("M-v" "<prior>" "<kp-prior>" "S-SPC" "<backspace>"))
          (define-key map (kbd key) #'ebox-scroll-page-up))
        (define-key map (kbd "q") #'quit-window)
        map))

(defconst ebox--scroll-overridden-minor-modes
  '(pixel-scroll-precision-mode pixel-scroll-mode)
  "Minor modes whose scroll bindings should not override ebox buffers.")

(defun ebox--install-scroll-map-overrides ()
  "Make ebox scroll bindings win over global pixel-scroll bindings locally."
  (setq-local minor-mode-overriding-map-alist
              (cl-remove-if
               (lambda (entry)
                 (memq (car entry) ebox--scroll-overridden-minor-modes))
               minor-mode-overriding-map-alist))
  (dolist (mode ebox--scroll-overridden-minor-modes)
    (push (cons mode ebox-scroll-map)
          minor-mode-overriding-map-alist)))

(defun ebox--clear-scroll-map-overrides ()
  "Remove ebox-local scroll binding overrides from the current buffer."
  (setq-local minor-mode-overriding-map-alist
              (cl-remove-if
               (lambda (entry)
                 (memq (car entry) ebox--scroll-overridden-minor-modes))
               minor-mode-overriding-map-alist)))

;;;###autoload
(define-minor-mode ebox-buffer-mode
  "Minor mode for interactive ebox buffers."
  :lighter " Ebox"
  :keymap ebox-scroll-map
  (if ebox-buffer-mode
      (ebox--install-scroll-map-overrides)
    (ebox--clear-scroll-map-overrides)))

;;;###autoload
(defun ebox-render-to-buffer (buffer-or-name node)
  "Render layout NODE into BUFFER-OR-NAME and return the buffer.
NODE can be any box/concat/stack node created by `ebox-create',
`ebox-concat', or `ebox-stack', or a pre-rendered string."
  (declare (indent 1))
  (unless (stringp node)
    ;; Validate opaque host identities before preparing a target generation.
    (ebox-tree-validate-host-refs node))
  (let ((buffer (get-buffer-create buffer-or-name)))
    (ebox--with-render-gc
      (ebox-surface-mount-buffer buffer node)
      (with-current-buffer buffer
        (goto-char (point-min))
        (add-hook 'kill-buffer-hook #'ebox--cleanup-current-buffer nil t)
        (ebox-buffer-mode 1)
        (read-only-mode 1)
        (ebox--schedule-buffer-runtime-prewarm buffer nil nil)
        buffer))))

(defun ebox--host-ref-buffer (buffer-or-name)
  "Return the live buffer named by BUFFER-OR-NAME, or nil."
  (let ((buffer (and buffer-or-name (get-buffer buffer-or-name))))
    (and (buffer-live-p buffer) buffer)))

(defun ebox--host-ref-node (buffer host-ref)
  "Return BUFFER's runtime node indexed by opaque HOST-REF."
  (when-let* ((table (ebox--buffer-host-ref-table buffer))
              (node-id (gethash host-ref table)))
    (ebox--buffer-runtime-node buffer node-id)))

(defun ebox--host-ref-role-bounds (buffer node)
  "Return NODE's margin-free role bounds in BUFFER, or nil."
  (let (start end)
    (dolist (region-id (ebox--node-all-region-ids node))
      (when-let* ((bounds
                  (ebox-surface-region-bounds
                   buffer region-id ebox--horizontal-border-anchor-roles)))
        (setq start (if start (min start (car bounds)) (car bounds))
              end (if end (max end (cdr bounds)) (cdr bounds)))))
    (and start end (cons start end))))

(defun ebox--host-ref-mount-bounds (buffer node)
  "Return fallback TP mount bounds for NODE in BUFFER, or nil."
  (let (start end)
    (dolist (region-id (ebox--node-all-region-ids node))
      (when-let* ((bounds (ebox-surface-region-bounds buffer region-id)))
        (setq start (if start (min start (car bounds)) (car bounds))
              end (if end (max end (cdr bounds)) (cdr bounds)))))
    (and start end (< start end) (cons start end))))

;;;###autoload
(defun ebox-host-ref-bounds (buffer-or-name host-ref)
  "Return live integer bounds for HOST-REF in BUFFER-OR-NAME.

The result is a `(START . END)' pair spanning the referenced runtime node's
rendered border-box characters (excluding margins), or nil when the buffer,
reference, or live TP mounts no longer exist.  HOST-REF is opaque and
compared with `equal'."
  (when-let* ((buffer (ebox--host-ref-buffer buffer-or-name))
              (node (ebox--host-ref-node buffer host-ref)))
    (or (ebox--host-ref-role-bounds buffer node)
        (ebox--host-ref-mount-bounds buffer node))))

;;;###autoload
(defun ebox-host-ref-position (buffer-or-name host-ref)
  "Return HOST-REF's first live position in BUFFER-OR-NAME, or nil.
See `ebox-host-ref-bounds' for lookup and lifetime semantics."
  (car-safe (ebox-host-ref-bounds buffer-or-name host-ref)))

;;;###autoload
(defun ebox-candidate-begin (buffer-or-name)
  "Begin a one-shot logical transaction from BUFFER-OR-NAME's exact runtime."
  (let ((buffer (get-buffer buffer-or-name)))
    (unless (buffer-live-p buffer)
      (error "Ebox candidate requires an existing live buffer: %S"
             buffer-or-name))
    (ebox-incremental-candidate-begin buffer)))

;;;###autoload
(defun ebox-range-ref-present-p (buffer-or-name range-ref)
  "Return non-nil when RANGE-REF is a live mounted address in BUFFER-OR-NAME.

This is a read-only boundary query for framework integrations.  It does not
create a candidate or expose Ebox's runtime tables; a caller should fall back
to its wider owner when a semantic Range has no corresponding published
address."
  (when-let* ((buffer (get-buffer buffer-or-name))
              (state (ebox--buffer-render-state buffer))
              (table (plist-get state :range-ref-table)))
    (and (hash-table-p table)
         (gethash range-ref table))))

;;;###autoload
(defun ebox-child-range (range-ref &rest items)
  "Return an owned child Range descriptor for non-nil RANGE-REF and ITEMS.
ITEMS are declarative nodes.  Child Range descriptors cannot be nested."
  (unless range-ref (error "Ebox child Range ref must be non-nil"))
  (dolist (item items)
    (unless (and (listp item) (not (stringp item)))
      (error "Ebox child Range item must be a declarative node"))
    (cl-labels ((reject-range
                 (node)
                 (when (ebox-child-range--descriptor-p node)
                   (error "Ebox child Range descriptors cannot be nested"))
                 (when (and (listp node) (not (stringp node)))
                   (dolist (child (ebox-tree--children-raw node))
                     (reject-range child)))))
      (reject-range item)))
  (ebox-tree-validate-declarative-root
   (list :ebox-type 'stack :display '(block column) :children items))
  (ebox-child-range--descriptor-create
   range-ref
   (mapcar (lambda (item)
             (ebox-tree-clear-runtime-identities
              (ebox-tree-copy-node-structure item)))
           items)))

;;;###autoload
(defun ebox-candidate-replace
    (candidate node-id next-subtree
               &optional old-semantic-key new-semantic-key)
  "Replace NODE-ID in CANDIDATE with declarative NEXT-SUBTREE.
OLD-SEMANTIC-KEY and NEW-SEMANTIC-KEY may identify a stable anchor's detached
semantic variants so a later return can reuse bounded runtime identity.
Return CANDIDATE for convenient transaction construction."
  (ebox-incremental-candidate-replace
   candidate node-id next-subtree old-semantic-key new-semantic-key))

;;;###autoload
(defun ebox-candidate-replace-host-ref
    (candidate host-ref next-subtree
               &optional old-semantic-key new-semantic-key)
  "Replace HOST-REF in CANDIDATE with declarative NEXT-SUBTREE.
HOST-REF is resolved against the exact published runtime captured by
`ebox-candidate-begin'.  OLD-SEMANTIC-KEY and NEW-SEMANTIC-KEY have the same
optional detached-identity meaning as in `ebox-candidate-replace'.
Return CANDIDATE."
  (ebox-incremental-candidate-replace-host-ref
   candidate host-ref next-subtree old-semantic-key new-semantic-key))

;;;###autoload
(defun ebox-candidate-patch-host-paint
    (candidate host-ref previous-subtree next-subtree)
  "Patch HOST-REF paint from declarative OLD/NEW subtrees in CANDIDATE.
Only node-local paint fields may differ.  The Host's children and runtime
identities are retained instead of being copied as a replacement subtree.
Return CANDIDATE when accepted, or nil when the delta needs ordinary subtree
replacement."
  (ebox-incremental-candidate-patch-host-paint
   candidate host-ref previous-subtree next-subtree))

;;;###autoload
(defun ebox-candidate-replace-range-ref
    (candidate range-ref next-items &optional reuse-map)
  "Replace RANGE-REF, retaining slots named by proven REUSE-MAP."
  (ebox-incremental-candidate-replace-range-ref
   candidate range-ref next-items reuse-map))

;;;###autoload
(defun ebox-candidate-replace-root (candidate next-root)
  "Replace CANDIDATE's exact implicit root with declarative NEXT-ROOT.
The root address is private, base-bound, and cannot collide with host refs.
Repeated calls are last-wins and absorb all descendant candidate operations."
  (ebox-incremental-candidate-replace-root candidate next-root))

;;;###autoload
(defun ebox-commit
    (buffer-or-name next-root &optional framework-publish framework-rollback)
  "Atomically commit declarative NEXT-ROOT into BUFFER-OR-NAME.

NEXT-ROOT may be a newly built Ebox node tree or a one-shot logical candidate
from `ebox-candidate-begin'.  A complete root is copied into a buffer-owned
runtime.  A logical candidate path-copies replaced ancestor chains, shares
untouched subtrees, and isolates retained scroll nodes before proof rendering.
Both forms reconcile Ebox-owned identity,
prove rendered owners in isolation, and publish only property-aware buffer
differences.  Validation, render, and publication failures leave the current
buffer and runtime unchanged.

When FRAMEWORK-PUBLISH is non-nil, it must be a function of one update report.
Ebox invokes it inside the quit-free atomic publication boundary after the
buffer and runtime agree.  This hook is for framework pointer promotion only;
it must not run application code.  An error rolls the Ebox publication back.
FRAMEWORK-ROLLBACK, when supplied, receives the same report if publication or
a later transaction phase fails, and is contained if it violates no-throw.

Return the successful publication report stored by `ebox-buffer-update-report'."
  (let ((execute
         (lambda ()
           (unless (or (null framework-publish) (functionp framework-publish))
             (signal 'wrong-type-argument (list 'functionp framework-publish)))
           (unless (or (null framework-rollback)
                       (functionp framework-rollback))
             (signal 'wrong-type-argument (list 'functionp framework-rollback)))
           (when (and framework-rollback (null framework-publish))
             (error "Ebox framework rollback requires framework publish"))
           (let ((buffer (get-buffer buffer-or-name)))
             (unless (buffer-live-p buffer)
               (error
                "Ebox declarative commit requires an existing live buffer: %S"
                buffer-or-name))
             (let* ((commit-input
                     (if (ebox-candidate-p next-root)
                         (ebox-incremental-consume-candidate buffer next-root)
                       (ebox-incremental-prepare-root-commit buffer next-root)))
                    (source (plist-get commit-input :root))
                    (callback
                     (or framework-publish
                         ebox-incremental--after-declarative-publication))
                    (participant
                     (ebox-surface--make-framework-participant
                      :publish callback :rollback framework-rollback
                      :state 'unpublished :diagnostics nil))
                    (_surface
                     (if-let* ((scope-node-ids
                               (plist-get commit-input :scope-node-ids)))
                         (ebox-surface-update-buffer-scoped
                          buffer source scope-node-ids
                          (plist-get commit-input :report-base)
                          (plist-get commit-input :state-overrides)
                          callback
                          (plist-get commit-input :on-mismatch)
                          nil
                          (plist-get commit-input :projection-kind)
                          t participant)
                       (ebox-surface-mount-buffer
                        buffer source
                        (plist-get commit-input :report-base)
                        callback
                        (plist-get commit-input :preserve-identities-p)
                        (plist-get commit-input :state-overrides)
                        participant))))
               (ebox-surface--framework-participant-report participant))))))
    (if noninteractive
        (ebox--with-render-gc
          (funcall execute))
      (ebox--with-deferred-render-gc
        (funcall execute)))))

;;;###autoload
(defun ebox-rerender-buffer-with-context
    (buffer viewport-width &optional viewport-height)
  "Rerender BUFFER's stored runtime tree using VIEWPORT-WIDTH.
When VIEWPORT-HEIGHT is non-nil, height values using `(viewport-height)' are
resolved against that line count.
This preserves node and region identity and routes viewport-dependent changes
through dirty-set and patch-set execution before falling back to root rerender."
  (let ((execute
         (lambda ()
           (let* ((state (ebox--buffer-render-state buffer))
                  (old-viewport-width
                   (and state (plist-get state :viewport-width))))
             (unless (ebox-surface-buffer-mounted-p buffer)
               (user-error "Ebox buffer has no mounted TP surface: %S" buffer))
             (ebox--cancel-buffer-runtime-prewarm buffer)
             (prog1
                 (ebox-surface-update-buffer-viewport
                  buffer viewport-width viewport-height)
               (ebox--schedule-buffer-runtime-prewarm buffer nil t)
               (ebox--schedule-buffer-reflow-cache-prewarm
                buffer old-viewport-width viewport-width))))))
    (if noninteractive
        (ebox--with-render-gc
          (funcall execute))
      (ebox--with-deferred-render-gc
        (funcall execute)))))

(defun ebox--rerender-buffer-preserving-runtime (buffer)
  "Rerender BUFFER from stored runtime state without rebuilding identity."
  (let ((state (ebox--buffer-render-state buffer)))
    (unless state
      (user-error "Ebox buffer has no rendered runtime: %S" buffer))
    (ebox-rerender-buffer-with-context
     buffer (plist-get state :viewport-width)
     (plist-get state :viewport-height))))

;;;###autoload
(defun ebox-display-buffer (buffer-or-name node)
  "Render NODE to BUFFER-OR-NAME through TP and display the buffer."
  (declare (indent 1))
  (delete-other-windows)
  (switch-to-buffer (ebox-render-to-buffer buffer-or-name node)))

(defconst ebox-public-api
  '(ebox-buffer-mode
    ebox-buffer-update-report
    ebox-build
    ebox-byte-compile
    ebox-call-with-render-burst
    ebox-candidate-begin
    ebox-child-range
    ebox-candidate-replace
    ebox-candidate-replace-range-ref
    ebox-candidate-replace-root
    ebox-candidate-replace-host-ref
    ebox-candidate-patch-host-paint
    ebox-clear-cache
    ebox-column
    ebox-column-layout-create
    ebox-normal-layout-create
    ebox-row-layout-create
    ebox-text-create
    ebox-box-create
    ebox-commit
    ebox-concat
    ebox-create
    ebox-display-buffer
    ebox-display-signature
    ebox-flex
    ebox-flex-item
    ebox-grid
    ebox-grid-fr
    ebox-grid-item
    ebox-host-ref-bounds
    ebox-host-ref-position
    ebox-native-build
    ebox-native-status
    ebox-region-ids
    ebox-region-resolve
    ebox-region-update
    ebox-render
    ebox-render-burst-begin
    ebox-render-burst-end
    ebox-render-to-buffer
    ebox-rerender-buffer-with-context
    ebox-row
    ebox-scroll-down
    ebox-scroll-map
    ebox-scroll-page-down
    ebox-scroll-page-up
    ebox-scroll-state
    ebox-scroll-up
    ebox-select-all
    ebox-selector-match-node-p
    ebox-selector-parse
    ebox-selector-query-all
    ebox-selector-query-buffer
    ebox-selector-update-buffer
    ebox-spacer
    ebox-stack
    ebox-string-pixel-width
    ebox-update-selector
    ebox-viewport-window-width
    ebox-wheel-scroll-down
    ebox-wheel-scroll-up)
  "Stable core Ebox entry points available to applications and tooling.
This inventory includes the public autoloaded constructors, render/update
commands, selector/scroll helpers, measurement accessors, Grid helpers, and
optional native workflow commands.  Style-rule helpers live in `ebox-style.el'
and are documented separately in the public API reference.")

(defconst ebox-feature-families
  '(box-model
    declarative-commit
    direct-region-update
    dsl
    failure-atomic-rollback
    framework-render-burst
    flex-layout
    host-reference
    intrinsic-and-viewport-sizing
    logical-candidate
    native-reflow
    overflow-and-wrapping
    paint-and-text-properties
    prepared-publication
    render-cache
    scroll-window
    selector-runtime-index
    stable-runtime-identity
    surface-properties
    viewport-reflow)
  "Stable high-level Ebox capability families used by conformance tooling.")

(provide 'ebox)
;;; ============================================================
;;; Public API Summary
;;; ============================================================
;; The complete facade inventory is `ebox-public-api'.  Style-rule entry points
;; are defined in `ebox-style.el' and the user-facing inventory is maintained
;; in `docs/user/ebox-api-reference.en.md` and its Chinese counterpart.
;; All other ebox-- prefixed functions are internal implementation details.
;;
;; ── Creation ──────────────────────────────────────────────────
;;   ebox-text-create :value string &rest canonical-measurement-props
;;       Create one typed canonical TextNode.
;;   ebox-normal-layout-create
;;       Create the typed Normal LayoutConfig.
;;   ebox-box-create :layout config :children nodes &rest geometry-props
;;       Create one typed canonical BoxNode.  The current vertical slice
;;       accepts Normal layout with zero or one canonical child.
;;   ebox-create &rest plist
;;       Legacy untyped runtime constructor retained during migration.
;;       Key options: :content :width :height
;;       :padding :margin :border :border-color :bgcolor
;;       :text-align :wrap-mode :box-sizing :surface-properties :host-ref
;;   ebox-build dsl
;;       Compile ETML-style (box/row/column/flex/item/spacer ...) forms into
;;       normal ebox layout nodes.
;;
;; ── Layout ────────────────────────────────────────────────────
;;   ebox-concat left right      → horizontal side-by-side
;;   ebox-stack  top  bottom     → vertical stacking (nest for 3+)
;;   ebox-row    &rest nodes     → horizontal layout from many nodes
;;   ebox-column &rest nodes     → vertical layout from many nodes
;;   ebox-spacer &rest plist     → blank box node
;;   ebox-flex   &rest items     → flex layout from boxes/items
;;       Container may also carry normal ebox-create box properties.
;;   ebox-flex-item node &rest plist
;;       Attach :order :flex-grow :flex-shrink :flex-basis :flex
;;       and :align-self metadata to a child node; non-flex properties
;;       wrap the child in an ebox-create box.
;;
;; ── Rendering ─────────────────────────────────────────────────
;;   ebox-render box              → propertized string (no buffer side-effect)
;;   ebox-render-to-buffer buf box → insert into buffer, returns buffer
;;   ebox-commit buf next-root     → atomically publish a declarative root
;;   ebox-candidate-begin buf      → begin a one-shot logical transaction
;;   ebox-candidate-replace cand id root &optional old-key new-key
;;                                → replace one runtime node logically
;;   ebox-candidate-replace-host-ref cand ref root &optional old-key new-key
;;                                → replace one semantic host boundary
;;   ebox-candidate-patch-host-paint cand ref old-root new-root
;;                                → patch paint without replacing its subtree
;;   ebox-display-buffer buf box   → render through TP and display the buffer
;;   ebox-host-ref-position buf ref → first live position for :host-ref
;;   ebox-host-ref-bounds buf ref   → live (START . END) bounds for :host-ref
;;
;; ── Region IDs ────────────────────────────────────────────────
;;   ebox-region-ids layout       → list of region-ids in document order
;;                                   call BEFORE render-to-buffer
;;
;; ── Dynamic Updates (call inside with-current-buffer + inhibit-read-only) ──
;;   ebox-region-update handle &rest props
;;       Single entry-point for all dynamic changes.  HANDLE comes from
;;       ebox-region-resolve or a selector match's :region-handle field;
;;       numeric region ids are not update handles.
;;
;; ── Scroll ────────────────────────────────────────────────────
;;   ebox-scroll-up   &optional n
;;   ebox-scroll-down &optional n
;;   ebox-scroll-map  (keymap, bind to buffer local map)
;;
;; ── Cache ─────────────────────────────────────────────────────
;;   ebox-clear-cache

;;; ebox.el ends here
