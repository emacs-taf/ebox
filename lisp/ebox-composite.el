;;; ebox-composite.el --- Pixel interval row composition -*- lexical-binding: t; -*-

;;; Commentary:
;; Compose opaque, already rendered rows without changing their source strings.
;; Resolve coverage first so every visible interval is cut from its original
;; source, independent of the number or ordering of hidden lower placements.

;;; Code:

(require 'cl-lib)
(require 'ebox-measure)
(require 'ebox-render-context)

(declare-function ebox--grapheme-cluster-end "ebox-layout" (string start))

(defun ebox-composite--line-p (line)
  "Return non-nil if LINE is a single-line string or nil."
  (or (null line)
      (and (stringp line) (not (string-match-p "\n" line)))))

(defun ebox-composite--replacement-p (display)
  "Return non-nil when DISPLAY replaces an entire EQ property run."
  (or (stringp display) (memq (car-safe display) '(space image))))

(defun ebox-composite--unit-end (line position)
  "Return the complete display unit end in LINE at POSITION."
  (let ((end (ebox--grapheme-cluster-end line position)))
    (if (ebox-composite--replacement-p
         (get-text-property position 'display line))
        (max end (next-single-property-change
                  position 'display line (length line)))
      end)))

(defun ebox-composite--space (line start end width)
  "Copy LINE's fixed space at START through END using WIDTH pixels.
Retain the source properties and nested display values by identity."
  (let* ((result (substring line start end))
         (display (get-text-property start 'display line))
         (properties (copy-sequence (cdr display)))
         ;; Match `ebox-pixel-space': retained integer allocations and
         ;; freshly resolved float allocations describe the same pixels.
         (whole-pixels (truncate width))
         (width (if (= width whole-pixels) whole-pixels width)))
    (put-text-property
     0 (length result) 'display
     (cons 'space (plist-put properties :width (list width))) result)
    result))

(defun ebox-composite--fill (line position width)
  "Replace LINE's glyph at POSITION with WIDTH pixels of painted blank.
Keep face values by identity so named paint slots remain live.  Retain paint
dependencies on the transient origin carrier, separately from the omitted
glyph's display, interaction and semantic ownership properties."
  (let ((space (ebox-pixel-space width)))
    (dolist (property '(face font-lock-face))
      (when-let* ((value (get-text-property position property line)))
        (put-text-property 0 (length space) property value space)))
    (let ((origin (get-text-property position ebox--paint-origin-property line)))
      (when (or origin ebox--paint-origin-capture-p)
        (put-text-property
         0 (length space) ebox--paint-origin-property
         (ebox--paint-origin-create
          :baseline (if origin (ebox--paint-origin-baseline origin)
                      (copy-tree (get-text-property position 'face line)))
          :source-roles
          (delete-dups
           (append (and origin
                        (copy-sequence (ebox--paint-origin-source-roles origin)))
                   (ebox--render-role-ids-from-properties
                    (text-properties-at position line)))))
         space)))
    space))

(defun ebox-composite--join (parts)
  "Join PARTS while retaining their separately measured pixel extents.
A neutral zero-pixel display boundary prevents adjacent EQ replacement runs
from collapsing or independently shaped source fragments from reshaping."
  (let ((result "") (width 0))
    (dolist (part parts result)
      (unless (equal part "")
        (let* ((next-width (+ width (ebox--string-pixel-width part)))
               (joined (concat result part)))
          (setq result
                (if (= (ebox--string-pixel-width joined) next-width)
                    joined
                  (concat result
                          (propertize " " 'display '(space :width (0)))
                          part))
                width next-width))))))

(defun ebox-composite--fit (line start end left right)
  "Fit LINE from START through END in its original [LEFT, RIGHT) pixels.
Removing a left shaping context can change a retained unit's width.  Resolve
that unit within its original pixel interval, then retry the remaining whole
run.  A newly wider glyph becomes painted fill rather than shifting the next
source glyph or borrowing its pixels."
  (let ((position start) (pixel left) parts)
    (while (< position end)
      (let* ((remaining (substring line position end))
             (width (ebox--string-pixel-width remaining)))
        (if (= width (- right pixel))
            (progn (push remaining parts) (setq position end))
          (let* ((next (ebox-composite--unit-end line position))
                 (next-pixel (ebox--substring-pixel-width line 0 next))
                 (unit (substring line position next))
                 (unit-width (ebox--string-pixel-width unit))
                 (available (- next-pixel pixel)))
            (cond
             ((<= unit-width available)
              (push unit parts)
              (push (ebox-composite--fill
                     line position (- available unit-width)) parts))
             ((ebox--display-space-width
               (get-text-property position 'display line))
              (push (ebox-composite--space line position next available)
                    parts))
             (t (push (ebox-composite--fill line position available) parts)))
            (setq position next pixel next-pixel)))))
    (ebox-composite--join (nreverse parts))))

(defvar ebox-composite--prepared-lines nil
  "Owner-local slice indexes for immutable retained lines in this display context.
Only a validated retained program binds this table.  Indexes are built on the
first slice of each line, so preparation pays nothing for lines that are
never cropped.  Lines whose shaping admits no monotone index record nil and
keep the ordinary measurement path.")

(defun ebox-composite--prepare-line (line)
  "Record LINE's display units and monotone original prefix widths once.
Return nil when shaping does not admit a monotone index. The owning retained
program is responsible for invalidating this data with its display context."
  (let ((position 0) (pixel 0) (positions (list 0)) (pixels (list 0)) (valid t))
    (while (and valid (< position (length line)))
      (let* ((next (ebox-composite--unit-end line position))
             (width (ebox--substring-pixel-width line 0 next)))
        (setq valid (and (ebox-size--finite-number-p width) (>= width pixel)))
        (push next positions) (push width pixels)
        (setq position next pixel width)))
    (when (and valid (= pixel (ebox--string-pixel-width line)))
      (cons (vconcat (nreverse positions)) (vconcat (nreverse pixels))))))

(defun ebox-composite--prepared-index (line)
  "Return LINE's slice index from the bound owner table, building it once."
  (let ((entry (gethash line ebox-composite--prepared-lines 'missing)))
    (if (eq entry 'missing)
        (puthash line (ebox-composite--prepare-line line) ebox-composite--prepared-lines)
      entry)))

(defun ebox-composite--slice-unit-index (pixels start)
  "Locate the first possibly intersecting unit for START in sorted PIXELS.
Keep the preceding unit at an exact boundary so zero-width units retain the
ordinary slice semantics."
  (let ((low 0) (high (1- (length pixels))))
    (while (< low high)
      (let ((middle (/ (+ low high) 2)))
        (if (< (aref pixels middle) start) (setq low (1+ middle))
          (setq high middle))))
    (max 0 (1- low))))

(defun ebox-composite-slice (line start end)
  "Extract LINE's pixel interval [START, END), exactly END minus START wide.
START and END must be finite nonnegative numbers with START <= END.  LINE is
a single-line string or nil.  Pixels beyond LINE are neutral blank space.
Keep complete supported graphemes and replacement display runs, preserving
their text property values by identity.  Fixed pixel spaces can be cut at
either edge; other partial glyphs become noninteractive blanks retaining their
source faces at their original positions.  Measure original prefixes so
adjacent shaping is not summed as isolated characters.  Neither LINE nor its
property values are modified."
  (unless (ebox-composite--line-p line)
    (error "Ebox composite needs a single-line string: %S" line))
  (unless (and (ebox-size--finite-number-p start) (>= start 0)
               (ebox-size--finite-number-p end) (>= end start))
    (error "Invalid Ebox composite pixel interval: %S %S" start end))
  (let* ((line (or line ""))
         (line-width (ebox--string-pixel-width line)))
    (cond
     ((= start end) "")
     ((and (= start 0) (<= line-width end))
      (ebox-composite--join
       (list line (ebox-pixel-space (- end line-width)))))
     ((>= start line-width) (ebox-pixel-space (- end start)))
     (t
      (let* ((prepared (and ebox-composite--prepared-lines
                            (ebox-composite--prepared-index line)))
             (positions (car prepared)) (pixels (cdr prepared))
             (index (if prepared (ebox-composite--slice-unit-index pixels start) 0))
             (position (if prepared (aref positions index) 0))
             (pixel (if prepared (aref pixels index) 0)) parts
             run-start run-end run-left run-right)
        (cl-labels
            ((flush ()
               (when run-start
                 (push (ebox-composite--fit
                        line run-start run-end run-left run-right)
                       parts)
                 (setq run-start nil))))
          (while (and (< position (length line)) (< pixel end))
            (let* ((next (if prepared (aref positions (1+ index))
                           (ebox-composite--unit-end line position)))
                   (next-pixel (if prepared (aref pixels (1+ index))
                                 (ebox--substring-pixel-width line 0 next)))
                   (left (max start pixel))
                   (right (min end next-pixel)))
              (cond
               ((and (>= pixel start) (<= next-pixel end))
                (unless run-start
                  (setq run-start position run-left pixel))
                (setq run-end next run-right next-pixel))
               ((< left right)
                (flush)
                (push (if (ebox--display-space-width
                           (get-text-property position 'display line))
                          (ebox-composite--space
                           line position next (- right left))
                        (ebox-composite--fill line position (- right left)))
                      parts)))
              (setq position next pixel next-pixel index (1+ index))))
          (flush))
        (when (> end (max start pixel))
          (push (ebox-pixel-space (- end (max start pixel))) parts))
        (ebox-composite--join (nreverse parts)))))))

(defun ebox-composite--uncovered (start end covered)
  "Return portions of [START, END) outside sorted merged COVERED intervals."
  (let ((cursor start) result)
    (dolist (interval covered)
      (when (and (< cursor end) (> (cdr interval) cursor))
        (when (> (car interval) cursor)
          (push (cons cursor (min end (car interval))) result))
        (setq cursor (max cursor (cdr interval)))))
    (when (< cursor end) (push (cons cursor end) result))
    (nreverse result)))

(defun ebox-composite--cover (start end covered)
  "Return sorted merged COVERED intervals including [START, END).
Do not modify the input interval list or its cons cells."
  (let (result)
    (dolist (interval covered)
      (cond
       ((< (cdr interval) start) (push interval result))
       ((> (car interval) end)
        (push (cons start end) result)
        (setq start (car interval) end (cdr interval)))
       (t (setq start (min start (car interval))
                end (max end (cdr interval))))))
    (push (cons start end) result)
    (nreverse result)))

(defun ebox-composite-line (base placements width &optional stop)
  "Compose BASE and opaque PLACEMENTS on a fixed WIDTH-pixel canvas.
BASE is a single-line string or nil.  PLACEMENTS is a proper list of plists
with a single-line string :text and finite pixel :x, already ordered bottom
to top.  Each placement covers the full measured width of its text, including
blanks, or its optional :source-start/:source-end pixel interval.  Such an
interval retains the original row until visibility is resolved; :x positions
the interval's left edge.  Negative and overflowing placements are clipped.
WIDTH must be finite and nonnegative.  Uncovered pixels beyond BASE receive
neutral fill.  Compute coverage before extracting original source intervals,
so hidden placements cannot introduce cuts into a visible source glyph.
Do not modify BASE, PLACEMENTS, or any of their text property values.
STOP, when non-nil, is the first unused tail of a prepared placement spine."
  (unless (and (ebox-composite--line-p base)
               (proper-list-p placements)
               (ebox-size--finite-number-p width) (>= width 0))
    (error "Invalid Ebox composite canvas"))
  (let (sources covered visible)
    (while (and placements (not (eq placements stop)))
      (let ((placement (car placements)))
      (let* ((text (plist-get placement :text))
             (x (plist-get placement :x))
             (source-start (or (plist-get placement :source-start) 0))
             (source-end (plist-get placement :source-end)))
        (unless (and (stringp text) (ebox-composite--line-p text)
                     (ebox-size--finite-number-p x)
                     (ebox-size--finite-number-p source-start) (>= source-start 0))
          (error "Invalid Ebox composite placement: %S" placement))
        (setq source-end (or source-end (ebox--string-pixel-width text)))
        (unless (and (ebox-size--finite-number-p source-end) (>= source-end source-start))
          (error "Invalid Ebox composite source interval"))
        (let* ((right (+ x (- source-end source-start)))
               (left (max 0 x))
               (end (min width right)))
          (unless (ebox-size--finite-number-p right)
            (error "Ebox composite placement extent is not finite"))
          (when (< left end)
            (push (list left end text (- x source-start)) sources)))))
      (setq placements (cdr placements)))
    ;; Sources were pushed from bottom to top.  Only original source metadata
    ;; participates in occlusion; no sliced text is ever sliced again.
    (dolist (source (append sources (list (list 0 width base 0))))
      (pcase-let ((`(,start ,end ,text ,x) source))
        (dolist (interval (ebox-composite--uncovered start end covered))
          (push (list (car interval) (cdr interval) text x) visible))
        (when (< start end)
          (setq covered (ebox-composite--cover start end covered)))))
    (ebox-composite--join
     (mapcar
      (lambda (interval)
        (pcase-let ((`(,start ,end ,text ,x) interval))
          (ebox-composite-slice text (- start x) (- end x))))
      (sort visible (lambda (a b) (< (car a) (car b))))))))

(provide 'ebox-composite)
;;; ebox-composite.el ends here
