;;; ebox-layout.el --- Generic layout composition for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns generic box, row, column, stack, and spacer layout operations.  It does
;; not own flex/grid formatting or Emacs buffer patch execution.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ebox-tree)
(require 'ebox-measure)
(require 'ebox-fragment)
(require 'ebox-render-context)
(require 'ebox-buffer-backend)

(declare-function ebox--render-grid "ebox-grid" (node))
(declare-function ebox--render-flex "ebox-flex" (node))
(declare-function ebox--render-with-cache
                  "ebox-incremental" (node &optional force cache-probe))
(declare-function ebox-create "ebox" (&rest plist))
(declare-function ebox-get "ebox" (box property))
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--scroll-clear-state "ebox" (region-id))
(declare-function ebox--scroll-set-state "ebox" (region-id state))
(declare-function ebox--apply-hidden-visibility "ebox" (string))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-string-height "ebox" (string))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox--maplines "ebox" (function string))
(declare-function ebox--line-has-non-content-properties-p "ebox" (line))
(declare-function ebox--lines-align-vertical
                  "ebox" (string height align))
(declare-function ebox--lines-concat-horizontal "ebox" (&rest strings))
(declare-function ebox--lines-stack-vertical "ebox" (&rest strings))
(declare-function ebox--add-content-owner
                  "ebox-buffer-backend" (string region-id))
(declare-function ebox--pixel-border
                  "ebox-buffer-backend"
                  (pixel-width height &optional color))
(declare-function ebox--propertize-color
                  "ebox-buffer-backend" (string color))
(declare-function ebox--propertize-colors
                  "ebox-buffer-backend" (string color bgcolor))
(declare-function ebox--propertize-content-line
                  "ebox-buffer-backend" (line region-id idx fallback))
(declare-function ebox--propertize-overline
                  "ebox-buffer-backend" (string &optional color))
(declare-function ebox--propertize-region
                  "ebox-buffer-backend" (string property region-id))
(declare-function ebox--propertize-typography
                  "ebox-buffer-backend" (string style))
(declare-function ebox--propertize-underline
                  "ebox-buffer-backend" (string &optional color))

(defvar ebox--render-runtime-revision nil
  "Current buffer runtime revision for render-local cache validation.")

(defvar ebox--region-id-counter)
(defvar ebox--runtime-node-id-counter)
(defvar ebox--region-box-table)
(defvar ebox--render-region-id)
(defvar ebox--defer-scroll-content-index)

(defvar ebox--intrinsic-layout-measurement nil
  "Non-nil while measuring intrinsic layout contributions.
Descendants still see the current containing block, but stack/column containers
must not stretch their own outer width to that containing block.")

(defvar ebox--inline-auto-width-intrinsic-p nil
  "Non-nil while a horizontal layout sizes auto-width children intrinsically.
The ambient viewport remains available to explicit `viewport' and `stretch'
widths, but an omitted or `auto' width must not consume the whole horizontal
containing block merely because the row itself is being rendered in it.")

(defvar ebox--box-content-render-cache nil
  "Dynamic render-pass cache for rendered lazy child content.")

(defvar ebox--rendered-uniform-width-table
  (make-hash-table :test 'eq :weakness 'key)
  "Weak map from rendered strings to their proven uniform pixel width.")

(defvar ebox--transparent-preformatted-box-fast-path-disabled nil
  "Non-nil disables transparent preformatted box reuse for diagnostics.")

(defvar ebox--flat-preformatted-box-fast-path-disabled nil
  "Non-nil disables one-pass preformatted wrapper rendering for diagnostics.")

(declare-function ebox--strip-paint-origins!
                  "ebox-render-context" (string))

(defun ebox--record-rendered-uniform-width (rendered pixel-width)
  "Record that every line of RENDERED is exactly PIXEL-WIDTH wide."
  (when (and (stringp rendered) (numberp pixel-width))
    (puthash rendered pixel-width ebox--rendered-uniform-width-table))
  rendered)

(defun ebox--preformatted-content-lines-fit-p (lines pixel-width)
  "Return non-nil when LINES fit the exact content PIXEL-WIDTH.
Blank lines without data-bearing properties are safe because the wrapper
replaces them with its full-width filler line."
  (cl-every
   (lambda (line)
     (or (and (string-blank-p line)
              (not (ebox--line-has-non-content-properties-p line)))
         (= (ebox--string-pixel-width line) pixel-width)))
   lines))

(defun ebox--every-rendered-line-nonempty-p (rendered)
  "Return non-nil when every line in RENDERED can carry text properties."
  (let ((start 0)
        (length (length rendered))
        valid)
    (setq valid (> length 0))
    (while (and valid (<= start length))
      (let ((end (or (string-match "\n" rendered start) length)))
        (setq valid (< start end))
        (setq start (1+ end))))
    valid))

(defun ebox--finish-preformatted-content-ownership! (rendered region-id)
  "Finish line ownership for REGION-ID in pre-owned RENDERED."
  (let ((start 0)
        (index 0)
        (length (length rendered)))
    (while (<= start length)
      (let ((end (or (string-match "\n" rendered start) length)))
        (unless (text-property-not-all
                 start end 'ebox-content nil rendered)
          (add-text-properties
           start end
           (list 'ebox-content region-id 'ebox-content-idx index)
           rendered))
        (when (< end length)
          (remove-text-properties
           end (1+ end)
           '(ebox-content-owner nil ebox-content-owners nil)
           rendered))
        (setq start (1+ end)
              index (1+ index)))))
  rendered)

(defun ebox--apply-surface-properties (rendered properties)
  "Apply text-property PROPERTIES to RENDERED's character surface.

Newlines are excluded.  For each property independently, an existing non-nil
value on an inner rendered surface wins over the enclosing box's value."
  (when properties
    (unless (and (proper-list-p properties)
                 (zerop (% (length properties) 2)))
      (error "ebox: :surface-properties must be an even property list"))
    (let ((tail properties))
      (while tail
        (unless (symbolp (car tail))
          (error "ebox: surface property name must be a symbol: %S"
                 (car tail)))
        (setq tail (cddr tail))))
    (let ((line-start 0)
          (limit (length rendered)))
      (while (< line-start limit)
        (let ((line-end (or (string-match "\n" rendered line-start) limit))
              (tail properties))
          (while tail
            (let ((property (pop tail))
                  (value (pop tail))
                  (position line-start))
              ;; A nil text-property value denotes absence.  Skipping it also
              ;; prevents an enclosing surface from deleting an inner value.
              (when value
                (while (< position line-end)
                  (let ((next (or (next-single-property-change
                                   position property rendered line-end)
                                  line-end)))
                    (unless (get-text-property position property rendered)
                      (add-text-properties
                       position next (list property value) rendered))
                    (setq position (max next (1+ position))))))))
          (setq line-start
                (if (< line-end limit) (1+ line-end) limit))))))
  rendered)

(defun ebox--render-transparent-preformatted-box (box)
  "Render BOX by owning proven exact preformatted child content directly.
Return nil unless BOX has no visual chrome or sizing behavior that requires
the generic box pipeline."
  (when (and (not ebox--transparent-preformatted-box-fast-path-disabled)
             (ebox--box-content-node box)
             (not (eq (ebox-get box :visibility) 'hidden))
             (null (ebox-get box :wrap-mode))
             (eq (ebox-get box :text-align) 'left)
             (eq (ebox-get box :vertical-align) 'top)
             (null (ebox-get box :height))
             (equal (or (ebox-get box :min-height) 0) 0)
             (null (ebox-get box :max-height))
             (eq (ebox-get box :overflow) 'scroll)
             (equal (ebox-get box :padding-left-pixel) 0)
             (equal (ebox-get box :padding-right-pixel) 0)
             (equal (ebox-get box :padding-top-height) 0)
             (equal (ebox-get box :padding-bottom-height) 0)
             (equal (ebox-get box :margin-left-pixel) 0)
             (equal (ebox-get box :margin-right-pixel) 0)
             (equal (ebox-get box :margin-top-height) 0)
             (equal (ebox-get box :margin-bottom-height) 0)
             (equal (ebox-get box :border-left-pixel) 0)
             (equal (ebox-get box :border-right-pixel) 0)
             (not (ebox-get box :border-top-p))
             (not (ebox-get box :border-bottom-p))
             (null (ebox-get box :color))
             (null (ebox-get box :bgcolor)))
    (let* ((content (ebox--box-content box))
           (known-width
            (gethash content ebox--rendered-uniform-width-table))
           (content-width (and (numberp known-width)
                               (ebox--content-pixel box))))
      (when (and (numberp known-width)
                 (= known-width content-width)
                 (ebox--every-rendered-line-nonempty-p content))
        (let* ((region-id (or ebox--render-region-id
                              (ebox--ensure-region-id box)))
               (rendered (ebox--add-content-owner content region-id)))
          (ebox--finish-preformatted-content-ownership!
           rendered region-id)
          (ebox--apply-surface-properties
           rendered (ebox-get box :surface-properties))
          (puthash region-id box ebox--region-box-table)
          (unless ebox--intrinsic-layout-measurement
            (ebox--scroll-clear-state region-id))
          (ebox--record-rendered-uniform-width rendered known-width))))))

(defun ebox--render-flat-preformatted-box (box)
  "Render simple BOX chrome in a single line-oriented pass.
Return nil unless BOX has no child layout, no margins or vertical clipping,
and its formatted content exactly fills the used height."
  (when (and (not ebox--flat-preformatted-box-fast-path-disabled)
             (not (eq (ebox-get box :visibility) 'hidden))
             (null (ebox--box-content-node box))
             (stringp (ebox-get box :content))
             (eq (ebox-get box :vertical-align) 'top)
             (equal (or (ebox-get box :min-height) 0) 0)
             (null (ebox-get box :max-height))
             (equal (or (ebox-get box :scroll-offset) 0) 0)
             (equal (ebox-get box :margin-left-pixel) 0)
             (equal (ebox-get box :margin-right-pixel) 0)
             (equal (ebox-get box :margin-top-height) 0)
             (equal (ebox-get box :margin-bottom-height) 0))
    (let* ((content (ebox--box-content box))
           (exact-p (and (plist-get box :ebox-content-width-exact-p)
                         (null (ebox-get box :wrap-mode))
                         (eq (ebox-get box :text-align) 'left)))
           (formatted (if exact-p
                          content
                        (ebox--format-content-string box content)))
           (lines (ebox-string-lines formatted))
           (text-height (length lines))
           (content-height (ebox--content-height box text-height))
           (content-pixel (ebox--content-pixel box))
           (lines-fit-p
            (ebox--preformatted-content-lines-fit-p lines content-pixel))
           (underfilled-simple-scroll-p
            (and lines-fit-p
                 (< text-height content-height)
                 (eq (ebox-get box :overflow) 'scroll)
                 (= (ebox-get box :padding-left-pixel) 0)
                 (= (ebox-get box :padding-right-pixel) 0)
                 (= (floor (ebox-get box :padding-top-height)) 0)
                 (= (floor (ebox-get box :padding-bottom-height)) 0)
                 (= (ebox-get box :border-left-pixel) 0)
                 (= (ebox-get box :border-right-pixel) 0)
                 (not (ebox-get box :border-top-p))
                 (not (ebox-get box :border-bottom-p)))))
      (when (and lines-fit-p
                 (or (= text-height content-height)
                     underfilled-simple-scroll-p))
        (let* ((region-id (or ebox--render-region-id
                              (ebox--ensure-region-id box)))
               (padding-line-filler (ebox-pixel-space content-pixel))
               (rendered
                (if underfilled-simple-scroll-p
                    (ebox-lines-join
                     (ebox--render-underfilled-simple-scroll-lines
                      lines region-id content-height padding-line-filler
                      (ebox-get box :color) (ebox-get box :bgcolor)))
                  (ebox-lines-join
                   (ebox--window-render-flat-wrapper-chunk-lines
                    box lines 0 region-id padding-line-filler t t)))))
          (when underfilled-simple-scroll-p
            (ebox--apply-surface-properties
             rendered (ebox-get box :surface-properties)))
          (puthash region-id box ebox--region-box-table)
          (unless ebox--intrinsic-layout-measurement
            (ebox--scroll-clear-state region-id))
          (ebox--record-rendered-uniform-width
           rendered (+ content-pixel (ebox--side-pixel box))))))))

(defvar ebox--scroll-window-render-disabled nil
  "Non-nil disables lazy scroll-window rendering for full materialization.")

(defvar ebox--scroll-window-render-result nil
  "Dynamic metadata for the current box's lazy scroll-window render.")

(defvar ebox--scroll-window-cached-state nil
  "Dynamic staged scroll state used by a bounded cached-window projection.")

(defvar ebox--scroll-window-cached-rendered-lines-p nil
  "Non-nil when cached scroll lines already carry wrapper ownership.")

(defvar ebox--scroll-window-skip-state-rebuild-p nil
  "Non-nil when a scroll projection already staged its derived line indexes.")

(defvar ebox--scroll-rendered-content-lines-private-p nil
  "Non-nil when scroll content line inputs may receive ownership in place.")

(defvar ebox--propertize-private-content-line-p)

(defvar ebox--window-line-renderer-table (make-hash-table :test 'eq)
  "Node-type keyed renderers for lazy scroll window line production.")

(defvar ebox--window-line-prewarmer-table (make-hash-table :test 'eq)
  "Node-type keyed prewarmers for yielding lazy scroll production.")

(defvar ebox--scroll-window-yielding-prewarm-p nil
  "Non-nil lets an idle prefix slice prepare one atomic child then yield.")

(defvar ebox--scroll-window-prewarm-state nil
  "Prefix-local state table used by yielding window-line prewarmers.")

(defvar ebox-scroll-lazy-prefix-lookahead-lines)
(defvar ebox-wheel-scroll-step)
(defvar ebox--scroll-window-initial-lookahead-lines-override nil
  "Optional exact lookahead used by latency-sensitive root reflows.")
(defvar ebox--render-cache-allow-viewport-dependent)
(defvar ebox--render-cache-signature-cache)
(defvar ebox--render-cache-table)
(defvar ebox--render-cache-scroll-state-region-ids)
(defvar ebox--render-cache-scroll-state-restorable-p)
(defvar ebox--render-cache-scroll-state-retained-cost-cache)

(declare-function ebox-style-cascade-active-p "ebox-style" ())
(declare-function ebox-surface--candidate-root "ebox-surface"
                  (source preserve-identities-p))
(declare-function ebox-surface--inline-inheritance-required-p "ebox-surface"
                  (root))
(declare-function ebox--add-render-face!
                  "ebox-render-context" (string start end face &optional append))

(defun ebox--register-window-line-renderer (type function)
  "Register FUNCTION as TYPE's lazy window-line renderer.
FUNCTION receives a node and a line limit.  It should return a plist with
`:lines' and `:complete', or nil when the node needs normal rendering.
When returned lines are not already target-width lines, the plist may include
`:pixel-width' so the generic stack window can pad them.  Incremental
producers may also return an exact `:prefix-delta' with equal-length rewrite
and append payloads; in that case they must retain the returned list's cons
prefix across extensions."
  (unless (symbolp type)
    (error "ebox: window-line renderer type must be a symbol: %S" type))
  (unless (functionp function)
    (error "ebox: window-line renderer must be a function: %S" function))
  (puthash type function ebox--window-line-renderer-table)
  function)

(defun ebox--register-window-line-prewarmer (type function)
  "Register FUNCTION as TYPE's yielding lazy line prewarmer."
  (unless (symbolp type)
    (error "ebox: window-line prewarmer type must be a symbol: %S" type))
  (unless (functionp function)
    (error "ebox: window-line prewarmer must be a function: %S" function))
  (puthash type function ebox--window-line-prewarmer-table)
  function)

(defun ebox--prewarm-node-window-line (node target-width)
  "Prepare at most one atomic child of NODE for TARGET-WIDTH.
Return non-nil only when the caller should yield without publishing a line.
Single-child wrappers are transparent to this scheduling boundary."
  (when (and ebox--scroll-window-yielding-prewarm-p
             (hash-table-p ebox--scroll-window-prewarm-state)
             (listp node)
             (not (stringp node)))
    (let* ((type (plist-get node :ebox-type))
           (prewarmer (gethash type ebox--window-line-prewarmer-table)))
      (if prewarmer
          (funcall prewarmer node target-width)
        (let ((children (ebox-tree--children-raw node)))
          (when (and children (null (cdr children)))
            (ebox--prewarm-node-window-line (car children) target-width)))))))

(defun ebox--render-node-window-lines (node limit)
  "Return NODE's lazy window lines through the registered type renderer."
  (when-let* ((type (and (listp node) (plist-get node :ebox-type)))
              (renderer (gethash type ebox--window-line-renderer-table)))
    (funcall renderer node limit)))

(defun ebox--scroll-lazy-prefix-lookahead-lines ()
  "Return the current lazy scroll prefix lookahead in lines."
  (if (boundp 'ebox-scroll-lazy-prefix-lookahead-lines)
      (max 0 (or ebox-scroll-lazy-prefix-lookahead-lines 0))
    8))

(defun ebox--scroll-window-initial-lookahead-lines ()
  "Return extra lazy scroll lines retained after initial render."
  (if (numberp ebox--scroll-window-initial-lookahead-lines-override)
      (max 0 ebox--scroll-window-initial-lookahead-lines-override)
    (let ((prefix-lookahead (ebox--scroll-lazy-prefix-lookahead-lines))
          (wheel-lookahead (if (boundp 'ebox-wheel-scroll-step)
                               (max 0 (or ebox-wheel-scroll-step 0))
                             16)))
      (if (and ebox--defer-scroll-content-index
               (boundp 'ebox-wheel-smooth-scroll)
               ebox-wheel-smooth-scroll)
          (max wheel-lookahead
               (+ prefix-lookahead
                  (if (boundp 'ebox-wheel-smooth-scroll-lines-per-tick)
                      (max 1 (or ebox-wheel-smooth-scroll-lines-per-tick 1))
                    1)))
        (+ prefix-lookahead wheel-lookahead)))))

(defun ebox--scroll-rendered-content-lines
    (box lines region-id &optional start-index)
  "Return LINES as rendered scroll content lines for BOX and REGION-ID.
START-INDEX is the first source line index represented by LINES."
  (let* ((padding-line-filler
          (ebox-pixel-space (ebox--content-pixel box)))
         (color (ebox-get box :color))
         (bgcolor (ebox-get box :bgcolor))
         (rendered
          (cl-loop for line in lines
                   for idx from (or start-index 0)
                   collect
                   (let* ((colored-p (or color bgcolor))
                          (owned-source
                           (if colored-p
                               (ebox--propertize-colors
                                (if (string-empty-p line)
                                    padding-line-filler
                                  line)
                                color bgcolor)
                             line)))
                     (let ((ebox--propertize-private-content-line-p
                            (or colored-p
                                ebox--scroll-rendered-content-lines-private-p)))
                       (ebox--propertize-content-line
                        owned-source region-id idx padding-line-filler))))))
    rendered))

(defun ebox--render-underfilled-simple-scroll-lines
    (lines region-id content-height padding-line-filler color bgcolor)
  "Finish chrome-free top-aligned underfilled scroll LINES in one pass."
  (let ((ebox--propertize-private-content-line-p t)
        rendered-lines)
    (cl-labels
        ((finish-line (line index source-p)
           (when source-p
             (setq line
                   (ebox--propertize-content-line
                    line region-id index padding-line-filler)))
           (when (and (string-blank-p line)
                      (not (ebox--line-has-non-content-properties-p line)))
             (let ((content-id (get-text-property 0 'ebox-content line))
                   (content-idx
                    (get-text-property 0 'ebox-content-idx line)))
               (setq line
                     (if content-id
                         (propertize padding-line-filler
                                     'ebox-content content-id
                                     'ebox-content-idx content-idx
                                     'ebox-content-owner region-id)
                       (propertize padding-line-filler
                                   'ebox-content region-id
                                   'ebox-content-idx 0
                                   'ebox-content-owner region-id)))))
           ;; `ebox-string-lines' made these source lines private, and blank
           ;; normalization above creates a fresh filler.  Apply the same face
           ;; properties in place instead of copying every viewport-wide line.
          (when color
             (ebox--add-render-face!
              line 0 (length line) `(:foreground ,color) t))
           (when bgcolor
             (ebox--add-render-face!
              line 0 (length line) `(:background ,bgcolor) t))
           line))
      (cl-loop for line in lines
               for index from 0
               do (push (finish-line line index t) rendered-lines))
      (dotimes (_ (max 0 (- content-height (length lines))))
        (push (finish-line padding-line-filler 0 nil) rendered-lines)))
    (nreverse rendered-lines)))

(defun ebox--scroll-rendered-prefix-through-content
    (box content-lines content-count region-id
         rendered-lines rendered-count rendered-tail)
  "Extend RENDERED-LINES through CONTENT-COUNT and return cache metadata.
The result is (LINES COUNT TAIL).  Reuse the existing rendered prefix when it
is aligned with CONTENT-LINES; otherwise rebuild the bounded content cache."
  (cond
   ((>= rendered-count content-count)
    (list rendered-lines rendered-count rendered-tail))
   ((and rendered-lines (<= rendered-count content-count))
    (let* ((suffix
            (seq-take (nthcdr rendered-count content-lines)
                      (- content-count rendered-count)))
           (rendered-suffix
            (ebox--scroll-rendered-content-lines
             box suffix region-id rendered-count)))
      (pcase-let ((`(,new-lines ,new-tail)
                   (ebox--line-list-append!
                    rendered-lines rendered-tail rendered-suffix)))
        (list new-lines content-count new-tail))))
   (t
    (let ((rebuilt
           (ebox--scroll-rendered-content-lines
            box content-lines region-id 0)))
      (list rebuilt content-count (last rebuilt))))))

(defun ebox--lines-justify (string pixel-width &optional align)
  "Justify lines of STRING to PIXEL-WIDTH."
  (let ((align (or align 'left)))
    (if (eq align 'left)
        (ebox--maplines
         (lambda (line)
           (let ((line-width (ebox--string-pixel-width line)))
             (if (>= line-width pixel-width)
                 line
               (concat line (ebox-pixel-space
                             (- pixel-width line-width))))))
         string)
      (ebox--maplines
       (lambda (line)
         (ebox--pixel-reach line pixel-width align))
       string))))

(defsubst ebox--cjk-char-p (char)
  "Check if CHAR is a CJK (Chinese, Japanese, Korean) character."
  (and char
       (>= char #x3000)
       (or (<= char #x303F)                          ; CJK Symbols and Punctuation
           (and (>= char #x3040) (<= char #x309F))   ; Hiragana
           (and (>= char #x30A0) (<= char #x30FF))   ; Katakana
           (and (>= char #x3400) (<= char #x4DBF))   ; CJK Extension A
           (and (>= char #x4E00) (<= char #x9FFF))   ; CJK Unified Ideographs
           (and (>= char #xFF00) (<= char #xFFEF))))) ; Fullwidth Forms

(defsubst ebox--combining-char-p (char)
  "Return non-nil when CHAR is a combining mark."
  (and char
       (or (and (>= char #x0300) (<= char #x036F))
           (and (>= char #x1AB0) (<= char #x1AFF))
           (and (>= char #x1DC0) (<= char #x1DFF))
           (and (>= char #x20D0) (<= char #x20FF))
           (and (>= char #xFE20) (<= char #xFE2F)))))

(defsubst ebox--variation-selector-char-p (char)
  "Return non-nil when CHAR is a Unicode variation selector."
  (and char
       (or (and (>= char #xFE00) (<= char #xFE0F))
           (and (>= char #xE0100) (<= char #xE01EF)))))

(defsubst ebox--emoji-modifier-char-p (char)
  "Return non-nil when CHAR is an emoji modifier."
  (and char (>= char #x1F3FB) (<= char #x1F3FF)))

(defsubst ebox--regional-indicator-char-p (char)
  "Return non-nil when CHAR is a regional indicator symbol."
  (and char (>= char #x1F1E6) (<= char #x1F1FF)))

(defsubst ebox--grapheme-extension-char-p (char)
  "Return non-nil when CHAR extends the previous grapheme cluster."
  (or (ebox--combining-char-p char)
      (ebox--variation-selector-char-p char)
      (ebox--emoji-modifier-char-p char)
      (eq char #x200D)))

(defsubst ebox--grapheme-cluster-end (string start)
  "Return the end index of the grapheme cluster at START in STRING.
This handles the common clusters that matter for UI text: combining marks,
variation selectors, emoji modifiers, ZWJ sequences, and regional-indicator
pairs. It is intentionally small; full Unicode segmentation is out of scope."
  (let* ((len (length string))
         (end (min len (1+ start))))
    ;; Adjacent ASCII codepoints cannot form any cluster recognized below.
    ;; Keep the full Unicode path when a non-ASCII extension follows an ASCII
    ;; base, so combining marks retain exactly the same grouping.
    (unless (and (< (aref string start) 128)
                 (or (= end len) (< (aref string end) 128)))
      (when (and (< end len)
                 (ebox--regional-indicator-char-p (aref string start))
                 (ebox--regional-indicator-char-p (aref string end)))
        (setq end (1+ end)))
      (while (and (< end len)
                  (or (ebox--grapheme-extension-char-p (aref string end))
                      (eq (aref string (1- end)) #x200D)))
        (setq end (1+ end))))
    end))

(defun ebox--grapheme-clusters (string)
  "Return STRING as grapheme-cluster metadata plists."
  (let ((pos 0)
        (len (length string))
        clusters)
    (while (< pos len)
      (let* ((end (ebox--grapheme-cluster-end string pos))
             (text (substring string pos end)))
        (push (list :start pos
                    :end end
                    :text text
                    :width (ebox--string-pixel-width text)
                    :cjk (ebox--cjk-char-p (aref string pos))
                    :space (= (aref string pos) ?\s))
              clusters)
        (setq pos end)))
    (vconcat (nreverse clusters))))

(defun ebox--max-char-pixel (string)
  "Return the pixel width of the widest character in STRING."
  (if (string-empty-p string)
      (ebox--space-pixel-width)
    (let ((max-width 0)
          (clusters (ebox--grapheme-clusters string)))
      (dotimes (i (length clusters))
        (let ((width (plist-get (aref clusters i) :width)))
          (when (> width max-width) (setq max-width width))))
      (max max-width (ebox--space-pixel-width)))))

(defun ebox--wrap-line (line max-pixel wrap-mode)
  "Wrap a single LINE to MAX-PIXEL width, preserving text properties.
WRAP-MODE can be `word', `char', or `kp'.
CJK characters are always wrapped by char.
For `kp' mode, see `ebox--wrap-text' which delegates to ekp package.
Returns a list of strings (lines)."
  (cond
   ((or (null line) (string-empty-p line))
    (list ""))
   ;; Fast path: line fits
   ((<= (ebox--string-pixel-width line) max-pixel)
    (list line))
   ;; Wrap needed
   (t
    (let* ((clusters (ebox--grapheme-clusters line))
           (cluster-count (length clusters))
           (result-lines '())
           (line-start 0)
           (current-width 0)
           (index 0))
      (cl-labels ((cluster-start (i)
                    (plist-get (aref clusters i) :start))
                  (cluster-width (i)
                    (plist-get (aref clusters i) :width))
                  (cluster-cjk-p (i)
                    (plist-get (aref clusters i) :cjk))
                  (cluster-space-p (i)
                    (plist-get (aref clusters i) :space))
                  (flush-before (i)
                    (let ((end (cluster-start i)))
                      (when (< line-start end)
                        (push (substring line line-start end) result-lines))
                      (setq line-start end current-width 0))))
        (while (< index cluster-count)
          (let ((cluster-width (cluster-width index)))
            (cond
             ;; CJK: Wrap by character
             ((cluster-cjk-p index)
              (when (> (+ current-width cluster-width) max-pixel)
                (flush-before index))
              (setq current-width (+ current-width cluster-width))
              (setq index (1+ index)))

             ;; Word mode: Wrap by word
             ((eq wrap-mode 'word)
              (let ((word-end index)
                    (word-width 0))
                ;; Scan word
                (while (and (< word-end cluster-count)
                            (not (cluster-space-p word-end))
                            (not (cluster-cjk-p word-end)))
                  (setq word-width (+ word-width (cluster-width word-end)))
                  (setq word-end (1+ word-end)))
                (cond
                 ;; Word too long: split by char
                 ((> word-width max-pixel)
                  (while (< index word-end)
                    (let ((cw (cluster-width index)))
                      (when (> (+ current-width cw) max-pixel)
                        (flush-before index))
                      (setq current-width (+ current-width cw))
                      (setq index (1+ index)))))
                 ;; Word fits on current line
                 ((<= (+ current-width word-width) max-pixel)
                  (setq current-width (+ current-width word-width))
                  (setq index word-end))
                 ;; Word goes to next line
                 (t
                  (flush-before index)
                  (setq current-width word-width)
                  (setq index word-end)))
                ;; Handle trailing space
                (when (and (< index cluster-count) (cluster-space-p index))
                  (let ((space-width (cluster-width index)))
                    (if (<= (+ current-width space-width) max-pixel)
                        (progn
                          (setq current-width (+ current-width space-width))
                          (setq index (1+ index)))
                      (flush-before index)
                      (setq index (1+ index))
                      (setq line-start
                            (if (< index cluster-count)
                                (cluster-start index)
                              (length line))))))))

             ;; Char mode
             (t
              (when (> (+ current-width cluster-width) max-pixel)
                (flush-before index))
              (setq current-width (+ current-width cluster-width))
              (setq index (1+ index))))))
        ;; Flush remaining
        (when (< line-start (length line))
          (push (substring line line-start) result-lines)))
      (nreverse result-lines)))))

(defun ebox--wrap-text (text max-pixel wrap-mode)
  "Wrap multi-line TEXT to MAX-PIXEL using WRAP-MODE.
When WRAP-MODE is nil, return TEXT without pre-wrapping.
When WRAP-MODE is `kp', use Knuth-Plass algorithm via ekp package."
  (cond
   ((null wrap-mode)
    text)
   ((eq wrap-mode 'kp)
    (if (and (require 'ekp nil t)
             (fboundp 'ekp-pixel-justify))
        (ekp-pixel-justify text max-pixel)
      (ebox--wrap-text text max-pixel 'word)))
   (t
    (let* ((lines (ebox-string-lines text))
           (wrapped (mapcan (lambda (l)
                              (ebox--wrap-line l max-pixel wrap-mode))
                            lines)))
      (ebox-lines-join wrapped)))))

;;; ============================================================
;;; Render: Box Rendering Logic
;;; ============================================================

(defun ebox--side-pixel (box &optional side)
  "Calculate side pixel width (padding + border + margin).
SIDE can be `left', `right', or nil (both)."
  (let ((left (+ (ebox-get box :padding-left-pixel)
                 (ebox-get box :border-left-pixel)
                 (ebox-get box :margin-left-pixel)))
        (right (+ (ebox-get box :padding-right-pixel)
                  (ebox-get box :border-right-pixel)
                  (ebox-get box :margin-right-pixel))))
    (pcase side
      ('left left)
      ('right right)
      (_ (+ left right)))))

(defun ebox--side-height (box)
  "Calculate side height (padding + margin) in lines."
  (+ (floor (ebox-get box :padding-top-height))
     (floor (ebox-get box :padding-bottom-height))
     (floor (ebox-get box :margin-top-height))
     (floor (ebox-get box :margin-bottom-height))))

(defun ebox--box-sizing-content-pixel (box value)
  "Return VALUE converted to content pixels according to BOX sizing."
  (when value
    (if (eq (ebox-get box :box-sizing) 'border-box)
        (max 0 (- value (+ (ebox-get box :padding-left-pixel)
                           (ebox-get box :padding-right-pixel)
                           (ebox-get box :border-left-pixel)
                           (ebox-get box :border-right-pixel))))
      value)))

(defun ebox--box-sizing-content-height (box value)
  "Return VALUE converted to content lines according to BOX sizing."
  (when value
    (if (eq (ebox-get box :box-sizing) 'border-box)
        (max 0 (- value
                  (+ (floor (ebox-get box :padding-top-height))
                     (floor (ebox-get box :padding-bottom-height)))))
      value)))

(defun ebox--viewport-pixel-width (&optional default)
  "Return the current viewport width in pixels, or DEFAULT."
  (if (and (numberp ebox-viewport-width)
           (> ebox-viewport-width 0))
      (floor ebox-viewport-width)
    default))

(defun ebox--viewport-size-value-p (value)
  "Return non-nil when VALUE is a viewport-relative size marker."
  (or (eq value 'viewport)
      (and (consp value) (eq (car value) 'viewport))))

(defun ebox--horizontal-size-pixels (value &optional default)
  "Return VALUE as pixels using Ebox horizontal size units.
DEFAULT is returned when VALUE is nil or not a supported horizontal size.
In addition to normal Ebox units, `(viewport)' resolves to
`ebox-viewport-width'."
  (cond
   ((null value) default)
   ((ebox--viewport-size-value-p value)
    (ebox--viewport-pixel-width default))
   ((and (consp value) (numberp (car value))) (car value))
   ((numberp value) (* value (ebox--space-pixel-width)))
   (t default)))

(defun ebox--nonnegative-horizontal-size-pixels (value &optional default)
  "Return VALUE as non-negative horizontal pixels.
Signal an error when VALUE resolves to a negative width-like size."
  (let ((pixels (ebox--horizontal-size-pixels value default)))
    (when (and pixels (< pixels 0))
      (error "ebox: width values cannot be negative: %S" value))
    pixels))

(defun ebox--viewport-height-lines (&optional fallback)
  "Return the dynamically bound viewport height in lines, or FALLBACK."
  (if (and (numberp ebox-viewport-height)
           (> ebox-viewport-height 0))
      (floor ebox-viewport-height)
    fallback))

(defun ebox--viewport-height-size-value-p (value)
  "Return non-nil when vertical size VALUE depends on viewport height."
  (or (eq value 'viewport-height)
      (and (consp value)
           (or (eq (car value) 'viewport-height)
               (and (memq (car value) '(+ -))
                    (cl-some #'ebox--viewport-height-size-value-p
                             (cdr value)))))))

(defun ebox--resolve-height-expression-lines (value)
  "Resolve vertical size expression VALUE to raw outer height lines.
Return nil when VALUE depends on an unavailable viewport height."
  (cond
   ((numberp value) value)
   ((eq value 'viewport-height)
    (ebox--viewport-height-lines nil))
   ((and (consp value)
         (eq (car value) 'viewport-height))
    (ebox--viewport-height-lines nil))
   ((and (consp value)
         (memq (car value) '(+ -)))
    (let ((values
           (mapcar #'ebox--resolve-height-expression-lines
                   (cdr value))))
      (when (cl-every #'numberp values)
        (pcase (car value)
          ('+ (apply #'+ values))
          ('- (if (= (length values) 1)
                  (- (car values))
                (apply #'- values)))))))
   (t
    (error "ebox: unsupported height value after expansion: %S" value))))

(defun ebox--resolve-size-content-height (box value fallback)
  "Resolve vertical size VALUE to BOX content height lines.
FALLBACK is used for nil, auto, or unavailable viewport-height values."
  (cond
   ((null value) fallback)
   ((eq value 'auto) fallback)
   ((or (numberp value)
        (eq value 'viewport-height)
        (and (consp value)
             (or (eq (car value) 'viewport-height)
                 (memq (car value) '(+ -)))))
    (if-let* ((height (ebox--resolve-height-expression-lines value)))
        (ebox--box-sizing-content-height box (max 0 height))
      fallback))
   (t
    (error "ebox: unsupported height value after expansion: %S" value))))

(defun ebox--content-max-pixel (box)
  "Return BOX's max-content width in content pixels."
  (let* ((content (ebox--box-content box))
         (lines (ebox-string-lines content)))
    (if lines
        (apply #'max (mapcar #'ebox--string-pixel-width lines))
      0)))

(defun ebox--box-content-node (box)
  "Return BOX's lazy child layout node, if any."
  (plist-get box :ebox-content-node))

(defun ebox--box-content-cache-context ()
  "Return the current render context for lazy box content caching."
  (list ebox-viewport-width
        ebox-viewport-height
        ebox--intrinsic-layout-measurement
        ebox--inline-auto-width-intrinsic-p
        ebox--render-region-id))

(defun ebox--render-box-content-node (box node)
  "Render NODE as BOX content, using the render-pass cache when available."
  (let* ((content-viewport (ebox--wrapper-content-viewport-pixel box))
         (content
          (if (null ebox--box-content-render-cache)
              (ebox--render-node-as-box-content node box)
            (let* ((context (ebox--box-content-cache-context))
                   (entries (gethash box ebox--box-content-render-cache))
                   (cached (assoc context entries)))
              (if cached
                  (cdr cached)
                (let ((rendered
                       (ebox--render-node-as-box-content node box)))
                  (puthash box
                           (cons (cons context rendered) entries)
                           ebox--box-content-render-cache)
                  rendered))))))
    ;; A child layout has already resolved wrapping, alignment, and overflow
    ;; against CONTENT-VIEWPORT.  Preserve that fact on the owning box so the
    ;; generic string formatter does not traverse the same propertized output
    ;; a second time.  Intrinsic measurement is deliberately excluded: it
    ;; produces a natural-width probe, not final box content.
    (when (and content-viewport
               (not (eq (and (listp node) (plist-get node :ebox-type))
                        'box))
               (not ebox--intrinsic-layout-measurement)
               (equal (gethash content ebox--rendered-uniform-width-table)
                      content-viewport))
      (plist-put box :ebox-content-width-exact-p t))
    content))

(defun ebox--box-content (box)
  "Return BOX content, rendering any lazy child layout content if present."
  (ebox--propertize-typography
   (or (when-let* ((node (ebox--box-content-node box)))
         (ebox--render-box-content-node box node))
       (ebox-get box :content))
   box))

(defun ebox--line-min-content-pixel (line)
  "Return LINE's min-content width in content pixels."
  (let ((position 0)
        (end (length line))
        (max-width 0)
        (run-width 0))
    (cl-labels ((flush-run ()
                   (when (> run-width max-width)
                     (setq max-width run-width))
                   (setq run-width 0)))
      (while (< position end)
        (let* ((cluster-end
                (ebox--grapheme-cluster-end line position))
               (char (aref line position)))
          (cond
           ;; A separator width never contributes to either adjacent run.
           ;; Skip the pixel query instead of measuring and discarding it.
           ((= char ?\s)
            (flush-run))
           (t
            (let ((width
                   (if (and (< char 128)
                            (= cluster-end (1+ position))
                            (null (text-properties-at position line)))
                       (ebox--char-pixel-width char)
                     (ebox--substring-pixel-width
                      line position cluster-end))))
              (if (ebox--cjk-char-p char)
                  (progn
                    (flush-run)
                    (when (> width max-width)
                      (setq max-width width)))
                (setq run-width (+ run-width width))))))
          (setq position cluster-end)))
      (flush-run))
    max-width))

(defun ebox--content-min-pixel (box)
  "Return BOX's min-content width in content pixels."
  (let ((wrap-mode (ebox-get box :wrap-mode)))
    (if (null wrap-mode)
        (ebox--content-max-pixel box)
      (let ((lines (ebox-string-lines (ebox--box-content box)))
            (max-width 0))
        (dolist (line lines max-width)
          (setq max-width
                (max max-width (ebox--line-min-content-pixel line))))))))

(defun ebox--stretch-content-pixel (box)
  "Return BOX's stretch-fit content width, or nil without a viewport."
  (when-let* ((viewport (ebox--viewport-pixel-width nil)))
    (max 0 (- viewport (ebox--side-pixel box)))))

(defun ebox--fit-content-pixel (box limit)
  "Return BOX's fit-content width in content pixels.
LIMIT is already resolved to content pixels, or nil for stretch-fit."
  (let ((min-content (ebox--content-min-pixel box))
        (max-content (ebox--content-max-pixel box))
        (available (or limit
                       (ebox--stretch-content-pixel box)
                       (ebox--content-max-pixel box))))
    (max min-content
         (min max-content available))))

(defun ebox--definite-content-size-pixel (box value)
  "Resolve VALUE to BOX content pixels when it is independent of content.
Return nil for intrinsic sizes such as min-content and max-content."
  (cond
   ((null value) nil)
   ((ebox--viewport-size-value-p value)
    (when-let* ((viewport (ebox--viewport-pixel-width nil)))
      (ebox--box-sizing-content-pixel box viewport)))
   ((numberp value)
    (ebox--box-sizing-content-pixel box value))
   ((memq value '(stretch contain fit-content))
    (ebox--stretch-content-pixel box))
   ((and (consp value) (eq (car value) 'fit-content))
    (let ((limit (cadr value)))
      (cond
       ((ebox--viewport-size-value-p limit)
        (when-let* ((viewport (ebox--viewport-pixel-width nil)))
          (ebox--box-sizing-content-pixel box viewport)))
       ((numberp limit)
        (ebox--box-sizing-content-pixel box limit))
       (t nil))))
   (t nil)))

(defun ebox--wrapper-content-viewport-pixel (props)
  "Return PROPS' content viewport for rendering preformatted child layouts.
PROPS are already engine-normalized; do not pass them back through public
property parsers."
  (let* ((width-value (ebox-get props :width))
         (min-width (ebox--definite-content-size-pixel
                     props (ebox-get props :min-width)))
         (max-width (ebox--definite-content-size-pixel
                     props (ebox-get props :max-width)))
         (preferred-width
          (or (ebox--definite-content-size-pixel props width-value)
              (and (not ebox--inline-auto-width-intrinsic-p)
                   (or (null width-value)
                       (eq width-value 'auto)
                       (eq width-value 'fit-content))
                   (ebox--stretch-content-pixel props))
              max-width)))
    (when preferred-width
      (max (or min-width 0)
           (min (or max-width 999999999)
                (max 0 preferred-width))))))

(defun ebox--render-node-as-box-content (node props)
  "Render NODE as preformatted content for a box with PROPS.
When PROPS establish a content-box viewport, nested auto and `(viewport)'
widths resolve against that inner content box instead of the outer caller
viewport.  A max-content wrapper instead measures the composite NODE without
an inherited viewport."
  (let ((content-viewport (ebox--wrapper-content-viewport-pixel props)))
    (cond
     ((eq (ebox-get props :width) 'max-content)
      (let ((ebox-viewport-width nil)
            (ebox--intrinsic-layout-measurement t)
            (ebox--inline-auto-width-intrinsic-p nil))
        (ebox-render node)))
     (content-viewport
      (let ((ebox-viewport-width content-viewport)
            ;; A definite wrapper establishes a new containing block.  Its
            ;; child layout must resume normal cross-axis stretch semantics,
            ;; even when the wrapper itself is an item of an intrinsic row.
            (ebox--inline-auto-width-intrinsic-p nil))
        (if (and (hash-table-p ebox--render-cache-table)
                 (not ebox--intrinsic-layout-measurement)
                 (null ebox--render-region-id)
                 (fboundp 'ebox--render-cache-probe)
                 (fboundp 'ebox--render-with-cache))
            (ebox--render-with-cache
             node nil
             (ebox--render-cache-probe
              node nil
              (list :box-content t
                    :content-viewport content-viewport
                    :viewport-height ebox-viewport-height
                    :intrinsic ebox--intrinsic-layout-measurement
                    :auto-width-intrinsic
                    ebox--inline-auto-width-intrinsic-p
                    :render-region-id ebox--render-region-id
                    :scroll-lookahead
                    ebox--scroll-window-initial-lookahead-lines-override
                    :scroll-disabled ebox--scroll-window-render-disabled)))
          (ebox-render node))))
     (t
      (ebox-render node)))))

(defun ebox--resolve-size-content-pixel (box value fallback)
  "Resolve a horizontal size VALUE to BOX content pixels.
FALLBACK is used for nil and auto values."
  (cond
   ((null value) fallback)
   ((eq value 'viewport)
    (if-let* ((viewport (ebox--viewport-pixel-width nil)))
        (ebox--box-sizing-content-pixel box viewport)
      fallback))
   ((numberp value)
    (ebox--box-sizing-content-pixel box value))
   ((eq value 'auto) fallback)
   ((eq value 'none) nil)
   ((eq value 'min-content)
    (ebox--content-min-pixel box))
   ((eq value 'max-content)
    (ebox--content-max-pixel box))
   ((eq value 'fit-content)
    (ebox--fit-content-pixel box nil))
   ((memq value '(stretch contain))
    (or (ebox--stretch-content-pixel box) fallback))
   ((and (consp value) (eq (car value) 'fit-content))
    (ebox--fit-content-pixel
     box (ebox--resolve-size-content-pixel box (cadr value) nil)))
   (t
    (error "ebox: unsupported width value after expansion: %S" value))))

(defun ebox--content-pixel (box)
  "Calculate content pixel width, respecting box-sizing."
  (let* ((width-value (ebox-get box :width))
         ;; Intrinsic measurement is only a fallback for auto-like widths.
         ;; Definite and intrinsic keywords resolve themselves, so eagerly
         ;; measuring max-content here only repeats GUI pixel work without
         ;; affecting the used width.
         (preferred-width
          (cond
           ((or (null width-value) (eq width-value 'auto))
            (or (and (not ebox--inline-auto-width-intrinsic-p)
                     (ebox--stretch-content-pixel box))
                (ebox--content-max-pixel box)))
           ((or (eq width-value 'viewport)
                (memq width-value '(stretch contain)))
            (or (ebox--resolve-size-content-pixel box width-value nil)
                (ebox--content-max-pixel box)))
           (t
            (ebox--resolve-size-content-pixel box width-value nil))))
         (min-width (ebox--resolve-size-content-pixel
                     box (ebox-get box :min-width) 0))
         (max-width (ebox--resolve-size-content-pixel
                     box (ebox-get box :max-width) nil)))
    (max (or min-width 0)
         (min (or max-width 999999999)
              (max 0 preferred-width)))))

(defun ebox--content-height (box text-height)
  "Calculate content height, respecting box-sizing."
  (let* ((min-height (ebox--resolve-size-content-height
                      box (ebox-get box :min-height) 0))
         (max-height (ebox--resolve-size-content-height
                      box (ebox-get box :max-height) nil))
         (fixed-height (ebox--resolve-size-content-height
                        box (ebox-get box :height) nil))
         (raw-height (or fixed-height text-height)))
    (max 1 min-height
         (min (or max-height 999999999) raw-height))))

(defun ebox--format-content-string (box content)
  "Format BOX CONTENT (wrap and justify) returning a string."
  (let ((wrap-mode (ebox-get box :wrap-mode))
        (align (ebox-get box :text-align))
        (known-width
         (gethash content ebox--rendered-uniform-width-table)))
    (if (and (eq align 'left)
             (or (and (null wrap-mode)
                      (or (plist-get box :ebox-content-width-exact-p)
                          (and (numberp known-width)
                               (= known-width
                                  (ebox--content-pixel box)))))
                 (and (memq wrap-mode '(word char))
                      (numberp known-width)
                      (= known-width (ebox--content-pixel box)))))
        content
      (let* ((pixel-width (ebox--content-pixel box))
             (wrapped-content (ebox--wrap-text content pixel-width wrap-mode)))
        ;; kp mode distributes inner gaps, but Ebox still owns the box geometry.
        ;; Pad ragged lines (notably the last line) back to the content width
        ;; while preserving the requested alignment for those lines.
        (ebox--lines-justify wrapped-content pixel-width align)))))

(defun ebox--format-content (box)
  "Format BOX content (wrap and justify) returning a string."
  (or (ebox--format-scroll-window-content box)
      (ebox--format-content-string box (ebox--box-content box))))

(defun ebox--total-pixel (box)
  "Get the total pixel width of the BOX."
  (+ (ebox--content-pixel box) (ebox--side-pixel box)))

(defun ebox--total-height (box)
  "Get the total height of the BOX in lines."
  (let* ((formatted-content (ebox--format-content box))
         (text-height (ebox-string-height formatted-content)))
    (+ (ebox--content-height box text-height) (ebox--side-height box))))

(defun ebox--node-p (x)
  "Return non-nil if X is an ebox layout node."
  (and (listp x) (plist-member x :ebox-type)))

(defun ebox--render-box (box)
  "Render BOX to a string.
Internal implementation of `ebox-render' for box nodes."
  (or (ebox--render-transparent-preformatted-box box)
      (ebox--render-flat-preformatted-box box)
      (let* (;; Generate unique region ID for this box.
         ;; Priority:
         ;;   1. ebox--render-region-id — explicit single-box render override;
         ;;      never bind it across a recursive layout render
         ;;   2. :region-id cached on box plist — survives full-rerender so callers
         ;;      that stored the id after the first render can keep using it
         ;;   3. Fresh id stored back on box plist for all subsequent renders
         (region-id (or ebox--render-region-id
                        (ebox--ensure-region-id box)))

         ;; Format content first
         (ebox--scroll-window-render-result nil)
         (formatted-content (ebox--format-content box))
         (scroll-window-result ebox--scroll-window-render-result)
         (text-height (ebox-string-height formatted-content))

         ;; Calculate dimensions
         (content-pixel (ebox--content-pixel box))
         (content-height (or (plist-get scroll-window-result
                                        :content-height)
                             (ebox--content-height box text-height)))

         ;; overflow
         (overflow (ebox-get box :overflow))

         ;; Padding
         (padding-left (ebox-get box :padding-left-pixel))
         (padding-right (ebox-get box :padding-right-pixel))
         (padding-top (floor (ebox-get box :padding-top-height)))
         (padding-bottom (floor (ebox-get box :padding-bottom-height)))

         ;; Margin
         (margin-left (ebox-get box :margin-left-pixel))
         (margin-right (ebox-get box :margin-right-pixel))
         (margin-top (floor (ebox-get box :margin-top-height)))
         (margin-bottom (floor (ebox-get box :margin-bottom-height)))

         ;; Border Dimensions and Colors
         (border-left-pixel (ebox-get box :border-left-pixel))
         (border-left-color (ebox-get box :border-left-color))
         (border-right-pixel (ebox-get box :border-right-pixel))
         (border-right-color (ebox-get box :border-right-color))
         (border-top-p (ebox-get box :border-top-p))
         (border-top-color (ebox-get box :border-top-color))
         (border-bottom-p (ebox-get box :border-bottom-p))
         (border-bottom-color (ebox-get box :border-bottom-color))

         ;; Style and Layout
         (color (ebox-get box :color))
         (bgcolor (ebox-get box :bgcolor))
         (inner-height (+ content-height padding-top padding-bottom))
         (padding-line-filler (ebox-pixel-space content-pixel))

         (scroll-offset (or (ebox-get box :scroll-offset) 0))

         ;; Overflow handling
         (formatted-lines (ebox-string-lines formatted-content))
         (private-formatted-lines-p
          (not (and (eq overflow 'scroll)
                    (> text-height content-height))))
         (overflow-lines (when (and (eq overflow 'visible)
                                    (> text-height content-height))
                           (seq-drop formatted-lines content-height)))

         ;; For scroll mode, take lines starting from scroll-offset
         (visible-start
          (if (eq overflow 'scroll)
              (max 0
                   (min scroll-offset
                        (max 0 (- text-height content-height))))
            0))
         (visible-end
          (min (+ visible-start content-height) text-height))
         (visible-lines
          (if (eq overflow 'scroll)
              (seq-subseq formatted-lines visible-start visible-end)
            (seq-take formatted-lines content-height)))

         (underfilled-simple-scroll-lines
          (when (and (eq overflow 'scroll)
                     (or (null scroll-window-result)
                         (plist-get scroll-window-result :complete))
                     (< text-height content-height)
                     (= padding-left 0)
                     (= padding-right 0)
                     (= padding-top 0)
                     (= padding-bottom 0)
                     (= margin-left 0)
                     (= margin-right 0)
                     (= margin-top 0)
                     (= margin-bottom 0)
                     (= border-left-pixel 0)
                     (= border-right-pixel 0)
                     (not border-top-p)
                     (not border-bottom-p)
                     (eq (ebox-get box :vertical-align) 'top))
            (ebox--render-underfilled-simple-scroll-lines
             formatted-lines region-id content-height padding-line-filler
             color bgcolor)))

         (scroll-rendered-lines
          (when (and (eq overflow 'scroll)
                     (>= text-height content-height)
                     (= padding-left 0)
                     (= padding-right 0)
                     (= margin-left 0)
                     (= margin-right 0)
                     (= margin-top 0)
                     (= margin-bottom 0)
                     (= border-left-pixel 0)
                     (= border-right-pixel 0)
                     (eq (ebox-get box :vertical-align) 'top))
            (if (plist-get scroll-window-result
                           :cached-rendered-lines-p)
                ;; The staged producer already applied content/owner
                ;; properties.  Re-running the generic ownership pass here
                ;; was the dominant grid-scroll stall.
                formatted-lines
              (let ((ebox--scroll-rendered-content-lines-private-p
                     private-formatted-lines-p))
                (ebox--scroll-rendered-content-lines
                 box formatted-lines region-id 0)))))

         (simple-scroll-rendered-lines
          (or underfilled-simple-scroll-lines
              (and scroll-rendered-lines
                   (= padding-top 0)
                   (= padding-bottom 0)
                   (not border-top-p)
                   (not border-bottom-p)
                   scroll-rendered-lines)))

         ;; The main content block - 给每行添加 ebox-content 属性用于增量更新
         ;; 注意：空字符串无法承载 text-property，需先替换为有宽度的空白
         (result
          (cond
           (underfilled-simple-scroll-lines
            (ebox-lines-join underfilled-simple-scroll-lines))
           (simple-scroll-rendered-lines
            (ebox-lines-join
             (seq-subseq simple-scroll-rendered-lines
                         visible-start visible-end)))
           (t
            (let ((ebox--propertize-private-content-line-p
                   private-formatted-lines-p))
              (ebox-lines-join
               (cl-loop for line in visible-lines
                        for idx from 0
                        collect (ebox--propertize-content-line
                                 line region-id idx
                                 padding-line-filler))))))))

    ;; Rendering is the first point where the complete formatted height is
    ;; known.  Keep the host box and published scroll state on the same
    ;; canonical offset after data shrinkage (including underfill), otherwise
    ;; a later growth can resurrect an invisible stale position.
    (when (eq overflow 'scroll)
      (setq scroll-offset visible-start)
      ;; Intrinsic measurement renders live runtime subtrees against
      ;; placeholder content whose visible-start is always 0; writing
      ;; that back would reset the user's real scroll offset.
      (unless ebox--intrinsic-layout-measurement
        (plist-put box :scroll-offset visible-start)))

    ;; 1. Vertical Alignment of content within the box height.  Reused scroll
    ;; lines already fill a top-aligned, chrome-free viewport.
    (unless simple-scroll-rendered-lines
      (setq result (ebox--lines-align-vertical
                    result content-height
                    (ebox-get box :vertical-align))))

    ;; Fill any empty lines generated by alignment with correct width spaces
    ;; 保留原有的 ebox-content/ebox-content-idx 属性
    (unless simple-scroll-rendered-lines
      (setq result
            (ebox--maplines
             (lambda (line)
               (if (and (string-empty-p (string-trim line))
                        (not (ebox--line-has-non-content-properties-p line)))
                   (let ((content-id (get-text-property 0 'ebox-content line))
                         (content-idx
                          (get-text-property 0 'ebox-content-idx line)))
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
             result)))

    ;; 2. Vertical Padding (Top/Bottom) - 添加区域标记
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

    ;; 3. Horizontal Padding (Left/Right)
    (let* ((pl-str (when (> padding-left 0)
                     (ebox--propertize-region
                      (ebox--pixel-blank padding-left inner-height)
                      'ebox-pl region-id)))
           (pr-str (when (> padding-right 0)
                     (ebox--propertize-region
                      (ebox--pixel-blank padding-right inner-height)
                      'ebox-pr region-id))))
      ;; Cache box definition for dynamic content updates
      (puthash region-id box ebox--region-box-table)
      ;; Cache scroll state only when the box can actually move.  Most boxes
      ;; use scroll overflow by default but have no hidden lines; keeping them
      ;; out of the global scroll table keeps wheel hit-testing cheap.
      ;; Intrinsic measurement must leave published scroll state alone: its
      ;; placeholder content always looks fully visible and would clear the
      ;; live lazy producer state.
      (unless (or ebox--intrinsic-layout-measurement
                  ebox--scroll-window-skip-state-rebuild-p)
        (if (and (eq overflow 'scroll)
                 (> text-height content-height))
            (ebox--scroll-set-state
             region-id
             (append
              (list :scroll-offset scroll-offset
                    :content-lines formatted-lines
                    :content-height content-height
                    :rendered-content-lines scroll-rendered-lines
                    :box box)
              (when scroll-window-result
                (list :content-lines-complete-p
                      (plist-get scroll-window-result :complete)
                      :scroll-window-producer-spec
                      (plist-get scroll-window-result
                                 :scroll-window-producer-spec)
                      :render-content-prefix
                      (plist-get scroll-window-result
                                 :render-content-prefix)
                      :materialize-content-lines
                      (plist-get scroll-window-result
                                 :materialize-content-lines)))))
          (ebox--scroll-clear-state region-id)))
      (when (or pl-str pr-str)
        (setq result
              (ebox--lines-concat-horizontal pl-str result pr-str))))

    ;; 4. Foreground and Background Color
    (when (and (or color bgcolor)
               (not simple-scroll-rendered-lines))
      (setq result
            (ebox--maplines
             (lambda (line)
               (ebox--propertize-colors line color bgcolor))
             result)))

    ;; 5. Left/Right Border - 添加区域标记
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
        (setq result
              (ebox--lines-concat-horizontal
               bl-str result br-str))))

    ;; 6. Top/Bottom Border (implemented as overline/underline) - 添加区域标记
    ;;
    ;; Apply horizontal borders after horizontal padding and side borders are
    ;; assembled, so the overline/underline spans the same full outer line that
    ;; owns the left/right border display spaces.  This keeps corners visually
    ;; connected when text-scale changes line metrics.
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
                 (ebox--propertize-underline (car (last lines)) border-bottom-color)
                 'ebox-bb region-id)))
        (setq result (ebox-lines-join lines))))

    ;; The host interaction surface is the border box.  Apply it after all
    ;; content, padding, and border characters exist, but before margins and
    ;; visible overflow are appended.  Nested text properties retain priority.
    (ebox--apply-surface-properties
     result (ebox-get box :surface-properties))

    ;; 7. Left/Right Margin - 添加区域标记
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
        (setq result
              (ebox--lines-concat-horizontal
               ml-str result mr-str))))

    ;; 8. Top/Bottom Margin - 添加区域标记
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

    ;; 8. Overflow Content (Rendered outside the box if visible)
    (when overflow-lines
      (let* ((left-space (+ margin-left border-left-pixel padding-left))
             (right-space (+ padding-right border-right-pixel margin-right))
             (overflow-left-pad (ebox-pixel-space left-space))
             (overflow-right-pad (ebox-pixel-space right-space))
             (overflow-text
              (mapconcat
               (lambda (line)
                 (let ((line (if color
                                 (ebox--propertize-color line color)
                               (copy-sequence line))))
                   (when (> (length line) 0)
                     (put-text-property
                      0 (length line) 'ebox-overflow-foreground-source
                      region-id line))
                   (concat overflow-left-pad line overflow-right-pad)))
               overflow-lines
               "\n")))
        (setq result (concat result "\n" overflow-text))))
    (when (and (eq overflow 'scroll)
               (> text-height content-height))
      (add-text-properties 0 (length result)
                           (list 'ebox-scroll-window region-id)
                           result))
    ;; Visibility suppresses every drop of the box's ink (content,
    ;; colors, borders, visible-overflow spill) while margins remain
    ;; the same blanks and all metadata properties survive verbatim.
    (when (eq (ebox-get box :visibility) 'hidden)
      (setq result (ebox--apply-hidden-visibility result)))
        result)))

(defvar ebox--surface-materialization-active nil
  "Non-nil while an Ebox TP producer is running raw layout.")

(defun ebox--render-layout (node)
  "Render layout NODE directly to a multi-line propertized string.
NODE can be:
  - a box plist created by `ebox-create'
  - a concat node created by `ebox-concat'
  - a stack node created by `ebox-stack'
  - a flex node created by `ebox-flex'
This function owns spatial layout only; it never creates a live TP surface."
  (ebox--with-validated-display-cache
    (let ((ebox--box-content-render-cache
           (or ebox--box-content-render-cache
               (make-hash-table :test 'eq))))
      (when (listp node)
        (ebox--ensure-node-id node))
      (let ((type (plist-get node :ebox-type)))
        (cond
         ((eq type 'box)    (ebox--render-box node))
         ((eq type 'concat) (ebox--render-concat node))
         ((eq type 'stack)  (ebox--render-stack node))
         ((eq type 'flex)   (ebox--render-flex node))
         ((eq type 'grid)   (ebox--render-grid node))
         ((eq type 'flex-item) (ebox--render-layout (plist-get node :node)))
         (t (error "ebox-render: unknown node type %S" type)))))))

(declare-function ebox-surface-producer
                  "ebox-surface"
                  (source &optional previous-state preserve-identities-p
                          state-overrides signals projection-kind
                          source-isolated-p source-path-copied-p))
(declare-function tp-surface-materialize-string "tp-surface" (plan-or-producer))

(defun ebox--render-ephemeral-static (node)
  "Render static NODE without constructing a TP object tree.
The source remains caller-owned; the candidate copy carries all ephemeral
region/node identities and render side tables for this one materialization."
  (let ((candidate (ebox-surface--candidate-root node t)))
    (let ((ebox--surface-materialization-active t)
          (ebox--region-box-table (make-hash-table :test 'equal))
          (ebox--scroll-global-state (make-hash-table :test 'equal))
          (ebox--scroll-idle-prefetch-timers (make-hash-table :test 'equal))
          (ebox--smooth-scroll-state-table (make-hash-table :test 'equal))
          (ebox--render-cache-table (make-hash-table :test 'equal))
          (ebox--render-cache-signature-cache (make-hash-table :test 'eq))
          (ebox--box-content-render-cache (make-hash-table :test 'eq))
          (ebox--viewport-dependent-node-ids-cache
           (make-hash-table :test 'eq))
          (ebox--viewport-dependent-subtree-cache
           (make-hash-table :test 'eq))
          (ebox--viewport-height-dependent-subtree-cache
           (make-hash-table :test 'eq))
          (ebox--flex-content-min-width-table (make-hash-table :test 'eq))
          (ebox--render-runtime-revision nil)
          (ebox--render-cache-allow-viewport-dependent nil)
          (ebox--render-cache-scroll-state-region-ids nil)
          (ebox--render-cache-scroll-state-restorable-p nil)
          (ebox--render-cache-scroll-state-retained-cost-cache nil))
      (ebox--render-layout candidate))))

;;;###autoload
(defun ebox-render (node)
  "Render layout NODE to a multi-line string through a TP materialization.
NODE accepts every layout node supported by `ebox--render-layout'.  The
materialized surface is ephemeral and creates no live buffer state."
  (let ((rendered
         (if (or ebox--surface-materialization-active
                 ebox--render-runtime-revision)
             (ebox--render-layout node)
           (require 'ebox-surface)
           (if (and (not (stringp node))
                    (not (ebox-style-cascade-active-p))
                    (not (ebox-surface--inline-inheritance-required-p node)))
               (let ((ebox--region-id-counter ebox--region-id-counter)
                     (ebox--runtime-node-id-counter ebox--runtime-node-id-counter))
                 (ebox--render-ephemeral-static node))
             (let ((ebox--surface-materialization-active t)
                   (ebox--region-id-counter ebox--region-id-counter)
                   (ebox--runtime-node-id-counter ebox--runtime-node-id-counter))
               (tp-surface-materialize-string
                (ebox-surface-producer node nil t)))))))
    (unless ebox--paint-origin-capture-p
      (ebox--strip-paint-origins! rendered))
    rendered))

(defun ebox--width-pad (string extra-pixels)
  "Append a display-space of EXTRA-PIXELS to the right of every line in STRING.
Used by `ebox--render-stack' to equalise rows to the same total width."
  (if (<= extra-pixels 0)
      string
    (let* ((display
            (ebox--register-render-owned-text-value
             'display `(space :width (,extra-pixels))))
           (pad (propertize " " 'display display)))
      (ebox--maplines (lambda (line) (concat line pad)) string))))

(defun ebox--height-pad (string target-height)
  "Pad STRING to TARGET-HEIGHT lines, appending blank pixel-wide lines.
The blank lines match the pixel width of the first line of STRING."
  (let* ((lines (ebox-string-lines string))
         (current-h (length lines))
         (extra (- target-height current-h)))
    (if (<= extra 0)
        string
      (let* ((px (ebox--string-pixel-width string))
             (blank (ebox-pixel-space px)))
        (ebox-lines-join (append lines (make-list extra blank)))))))

;;;###autoload
(defun ebox-concat (node1 node2)
  "Return a lazy concat node that places NODE1 and NODE2 side by side.
NODE1 and NODE2 must be box/concat/stack nodes created by
`ebox-create', `ebox-concat', or `ebox-stack'.
The result is not rendered until `ebox-render' or `ebox-render-to-buffer'
is called.  To compose more than two boxes, nest calls:
  (ebox-concat a (ebox-concat b c))"
  (list :ebox-type 'concat
        :display '(block row)
        :children (delq nil (list node1 node2))
        :left node1
        :right node2))

;;;###autoload
(defun ebox-spacer (&rest plist)
  "Return a blank box node.
PLIST accepts the same properties as `ebox-create', such as :width,
:height, :margin, or :bgcolor."
  (apply #'ebox-create :content "" plist))

;;;###autoload
(defun ebox-row (&rest nodes)
  "Return a lazy horizontal layout node from NODES.
Nil entries are ignored.  With zero non-nil nodes, return `ebox-spacer'.
A sole child Range keeps a material row parent so the Range stays addressable."
  (setq nodes (delq nil nodes))
  (cond
   ((null nodes) (ebox-spacer))
   ((and (null (cdr nodes))
         (not (ebox-child-range--descriptor-p (car nodes))))
    (car nodes))
   (t (list :ebox-type 'concat
            :display '(block row)
            :children nodes))))

(defun ebox--render-concat (node)
  "Render a concat NODE to a string (internal, called by `ebox-render').
Auto-width children are rendered at intrinsic inline size while explicit
viewport/definite widths keep their containing-block semantics.  Shorter
children are padded with blank lines so all reach the same height before
horizontal concatenation."
  (let* ((rendered
          (mapcar (lambda (child)
                    ;; A row owns the horizontal concatenation.  Its auto
                    ;; width children must therefore measure intrinsically;
                    ;; explicit viewport/stretch widths still resolve against
                    ;; the ambient containing block.
                    (let ((ebox--inline-auto-width-intrinsic-p t))
                      (ebox--render-with-cache child)))
                  (ebox--layout-children node)))
         (max-h (if rendered
                    (apply #'max (mapcar #'ebox-string-height rendered))
                  0))
         (line-lists
          (mapcar (lambda (string)
                    (ebox-string-lines
                     (ebox--height-pad string max-h)))
                  rendered)))
    (if line-lists
        (ebox-lines-join (apply #'cl-mapcar #'concat line-lists))
      "")))

;;;###autoload
(defun ebox-stack (node1 node2)
  "Return a lazy stack node that places NODE1 above NODE2 vertically.
NODE1 and NODE2 must be box/concat/stack nodes created by
`ebox-create', `ebox-concat', or `ebox-stack'.
The result is not rendered until `ebox-render' or `ebox-render-to-buffer'
is called.  To stack more than two boxes, nest calls:
  (ebox-stack a (ebox-stack b c))"
  (list :ebox-type 'stack
        :display '(block column)
        :children (delq nil (list node1 node2))
        :top node1
        :bottom node2))

;;;###autoload
(defun ebox-column (&rest nodes)
  "Return a lazy vertical layout node from NODES.
Nil entries are ignored.  With zero non-nil nodes, return `ebox-spacer'.
A sole child Range keeps a material column parent so the Range stays
addressable."
  (setq nodes (delq nil nodes))
  (cond
   ((null nodes) (ebox-spacer))
   ((and (null (cdr nodes))
         (not (ebox-child-range--descriptor-p (car nodes))))
    (car nodes))
   (t (list :ebox-type 'stack
            :display '(block column)
            :children nodes))))

(defun ebox--stack-leaves (node)
  "Return NODE's vertical stack leaves in render order."
  (let (leaves)
    (cl-labels ((collect (current)
                  (if (and (listp current)
                           (eq (plist-get current :ebox-type) 'stack))
                      (dolist (child (ebox--layout-children current))
                        (collect child))
                    (push current leaves))))
      (collect node))
    (nreverse leaves)))

(defun ebox--render-stack-window-leaf-lines (leaf limit target-width)
  "Render LEAF up to LIMIT lines for a stack scroll window.
TARGET-WIDTH is the containing block width used to pad narrower leaves."
  (if (ebox--prewarm-node-window-line leaf target-width)
      (list :lines nil :line-count 0 :line-tail nil :complete nil)
    (let* ((window (ebox--render-node-window-lines leaf limit))
         (window-lines (plist-get window :lines))
         (rendered (unless window
                     (ebox--render-with-cache leaf)))
         (width (cond
                 ((plist-member window :pixel-width)
                  (plist-get window :pixel-width))
                 ((and window (> target-width 0))
                  target-width)
                 ((eq (and (listp leaf) (plist-get leaf :ebox-type))
                      'box)
                  (ebox--total-pixel leaf))
                 (t
                  (ebox--string-pixel-width rendered))))
         (needs-padding (and (> target-width 0) (< width target-width)))
         (lines
          (cond
           ((and window (not needs-padding))
            window-lines)
           (window
            (ebox-string-lines
             (ebox--width-pad
              (ebox-lines-join window-lines)
              (- target-width width))))
           (needs-padding
            (ebox-string-lines
             (ebox--width-pad rendered (- target-width width))))
           (t
            (ebox-string-lines rendered)))))
    (list :lines lines
          :line-count (or (and window (not needs-padding)
                               (plist-get window :line-count))
                          (length lines))
          :line-tail (or (and window (not needs-padding)
                              (plist-get window :line-tail))
                         (last lines))
          :complete (if window
                        (plist-get window :complete)
                      t)
          :prefix-delta
          (and window (not needs-padding)
               (plist-get window :prefix-delta))
          :completion-prefix-tail-rewrite-count
          (and window
               (plist-get
                window :completion-prefix-tail-rewrite-count))
          :completion-prefix-tail-rewrite-known-p
          (and window
               (plist-member
                window :completion-prefix-tail-rewrite-count))))))

(defun ebox--stack-window-cache-compatible-p
    (cache node target-width)
  "Return non-nil when CACHE can extend NODE at TARGET-WIDTH."
  (and cache
       (eq (plist-get cache :node) node)
       (equal (plist-get cache :target-width) target-width)))

(defun ebox--stack-window-cache-put
    (node target-width leaves lines line-count line-tail index pending
          partial-index partial-count complete)
  "Return a stack scroll-window cache plist."
  (list :node node
        :target-width target-width
        :leaves leaves
        :lines lines
        :line-count line-count
        :line-tail line-tail
        :index index
        :pending-lines pending
        :partial-index partial-index
        :partial-count partial-count
        :complete complete))

(defun ebox--line-list-append! (lines tail new-lines)
  "Append NEW-LINES to LINES through TAIL and return (LINES TAIL).
The existing prefix cons cells stay stable so lazy consumers can retain a
cursor at their published boundary."
  (if (null new-lines)
      (list lines tail)
    (let ((new-tail (last new-lines)))
      (if tail
          (setcdr tail new-lines)
        (setq lines new-lines))
      (list lines new-tail))))

(defun ebox--line-list-rewrite! (lines start replacement)
  "Replace LINES at zero-based START with equal-length REPLACEMENT in place."
  (let ((cursor (nthcdr start lines)))
    (dolist (line replacement)
      (unless cursor
        (error "Prefix rewrite exceeds cached line list"))
      (setcar cursor line)
      (setq cursor (cdr cursor))))
  lines)

(defun ebox--line-list-rewrite-range!
    (lines line-count tail range replacement)
  "Apply equal-length REPLACEMENT to RANGE in LINES.
The common one-line tail completion uses TAIL directly; other ranges retain a
conservative indexed fallback."
  (unless (= (length replacement) (- (cdr range) (car range)))
    (error "Prefix rewrite payload does not match its range"))
  (if (and (= (length replacement) 1)
           (= (car range) (1- line-count))
           (= (cdr range) line-count)
           tail)
      (setcar tail (car replacement))
    (ebox--line-list-rewrite! lines (car range) replacement))
  lines)

(defun ebox--prefix-delta-valid-p (delta base-count line-count)
  "Return non-nil when DELTA exactly extends BASE-COUNT to LINE-COUNT.
DELTA uses zero-based, half-open line coordinates.  Its optional rewrite
range must stay inside the reused prefix; lines after BASE-COUNT are append
only."
  (and (plist-get delta :exact-p)
       (integerp (plist-get delta :base-count))
       (= (plist-get delta :base-count) base-count)
       (<= 0 base-count line-count)
       (let ((range (plist-get delta :rewrite-range)))
         (or (null range)
             (and (consp range)
                  (integerp (car range))
                  (integerp (cdr range))
                  (<= 0 (car range))
                  (< (car range) (cdr range))
                  (<= (cdr range) base-count))))))

(defun ebox--prefix-delta-project
    (delta base-count full-line-count line-count)
  "Project exact DELTA onto an exposed BASE-COUNT line prefix.
FULL-LINE-COUNT is the complete line list described by DELTA, while LINE-COUNT
is the newly exposed prefix length.  Lazy sources may cache extra wrapper
chrome or prefetched lines beyond the prefix published to scroll state."
  (let* ((delta-base (plist-get delta :base-count))
         (range (plist-get delta :rewrite-range))
         (projected-range
          (and range
               (< (car range) base-count)
               (cons (car range)
                     (min (cdr range) base-count)))))
    (when (and (integerp delta-base)
               (ebox--prefix-delta-payload-valid-p
                delta delta-base full-line-count)
               (<= 0 base-count delta-base)
               (<= base-count line-count full-line-count))
      (list :exact-p t
            :base-count base-count
            :rewrite-range projected-range
            :rewrite-lines
            (and projected-range
                 (seq-take
                  (plist-get delta :rewrite-lines)
                  (- (cdr projected-range)
                     (car projected-range))))))))

(defun ebox--prefix-delta-payload-valid-p (delta base-count line-count)
  "Return non-nil when DELTA has exact rewrite and append payloads."
  (and (ebox--prefix-delta-valid-p delta base-count line-count)
       (let ((range (plist-get delta :rewrite-range))
             (rewrite-lines (plist-get delta :rewrite-lines))
             (append-lines (plist-get delta :append-lines)))
         (and (= (length rewrite-lines)
                 (if range (- (cdr range) (car range)) 0))
              (= (length append-lines)
                 (- line-count base-count))))))

(defun ebox--render-stack-window-lines (node limit &optional cache)
  "Render stack NODE until LIMIT content lines are available.
Return a plist with :lines and :complete.  This mirrors the normal stack
renderer for the top window of a scroll container, but stops before hidden
leaves are rendered.  When CACHE is supplied, rendering continues from the
last cached leaf instead of walking the stack from the beginning."
  (let* ((target-w (if ebox--inline-auto-width-intrinsic-p
                       0
                     (or (ebox--viewport-pixel-width nil) 0)))
         (cached (and (ebox--stack-window-cache-compatible-p
                       cache node target-w)
                      cache))
         (leaves (or (plist-get cached :leaves)
                     (ebox--stack-leaves node)))
         (lines (plist-get cached :lines))
         (count (or (plist-get cached :line-count)
                    (length lines)))
         (line-tail (or (plist-get cached :line-tail)
                        (last lines)))
         (index (or (plist-get cached :index) 0))
         (pending (copy-sequence (plist-get cached :pending-lines)))
         (partial-index (plist-get cached :partial-index))
         (partial-count (or (plist-get cached :partial-count) 0))
         (complete (plist-get cached :complete))
         (base-count count)
         (delta-exact-p (and cached (>= limit base-count)))
         invalid-prefix-cache-p
         rewrite-range
         rewrite-lines
         appended-lines
         appended-tail
         (ebox--render-cache-allow-viewport-dependent t))
    (unless (and cached complete)
      (setq complete nil)
      (catch 'limit
        (while (< count limit)
          (cond
           (pending
            (let* ((need (- limit count))
                   (chunk (seq-take pending need)))
              (pcase-let ((`(,new-lines ,new-tail)
                           (ebox--line-list-append!
                            appended-lines appended-tail
                            (copy-sequence chunk))))
                (setq appended-lines new-lines
                      appended-tail new-tail))
              (setq count (+ count (length chunk)))
              (setq pending (nthcdr (length chunk) pending))
              (when pending
                (throw 'limit nil))))
           ((>= index (length leaves))
            (setq complete t)
            (throw 'limit nil))
           (t
            (let* ((leaf (nth index leaves))
                   (need (max 1 (- limit count)))
                   (leaf-limit (if (equal partial-index index)
                                   (+ partial-count need)
                                 need))
                   (window
                    (ebox--render-stack-window-leaf-lines
                     leaf leaf-limit target-w))
                   (leaf-lines (plist-get window :lines))
                   (leaf-count (or (plist-get window :line-count)
                                   (length leaf-lines)))
                   (leaf-complete (plist-get window :complete))
                   (leaf-delta (plist-get window :prefix-delta))
                   (leaf-prefix-exact-p
                    (and (equal partial-index index)
                         (ebox--prefix-delta-payload-valid-p
                          leaf-delta partial-count leaf-count)))
                   (completion-tail-rewrite-metadata
                    (plist-get
                     window :completion-prefix-tail-rewrite-count))
                   (completion-tail-rewrite-known-p
                    (plist-get
                     window :completion-prefix-tail-rewrite-known-p))
                   (completion-tail-rewrite-metadata-valid-p
                    (and
                     completion-tail-rewrite-known-p
                     (or (null completion-tail-rewrite-metadata)
                         (and (integerp
                               completion-tail-rewrite-metadata)
                              (>= completion-tail-rewrite-metadata 0)))))
                   (completion-tail-rewrite-count
                    (if completion-tail-rewrite-metadata-valid-p
                        (or completion-tail-rewrite-metadata 0)
                      0))
                   (completion-tail-rewrite-leaf-range
                    (and (> completion-tail-rewrite-count 0)
                         (>= partial-count
                             completion-tail-rewrite-count)
                         (cons
                          (- partial-count
                             completion-tail-rewrite-count)
                          partial-count)))
                   (completion-tail-rewrite-from-delta-p
                    (and leaf-prefix-exact-p
                         (equal
                          (plist-get leaf-delta :rewrite-range)
                          completion-tail-rewrite-leaf-range)))
                   (new-lines
                    (cond
                     (leaf-prefix-exact-p
                      (plist-get leaf-delta :append-lines))
                     ((equal partial-index index)
                      (nthcdr partial-count leaf-lines))
                     (t leaf-lines)))
                   (chunk (seq-take new-lines need))
                   (chunk-count (length chunk)))
              ;; A producer may explicitly declare completion-only rewrites
              ;; to the tail already stored for a partial leaf.  Flex uses one
              ;; line for a wrapper's bottom border.  The partial leaf is
              ;; always the cache tail, so reconcile only that declared suffix
              ;; before appending any newly produced lines.
              (when (and (equal partial-index index)
                         (> partial-count 0)
                         leaf-complete
                         (or (not
                              completion-tail-rewrite-metadata-valid-p)
                             (> completion-tail-rewrite-count 0)))
                (if (and completion-tail-rewrite-metadata-valid-p
                         (> partial-count 0)
                         (>= leaf-count partial-count)
                         (>= count completion-tail-rewrite-count)
                         (>= partial-count completion-tail-rewrite-count))
                    (progn
                      (if rewrite-range
                          (setq delta-exact-p nil)
                        (setq rewrite-range
                              (cons
                               (- count completion-tail-rewrite-count)
                               count)))
                      (setq rewrite-lines
                            (if completion-tail-rewrite-from-delta-p
                                (plist-get leaf-delta :rewrite-lines)
                              (seq-subseq
                               leaf-lines
                               (- partial-count
                                  completion-tail-rewrite-count)
                               partial-count))))
                  ;; A producer that declares an impossible rewrite cannot
                  ;; safely reuse any cached prefix: the cached strings may
                  ;; already be stale even if downstream consumers rebuild.
                  (setq invalid-prefix-cache-p t)
                  (throw 'limit nil)))
              (pcase-let ((`(,new-lines ,new-tail)
                           (ebox--line-list-append!
                            appended-lines appended-tail
                            (copy-sequence chunk))))
                (setq appended-lines new-lines
                      appended-tail new-tail))
              (setq count (+ count chunk-count))
              (cond
               ((and leaf-complete
                     (<= (length new-lines) need))
                (setq index (1+ index))
                (setq partial-index nil)
                (setq partial-count 0)
                (when (> (length new-lines) chunk-count)
                  (setq pending (nthcdr chunk-count new-lines))
                  (throw 'limit nil)))
               (leaf-complete
                (setq index (1+ index))
                (setq partial-index nil)
                (setq partial-count 0)
                (setq pending (nthcdr chunk-count new-lines))
                (throw 'limit nil))
               (t
                (setq partial-index index)
                (setq partial-count (+ partial-count chunk-count))
                (throw 'limit nil)))))))))
    (if invalid-prefix-cache-p
        (ebox--render-stack-window-lines node limit nil)
      (let ((inhibit-quit t))
        (when rewrite-range
          (ebox--line-list-rewrite-range!
           lines base-count line-tail rewrite-range rewrite-lines))
        (pcase-let ((`(,new-lines ,new-tail)
                     (ebox--line-list-append!
                      lines line-tail appended-lines)))
          (setq lines new-lines
                line-tail new-tail)))
      (let* ((result-lines (if (<= count limit)
                               lines
                             (seq-take lines limit)))
             (result-count (min count limit))
             (cache
              (ebox--stack-window-cache-put
               node target-w leaves lines count line-tail index pending
               partial-index partial-count complete)))
        (list :lines result-lines
              :line-count result-count
              :line-tail (if (= result-count count)
                             line-tail
                           (last result-lines))
              :complete complete
              :cache cache
              :prefix-delta
              (list :exact-p
                    (and delta-exact-p
                         (<= base-count result-count))
                    :base-count base-count
                    :rewrite-range rewrite-range
                    :rewrite-lines rewrite-lines
                    :append-lines appended-lines))))))

(defun ebox--scroll-window-content-height (box)
  "Return BOX's definite scroll content height, or nil."
  (when-let* ((fixed-height
              (ebox--resolve-size-content-height
               box (ebox-get box :height) nil)))
    (ebox--content-height box fixed-height)))

(defun ebox--scroll-window-materializer
    (box viewport-width viewport-height)
  "Return a function that materializes BOX scroll content."
  (lambda (&rest _)
    (let ((ebox-viewport-width viewport-width)
          (ebox-viewport-height viewport-height)
          (ebox--scroll-window-render-disabled t)
          (ebox--scroll-window-render-result nil))
      (let* ((full (ebox--format-content box))
             (lines (ebox-string-lines full)))
        (list :content-lines lines
              :content-height (ebox--content-height box (length lines))
              :box box)))))

(defun ebox--scroll-window-producer-spec
    (prefix-viewport-width materialize-viewport-width viewport-height)
  "Return portable dimensions for one lazy scroll producer pair."
  (list :prefix-viewport-width prefix-viewport-width
        :materialize-viewport-width materialize-viewport-width
        :viewport-height viewport-height))

(defun ebox--scroll-window-prefix-renderer
    (box source viewport-width viewport-height
         &optional initial-source-cache initial-content-lines)
  "Return a function that renders BOX scroll content up to a line limit."
  (let* ((source-cache initial-source-cache)
         (content-lines-cache initial-content-lines)
         (content-lines-count (length initial-content-lines))
         (content-lines-tail (last initial-content-lines))
         (source-lines-head
          (plist-get initial-source-cache :rendered-lines))
         (source-lines-boundary-tail
          (and (> content-lines-count 0)
               (nthcdr (1- content-lines-count) source-lines-head)))
         (rendered-content-lines-cache nil)
         (rendered-content-lines-count 0)
         (rendered-content-lines-tail nil)
         (signature-cache (make-hash-table :test 'eq))
         ;; The lazy prefix belongs to one validated display signature.  Keep
         ;; its render-local measurement caches across idle slices so repeated
         ;; card chrome and labels are not sent back through GUI font
         ;; measurement on every callback.
         (pixel-width-cache
          (or ebox--render-string-pixel-width-cache
              (make-hash-table :test 'equal)))
         (max-pixel-width-cache
          (or ebox--render-string-max-pixel-width-cache
              (make-hash-table :test 'eq)))
         (recached-source-node-cache
          (or ebox--render-recached-source-node-cache
              (make-hash-table :test 'eq)))
         (prewarm-state (make-hash-table :test 'eq))
         (source-revision ebox--render-runtime-revision)
         (complete-cache nil))
    (lambda (state region-id limit)
      (let ((prefix-dirty
             (or (plist-get state :lazy-scroll-prefix-dirty)
                 (not (equal source-revision
                             ebox--render-runtime-revision)))))
        (when prefix-dirty
          (setq source-cache nil)
          (setq content-lines-cache nil)
          (setq content-lines-count 0)
          (setq content-lines-tail nil)
          (setq source-lines-head nil)
          (setq source-lines-boundary-tail nil)
          (setq rendered-content-lines-cache nil)
          (setq rendered-content-lines-count 0)
          (setq rendered-content-lines-tail nil)
          (setq signature-cache (make-hash-table :test 'eq))
          (clrhash pixel-width-cache)
          (clrhash max-pixel-width-cache)
          (clrhash recached-source-node-cache)
          (clrhash prewarm-state)
          (setq complete-cache nil)
          (setq source-revision ebox--render-runtime-revision))
        (let ((ebox-viewport-width viewport-width)
              (ebox-viewport-height viewport-height)
              (ebox--render-cache-signature-cache signature-cache)
              (ebox--render-string-pixel-width-cache pixel-width-cache)
              (ebox--render-string-max-pixel-width-cache
               max-pixel-width-cache)
              (ebox--render-recached-source-node-cache
               recached-source-node-cache)
              (ebox--surface-materialization-active t)
              (ebox--scroll-window-prewarm-state prewarm-state)
              (ebox--scroll-window-render-disabled t)
              (ebox--scroll-window-render-result nil))
          (unless rendered-content-lines-cache
            (unless prefix-dirty
              (setq rendered-content-lines-cache
                    (plist-get state :rendered-content-lines))
              (setq rendered-content-lines-count
                    (length rendered-content-lines-cache))
              (setq rendered-content-lines-tail
                    (last rendered-content-lines-cache))))
          (let* ((limit (max 1 limit))
                 (content-height (ebox--scroll-window-content-height box))
                 (old-count content-lines-count)
                 (cached-hit
                  (and content-lines-cache
                       (or complete-cache
                           (>= content-lines-count limit)))))
            ;; The producer may have returned a bounded private chunk beyond
            ;; the published scroll state.  Paint that small suffix before a
            ;; source extension so the exact delta can append instead of
            ;; rebuilding every rendered line from zero.
            (when (and (not cached-hit)
                       rendered-content-lines-cache
                       (< rendered-content-lines-count content-lines-count))
              (pcase-let
                  ((`(,lines ,count ,tail)
                    (ebox--scroll-rendered-prefix-through-content
                     box content-lines-cache content-lines-count region-id
                     rendered-content-lines-cache
                     rendered-content-lines-count
                     rendered-content-lines-tail)))
                (setq rendered-content-lines-cache lines
                      rendered-content-lines-count count
                      rendered-content-lines-tail tail)))
            (unless cached-hit
              (condition-case err
                  (let* ((window (ebox--render-scroll-window-source
                                  source limit source-cache))
                     (next-source-cache (plist-get window :cache))
                     (next-complete-cache (plist-get window :complete))
                     (source-lines-exact-p
                      (ebox--scroll-window-source-lines-exact-p
                       box window))
                     (formatted-lines
                      (ebox--scroll-window-formatted-lines box window))
                     (full-line-count
                      (if source-lines-exact-p
                          (or (plist-get window :line-count)
                              (length formatted-lines))
                        (length formatted-lines)))
                     (new-count
                      (if (plist-get window :complete)
                          full-line-count
                        (min full-line-count limit)))
                     (content-prefix-delta
                      (and source-lines-exact-p
                           (eq formatted-lines source-lines-head)
                           (ebox--prefix-delta-project
                            (plist-get window :prefix-delta)
                            old-count full-line-count new-count)))
                     (append-count (- new-count old-count))
                     (source-append-start
                      (if source-lines-boundary-tail
                          (cdr source-lines-boundary-tail)
                        source-lines-head))
                     (candidate-appended-lines
                      (and content-prefix-delta
                           (>= append-count 0)
                           (seq-take source-append-start append-count)))
                     (exact-extension-p
                      (and content-prefix-delta
                           (= (length candidate-appended-lines)
                              append-count)
                           rendered-content-lines-cache
                           (= rendered-content-lines-count old-count))))
                    (if exact-extension-p
                        (let* ((rewrite-range
                                (plist-get content-prefix-delta
                                           :rewrite-range))
                               (rewrite-lines
                                (plist-get content-prefix-delta
                                           :rewrite-lines))
                               (rendered-rewrite-lines
                                (and rewrite-range
                                     (ebox--scroll-rendered-content-lines
                                      box rewrite-lines region-id
                                      (car rewrite-range))))
                               (rendered-append-lines
                                (ebox--scroll-rendered-content-lines
                                 box candidate-appended-lines region-id
                                 old-count)))
                          ;; All rendering that can signal completes before
                          ;; published content/rendered lists are mutated.
                          (unless (and (= (length rendered-rewrite-lines)
                                          (length rewrite-lines))
                                       (= (length rendered-append-lines)
                                          append-count))
                            (error
                             "Prefix renderer returned inconsistent delta"))
                          (let ((inhibit-quit t))
                            (when rewrite-range
                              (ebox--line-list-rewrite-range!
                               content-lines-cache old-count
                               content-lines-tail rewrite-range
                               rewrite-lines))
                            (pcase-let ((`(,new-lines ,new-tail)
                                         (ebox--line-list-append!
                                          content-lines-cache
                                          content-lines-tail
                                          candidate-appended-lines)))
                              (setq content-lines-cache new-lines
                                    content-lines-tail new-tail))
                            (when rewrite-range
                              (ebox--line-list-rewrite-range!
                               rendered-content-lines-cache old-count
                               rendered-content-lines-tail rewrite-range
                               rendered-rewrite-lines))
                            (pcase-let ((`(,new-lines ,new-tail)
                                         (ebox--line-list-append!
                                          rendered-content-lines-cache
                                          rendered-content-lines-tail
                                          rendered-append-lines)))
                              (setq rendered-content-lines-cache new-lines
                                    rendered-content-lines-tail new-tail))
                            (setq content-lines-count new-count)
                            (setq rendered-content-lines-count new-count)
                            (when (> append-count 0)
                              (setq source-lines-boundary-tail
                                    (nthcdr (1- append-count)
                                            source-append-start)))))
                      (let* ((new-content-lines
                              (seq-take formatted-lines new-count))
                             (new-rendered-lines
                              (ebox--scroll-rendered-content-lines
                               box new-content-lines region-id 0)))
                        ;; Commit the rebuilt pair only after rendering succeeds.
                        (setq content-lines-cache new-content-lines
                              content-lines-count new-count
                              content-lines-tail (last new-content-lines)
                              rendered-content-lines-cache new-rendered-lines
                              rendered-content-lines-count new-count
                              rendered-content-lines-tail
                              (last new-rendered-lines))
                        (if source-lines-exact-p
                            (setq source-lines-head formatted-lines
                                  source-lines-boundary-tail
                                  (and (> new-count 0)
                                       (nthcdr (1- new-count)
                                               formatted-lines)))
                          (setq source-lines-head nil
                                source-lines-boundary-tail nil))))
                    (setq source-cache next-source-cache
                          complete-cache next-complete-cache))
                ((error quit)
                 ;; A producer may have extended private stack/flex caches in
                 ;; place before a later wrapper or face renderer signalled.
                 ;; Published content remains intact; discard every private
                 ;; continuation so the next attempt starts from that prefix.
                 (setq source-cache nil
                       source-lines-head nil
                       source-lines-boundary-tail nil
                       complete-cache nil
                       signature-cache (make-hash-table :test 'eq))
                 (when (hash-table-p ebox--render-cache-table)
                   (clrhash ebox--render-cache-table))
                 (signal (car err) (cdr err)))))
            (let* ((published-count
                    (if complete-cache
                        content-lines-count
                      (min content-lines-count limit)))
                   (content-lines
                    (if (= published-count content-lines-count)
                        content-lines-cache
                      (seq-take content-lines-cache published-count))))
              (when (< rendered-content-lines-count published-count)
                (pcase-let
                    ((`(,lines ,count ,tail)
                      (ebox--scroll-rendered-prefix-through-content
                       box content-lines-cache content-lines-count region-id
                       rendered-content-lines-cache
                       rendered-content-lines-count
                       rendered-content-lines-tail)))
                  (setq rendered-content-lines-cache lines
                        rendered-content-lines-count count
                        rendered-content-lines-tail tail)))
              (list :content-lines
                    content-lines
                    :content-height content-height
                    :rendered-content-lines
                    (if (= published-count rendered-content-lines-count)
                        rendered-content-lines-cache
                      (seq-take rendered-content-lines-cache
                                published-count))
                    :complete complete-cache
                    :box box))))))))

(defun ebox--scroll-window-stack-source (node)
  "Return lazy scroll stack source metadata for NODE, or nil."
  (cond
   ((eq (plist-get node :ebox-type) 'stack)
    (list :stack node))
   ((and (eq (plist-get node :ebox-type) 'box)
         (eq (plist-get (plist-get node :ebox-content-node)
                        :ebox-type)
             'stack))
    (list :stack (plist-get node :ebox-content-node)
          :wrapper node))))

(defun ebox--scroll-window-rebind-state-producers (state box)
  "Rebind lazy scroll producers in STATE to candidate runtime BOX.
The stored producer descriptor carries only viewport dimensions; source nodes
are always resolved from BOX so no closure can retain a replaced runtime."
  (when (or (plist-get state :render-content-prefix)
            (plist-get state :materialize-content-lines))
    (let* ((spec (plist-get state :scroll-window-producer-spec))
           (prefix-viewport-width
            (plist-get spec :prefix-viewport-width))
           (materialize-viewport-width
            (plist-get spec :materialize-viewport-width))
           (viewport-height (plist-get spec :viewport-height))
           (source
            (ebox--scroll-window-stack-source
             (ebox--box-content-node box))))
      (unless (and (numberp prefix-viewport-width)
                   (> prefix-viewport-width 0)
                   (numberp materialize-viewport-width)
                   (> materialize-viewport-width 0)
                   (numberp viewport-height)
                   (> viewport-height 0))
        (error "Ebox lazy scroll state lacks a portable producer descriptor"))
      (if source
          (progn
            (when (plist-get state :render-content-prefix)
              (setq state
                    (plist-put
                     state :render-content-prefix
                     (ebox--scroll-window-prefix-renderer
                      box source prefix-viewport-width viewport-height))))
            (when (plist-get state :materialize-content-lines)
              (setq state
                    (plist-put
                     state :materialize-content-lines
                     (ebox--scroll-window-materializer
                      box materialize-viewport-width viewport-height)))))
        ;; A changed candidate may no longer have a lazy source.  Its dirty
        ;; render will install the new state; never carry old-tree closures
        ;; across that preparation boundary.
        (setq state (plist-put state :render-content-prefix nil))
        (setq state (plist-put state :materialize-content-lines nil)))))
  state)

(defun ebox--scroll-window-source-lines-exact-p (box window)
  "Return non-nil when WINDOW lines can be used as BOX formatted content."
  (and (plist-get window :content-width-exact-p)
       (null (ebox-get box :wrap-mode))
       (eq (ebox-get box :text-align) 'left)
       (= (ebox--content-pixel box)
          (or (ebox--viewport-pixel-width nil) 0))))

(defun ebox--scroll-window-formatted-lines (box window)
  "Return formatted scroll content lines for BOX from WINDOW."
  (if (ebox--scroll-window-source-lines-exact-p box window)
      (plist-get window :lines)
    (ebox-string-lines
     (ebox--format-content-string
      box
      (or (plist-get window :rendered)
          (ebox-lines-join (plist-get window :rendered-lines)))))))

(defun ebox--scroll-window-wrapper-supported-p (box)
  "Return non-nil when BOX can wrap an incomplete lazy scroll prefix."
  (or (null box)
      (and (null (ebox-get box :height))
           (or (null (ebox-get box :min-height))
               (equal (ebox-get box :min-height) 0))
           (null (ebox-get box :max-height))
           (null (ebox-get box :wrap-mode))
           (eq (ebox-get box :text-align) 'left)
           (eq (ebox-get box :vertical-align) 'top))))

(defun ebox--scroll-window-render-wrapper-full
    (wrapper content content-width-exact-p)
  "Render WRAPPER around CONTENT through the normal box renderer."
  (let* ((copy (copy-sequence wrapper))
         (region-id (ebox--ensure-region-id wrapper)))
    (plist-put copy :region-id region-id)
    (plist-put copy :content content)
    (plist-put copy :ebox-content-node nil)
    (plist-put copy :ebox-content-width-exact-p content-width-exact-p)
    (prog1 (ebox-render copy)
      (puthash region-id wrapper ebox--region-box-table))))

(defun ebox--window-render-flat-wrapper-chunk-lines
    (box content-lines start-index region-id padding-line-filler
         &optional include-top include-bottom)
  "Render a marginless BOX wrapper around CONTENT-LINES in one pass.
START-INDEX and REGION-ID identify the wrapped content lines.  INCLUDE-TOP
adds top padding and border chrome.  INCLUDE-BOTTOM adds bottom padding and
border chrome.  The caller guarantees that BOX has no horizontal margins and
no included vertical margin."
  (let* ((padding-left (ebox-get box :padding-left-pixel))
         (padding-right (ebox-get box :padding-right-pixel))
         (padding-top (if include-top
                          (floor (ebox-get box :padding-top-height))
                        0))
         (padding-bottom (if include-bottom
                             (floor (ebox-get box :padding-bottom-height))
                           0))
         (border-left-pixel (ebox-get box :border-left-pixel))
         (border-right-pixel (ebox-get box :border-right-pixel))
         (border-top-p (and include-top (ebox-get box :border-top-p)))
         (border-top-color (ebox-get box :border-top-color))
         (border-bottom-p
          (and include-bottom (ebox-get box :border-bottom-p)))
         (border-bottom-color (ebox-get box :border-bottom-color))
         (color (ebox-get box :color))
         (bgcolor (ebox-get box :bgcolor))
         (padding-left-line
          (when (> padding-left 0)
            (let ((line
                   (ebox--propertize-region
                    (ebox--pixel-blank padding-left 1)
                    'ebox-pl region-id)))
              (if (or color bgcolor)
                  (ebox--propertize-colors line color bgcolor)
                line))))
         (padding-right-line
          (when (> padding-right 0)
            (let ((line
                   (ebox--propertize-region
                    (ebox--pixel-blank padding-right 1)
                    'ebox-pr region-id)))
              (if (or color bgcolor)
                  (ebox--propertize-colors line color bgcolor)
                line))))
         (border-left-line
          (when (> border-left-pixel 0)
            (ebox--propertize-region
             (ebox--pixel-border border-left-pixel 1
                                 (ebox-get box :border-left-color))
             'ebox-bl region-id)))
         (border-right-line
          (when (> border-right-pixel 0)
            (ebox--propertize-region
             (ebox--pixel-border border-right-pixel 1
                                 (ebox-get box :border-right-color))
             'ebox-br region-id))))
    (let* ((top-core-line
            (when (> padding-top 0)
              (let ((line
                     (ebox--propertize-region
                      padding-line-filler 'ebox-pt region-id)))
                (if (or color bgcolor)
                    (ebox--propertize-colors line color bgcolor)
                  line))))
           (top-lines
            (when top-core-line
              (cl-loop repeat padding-top
                       collect
                       (concat border-left-line padding-left-line
                               top-core-line padding-right-line
                               border-right-line))))
           (bottom-core-line
            (when (> padding-bottom 0)
              (let ((line
                     (ebox--propertize-region
                      padding-line-filler 'ebox-pb region-id)))
                (if (or color bgcolor)
                    (ebox--propertize-colors line color bgcolor)
                  line))))
           (bottom-lines
            (when bottom-core-line
              (cl-loop repeat padding-bottom
                       collect
                       (concat border-left-line padding-left-line
                               bottom-core-line padding-right-line
                               border-right-line))))
           (wrapped-lines
            (cl-loop
             for source-line in content-lines
             for idx from start-index
             collect
             (let* ((child-ownership-uniform-p
                     (cl-every
                      (lambda (property)
                        (not
                         (text-property-not-all
                          0 (length source-line) property
                          (get-text-property 0 property source-line)
                          source-line)))
                      '(ebox-content ebox-content-idx
                        ebox-content-owner ebox-content-owners)))
                    (blank-replacement-p
                    (and (string-blank-p source-line)
                          child-ownership-uniform-p
                          (not (ebox--line-has-non-content-properties-p
                                source-line))))
                    (line
                     (if blank-replacement-p
                         (let ((content-id
                                (get-text-property
                                 0 'ebox-content source-line))
                               (content-idx
                                (get-text-property
                                 0 'ebox-content-idx source-line))
                               (content-owner
                                (get-text-property
                                 0 'ebox-content-owner source-line))
                               (content-owners
                                (get-text-property
                                 0 'ebox-content-owners source-line)))
                           (if (or content-owner content-owners)
                               (ebox--propertize-content-line
                                (propertize
                                 padding-line-filler
                                 'ebox-content content-id
                                 'ebox-content-idx content-idx
                                 'ebox-content-owner
                                 (or content-owner content-id)
                                 'ebox-content-owners
                                 (or content-owners
                                     (list content-owner)))
                                region-id idx padding-line-filler)
                             (if content-id
                                 (propertize
                                  padding-line-filler
                                  'ebox-content content-id
                                  'ebox-content-idx content-idx
                                  'ebox-content-owner region-id)
                               (propertize
                                padding-line-filler
                                'ebox-content region-id
                                'ebox-content-idx idx
                                'ebox-content-owner region-id))))
                       (let* ((colored-p (or color bgcolor))
                              (owned-source
                               (if colored-p
                                   (ebox--propertize-colors
                                    source-line color bgcolor)
                                 source-line)))
                         (let ((ebox--propertize-private-content-line-p
                                colored-p))
                           (ebox--propertize-content-line
                            owned-source region-id idx
                            padding-line-filler))))))
               (when (and blank-replacement-p (or color bgcolor))
                 (setq line (ebox--propertize-colors line color bgcolor)))
               (concat border-left-line padding-left-line line
                       padding-right-line border-right-line))))
           (lines (nconc top-lines wrapped-lines bottom-lines)))
      (when (and border-top-p lines)
        (setcar lines
                (propertize
                 (ebox--propertize-overline (car lines) border-top-color)
                 'ebox-bt region-id)))
      (when (and border-bottom-p lines)
        (let ((tail (last lines)))
          (setcar tail
                  (propertize
                   (ebox--propertize-underline
                    (car tail) border-bottom-color)
                   'ebox-bb region-id))))
      (when-let* ((properties (ebox-get box :surface-properties)))
        (setq lines
              (mapcar (lambda (line)
                        (ebox--apply-surface-properties line properties))
                      lines)))
      lines)))

(defun ebox--scroll-window-render-wrapper-chunk-lines
    (box content-lines start-index include-top)
  "Render BOX wrapper chrome around newly appended CONTENT-LINES.
START-INDEX is the first content-line index inside BOX.  INCLUDE-TOP means the
chunk begins at the wrapper top and should include top padding, margin, and
border chrome.  Bottom chrome is intentionally omitted because this helper is
only used for incomplete lazy prefixes."
  (if (not box)
      content-lines
    (let* ((region-id (ebox--ensure-region-id box))
           (content-pixel (ebox--content-pixel box))
           (padding-line-filler (ebox-pixel-space content-pixel))
           (padding-left (ebox-get box :padding-left-pixel))
           (padding-right (ebox-get box :padding-right-pixel))
           (padding-top (if include-top
                            (floor (ebox-get box :padding-top-height))
                          0))
           (margin-left (ebox-get box :margin-left-pixel))
           (margin-right (ebox-get box :margin-right-pixel))
           (margin-top (if include-top
                           (floor (ebox-get box :margin-top-height))
                         0))
           (border-left-pixel (ebox-get box :border-left-pixel))
           (border-left-color (ebox-get box :border-left-color))
           (border-right-pixel (ebox-get box :border-right-pixel))
           (border-right-color (ebox-get box :border-right-color))
           (border-top-p (and include-top
                              (ebox-get box :border-top-p)))
           (border-top-color (ebox-get box :border-top-color))
           (color (ebox-get box :color))
           (bgcolor (ebox-get box :bgcolor))
           (inner-height (+ (length content-lines) padding-top))
           result)
      (puthash region-id box ebox--region-box-table)
      (if (and (= margin-left 0)
               (= margin-right 0)
               (= margin-top 0))
          (ebox--window-render-flat-wrapper-chunk-lines
           box content-lines start-index region-id padding-line-filler
           include-top)
        (progn
          (setq result
                (ebox-lines-join
                 (cl-loop for line in content-lines
                          for idx from start-index
                          collect (ebox--propertize-content-line
                                   line region-id idx
                                   padding-line-filler))))
          (setq result
                (ebox--maplines
                 (lambda (line)
                   (if (and
                        (string-empty-p (string-trim line))
                        (not (ebox--line-has-non-content-properties-p line)))
                       (let ((content-id
                              (get-text-property 0 'ebox-content line))
                             (content-idx
                              (get-text-property 0 'ebox-content-idx line)))
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
          (when (> padding-top 0)
            (setq result
                  (ebox--lines-stack-vertical
                   (ebox--propertize-region
                    (ebox--pixel-blank content-pixel padding-top)
                    'ebox-pt region-id)
                   result)))
          (let ((pl-str (when (> padding-left 0)
                          (ebox--propertize-region
                           (ebox--pixel-blank padding-left inner-height)
                           'ebox-pl region-id)))
                (pr-str (when (> padding-right 0)
                          (ebox--propertize-region
                           (ebox--pixel-blank padding-right inner-height)
                           'ebox-pr region-id))))
            (when (or pl-str pr-str)
              (setq result
                    (ebox--lines-concat-horizontal pl-str result pr-str))))
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
                                                 inner-height
                                                 border-left-color)
                             'ebox-bl region-id)))
                  (br-str (when (> border-right-pixel 0)
                            (ebox--propertize-region
                             (ebox--pixel-border border-right-pixel
                                                 inner-height
                                                 border-right-color)
                             'ebox-br region-id))))
              (setq result
                    (ebox--lines-concat-horizontal bl-str result br-str))))
          (when border-top-p
            (let ((lines (ebox-string-lines result)))
              (setf (car lines)
                    (propertize
                     (ebox--propertize-overline (car lines) border-top-color)
                     'ebox-bt region-id))
              (setq result (ebox-lines-join lines))))
          (ebox--apply-surface-properties
           result (ebox-get box :surface-properties))
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
              (setq result
                    (ebox--lines-concat-horizontal ml-str result mr-str))))
          (when (> margin-top 0)
            (setq result
                  (ebox--lines-stack-vertical
                   (ebox--propertize-region
                    (ebox--pixel-blank (ebox--total-pixel box) margin-top)
                    'ebox-mt region-id)
                   result)))
          (ebox-string-lines result))))))

(defun ebox--render-scroll-window-source (source limit &optional cache)
  "Render lazy scroll SOURCE until LIMIT parent content lines are available."
  (let* ((stack (plist-get source :stack))
         (wrapper (plist-get source :wrapper))
         (cached-source-lines (plist-get cache :source-lines))
         (cached-count (or (plist-get cache :source-count)
                           (length cached-source-lines)))
         (cached-rendered-lines (plist-get cache :rendered-lines))
         (cached-rendered-count
          (or (plist-get cache :rendered-count)
              (length cached-rendered-lines)))
         (cached-rendered-tail
          (or (plist-get cache :rendered-tail)
              (last cached-rendered-lines)))
         (content-viewport (and wrapper
                                (ebox--wrapper-content-viewport-pixel
                                 wrapper)))
         (window (let ((ebox-viewport-width
                        (or content-viewport ebox-viewport-width)))
                   (ebox--render-stack-window-lines
                    stack limit (plist-get cache :stack))))
         (source-lines (plist-get window :lines))
         (source-count (or (plist-get window :line-count)
                           (length source-lines)))
         (complete (plist-get window :complete))
         (stack-delta (plist-get window :prefix-delta))
         (stack-prefix-exact-p
          (and (eq source-lines cached-source-lines)
               (ebox--prefix-delta-payload-valid-p
                stack-delta cached-count source-count)))
         (rewrite-range
          (and stack-prefix-exact-p
               (plist-get stack-delta :rewrite-range)))
         (wrapper-prefix-count
          (- cached-rendered-count cached-count))
         (wrapper-reuse-p
          (and wrapper
               (not complete)
               stack-prefix-exact-p
               (ebox--scroll-window-wrapper-supported-p wrapper)
               cached-source-lines
               cached-rendered-lines
               (>= wrapper-prefix-count 0)))
         (mapped-rewrite-range
          (and wrapper-reuse-p rewrite-range
               (if (= (car rewrite-range) 0)
                   (cons 0 (+ wrapper-prefix-count
                              (cdr rewrite-range)))
                 (cons (+ wrapper-prefix-count
                          (car rewrite-range))
                       (+ wrapper-prefix-count
                          (cdr rewrite-range))))))
         (rewritten-lines
          (and wrapper-reuse-p rewrite-range
               (ebox--scroll-window-render-wrapper-chunk-lines
                wrapper
                (plist-get stack-delta :rewrite-lines)
                (car rewrite-range)
                (= (car rewrite-range) 0))))
         (appended-source-lines
          (and wrapper-reuse-p
               (plist-get stack-delta :append-lines)))
         (appended-lines
          (and appended-source-lines
               (ebox--scroll-window-render-wrapper-chunk-lines
                wrapper appended-source-lines cached-count nil)))
         (wrapper-prefix-exact-p
          (and wrapper-reuse-p
               (or (null mapped-rewrite-range)
                   (= (length rewritten-lines)
                      (- (cdr mapped-rewrite-range)
                         (car mapped-rewrite-range))))
               (= (length appended-lines)
                  (length appended-source-lines))))
         rendered-lines
         rendered-count
         rendered-tail
         prefix-delta)
    (cond
     ((not wrapper)
      (setq rendered-lines source-lines
            rendered-count source-count
            rendered-tail (plist-get window :line-tail)
            prefix-delta
            (if stack-prefix-exact-p
                stack-delta
              (list :exact-p nil :base-count cached-count
                    :rewrite-range nil :rewrite-lines nil
                    :append-lines nil))))
     (wrapper-prefix-exact-p
      (let ((inhibit-quit t))
        (when mapped-rewrite-range
          (ebox--line-list-rewrite-range!
           cached-rendered-lines cached-rendered-count cached-rendered-tail
           mapped-rewrite-range rewritten-lines))
        (pcase-let ((`(,new-lines ,new-tail)
                     (ebox--line-list-append!
                      cached-rendered-lines cached-rendered-tail
                      appended-lines)))
          (setq rendered-lines new-lines
                rendered-tail new-tail))
        (setq rendered-count
              (+ cached-rendered-count (length appended-lines))))
      (setq prefix-delta
            (list :exact-p t
                  :base-count cached-rendered-count
                  :rewrite-range mapped-rewrite-range
                  :rewrite-lines rewritten-lines
                  :append-lines appended-lines)))
     (t
      (setq rendered-lines
            (if (and (not complete)
                     (ebox--scroll-window-wrapper-supported-p wrapper))
                (ebox--scroll-window-render-wrapper-chunk-lines
                 wrapper source-lines 0 t)
              (ebox-string-lines
               (ebox--scroll-window-render-wrapper-full
                wrapper (ebox-lines-join source-lines) t))))
      (setq rendered-count (length rendered-lines)
            rendered-tail (last rendered-lines)
            prefix-delta
            (list :exact-p nil
                  :base-count cached-rendered-count
                  :rewrite-range nil
                  :rewrite-lines nil
                  :append-lines nil))))
    (list :complete complete
          :cache (list :stack (plist-get window :cache)
                       :source-lines source-lines
                       :source-count source-count
                       :rendered-lines rendered-lines
                       :rendered-count rendered-count
                       :rendered-tail rendered-tail)
          :lines rendered-lines
          :line-count rendered-count
          :line-tail rendered-tail
          :content-width-exact-p t
          :rendered-lines rendered-lines
          :prefix-delta prefix-delta)))

(defun ebox--format-scroll-window-content (box)
  "Return a lazily rendered scroll content window for BOX, or nil."
  (catch 'ebox-scroll-window-cached
    (let* ((cached ebox--scroll-window-cached-state)
         (cached-box (and cached (plist-get cached :box)))
         (cached-id (and cached-box (plist-get cached-box :node-id)))
         (box-id (and (listp box) (plist-get box :node-id)))
         (cached-rendered-lines
          (and cached (plist-get cached :rendered-content-lines)))
         (use-cached-rendered-lines-p
          (and ebox--scroll-window-skip-state-rebuild-p
               cached-rendered-lines))
         (cached-lines (and cached
                            (or (and use-cached-rendered-lines-p
                                     cached-rendered-lines)
                                (plist-get cached :content-lines)))))
    (when (and cached cached-box cached-lines box-id
               (equal box-id cached-id)
               (eq (ebox-get box :overflow) 'scroll))
      (setq ebox--scroll-window-render-result
            (list :complete (plist-get cached :content-lines-complete-p)
                  :content-height (plist-get cached :content-height)
                  :scroll-window-producer-spec
                  (plist-get cached :scroll-window-producer-spec)
                  :render-content-prefix
                  (plist-get cached :render-content-prefix)
                  :materialize-content-lines
                  (plist-get cached :materialize-content-lines)
                  :cached-rendered-lines-p
                  (and use-cached-rendered-lines-p t)))
      (throw 'ebox-scroll-window-cached
        (ebox-lines-join cached-lines))))
  (let ((content-height (ebox--scroll-window-content-height box))
        (scroll-offset (max 0 (or (ebox-get box :scroll-offset) 0)))
        (content-viewport (ebox--wrapper-content-viewport-pixel box))
        (source (ebox--scroll-window-stack-source
                 (ebox--box-content-node box))))
    (when (and (not ebox--scroll-window-render-disabled)
               (eq (ebox-get box :overflow) 'scroll)
               (ebox--viewport-height-size-value-p (ebox-get box :height))
               content-height
               (> content-height 0)
               (ebox--viewport-pixel-width nil)
               source)
      (if ebox--intrinsic-layout-measurement
          (progn
            (setq ebox--scroll-window-render-result
                  (list :content-height content-height
                        :measurement-placeholder t))
            (or (ebox--pixel-blank (ebox--content-pixel box)
                                   content-height)
                ""))
        (let ((ebox-viewport-width
               (or content-viewport ebox-viewport-width)))
          (let* ((target-lines
                  (+ scroll-offset
                     content-height 1
                     (ebox--scroll-window-initial-lookahead-lines)))
                 (window (ebox--render-scroll-window-source
                          source target-lines))
                 (formatted-lines
                  (ebox--scroll-window-formatted-lines box window))
                 (viewport-width ebox-viewport-width)
                 (viewport-height ebox-viewport-height))
            (setq ebox--scroll-window-render-result
                  (list :complete (plist-get window :complete)
                        :content-height content-height
                        :scroll-window-producer-spec
                        (ebox--scroll-window-producer-spec
                         viewport-width viewport-width viewport-height)
                        :render-content-prefix
                        (ebox--scroll-window-prefix-renderer
                         box source viewport-width viewport-height
                         (plist-get window :cache)
                         formatted-lines)
                        :materialize-content-lines
                        (ebox--scroll-window-materializer
                         box viewport-width viewport-height)))
            (ebox-lines-join
             (if (plist-get window :complete)
                 formatted-lines
               (seq-take formatted-lines target-lines))))))))))

(defun ebox--render-stack (node)
  "Render a stack NODE to a string (internal, called by `ebox-render').

Stack leaves are rendered independently.  When a containing-block viewport is
bound, narrower rows are padded to that available width, while wider definite
children keep their own width and overflow only on their own rows.  During
intrinsic measurement, descendants still receive the containing block but the
stack itself uses its natural max child width.  A stack used as an intrinsic
inline child follows the same natural-width rule and does not consume the
ambient horizontal viewport."
  (let* ((rendered-items
          (mapcar (lambda (leaf)
                    (let ((rendered (ebox--render-with-cache leaf)))
                      (cons rendered
                            (ebox--string-max-pixel-width rendered))))
                  (ebox--stack-leaves node)))
         (max-w (if rendered-items
                    (apply #'max (mapcar #'cdr rendered-items))
                  0))
         (target-w (if (or ebox--intrinsic-layout-measurement
                         ebox--inline-auto-width-intrinsic-p)
                       max-w
                     (or (ebox--viewport-pixel-width nil) max-w))))
    (let ((rendered
           (apply #'ebox--lines-stack-vertical
                  (mapcar (lambda (item)
                            (let ((rendered (car item))
                                  (width (cdr item)))
                              (if (< width target-w)
                                  (ebox--width-pad rendered (- target-w width))
                                rendered)))
                          rendered-items))))
      ;; When no child overflows the containing block, stack padding proves
      ;; every output line already has the exact target width.  A wrapping box
      ;; can then preserve this preformatted content without measuring every
      ;; line again.  Wider children deliberately keep their own overflow rows
      ;; and therefore must not publish uniform-width metadata.
      (if (<= max-w target-w)
          (ebox--record-rendered-uniform-width rendered target-w)
        rendered))))

(provide 'ebox-layout)

;;; ebox-layout.el ends here
