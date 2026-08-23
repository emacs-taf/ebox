;;; ebox-measure.el --- Pixel measurement helpers for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns display-signature-sensitive measurement caches and text/space width
;; helpers.  It does not own layout decisions or dirty classification.

;;; Code:

(require 'cl-lib)
(require 'ebox-cache)

(declare-function ebox--register-render-owned-text-value
                  "ebox-render-context" (property value))

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
  (when (and (consp display) (eq (car display) 'space))
    (let ((width (plist-get (cdr display) :width)))
      (cond
       ((numberp width) width)
       ((and (consp width) (numberp (car width))) (car width))))))

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

(defun ebox--string-pixel-width-visual-key (line factor)
  "Return a width cache key for LINE at FACTOR when visual properties are constant."
  (let ((end (length line)))
    (list factor
          (substring-no-properties line)
          (cl-loop for property in '(face display)
                   for value = (and (> end 0)
                                    (get-text-property 0 property line))
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

(defun ebox--cached-string-pixel-width (line factor key)
  "Return LINE width at FACTOR through the render and display caches at KEY."
  (let ((cached
         (or (and ebox--render-string-pixel-width-cache
                  (gethash key ebox--render-string-pixel-width-cache))
             (gethash key ebox--string-pixel-width-cache))))
    (if cached
        (progn
          (when ebox--render-string-pixel-width-cache
            (puthash key cached ebox--render-string-pixel-width-cache))
          cached)
      (let* ((width (ebox--scaled-string-pixel-width line factor))
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
               (next
                (cl-loop for property in
                         '(face display)
                         minimize (or (next-single-property-change
                                       pos property line end)
                                      end)))
               (segment (substring line pos next))
               ;; The segment ends at every visual property change, so its
               ;; width key can skip the second constant-property scan.
               (segment-key
                (ebox--string-pixel-width-visual-key segment factor))
               (space-width (ebox--display-space-width display)))
          (setq total
                (+ total
                   (if space-width
                       (* space-width (- next pos))
                     (if segment-key
                         (ebox--cached-string-pixel-width
                          segment factor segment-key)
                       (ebox--scaled-string-pixel-width
                        segment factor)))))
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

;;;###autoload
(defun ebox-string-pixel-width (string)
  "Return the display pixel width of STRING's first line.
This is the public, text-scale-aware measurement used by Ebox layout code."
  (ebox--string-pixel-width string))

(defun ebox--display-signature ()
  "Return the current display signature for pixel measurement caches."
  (list (frame-parameter nil 'font)
        (frame-parameter nil 'font-backend)
        (frame-parameter nil 'line-spacing)
        (frame-parameter nil 'internal-border-width)
        (face-attribute 'default :family nil t)
        (face-attribute 'default :height nil t)
        (face-attribute 'default :weight nil t)
        (face-attribute 'default :slant nil t)
        (face-attribute 'default :width nil t)
        (face-attribute 'default :foreground nil t)
        (face-attribute 'default :background nil t)
        (and (boundp 'face-remapping-alist) face-remapping-alist)
        (and (boundp 'text-scale-mode-amount) text-scale-mode-amount)))

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
  (setq ebox--space-pixel-cache nil)
  (setq ebox--face-height-width-cache nil)
  (setq ebox--display-signature-cache (ebox--display-signature)))

(defun ebox--init-ascii-cache ()
  "Pre-calculate cache for ASCII characters."
  (dotimes (i 128)
    (ebox--char-pixel-width i))
  (ebox--space-pixel-width))

(defsubst ebox-pixel-space (pixel-width)
  "Generate a space string with PIXEL-WIDTH."
  (if (or (null pixel-width) (<= pixel-width 0))
      ""
    (let ((display
           (ebox--register-render-owned-text-value
            'display `(space :width (,pixel-width)))))
      (propertize " " 'display display))))

(defun ebox--pixel-blank (pixel-width height)
  "Generate a blank area of PIXEL-WIDTH and HEIGHT lines."
  (when (and pixel-width height (> pixel-width 0) (> height 0))
    (ebox--string-repeat-lines (ebox-pixel-space pixel-width) height)))

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
