;;; ebox-measure.el --- Pixel measurement helpers for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns display-signature-sensitive measurement caches and text/space width
;; helpers.  It does not own layout decisions or dirty classification.

;;; Code:

(require 'cl-lib)
(require 'ebox-cache)
(require 'ebox-font)
(require 'ebox-size)

(declare-function ebox--register-render-owned-text-value
                  "ebox-render-context" (property value))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox--string-repeat-lines "ebox" (string count))

;; Measurement Cache Model:
;; These caches only accelerate display-signature-sensitive pixel measurement.
;; They must not carry layout identity, dirty state, or buffer ownership.

(defvar ebox--char-width-cache (make-hash-table :test 'eq)
  "Cache for character pixel widths.")

(defvar ebox--space-pixel-cache nil
  "Cache for space pixel width.")

(defvar ebox--face-height-width-cache nil
  "Cache indicating whether explicit face height affects measured width.")

(defvar ebox--display-signature-cache nil
  "Cached display signature used to invalidate pixel measurements.")

(defvar ebox--display-cache-validated nil
  "Non-nil while the display signature has already been validated.
Bound to t for the dynamic extent of a single render so that the thousands
of pixel measurements it triggers do not each rebuild the display signature.")

(defvar ebox--render-display-signature nil
  "Display signature snapshot for the current render transaction.")

(defvar ebox--render-string-pixel-width-cache nil
  "Dynamic render-local cache for reusable string pixel widths.")

(defconst ebox--string-pixel-width-cache-max-entries 4096
  "Maximum safe string measurements retained for one display signature.")

(defvar ebox--string-pixel-width-cache (make-hash-table :test 'equal)
  "Display-signature-scoped cache for reusable string pixel widths.")

(defvar ebox--string-pixel-width-cache-ring
  (make-vector ebox--string-pixel-width-cache-max-entries nil)
  "Insertion-order keys for bounded string measurement eviction.")

(defvar ebox--string-pixel-width-cache-ring-index 0
  "Next insertion slot in `ebox--string-pixel-width-cache-ring'.")

(defvar ebox--render-string-max-pixel-width-cache nil
  "Dynamic render-local cache for rendered multiline string max widths.")

(defvar ebox--render-recached-source-node-cache nil
  "Dynamic render-local set of source subtrees recached into region tables.")

(defun ebox--text-scale-factor ()
  "Return the active text scale multiplier."
  (let ((amount (and (boundp 'text-scale-mode-amount)
                     (numberp text-scale-mode-amount)
                     text-scale-mode-amount))
        (step (if (and (boundp 'text-scale-mode-step)
                       (numberp text-scale-mode-step))
                  text-scale-mode-step
                1.2)))
    (if amount (expt step amount) 1.0)))

(defun ebox--display-space-width (display)
  "Return fixed pixel width for DISPLAY space specs, or nil."
  (ebox--fixed-pixel-space-width display))

(defun ebox--fixed-pixel-space-width (display)
  "Return DISPLAY's nonnegative fixed pixel width, or nil for other specs.
Bare space widths use character units; align-to spaces depend on placement."
  (when (and (consp display) (eq (car display) 'space)
             (not (plist-member (cdr display) :align-to)))
    (let ((width (plist-get (cdr display) :width)))
      (when (and (consp width) (null (cdr width))
                 (ebox-size--finite-number-p (car width)) (>= (car width) 0))
        (car width)))))

(defun ebox--fractional-pixel-spaces-p (string)
  "Return non-nil when STRING has a nonintegral fixed-pixel space glyph."
  (let ((position 0) (end (length string)))
    (catch 'fractional
      (while (< position end)
        (let* ((next (next-single-property-change position 'display string end))
               (width (ebox--fixed-pixel-space-width
                       (get-text-property position 'display string))))
          (when (and width (/= width (floor width))
                     (cl-position-if (lambda (char) (/= char ?\n)) string
                                     :start position :end next))
            (throw 'fractional t))
          (setq position next)))
      nil)))

(defun ebox--quantize-pixel-spaces (string)
  "Return complete STRING lines with cumulative whole-pixel space extents.
Keep raw layout strings and their cached geometry private.  Only the final
output copy changes: equal line boundaries share the same rounding regardless
of text alignment, blank fill, borders, padding, or sibling segmentation.
Ordinary glyph advances are whole pixels, so only fixed space extents affect
the fractional remainder.  Preserve zero-width glyphs and all other properties.
An already integral STRING is returned unchanged."
  (if (not (ebox--fractional-pixel-spaces-p string))
      string
    (let ((result (copy-sequence string))
          (start 0)
          (end (length string)))
      (while (< start end)
        (let* ((line-end (or (string-match "\n" string start) end))
               (position start)
               positions widths)
          (while (< position line-end)
            (let* ((next (next-single-property-change
                          position 'display string line-end))
                   (width (ebox--fixed-pixel-space-width
                           (get-text-property position 'display string))))
              (when width
                (push (cons position next) positions)
                (push width widths))
              (setq position next)))
          (cl-mapc
           (lambda (range used)
             (let ((display (get-text-property (car range) 'display string)))
               (unless (= used (ebox--fixed-pixel-space-width display))
                 (let ((updated (cons 'space (copy-sequence (cdr display)))))
                   (setcdr updated (plist-put (cdr updated) :width (list used)))
                   (put-text-property
                    (car range) (cdr range) 'display
                    (ebox--register-render-owned-text-value 'display updated)
                    result)))))
           (nreverse positions) (ebox-size-quantize (nreverse widths)))
          (setq start (1+ line-end))))
      result)))

(defun ebox--string-with-text-scale (string factor)
  "Return STRING with FACTOR applied as an explicit face height."
  (if (= factor 1.0)
      string
    (let ((copy (copy-sequence string)))
      (add-face-text-property 0 (length copy) `(:height ,factor) t copy)
      copy)))

(defun ebox--face-height-affects-width-p (factor)
  "Return non-nil when `string-pixel-width' honors explicit face FACTOR."
  (or (= factor 1.0)
      (let ((cached (assoc factor ebox--face-height-width-cache)))
        (if cached
            (cdr cached)
          (let* ((probe "MMMMmmmm")
                 (plain (string-pixel-width probe))
                 (scaled (string-pixel-width
                          (ebox--string-with-text-scale probe factor)))
                 (works (/= scaled plain)))
            (push (cons factor works) ebox--face-height-width-cache)
            works)))))

(defun ebox--scaled-string-pixel-width (string factor)
  "Return pixel width of STRING under text-scale FACTOR."
  (let ((plain (string-pixel-width string)))
    (cond
     ((= factor 1.0) plain)
     ((ebox--face-height-affects-width-p factor)
      (string-pixel-width (ebox--string-with-text-scale string factor)))
     (t
      (ceiling (* plain factor))))))

(defun ebox--clear-string-pixel-width-cache ()
  "Clear display-scoped reusable string measurements and eviction state."
  (clrhash ebox--string-pixel-width-cache)
  (fillarray ebox--string-pixel-width-cache-ring nil)
  (setq ebox--string-pixel-width-cache-ring-index 0))

(defun ebox--string-pixel-width-visual-key
    (line factor &optional start end)
  "Return a width cache key for LINE slice at FACTOR.
START and END default to the complete string; visual properties must be
constant across the selected slice."
  (let ((start (or start 0))
        (end (or end (length line))))
    (list factor
          (substring-no-properties line start end)
          (cl-loop for property in '(face display)
                   for value = (and (> end start)
                                    (get-text-property start property line))
                   when value append (list property value)))))

(defun ebox--string-pixel-width-cache-key (line factor)
  "Return a safe display-scoped measurement key for LINE at FACTOR."
  (let* ((end (length line))
         ;; Ebox layout text uses `face' and `display' as its width-bearing
         ;; properties.  Ownership/region metadata is deliberately ignored;
         ;; the other generic text properties are not emitted by Ebox's
         ;; layout pipeline and would make this hot key scan needlessly broad.
         (constant-p
          (and (= (or (next-single-property-change 0 'face line end) end)
                  end)
               (= (or (next-single-property-change 0 'display line end) end)
                  end))))
    (and constant-p
         (ebox--string-pixel-width-visual-key line factor))))

(defun ebox--cached-string-pixel-width
    (line factor key &optional start end)
  "Return LINE slice width at FACTOR through both caches at KEY."
  (let ((cached
         (or (and ebox--render-string-pixel-width-cache
                  (gethash key ebox--render-string-pixel-width-cache))
             (gethash key ebox--string-pixel-width-cache))))
    (if cached
        (progn
          (when ebox--render-string-pixel-width-cache
            (puthash key cached ebox--render-string-pixel-width-cache))
          cached)
      (let* ((sample (if (or start end)
                         (substring line (or start 0) (or end (length line)))
                       line))
             (space-width
              (and (> (length sample) 0)
                   (ebox--display-space-width
                    (get-text-property 0 'display sample))))
             ;; This cache key proves uniform visual properties.  Preserve
             ;; display-space fractions just as the segmented path does;
             ;; Emacs's glyph measurement quantizes them before padding.
             (width (if space-width
                        space-width
                      (ebox--scaled-string-pixel-width sample factor)))
             (index ebox--string-pixel-width-cache-ring-index)
             (evicted (aref ebox--string-pixel-width-cache-ring index)))
        (when ebox--render-string-pixel-width-cache
          (puthash key width ebox--render-string-pixel-width-cache))
        (when evicted
          (remhash evicted ebox--string-pixel-width-cache))
        (puthash key width ebox--string-pixel-width-cache)
        (aset ebox--string-pixel-width-cache-ring index key)
        (setq ebox--string-pixel-width-cache-ring-index
              (mod (1+ index)
                   ebox--string-pixel-width-cache-max-entries))
        width))))

(defun ebox--string-pixel-width (string)
  "Return the display pixel width of STRING's first line.
Text characters follow the current buffer text scale.  Fixed display spaces
keep their absolute pixel width."
  (ebox--ensure-display-cache-current)
  (let* ((source (or string ""))
         (newline (and (stringp source) (string-match "\n" source)))
         (line (if newline (substring source 0 newline) source))
         (factor (ebox--text-scale-factor))
         (pos 0)
         (end (length line))
         (total 0)
         (cache-key (ebox--string-pixel-width-cache-key line factor)))
    (if cache-key
        (ebox--cached-string-pixel-width line factor cache-key)
      (while (< pos end)
        (let* ((display (get-text-property pos 'display line))
               (space-width (ebox--display-space-width display))
               (next
                (if (or (stringp display)
                        (memq (car-safe display) '(space image)))
                    ;; Emacs replaces an entire EQ display run once.  Face
                    ;; boundaries inside it do not create additional glyphs.
                    (next-single-property-change pos 'display line end)
                  (cl-loop for property in '(face display)
                           minimize (or (next-single-property-change
                                         pos property line end)
                                        end)))))
          (setq total
                (+ total
                   (if space-width
                       space-width
                     ;; The segment ends at every visual property change.
                     ;; Build only its property-free cache key on hits; a
                     ;; propertized substring is materialized solely on miss.
                     (let ((segment-key
                            (ebox--string-pixel-width-visual-key
                             line factor pos next)))
                       (ebox--cached-string-pixel-width
                        line factor segment-key pos next)))))
          (setq pos next)))
      total)))

(defun ebox--string-max-pixel-width (string)
  "Return the maximum display pixel width across STRING's lines."
  (if (string-empty-p string)
      0
    (let* ((cache ebox--render-string-max-pixel-width-cache)
           (missing (make-symbol "ebox-string-max-pixel-width-missing"))
           (cached (if cache
                       (gethash string cache missing)
                     missing)))
      (if (not (eq cached missing))
          cached
        (let ((width (apply #'max
                            (mapcar #'ebox--string-pixel-width
                                    (ebox-string-lines string)))))
          (when cache
            (puthash string width cache))
          width)))))

(defun ebox--measurement-face-remapping ()
  "Return face remaps that can affect geometric text measurement.  Ebox
publication paint slots are stable paint-layer addresses.  Their
foreground/background updates change redisplay without changing glyph
geometry, so installing or switching those layers must not invalidate Ebox
measurement caches."
  (when (boundp 'face-remapping-alist)
    (cl-remove-if
     (lambda (entry)
       (let ((face (car-safe entry)))
         (and (symbolp face)
              (string-match-p "\\`ebox-paint-slot-" (symbol-name face)))))
     face-remapping-alist)))

;;;###autoload
(defun ebox-string-pixel-width (string)
  "Return the display pixel width of STRING's first line.
This is the public, text-scale-aware measurement used by Ebox layout code."
  (ebox--string-pixel-width string))

(defun ebox--display-signature-for-frame (frame)
  "Return the pixel-measurement capability signature for FRAME."
  (list frame
        (frame-parameter frame 'font)
        (frame-parameter frame 'font-backend)
        (frame-parameter frame 'line-spacing)
        (face-attribute 'default :family frame t)
        (face-attribute 'default :height frame t)
        (face-attribute 'default :weight frame t)
        (face-attribute 'default :slant frame t)
        (face-attribute 'default :width frame t)
        ;; `face-remap-add-relative' can replace an existing entry's tail.
        ;; A retained display proof must keep its accepted remapping values.
        (copy-tree (ebox--measurement-face-remapping))
        (and (boundp 'text-scale-mode-amount) text-scale-mode-amount)
        (and (boundp 'text-scale-mode-step) text-scale-mode-step)))

(defun ebox--display-signature-for-window (window)
  "Return the pixel-measurement capability signature for live WINDOW."
  (ebox--display-signature-for-frame
   (if (window-live-p window) (window-frame window) (selected-frame))))

(defun ebox--display-signature ()
  "Return the selected frame's pixel-measurement capability signature."
  (ebox--display-signature-for-frame (selected-frame)))

(defsubst ebox--current-display-signature ()
  "Return the render snapshot or sample the current display signature."
  (or ebox--render-display-signature
      (ebox--display-signature)))

;;;###autoload
(defun ebox-display-signature ()
  "Return the current display signature used for pixel measurements."
  (ebox--display-signature))

(defun ebox--validate-display-cache ()
  "Clear pixel caches when the current display signature changed."
  (let ((signature (ebox--current-display-signature)))
    (unless (equal signature ebox--display-signature-cache)
      (clrhash ebox--char-width-cache)
      (ebox--clear-string-pixel-width-cache)
      (setq ebox--space-pixel-cache nil)
      (setq ebox--face-height-width-cache nil)
      (setq ebox--display-signature-cache signature))))

(defun ebox--ensure-display-cache-current ()
  "Validate the display cache unless it was already validated for this render.
Rebuilding the display signature is comparatively expensive, so a single
render validates it once via `ebox--with-validated-display-cache' and every
inner measurement skips the check."
  (unless ebox--display-cache-validated
    (ebox--validate-display-cache)))

(defmacro ebox--with-validated-display-cache (&rest body)
  "Validate the display cache once, then run BODY without re-validating.
Nested uses reuse the outer validation."
  (declare (indent 0) (debug t))
  `(if ebox--display-cache-validated
       (progn ,@body)
     (let ((ebox--display-cache-validated t)
           (ebox--render-display-signature
            (or ebox--render-display-signature
                (ebox--display-signature))))
       (let ((ebox--render-string-pixel-width-cache
              (make-hash-table :test 'equal))
             (ebox--render-string-max-pixel-width-cache
              (make-hash-table :test 'eq))
             (ebox--render-recached-source-node-cache
              (make-hash-table :test 'eq)))
         (ebox--validate-display-cache)
         ,@body))))

(defsubst ebox--char-pixel-width (char)
  "Get the pixel width of CHAR, using cache."
  (ebox--ensure-display-cache-current)
  (or (gethash char ebox--char-width-cache)
      (puthash char (ebox--string-pixel-width (char-to-string char))
               ebox--char-width-cache)))

(defsubst ebox--substring-pixel-width (string start end)
  "Return STRING width from START to END, preserving text properties."
  (ebox--string-pixel-width (substring string start end)))

(defun ebox--space-pixel-width ()
  "Get the pixel width of a space character, using cache."
  (ebox--ensure-display-cache-current)
  (or ebox--space-pixel-cache
      (setq ebox--space-pixel-cache (ebox--string-pixel-width " "))))

;;;###autoload
(defun ebox-clear-cache ()
  "Clear pixel width caches after font or named face metrics change."
  (clrhash ebox--char-width-cache)
  (ebox--clear-string-pixel-width-cache)
  (ebox-font-clear-cache)
  (setq ebox--space-pixel-cache nil)
  (setq ebox--face-height-width-cache nil)
  (setq ebox--display-signature-cache (ebox--display-signature)))

(defun ebox--init-ascii-cache ()
  "Pre-calculate cache for ASCII characters."
  (dotimes (i 128)
    (ebox--char-pixel-width i))
  (ebox--space-pixel-width))

(defsubst ebox-pixel-space (pixel-width)
  "Generate a space string with PIXEL-WIDTH.
Canonicalize whole pixels so equal computed lengths have identical display
properties.  Preserve a genuine fractional remainder until display."
  (if (or (null pixel-width) (<= pixel-width 0))
      ""
    (let* ((whole-pixels (truncate pixel-width))
           (pixel-width (if (= pixel-width whole-pixels)
                            whole-pixels pixel-width))
           (display
           (ebox--register-render-owned-text-value
            'display `(space :width (,pixel-width)))))
      (propertize " " 'display display))))

(defun ebox--pixel-blank (pixel-width height)
  "Generate a blank area of PIXEL-WIDTH and HEIGHT lines.
A zero pixel width still preserves the requested positive line height."
  (when (and pixel-width height (>= pixel-width 0) (> height 0))
    (ebox--string-repeat-lines
     (if (zerop pixel-width)
         (ebox-lines-join '(""))
       (ebox-pixel-space pixel-width))
     height)))

(defun ebox--pixel-pad (string prefix-pixel &optional suffix-pixel)
  "Pad STRING with pixel spaces on left (PREFIX-PIXEL) and right (SUFFIX-PIXEL)."
  (concat (ebox-pixel-space (or prefix-pixel 0))
          string
          (ebox-pixel-space (or suffix-pixel 0))))

(defun ebox--pixel-reach (string total-pixel &optional align)
  "Extend STRING to TOTAL-PIXEL width.
ALIGN can be `left', `center', or `right'."
  (let* ((string-pixel (ebox--string-pixel-width string))
         (rest-pixel (max 0 (- total-pixel string-pixel)))
         (align (or align 'left))
         (left-pixel (pcase align
                       ('left 0)
                       ('right rest-pixel)
                       ('center (/ rest-pixel 2))
                       (_ 0))))
    (ebox--pixel-pad string left-pixel (- rest-pixel left-pixel))))

(defsubst ebox-pixel-left (string total-pixel)
  "Align STRING to the left within TOTAL-PIXEL."
  (ebox--pixel-reach string total-pixel 'left))

(defsubst ebox-pixel-center (string total-pixel)
  "Align STRING to the center within TOTAL-PIXEL."
  (ebox--pixel-reach string total-pixel 'center))

(defsubst ebox-pixel-right (string total-pixel)
  "Align STRING to the right within TOTAL-PIXEL."
  (ebox--pixel-reach string total-pixel 'right))

;; Initialize measurement cache after all measurement helpers are defined.
(ebox--init-ascii-cache)

(provide 'ebox-measure)

;;; ebox-measure.el ends here
