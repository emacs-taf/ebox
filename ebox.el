;;; ebox.el --- Pixel-perfect box model renderer -*- lexical-binding: t -*-

;; Author: ebox contributors
;; Version: 1.0.1
;; Package-Requires: ((emacs "29.1") (tp "1.0.0"))
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
  '("ebox-cache.el" "ebox-style.el" "ebox-tree.el" "ebox-measure.el"
    "ebox-fragment.el" "ebox-render-context.el" "ebox-layout.el"
    "ebox-flex.el" "ebox-grid.el" "ebox-buffer-backend.el" "ebox-incremental.el"
    "ebox-surface.el" "ebox-dsl.el" "ebox-selector.el" "ebox.el"
    "ebox-native-reflow.el")
  "Active Ebox Lisp sources compiled by `ebox-byte-compile'.")

(add-to-list 'load-path ebox--directory)

(require 'cl-lib)
(require 'mwheel)
(require 'seq)
(require 'subr-x)
(require 'ebox-cache)
(require 'ebox-style)
(require 'ebox-tree)
(require 'ebox-measure)
(require 'ebox-fragment)
(require 'ebox-render-context)
(require 'ebox-layout)
(require 'ebox-flex)
(require 'ebox-grid)
(require 'ebox-buffer-backend)
(require 'ebox-incremental)
(require 'ebox-surface)
(require 'ebox-dsl)
(require 'ebox-selector)

(declare-function ebox--buffer-update-report "ebox-incremental" (buffer))
(declare-function ebox--set-buffer-update-report
                  "ebox-incremental" (buffer report))

(unless (fboundp 'ebox-native-build)
  (autoload 'ebox-native-build "ebox-native-reflow" nil t))
(unless (fboundp 'ebox-native-status)
  (autoload 'ebox-native-status "ebox-native-reflow" nil t))
(autoload 'ebox-native-reflow-render-owner-proof "ebox-native-reflow")
(setq ebox-buffer-owner-proof-renderer
      #'ebox-native-reflow-render-owner-proof)

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

(defcustom ebox-wheel-scroll-step 16
  "Default number of lines moved by one vertical mouse wheel event.
This is separate from `ebox-scroll-step' so keyboard fine scrolling can stay
precise while real mouse and trackpad scrolling feels responsive."
  :type 'positive-integer
  :group 'ebox)

(defcustom ebox-wheel-smooth-scroll t
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
This keeps repeated fine scroll steps on the marker-window patch path without
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
(defvar ebox-region-types)
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
(defvar ebox--reflow-cache-prewarm-timers (make-hash-table :test 'eq)
  "Buffer-keyed idle timers for predicted reflow-cache warming.")
(defvar ebox--scroll-prefetch-delay-override nil
  "Dynamically bound delay for scroll prefix prefetch scheduling.")
(defvar ebox--region-update-buffer-hint nil
  "Optional buffer hint for internal selector-driven region updates.")

(defsubst ebox--next-region-id ()
  "Generate next unique region ID."
  (cl-incf ebox--region-id-counter))

(defconst ebox--longhand
  '( :content ""
     :box-sizing border-box ;; content-box or border-box

     ;; 所有宽度的单位是像素，所有高度的单位是行数
     :width nil :min-width 0 :max-width nil
     :height nil :min-height 0 :max-height nil

     :padding-left-pixel 0 :padding-right-pixel 0
     :padding-top-height 0 :padding-bottom-height 0
     :margin-left-pixel 0 :margin-right-pixel 0
     :margin-top-height 0 :margin-bottom-height 0

     ;; 左右边框支持设置宽度
     :border-left-pixel 0 :border-left-color nil
     :border-right-pixel 0 :border-right-color nil
     ;; 上下边框由于 Emacs 限制，用 overline/underline 实现，不支持设置宽度
     :border-top-p nil :border-top-color nil
     :border-bottom-p nil :border-bottom-color nil

     :color nil
     :bgcolor nil
     :text-align left :vertical-align top
     ;; supports: 'visible / 'hidden / 'scroll
     :overflow scroll
     ;; supports: 'visible / 'hidden — hidden suppresses ink while the
     ;; layout footprint, buffer text, and metadata stay identical
     :visibility visible
     ;; supports: 'word / 'char / 'kp
     :wrap-mode word
     :scroll-offset 0 ;; 当前滚动偏移（行数）
     )
  "Default plist for a box structure (longhand properties only).")

(defun ebox--longhand-create (&optional plist)
  "Create a shorthand box structure.
PLIST is a property list that overrides the defaults."
  (let ((box (copy-sequence ebox--longhand)))
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (plist-put box key value)))
    box))

(defsubst ebox-get (box property)
  "Retrieve PROPERTY from BOX."
  (plist-get box property))

(defsubst ebox-put (box property value)
  "Set PROPERTY to VALUE in BOX and return the modified box."
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
        (when-let ((id (get-text-property pos 'ebox-content string)))
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
      (when-let ((id (get-text-property pos 'ebox-content string)))
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
        (cons (ebox--ensure-region-id node)
              (ebox-region-ids (plist-get node :ebox-content-node))))
       ((eq type 'concat)
        (apply #'append
               (mapcar #'ebox-region-ids
                       (ebox--layout-children node))))
       ((eq type 'stack)
        (apply #'append
               (mapcar #'ebox-region-ids
                       (ebox--layout-children node))))
       ((eq type 'flex)
        (if-let ((box (plist-get node :box)))
            (list (ebox--ensure-region-id box))
          (apply #'append
                 (mapcar #'ebox-region-ids (plist-get node :children)))))
       ((eq type 'grid)
        (if-let ((box (plist-get node :box)))
            (list (ebox--ensure-region-id box))
          (apply #'append
                 (mapcar #'ebox-region-ids (plist-get node :children)))))
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
      (when-let ((key (ebox--runtime-node-key child)))
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
  (when-let ((key (ebox--runtime-node-key new-child)))
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

(defmacro ebox--to-buffer (buffer-or-name switch-fn &rest body)
  "Render into BUFFER-OR-NAME using SWITCH-FN, executing BODY."
  (declare (indent 2))
  `(let ((buffer (get-buffer-create ,buffer-or-name)))
     (with-current-buffer buffer
       (let ((inhibit-read-only t))
         (erase-buffer)
         ,@body)
       (local-set-key "q" (lambda () (interactive)
                            (local-unset-key "q")
                            (quit-window)))
       (read-only-mode 1)
       (funcall ,switch-fn buffer))))

(defmacro ebox-pop-to-buffer (buffer-or-name &rest body)
  (declare (indent defun))
  `(ebox--to-buffer ,buffer-or-name #'pop-to-buffer ,@body))

(defmacro ebox-switch-to-buffer (buffer-or-name &rest body)
  (declare (indent defun))
  `(ebox--to-buffer ,buffer-or-name #'switch-to-buffer ,@body))

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

;;;###autoload
(defun ebox-create (&rest plist)
  "Create a box from PLIST. Supports all shorthand and longhand properties.
Properties are expanded recursively according to `ebox-property-rules'."
  (let ((expanded (ebox--expand-plist plist))
        (controlled-scroll-offset-p (plist-member plist :scroll-offset)))
    (let ((box (ebox--longhand-create expanded)))
      (plist-put box :ebox-type 'box)
      (plist-put box :display '(block flow))
      (when controlled-scroll-offset-p
        (plist-put box :ebox-scroll-offset-controlled-p t))
      box)))

;;; ============================================================
;;; Buffer Runtime State & Scroll State
;;; ============================================================

;; Incremental runtime model boundaries:
;; - Source Tree Model: user/DSL plists with stable :region-id and :node-id.
;; - Render Context Model: dynamic bindings such as `ebox-viewport-width'.
;; - Buffer Runtime Model: per-buffer root node, viewport, and node indexes.
;; - Layout Snapshot Model: derived render facts used for diffing.
;; - Dirty/Patch Model: executable update choices for buffer edits.
;;
;; Dynamic render-local, flex-local, and snapshot-detail-local caches are
;; optimizations.  Do not make them public API or component-owned state.

(defvar ebox--region-box-table (make-hash-table :test 'equal)
  "Maps region-id to its box definition for dynamic content updates.")

(defvar ebox--box-extents (make-hash-table :test 'equal)
  "Maps region-id to (start-marker . end-marker) for contiguous box roots.
Only boxes occupying one contiguous buffer slice are stored here.")

(defvar-local ebox--box-extent-template nil
  "Prepared numeric box extents for the current root publication.")

(defvar ebox--defer-scroll-content-index nil
  "Non-nil means full scroll content indexes are built lazily.")

(defun ebox--scroll-get-state (region-id)
  "Get scroll state for REGION-ID."
  (gethash region-id ebox--scroll-global-state))

(defun ebox--scroll-cancel-idle-prefetch (region-id)
  "Cancel any pending idle prefix prefetch for REGION-ID."
  (when-let ((timer (gethash region-id ebox--scroll-idle-prefetch-timers)))
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
  (+ (or (when-let ((idle (current-idle-time)))
           (float-time idle))
         0)
     (max 0 (or delay 0))))

(defun ebox--scroll-schedule-idle-prefetch (region-id &optional delay)
  "Schedule input-yielding lazy prefix prefetch for REGION-ID when useful."
  (ebox--scroll-cancel-idle-prefetch region-id)
  (when-let ((state (and (or (not noninteractive)
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
  (when-let ((entry (gethash region-id ebox--smooth-scroll-state-table)))
    (and (timerp (plist-get entry :timer))
         (not (plist-get entry :waiting-prefetch)))))

(defun ebox--smooth-scroll-resume-after-prefetch (region-id)
  "Resume REGION-ID smooth scrolling after a paused lazy prefetch."
  (when-let ((entry (gethash region-id ebox--smooth-scroll-state-table)))
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
    (when-let ((state (ebox--scroll-get-state region-id)))
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

(defun ebox--scroll-content-marker-spans (markers)
  "Return MARKERS as a plain list of marker span conses."
  (cond
   ((vectorp markers) (append markers nil))
   ((listp markers) markers)
   (t nil)))

(defun ebox--scroll-line-spans-in-window (start line-count)
  "Return LINE-COUNT line spans starting at START in one forward scan."
  (save-excursion
    (goto-char start)
    (cl-loop repeat line-count
             collect (cons (point) (line-end-position))
             do (forward-line 1))))

(defun ebox--scroll-clear-content-markers (state)
  "Detach content span markers stored in scroll STATE."
  (dolist (span (ebox--scroll-content-marker-spans
                 (plist-get state :content-span-markers)))
    (when (consp span)
      (when (markerp (car span))
        (set-marker (car span) nil))
      (when (markerp (cdr span))
        (set-marker (cdr span) nil)))))

(defun ebox--scroll-clear-rendered-window-markers (state)
  "Detach rendered scroll window boundary markers stored in STATE."
  (when-let ((start (plist-get state :rendered-window-start-marker)))
    (when (markerp start)
      (set-marker start nil)))
  (when-let ((end (plist-get state :rendered-window-end-marker)))
    (when (markerp end)
      (set-marker end nil))))

(defun ebox--scroll-store-rendered-window-extents
    (buffer region-id state start end line-count)
  "Store lightweight rendered window extents for REGION-ID.
Unlike content span markers, these two markers are cheap enough for the scroll
hot path and are sufficient to anchor the next viewport replacement."
  (when (and (buffer-live-p buffer)
             (integer-or-marker-p start)
             (integer-or-marker-p end)
             (integerp line-count)
             (> line-count 0))
    (with-current-buffer buffer
      (let ((start-pos (if (markerp start) (marker-position start) start))
            (end-pos (if (markerp end) (marker-position end) end)))
        (when (and start-pos end-pos (< start-pos end-pos))
          (let ((start-marker
                 (or (and (markerp (plist-get
                                     state :rendered-window-start-marker))
                          (plist-get state :rendered-window-start-marker))
                     (make-marker)))
                (end-marker
                 (or (and (markerp (plist-get
                                     state :rendered-window-end-marker))
                          (plist-get state :rendered-window-end-marker))
                     (make-marker))))
            (set-marker-insertion-type start-marker nil)
            (set-marker-insertion-type end-marker t)
            (set-marker start-marker start-pos)
            (set-marker end-marker end-pos)
            (setq state
                  (plist-put state :rendered-window-start-marker
                             start-marker))
            (setq state
                  (plist-put state :rendered-window-end-marker
                             end-marker)))
          (setq state
                (plist-put state :rendered-window-line-count line-count))
          (setq state (plist-put state :buffer buffer))
          (puthash region-id state ebox--scroll-global-state)
          state)))))

(defun ebox--scroll-window-region-id-set (buffer ranges)
  "Return all ebox region ids inside BUFFER RANGES as a hash set."
  (let ((set (make-hash-table :test 'equal)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (dolist (range ranges)
          (let ((pos (car range))
                (end (cdr range)))
            (while (< pos end)
              (dolist (region-id (ebox--pos-region-ids pos))
                (puthash region-id t set))
              (setq pos (or (next-property-change pos nil end)
                            end)))))))
    set))

(defun ebox--scroll-state-put-window-region-id-set (state value)
  "Return STATE with cached visible region id set stored at the front."
  (cons :content-window-region-id-set
        (cons value
              (ebox--plist-remove state :content-window-region-id-set))))

(defun ebox--scroll-state-store-window-region-id-set
    (region-id state buffer ranges)
  "Store visible region ids for REGION-ID/STATE from BUFFER RANGES."
  (setq state
        (ebox--scroll-state-put-window-region-id-set
         state (ebox--scroll-window-region-id-set buffer ranges)))
  (setq state (plist-put state :buffer buffer))
  (puthash region-id state ebox--scroll-global-state)
  state)

(defun ebox--scroll-state-clear-window-region-id-set
    (region-id state &optional buffer)
  "Clear the cached visible region id set for REGION-ID/STATE."
  (when (or (plist-get state :content-window-region-id-set)
            (and buffer (not (eq (plist-get state :buffer) buffer))))
    (setq state (plist-put state :content-window-region-id-set nil))
    (when buffer
      (setq state (plist-put state :buffer buffer)))
    (puthash region-id state ebox--scroll-global-state))
  state)

(defun ebox--scroll-state-region-visible-in-window-p (state region-ids)
  "Return non-nil when REGION-IDS appear in STATE's marker window."
  (if-let ((region-set (plist-get state :content-window-region-id-set)))
      (cl-some (lambda (region-id)
                 (gethash region-id region-set))
               region-ids)
    (when-let ((markers (plist-get state :content-span-markers)))
      (let ((region-set (ebox--region-id-set region-ids)))
        (catch 'visible
          (dolist (span (ebox--scroll-content-marker-spans markers))
            (when-let* ((start-marker (car-safe span))
                        (end-marker (cdr-safe span))
                        ((markerp start-marker))
                        ((markerp end-marker))
                        (buffer (marker-buffer start-marker))
                        ((eq buffer (marker-buffer end-marker)))
                        (start (marker-position start-marker))
                        (end (marker-position end-marker))
                        ((< start end)))
              (with-current-buffer buffer
                (let ((pos start))
                  (while (< pos end)
                    (when (cl-some (lambda (region-id)
                                     (gethash region-id region-set))
                                   (ebox--pos-region-ids pos))
                      (throw 'visible t))
                    (setq pos (or (next-property-change pos nil end)
                                  end)))))))
          nil)))))

(defun ebox--scroll-state-region-visible-in-content-range-p
    (state region-ids)
  "Return non-nil when REGION-IDS have spans in STATE's visible line range."
  (when-let ((spans
              (ebox--scroll-hot-content-line-spans
               state region-ids)))
    (ebox--scroll-state-spans-visible-p state spans)))

(defun ebox--scroll-state-buffer (state)
  "Return the buffer associated with scroll STATE, or nil."
  (or (plist-get state :buffer)
      (catch 'buffer
        (dolist (span (ebox--scroll-content-marker-spans
                       (plist-get state :content-span-markers)))
          (when-let ((buffer (and (consp span)
                                  (markerp (car span))
                                  (marker-buffer (car span)))))
            (throw 'buffer buffer)))
        nil)))

;;;###autoload
(defun ebox-scroll-state (region-id)
  "Return the scroll state plist for REGION-ID, or nil.
The plist is read-only API for consumers that need to map visible scroll
content back to their own source model."
  (ebox--scroll-get-state region-id))

(defconst ebox--scroll-cache-transient-state-keys
  '(:buffer
    :content-span-markers
    :content-window-region-id-set
    :rendered-window-start-marker
    :rendered-window-end-marker
    :rendered-window-line-count
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
         (if-let ((state (ebox--scroll-get-state region-id)))
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
  (when-let ((old-state (ebox--scroll-get-state region-id)))
    (ebox--scroll-clear-content-markers old-state)
    (ebox--scroll-clear-rendered-window-markers old-state))
  (when-let ((content-lines (plist-get state :content-lines)))
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
  (ebox--scroll-cancel-idle-prefetch region-id)
  (when-let ((old-state (ebox--scroll-get-state region-id)))
    (ebox--scroll-clear-content-markers old-state)
    (ebox--scroll-clear-rendered-window-markers old-state))
  (remhash region-id ebox--scroll-global-state)
  (ebox--record-render-cache-scroll-region region-id))

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
      (when-let ((lines (plist-get state :rendered-content-lines)))
        (let* ((max-offset (max 0 (- (length lines) content-height)))
               (offset (max 0 (min max-offset offset)))
               (end (min (+ offset content-height) (length lines))))
          (list offset (seq-subseq lines offset end))))))))

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
  (if-let ((materialize (plist-get state :materialize-content-lines)))
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
          ;; Native publication already exposed this exact visible window.
          ;; Property-list order can differ between the live patch and the
          ;; freshly rendered prefix while their text, faces and display
          ;; geometry are identical.  Keep the bounded line-slide path when
          ;; the live marker window proves that visual identity.
          (when (and native-target-p
                     (not (plist-get state
                                     :native-reflow-target-prefix-p))
                     buffer
                     (ebox--scroll-state-window-markers-healthy-p
                      buffer region-id state))
            (setq state
                  (ebox--plist-remove
                   state :lazy-scroll-window-refresh-required)))
          (when (plist-get rendered :complete)
            (setq state (ebox--plist-remove
                         state :materialize-content-lines))
            (setq state (ebox--plist-remove
                         state :render-content-prefix))
            (ebox--scroll-cancel-idle-prefetch region-id))
          (puthash region-id state ebox--scroll-global-state)
          state)))))

(defun ebox--next-content-span-change (pos limit)
  "Return the next visible content span property change after POS."
  (let ((next limit))
    (dolist (prop '(ebox-content ebox-content-idx))
      (let ((change (next-single-property-change pos prop nil limit)))
        (when (and change (< change next))
          (setq next change))))
    next))

(defun ebox--scroll-state-with-content-marker-spans
    (buffer state entries &optional defer-window-region-set)
  "Return STATE with marker-backed content ENTRIES in BUFFER."
  (let* ((max-idx (cl-loop for entry in entries
                           maximize (or (car entry) 0)))
         (markers (make-vector (1+ (or max-idx 0)) nil))
         ranges)
    (with-current-buffer buffer
      (dolist (entry entries)
        (pcase-let ((`(,idx ,start . ,end) entry))
          (when (and (integerp idx) start end)
            (let ((start-marker (copy-marker start nil))
                  (end-marker (copy-marker end t)))
              (aset markers idx (cons start-marker end-marker))
              (push (cons start end) ranges))))))
    (setq state (plist-put state :content-span-markers markers))
    (if defer-window-region-set
        (progn
          (setq state (plist-put state :content-window-region-id-set nil))
          (plist-put state :buffer buffer))
      (ebox--scroll-state-put-window-region-id-set
       state (ebox--scroll-window-region-id-set buffer ranges)))))

(defun ebox--scroll-store-content-marker-spans
    (buffer region-id state entries &optional defer-window-region-set)
  "Store marker-backed visible content ENTRIES for REGION-ID in BUFFER."
  (let ((old-state state))
    (setq state
          (ebox--scroll-state-with-content-marker-spans
           buffer (copy-sequence state) entries
           defer-window-region-set))
    (puthash region-id state ebox--scroll-global-state)
    (ebox--scroll-clear-content-markers old-state)
    (ebox--scroll-state-window-extents region-id state)))

(defun ebox--scroll-window-region-id-set-in-spans (spans)
  "Return scroll viewport region ids marked inside buffer SPANS."
  (let ((region-set (make-hash-table :test 'equal)))
    (dolist (span spans)
      (let ((pos (car span))
            (end (cdr span)))
        (while (< pos end)
          (when-let ((region-id
                      (get-text-property pos 'ebox-scroll-window)))
            (puthash region-id t region-set))
          (setq pos
                (or (next-single-property-change
                     pos 'ebox-scroll-window nil end)
                    end)))))
    region-set))

(defun ebox--refresh-root-owner-scroll-windows (buffer results)
  "Refresh lightweight scroll window markers after one root owner replacement.
Return non-nil when RESULTS cover BUFFER's root and every scroll viewport can
use the rendered-window fast path."
  (when (and (= (length results) 1)
             (equal (plist-get (car results) :owner-id)
                    (ebox--buffer-root-node-id buffer)))
    (let ((region-set (ebox--buffer-region-id-set buffer))
          (rendered-scroll-region-set
           (with-current-buffer buffer
             (ebox--scroll-window-region-id-set-in-spans
              (plist-get (car results) :new-buffer-spans))))
          (replacement-spans (plist-get (car results) :new-buffer-spans))
          region-ids
          windows
          compatible)
      (maphash
       (lambda (region-id state)
         (when (and (gethash region-id region-set)
                    (gethash region-id rendered-scroll-region-set)
                    (plist-get state :box))
           (push region-id region-ids)))
       ebox--scroll-global-state)
      (setq region-ids (nreverse region-ids))
      (if (null region-ids)
          t
        (with-current-buffer buffer
          (if (ebox-buffer--region-role-span-table)
              (ebox--refresh-box-extents-from-role-spans
               region-ids replacement-spans)
            (ebox--refresh-scroll-window-extents-from-render-markers
             region-ids replacement-spans))
          (setq compatible t)
          (dolist (region-id region-ids)
            (let* ((state (ebox--scroll-get-state region-id))
                   (box (plist-get state :box))
                   (height (plist-get state :content-height))
                   (extents (ebox--live-box-extents region-id))
                   (start (and extents
                               (marker-position (car extents))))
                   (end (and extents
                             (marker-position (cdr extents)))))
              (if (and (ebox--scroll-chrome-free-rendered-window-p box)
                       (integerp height)
                       (> height 0)
                       start end (< start end)
                       (= (count-lines start end) height))
                  (push (list region-id state start end height) windows)
                (setq compatible nil))))
          (when compatible
            (dolist (window windows)
              (pcase-let ((`(,region-id ,state ,start ,end ,height) window))
                (ebox--scroll-clear-content-markers state)
                (setq state (plist-put state :content-span-markers nil))
                (setq state
                      (plist-put state :content-window-region-id-set nil))
                (ebox--scroll-store-rendered-window-extents
                 buffer region-id state start end height)))
            (when-let ((render-state (ebox--buffer-render-state buffer)))
              (plist-put render-state :scroll-region-ids region-ids))
            t))))))

(defun ebox--face-visual-attributes (face)
  "Return FACE's effective visual attributes under Emacs merge order.
Earlier entries of an anonymous face list take precedence, so for
every attribute keyword the first provider wins and the result is
independent of how contributors were merged or split.  Named faces
cannot be attribute-merged without display context, so any face
containing a named entry compares by its raw representation instead."
  (let ((entries (if (and (listp face) (not (keywordp (car-safe face))))
                     face
                   (list face)))
        attributes named)
    (dolist (entry entries)
      (cond
       ((null entry) nil)
       ((and (listp entry) (keywordp (car-safe entry)))
        (cl-loop for (key value) on entry by #'cddr
                 unless (assq key attributes)
                 do (push (cons key value) attributes)))
       (t (setq named t))))
    (if named
        (list 'raw face)
      (list 'visual
            (sort attributes
                  (lambda (a b)
                    (string< (symbol-name (car a))
                             (symbol-name (car b)))))))))

(defun ebox--scroll-string-visual-signature (string)
  "Return STRING's visual signature as pixel-extent glyph runs.
Each run is (START-PIXEL END-PIXEL TEXT DISPLAY VISUAL): equal runs
carry the same characters, the same display spec, the same effective
visual attributes, and the same pixel extent, which fully determines
their rendering.  Faces compare by `ebox--face-visual-attributes'
rather than raw face shape: independent patch paths legitimately
produce different face representations for the same visible result,
and this signature's contract is visual equality.  Pixel widths are
measured once per property run, never per character."
  (let ((pixel 0)
        (length (length string))
        (position 0)
        runs)
    (cl-flet
        ((record (start end text display visual)
           ;; TEXT is nil for visually blank segments; blank extents
           ;; merge across property boundaries so equality does not
           ;; depend on how invisible properties segment identical
           ;; lines.  Contiguous word segments with equal display and
           ;; visual attributes merge the same way.
           (let ((run (car runs)))
             (cond
              ((and run (null text) (null (nth 2 run))
                    (equal (nth 4 run) visual))
               (setcar (cdr run) end))
              ((and run text (nth 2 run)
                    (equal (nth 3 run) display)
                    (equal (nth 4 run) visual))
               (setcar (cdr run) end)
               (setcar (cddr run) (concat (nth 2 run) text)))
              (t (push (list start end text display visual) runs))))))
      (while (< position length)
        (let* ((next (or (next-property-change position string) length))
               (face (get-text-property position 'face string))
               (display (get-text-property position 'display string))
               (visual (ebox--face-visual-attributes face))
               (space-display-p (eq (car-safe display) 'space)))
          (cond
           (space-display-p
            (let ((width (ebox--substring-pixel-width string position next)))
              (record pixel (+ pixel width) nil nil visual)
              (setq pixel (+ pixel width))))
           (display
            (let ((width (ebox--substring-pixel-width string position next)))
              (record pixel (+ pixel width)
                      (substring-no-properties string position next)
                      display visual)
              (setq pixel (+ pixel width))))
           (t
            (let ((cursor position))
              (while (< cursor next)
                (let ((blank (eq (aref string cursor) ?\s))
                      (segment-end cursor))
                  (while (and (< segment-end next)
                              (eq (eq (aref string segment-end) ?\s)
                                  blank))
                    (setq segment-end (1+ segment-end)))
                  (let ((width (ebox--substring-pixel-width
                                string cursor segment-end)))
                    (record pixel (+ pixel width)
                            (unless blank
                              (substring-no-properties
                               string cursor segment-end))
                            nil visual)
                    (setq pixel (+ pixel width)))
                  (setq cursor segment-end))))))
          (setq position next))))
    (list pixel (nreverse runs))))

(defun ebox--scroll-lines-visually-equal-p (actual expected)
  "Return non-nil when ACTUAL and EXPECTED line lists render identically.
Raw string/property equality is a sufficient fast path; only lines
whose representations diverge pay for pixel-measured signatures."
  (and (= (length actual) (length expected))
       (cl-every
        (lambda (actual-line expected-line)
          (or (equal-including-properties actual-line expected-line)
              (equal (ebox--scroll-string-visual-signature actual-line)
                     (ebox--scroll-string-visual-signature expected-line))))
        actual expected)))

(defun ebox--scroll-state-window-markers-healthy-p
    (buffer region-id state)
  "Return non-nil when STATE's live BUFFER window equals its cached slice."
  (when-let* (((buffer-live-p buffer))
              (box (plist-get state :box))
              (height (plist-get state :content-height))
              ((integerp height))
              ((> height 0))
              ((eq (ebox--scroll-state-buffer state) buffer)))
    (let* ((offset (or (plist-get state :scroll-offset) 0))
           (native-offset (plist-get state :native-reflow-visible-offset))
           (native-lines (plist-get state :native-reflow-visible-lines))
           (chrome-free-p
            (ebox--scroll-chrome-free-rendered-window-p box))
           (marker-spans
            (delq nil
                  (ebox--scroll-content-marker-spans
                   (plist-get state :content-span-markers))))
           (contiguous-marker-window-p
            (and chrome-free-p
                 (= (length marker-spans) height)
                 (ebox--scroll-content-window
                  (plist-put (copy-sequence state) :region-id region-id)
                  height)))
           (lines
            (if chrome-free-p
                (or (plist-get state :rendered-content-lines)
                    (plist-get state :content-lines))
              (plist-get state :content-lines)))
           (visible
            (cond
             ((and (equal native-offset offset)
                   (= (length native-lines) height))
              (list offset native-lines))
             (lines
              (let ((end (min (length lines) (+ offset height))))
                (and (<= (+ offset height) (length lines))
                     (list offset (seq-subseq lines offset end)))))))
           (expected (and visible
                          (= (length (cadr visible)) height)
                          (cadr visible)))
           (expected
            (if (and expected
                     (not chrome-free-p))
                (let ((decorated
                       (ebox--scroll-decorate-rendered-window-lines
                        expected box region-id)))
                  (if (= (length decorated) height)
                      decorated
                    expected))
              expected)))
      (and expected
           (if (and chrome-free-p
                    (or (null marker-spans) contiguous-marker-window-p))
        (when-let* ((extents (ebox--scroll-state-window-extents
                              region-id state))
                    (start (car extents))
                    (end (cdr extents))
                    ((markerp start))
                    ((markerp end))
                    ((eq (marker-buffer start) buffer))
                    ((eq (marker-buffer end) buffer))
                    (start-pos (marker-position start))
                    (end-pos (marker-position end))
                    ((< start-pos end-pos))
                    (expected
                     (with-current-buffer buffer
                       (ebox--scroll-lines-with-live-wrapper-context
                        expected start-pos region-id))))
          (and (= (with-current-buffer buffer
                    (count-lines start-pos end-pos))
                  height)
               (ebox--scroll-lines-visually-equal-p
                (with-current-buffer buffer
                  (ebox-string-lines
                   (buffer-substring start-pos end-pos)))
                expected)))
      (let ((spans marker-spans))
        (and (= (length spans) height)
             (cl-every
              (lambda (span)
                (when-let* (((consp span))
                            (start (car span))
                            (end (cdr span))
                            ((markerp start))
                            ((markerp end))
                            ((eq (marker-buffer start) buffer))
                            ((eq (marker-buffer end) buffer))
                            (start-pos (marker-position start))
                            (end-pos (marker-position end)))
                  (< start-pos end-pos)))
              spans)
             (ebox--scroll-lines-visually-equal-p
              (with-current-buffer buffer
                (mapcar
                 (lambda (span)
                   (buffer-substring
                    (marker-position (car span))
                    (marker-position (cdr span))))
                 spans))
              expected))))))))

(defun ebox--publish-scoped-owner-scroll-windows
    (buffer results source-node-ids
            &optional pre-containing-region-ids rebuilt-region-ids
            final-spans-by-result)
  "Atomically publish scroll windows rebuilt by owner rerenders in BUFFER.
RESULTS are already-applied backend patch results and SOURCE-NODE-IDS are the
runtime nodes whose changes produced them.  One buffer-wide marker rebuild is
performed only after every replacement is complete, so nested scroll windows
cannot invalidate markers installed for one another.  `:covered-p' is non-nil
only when every source-containing state and every scroll state rebuilt inside
RESULTS has a verified live window from this same buffer generation."
  (when (and (buffer-live-p buffer) results source-node-ids)
    (let ((buffer-region-set (ebox--buffer-region-id-set buffer))
          (rendered-region-set (make-hash-table :test 'equal))
          rendered-region-ids
          candidate-region-ids
          published-region-ids
          (affected-region-ids (copy-sequence pre-containing-region-ids)))
      (with-current-buffer buffer
        (dolist (result results)
          (when (eq (plist-get result :op) 'owner-rerender)
            (let ((spans
                   (or (and final-spans-by-result
                            (gethash result final-spans-by-result))
                       (plist-get result :new-buffer-spans))))
              (maphash
               (lambda (region-id _present)
                 (when (gethash region-id buffer-region-set)
                   (puthash region-id t rendered-region-set)))
               (ebox--scroll-window-region-id-set-in-spans spans)))))
        (maphash (lambda (region-id _present)
                   (push region-id rendered-region-ids))
                 rendered-region-set))
      (dolist (region-id rendered-region-ids)
        (cl-pushnew region-id affected-region-ids :test #'equal))
      (dolist (region-id rebuilt-region-ids)
        (when-let ((state (and (gethash region-id buffer-region-set)
                               (ebox--scroll-get-state region-id))))
          (when (eq (ebox--scroll-state-buffer state) buffer)
          (cl-pushnew region-id affected-region-ids :test #'equal)
            (cl-pushnew region-id candidate-region-ids :test #'equal))))
      (dolist (region-id rendered-region-ids)
        (cl-pushnew region-id candidate-region-ids :test #'equal))
      (when candidate-region-ids
        ;; Install every content marker generation together.  This handles
        ;; chromed, chrome-free, root and nested scroll owners without a
        ;; per-state zero-delta rewrite.
        (ebox--refresh-buffer-scroll-content-markers buffer)
        (dolist (region-id candidate-region-ids)
          (when-let ((state (ebox--scroll-get-state region-id)))
            (when (ebox--scroll-state-window-markers-healthy-p
                   buffer region-id state)
              (setq state
                    (ebox--plist-remove
                     state :lazy-scroll-window-refresh-required))
              (puthash region-id state ebox--scroll-global-state)
              (push region-id published-region-ids))))
        (list :covered-p
              (cl-every
               (lambda (region-id)
                 (member region-id published-region-ids))
               affected-region-ids)
              :covered-region-ids (nreverse affected-region-ids)
              :published-region-ids (nreverse published-region-ids))))))

(defun ebox--refresh-scroll-window-extents-from-render-markers
    (region-ids spans)
  "Refresh scroll REGION-IDS in SPANS from rendered window markers.
Root reflow invalidates the broad role index.  Chrome-free scroll boxes mark
their exact visible window on the rendered string, so recovering those ranges
requires only one dedicated property scan rather than generic role inference."
  (ebox--clear-box-extents-for-region-ids region-ids)
  (when spans
    (let ((region-set (ebox--region-id-set region-ids))
          (ranges (make-hash-table :test 'equal)))
      (dolist (span spans)
        (let ((pos (car span))
              (end (cdr span)))
          (while (< pos end)
            (let* ((region-id
                    (get-text-property pos 'ebox-scroll-window))
                   (next
                    (or (next-single-property-change
                         pos 'ebox-scroll-window nil end)
                        end)))
              (when (and region-id (gethash region-id region-set))
                (if-let ((range (gethash region-id ranges)))
                    (progn
                      (setcar range (min (car range) pos))
                      (setcdr range (max (cdr range) next)))
                  (puthash region-id (cons pos next) ranges)))
              (setq pos (max next (1+ pos)))))))
      (maphash
       (lambda (region-id range)
         (when (< (car range) (cdr range))
           (ebox--set-box-extents region-id (car range) (cdr range))))
       ranges))))

(defun ebox--refresh-buffer-scroll-content-markers (buffer)
  "Refresh marker-backed scroll content spans for scroll regions in BUFFER."
  (when (and (buffer-live-p buffer)
             (> (hash-table-count ebox--scroll-global-state) 0))
    (let ((spans-by-region (make-hash-table :test 'equal))
          (owner-line-indexes (make-hash-table :test 'equal))
          (seen (make-hash-table :test 'equal))
          scroll-region-ids)
      (cl-labels
          ((record (region-id idx start end)
             (when (and region-id
                        (integerp idx)
                        (ebox--scroll-get-state region-id)
                        (< start end))
               (puthash region-id t seen)
               (puthash region-id
                        (cons (cons idx (cons start end))
                              (gethash region-id spans-by-region))
                        spans-by-region)))
           (owner-ids-at (pos)
             (let (ids)
               (dolist (region-id (get-text-property
                                    pos 'ebox-content-owners))
                 (cl-pushnew region-id ids :test #'equal))
               (when-let ((region-id (get-text-property
                                       pos 'ebox-content-owner)))
                 (cl-pushnew region-id ids :test #'equal))
               ids))
           (line-owner-spans (start end)
             (let ((pos start)
                   spans)
               (while (< pos end)
                 (let ((next (or (next-property-change pos nil end) end)))
                   (dolist (region-id (owner-ids-at pos))
                     (when (ebox--scroll-get-state region-id)
                       (let ((span (alist-get region-id spans nil nil
                                              #'equal)))
                         (if span
                             (setcdr span next)
                           (push (cons region-id (cons pos next))
                                 spans)))))
                   (setq pos (max next (1+ pos)))))
               spans)))
        (with-current-buffer buffer
          (save-excursion
            (goto-char (point-min))
            (while (< (point) (point-max))
              (let* ((region-id (get-text-property (point) 'ebox-content))
                     (idx (get-text-property (point) 'ebox-content-idx))
                     (next (ebox--next-content-span-change
                            (point) (point-max))))
                (record region-id idx (point) next)
                (goto-char (max next (1+ (point)))))))
          (save-excursion
            (goto-char (point-min))
            (while (< (point) (point-max))
              (let* ((line-start (point))
                     (line-end (line-end-position)))
                (when (< line-start line-end)
                  (dolist (entry (line-owner-spans line-start line-end))
                    (let* ((region-id (car entry))
                           (span (cdr entry))
                           (idx (gethash region-id owner-line-indexes 0)))
                      (record region-id idx (car span) (cdr span))
                      (puthash region-id (1+ idx) owner-line-indexes))))
                (forward-line 1))))))
      (maphash
       (lambda (region-id entries)
         (when-let ((state (ebox--scroll-get-state region-id)))
           (ebox--scroll-store-content-marker-spans
            buffer region-id state (nreverse entries))))
       spans-by-region)
      (maphash
       (lambda (region-id state)
         (when (eq (ebox--scroll-state-buffer state) buffer)
           (push region-id scroll-region-ids)
           (unless (gethash region-id seen)
             (ebox--scroll-clear-content-markers state)
             (setq state (plist-put state :content-span-markers nil))
             (setq state (plist-put state :content-window-region-id-set nil))
             (setq state (plist-put state :buffer nil))
             (puthash region-id state ebox--scroll-global-state))))
       ebox--scroll-global-state)
      (when-let ((render-state (ebox--buffer-render-state buffer)))
        (plist-put render-state :scroll-region-ids
                   (nreverse scroll-region-ids))))))

(defun ebox--span-touches-range-p (span range)
  "Return non-nil when SPAN overlaps RANGE or contains its empty insertion."
  (if (= (car range) (cdr range))
      (<= (car span) (car range) (cdr span))
    (and (< (car span) (cdr range))
         (> (cdr span) (car range)))))

(defun ebox--scroll-content-entries-in-range (region-id start end)
  "Return visible content marker entries for REGION-ID inside START..END."
  (let ((position start)
        direct
        owned
        (owner-index 0))
    (while (< position end)
      (let* ((content (get-text-property position 'ebox-content))
             (index (get-text-property position 'ebox-content-idx))
             (next (ebox--next-content-span-change position end)))
        (when (and (equal content region-id) (integerp index))
          (push (cons index (cons position next)) direct))
        (setq position (max next (1+ position)))))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (let* ((line-start (point))
               (line-end (min end (line-end-position)))
               (position line-start)
               owner-start owner-end)
          (while (< position line-end)
            (let* ((owners
                    (append
                     (get-text-property position 'ebox-content-owners)
                     (when-let ((owner
                                 (get-text-property
                                  position 'ebox-content-owner)))
                       (list owner))))
                   (next (or (next-property-change position nil line-end)
                             line-end)))
              (when (member region-id owners)
                (setq owner-start (or owner-start position)
                      owner-end next))
              (setq position (max next (1+ position)))))
          (when (and owner-start owner-end (< owner-start owner-end))
            (push (cons owner-index (cons owner-start owner-end)) owned)
            (cl-incf owner-index))
          (forward-line 1))))
    (nreverse (or direct owned))))

(defconst ebox--scroll-content-template-absent
  'ebox--scroll-content-template-absent
  "Sentinel returned when a scroll content template has no REGION-ID entry.")

(defun ebox--scroll-content-template-entries (template region-id start)
  "Return REGION-ID scroll content entries from TEMPLATE at buffer START."
  (when (and (hash-table-p template) (integerp start))
    (let ((entries
           (gethash region-id template
                    ebox--scroll-content-template-absent)))
      (if (eq entries ebox--scroll-content-template-absent)
          (list ebox--scroll-content-template-absent)
        (mapcar
         (lambda (entry)
           (cons (car entry)
                 (cons (+ start (cadr entry))
                       (+ start (cddr entry)))))
         entries)))))

(defun ebox--preflight-scroll-content-span-template
    (buffer template start target-length)
  "Validate TEMPLATE for BUFFER before prepared-root publication.
Return translated target entries keyed by scroll region id.  Missing template
entries, malformed target offsets, and nonempty states with empty entries are
rejected before the visible buffer text changes."
  (unless (and (buffer-live-p buffer)
               (hash-table-p template)
               (integerp start)
               (integerp target-length)
               (>= target-length 0))
    (error "Invalid prepared scroll template"))
  (let ((translated (make-hash-table :test 'equal))
        (scroll-region-ids
         (delete-dups
          (append
           (copy-sequence
            (plist-get (ebox--buffer-render-state buffer)
                       :scroll-region-ids))
           (cl-loop for region-id being the hash-keys of ebox--scroll-global-state
                    using (hash-values state)
                    when (eq (ebox--scroll-state-buffer state) buffer)
                    collect region-id)))))
    (dolist (region-id scroll-region-ids)
      (let ((entries
             (gethash region-id template
                      ebox--scroll-content-template-absent))
            (state (ebox--scroll-get-state region-id)))
        (when (eq entries ebox--scroll-content-template-absent)
          (error "Prepared scroll template missing region %S" region-id))
        (unless state
          (error "Prepared scroll template has no live state for %S"
                 region-id))
        (when (and (null entries)
                   (> (or (plist-get state :content-height) 0) 0))
          (error "Prepared scroll template is empty for nonempty region %S"
                 region-id))
        (puthash
         region-id
         (mapcar
          (lambda (entry)
            (let ((index (car entry))
                  (entry-start (cadr entry))
                  (entry-end (cddr entry)))
              (unless (and (integerp index)
                           (>= index 0)
                           (integerp entry-start)
                           (integerp entry-end)
                           (<= 0 entry-start entry-end target-length)
                           (< entry-start entry-end))
                (error "Prepared scroll template has invalid target offsets"))
              (cons index
                    (cons (+ start entry-start)
                          (+ start entry-end)))))
          entries)
         translated)))
    (list :entries-by-region translated
          :scroll-region-ids scroll-region-ids)))

(defun ebox--refresh-patched-scroll-markers
    (buffer affected-region-ids published-spans
            &optional scroll-content-template root-start)
  "Refresh only scroll windows touched by an exact root patch in BUFFER.
Return a plist whose `:complete-p' value proves every affected live scroll
state received one current marker generation.
SCROLL-CONTENT-TEMPLATE contains target-side scroll spans relative to
ROOT-START, and avoids live extent scans for prepared root publications."
  (when (buffer-live-p buffer)
    (let ((candidate-set (make-hash-table :test 'equal))
          candidates staged staged-publications published
          (complete-p t))
      (dolist (region-id affected-region-ids)
        (when (ebox--scroll-get-state region-id)
          (puthash region-id t candidate-set)))
      (dolist (region-id
               (plist-get (ebox--buffer-render-state buffer)
                          :scroll-region-ids))
        (let* ((template-entries
                (ebox--scroll-content-template-entries
                 scroll-content-template region-id root-start))
               (template-present-p
                (not (eq (car template-entries)
                         ebox--scroll-content-template-absent)))
               extents start end)
          (unless template-present-p
            (setq extents
                  (with-current-buffer buffer
                    (ebox--live-box-extents region-id))
                  start (and extents (marker-position (car extents)))
                  end (and extents (marker-position (cdr extents)))))
          ;; Exact root patches already bound the publication work.  If their
          ;; role delta is empty, retain correctness for scroll roots whose
          ;; extents do not expose the changed interior by refreshing the
          ;; small render-state scroll set, never by scanning the page.
          (when (or (null affected-region-ids)
                    template-present-p
                    (and start end (< start end)
                         (cl-some
                          (lambda (span)
                            (ebox--span-touches-range-p
                             (cons start end) span))
                          published-spans)))
            (puthash region-id t candidate-set))))
      (maphash (lambda (region-id _present)
                 (push region-id candidates))
               candidate-set)
      (with-current-buffer buffer
        (dolist (region-id candidates)
          (let* ((state (ebox--scroll-get-state region-id))
                 (template-entries
                  (ebox--scroll-content-template-entries
                   scroll-content-template region-id root-start))
                 (template-present-p
                  (not (eq (car template-entries)
                           ebox--scroll-content-template-absent)))
                 extents start end entries)
            (if (not state)
                (setq complete-p nil)
              (unless template-present-p
                (setq extents (ebox--live-box-extents region-id)
                      start (and extents (marker-position (car extents)))
                      end (and extents (marker-position (cdr extents)))))
              (setq entries
                    (if template-present-p
                        template-entries
                      (and start end (< start end)
                           (ebox--scroll-content-entries-in-range
                            region-id start end))))
              (if (or entries
                      (and template-present-p
                           (= (or (plist-get state :content-height) 0)
                              0)))
                  (push (list region-id state entries) staged)
                (setq complete-p nil)))))
        (when complete-p
          (dolist (prepared (nreverse staged))
            (pcase-let ((`(,region-id ,state ,entries) prepared))
              (let* ((render-state (ebox--buffer-render-state buffer))
                       (old-state state)
                       (state (copy-sequence state))
                       (box (plist-get state :box))
                       (viewport-width
                        (plist-get render-state :viewport-width))
                       (viewport-height
                        (plist-get render-state :viewport-height))
                       (prefix-viewport-width
                        (and box viewport-width
                             (let ((ebox-viewport-width viewport-width))
                               (or (ebox--wrapper-content-viewport-pixel box)
                                   viewport-width))))
                       (content-height (plist-get state :content-height))
                       (scroll-offset
                        (or (plist-get state :scroll-offset) 0))
                       (source
                        (and box
                             (ebox--scroll-window-stack-source
                              (ebox--box-content-node box))))
                       (visible-lines
                        (and (integerp content-height)
                             (= (length entries) content-height)
                             (cl-loop
                              for entry in (sort (copy-sequence entries)
                                                 (lambda (left right)
                                                   (< (car left)
                                                      (car right))))
                              for expected-index from 0
                              when (= (car entry) expected-index)
                              collect
                              (buffer-substring
                               (cadr entry) (cddr entry))))))
                  ;; The patch contains the complete visible target window but
                  ;; no hidden target page.  Drop the old-width line cache,
                  ;; retain only this exact visible proof, and rebuild the new
                  ;; prefix incrementally.  This keeps publication proportional
                  ;; to the patch and prevents first scroll input from paying a
                  ;; full-page materialization.
                  (when (and box source prefix-viewport-width viewport-height
                             (= (length visible-lines) content-height))
                    (setq state (plist-put state :content-lines nil))
                    (setq state
                          (ebox--plist-remove state
                                              :rendered-content-lines))
                    (dolist (key '(:content-region-id-set
                                   :region-line-bounds-index
                                   :region-line-span-index
                                   :region-line-span-index-deferred
                                   :rendered-region-line-span-index
                                   :rendered-region-line-span-index-deferred
                                   :region-line-span-hints))
                      (setq state (ebox--plist-remove state key)))
                    (setq state
                          (plist-put
                           state :render-content-prefix
                           (ebox--scroll-window-prefix-renderer
                            box source prefix-viewport-width
                            viewport-height)))
                    (setq state
                          (plist-put
                           state :scroll-window-producer-spec
                           (ebox--scroll-window-producer-spec
                            prefix-viewport-width viewport-width
                            viewport-height)))
                    (setq state
                          (plist-put
                           state :materialize-content-lines
                           (ebox--scroll-window-materializer
                            box viewport-width viewport-height)))
                    (setq state
                          (plist-put state :content-lines-complete-p nil))
                    (setq state
                          (plist-put state
                                     :native-reflow-target-prefix-p t))
                    (setq state
                          (plist-put state
                                     :native-reflow-prefix-reset-p t))
                    (setq state
                          (plist-put state :native-reflow-visible-offset
                                     scroll-offset))
                    (setq state
                          (plist-put state :native-reflow-visible-lines
                                     visible-lines))
                    (setq state
                          (ebox--plist-remove
                           state :native-reflow-materialize-p)))
                  (push
                   (list region-id old-state
                         (ebox--scroll-state-with-content-marker-spans
                          buffer state entries))
                   staged-publications)
                  (push region-id published)))))
        (let (swapped)
          (condition-case err
              (progn
                (dolist (publication (nreverse staged-publications))
                  (pcase-let ((`(,region-id ,old-state ,new-state)
                               publication))
                    (puthash region-id new-state ebox--scroll-global-state)
                    (push (list region-id old-state new-state) swapped)))
                (dolist (publication swapped)
                  (pcase-let ((`(,region-id ,_old-state ,_new-state)
                               publication))
                    (ebox--scroll-schedule-idle-prefetch region-id)))
                (dolist (publication swapped)
                  (pcase-let ((`(,_region-id ,old-state ,_new-state)
                               publication))
                    (ebox--scroll-clear-content-markers old-state))))
            (error
             (dolist (publication swapped)
               (pcase-let ((`(,region-id ,old-state ,new-state)
                            publication))
                 (puthash region-id old-state ebox--scroll-global-state)
                 (ebox--scroll-clear-content-markers new-state)))
             (signal (car err) (cdr err))))))
      (list :complete-p complete-p
            :affected-region-ids (nreverse candidates)
            :published-region-ids (nreverse published)))))

(defun ebox--next-string-content-span-change (position string limit)
  "Return next content property change after POSITION in STRING."
  (let ((next limit))
    (dolist (property '(ebox-content ebox-content-idx))
      (let ((change (next-single-property-change
                     position property string limit)))
        (when (and change (< change next))
          (setq next change))))
    next))

(defun ebox--next-string-content-owner-change (position string limit)
  "Return next wrapper-owner property change after POSITION in STRING."
  (let ((next limit))
    (dolist (property '(ebox-content-owner ebox-content-owners))
      (let ((change (next-single-property-change
                     position property string limit)))
        (when (and change (< change next))
          (setq next change))))
    next))

(defun ebox--build-scroll-content-span-template (string)
  "Build scroll content marker offsets from rendered STRING."
  (let ((table (make-hash-table :test 'equal))
        (owner-line-indexes (make-hash-table :test 'equal))
        (limit (length string)))
    (cl-labels
        ((record (region-id index start end)
           (when (and region-id
                      (gethash region-id ebox--scroll-global-state)
                      (integerp index)
                      (< start end))
             (puthash region-id
                      (cons (cons index (cons start end))
                            (gethash region-id table))
                      table)))
         (owner-ids-at (position)
           (let (ids)
             (dolist (region-id
                      (get-text-property position 'ebox-content-owners string))
               (when (gethash region-id ebox--scroll-global-state)
                 (cl-pushnew region-id ids :test #'equal)))
             (when-let ((region-id
                         (get-text-property
                          position 'ebox-content-owner string)))
               (when (gethash region-id ebox--scroll-global-state)
                 (cl-pushnew region-id ids :test #'equal)))
             ids))
         (line-owner-spans (start end)
           (let ((position start)
                 spans)
             (while (< position end)
              (let ((next (ebox--next-string-content-owner-change
                           position string end)))
                 (dolist (region-id (owner-ids-at position))
                   (let ((span (alist-get region-id spans nil nil #'equal)))
                     (if span
                         (setcdr span next)
                       (push (cons region-id (cons position next)) spans))))
                 (setq position (max next (1+ position)))))
             spans)))
      (let ((position 0))
        (while (< position limit)
          (let* ((region-id
                  (get-text-property position 'ebox-content string))
                 (index
                  (get-text-property position 'ebox-content-idx string))
                 (next
                  (ebox--next-string-content-span-change
                   position string limit)))
            (record region-id index position next)
            (setq position (max next (1+ position))))))
      (let ((line-start 0))
        (while (< line-start limit)
          (let ((line-end (or (string-search "\n" string line-start) limit)))
            (when (< line-start line-end)
              (dolist (entry (line-owner-spans line-start line-end))
                (let* ((region-id (car entry))
                       (span (cdr entry))
                       (index (gethash region-id owner-line-indexes 0)))
                  (record region-id index (car span) (cdr span))
                  (puthash region-id (1+ index) owner-line-indexes))))
            (setq line-start (if (< line-end limit) (1+ line-end) limit))))))
    (maphash (lambda (region-id entries)
               (puthash region-id (nreverse entries) table))
             table)
    table))

(defun ebox--install-buffer-scroll-content-span-template
    (buffer template start &optional defer-window-region-set)
  "Install scroll marker TEMPLATE in BUFFER relative to START.
When DEFER-WINDOW-REGION-SET is non-nil, postpone computing the visible
region set until the first scroll operation."
  (when (and (buffer-live-p buffer) (hash-table-p template))
    (let ((region-set (ebox--buffer-region-id-set buffer))
          (seen (make-hash-table :test 'equal))
          scroll-region-ids)
      (maphash
       (lambda (region-id entries)
         (when-let ((state (and (gethash region-id region-set)
                                (ebox--scroll-get-state region-id))))
           (puthash region-id t seen)
           (ebox--scroll-store-content-marker-spans
            buffer region-id state
            (mapcar (lambda (entry)
                      (cons (car entry)
                            (cons (+ start (cadr entry))
                                  (+ start (cddr entry)))))
                    entries)
            defer-window-region-set)))
       template)
      (maphash
       (lambda (region-id state)
         (when (eq (ebox--scroll-state-buffer state) buffer)
           (push region-id scroll-region-ids)
           (unless (gethash region-id seen)
             (ebox--scroll-clear-content-markers state)
             (setq state (plist-put state :content-span-markers nil))
             (setq state (plist-put state :content-window-region-id-set nil))
             (setq state (plist-put state :buffer nil))
             (puthash region-id state ebox--scroll-global-state))))
       ebox--scroll-global-state)
      (when-let ((render-state (ebox--buffer-render-state buffer)))
        (plist-put render-state :scroll-region-ids
                   (nreverse scroll-region-ids)))
      t)))

(defvar ebox--rendered-root-metadata-table
  (make-hash-table :test 'eq :weakness 'key)
  "Weak rendered-string map for root replacement index templates.")

(defun ebox--string-foreign-region-in-range-p
    (rendered start end region-id)
  "Return non-nil when RENDERED START..END crosses REGION-ID ownership."
  (let ((position start)
        found)
    (while (and (< position end) (not found))
      (unless (eq (aref rendered position) ?\n)
        (let ((region-ids (ebox--string-region-ids-at rendered position))
              (owner-stack
               (get-text-property
                position 'ebox-content-owners rendered)))
          (when (cl-some
                 (lambda (owner)
                   (and (not (equal owner region-id))
                        (not (member region-id owner-stack))))
                 region-ids)
            (setq found t))))
      (setq position (1+ position)))
    found))

(defun ebox--build-box-extent-template (rendered)
  "Build safe point-min-based numeric box extents from RENDERED once."
  (let ((table (make-hash-table :test 'equal))
        (interleaved (make-hash-table :test 'equal))
        (position 0)
        (limit (length rendered)))
    (while (< position limit)
      (let* ((next (or (next-property-change position rendered limit) limit))
             (start (1+ position))
             (end (1+ next))
             (region-ids
              (delete-dups
               (append
                (get-text-property position 'ebox-content-owners rendered)
                (when-let ((owner (get-text-property
                                   position 'ebox-content-owner rendered)))
                  (list owner))
                (when-let ((content (get-text-property
                                     position 'ebox-content rendered)))
                  (list content))
                (delq nil
                      (mapcar
                       (lambda (entry)
                         (get-text-property position (cdr entry) rendered))
                       ebox-region-types))))))
        (dolist (region-id region-ids)
          (if-let ((span (gethash region-id table)))
              (progn
                (when (and (> start (cdr span))
                           (ebox--string-foreign-region-in-range-p
                            rendered (1- (cdr span)) position region-id))
                  (puthash region-id t interleaved))
                (setcar span (min (car span) start))
                (setcdr span (max (cdr span) end)))
            (puthash region-id (cons start end) table)))
        (setq position (max next (1+ position)))))
    (maphash (lambda (region-id _)
               (remhash region-id table))
             interleaved)
    table))

(defun ebox--register-rendered-root-metadata (rendered prepared)
  "Register Rust PREPARED root indexes for RENDERED.
The native tape uses ordinary hash tables.  Add the private template marker
only after the tape has been validated, then update any stable lightweight
descriptor already retained by a prepared patch result."
  (unless (and (stringp rendered)
               (plist-get prepared :prepared-p)
               (hash-table-p (plist-get prepared :role-span-template))
               (hash-table-p (plist-get prepared :box-extent-template))
               (hash-table-p
                (plist-get prepared :scroll-content-span-template)))
    (error "Invalid prepared rendered-root metadata"))
  (let* ((role-template (plist-get prepared :role-span-template))
         (metadata
          (or (gethash rendered ebox--rendered-root-metadata-table)
              (list :prepared-p nil
                    :role-span-template nil
                    :box-extent-template nil
                    :scroll-content-span-template nil
                    :scroll-window-p nil))))
    (puthash ebox-buffer--role-span-table-template-key t role-template)
    (plist-put metadata :role-span-template role-template)
    (plist-put metadata :box-extent-template
               (plist-get prepared :box-extent-template))
    (plist-put metadata :scroll-content-span-template
               (plist-get prepared :scroll-content-span-template))
    (plist-put metadata :scroll-window-p
               (and (plist-get prepared :scroll-window-p) t))
    (plist-put metadata :prepared-p t)
    (puthash rendered metadata ebox--rendered-root-metadata-table)
    metadata))

(defun ebox--rendered-root-metadata (rendered &optional lightweight-only)
  "Return reusable root replacement metadata for RENDERED output.
When LIGHTWEIGHT-ONLY is non-nil, record only whether RENDERED contains a
scroll window.  A later offscreen prewarm or an incompatible visible scroll
root may upgrade the same metadata object with complete role and scroll span
templates.  This keeps ordinary cold-width publication off the full-output
property-scan path while preserving prepared indexes where they are needed."
  (let ((metadata
         (gethash rendered ebox--rendered-root-metadata-table)))
    (unless metadata
      (setq metadata
            (list :prepared-p nil
                  :role-span-template nil
                  :box-extent-template nil
                  :scroll-content-span-template nil
                  :scroll-window-p
                  (not
                   (null
                    (text-property-not-all
                     0 (length rendered)
                     'ebox-scroll-window nil rendered)))))
      (puthash rendered metadata ebox--rendered-root-metadata-table))
    (unless (or lightweight-only
                (plist-get metadata :prepared-p))
      ;; Keep the plist object stable: patch results holding the lightweight
      ;; descriptor observe this in-place upgrade without retaining RENDERED.
      (plist-put metadata :role-span-template
                 (ebox-buffer--build-region-role-span-template rendered))
      (plist-put metadata :box-extent-template
                 (ebox--build-box-extent-template rendered))
      (plist-put metadata :scroll-content-span-template
                 (ebox--build-scroll-content-span-template rendered))
      (plist-put metadata :prepared-p t))
    metadata))

(defconst ebox--scroll-state-span-patch-keys
  '(:content :text-align :vertical-align :wrap-mode :scroll-offset)
  "Local keys that can patch cached scroll content lines directly.")

(defun ebox--scroll-state-span-patch-keys-p (changed-keys)
  "Return non-nil when CHANGED-KEYS are safe for scroll-state line patching."
  (and changed-keys
       (cl-every
        (lambda (key)
          (or (memq key ebox--scroll-state-span-patch-keys)
              (and (memq :content changed-keys)
                   (memq key ebox--paint-style-signature-keys))))
        changed-keys)))

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
      (when-let ((node (ebox--buffer-runtime-node buffer node-id)))
        (dolist (region-id buffer-region-ids)
          (when-let ((state (ebox--scroll-get-state region-id)))
            (when (ebox--scroll-state-covers-node-p buffer state node)
              (cl-pushnew region-id region-ids :test #'equal))))))
    (nreverse region-ids)))

(defun ebox--region-ids-visible-via-role-table-p (region-ids)
  "Return non-nil when REGION-IDS have any visible role span in current buffer."
  (when-let ((table (ebox-buffer--region-role-span-table)))
    (catch 'visible
      (dolist (region-id region-ids)
        (dolist (entry ebox-region-types)
          (when (cl-some
                 (lambda (span)
                   (ebox-buffer--current-region-role-span-p
                    span region-id (car entry)))
                 (gethash (ebox-buffer--region-role-key
                           region-id (car entry))
                          table))
            (throw 'visible t))))
      nil)))

(defun ebox--region-ids-role-table-status (table region-ids)
  "Return `current', `stale', or nil for REGION-IDS entries in TABLE."
  (let (indexed)
    (catch 'status
      (dolist (region-id region-ids)
        (dolist (entry ebox-region-types)
          (dolist (span (gethash (ebox-buffer--region-role-key
                                  region-id (car entry))
                                 table))
            (setq indexed t)
            (unless (ebox-buffer--current-region-role-span-p
                     span region-id (car entry))
              (throw 'status 'stale)))))
      (and indexed 'current))))

(defun ebox--region-ids-visible-by-property-scan-p (region-ids)
  "Return non-nil when REGION-IDS appear in current buffer text properties."
  (catch 'visible
    (dolist (region-id region-ids)
      (dolist (entry ebox-region-types)
        (goto-char (point-min))
        (when (text-property-search-forward (cdr entry) region-id t)
          (throw 'visible t))))
    nil))

(defun ebox--region-ids-visible-in-buffer-p (buffer region-ids)
  "Return non-nil when REGION-IDS currently have visible spans in BUFFER."
  (and buffer
       region-ids
       (buffer-live-p buffer)
       (with-current-buffer buffer
         (or (ebox--region-ids-visible-via-role-table-p region-ids)
             (unless (ebox-buffer--region-role-span-table)
               (save-excursion
                 (ebox--region-ids-visible-by-property-scan-p
                  region-ids)))))))

(defun ebox--runtime-node-own-region-ids (node)
  "Return NODE's own wrapper region ids without descending into children."
  (when (listp node)
    (pcase (plist-get node :ebox-type)
      ('box
       (when-let ((region-id (ebox-get node :region-id)))
         (list region-id)))
      ('flex
       (when-let* ((box (plist-get node :box))
                   (region-id (ebox-get box :region-id)))
         (list region-id))))))

(defun ebox--scroll-state-node-visible-p (buffer state node)
  "Return non-nil when NODE occupies STATE's current visible window.
When an empty fixed box has no own text-property span, walk only through its
local wrapper ancestors.  Stop before the scroll owner's direct content
wrapper so one visible row cannot make every hidden descendant look visible."
  (when-let* ((scroll-box (plist-get state :box))
              (scroll-node-id (ebox--ensure-node-id scroll-box))
              (node-id (plist-get node :node-id)))
    (let ((candidate-id node-id)
          (first t))
      (catch 'visible
        (while candidate-id
          (let* ((candidate
                  (ebox--buffer-runtime-node buffer candidate-id))
                 (parent-id
                  (ebox--runtime-parent-id buffer candidate-id)))
            (when (or first (not (equal parent-id scroll-node-id)))
              (when-let ((region-ids
                          (ebox--runtime-node-own-region-ids candidate)))
                (when (or
                       (ebox--region-ids-visible-in-buffer-p
                        buffer region-ids)
                       (ebox--scroll-state-region-visible-in-window-p
                        state region-ids)
                       (ebox--scroll-state-region-visible-in-content-range-p
                        state region-ids))
                  (throw 'visible t))))
            (when (or (equal candidate-id scroll-node-id)
                      (equal parent-id scroll-node-id))
              (setq candidate-id nil))
            (when candidate-id
              (setq candidate-id parent-id
                    first nil))))
        nil))))

(defun ebox--node-visible-in-buffer-p (buffer node)
  "Return non-nil when NODE is represented in BUFFER's visible scroll windows."
  (let ((region-ids (and node (ebox--node-all-region-ids node)))
        containing-states)
    (or (ebox--region-ids-visible-in-buffer-p buffer region-ids)
        (progn
          (maphash
           (lambda (_scroll-region-id state)
             (when (ebox--scroll-state-covers-node-p buffer state node)
               (push state containing-states)))
           ebox--scroll-global-state)
          (and containing-states
               (cl-every
                (lambda (state)
                  (ebox--scroll-state-node-visible-p buffer state node))
                containing-states))))))

(defun ebox--ensure-visible-node-runtime-indexes
    (buffer node &optional primary-region-id)
  "Refresh missing or stale visible role spans for NODE in BUFFER.
A missing table uses a targeted property search before rebuilding the small
rendered viewport.  A present table is authoritative unless requested entries
exist but no longer validate, in which case rebuild it without a property scan."
  (when (and (buffer-live-p buffer) node)
    (let ((region-ids (if primary-region-id
                          (list primary-region-id)
                        (ebox--node-all-region-ids node))))
      (with-current-buffer buffer
        (let ((table (ebox-buffer--region-role-span-table)))
          (if table
              (when (eq (ebox--region-ids-role-table-status
                         table region-ids)
                        'stale)
                (ebox-buffer-refresh-region-role-spans buffer)
                t)
            (when (save-excursion
                    (ebox--region-ids-visible-by-property-scan-p region-ids))
              (ebox-buffer-refresh-region-role-spans buffer)
              t)))))))

(defun ebox--mark-lazy-scroll-covered-hidden-states
    (buffer node region-ids)
  "Mark lazy scroll states covering hidden NODE/REGION-IDS as dirty.
Return the number of marked states.  This preserves deferred hidden-update
performance while preventing later prefix extension from replaying stale cached
lines."
  (let ((count 0))
    (unless (ebox--node-visible-in-buffer-p buffer node)
      (maphash
       (lambda (scroll-region-id state)
         (when (and (plist-get state :materialize-content-lines)
                    (ebox--scroll-state-covers-node-p buffer state node))
           (let* ((content-lines (plist-get state :content-lines))
                  (cached-spans
                   (and content-lines
                        (ebox--scroll-hot-content-line-spans
                         state region-ids))))
             (when (and (not cached-spans)
                        (not (ebox--scroll-state-region-visible-in-window-p
                              state region-ids)))
               (setq state (plist-put state :lazy-scroll-prefix-dirty t))
               (puthash scroll-region-id state ebox--scroll-global-state)
               (cl-incf count)))))
       ebox--scroll-global-state))
    count))

(defun ebox--try-lazy-scroll-deferred-patch
    (buffer region-id node changed-keys)
  "Record a hidden lazy scroll update without materializing its scroll source."
  (when (and buffer node changed-keys)
    (let ((region-ids (ebox--node-all-region-ids node)))
      (when (> (ebox--mark-lazy-scroll-covered-hidden-states
                buffer node region-ids)
               0)
        (ebox--update-report
         region-id 'span-patch
         :dirty-count 1
         :patch-count 0
         :patch-ops nil
         :owner-id (plist-get node :node-id)
         :owner-ids (list (plist-get node :node-id))
         :owner-type (plist-get node :ebox-type)
         :span-count 0
         :scroll-state-patch t
         :lazy-scroll-deferred-patch t
         :dirty-kinds '(geometry)
         :dirty-keys changed-keys)))))

(defun ebox--string-region-role-ids-at (string pos)
  "Return ebox role/id pairs at POS in STRING."
  (let (role-ids)
    (dolist (entry ebox-region-types)
      (when-let ((region-id (get-text-property pos (cdr entry) string)))
        (push (cons (car entry) region-id) role-ids)))
    role-ids))

(defun ebox--string-region-ids-at (string pos)
  "Return all ebox region ids present at POS in STRING."
  (let (ids)
    (dolist (region-id (get-text-property pos 'ebox-content-owners string))
      (cl-pushnew region-id ids :test #'equal))
    (dolist (entry ebox-region-types)
      (when-let ((region-id (get-text-property pos (cdr entry) string)))
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

(defun ebox--scroll-line-region-span-for-ids (line region-ids)
  "Return a conservative owned span for REGION-IDS in LINE.
This lookup searches each role directly in the string property intervals.  It
is optimized for validating a few known rendered-line hints and returns nil
when foreign direct content makes the combined span ambiguous."
  (let ((limit (length line))
        (region-set (ebox--region-id-set region-ids))
        span-start span-end)
    (dolist (region-id region-ids)
      (dolist (entry ebox-region-types)
        (let ((property (cdr entry))
              (pos 0)
              found)
          (while (and (< pos limit)
                      (setq found
                            (text-property-any
                             pos limit property region-id line)))
            (let ((next (or (next-single-property-change
                             found property line limit)
                            limit)))
              (setq span-start (if span-start
                                   (min span-start found)
                                 found)
                    span-end (if span-end
                                 (max span-end next)
                               next)
                    pos (max next (1+ found))))))))
    (let ((pos 0))
      (while (< pos limit)
        (let* ((owners (get-text-property
                        pos 'ebox-content-owners line))
               (next (or (next-single-property-change
                          pos 'ebox-content-owners line limit)
                         limit)))
          (when (cl-some (lambda (region-id)
                           (member region-id owners))
                         region-ids)
            (setq span-start (if span-start (min span-start pos) pos)
                  span-end (if span-end (max span-end next) next)))
          (setq pos (max next (1+ pos))))))
    (when (and span-start span-end)
      (let ((pos span-start)
            (compatible t))
        (while (and compatible (< pos span-end))
          (let* ((content-id
                  (get-text-property pos 'ebox-content line))
                 (next (or (next-single-property-change
                            pos 'ebox-content line span-end)
                           span-end)))
            (when (and content-id
                       (not (gethash content-id region-set)))
              (setq compatible nil))
            (setq pos (max next (1+ pos)))))
        (and compatible (cons span-start span-end))))))

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
                  (when-let ((span (ebox--scroll-line-region-span
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
        (when-let ((region-id (get-text-property pos property line)))
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
      (when-let ((region-id (get-text-property pos 'ebox-content line)))
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
    (if-let ((bounds (gethash region-id index)))
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
               (when-let ((span (ebox--scroll-line-region-span
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
    (when-let ((span (ebox--scroll-line-region-span
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

(defun ebox--scroll-state-ensure-region-line-span-index (state)
  "Return STATE's content line index, building deferred indexes on demand."
  (or (plist-get state :region-line-span-index)
      (when (plist-get state :region-line-span-index-deferred)
        (let ((index (ebox--scroll-build-region-line-span-index
                      (plist-get state :content-lines))))
          (plist-put state :region-line-span-index index)
          (plist-put state :region-line-span-index-deferred nil)
          index))))

(defun ebox--scroll-state-ensure-rendered-line-span-index (state)
  "Return STATE's rendered line index, building deferred indexes on demand."
  (or (plist-get state :rendered-region-line-span-index)
      (when (plist-get state :rendered-region-line-span-index-deferred)
        (let ((index (ebox--scroll-build-region-line-span-index
                      (plist-get state :rendered-content-lines))))
          (plist-put state :rendered-region-line-span-index index)
          (plist-put state :rendered-region-line-span-index-deferred nil)
          index))))

(defun ebox--scroll-state-patch-lines
    (state content-lines content-spans
           &optional rendered-lines _rendered-spans region-ids)
  "Return STATE with patched lines and deferred derived span indexes.
CONTENT-SPANS and REGION-IDS retain bounded line hints for follow-up updates.
An existing full index is downgraded to line-number hints: its character spans
are never trusted after the patch, but every indexed region remains locatable."
  (let ((line-hints
         (when-let ((existing
                     (or (plist-get state :region-line-span-index)
                         (plist-get state :region-line-span-hints))))
           (copy-hash-table existing)))
        (content-region-id-set (plist-get state :content-region-id-set))
        (ebox--defer-scroll-content-index t))
    (setq state
          (ebox--scroll-state-set-lines state content-lines rendered-lines))
    (when (and content-spans region-ids)
      (unless line-hints
        (setq line-hints (make-hash-table :test 'equal)))
      (dolist (region-id region-ids)
        (puthash region-id (copy-tree content-spans) line-hints)))
    (when line-hints
      (setq state
            (plist-put state :region-line-span-hints line-hints)))
    ;; Runtime updates preserve region topology, so an equal-layout line patch
    ;; cannot add or remove ids from the cached prefix.
    (when content-region-id-set
      (setq state
            (plist-put state :content-region-id-set
                       content-region-id-set))))
  state)

(defun ebox--scroll-state-line-spans-for-region-ids (state region-ids)
  "Return cached content line spans for REGION-IDS in scroll STATE."
  (if-let ((index (ebox--scroll-state-ensure-region-line-span-index state)))
      (ebox--scroll-index-line-spans index region-ids)
    (ebox--scroll-state-region-line-spans
     (plist-get state :content-lines) region-ids)))

(defun ebox--scroll-rendered-line-spans-for-region-ids (state region-ids)
  "Return cached rendered-content line spans for REGION-IDS in scroll STATE."
  (if-let ((index (ebox--scroll-state-ensure-rendered-line-span-index state)))
      (ebox--scroll-index-line-spans index region-ids)
    (when-let ((lines (plist-get state :rendered-content-lines)))
      (ebox--scroll-state-region-line-spans lines region-ids))))

(defun ebox--scroll-hot-content-line-spans (state region-ids)
  "Return content spans for REGION-IDS without building a deferred full index.
Dynamic updates reuse an already prepared index.  When no ready index exists,
scan for only REGION-IDS; building the all-region index synchronously is much
more expensive than the targeted fallback on a long lazy prefix."
  (if-let ((index (plist-get state :region-line-span-index)))
      ;; A ready exact index already proves both membership and spans.  Building
      ;; the prefix-wide membership set first adds an O(prefix) tax to visible
      ;; updates after scrolling.
      (ebox--scroll-index-line-spans index region-ids)
    (let ((content-region-id-set
           (ebox--scroll-state-ensure-content-region-id-set state)))
      (when (ebox--scroll-region-id-set-intersects-p
             content-region-id-set region-ids)
        (let ((hints (plist-get state :region-line-span-hints)))
          (if-let ((hint-spans
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
                 (when-let ((span (ebox--scroll-line-region-span
                                   line region-set)))
                   (push (cons line-index span) spans)))
               (setq indices (cdr indices)))))
    (nreverse spans)))

(defun ebox--scroll-hot-rendered-line-spans
    (state region-ids content-spans)
  "Return rendered spans for REGION-IDS without building a deferred index.
Reuse a ready rendered index; otherwise inspect only lines named by
CONTENT-SPANS, whose line numbers are aligned with rendered scroll lines."
  (if-let ((index (plist-get state :rendered-region-line-span-index)))
      (ebox--scroll-index-line-spans index region-ids)
    (when-let ((lines (plist-get state :rendered-content-lines)))
      (if (cl-every
           (lambda (entry)
             (equal (cdr entry)
                    (ebox--scroll-line-region-span-for-ids
                     (nth (car entry) lines) region-ids)))
           content-spans)
          ;; The rendered copy can add outer wrapper ownership while retaining
          ;; the exact target span.  Reuse only after direct-role validation.
          content-spans
        (ebox--scroll-line-spans-at-index-hints
         lines region-ids content-spans)))))

(defun ebox--cancel-buffer-reflow-cache-prewarm (buffer)
  "Cancel pending predicted reflow-cache warming for BUFFER."
  (when-let ((timer (gethash buffer ebox--reflow-cache-prewarm-timers)))
    (when (timerp timer)
      (cancel-timer timer)))
  (remhash buffer ebox--reflow-cache-prewarm-timers))

(defun ebox--cancel-buffer-runtime-prewarm (buffer)
  "Cancel and discard pending runtime prewarming for BUFFER."
  (ebox--cancel-buffer-reflow-cache-prewarm buffer)
  (when-let ((timer (gethash buffer ebox--runtime-prewarm-timers)))
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
          (let ((rendered
                 (ebox--render-with-cache
                  (plist-get scratch :tree) t)))
            (ebox--rendered-root-metadata rendered)))))))

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
  (when-let ((owner (car (ebox--node-path-to-region root region-id))))
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
              (ebox-put box-copy :width target-width)
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
  (when-let ((state (and (ebox--reflow-cache-prewarm-enabled-p)
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

(defun ebox--runtime-prewarm-new-job (state)
  "Return a new runtime prewarm job for render STATE."
  (list :render-state state
        :runtime-revision (or (plist-get state :runtime-revision) 0)
        :phase 'role-index
        :snapshot-stack
        (when-let ((root (plist-get state :root-node)))
          (list (vector root :uninitialized t t)))
        :node-region-ids-cache (make-hash-table :test 'eq)
        :viewport-width-ids-rev nil
        :viewport-height-ids-rev nil
        :scroll-region-ids (plist-get state :scroll-region-ids)
        :scroll-sources nil
        :scroll-task nil))

(defun ebox--runtime-prewarm-role-index-slice (buffer job)
  "Materialize BUFFER's prepared publication indexes before interactions."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((table (ebox-buffer--region-role-span-table)))
        (unless (ebox-buffer--marker-role-span-table-p table)
          (ebox-buffer-materialize-region-role-spans buffer)))
      (unless (or (ebox--materialize-box-extent-template buffer)
                  (when-let* ((root-id (ebox--buffer-root-node-id buffer))
                              (extents (gethash root-id ebox--box-extents)))
                    (and (eq (marker-buffer (car extents)) buffer)
                         (eq (marker-buffer (cdr extents)) buffer))))
        (ebox--clear-buffer-extents buffer)
        (ebox--register-box-extents-in-range (point-min) (point-max)))))
  (plist-put job :phase 'snapshots))

(defun ebox--runtime-prewarm-schedule-timer (buffer &optional delay)
  "Schedule BUFFER's next runtime prewarm slice after DELAY."
  (when (and (buffer-live-p buffer)
             (gethash buffer ebox--runtime-prewarm-jobs))
    (when-let ((old (gethash buffer ebox--runtime-prewarm-timers)))
      (when (timerp old)
        (cancel-timer old)))
    (puthash buffer
             (run-with-idle-timer
              (max 0 (or delay ebox-runtime-idle-prewarm-delay))
              nil #'ebox--runtime-prewarm-timer buffer)
             ebox--runtime-prewarm-timers)))

(defun ebox--schedule-buffer-runtime-prewarm (buffer &optional delay)
  "Schedule shared incremental-update prewarming for BUFFER."
  (ebox--cancel-buffer-runtime-prewarm buffer)
  (when-let ((state (and (ebox--runtime-prewarm-enabled-p)
                         (buffer-live-p buffer)
                         (ebox--buffer-render-state buffer))))
    (puthash buffer (ebox--runtime-prewarm-new-job state)
             ebox--runtime-prewarm-jobs)
    (ebox--runtime-prewarm-schedule-timer buffer delay)))

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
      (when-let ((state (ebox--buffer-render-state buffer)))
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
      (when-let ((span (ebox--scroll-line-region-span
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
                (not (eq (plist-get job :phase) 'done)))
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
          (when-let ((task
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
        (plist-put job :phase 'done))))))

(defun ebox--runtime-prewarm-step (buffer)
  "Run one bounded runtime prewarm slice for BUFFER.
Return non-nil while more work remains."
  (when-let ((job (gethash buffer ebox--runtime-prewarm-jobs)))
    (let ((state (ebox--buffer-render-state buffer)))
      (if (or (not (buffer-live-p buffer))
              (not (eq state (plist-get job :render-state)))
              (/= (or (plist-get state :runtime-revision) 0)
                  (plist-get job :runtime-revision)))
          (ebox--cancel-buffer-runtime-prewarm buffer)
        (pcase (plist-get job :phase)
          ('role-index
           (ebox--runtime-prewarm-role-index-slice buffer job))
          ('snapshots
           (ebox--runtime-prewarm-snapshot-slice buffer job))
          ('scroll
           (ebox--runtime-prewarm-scroll-slice buffer job)))
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
  (when-let ((timer (gethash buffer ebox--runtime-prewarm-timers)))
    (when (timerp timer)
      (cancel-timer timer))
    (remhash buffer ebox--runtime-prewarm-timers))
  (let ((limit 100000)
        completed)
    (while (and (> limit 0) (not completed))
      (unless (gethash buffer ebox--runtime-prewarm-jobs)
        (when-let ((state (and (buffer-live-p buffer)
                               (ebox--buffer-render-state buffer))))
          (puthash buffer (ebox--runtime-prewarm-new-job state)
                   ebox--runtime-prewarm-jobs)))
      (if (ebox--runtime-prewarm-step buffer)
          (setq limit (1- limit))
        (setq completed t)))
    (when (not completed)
      (error "Runtime prewarm did not converge for %S" buffer))))

(defun ebox--refresh-layout-snapshots-for-node (buffer node)
  "Refresh lightweight snapshots for NODE's runtime subtree in BUFFER."
  (ebox--invalidate-buffer-layout-snapshot-details buffer)
  (let ((ebox--node-region-ids-cache (make-hash-table :test 'eq)))
    (ebox--capture-layout-snapshots buffer node)))

(defun ebox--scroll-line-with-preserved-wrapper-owner
    (line span replacement rendered-owner-set)
  "Return REPLACEMENT preserving wrapper context from LINE SPAN.
RENDERED-OWNER-SET identifies owners supplied by the complete fresh render."
  (let ((owners (or (get-text-property (car span) 'ebox-content-owners line)
                   (when-let ((owner (get-text-property
                                      (car span)
                                      'ebox-content-owner
                                      line)))
                     (list owner)))))
    (if owners
        (ebox--string-with-preserved-wrapper-context
         replacement owners rendered-owner-set)
      replacement)))

(defun ebox--scroll-pad-line-to-slot-width (line width)
  "Return LINE padded to visual slot WIDTH, or nil when LINE is too wide."
  (let* ((line-width (ebox--string-pixel-width line))
         (extra (- width line-width)))
    (when (>= extra 0)
      (concat line (ebox-pixel-space extra)))))

(defun ebox--scroll-patch-lines-for-region
    (lines region-ids rendered &optional spans rendered-owner-set)
  "Return LINES with REGION-IDS replaced by RENDERED, or nil on mismatch.
RENDERED-OWNER-SET reuses an existing content-owner scan when supplied."
  (let* ((spans (or spans
                    (ebox--scroll-state-region-line-spans lines region-ids)))
         (rendered-lines (ebox-string-lines rendered))
         (rendered-owner-set
          (or rendered-owner-set
              (ebox--string-content-owner-set rendered))))
    (when (and spans
               (<= (length rendered-lines) (length spans)))
      (catch 'failed
        (let ((result (copy-sequence lines)))
          (cl-loop for entry in spans
                   for replacement = (or (pop rendered-lines)
                                         (ebox-pixel-space 0))
                   do
                   (let* ((idx (car entry))
                          (span (cdr entry))
                          (line (nth idx result))
                          (old-slot (substring line (car span) (cdr span)))
                          (slot-width (ebox--string-pixel-width old-slot))
                          (padded (ebox--scroll-pad-line-to-slot-width
                                   replacement slot-width)))
                     (unless padded
                       (throw 'failed nil))
                     (setq padded
                           (ebox--scroll-line-with-preserved-wrapper-owner
                            line span padded rendered-owner-set))
                     (setf (nth idx result)
                           (concat (substring line 0 (car span))
                                   padded
                                   (substring line (cdr span))))))
          result)))))

(defun ebox--scroll-patch-rendered-lines-for-region
    (state region-ids rendered)
  "Return rendered content lines patched for REGION-IDS, or nil."
  (when-let* ((rendered-lines (plist-get state :rendered-content-lines))
              (rendered-spans
               (ebox--scroll-rendered-line-spans-for-region-ids
                state region-ids)))
    (ebox--scroll-patch-lines-for-region
     rendered-lines region-ids rendered rendered-spans)))

(defun ebox--scroll-state-visible-range (state)
  "Return visible content index range for scroll STATE as (START . END)."
  (let* ((content-lines (plist-get state :content-lines))
         (content-height (or (plist-get state :content-height) 0))
         (max-offset (max 0 (- (length content-lines) content-height)))
         (scroll-offset (max 0 (min max-offset
                                     (or (plist-get state :scroll-offset)
                                         0)))))
    (cons scroll-offset
          (min (+ scroll-offset content-height)
               (length content-lines)))))

(defun ebox--scroll-state-spans-visible-p (state spans)
  "Return non-nil when any SPANS entry falls inside STATE's visible range."
  (pcase-let ((`(,start . ,end) (ebox--scroll-state-visible-range state)))
    (cl-some (lambda (entry)
               (let ((idx (car entry)))
                 (and (>= idx start) (< idx end))))
             spans)))

(defun ebox--scroll-apply-visible-node-span-patch
    (buffer node changed-keys region-ids rendered rendered-owner-set)
  "Patch visible NODE directly while its cached scroll lines are synchronized.
Return backend patch metadata on success.  The ordinary span backend preserves
the current parent slot and wrapper paint, avoiding a fixed-height scroll
viewport replacement when only NODE's proven-stable visible spans changed.
RENDERED and RENDERED-OWNER-SET reuse the scroll cache patch's fresh render."
  (let* ((node-id (plist-get node :node-id))
         (dirty (list :node-id node-id
                      :dirty-kind 'geometry
                      :changed-keys changed-keys
                      :region-ids region-ids))
         (op (list :op 'span-patch :owner-id node-id :dirty dirty))
         (result (ebox-buffer-apply-span-patch
                  buffer op rendered rendered-owner-set)))
    (when result
      (ebox--refresh-runtime-indexes-for-patch-results
       buffer (list result) 'span-patch)
      (ebox--refresh-text-patch-layout-snapshots buffer (list result))
      result)))

(defun ebox--try-scroll-state-span-patch
    (buffer region-id node changed-keys
            &optional skip-materialize allow-nonlocal-keys)
  "Patch cached scroll state lines for REGION-ID/NODE in BUFFER.
Return an update report when all containing scroll states were patched.
When ALLOW-NONLOCAL-KEYS is non-nil, the rendered replacement still must fit
the cached line slots, but CHANGED-KEYS need not belong to the visible-buffer
span-patch whitelist.  This is used only for semantically hidden nodes."
  (when (and buffer node
             changed-keys
             (or allow-nonlocal-keys
                 (ebox--scroll-state-span-patch-keys-p changed-keys)))
    (let* ((region-ids (ebox--node-all-region-ids node))
           (containing-scroll-state-count
            (ebox--node-containing-scroll-state-count buffer node))
           rendered
           rendered-owner-set
           patched visible-patched span-count
           rendered-range-patched
           index-used
           visible-buffer-patched
           visible-direct-patched
           patches
           (ok
            (catch 'scroll-state-patch-failed
              (maphash
               (lambda (scroll-region-id state)
                 (when (and
                        (ebox--scroll-state-covers-node-p buffer state node)
                        ;; A scroll container's own offset is state, not one
                        ;; of its cached descendant lines.  Treating the whole
                        ;; container as a line replacement can publish the new
                        ;; viewport while leaving :scroll-offset stale.
                        (not (and (equal changed-keys '(:scroll-offset))
                                  (equal scroll-region-id region-id))))
                   (let* ((content-lines (plist-get state :content-lines))
                          (content-spans
                           (and content-lines
                                (progn
                                  (when (plist-get
                                         state :region-line-span-index)
                                    (setq index-used t))
                                  (ebox--scroll-hot-content-line-spans
                                   state region-ids)))))
                     (when (and (not skip-materialize)
                                (not content-spans)
                                (not (ebox--node-visible-in-buffer-p
                                      buffer node))
                                (plist-get state :materialize-content-lines))
                       (setq state
                             (ebox--scroll-state-materialize-lines
                              scroll-region-id state))
                       (setq content-lines (plist-get state :content-lines))
                       (setq content-spans
                             (and content-lines
                                  (progn
                                    (when (plist-get
                                           state :region-line-span-index)
                                      (setq index-used t))
                                    (ebox--scroll-hot-content-line-spans
                                     state region-ids)))))
                     (when content-spans
                       (unless rendered
                         (setq rendered
                               (ebox--with-buffer-render-context buffer
                                 (or
                                  (when-let ((snapshot
                                              (and
                                               (ebox--node-visible-in-buffer-p
                                                buffer node)
                                               (ebox--direct-flex-parent-p
                                                buffer
                                                (plist-get node :node-id))
                                               (ebox--ensure-layout-snapshot-spans
                                                buffer
                                                (plist-get node :node-id)))))
                                    (ebox--render-node-in-current-flex-slot
                                     buffer
                                     (plist-get node :node-id)
                                     snapshot changed-keys))
                                  (ebox-render node))))
                         (setq rendered-owner-set
                               (ebox--string-content-owner-set rendered)))
                       (let* ((new-content-lines
                               (ebox--scroll-patch-lines-for-region
                                content-lines region-ids rendered
                                content-spans rendered-owner-set))
                              (rendered-lines
                               (plist-get state :rendered-content-lines))
                              (rendered-spans
                               (and rendered-lines
                                    (progn
                                      (when (plist-get
                                             state
                                             :rendered-region-line-span-index)
                                        (setq index-used t))
                                      (ebox--scroll-hot-rendered-line-spans
                                       state region-ids content-spans))))
                              (new-rendered-lines
                               (if rendered-lines
                                   (ebox--scroll-patch-lines-for-region
                                    rendered-lines region-ids rendered
                                    rendered-spans rendered-owner-set)
                                 nil)))
                         (unless (and new-content-lines
                                      (or (not rendered-lines)
                                          new-rendered-lines))
                           (throw 'scroll-state-patch-failed nil))
                         (setq patched t)
                         (when (and rendered-lines new-rendered-lines)
                           (setq rendered-range-patched t))
                         (setq span-count (+ (or span-count 0)
                                             (length content-spans)))
                         (push (list :scroll-region-id scroll-region-id
                                     :state state
                                     :content-lines new-content-lines
                                     :rendered-lines new-rendered-lines
                                     :has-rendered-lines rendered-lines
                                     :content-spans content-spans
                                     :rendered-spans rendered-spans)
                               patches))))))
               ebox--scroll-global-state)
              t)))
      (when (and ok patched)
        (catch 'scroll-state-apply-failed
          (dolist (patch (nreverse patches))
            (let ((state (plist-get patch :state))
                  (scroll-region-id (plist-get patch :scroll-region-id))
                  (new-content-lines (plist-get patch :content-lines)))
              (setq state
                    (ebox--scroll-state-patch-lines
                     state new-content-lines
                     (plist-get patch :content-spans)
                     (and (plist-get patch :has-rendered-lines)
                          (plist-get patch :rendered-lines))
                     (plist-get patch :rendered-spans)
                     region-ids))
              (puthash scroll-region-id state ebox--scroll-global-state)
              (when (ebox--scroll-state-spans-visible-p
                     state (plist-get patch :content-spans))
                (setq visible-patched t)
                (unless visible-buffer-patched
                  (setq visible-direct-patched
                        (ebox--scroll-apply-visible-node-span-patch
                         buffer node changed-keys region-ids
                         rendered rendered-owner-set))
                  (setq visible-buffer-patched
                        (or visible-direct-patched
                            (and
                             (= containing-scroll-state-count 1)
                             (let* ((range
                                     (ebox--scroll-state-visible-range state))
                                    (visible-lines
                                     (seq-subseq new-content-lines
                                                 (car range) (cdr range))))
                               (with-current-buffer buffer
                                 (ebox--scroll-update-content
                                  scroll-region-id visible-lines))))))
                  (unless visible-buffer-patched
                    (throw 'scroll-state-apply-failed nil))))))
          (when visible-patched
            (unless visible-direct-patched
              (ebox--refresh-layout-snapshots-for-node buffer node)))
          (ebox--update-report
           region-id 'span-patch
           :dirty-count 1
           :patch-count 1
           :patch-ops '(span-patch)
           :owner-id (plist-get node :node-id)
           :owner-ids (list (plist-get node :node-id))
           :owner-type (plist-get node :ebox-type)
           :span-count span-count
           :scroll-state-patch t
           :scroll-state-index index-used
           :scroll-rendered-range-patch rendered-range-patched
           :dirty-kinds '(geometry)
           :dirty-keys changed-keys))))))

(defun ebox--try-hidden-scroll-state-span-patch
    (buffer region-id node changed-keys)
  "Patch cached scroll lines for hidden NODE without touching the live buffer.
Complete scroll states still contain offscreen formatted lines, so safe
  slot-compatible geometry changes should update those lines directly instead
of falling through to a live owner rerender at stale viewport coordinates."
  (when (and buffer node changed-keys)
    (when (and (not (ebox--node-visible-in-buffer-p buffer node))
               (= (ebox--node-containing-scroll-state-count buffer node)
                  1))
      (ebox--try-scroll-state-span-patch
       buffer region-id node changed-keys t t))))

(defun ebox--node-containing-scroll-state-count (buffer node)
  "Return the number of BUFFER scroll states that contain NODE."
  (let ((count 0))
    (maphash
     (lambda (_scroll-region-id state)
       (when (ebox--scroll-state-covers-node-p buffer state node)
         (setq count (1+ count))))
     ebox--scroll-global-state)
    count))

(defun ebox--try-hidden-scroll-root-fallback
    (buffer region-id node changed-keys)
  "Rerender BUFFER root when a hidden scroll cache patch cannot fit.
This correctness fallback preserves the current scroll offset and never treats
offscreen owner coordinates as live patch spans."
  (let ((region-ids (and node (ebox--node-all-region-ids node))))
    (when (and buffer node region-ids
               (not (ebox--node-visible-in-buffer-p buffer node))
               (> (ebox--node-containing-scroll-state-count buffer node) 0))
      (ebox-buffer-apply-root-rerender buffer)
      (ebox--update-report
       region-id 'root-rerender
       :dirty-count 1
       :patch-count 0
       :patch-ops nil
       :owner-id (ebox--buffer-root-node-id buffer)
       :owner-ids (list (ebox--buffer-root-node-id buffer))
       :root-rerender t
       :scroll-state-patch t
       :dirty-kinds '(geometry)
       :dirty-keys changed-keys))))

(defun ebox--sync-scroll-state-lines-for-node-fallback
    (buffer region-id node changed-keys report)
  "Synchronize cached scroll lines for updated NODE in BUFFER by rerendering.
Ordinary incremental patching mutates the visible buffer.  Scroll containers
also keep their own cached content lines, so those lines must be updated or a
later scroll-window replacement can replay stale content."
  (when (and buffer node changed-keys)
    (let* ((region-ids (ebox--node-all-region-ids node))
           targets
           rendered
           patched-count
           refreshed-count
           deferred-count
           failed-count
           span-count
           marker-refresh-count
           (visible-node-p
            (ebox--node-visible-in-buffer-p buffer node)))
      (maphash
       (lambda (scroll-region-id state)
         (when (and
                (ebox--scroll-state-covers-node-p buffer state node)
                ;; The dedicated scroll-offset transaction has already
                ;; committed this container's own state/window.  Only outer
                ;; containing scroll caches still need the rendered node.
                (not (and (equal changed-keys '(:scroll-offset))
                          (equal scroll-region-id region-id))))
           (let* ((content-lines (plist-get state :content-lines))
                  (content-spans
                   (and content-lines
                        (ebox--scroll-hot-content-line-spans
                         state region-ids))))
             (when (or content-spans visible-node-p)
               (push (list :scroll-region-id scroll-region-id
                           :state state
                           :content-lines content-lines
                           :content-spans content-spans
                           :rendered-lines
                           (plist-get state :rendered-content-lines))
                     targets)))))
       ebox--scroll-global-state)
      (when targets
        (setq rendered
              (ebox--with-buffer-render-context buffer
                (or
                 (when-let ((snapshot
                             (and
                              visible-node-p
                              (ebox--direct-flex-parent-p
                               buffer (plist-get node :node-id))
                              (ebox--ensure-layout-snapshot-spans
                               buffer (plist-get node :node-id)))))
                   (ebox--render-node-in-current-flex-slot
                    buffer (plist-get node :node-id) snapshot changed-keys))
                 (ebox-render node))))
        (dolist (target targets)
          (let* ((scroll-region-id (plist-get target :scroll-region-id))
                 (state (plist-get target :state))
                 (content-lines (plist-get target :content-lines))
                 (content-spans (plist-get target :content-spans))
                 (new-content-lines
                  (ebox--scroll-patch-lines-for-region
                   content-lines region-ids rendered content-spans))
                 (rendered-lines (plist-get target :rendered-lines))
                 (rendered-spans
                  (and new-content-lines rendered-lines
                       (ebox--scroll-hot-rendered-line-spans
                        state region-ids content-spans)))
                 (new-rendered-lines
                  (if (and new-content-lines rendered-lines)
                      (and rendered-spans
                           (ebox--scroll-patch-lines-for-region
                            rendered-lines region-ids rendered
                            rendered-spans))
                    nil)))
            (when (and new-content-lines
                       (or (not rendered-lines)
                           new-rendered-lines))
              (setq state
                    (ebox--scroll-state-patch-lines
                     state new-content-lines content-spans
                     (and rendered-lines new-rendered-lines)
                     rendered-spans region-ids))
              (setq state (plist-put state :buffer buffer))
              (puthash scroll-region-id state ebox--scroll-global-state)
              (plist-put target :cache-synchronized t)
              (setq patched-count (1+ (or patched-count 0)))
              (setq span-count (+ (or span-count 0)
                                  (length content-spans))))
            (unless (and new-content-lines
                         (or (not rendered-lines)
                             new-rendered-lines))
              ;; A geometry change can outgrow its cached line slot.  Lazy
              ;; prefixes can be rebuilt from the current runtime tree.  A
              ;; visible update must publish that cache generation before it
              ;; returns; otherwise redisplay can expose a buffer/state split
              ;; until an unrelated annotation or scroll repairs the window.
              (if (plist-get state :render-content-prefix)
                  (progn
                    (setq state
                          (plist-put state :lazy-scroll-prefix-dirty t))
                    (puthash scroll-region-id state
                             ebox--scroll-global-state)
                    (let* ((required-lines
                            (+ (or (plist-get state :scroll-offset) 0)
                               (or (plist-get state :content-height) 0)))
                           (rebuilt
                            (ebox--scroll-state-ensure-prefix-lines
                             scroll-region-id state required-lines t)))
                      (if (plist-get rebuilt :lazy-scroll-prefix-dirty)
                          (progn
                            (plist-put target :deferred t)
                            (setq deferred-count
                                  (1+ (or deferred-count 0))))
                        (plist-put target :cache-synchronized t))))
                ;; A complete window has no prefix producer left to
                ;; rebuild from.  The publication itself was verified
                ;; by footprint proofs and only touched visible rows,
                ;; so adopting the published window back into the
                ;; cache is exact; marker verification below still
                ;; guards the result.
                (let ((adopted
                       (ebox--scroll-state-adopt-buffer-window-lines
                        buffer scroll-region-id state)))
                  (if adopted
                      (progn
                        (setq adopted
                              (plist-put adopted :buffer buffer))
                        (puthash scroll-region-id adopted
                                 ebox--scroll-global-state)
                        (plist-put target :cache-synchronized t)
                        (setq patched-count
                              (1+ (or patched-count 0))))
                    (plist-put target :failed t)
                    (setq failed-count
                          (1+ (or failed-count 0))))))))))
      ;; Commit one marker generation after every cache mutation.  Marker-only
      ;; publication never rewrites visible text, so nested scroll windows
      ;; cannot invalidate each other as they did with per-state zero-delta
      ;; scrolling.
      (when targets
        (ebox--refresh-buffer-scroll-content-markers buffer)
        (dolist (target targets)
          (when (plist-get target :cache-synchronized)
            (let* ((scroll-region-id (plist-get target :scroll-region-id))
                   (state (ebox--scroll-get-state scroll-region-id)))
              (if (and state
                       (ebox--scroll-state-window-markers-healthy-p
                        buffer scroll-region-id state))
                  (progn
                    (when (plist-get
                           state :lazy-scroll-window-refresh-required)
                      (setq refreshed-count
                            (1+ (or refreshed-count 0))))
                    (setq state
                          (ebox--plist-remove
                           state :lazy-scroll-window-refresh-required))
                    (puthash scroll-region-id state
                             ebox--scroll-global-state)
                    (setq marker-refresh-count
                          (1+ (or marker-refresh-count 0))))
                (unless (plist-get target :failed)
                  ;; In-slot patching cannot represent structural line
                  ;; changes (for example :overflow transitions adding
                  ;; or removing unowned visible-overflow lines), and
                  ;; the divergence only surfaces at this verification.
                  ;; The published window is footprint-verified truth,
                  ;; so first adopt it back into the visible cache
                  ;; slice; only when adoption cannot apply rebuild the
                  ;; prefix from the current runtime exactly like the
                  ;; outgrown-slot branch.  Publishing a stale cache
                  ;; that carries no repair marker is never an option.
                  (cl-flet ((verify ()
                              (ebox--refresh-buffer-scroll-content-markers
                               buffer)
                              (when-let ((current
                                          (ebox--scroll-get-state
                                           scroll-region-id)))
                                (ebox--scroll-state-window-markers-healthy-p
                                 buffer scroll-region-id current))))
                    (let* ((adopted
                            (when-let ((current
                                        (ebox--scroll-get-state
                                         scroll-region-id)))
                              (ebox--scroll-state-adopt-buffer-window-lines
                               buffer scroll-region-id current)))
                           (healthy
                            (when adopted
                              (puthash scroll-region-id
                                       (plist-put adopted :buffer buffer)
                                       ebox--scroll-global-state)
                              (verify)))
                           (rebuilt-healthy
                            (unless healthy
                              (when (plist-get
                                     state :render-content-prefix)
                                (setq state
                                      (plist-put
                                       state :lazy-scroll-prefix-dirty
                                       t))
                                (puthash scroll-region-id state
                                         ebox--scroll-global-state)
                                (let* ((required-lines
                                        (+ (or (plist-get
                                                state :scroll-offset)
                                               0)
                                           (or (plist-get
                                                state :content-height)
                                               0)))
                                       (rebuilt
                                        (ebox--scroll-state-ensure-prefix-lines
                                         scroll-region-id state
                                         required-lines t)))
                                  (and rebuilt
                                       (not (plist-get
                                             rebuilt
                                             :lazy-scroll-prefix-dirty))
                                       (verify))))))
                           (healthy (or healthy rebuilt-healthy)))
                    (if healthy
                        (progn
                          (when-let ((current (ebox--scroll-get-state
                                               scroll-region-id)))
                            (puthash scroll-region-id
                                     (ebox--plist-remove
                                      current
                                      :lazy-scroll-window-refresh-required)
                                     ebox--scroll-global-state))
                          (setq refreshed-count
                                (1+ (or refreshed-count 0))
                                marker-refresh-count
                                (1+ (or marker-refresh-count 0))))
                      (plist-put target :failed t)
                      (setq failed-count
                            (1+ (or failed-count 0))))))))))))
      (if (or patched-count refreshed-count deferred-count failed-count)
          (append report
                  (list :scroll-state-sync
                        (and (not (null (or patched-count
                                           refreshed-count)))
                             (= (or deferred-count 0) 0)
                             (= (or failed-count 0) 0))
                        :scroll-state-sync-count patched-count
                        :scroll-state-sync-span-count
                        (or span-count 0)
                        :scroll-state-sync-refreshed
                        (not (null refreshed-count))
                        :scroll-state-sync-refreshed-count
                        (or refreshed-count 0)
                        :scroll-state-sync-deferred
                        (not (null deferred-count))
                        :scroll-state-sync-deferred-count
                        (or deferred-count 0)
                        :scroll-state-sync-failed-count
                        (or failed-count 0)
                        :scroll-state-window-marker-refresh-count
                        (or marker-refresh-count 0)
                        :scroll-state-window-markers-invalidated
                        (and (not (null patched-count))
                             (null marker-refresh-count))))
        report))))

(defun ebox--scroll-line-role-spans (line role region-set)
  "Return spans in LINE where ROLE belongs to REGION-SET."
  (let* ((property (ebox-buffer--role-property role))
         (limit (length line))
         (pos 0)
         spans)
    (while (< pos limit)
      (let* ((next (or (next-single-property-change pos property line limit)
                       limit))
             (region-id (get-text-property pos property line)))
        (when (and region-id (gethash region-id region-set))
          (push (cons pos next) spans))
        (setq pos next)))
    (nreverse spans)))

(defun ebox--scroll-patch-face-key-in-line-span (line start end key value)
  "Patch LINE face KEY to VALUE in START..END."
  (let ((pos start))
    (while (< pos end)
      (let* ((next (or (next-single-property-change pos 'face line end)
                       end))
             (face (get-text-property pos 'face line)))
        (put-text-property pos next 'face
                           (ebox-buffer--face-put face key value)
                           line)
        (setq pos next)))))

(defun ebox--scroll-patch-horizontal-border-face-in-line-span
    (line start end key value)
  "Patch horizontal border face KEY to VALUE in LINE START..END."
  (if (eq value ebox-buffer--remove-face-key)
      (ebox--scroll-patch-face-key-in-line-span line start end key value)
    (add-face-text-property start end (list key value) nil line)))

(defun ebox--scroll-paint-lines-for-region
    (lines region-ids surfaces &optional candidate-spans)
  "Return LINES with paint SURFACES patched for REGION-IDS.
CANDIDATE-SPANS limits scanning to known lines owned by REGION-IDS.  Return a
plist with :lines and possibly empty :spans, or nil when a required inferred
surface is absent."
  (let* ((region-set (ebox--region-id-set region-ids))
         (result (copy-sequence lines))
         (line-indices (if candidate-spans
                           (delete-dups
                            (mapcar #'car (copy-sequence candidate-spans)))
                         (number-sequence 0 (1- (length lines)))))
         changed-spans
         failed)
    (catch 'failed
      (dolist (spec surfaces)
        (let ((role (plist-get spec :role))
              (face-key (plist-get spec :face-key))
              (face-value (plist-get spec :face-value))
              (missing (plist-get spec :missing))
              (remove-role (plist-get spec :remove-role))
              (surface-patched nil))
          (dolist (idx line-indices)
            (when-let ((line (nth idx result)))
              (let ((line-copy nil))
                (dolist (span (ebox--scroll-line-role-spans
                               line role region-set))
                  (unless line-copy
                    (setq line-copy (copy-sequence line))
                    (setf (nth idx result) line-copy))
                  (if (memq role '(bt bb))
                      (ebox--scroll-patch-horizontal-border-face-in-line-span
                       line-copy (car span) (cdr span) face-key face-value)
                    (ebox--scroll-patch-face-key-in-line-span
                     line-copy (car span) (cdr span) face-key face-value))
                  (when remove-role
                    (remove-text-properties
                     (car span) (cdr span)
                     (list (ebox-buffer--role-property role) nil)
                     line-copy))
                  (push (cons idx span) changed-spans)
                  (setq surface-patched t)))))
          (when (and (not surface-patched)
                     (eq missing 'infer))
            (setq failed t)
            (throw 'failed nil))))
      (unless failed
        (list :lines result :spans (nreverse changed-spans))))))

(defun ebox--scroll-state-adopt-buffer-window-lines (buffer region-id state)
  "Adopt BUFFER's live window text into STATE's visible rendered cache.
Buffer and cache paint patches run through different patchers, so
visually identical lines can diverge in raw representation.  The
published buffer is the display truth: copying its window lines back
over the visible slice of `:rendered-content-lines' restores exact
representational identity, which keeps later window verification on
the cheap raw-equality path and keeps the settled cache replaying
exactly what is on screen.  Only chrome-free windows adopt; decorated
windows keep their semantically patched lines.  Return the updated
state, or nil when no adoption happened."
  (when-let* ((box (plist-get state :box))
              ((ebox--scroll-chrome-free-rendered-window-p box))
              (rendered-lines (plist-get state :rendered-content-lines))
              (height (plist-get state :content-height))
              ((integerp height))
              ((> height 0))
              (extents (ebox--scroll-state-window-extents region-id state))
              (start (car extents))
              (end (cdr extents))
              ((markerp start))
              ((markerp end))
              ((eq (marker-buffer start) buffer))
              ((eq (marker-buffer end) buffer))
              (start-pos (marker-position start))
              (end-pos (marker-position end))
              ((< start-pos end-pos)))
    (with-current-buffer buffer
      (when (= (count-lines start-pos end-pos) height)
        (let* ((window-lines
                (ebox-string-lines
                 (buffer-substring start-pos end-pos)))
               (offset (or (plist-get state :scroll-offset) 0)))
          (when (and (= (length window-lines) height)
                     (<= (+ offset height) (length rendered-lines)))
            (let ((copy (copy-sequence rendered-lines)))
              (cl-loop for line in window-lines
                       for index from offset
                       do (setf (nth index copy) line))
              (setq state
                    (plist-put state :rendered-content-lines copy)))
            (when-let* ((content-lines (plist-get state :content-lines))
                        ((<= (+ offset height) (length content-lines))))
              (let ((copy (copy-sequence content-lines)))
                (cl-loop for line in window-lines
                         for index from offset
                         do (setf (nth index copy) line))
                (setq state (plist-put state :content-lines copy))))
            state))))))

(defun ebox--sync-scroll-state-paint-lines-for-node
    (buffer node changed-keys report)
  "Synchronize scroll cached lines for NODE paint-only CHANGED-KEYS.
This mirrors buffer paint patches by editing cached line text properties rather
than rerendering NODE, keeping GUI dynamic updates bounded."
  (when-let* ((surfaces (and (cl-every
                              (lambda (key)
                                (memq key ebox--paint-style-signature-keys))
                              changed-keys)
                             (ebox--paint-text-property-surfaces
                              node changed-keys)))
              (_ (ebox-buffer--paint-surfaces-safe-for-node-p
                  node surfaces)))
    (let* ((region-ids (ebox--node-all-region-ids node))
           (index-stable
            (cl-every (lambda (spec)
                        (not (plist-get spec :remove-role)))
                      surfaces))
           patched-region-ids
           patched-count
           span-count)
      (catch 'failed
        (maphash
         (lambda (scroll-region-id state)
           (let ((covering-lazy-state
                  (and (plist-get state :materialize-content-lines)
                       (not (plist-get state :content-lines-complete-p))
                       (ebox--scroll-state-covers-node-p
                        buffer state node))))
             (let* ((content-lines (plist-get state :content-lines))
                    (content-spans
                     (and content-lines
                          (ebox--scroll-hot-content-line-spans
                           state region-ids))))
               (if (not content-spans)
                   (when covering-lazy-state
                     (setq state
                           (plist-put state :lazy-scroll-prefix-dirty t))
                     (puthash scroll-region-id state
                              ebox--scroll-global-state))
                 (let* ((content-patch
                         (ebox--scroll-paint-lines-for-region
                          content-lines region-ids surfaces content-spans))
                          (rendered-lines
                           (plist-get state :rendered-content-lines))
                          (rendered-spans
                           (and rendered-lines
                                (ebox--scroll-hot-rendered-line-spans
                                 state region-ids content-spans)))
                          (rendered-patch
                           (and rendered-lines
                                rendered-spans
                                (ebox--scroll-paint-lines-for-region
                                 rendered-lines region-ids surfaces
                                 rendered-spans))))
                     (if (not (and content-patch
                                   (or (not rendered-lines)
                                       rendered-patch)))
                         ;; A surface the cached lines cannot express
                         ;; yet (for example enabling a border whose
                         ;; role span does not exist in the cache)
                         ;; already patched the published buffer
                         ;; through the inferring buffer patcher.  The
                         ;; buffer is the display truth and the paint
                         ;; only touched rows inside the visible
                         ;; window, so adopting the window back into
                         ;; the cache is exact; only when even
                         ;; adoption is impossible does the fallback
                         ;; take over.
                         (let ((adopted
                                (ebox--scroll-state-adopt-buffer-window-lines
                                 buffer scroll-region-id state)))
                           (unless adopted
                             (throw 'failed nil))
                           (setq adopted
                                 (plist-put adopted :buffer buffer))
                           (puthash scroll-region-id adopted
                                    ebox--scroll-global-state)
                           (cl-pushnew scroll-region-id
                                       patched-region-ids
                                       :test #'equal)
                           (setq patched-count
                                 (1+ (or patched-count 0))))
                       (setq state
                             (if index-stable
                                 (let ((state
                                        (plist-put
                                         state :content-lines
                                         (plist-get content-patch
                                                    :lines))))
                                   (if rendered-lines
                                       (plist-put
                                        state :rendered-content-lines
                                        (plist-get rendered-patch
                                                   :lines))
                                     state))
                               (ebox--scroll-state-patch-lines
                                state
                                (plist-get content-patch :lines)
                                (plist-get content-patch :spans)
                                (and rendered-lines
                                     (plist-get rendered-patch :lines))
                                (and rendered-lines
                                     (plist-get rendered-patch :spans))
                                region-ids)))
                       (setq state (plist-put state :buffer buffer))
                       ;; Restore exact representational identity
                       ;; between the published window and its visible
                       ;; cache slice so the settled cache replays
                       ;; exactly what is on screen and verification
                       ;; stays on the raw fast path.
                       (setq state
                             (or (ebox--scroll-state-adopt-buffer-window-lines
                                  buffer scroll-region-id state)
                                 state))
                       (puthash scroll-region-id state
                                ebox--scroll-global-state)
                       (cl-pushnew scroll-region-id patched-region-ids
                                   :test #'equal)
                       (setq patched-count (1+ (or patched-count 0)))
                       (setq span-count
                             (+ (or span-count 0)
                                (length
                                 (plist-get content-patch
                                            :spans))))))))))
         ebox--scroll-global-state)
        (when patched-count
          ;; Pure property patches move no buffer text, so existing
          ;; marker windows stay anchored to the same positions and the
          ;; full-buffer marker rebuild is normally unnecessary.  Verify
          ;; first; rebuild one marker generation and re-verify only
          ;; when a patched window no longer proves healthy (for
          ;; example after a role-removing patch replaced cached line
          ;; structure).  Existing markers are never cleared without a
          ;; replacement, so the live window cannot detach.
          (let ((refreshed 0))
            (cl-flet ((windows-healthy-p ()
                        (cl-every
                         (lambda (scroll-region-id)
                           (when-let ((state
                                       (ebox--scroll-get-state
                                        scroll-region-id)))
                             (ebox--scroll-state-window-markers-healthy-p
                              buffer scroll-region-id state)))
                         patched-region-ids)))
              (unless (windows-healthy-p)
                (ebox--refresh-buffer-scroll-content-markers buffer)
                (setq refreshed (length patched-region-ids))
                (unless (windows-healthy-p)
                  (throw 'failed nil))))
            (setq report
                  (append report
                          (list :scroll-state-paint-sync t
                                :scroll-state-sync-count patched-count
                                :scroll-state-sync-span-count
                                (or span-count 0)
                                :scroll-state-index-preserved index-stable
                                :scroll-state-window-marker-refresh-count
                                refreshed
                                :scroll-state-window-markers-invalidated
                                nil)))))
        report))))

(defun ebox--sync-scroll-state-lines-for-node
    (buffer region-id node changed-keys report)
  "Synchronize cached scroll lines for updated NODE in BUFFER.
Ordinary incremental patching mutates the visible buffer.  Scroll containers
also keep their own cached content lines, so those lines must be updated or a
later scroll-window replacement can replay stale content."
  (or (ebox--sync-scroll-state-paint-lines-for-node
       buffer node changed-keys report)
      (ebox--sync-scroll-state-lines-for-node-fallback
       buffer region-id node changed-keys report)))

;;; ============================================================
;;; Scroll Interaction Commands
;;; ============================================================

(defun ebox--region-id-at-point ()
  "Get region-id at current point by checking ebox-content property."
  (get-text-property (point) 'ebox-content))

(defun ebox--scroll-region-ids-in-extents-at-pos (pos)
  "Return scroll region ids whose live extents contain POS, inner first."
  (let (candidates)
    (maphash
     (lambda (region-id _state)
       (when-let ((extents (ebox--live-box-extents region-id)))
         (let ((start (car extents))
               (end (cdr extents)))
           (when (and (markerp start)
                      (markerp end)
                      (eq (marker-buffer start) (current-buffer))
                      (<= (marker-position start) pos)
                      (< pos (marker-position end)))
             (push (cons region-id
                         (- (marker-position end)
                            (marker-position start)))
                   candidates)))))
     ebox--scroll-global-state)
    (mapcar #'car
            (sort candidates
                  (lambda (a b) (< (cdr a) (cdr b)))))))

(defun ebox--scroll-region-ids-in-buffer-outer-first ()
  "Return scroll region ids in the current buffer from outer to inner."
  (let (candidates)
    (maphash
     (lambda (region-id _state)
       (when-let ((extents (ebox--live-box-extents region-id)))
         (let ((start (car extents))
               (end (cdr extents)))
           (when (and (markerp start)
                      (markerp end)
                      (eq (marker-buffer start) (current-buffer)))
             (push (cons region-id
                         (- (marker-position end)
                            (marker-position start)))
                   candidates)))))
     ebox--scroll-global-state)
    (mapcar #'car
            (sort candidates
                  (lambda (a b) (> (cdr a) (cdr b)))))))

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
        (dolist (region-id (ebox--scroll-region-ids-in-extents-at-pos pos))
          (add region-id))))
    ids))

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

(defun ebox--scroll-region-by (region-id delta &optional prefix-budget-lines)
  "Scroll REGION-ID content by DELTA lines when it has scroll capacity.
Return the consumed line delta, `pending' for lazy cache misses, or nil.
PREFIX-BUDGET-LINES caps synchronous lazy-prefix rendering for this call."
  (when-let ((state (and region-id (ebox--scroll-get-state region-id))))
    (catch 'native-prefix-pending
      (when (and (plist-get state :native-reflow-materialize-p)
                 (plist-get state :materialize-content-lines))
        (setq state (ebox--scroll-state-materialize-lines region-id state)))
      (when (plist-get state :native-reflow-target-prefix-p)
        (let* ((scroll-offset (or (plist-get state :scroll-offset) 0))
               (content-height
                (max 0 (or (plist-get state :content-height) 0)))
               (required-lines
                (+ (max 0 scroll-offset (+ scroll-offset delta))
                   content-height)))
          (if (ebox--scroll-sync-prefix-render-p)
              (setq state
                    (ebox--scroll-state-ensure-prefix-lines
                     region-id state required-lines t))
            ;; The exact native window is already visible.  Preserve it and
            ;; let bounded idle slices prepare the target-width cache instead
            ;; of freezing the GUI on a first wheel event.
            (setq state
                  (plist-put state :cache-miss-prefetch-target-lines
                             required-lines))
            (puthash region-id state ebox--scroll-global-state)
            (ebox--scroll-schedule-idle-prefetch region-id 0)
            (throw 'native-prefix-pending 'pending))))
      (let* ((scroll-offset (or (plist-get state :scroll-offset) 0))
             (desired-offset (+ scroll-offset delta))
             (dirty-prefix-p (plist-get state :lazy-scroll-prefix-dirty))
             refresh-window-p)
        (setq state
              (ebox--scroll-refresh-dirty-prefix-for-offset
               region-id state desired-offset))
        (setq refresh-window-p
              (or dirty-prefix-p
                  (plist-get state :lazy-scroll-window-refresh-required)))
        (if (plist-get state :lazy-scroll-prefix-dirty)
            'pending
          (when (and (> delta 0)
                     (or prefix-budget-lines
                         (and (ebox--scroll-sync-prefix-render-p)
                              (<= delta
                                  (ebox--scroll-prefetch-slice-lines)))))
            (setq state
                  (ebox--scroll-ensure-bounded-prefix-for-offset
                   region-id state desired-offset prefix-budget-lines)))
          (setq refresh-window-p
                (or refresh-window-p
                    (plist-get state :lazy-scroll-window-refresh-required)))
          (let* ((content-lines (plist-get state :content-lines))
               (content-height (plist-get state :content-height))
               (max-offset (max 0 (- (length content-lines) content-height)))
               (cache-miss-p
                (and (> delta 0)
                     (> desired-offset max-offset)
                     (plist-get state :render-content-prefix)
                     (not (plist-get state :content-lines-complete-p))))
               (new-offset (max 0 (min max-offset desired-offset))))
          (when cache-miss-p
            (setq state
                  (ebox--scroll-schedule-cache-miss-prefetch
                   region-id state)))
          (cond
           ((and (= new-offset scroll-offset) refresh-window-p)
            (let* ((new-visible-lines
                    (seq-subseq content-lines
                                new-offset
                                (min (+ new-offset content-height)
                                     (length content-lines))))
                   (inhibit-read-only t)
                   (updated-spans
                    (ebox--scroll-update-content
                     region-id new-visible-lines nil))
                   (all-spans-updated
                    (and updated-spans
                         (cl-every #'identity updated-spans))))
              (when (or all-spans-updated
                        (ebox--scroll-replace-rendered-window region-id state)
                        (ebox--scroll-rerender-region region-id))
                (when-let ((current-state
                            (ebox--scroll-get-state region-id)))
                  (puthash
                   region-id
                   (ebox--plist-remove
                    current-state :lazy-scroll-window-refresh-required)
                   ebox--scroll-global-state))
                (unless (gethash region-id ebox--smooth-scroll-state-table)
                  (ebox--scroll-schedule-idle-prefetch region-id))
                'refreshed)))
           ((= new-offset scroll-offset)
            (and cache-miss-p 'pending))
           (t
            (let ((old-offset scroll-offset)
                  (box (plist-get state :box))
                  (buffer (ebox--scroll-state-buffer state)))
              (when box
                (ebox-put box :scroll-offset new-offset)
                (when buffer
                  (ebox--invalidate-buffer-render-signatures
                   buffer (ebox--ensure-node-id box))))
              (plist-put state :scroll-offset new-offset)
              (let* ((new-visible-lines
                      (seq-subseq content-lines
                                  new-offset
                                  (min (+ new-offset content-height)
                                       (length content-lines))))
                     (inhibit-read-only t)
                     (updated-spans
                      (ebox--scroll-update-content
                       region-id new-visible-lines
                       (unless refresh-window-p old-offset)))
                     (all-spans-updated
                      (and updated-spans
                           (cl-every #'identity updated-spans))))
                (if (or all-spans-updated
                        (ebox--scroll-replace-rendered-window region-id state)
                        (ebox--scroll-rerender-region region-id))
                    (progn
                      (when refresh-window-p
                        (when-let ((current-state
                                    (ebox--scroll-get-state region-id)))
                          (puthash
                           region-id
                           (ebox--plist-remove
                            current-state
                            :lazy-scroll-window-refresh-required)
                           ebox--scroll-global-state)))
                      (unless (gethash region-id
                                       ebox--smooth-scroll-state-table)
                        (ebox--scroll-schedule-idle-prefetch region-id))
                      (- new-offset old-offset))
                  (when box
                    (ebox-put box :scroll-offset old-offset))
                  (plist-put state :scroll-offset old-offset)
                  nil)))))))))))

(defun ebox--scroll-progress-p (result)
  "Return non-nil when RESULT represents consumed or pending scroll work."
  (or (memq result '(pending refreshed))
      (and (numberp result)
           (/= result 0))))

(defun ebox--scroll-redisplay-after-tick ()
  "Flush GUI redisplay after an asynchronous scroll tick."
  (unless noninteractive
    (redisplay t)))

(defun ebox--scroll-rerender-region (region-id)
  "Rerender scroll REGION-ID when direct content marker updates are unavailable."
  (when-let* ((extents (ebox--live-box-extents region-id))
              (start-marker (car extents))
              (buffer (marker-buffer start-marker)))
    (condition-case nil
        (progn
          (ebox--with-buffer-render-context buffer
            (ebox--rerender-box region-id))
          (when (buffer-live-p buffer)
            (ebox--refresh-buffer-scroll-content-markers buffer)
            (ebox-buffer-refresh-region-role-spans buffer)
            (ebox--refresh-buffer-layout-snapshots buffer))
          t)
      (error nil))))

(defun ebox--scroll-decorate-rendered-window-lines (lines box region-id)
  "Apply fixed scroll viewport chrome from BOX to rendered LINES."
  (let* ((padding-top (floor (ebox-get box :padding-top-height)))
         (padding-bottom (floor (ebox-get box :padding-bottom-height)))
         (content-pixel (ebox--content-pixel box))
         (color (ebox-get box :color))
         (bgcolor (ebox-get box :bgcolor)))
    (cl-labels
        ((style-line (line)
           (ebox--propertize-colors line color bgcolor))
         (padding-lines (height property)
           (when (> height 0)
             (mapcar #'style-line
                     (ebox-string-lines
                      (ebox--propertize-region
                       (or (ebox--pixel-blank content-pixel height) "")
                       property region-id))))))
      (let ((lines (append (padding-lines padding-top 'ebox-pt)
                           ;; These are already fully styled when
                           ;; `:rendered-content-lines' is produced during the
                           ;; original render.  Reapplying faces to every
                           ;; complex child-layout line on each wheel tick is
                           ;; expensive enough to freeze GUI Emacs.
                           (mapcar #'copy-sequence lines)
                           (padding-lines padding-bottom 'ebox-pb))))
        (when (and lines (ebox-get box :border-top-p))
          (let ((line (ebox--propertize-overline
                       (car lines)
                       (ebox-get box :border-top-color))))
            (add-text-properties 0 (length line) `(ebox-bt ,region-id) line)
            (setcar lines line)))
        (when (and lines (ebox-get box :border-bottom-p))
          (let ((line (ebox--propertize-underline
                       (car (last lines))
                       (ebox-get box :border-bottom-color))))
            (add-text-properties 0 (length line) `(ebox-bb ,region-id) line)
            (setcar (last lines) line)))
        lines))))

(defun ebox--render-scroll-state-window (state region-id)
  "Render scroll STATE's current visible window for REGION-ID.
This uses the already formatted `:content-lines' stored in STATE, so scrolling
child-layout content does not need to rerender the whole source tree."
  (setq state (ebox--scroll-state-materialize-lines region-id state))
  (when-let* ((box (plist-get state :box))
              (content-lines (plist-get state :content-lines))
              (content-height (plist-get state :content-height)))
    (let* ((text-height (length content-lines))
           (rendered-content-lines (plist-get state :rendered-content-lines))
           (max-offset (max 0 (- text-height content-height)))
           (scroll-offset (max 0 (min max-offset
                                       (or (plist-get state :scroll-offset)
                                           0)))))
      (if rendered-content-lines
          (ebox-lines-join
           (ebox--scroll-decorate-rendered-window-lines
            (seq-subseq rendered-content-lines
                        scroll-offset
                        (min (+ scroll-offset content-height) text-height))
            box region-id))
        (let* (
           (content-pixel (ebox--content-pixel box))
           (padding-left (ebox-get box :padding-left-pixel))
           (padding-right (ebox-get box :padding-right-pixel))
           (padding-top (floor (ebox-get box :padding-top-height)))
           (padding-bottom (floor (ebox-get box :padding-bottom-height)))
           (margin-left (ebox-get box :margin-left-pixel))
           (margin-right (ebox-get box :margin-right-pixel))
           (margin-top (floor (ebox-get box :margin-top-height)))
           (margin-bottom (floor (ebox-get box :margin-bottom-height)))
           (border-left-pixel (ebox-get box :border-left-pixel))
           (border-left-color (ebox-get box :border-left-color))
           (border-right-pixel (ebox-get box :border-right-pixel))
           (border-right-color (ebox-get box :border-right-color))
           (border-top-p (ebox-get box :border-top-p))
           (border-top-color (ebox-get box :border-top-color))
           (border-bottom-p (ebox-get box :border-bottom-p))
           (border-bottom-color (ebox-get box :border-bottom-color))
           (color (ebox-get box :color))
           (bgcolor (ebox-get box :bgcolor))
           (inner-height (+ content-height padding-top padding-bottom))
           (padding-line-filler (ebox-pixel-space content-pixel))
           (visible-lines
            (seq-subseq content-lines
                        scroll-offset
                        (min (+ scroll-offset content-height) text-height)))
           (result
            (ebox-lines-join
             (cl-loop for line in visible-lines
                      for idx from 0
                      collect (ebox--propertize-content-line
                               line region-id idx
                               padding-line-filler)))))
      (setq result
            (ebox--lines-align-vertical
             result content-height (ebox-get box :vertical-align)))
      (setq result
            (ebox--maplines
             (lambda (line)
               (if (and (string-empty-p (string-trim line))
                        (not (ebox--line-has-non-content-properties-p line)))
                   (let ((content-id (get-text-property 0 'ebox-content line))
                         (content-idx (get-text-property 0 'ebox-content-idx line)))
                     (if content-id
                         (propertize padding-line-filler
                                     'ebox-content content-id
                                     'ebox-content-idx content-idx
                                     'ebox-content-owner region-id)
                       (propertize padding-line-filler
                                   'ebox-content region-id
                                   'ebox-content-idx 0
                                   'ebox-content-owner region-id)))
                 line))
             result))
      (when (or (> padding-top 0) (> padding-bottom 0))
        (let ((pt-str (when (> padding-top 0)
                        (ebox--propertize-region
                         (ebox--pixel-blank content-pixel padding-top)
                         'ebox-pt region-id)))
              (pb-str (when (> padding-bottom 0)
                        (ebox--propertize-region
                         (ebox--pixel-blank content-pixel padding-bottom)
                         'ebox-pb region-id))))
          (setq result (ebox--lines-stack-vertical pt-str result pb-str))))
      (let ((pl-str (when (> padding-left 0)
                      (ebox--propertize-region
                       (ebox--pixel-blank padding-left inner-height)
                       'ebox-pl region-id)))
            (pr-str (when (> padding-right 0)
                      (ebox--propertize-region
                       (ebox--pixel-blank padding-right inner-height)
                       'ebox-pr region-id))))
        (when (or pl-str pr-str)
          (setq result (ebox--lines-concat-horizontal pl-str result pr-str))))
      (when (or color bgcolor)
        (setq result
              (ebox--maplines
               (lambda (line)
                 (ebox--propertize-colors line color bgcolor))
               result)))
      (when (or (> border-left-pixel 0) (> border-right-pixel 0))
        (let ((bl-str (when (> border-left-pixel 0)
                        (ebox--propertize-region
                         (ebox--pixel-border border-left-pixel
                                             inner-height border-left-color)
                         'ebox-bl region-id)))
              (br-str (when (> border-right-pixel 0)
                        (ebox--propertize-region
                         (ebox--pixel-border border-right-pixel
                                             inner-height border-right-color)
                         'ebox-br region-id))))
          (setq result (ebox--lines-concat-horizontal bl-str result br-str))))
      (when (or border-top-p border-bottom-p)
        (let ((lines (ebox-string-lines result)))
          (when border-top-p
            (setf (car lines)
                  (propertize
                   (ebox--propertize-overline (car lines) border-top-color)
                   'ebox-bt region-id)))
          (when border-bottom-p
            (setf (car (last lines))
                  (propertize
                   (ebox--propertize-underline
                    (car (last lines)) border-bottom-color)
                   'ebox-bb region-id)))
          (setq result (ebox-lines-join lines))))
      ;; Visibility hides the box's own ink (content glyphs, colors,
      ;; borders) after assembly; margins below stay blank either way.
      (when (eq (ebox-get box :visibility) 'hidden)
        (setq result (ebox--apply-hidden-visibility result)))
      (when (or (> margin-left 0) (> margin-right 0))
        (let* ((box-height (ebox-string-height result))
               (ml-str (when (> margin-left 0)
                         (ebox--propertize-region
                          (ebox--pixel-blank margin-left box-height)
                          'ebox-ml region-id)))
               (mr-str (when (> margin-right 0)
                         (ebox--propertize-region
                          (ebox--pixel-blank margin-right box-height)
                          'ebox-mr region-id))))
          (setq result (ebox--lines-concat-horizontal ml-str result mr-str))))
      (when (or (> margin-top 0) (> margin-bottom 0))
        (let ((total-pixel-width (ebox--total-pixel box)))
          (let ((mt-str (when (> margin-top 0)
                          (ebox--propertize-region
                           (ebox--pixel-blank total-pixel-width margin-top)
                           'ebox-mt region-id)))
                (mb-str (when (> margin-bottom 0)
                          (ebox--propertize-region
                           (ebox--pixel-blank total-pixel-width margin-bottom)
                           'ebox-mb region-id))))
            (setq result (ebox--lines-stack-vertical mt-str result mb-str)))))
      result)))))

(defun ebox--scroll-replace-rendered-window (region-id state)
  "Patch scroll REGION-ID by replacing its fixed rendered viewport from STATE."
  (when-let* ((extents (ebox--live-box-extents region-id))
              (start-marker (car extents))
              (end-marker (cdr extents))
              (buffer (marker-buffer start-marker))
              ((eq buffer (marker-buffer end-marker)))
              (rendered (ebox--render-scroll-state-window state region-id)))
    (with-current-buffer buffer
      (let* ((start (marker-position start-marker))
             (end (marker-position end-marker))
             (old-height (count-lines start end))
             (new-height (length (ebox-string-lines rendered)))
             (window-states
              (mapcar (lambda (window)
                        (list :window window
                              :start (window-start window)
                              :point (window-point window)
                              :hscroll (window-hscroll window)))
                      (get-buffer-window-list buffer nil t)))
             (inhibit-read-only t))
        (when (= old-height new-height)
          (save-excursion
            (goto-char start)
            (delete-region start end)
            (insert rendered)
            (ebox--scroll-store-rendered-window-extents
             buffer region-id state start (point) new-height))
          (dolist (window-state window-states)
            (let ((window (plist-get window-state :window)))
              (when (and (window-live-p window)
                         (eq (window-buffer window) buffer))
                (set-window-start
                 window
                 (min (plist-get window-state :start) (point-max))
                 t)
                (set-window-point
                 window
                 (min (plist-get window-state :point) (point-max)))
                (set-window-hscroll
                 window (plist-get window-state :hscroll)))))
          t)))))

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
  (when-let ((state (and region-id (ebox--scroll-get-state region-id))))
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
  (when-let ((entry (gethash region-id ebox--smooth-scroll-state-table)))
    (when-let ((timer (plist-get entry :timer)))
      (cancel-timer timer))
    (remhash region-id ebox--smooth-scroll-state-table)
    (ebox--deferred-render-gc-schedule-restore)
    (ebox--scroll-schedule-idle-prefetch region-id)))

(defun ebox--smooth-scroll-pause-for-prefetch
    (region-id entry pending)
  "Pause REGION-ID smooth scroll ENTRY until lazy prefetch extends the cache."
  (when-let ((timer (plist-get entry :timer)))
    (when (timerp timer)
      (cancel-timer timer)))
  (plist-put entry :timer nil)
  (plist-put entry :pending pending)
  (plist-put entry :waiting-prefetch t)
  (puthash region-id entry ebox--smooth-scroll-state-table))

(defun ebox--smooth-scroll-clamp-pending (region-id pending)
  "Clamp PENDING lines to REGION-ID's remaining scrollable range."
  (if-let ((state (and region-id (ebox--scroll-get-state region-id))))
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
  (when-let ((state (and (> delta 0)
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

(defun ebox--smooth-scroll-region-by (region-id delta)
  "Animate wheel scroll REGION-ID by DELTA lines."
  (let* ((existing (gethash region-id ebox--smooth-scroll-state-table))
         (entry (or existing (list :pending 0 :timer nil)))
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
      (puthash region-id entry ebox--smooth-scroll-state-table)
      ;; Move the first tick immediately so the UI responds to the initial
      ;; event.  While a timer is already active, new wheel events only update
      ;; pending distance; the timer coalesces them into frame-sized edits.
      (unless had-timer
        (ebox--smooth-scroll-tick region-id))
      (when-let ((entry (gethash region-id ebox--smooth-scroll-state-table)))
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
  "Scroll box content by DELTA lines. Positive = down, negative = up.
FALLBACK is the Emacs scroll command to call when ebox cannot scroll."
  (if (ebox--scroll-first-region-by
       (ebox--scroll-region-ids-at-point)
       delta)
      t
    (funcall fallback 1)))

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

(defun ebox--wheel-scroll (event delta &optional arg smooth)
  "Scroll an ebox region under EVENT by DELTA, or delegate to `mwheel-scroll'.
When SMOOTH is non-nil, animate the scroll over short line steps."
  (let* ((region-ids (ebox--wheel-region-ids event))
         (region-id (and smooth
                         ebox-wheel-smooth-scroll
                         (ebox--first-scrollable-region region-ids delta))))
    (cond
     (region-id
      (ebox--smooth-scroll-region-by region-id delta))
     ((ebox--scroll-first-region-by region-ids delta)
      t)
     (t
      (mwheel-scroll event arg)))))

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
     (lambda (&optional _n)
       (scroll-up-command arg)))))

;;;###autoload
(defun ebox-scroll-page-up (&optional arg)
  "Scroll ebox content up by a page.
With prefix ARG, scroll by that many content lines."
  (interactive "P")
  (let ((delta (- (ebox--scroll-page-lines arg))))
    (ebox--scroll-by
     delta
     (lambda (&optional _n)
       (scroll-down-command arg)))))

(defun ebox--scroll-replace-content-marker (state region-id idx string)
  "Replace visible scroll line IDX for REGION-ID using STATE markers."
  (when-let* ((markers (plist-get state :content-span-markers))
              ((< idx (length markers)))
              (span (aref markers idx))
              ((consp span))
              (start-marker (car span))
              (end-marker (cdr span))
              ((markerp start-marker))
              ((markerp end-marker))
              (buffer (marker-buffer start-marker))
              ((eq buffer (marker-buffer end-marker)))
              (start (marker-position start-marker))
              (end (marker-position end-marker)))
    (with-current-buffer buffer
      (when (and (<= start end)
                 (or
                  (and
                   (eql (get-text-property start 'ebox-content) region-id)
                   (eql (get-text-property start 'ebox-content-idx) idx))
                  (eql (get-text-property start 'ebox-content-owner) region-id)
                  (member region-id
                          (get-text-property start 'ebox-content-owners))))
        (let ((inhibit-read-only t)
              (props (copy-sequence (text-properties-at start))))
          (save-excursion
            (let ((replacement
                   (ebox--scroll-propertize-visible-line
                    string region-id idx props)))
              ;; Let Emacs retain unchanged buffer intervals and markers, then
              ;; copy the replacement's exact per-character properties.  A
              ;; delete/insert of the whole display-bearing span can make the
              ;; first GUI redisplay publish a torn flex row even when the
              ;; resulting buffer string is otherwise correct.
              (replace-region-contents start end (lambda () replacement))
              (ebox--copy-string-text-properties-to-buffer replacement start)
              (goto-char (+ start (length replacement))))
            (set-marker start-marker start)
            (set-marker end-marker (point)))
          (cons start (marker-position end-marker)))))))

(defun ebox--scroll-content-window (state line-count)
  "Return marker-backed visible scroll window for STATE and LINE-COUNT.
The return value is (BUFFER START END ENTRIES).  Each entry is
(IDX START-MARKER END-MARKER PROPS)."
  (when-let ((markers (plist-get state :content-span-markers)))
    (catch 'invalid
      (let (buffer window-start window-end previous-end entries)
        (dotimes (idx line-count)
          (unless (< idx (length markers))
            (throw 'invalid nil))
          (let* ((span (aref markers idx))
                 (start-marker (and (consp span) (car span)))
                 (end-marker (and (consp span) (cdr span))))
            (unless (and (markerp start-marker)
                         (markerp end-marker)
                         (marker-buffer start-marker)
                         (eq (marker-buffer start-marker)
                             (marker-buffer end-marker)))
              (throw 'invalid nil))
            (let ((start (marker-position start-marker))
                  (end (marker-position end-marker))
                  (span-buffer (marker-buffer start-marker)))
              (unless (and (<= start end)
                           (or (not buffer) (eq buffer span-buffer))
                           (or (not previous-end)
                               (and (= start (1+ previous-end))
                                    (with-current-buffer span-buffer
                                      (eq (char-after previous-end) ?\n)))))
                (throw 'invalid nil))
              (unless (and (< start end)
                           (with-current-buffer span-buffer
                             (let ((region-id (plist-get state :region-id)))
                               (or (and (equal (get-text-property
                                                start 'ebox-content)
                                               region-id)
                                        (eql (get-text-property
                                              start 'ebox-content-idx)
                                             idx))
                                   (equal (get-text-property
                                           start 'ebox-content-owner)
                                          region-id)
                                   (member region-id
                                           (get-text-property
                                            start 'ebox-content-owners))))))
                (throw 'invalid nil))
              (setq buffer span-buffer)
              (unless window-start
                (setq window-start start))
              (setq window-end end
                    previous-end end)
              (push (list idx start-marker end-marker
                          (with-current-buffer span-buffer
                            (copy-sequence (text-properties-at start))))
                    entries))))
        (and buffer window-start window-end
             (list buffer window-start window-end (nreverse entries)))))))

(defun ebox--scroll-propertize-visible-line (line region-id idx props)
  "Return LINE with visible scroll marker PROPS for REGION-ID and IDX."
  (let ((line (copy-sequence line)))
    (if (text-property-not-all 0 (length line) 'ebox-content nil line)
        (ebox--add-content-owner line region-id)
      (let ((props (copy-sequence props)))
        ;; LINE already owns its formatted `display' runs.  In particular,
        ;; centered content uses a width-bearing display space only at each
        ;; edge.  Copying the old first character's display value over the
        ;; entire replacement line makes every glyph consume that width and
        ;; visibly tears apart neighboring flex boxes until a later rerender.
        (setq props (ebox--plist-remove props 'display))
        (setq props (plist-put props 'ebox-content region-id))
        (setq props (plist-put props 'ebox-content-idx idx))
        (when (> (length line) 0)
          (add-text-properties 0 (length line) props line))
        line))))

(defun ebox--scroll-replace-content-window (state region-id new-lines)
  "Replace all visible scroll NEW-LINES for REGION-ID in one buffer edit."
  (let ((state (plist-put (copy-sequence state) :region-id region-id)))
    (pcase-let ((`(,buffer ,window-start ,window-end ,entries)
                 (ebox--scroll-content-window state (length new-lines))))
      (when (and buffer entries)
        (with-current-buffer buffer
          (let ((inhibit-read-only t)
                (line-count (length new-lines))
                spans
                marker-updates
                replacement-lines
                (offset 0))
            (save-excursion
              (cl-loop for line in new-lines
                       for entry in entries
                       for line-idx from 0
                       do
                       (pcase-let ((`(,idx ,start-marker ,end-marker ,props)
                                    entry))
                         (let* ((replacement-line
                                 (ebox--scroll-propertize-visible-line
                                  line region-id idx props))
                                (line-start (+ window-start offset))
                                (line-end (+ line-start
                                             (length replacement-line))))
                           (push replacement-line replacement-lines)
                           (push (list start-marker end-marker
                                       line-start line-end)
                                 marker-updates)
                           (push (cons line-start line-end) spans)
                           (setq offset
                                 (+ offset (length replacement-line)
                                    (if (< line-idx (1- line-count))
                                        1
                                      0))))))
              (let ((replacement
                     (ebox-lines-join (nreverse replacement-lines))))
                (replace-region-contents
                 window-start window-end (lambda () replacement))
                (ebox--copy-string-text-properties-to-buffer
                 replacement window-start))
              (dolist (update marker-updates)
                (pcase-let ((`(,start-marker ,end-marker ,start ,end)
                             update))
                  (set-marker start-marker start)
                  (set-marker end-marker end))))
            (let ((spans (nreverse spans)))
              (ebox--scroll-state-clear-window-region-id-set
               region-id (or (ebox--scroll-get-state region-id) state)
               buffer)
              spans)))))))

(defun ebox--scroll-chrome-free-rendered-window-p (box)
  "Return non-nil when BOX's scroll viewport has no dynamic chrome rows."
  (and (= (floor (ebox-get box :padding-top-height)) 0)
       (= (floor (ebox-get box :padding-bottom-height)) 0)
       (not (ebox-get box :border-top-p))
       (not (ebox-get box :border-bottom-p))
       (= (floor (ebox-get box :margin-top-height)) 0)
       (= (floor (ebox-get box :margin-bottom-height)) 0)))

(defun ebox--scroll-state-window-extents (region-id state)
  "Return marker-backed visible viewport extents for chrome-free scroll STATE.
The scroll state may own a lightweight rendered-window boundary marker pair.
For a chrome-free viewport those markers are the rendered box window, so they
are the most accurate source after viewport resize invalidates global extents.
Older content-span markers are kept as a fallback for freshly rendered buffers
and dynamic update marker refreshes."
  (when-let* ((box (plist-get state :box))
              ((ebox--scroll-chrome-free-rendered-window-p box))
              (content-height (plist-get state :content-height))
              ((> content-height 0)))
    (let* ((start-marker (plist-get state :rendered-window-start-marker))
           (end-marker (plist-get state :rendered-window-end-marker))
           (line-count (plist-get state :rendered-window-line-count))
           (buffer (and (markerp start-marker)
                        (marker-buffer start-marker))))
      (or
       (when (and buffer
                  (markerp end-marker)
                  (eq buffer (marker-buffer end-marker))
                  (integerp line-count)
                  (= line-count content-height)
                  (marker-position start-marker)
                  (marker-position end-marker)
                  (< (marker-position start-marker)
                     (marker-position end-marker)))
         (cons start-marker end-marker))
       (when-let ((markers (plist-get state :content-span-markers)))
         (let (buffer start end)
           (dolist (span (ebox--scroll-content-marker-spans markers))
             (let* ((start-marker (car-safe span))
                    (end-marker (cdr-safe span))
                    (span-buffer (and (markerp start-marker)
                                      (marker-buffer start-marker)))
                    (span-start (and (markerp start-marker)
                                     (marker-position start-marker)))
                    (span-end (and (markerp end-marker)
                                   (marker-position end-marker))))
               (when (and (markerp start-marker)
                          (markerp end-marker)
                          span-buffer
                          (eq span-buffer (marker-buffer end-marker))
                          span-start
                          span-end
                          (< span-start span-end)
                          (or (not buffer) (eq buffer span-buffer)))
                 (setq buffer span-buffer)
                 (setq start (if start (min start span-start) span-start))
                 (setq end (if end (max end span-end) span-end)))))
           (when (and buffer start end
                      (= (with-current-buffer buffer
                           (count-lines start end))
                         content-height))
             (when-let ((stored
                         (ebox--scroll-store-rendered-window-extents
                          buffer region-id state start end content-height)))
               (cons (plist-get stored :rendered-window-start-marker)
                     (plist-get stored
                                :rendered-window-end-marker))))))))))

(defun ebox--scroll-rendered-window-slide-preferred-p ()
  "Return non-nil when rendered scroll windows should use line sliding.
Line sliding keeps scroll edits proportional to the consumed delta instead of
the viewport height.  GUI and terminal frames both need this bounded edit path;
expensive hidden content should be prefetched asynchronously rather than paid
inside the scroll event."
  t)

(defun ebox--scroll-capture-window-states (buffer)
  "Return live window positions for BUFFER."
  (mapcar (lambda (window)
            (list :window window
                  :start (window-start window)
                  :point (window-point window)
                  :hscroll (window-hscroll window)))
          (get-buffer-window-list buffer nil t)))

(defun ebox--scroll-lines-with-live-wrapper-context
    (lines position region-id)
  "Return cached LINES with wrapper context recovered at POSITION.
The live owner stack is inner-to-outer.  Only owners after REGION-ID are outer
wrappers; copying an outgoing child's owners onto an entering line would make
section boundaries semantically stale.  Each line is decorated independently
because complete box rendering leaves the separators inserted by
`ebox-lines-join' unpropertized."
  (let* ((owners
          (or (get-text-property position 'ebox-content-owners)
              (when-let ((owner
                          (get-text-property position 'ebox-content-owner)))
                (list owner))))
         (owner-tail (member region-id owners)))
    (when owner-tail
      (mapcar
       (lambda (line)
         (let ((result
                (ebox--string-with-preserved-wrapper-context
                 line (cdr owner-tail)
                 (ebox--string-content-owner-set line))))
           (add-text-properties
            0 (length result) (list 'ebox-scroll-window region-id) result)
           result))
       lines))))

(defun ebox--scroll-restore-window-states (buffer window-states)
  "Restore WINDOW-STATES for live windows still showing BUFFER."
  (dolist (window-state window-states)
    (let ((window (plist-get window-state :window)))
      (when (and (window-live-p window)
                 (eq (window-buffer window) buffer))
        (set-window-start
         window
         (min (plist-get window-state :start) (point-max))
         t)
        (set-window-point
         window
         (min (plist-get window-state :point) (point-max)))
        (set-window-hscroll
         window (plist-get window-state :hscroll))))))

(defun ebox--scroll-replace-rendered-content-window-slide
    (state region-id old-offset scroll-offset rendered-content-lines
           content-height start-marker end-marker buffer)
  "Slide a rendered scroll viewport by mutating only entering/leaving lines."
  (when-let* (((integerp old-offset))
              (delta (- scroll-offset old-offset))
              ((/= delta 0))
              (step (abs delta))
              ((< step content-height))
              (start (marker-position start-marker))
              (end (marker-position end-marker)))
    (let* ((line-count (length rendered-content-lines))
           (entering-lines
            (if (> delta 0)
                (and (<= (+ scroll-offset content-height) line-count)
                     (seq-subseq rendered-content-lines
                                 (+ old-offset content-height)
                                 (+ scroll-offset content-height)))
              (and (<= old-offset line-count)
                   (seq-subseq rendered-content-lines
                               scroll-offset old-offset)))))
      (when (and entering-lines (= (length entering-lines) step))
        (with-current-buffer buffer
          (let* ((old-height (count-lines start end))
                 (window-states (ebox--scroll-capture-window-states buffer))
                 (inhibit-read-only t))
            (when (= old-height content-height)
              (when-let ((entering-lines
                          (ebox--scroll-lines-with-live-wrapper-context
                           entering-lines start region-id)))
                (ebox--scroll-clear-content-markers state)
                (setq state (plist-put state :content-span-markers nil))
                (setq state
                      (plist-put state :content-window-region-id-set nil))
                (setq state (plist-put state :buffer buffer))
                (puthash region-id state ebox--scroll-global-state)
                (save-excursion
                  (if (> delta 0)
                      (progn
                        (goto-char start)
                        (forward-line step)
                        (delete-region start (point))
                        (goto-char (marker-position end-marker))
                        (insert "\n")
                        (insert (ebox-lines-join entering-lines)))
                    (goto-char start)
                    (forward-line (- content-height step))
                    (let ((delete-start (if (> (point) start)
                                            (1- (point))
                                          (point))))
                      (delete-region
                       delete-start (marker-position end-marker)))
                    (goto-char start)
                    (insert (ebox-lines-join entering-lines))
                    (insert "\n")))
                (let* ((spans (ebox--scroll-line-spans-in-window
                               start content-height))
                       (new-end (if spans (cdr (car (last spans))) start)))
                  (ebox--scroll-store-rendered-window-extents
                   buffer region-id state start new-end content-height)
                  (ebox--scroll-restore-window-states buffer window-states)
                  spans)))))))))

(defun ebox--scroll-replace-rendered-content-window
    (state region-id &optional old-offset)
  "Replace chrome-free rendered scroll viewport for REGION-ID from STATE."
  (let ((marker-extents (ebox--scroll-state-window-extents region-id state)))
    (when-let* ((rendered-content-lines
                 (plist-get state :rendered-content-lines))
                (content-height (plist-get state :content-height))
                (box (plist-get state :box))
                ((ebox--scroll-chrome-free-rendered-window-p box))
                (extents (or marker-extents
                             (ebox--live-box-extents region-id)))
                (start-marker (car extents))
                (end-marker (cdr extents))
                (buffer (marker-buffer start-marker))
                ((eq buffer (marker-buffer end-marker))))
    (let* ((max-offset (max 0 (- (length rendered-content-lines)
                                 content-height)))
           (scroll-offset (max 0 (min max-offset
                                       (or (plist-get state :scroll-offset)
                                           0))))
           (visible-lines
            (seq-subseq rendered-content-lines
                        scroll-offset
                        (min (+ scroll-offset content-height)
                             (length rendered-content-lines)))))
      (or (and marker-extents
               (ebox--scroll-rendered-window-slide-preferred-p)
               (ebox--scroll-replace-rendered-content-window-slide
                state region-id old-offset scroll-offset rendered-content-lines
                content-height start-marker end-marker buffer))
          (with-current-buffer buffer
            (let* ((start (marker-position start-marker))
                   (rendered
                    (when-let ((lines
                                (ebox--scroll-lines-with-live-wrapper-context
                                 visible-lines start region-id)))
                      (ebox-lines-join lines)))
                   (end (marker-position end-marker))
                   (old-height (count-lines start end))
                   (new-height (length visible-lines))
                   (window-states
                    (ebox--scroll-capture-window-states buffer))
                   (inhibit-read-only t))
              (when (and rendered (= old-height new-height))
                  (ebox--scroll-clear-content-markers state)
                  (setq state (plist-put state :content-span-markers nil))
                  (setq state
                        (plist-put state :content-window-region-id-set nil))
                  (setq state (plist-put state :buffer buffer))
                  (puthash region-id state ebox--scroll-global-state)
                  (save-excursion
                    (goto-char start)
                    (delete-region start end)
                    (insert rendered))
                  (let ((spans (ebox--scroll-line-spans-in-window
                                start new-height)))
                    (ebox--scroll-store-rendered-window-extents
                     buffer region-id state start
                     (if spans (cdr (car (last spans))) start)
                     new-height)
                    (ebox--scroll-restore-window-states buffer window-states)
                    spans)))))))))

(defun ebox--scroll-ancestor-horizontal-border-p (buffer region-id state)
  "Return non-nil when REGION-ID has a bordered ancestor in BUFFER.
Horizontal ancestor borders are painted by viewport slot rather than by the
cached child line.  Moving cached lines directly would move or drop that
position-dependent paint."
  (when-let* (((buffer-live-p buffer))
              (extents (or (ebox--scroll-state-window-extents region-id state)
                           (ebox--live-box-extents region-id)))
              (start-marker (car extents))
              ((markerp start-marker))
              ((eq (marker-buffer start-marker) buffer))
              (position (marker-position start-marker))
              (owners
               (with-current-buffer buffer
                 (or (get-text-property position 'ebox-content-owners)
                     (when-let ((owner
                                 (get-text-property
                                  position 'ebox-content-owner)))
                       (list owner)))))
              (outer-owners (cdr (member region-id owners))))
    (cl-some
     (lambda (owner)
       (when-let ((box (gethash owner ebox--region-box-table)))
         (or (ebox-get box :border-top-p)
             (ebox-get box :border-bottom-p))))
     outer-owners)))

(defun ebox--scroll-rerender-root-window (buffer region-id)
  "Rerender BUFFER and return REGION-ID's freshly published line spans."
  (when (and (buffer-live-p buffer)
             (ebox-buffer-apply-root-rerender buffer))
    (when-let* ((state (ebox--scroll-get-state region-id))
                (height (plist-get state :content-height))
                (extents (ebox--scroll-state-window-extents region-id state))
                (start-marker (car extents))
                ((eq (marker-buffer start-marker) buffer)))
      (with-current-buffer buffer
        (ebox--scroll-line-spans-in-window
         (marker-position start-marker) height)))))

(defun ebox--scroll-update-content (region-id new-lines &optional old-offset)
  "Update visible content lines for scroll REGION-ID with NEW-LINES.
This is a dedicated fast path for overflow='scroll' boxes whose outer box
geometry stays unchanged while only the visible window contents move."
  (let* ((state (ebox--scroll-get-state region-id))
         (buffer (or (and state (ebox--scroll-state-buffer state))
                     (current-buffer)))
         (result
          (or (and state
                   (ebox--scroll-ancestor-horizontal-border-p
                    buffer region-id state)
                   (ebox--scroll-rerender-root-window buffer region-id))
              (and state
                   (ebox--scroll-replace-rendered-content-window
                    state region-id old-offset))
              (and state
                   (ebox--scroll-replace-content-window
                    state region-id new-lines))
              (when (or (not state)
                        (>= (length (ebox--scroll-content-marker-spans
                                     (plist-get state :content-span-markers)))
                            (length new-lines)))
                (cl-loop for line in new-lines
                         for idx from 0
                         collect
                         (or (and state
                                  (ebox--scroll-replace-content-marker
                                   state region-id idx line))
                             (ebox--region-replace-line
                              region-id idx line)))))))
    (when (and result (buffer-live-p buffer))
      ;; Scroll replacement changes which runtime regions occupy otherwise
      ;; stable marker coordinates.  Discard only the derived indexes here;
      ;; role spans and snapshot details are reconstructed lazily on demand.
      (ebox--set-buffer-region-role-span-table buffer nil)
      (ebox--invalidate-buffer-layout-snapshot-details buffer))
    result))

(defun ebox--scroll-marker-spans-compatible-p (state new-lines)
  "Return non-nil when NEW-LINES can replace STATE markers without shifting text."
  (when-let ((markers (plist-get state :content-span-markers)))
    (cl-loop for line in new-lines
             for idx from 0
             always
             (and (< idx (length markers))
                  (when-let* ((span (aref markers idx))
                              ((consp span))
                              (start-marker (car span))
                              (end-marker (cdr span))
                              ((markerp start-marker))
                              ((markerp end-marker))
                              ((eq (marker-buffer start-marker)
                                   (marker-buffer end-marker)))
                              (start (marker-position start-marker))
                              (end (marker-position end-marker)))
                    (= (- end start) (length line)))))))

(defun ebox--scroll-fast-path-report
    (buffer region-id node-id new-spans changed-keys)
  "Return an update report for a scroll-offset fast-path patch."
  (when (and buffer node-id new-spans)
    (ebox--update-report
     region-id 'span-patch
     :dirty-count 1
     :patch-count 1
     :patch-ops '(span-patch)
     :owner-id node-id
     :owner-ids (list node-id)
     :owner-type 'box
     :span-count (length new-spans)
     :scroll-fast-path t
     :dirty-kinds '(geometry)
     :dirty-keys changed-keys)))

(defun ebox--scroll-transaction-report
    (buffer region-id node-id span-count changed-keys)
  "Return a report for an atomically synchronized scroll transaction."
  (when (and buffer node-id)
    (ebox--update-report
     region-id 'span-patch
     :dirty-count 1
     :patch-count 1
     :patch-ops '(span-patch)
     :owner-id node-id
     :owner-ids (list node-id)
     :owner-type 'box
     :span-count (or span-count 0)
     :scroll-state-transaction t
     :scroll-state-sync t
     :scroll-state-sync-count 1
     :dirty-kinds '(geometry)
     :dirty-keys changed-keys)))

(defun ebox--scroll-offset-state-settled-p (region-id offset)
  "Return non-nil when REGION-ID atomically exposes OFFSET."
  (when-let ((state (ebox--scroll-get-state region-id)))
    (and (= (or (plist-get state :scroll-offset) 0) offset)
         (not (plist-get state :lazy-scroll-prefix-dirty))
         (not (plist-get state :lazy-scroll-window-refresh-required)))))

(defun ebox--try-scroll-offset-fast-path
    (buffer region-id changed-keys)
  "Patch REGION-ID for a scroll-offset-only update in BUFFER.
Return an update report only after its runtime, cache, and window agree."
  (when (and buffer
             (equal changed-keys '(:scroll-offset)))
    (when-let ((state (ebox--scroll-get-state region-id)))
      (setq state (ebox--scroll-state-materialize-lines region-id state))
      (when-let* ((box (plist-get state :box))
                  ((eq (ebox-get box :overflow) 'scroll))
                  (content-lines (plist-get state :content-lines))
                  (content-height (plist-get state :content-height)))
        (let* ((max-offset (max 0 (- (length content-lines) content-height)))
               (scroll-offset (max 0 (min max-offset
                                           (or (ebox-get box :scroll-offset)
                                               0))))
               (old-offset (or (plist-get state :scroll-offset) 0))
               (visible-lines
                (seq-subseq content-lines
                            scroll-offset
                            (min (+ scroll-offset content-height)
                                 (length content-lines))))
               (node-id (ebox--buffer-region-render-owner-node-id
                         buffer region-id))
               (direct-eligible-p
                (or (ebox--scroll-marker-spans-compatible-p
                     state visible-lines)
                    (and (null (plist-get state :content-span-markers))
                         (= (length visible-lines) content-height)
                         (plist-get state :rendered-content-lines)
                         (ebox--scroll-state-window-extents
                          region-id state))))
               direct-report)
          (when direct-eligible-p
            (let ((old-state (copy-sequence state)))
              (ebox-put box :scroll-offset scroll-offset)
              (setq state (plist-put state :scroll-offset scroll-offset))
              (setq state (plist-put state :box box))
              ;; `ebox--scroll-update-content' reads the shared state.  Publish
              ;; the staged offset before replacing the window, then retain it
              ;; only when every visible span was replaced successfully.
              (puthash region-id state ebox--scroll-global-state)
              (with-current-buffer buffer
                (let ((new-spans
                       (delq nil
                             (ebox--scroll-update-content
                              region-id visible-lines old-offset))))
                  (if new-spans
                      (progn
                        (when-let ((current-state
                                    (ebox--scroll-get-state region-id)))
                          (puthash
                           region-id
                           (ebox--plist-remove
                            current-state
                            :lazy-scroll-window-refresh-required)
                           ebox--scroll-global-state))
                        (when (ebox--scroll-offset-state-settled-p
                               region-id scroll-offset)
                          (setq direct-report
                                (ebox--scroll-fast-path-report
                                 buffer region-id node-id new-spans
                                 changed-keys))))
                    (puthash region-id old-state
                             ebox--scroll-global-state)))))
          (or direct-report
              ;; Marker slots can legitimately be incompatible after a large
              ;; jump or viewport reflow.  Reuse the ordinary scroll engine so
              ;; it commits the offset and visible window together instead of
              ;; letting the generic cached-line patch split those states.
              (let ((delta (- scroll-offset old-offset)))
                (ebox--scroll-region-by region-id delta)
                (if (ebox--scroll-offset-state-settled-p
                     region-id scroll-offset)
                    (ebox--scroll-transaction-report
                     buffer region-id node-id content-height changed-keys)
                  ;; `ebox--scroll-region-by' rolls the box back on failure;
                  ;; restore the requested runtime value for the conservative
                  ;; planner that follows this failed transaction.
                  (ebox-put box :scroll-offset scroll-offset)
                  nil)))))))))


;;; ============================================================
;;; Region Update API
;;; ============================================================

(defconst ebox-region-types
  '((content . ebox-content)
    (content-owner . ebox-content-owner)
    (pt . ebox-pt) (pb . ebox-pb) (pl . ebox-pl) (pr . ebox-pr)
    (mt . ebox-mt) (mb . ebox-mb) (ml . ebox-ml) (mr . ebox-mr)
    (bt . ebox-bt) (bb . ebox-bb) (bl . ebox-bl) (br . ebox-br))
  "Mapping from region type symbol to text property name.")

(defsubst ebox--region-property (type)
  "Get text property name for region TYPE."
  (or (alist-get type ebox-region-types)
      (error "Unknown region type: %S" type)))

(defun ebox--region-id-at-pos (pos)
  "Return the owning ebox region-id at POS, if any."
  (cl-loop for (_type . prop) in ebox-region-types
           for region-id = (get-text-property pos prop)
           when region-id return region-id))

(defun ebox--set-box-extents (region-id start end)
  "Record REGION-ID extents from START to END using markers."
  (let* ((existing (gethash region-id ebox--box-extents))
         (start-marker (or (car-safe existing) (make-marker)))
         (end-marker (or (cdr-safe existing) (make-marker))))
    (set-marker-insertion-type start-marker nil)
    (set-marker-insertion-type end-marker t)
    (set-marker start-marker start)
    (set-marker end-marker end)
    (puthash region-id (cons start-marker end-marker) ebox--box-extents)))

(defun ebox--clear-buffer-extents (&optional buffer preserve-template)
  "Remove cached extents whose markers belong to BUFFER.
Defaults to the current buffer.
When PRESERVE-TEMPLATE is non-nil, keep BUFFER's prepared numeric extent
template while stale live marker extents are removed."
  (let ((buffer (or buffer (current-buffer)))
        stale-ids)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless preserve-template
          (setq-local ebox--box-extent-template nil))))
    (maphash
     (lambda (region-id extents)
       (when (eq (marker-buffer (car extents)) buffer)
         (push region-id stale-ids)))
     ebox--box-extents)
    (dolist (region-id stale-ids)
      (when-let ((extents (gethash region-id ebox--box-extents)))
        (set-marker (car extents) nil)
        (set-marker (cdr extents) nil))
      (remhash region-id ebox--box-extents))))

(defun ebox--install-box-extent-template (buffer template start)
  "Install prepared numeric box extent TEMPLATE in BUFFER at root START."
  (when (and (buffer-live-p buffer) (hash-table-p template))
    (with-current-buffer buffer
      (setq-local
       ebox--box-extent-template
       (if (= start (point-min))
           template
         (let ((translated (make-hash-table :test 'equal))
               (delta (- start (point-min))))
           (maphash
            (lambda (region-id span)
              (puthash region-id
                       (cons (+ delta (car span)) (+ delta (cdr span)))
                       translated))
            template)
           translated))))))

(defun ebox--materialize-box-extent-template (buffer)
  "Promote BUFFER's prepared extent template to live marker pairs."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (hash-table-p ebox--box-extent-template)
        (maphash
         (lambda (region-id span)
           (ebox--set-box-extents region-id (car span) (cdr span)))
         ebox--box-extent-template)
        (setq-local ebox--box-extent-template nil)
        t))))

(defun ebox--clear-box-extents-for-region-ids (region-ids)
  "Remove cached box extents for REGION-IDS."
  (dolist (region-id region-ids)
    (when-let ((extents (gethash region-id ebox--box-extents)))
      (set-marker (car extents) nil)
      (set-marker (cdr extents) nil))
    (remhash region-id ebox--box-extents)))

(defun ebox--refresh-box-extents-for-region-ids-in-spans (region-ids spans)
  "Refresh box extents for REGION-IDS inside SPANS."
  (ebox--clear-box-extents-for-region-ids region-ids)
  (when spans
    (let ((start (apply #'min (mapcar #'car spans)))
          (end (apply #'max (mapcar #'cdr spans)))
          (region-id-allow-set (make-hash-table :test 'equal)))
      (dolist (region-id region-ids)
        (puthash region-id t region-id-allow-set))
      (when (< start end)
        (ebox--register-box-extents-in-range
         start end region-id-allow-set)))))

(defun ebox--span-bounds (span)
  "Return numeric bounds for SPAN."
  (cons (if (markerp (car span))
            (marker-position (car span))
          (car span))
        (if (markerp (cdr span))
            (marker-position (cdr span))
          (cdr span))))

(defun ebox--spans-bounding-range (spans)
  "Return a numeric bounding range for SPANS."
  (when spans
    (let* ((first (ebox--span-bounds (car spans)))
           (start (car first))
           (end (cdr first)))
      (dolist (span (cdr spans))
        (pcase-let ((`(,span-start . ,span-end)
                     (ebox--span-bounds span)))
          (setq start (min start span-start))
          (setq end (max end span-end))))
      (cons start end))))

(defun ebox--box-extents-contained-in-spans-p (region-id spans)
  "Return non-nil when REGION-ID's live extents are inside SPANS."
  (when-let* ((extents (gethash region-id ebox--box-extents))
              ((markerp (car extents)))
              ((markerp (cdr extents)))
              (range (ebox--spans-bounding-range spans)))
    (let ((start (marker-position (car extents)))
          (end (marker-position (cdr extents))))
      (and start end
           (<= (car range) start)
           (<= end (cdr range))))))

(defun ebox--box-extent-refresh-region-ids
    (region-ids spans &optional active-segments)
  "Return REGION-IDS whose cached extents can be refreshed in SPANS."
  (let ((root-id (ebox--buffer-root-node-id (current-buffer))))
    (cl-loop for region-id in region-ids
             for active-region-p = (and active-segments
                                        (gethash region-id active-segments))
             for contained-p = (ebox--box-extents-contained-in-spans-p
                                region-id spans)
             when (or contained-p
                      (and active-region-p
                           (not (equal region-id root-id))))
             collect region-id)))

(defun ebox--refresh-box-extents-from-segments (segments-by-region)
  "Refresh box extents from active SEGMENTS-BY-REGION."
  (maphash
   (lambda (region-id region-spans)
     (when region-spans
       (let* ((ordered
                (sort region-spans
                      (lambda (left right)
                        (if (= (car left) (car right))
                            (< (cdr left) (cdr right))
                          (< (car left) (car right))))))
              (range (copy-tree (pop ordered)))
              (interleaved
               (ebox--foreign-region-in-range-p
                (car range) (cdr range) region-id)))
         (dolist (segment ordered)
           (unless interleaved
             (cond
              ((ebox--foreign-region-in-range-p
                (car segment) (cdr segment) region-id)
               (setq interleaved t))
              ((<= (car segment) (cdr range))
               (setcdr range (max (cdr range) (cdr segment))))
              ((ebox--foreign-region-in-range-p
                (cdr range) (car segment) region-id)
               (setq interleaved t))
              (t
               (setcdr range (cdr segment))))))
         (unless interleaved
           (ebox--set-box-extents region-id (car range) (cdr range))))))
   segments-by-region))

(defun ebox--active-extent-segments-for-region-ids
    (active-segments region-ids)
  "Return ACTIVE-SEGMENTS filtered to REGION-IDS."
  (let ((region-set (ebox--region-id-set region-ids))
        (filtered (make-hash-table :test 'equal)))
    (maphash
     (lambda (region-id segments)
       (when (gethash region-id region-set)
         (puthash region-id segments filtered)))
     active-segments)
    filtered))

(defun ebox--refresh-box-extents-from-role-spans
    (region-ids spans &optional active-segments)
  "Refresh REGION-IDS extents in SPANS from the current role-span index.
The role index has already scanned the replacement text.  Reusing it avoids a
second per-character pass over every Ebox property.  Wrapper-only ownership is
merged from `ebox-content-owners'.  Fall back to the ordinary scoped scanner
when no role index is available."
  (if (not (ebox-buffer--region-role-span-table))
      (ebox--refresh-box-extents-for-region-ids-in-spans region-ids spans)
    (let* ((refresh-region-ids
            (ebox--box-extent-refresh-region-ids
             region-ids spans active-segments))
           (region-set (ebox--region-id-set refresh-region-ids)))
      (ebox--clear-box-extents-for-region-ids refresh-region-ids)
      (when spans
        (let* ((range (ebox--spans-bounding-range spans))
               (start (car range))
               (end (cdr range))
               (segments-by-region (make-hash-table :test 'equal))
               (table (ebox-buffer--region-role-span-table)))
          (if active-segments
              (ebox--refresh-box-extents-from-segments
               (ebox--active-extent-segments-for-region-ids
                active-segments refresh-region-ids))
            (cl-labels
                ((record (region-id segment-start segment-end)
                   (when (and (gethash region-id region-set)
                              (< segment-start segment-end)
                              (< segment-start end)
                              (> segment-end start))
                     (puthash region-id
                              (cons (cons (max start segment-start)
                                          (min end segment-end))
                                    (gethash region-id segments-by-region))
                              segments-by-region))))
              (dolist (region-id region-ids)
                (dolist (entry ebox-region-types)
                  (dolist (span
                           (gethash (ebox-buffer--region-role-key
                                     region-id (car entry))
                                    table))
                    (let ((span-start
                           (if (markerp (car span))
                               (marker-position (car span))
                             (car span)))
                          (span-end
                           (if (markerp (cdr span))
                               (marker-position (cdr span))
                             (cdr span))))
                      (when (and span-start span-end)
                        (record region-id span-start span-end))))))
              (let ((pos start))
                (while (< pos end)
                  (let* ((owners (get-text-property
                                  pos 'ebox-content-owners))
                         (next (or (next-single-property-change
                                    pos 'ebox-content-owners nil end)
                                   end)))
                    (dolist (region-id owners)
                      (record region-id pos next))
                    (setq pos (max next (1+ pos)))))))
            (ebox--refresh-box-extents-from-segments
             segments-by-region)))))))

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
    (when-let ((root (ebox--buffer-root-node buffer)))
      (ebox--clear-region-runtime-caches
       (ebox--node-all-region-ids root)))
    (ebox--clear-buffer-extents buffer)
    (ebox--clear-buffer-render-state buffer)))

(defun ebox--cleanup-current-buffer ()
  "Remove Ebox runtime state owned by the current buffer."
  (ebox--clear-buffer-runtime-state (current-buffer))
  (setq-local ebox-surface--buffer-surface nil))

(defun ebox--foreign-region-in-range-p (start end region-id)
  "Return non-nil if START..END contains another ebox region."
  (let ((pos start)
        found)
    (while (and (< pos end) (not found))
      (let ((next (or (next-property-change pos nil end) end)))
        (save-excursion
          (goto-char pos)
          (skip-chars-forward "\n" next)
          (when (< (point) next)
            (let ((owners (ebox--pos-region-ids (point)))
                  (owner-stack
                   (get-text-property (point) 'ebox-content-owners)))
              (when (cl-some (lambda (owner)
                               (and (not (equal owner region-id))
                                    (not (member region-id owner-stack))))
                             owners)
                (setq found t)))))
        (setq pos next)))
    found))

(defun ebox--region-property-segments-in-range (start end)
  "Return sorted ebox region property segments between START and END."
  (let (segments)
    (let ((pos start))
      (while (< pos end)
        (let* ((owners (get-text-property pos 'ebox-content-owners))
               (next (or (next-single-property-change
                          pos 'ebox-content-owners nil end)
                         end)))
          (dolist (region-id owners)
            (push (list region-id pos next) segments))
          (setq pos (max next (1+ pos))))))
    (dolist (entry ebox-region-types)
      (let ((prop (cdr entry))
            (pos start))
        (while (< pos end)
          (let* ((region-id (get-text-property pos prop))
                 (next (or (next-single-property-change pos prop nil end)
                           end)))
            (when region-id
              (push (list region-id pos next) segments))
            (setq pos (max next (1+ pos)))))))
    (sort segments
          (lambda (left right)
            (if (= (nth 1 left) (nth 1 right))
                (< (nth 2 left) (nth 2 right))
              (< (nth 1 left) (nth 1 right)))))))

(defconst ebox--box-extents-segment-scan-min-chars 2048
  "Minimum span size before box extent refresh uses segment scanning.")

(defun ebox--register-box-extents-by-position-scan
    (start end &optional region-id-allow-set)
  "Cache extents only for boxes that occupy one safe buffer slice.
Gaps containing only separators, such as newlines, are fine.  Gaps
containing another ebox region mean the box is interleaved by a concat
layout and must not be replaced through a single `delete-region'.
When REGION-ID-ALLOW-SET is non-nil, register only ids in that hash set."
  (let ((ranges (make-hash-table :test 'equal))
        (interleaved (make-hash-table :test 'equal))
        (pos start))
    (while (< pos end)
      (dolist (region-id (ebox--pos-region-ids pos))
        (when (or (null region-id-allow-set)
                  (gethash region-id region-id-allow-set))
          (let ((range (gethash region-id ranges)))
            (if range
                (progn
                  (when (and (> pos (cdr range))
                             (ebox--foreign-region-in-range-p
                              (cdr range) pos region-id))
                    (puthash region-id t interleaved))
                  (setcdr range (1+ pos)))
              (puthash region-id (cons pos (1+ pos)) ranges)))))
      (setq pos (1+ pos)))
    (maphash
     (lambda (region-id range)
       (unless (gethash region-id interleaved)
         (ebox--set-box-extents region-id (car range) (cdr range))))
     ranges)))

(defun ebox--register-box-extents-by-segment-scan
    (start end &optional region-id-allow-set)
  "Cache extents in START..END by scanning region property segments.
When REGION-ID-ALLOW-SET is non-nil, register only ids in that hash set."
  (let ((ranges (make-hash-table :test 'equal))
        (interleaved (make-hash-table :test 'equal)))
    (dolist (segment (ebox--region-property-segments-in-range start end))
      (pcase-let ((`(,region-id ,segment-start ,segment-end) segment))
        (when (or (null region-id-allow-set)
                  (gethash region-id region-id-allow-set))
          (let ((range (gethash region-id ranges)))
            (if range
                (progn
                  (when (and (> segment-start (cdr range))
                             (ebox--foreign-region-in-range-p
                              (cdr range) segment-start region-id))
                    (puthash region-id t interleaved))
                  (setcdr range (max (cdr range) segment-end)))
              (puthash region-id
                       (cons segment-start segment-end)
                       ranges))))))
    (maphash
     (lambda (region-id range)
       (unless (gethash region-id interleaved)
         (ebox--set-box-extents region-id (car range) (cdr range))))
     ranges)))

(defun ebox--register-box-extents-in-range
    (start end &optional region-id-allow-set)
  "Cache live box extents for ebox regions between START and END.
When REGION-ID-ALLOW-SET is non-nil, register only ids in that hash set."
  (if (< (- end start) ebox--box-extents-segment-scan-min-chars)
      (ebox--register-box-extents-by-position-scan
       start end region-id-allow-set)
    (ebox--register-box-extents-by-segment-scan
     start end region-id-allow-set)))

(defun ebox--ensure-live-box-extents (region-id)
  "Compute and cache live extents for REGION-ID on demand."
  (when-let ((buffer (and (fboundp 'ebox--region-buffer)
                          (ebox--region-buffer region-id))))
    (with-current-buffer buffer
      (if-let ((span (and (hash-table-p ebox--box-extent-template)
                          (gethash region-id ebox--box-extent-template))))
          (ebox--set-box-extents region-id (car span) (cdr span))
        (ebox--register-box-extents-in-range (point-min) (point-max)))
      (gethash region-id ebox--box-extents))))

(defun ebox--live-box-extents (region-id)
  "Return live extents for REGION-ID, or nil if unavailable."
  (or (when-let ((extents (gethash region-id ebox--box-extents)))
        (let* ((start-marker (car extents))
               (end-marker (cdr extents))
               (buffer (marker-buffer start-marker))
               (start (marker-position start-marker))
               (end (marker-position end-marker)))
          (when (and buffer
                     (eq buffer (marker-buffer end-marker))
                     start end
                     (< start end))
            extents)))
      (ebox--ensure-live-box-extents region-id)))

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

(defun ebox--region-update-analysis (box expanded)
  "Return the effective change analysis for BOX and EXPANDED properties."
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
          (or style-changed-p
              (and content-seen
                   (not (equal (ebox-get box :content) content-value))))
          :unknown-keys (nreverse unknown-keys))))

(defun ebox--region-update-buffer (region-id)
  "Return the render buffer for REGION-ID, preferring a valid buffer hint."
  (or (when (and ebox--region-update-buffer-hint
                 (buffer-live-p ebox--region-update-buffer-hint))
        (let ((region-id-set
               (ebox--buffer-region-id-set ebox--region-update-buffer-hint)))
          (when (and region-id-set
                     (gethash region-id region-id-set))
            ebox--region-update-buffer-hint)))
      (ebox--region-buffer region-id)))

(defun ebox--mirror-region-update-box (region-box-table region-id box)
  "Mirror REGION-ID's BOX into REGION-BOX-TABLE and the legacy side table."
  (when region-box-table
    (puthash region-id box region-box-table))
  (puthash region-id box ebox--region-box-table))

(defun ebox--scroll-state-sync-after-update-p (report)
  "Return non-nil when REPORT requires scroll cache synchronization."
  (and report
       (not (eq (plist-get report :strategy) 'no-op))
       (not (plist-get report :scroll-state-patch))
       (not (plist-get report :lazy-scroll-deferred-patch))))

(defun ebox--sync-scroll-offset-state-window (region-id changed-keys)
  "Synchronize REGION-ID's own scroll state/window after CHANGED-KEYS.
Return non-nil only when the runtime offset, cached offset, and rendered window
are settled in the same update transaction."
  (if (not (equal changed-keys '(:scroll-offset)))
      t
    (if-let ((state (ebox--scroll-get-state region-id)))
        (when-let* ((box (plist-get state :box))
                    (content-lines (plist-get state :content-lines))
                    (content-height (plist-get state :content-height)))
          (let* ((max-offset
                  (max 0 (- (length content-lines) content-height)))
                 (target (max 0 (min max-offset
                                     (or (ebox-get box :scroll-offset) 0))))
                 (current (or (plist-get state :scroll-offset) 0)))
            (ebox-put box :scroll-offset target)
            (unless (ebox--scroll-offset-state-settled-p region-id target)
              (ebox--scroll-region-by region-id (- target current)))
            (ebox--scroll-offset-state-settled-p region-id target)))
      t)))

(defun ebox--sync-scroll-state-after-batch-flush (buffer pending report)
  "Synchronize final runtime nodes from successful batch PENDING entries."
  (when (and buffer pending
             (ebox--scroll-state-sync-after-update-p report))
    (let ((sources (make-hash-table :test 'equal))
          (final-report report)
          source-order)
      (dolist (entry pending)
        (when-let* ((region-id (plist-get entry :region-id))
                    (node (ebox--buffer-region-render-owner-node
                           buffer region-id))
                    (node-id (ebox--ensure-node-id node)))
          (if-let ((source (gethash node-id sources)))
              (plist-put
               source :changed-keys
               (delete-dups
                (append
                 (copy-sequence (plist-get source :changed-keys))
                 (copy-sequence (plist-get entry :changed-keys)))))
            (puthash node-id
                     (list :region-id region-id
                           :node node
                           :changed-keys
                           (copy-sequence (plist-get entry :changed-keys)))
                     sources)
            (push node-id source-order))))
      (dolist (node-id (nreverse source-order))
        (let ((source (gethash node-id sources)))
          (unless (ebox--sync-scroll-offset-state-window
                   (plist-get source :region-id)
                   (plist-get source :changed-keys))
            (error "Ebox could not atomically synchronize scroll state %S"
                   (plist-get source :region-id)))
          (setq final-report
                (ebox--sync-scroll-state-lines-for-node
                 buffer
                 (plist-get source :region-id)
                 (plist-get source :node)
                 (plist-get source :changed-keys)
                 final-report))))
      (ebox--set-buffer-update-report buffer final-report))))

(add-hook 'ebox-incremental--after-successful-batch-flush-hook
          #'ebox--sync-scroll-state-after-batch-flush)

(defun ebox--schedule-runtime-prewarm-after-batch-flush
    (buffer _pending _report)
  "Schedule shared runtime prewarming after BUFFER's batch flush."
  (ebox--schedule-buffer-runtime-prewarm buffer))

(add-hook 'ebox-incremental--after-successful-batch-flush-hook
          #'ebox--schedule-runtime-prewarm-after-batch-flush t)

(defun ebox--root-width-reflow-update-p (buffer node changed-keys)
  "Return non-nil when NODE changes BUFFER's root width constraint."
  (and buffer node
       (equal (ebox--ensure-node-id node)
              (ebox--buffer-root-node-id buffer))
       (cl-some (lambda (key)
                  (memq key '(:width :min-width :max-width)))
                changed-keys)))

(defun ebox--surface-region-update (handle props)
  "Apply PROPS to surface-scoped region HANDLE through one TP commit."
  (pcase-let* ((`(,buffer . ,region-id)
                (ebox-selector--region-target handle))
               (state (ebox--buffer-render-state buffer))
               (box (gethash region-id
                             (plist-get state :region-box-table)))
               (expanded (ebox--expand-plist props))
               (analysis (ebox--region-update-analysis box expanded)))
    (dolist (key (plist-get analysis :unknown-keys))
      (message "ebox-region-update: unknown key %S (ignored)" key))
    (if (not (plist-get analysis :changed-p))
        (let ((report
               (ebox--update-report
                nil 'no-op :region-handle handle :constraint-source 'region
                :runtime-published nil :runtime-revision
                (plist-get state :runtime-revision)
                :surface-revision
                (tp-surface-revision (plist-get state :surface))
                :dirty-count 0 :patch-count 0 :patch-ops nil)))
          (plist-put state :last-update-report report)
          report)
      (let* ((candidate-root
              (ebox-tree-copy-node-structure
               (plist-get state :root-node)))
             (candidate-box
              (ebox--root-region-box candidate-root region-id))
             changed-keys)
        (unless candidate-box
          (user-error "Ebox region handle no longer resolves to a box"))
        (cl-loop for (key value) on expanded by #'cddr
                 for target-key = (ebox--region-update-normalize-property key)
                 when (or (eq target-key :content)
                          (memq target-key ebox--region-update-longhand-props))
                 unless (equal (ebox-get candidate-box target-key) value)
                 do (ebox-put candidate-box target-key value)
                 and do (push target-key changed-keys))
        (setq changed-keys (nreverse changed-keys))
        (let ((ebox-viewport-width (plist-get state :viewport-width))
              (ebox-viewport-height (plist-get state :viewport-height)))
          (let ((surface
                 (ebox-surface-mount-buffer
                  buffer candidate-root
                  (list :region-handle handle
                        :constraint-source 'region
                        :dirty-count 1
                        :dirty-keys changed-keys
                        :dirty-kinds
                        (list (ebox--region-update-dirty-kind changed-keys)))
                  nil t
                  (list :viewport-width (plist-get state :viewport-width)
                        :viewport-height (plist-get state :viewport-height)
                        :detached-identity-history
                        (plist-get state :detached-identity-history)))))
            (plist-get (tp-surface-client-state surface)
                       :last-update-report)))))))

;;;###autoload
(defun ebox-region-update (region-id &rest props)
  "Update one or more properties of the box identified by REGION-ID.

REGION-ID may also be an opaque handle returned by `ebox-region-resolve'.
Handles are surface-scoped and are the preferred form when one declarative
source is mounted in more than one buffer.

PROPS accepts the same shorthand and longhand keywords as `ebox-create'.
Properties are expanded through `ebox-property-rules', written to the box
plist, then rendered once.  Unsupported pseudo properties such as
:display are ignored by the shared rule table; :visibility affects rendering.
Return nil when the change is queued in an active explicit batch.  Otherwise
return the report stored by `ebox-buffer-update-report'; legal same-value
updates return a `no-op' report.

Examples:
  (ebox-region-update id :content \"Hello\")
  (ebox-region-update (ebox-region-resolve buffer \"status\")
                      :content \"Ready\")
  (ebox-region-update id :padding (list 1 2) :border-color \"red\")
  (ebox-region-update id :content \"Hi\" :width 30 :color \"white\")"
  (ebox--with-render-gc
   (if (ebox-region-handle-p region-id)
       (ebox--surface-region-update region-id props)
     (ebox--with-validated-display-cache
    (catch 'ebox-region-update-result
      (let* ((inhibit-read-only t)
             (buffer (ebox--region-update-buffer region-id))
             (region-box-table
              (and buffer (ebox--buffer-region-box-table buffer)))
             (box
              (if (hash-table-p region-box-table)
                  (or (gethash region-id region-box-table)
                      (error "No box found in buffer runtime for region %S"
                             region-id))
                (or (gethash region-id ebox--region-box-table)
                    (error "No box found for region %S" region-id))))
             (expanded (ebox--expand-plist props))
             (analysis (ebox--region-update-analysis box expanded)))
        (dolist (key (plist-get analysis :unknown-keys))
          (message "ebox-region-update: unknown key %S (ignored)" key))
        (unless (plist-get analysis :changed-p)
          (if (and buffer (ebox-incremental-batching-p buffer))
              (throw 'ebox-region-update-result nil)
            (let ((report
                   (ebox--update-report
                    region-id 'no-op
                    :dirty-count 0
                    :patch-count 0
                    :patch-ops nil)))
              (when buffer
                (ebox--set-buffer-update-report buffer report))
              (throw 'ebox-region-update-result report))))
        (when (and buffer ebox--prepared-root-render
                   (not (ebox-incremental-batching-p buffer))
                   (= (length expanded) 2)
                   (eq (ebox--region-update-normalize-property (car expanded))
                       :width))
          (let* ((state (ebox--buffer-render-state buffer))
                 (root (and state (plist-get state :root-node)))
                 (root-box
                  (pcase (plist-get root :ebox-type)
                    ('box root)
                    ('flex (plist-get root :box))))
                 (node (ebox--buffer-region-render-owner-node buffer region-id))
                 (target-box
                  (and root-box
                       (plist-put (copy-sequence root-box)
                                  :width (cadr expanded))))
                 (target-width
                  (and target-box
                       (ebox--literal-root-pixel-width target-box)))
                 (report
                  (and (eq box root-box) target-width
                       (ebox--root-width-reflow-update-p
                        buffer node '(:width))
                       (with-current-buffer buffer
                         (ebox-incremental--publish-prepared-root-native
                          buffer
                          (list
                           :kind 'root-width :region-id region-id :box box
                           :model-node-id (ebox--ensure-node-id box)
                           :target-root-width target-width
                           :target-viewport-width
                           (plist-get state :viewport-width)
                           :target-viewport-height
                           (plist-get state :viewport-height)))))))
            (when report
              (ebox--mirror-region-update-box
               region-box-table region-id box)
              (ebox--schedule-buffer-runtime-prewarm buffer)
              (throw 'ebox-region-update-result report))))
        (let* ((state (and buffer (ebox--buffer-render-state buffer)))
               (node (and buffer
                          (ebox--buffer-region-render-owner-node
                           buffer region-id)))
               (affected-scroll-ids
                (let ((subtree-ids
                       (and node (ebox--node-all-region-ids node)))
                      (containing-ids
                       (and buffer node
                            (ebox--scroll-state-region-ids-containing-node-ids
                             buffer (list (ebox--ensure-node-id node))))))
                  (delete-dups
                   (delq nil (append (list region-id)
                                      subtree-ids
                                      containing-ids)))))
               (box-before (copy-tree box))
               (state-revision-before
                (and state (plist-get state :runtime-revision)))
               (state-reflow-scratch-before
                (and state (plist-get state :reflow-prewarm-scratch)))
               (state-report-before
                (and state (plist-get state :last-update-report)))
               (scroll-before
                (mapcar
                 (lambda (scroll-id)
                   (let ((scroll-state (ebox--scroll-get-state scroll-id)))
                     (list
                      scroll-id scroll-state
                      (cl-loop for (key value) on scroll-state by #'cddr
                               append
                               (list
                                key
                                (if (or
                                     (eq key :box)
                                     (memq
                                      key
                                      ebox--scroll-cache-transient-state-keys))
                                    value
                                  (copy-tree value)))))))
                 affected-scroll-ids))
               (transaction-completed nil)
               (prewarm-cancelled nil)
               (mutation-notified-p nil)
               changed-keys
               old-style-values
               result-report
               (content-seen nil)
               content-val
               content-changed)
      (ebox--mirror-region-update-box region-box-table region-id box)
      (cl-labels
          ((restore-plist-object
            (object snapshot)
            (when object
              (setcar object (car snapshot))
              (setcdr object (cdr snapshot))))
           (restore-model ()
            (let ((inhibit-quit t))
              (restore-plist-object box box-before)
              (ebox--mirror-region-update-box
               region-box-table region-id box)
              (dolist (entry scroll-before)
                (pcase-let ((`(,scroll-id ,scroll-state ,snapshot) entry))
                  (if scroll-state
                      (progn
                        (restore-plist-object scroll-state snapshot)
                        (puthash scroll-id scroll-state
                                 ebox--scroll-global-state))
                    (remhash scroll-id ebox--scroll-global-state))))
              (when state
                (plist-put state :runtime-revision state-revision-before)
                (plist-put state :reflow-prewarm-scratch
                           state-reflow-scratch-before)
                (plist-put state :last-update-report state-report-before))
              (when (buffer-live-p buffer)
                (ebox--refresh-buffer-box-extents buffer)
                (ebox-buffer-refresh-region-role-spans buffer)
                (ebox--refresh-buffer-scroll-content-markers buffer))))
           (run-update ()
            (cl-loop for (k v) on expanded by #'cddr do
                     (let ((target-key
                            (ebox--region-update-normalize-property k)))
                       (cond
                        ((eq target-key :content)
                         (setq content-seen t
                               content-val v))
                        ((memq target-key ebox--region-update-longhand-props)
                         (unless (equal (ebox-get box target-key) v)
                           (when (and (eq target-key :overflow)
                                      (not (plist-member old-style-values
                                                        target-key)))
                             (setq old-style-values
                                   (plist-put old-style-values target-key
                                              (ebox-get box target-key))))
                           (when (and buffer (not prewarm-cancelled))
                             (ebox--cancel-buffer-runtime-prewarm buffer)
                             (setq prewarm-cancelled t))
                           (unless mutation-notified-p
                             (when buffer
                               (ebox-incremental--notify-before-runtime-mutation
                                buffer 'region-update))
                             (setq mutation-notified-p t))
                           (ebox-put box target-key v)
                           (push target-key changed-keys)))
                        (t nil))))
            (setq content-changed
                  (and content-seen
                       (not (equal (ebox-get box :content) content-val))))
            (when (and (null changed-keys)
                       (not content-changed)
                       (not (and buffer
                                 (ebox-incremental-batching-p buffer))))
              (setq result-report
                    (ebox--update-report
                     region-id 'no-op
                     :dirty-count 0
                     :patch-count 0
                     :patch-ops nil))
              (when buffer
                (ebox--set-buffer-update-report buffer result-report)))
            (when (and buffer (or changed-keys content-changed))
              (unless prewarm-cancelled
                (ebox--cancel-buffer-runtime-prewarm buffer)
                (setq prewarm-cancelled t))
              (ebox--invalidate-buffer-render-signatures
               buffer (ebox--ensure-node-id box)))
            ;; content sync (scroll state + rerender)
            (when content-changed
              (unless mutation-notified-p
                (when buffer
                  (ebox-incremental--notify-before-runtime-mutation
                   buffer 'region-update))
                (setq mutation-notified-p t))
              (let ((scroll-state (ebox--scroll-get-state region-id)))
                (ebox-put box :content content-val)
                (push :content changed-keys)
                (when scroll-state
                  (let* ((formatted (ebox--format-content box))
                         (formatted-lines (ebox-string-lines formatted))
                         (text-height (length formatted-lines))
                         (content-height (ebox--content-height box text-height))
                         (requested-offset
                          (if (plist-member expanded :scroll-offset)
                              (or (ebox-get box :scroll-offset) 0)
                            (or (plist-get scroll-state :scroll-offset) 0)))
                         (scroll-offset
                          (max 0
                               (min requested-offset
                                    (max 0 (- text-height content-height))))))
                    (ebox-put box :scroll-offset scroll-offset)
                    (setq scroll-state
                          (ebox--scroll-state-set-lines
                           scroll-state formatted-lines))
                    (plist-put scroll-state :content-height content-height)
                    (plist-put scroll-state :scroll-offset scroll-offset)
                    (plist-put scroll-state :box box)))))
            ;; Merge non-content changes into one dirty kind, then let the
            ;; shared constraint-change executor choose the smallest valid
            ;; patch owner.
            (when changed-keys
              (setq changed-keys (nreverse changed-keys))
              (let* ((dirty-kind (ebox--region-update-dirty-kind changed-keys))
                     (batched
                      (and buffer
                           (ebox-incremental-record-region-change
                            buffer region-id dirty-kind changed-keys
                            old-style-values)))
                     root-width-reflow)
                (when batched
                  (ebox--cancel-buffer-runtime-prewarm buffer))
                (unless batched
                  (setq result-report
                        (let* ((_root-width-reflow
                                (setq root-width-reflow
                                      (ebox--root-width-reflow-update-p
                                       buffer node changed-keys))))
                          (when (and node (not root-width-reflow))
                            (ebox--ensure-visible-node-runtime-indexes
                             buffer node region-id))
                          (or (ebox--try-scroll-offset-fast-path
                               buffer region-id changed-keys)
                              (and node (not root-width-reflow)
                                   (eq dirty-kind 'geometry)
                                   (ebox--try-lazy-scroll-deferred-patch
                                    buffer region-id node changed-keys))
                              (and node (not root-width-reflow)
                                   (eq dirty-kind 'geometry)
                                   (ebox--try-hidden-scroll-state-span-patch
                                    buffer region-id node changed-keys))
                              (and node (not root-width-reflow)
                                   (eq dirty-kind 'geometry)
                                   (ebox--try-hidden-scroll-root-fallback
                                    buffer region-id node changed-keys))
                              (and node (not root-width-reflow)
                                   (eq dirty-kind 'geometry)
                                   (ebox--try-scroll-state-span-patch
                                    buffer region-id node changed-keys))
                              (ebox--rerender-region-for-dirty-kind
                               region-id dirty-kind changed-keys buffer
                               old-style-values))))
                  (when buffer
                    (let* ((confirm-reflow-scratch
                            (and root-width-reflow
                                 (equal changed-keys '(:width))))
                           (revision
                            (ebox--bump-buffer-runtime-revision
                             buffer confirm-reflow-scratch)))
                      (when confirm-reflow-scratch
                        (ebox--confirm-reflow-prewarm-scratch
                         buffer region-id revision))))
                  (when (and buffer
                             (not root-width-reflow)
                             (ebox--scroll-state-sync-after-update-p
                              result-report))
                    (unless (ebox--sync-scroll-offset-state-window
                             region-id changed-keys)
                      (error
                       "Ebox could not atomically synchronize scroll state %S"
                       region-id))
                    (setq result-report
                          (ebox--sync-scroll-state-lines-for-node
                           buffer region-id node changed-keys result-report)))
                  (when (and buffer result-report)
                    (ebox--set-buffer-update-report buffer result-report))
                  (when buffer
                    (ebox--schedule-buffer-runtime-prewarm buffer)))))))
        (unwind-protect
            (progn
              (if (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (atomic-change-group
                      (run-update)))
                (run-update))
              (setq transaction-completed t))
          (unless transaction-completed
            (restore-model)))
        result-report))))))))

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
        (ebox--schedule-buffer-runtime-prewarm buffer)
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
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (let (start end)
        (dolist (region-id (ebox--node-all-region-ids node))
          (dolist (role ebox--horizontal-border-anchor-roles)
            (dolist (span (ebox--region-find region-id role))
              (let ((span-start (if (markerp (car span))
                                    (marker-position (car span))
                                  (car span)))
                    (span-end (if (markerp (cdr span))
                                  (marker-position (cdr span))
                                (cdr span)))
                    (start-buffer (and (markerp (car span))
                                       (marker-buffer (car span))))
                    (end-buffer (and (markerp (cdr span))
                                     (marker-buffer (cdr span)))))
                (when (and span-start span-end (< span-start span-end)
                           (or (and (null start-buffer) (null end-buffer))
                               (and (eq start-buffer buffer)
                                    (eq end-buffer buffer))))
                  (setq start (if start (min start span-start) span-start)
                        end (if end (max end span-end) span-end)))))))
        (and start end (cons start end))))))

(defun ebox--host-ref-extent-bounds (buffer node)
  "Return fallback live extent bounds for NODE in BUFFER, or nil."
  (let (start end)
    (dolist (region-id (ebox--node-all-region-ids node))
      (when-let* ((extents (ebox--live-box-extents region-id))
                  (start-marker (car extents))
                  (end-marker (cdr extents))
                  (region-start (marker-position start-marker))
                  (region-end (marker-position end-marker)))
        (when (and (eq (marker-buffer start-marker) buffer)
                   (eq (marker-buffer end-marker) buffer))
          (setq start (if start (min start region-start) region-start)
                end (if end (max end region-end) region-end)))))
    (and start end (< start end) (cons start end))))

;;;###autoload
(defun ebox-host-ref-bounds (buffer-or-name host-ref)
  "Return live integer bounds for HOST-REF in BUFFER-OR-NAME.

The result is a `(START . END)' pair spanning the referenced runtime node's
rendered border-box characters (excluding margins), or nil when the buffer,
reference, or live box extents no longer exist.  HOST-REF is opaque and
compared with `equal'."
  (when-let* ((buffer (ebox--host-ref-buffer buffer-or-name))
              (node (ebox--host-ref-node buffer host-ref)))
    (or (ebox--host-ref-role-bounds buffer node)
        (ebox--host-ref-extent-bounds buffer node))))

;;;###autoload
(defun ebox-host-ref-position (buffer-or-name host-ref)
  "Return the first live buffer position for HOST-REF, or nil.
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
(defun ebox-commit (buffer-or-name next-root &optional after-publication)
  "Atomically commit declarative NEXT-ROOT into BUFFER-OR-NAME.

NEXT-ROOT may be a newly built Ebox node tree or a one-shot logical candidate
from `ebox-candidate-begin'.  A complete root is copied into a buffer-owned
runtime.  A logical candidate path-copies replaced ancestor chains, shares
untouched subtrees, and isolates retained scroll nodes before proof rendering.
Both forms reconcile Ebox-owned identity,
prove rendered owners in isolation, and publish only property-aware buffer
differences.  Validation, render, and publication failures leave the current
buffer and runtime unchanged.

When AFTER-PUBLICATION is non-nil, it must be a function of one update report.
Ebox invokes it inside the quit-free atomic publication boundary after the
buffer and runtime agree.  This hook is for framework pointer promotion only;
it must not run application code.  An error rolls the Ebox publication back.

Return the successful publication report stored by `ebox-buffer-update-report'."
  (unless (or (null after-publication) (functionp after-publication))
    (signal 'wrong-type-argument (list 'functionp after-publication)))
  (let ((buffer (get-buffer buffer-or-name)))
    (unless (buffer-live-p buffer)
      (error "Ebox declarative commit requires an existing live buffer: %S"
             buffer-or-name))
    (let* ((commit-input
            (if (ebox-candidate-p next-root)
                (ebox-incremental-consume-candidate buffer next-root)
              (ebox-incremental-prepare-root-commit buffer next-root)))
           (source (plist-get commit-input :root))
           (callback
            (or after-publication
                ebox-incremental--after-declarative-publication))
           (surface
            (ebox-surface-mount-buffer
             buffer source
             (plist-get commit-input :report-base)
             callback
             (plist-get commit-input :preserve-identities-p)
             (plist-get commit-input :state-overrides))))
      (plist-get (tp-surface-client-state surface) :last-update-report))))

;;;###autoload
(defun ebox-rerender-buffer-with-context
    (buffer viewport-width &optional viewport-height)
  "Rerender BUFFER's stored runtime tree using VIEWPORT-WIDTH.
When VIEWPORT-HEIGHT is non-nil, height values using `(viewport-height)' are
resolved against that line count.
This preserves node and region identity and routes viewport-dependent changes
through dirty-set and patch-set execution before falling back to root rerender."
  (let* ((state (ebox--buffer-render-state buffer))
         (old-viewport-width (and state
                                  (plist-get state :viewport-width))))
    (ebox--cancel-buffer-runtime-prewarm buffer)
    (prog1
        (ebox-incremental-rerender-buffer-with-context
         buffer viewport-width viewport-height)
      (ebox--schedule-buffer-runtime-prewarm buffer)
      (ebox--schedule-buffer-reflow-cache-prewarm
       buffer old-viewport-width viewport-width))))

;;;###autoload
(defun ebox-display-buffer (buffer-or-name node)
  "Render NODE to BUFFER-OR-NAME and display the buffer with `pop-to-buffer'."
  (declare (indent 1))
  (delete-other-windows)
  (switch-to-buffer (ebox-render-to-buffer buffer-or-name node)))

(defconst ebox-public-api
  '(ebox-buffer-mode
    ebox-buffer-update-report
    ebox-build
    ebox-byte-compile
    ebox-candidate-begin
    ebox-candidate-replace
    ebox-candidate-replace-host-ref
    ebox-clear-cache
    ebox-column
    ebox-commit
    ebox-concat
    ebox-create
    ebox-display-buffer
    ebox-flex
    ebox-flex-item
    ebox-host-ref-bounds
    ebox-host-ref-position
    ebox-pop-to-buffer
    ebox-region-ids
    ebox-region-update
    ebox-render
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
    ebox-switch-to-buffer
    ebox-update-selector
    ebox-wheel-scroll-down
    ebox-wheel-scroll-up)
  "Stable core Ebox entry points available to applications and tooling.")

(defconst ebox-feature-families
  '(box-model
    declarative-commit
    direct-region-update
    dsl
    failure-atomic-rollback
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
;; The following functions form the stable public interface of ebox.
;; All other ebox-- prefixed functions are internal implementation
;; details and may change without notice.
;;
;; ── Creation ──────────────────────────────────────────────────
;;   ebox-create &rest plist
;;       Create a box. Key options: :content :width :height
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
;;   ebox-display-buffer buf box   → render and display with pop-to-buffer
;;   ebox-host-ref-position buf ref → first live position for :host-ref
;;   ebox-host-ref-bounds buf ref   → live (START . END) bounds for :host-ref
;;
;; ── Region IDs ────────────────────────────────────────────────
;;   ebox-region-ids layout       → list of region-ids in document order
;;                                   call BEFORE render-to-buffer
;;
;; ── Dynamic Updates (call inside with-current-buffer + inhibit-read-only) ──
;;   ebox-region-update region-id &rest props
;;       Single entry-point for all dynamic changes.  PROPS keywords mirror
;;       those of ebox-create:
;;         :content STRING
;;         :width SIZE  :padding-left SIZE  :padding-right SIZE  …
;;         :border-color COLOR  :border-top-color COLOR  …
;;         :bgcolor COLOR
;;       Multiple keywords may be combined in one call.
;;
;; ── Scroll ────────────────────────────────────────────────────
;;   ebox-scroll-up   &optional n
;;   ebox-scroll-down &optional n
;;   ebox-scroll-map  (keymap, bind to buffer local map)
;;
;; ── Cache ─────────────────────────────────────────────────────
;;   ebox-clear-cache

;;; ebox.el ends here
