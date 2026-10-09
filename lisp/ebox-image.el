;;; ebox-image.el --- Prepared character-grid image content -*- lexical-binding: t; -*-

;;; Commentary:
;; Image preparation owns I/O, capability selection and immutable cell rasters.
;; Image nodes and text content lay out the prepared lines; no decoder,
;; process or image constructor runs during layout or buffer writes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'image)
(require 'ansi-color)
(require 'ebox-measure)

(cl-defstruct (ebox-image--prepared (:constructor ebox-image--make-prepared))
  "Immutable, detached raster prepared for one character allocation."
  columns rows adapter converter text lines width)

(defvar ebox-image-converters
  '((chafa . ebox-image--chafa) (ffmpeg . ebox-image--ffmpeg))
  "Ordered (NAME . FUNCTION) image converters, called only by preparation.
FUNCTION receives SOURCE, COLUMNS, ROWS.  SOURCE is a local absolute file name
or an owned Emacs image descriptor.  Return nil to decline, or a string of
exactly ROWS lines of COLUMNS `▀' characters, each with a `face' plist
containing 24-bit :foreground and :background strings (#RRGGBB).
No trailing newline.
Errors and malformed results decline to the next converter.  Functions must
not mutate SOURCE.  Change NAME or clear the image cache when behavior changes.
The defaults try chafa's truecolor symbols, then ffmpeg's scaled raw RGB.
Neither executable is a package dependency; nil selects the placeholder.")

(defvar ebox-image--cache (make-hash-table :test #'equal)
  "Bounded cache of prepared image rasters, independent of mounted buffers.")

(defconst ebox-image--cache-limit 64
  "Maximum cached preparations; live prepared values survive eviction.")

(defun ebox-image-cache-clear ()
  "Release cached preparations without changing live image content.
Call after installing converters or changing their configuration."
  (clrhash ebox-image--cache))

(defun ebox-image--source (source)
  "Validate SOURCE and return an owned source and its cache identity."
  (cond
   ((stringp source)
    (when (file-remote-p source)
      (error "Ebox image sources must be local files"))
    (let* ((path (expand-file-name source))
           (attrs (file-attributes path 'integer)))
      (list path
            (list path (and attrs (file-truename path))
                  (and attrs (list (file-attribute-size attrs)
                                   (file-attribute-modification-time attrs)
                                   (file-attribute-status-change-time attrs)
                                   (file-attribute-inode-number attrs)))))))
   ((and (consp source) (eq (car source) 'image)
         (proper-list-p (cdr source))
         (zerop (% (length (cdr source)) 2))
         (symbolp (plist-get (cdr source) :type))
         (or (stringp (plist-get (cdr source) :data))
             (stringp (plist-get (cdr source) :file))))
    (let ((owned (copy-tree source)))
      (if-let* ((file (plist-get (cdr owned) :file))
                (normalized (ebox-image--source file)))
          (progn
            (setcdr owned (plist-put (cdr owned) :file (car normalized)))
            (list owned (list owned (cadr normalized))))
        (list owned owned))))
   (t (error "Ebox image source must be a file or image descriptor"))))

(defun ebox-image--metrics (frame)
  "Return FRAME's (CELL-WIDTH LINE-HEIGHT ASCENT-PERCENT), or nil.
Use the default font's actual ascent, never a minimum pixel height."
  (when (display-graphic-p frame)
    (let* ((info (ignore-errors (font-info (face-font 'default frame) frame)))
           (width (frame-char-width frame))
           (height (frame-char-height frame))
           (ascent (and info (> (length info) 9) (aref info 8))))
      (when (and (integerp width) (> width 0)
                 (integerp height) (> height 0)
                 (integerp ascent) (<= 0 ascent height))
        ;; Redisplay truncates HEIGHT * PERCENT / 100.  Rounding the
        ;; percentage down adds a descent pixel and expands every row.
        (let ((percent (ceiling (* 100 ascent) height)))
          (when (= (floor (* height percent) 100) ascent)
            (list width height percent)))))))

(defun ebox-image--bytes (source)
  "Read SOURCE bytes during preparation, never during rendering."
  (if-let* ((data (and (consp source) (plist-get (cdr source) :data))))
      (if (multibyte-string-p data) (encode-coding-string data 'utf-8-unix) data)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally
       (if (stringp source) source (plist-get (cdr source) :file)))
      (buffer-string))))

(defun ebox-image--grid (columns rows character cell)
  "Build COLUMNS by ROWS of CHARACTER, using CELL for each cell's properties."
  (mapconcat
   (lambda (y)
     (let ((line (make-string columns character)))
       (dotimes (x columns)
         (add-text-properties x (1+ x) (funcall cell x y) line))
       line))
   (number-sequence 0 (1- rows)) "\n"))

(defun ebox-image--slice (descriptor width y height ascent lh inset)
  "Return a WIDTH-pixel display slice of DESCRIPTOR from Y, HEIGHT tall.
A slice shorter than line height LH sits at the line's bottom, or with
INSET bottom at its top, so the line keeps its height.  ASCENT is the
descriptor's ascent percentage."
  (let ((slice (list 'slice 0 y width height)))
    (if (= height lh)
        (list slice descriptor)
      ;; Redisplay gives a slice HEIGHT * ASCENT / 100 pixels of ascent; raise
      ;; moves it to the font's ascent at the top or descent at the bottom.
      (let* ((font-ascent (floor (* lh ascent) 100))
             (own (floor (* height ascent) 100))
             (want (if (eq inset 'bottom) font-ascent (- height (- lh font-ascent)))))
        (list (list 'raise (/ (float (- want own)) lh)) slice descriptor)))))

(defun ebox-image--graphics (source columns rows metrics frame &optional inset)
  "Prepare SOURCE as COLUMNS by ROWS display slices using METRICS on FRAME.
INSET is (TOP . BOTTOM) pixels left empty above and below the image."
  (let* ((data (ebox-image--bytes source))
         (type (image-type data (and (consp source)
                                     (plist-get (cdr source) :type)) t)))
    (when (image-type-available-p type)
      (pcase-let* ((`(,cw ,lh ,ascent) metrics)
                   (top (min (or (car inset) 0) (1- lh)))
                   (bottom (min (or (cdr inset) 0) (1- lh)))
                   (width (* columns cw))
                   (height (- (* rows lh) top bottom))
                   (descriptor (and (> height 0)
                                    (create-image data type t :width width :height height
                                                  :scale 1 :ascent ascent :margin 0))))
        ;; A type that cannot decode/scale this source is not usable.  Decoding
        ;; here also warms Emacs' cache before a caller publishes the block.
        ;; Each row is one glyph showing a full-width slice: redisplay
        ;; draws an image once per glyph, so per-cell slices multiply the
        ;; cost of every scroll and repaint by the column count.
        (when (and descriptor (equal (image-size descriptor t frame)
                                     (cons width height)))
          (mapconcat
           (lambda (y)
             (let* ((start (max 0 (- (* y lh) top)))
                    (end (min height (- (* (1+ y) lh) top))))
               (propertize " " 'display
                           (ebox-image--slice descriptor width start (- end start) ascent lh
                                              (and (= y (1- rows)) (> bottom 0)
                                                   'bottom)))))
           (number-sequence 0 (1- rows)) "\n"))))))

(defun ebox-image--run (source program arguments)
  "Run PROGRAM with ARGUMENTS on SOURCE, returning bytes only on success."
  (when-let* ((executable (executable-find program)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let* ((coding-system-for-read 'binary)
             (coding-system-for-write 'binary)
             (data (and (consp source) (plist-get (cdr source) :data)
                        (ebox-image--bytes source)))
             (file (if (stringp source) source (plist-get (cdr source) :file)))
             (args (mapcar (lambda (arg) (if (eq arg :input)
                                               (if data "-" file) arg))
                           arguments))
             (status
              (if data
                  (progn
                    (insert data)
                    (apply #'call-process-region (point-min) (point-max)
                           executable t (list t nil) nil args))
                (apply #'call-process executable nil (list t nil) nil args))))
        (when (eql status 0) (buffer-string))))))

(defun ebox-image--ansi-face (face property)
  "Read PROPERTY from the plists in ANSI FACE."
  (if (keywordp (car-safe face)) (plist-get face property)
    (cl-loop for item in face thereis (and (listp item) (plist-get item property)))))

(defun ebox-image--chafa (source columns rows)
  "Convert SOURCE to a COLUMNS by ROWS truecolor half-block grid with chafa."
  (when-let* ((bytes
               (ebox-image--run
                source "chafa"
                (list "--format=symbols" "--colors=full" "--symbols=u2580"
                      "--fill=none" "--optimize=0" "--relative=off"
                      "--animate=off" "--stretch" "--polite=on" "--probe=off"
                      "--bg=#000000" "--size" (format "%dx%d" columns rows)
                      :input))))
    (let* ((ansi-color-apply-face-function #'ansi-color-apply-text-property-face)
           (text (ansi-color-apply (decode-coding-string bytes 'utf-8-unix)))
           (text (string-remove-suffix "\n" text))
           (result (substring-no-properties text)))
      (dotimes (i (length text))
        (unless (= (aref text i) ?\n)
          (let ((face (get-text-property i 'font-lock-face text)))
            (put-text-property
             i (1+ i) 'face
             (list :foreground (ebox-image--ansi-face face :foreground)
                   :background (ebox-image--ansi-face face :background)) result))))
      result)))

(defun ebox-image--ffmpeg (source columns rows)
  "Convert SOURCE to COLUMNS by ROWS using ffmpeg's two RGB pixels per cell."
  (when-let* ((bytes
               (ebox-image--run
                source "ffmpeg"
                (list "-v" "error" "-nostdin" "-i" :input
                      "-vf" (format "scale=%d:%d:flags=area" columns (* 2 rows))
                      "-frames:v" "1" "-f" "rawvideo" "-pix_fmt" "rgb24" "pipe:1"))))
    (when (= (length bytes) (* columns rows 6))
      (cl-labels ((rgb (x y)
                   (let ((offset (* 3 (+ x (* y columns)))))
                     (format "#%02x%02x%02x" (aref bytes offset)
                             (aref bytes (+ offset 1)) (aref bytes (+ offset 2))))))
        (ebox-image--grid columns rows ?▀
                          (lambda (x y)
                            (list 'face (list :foreground (rgb x (* y 2))
                                              :background (rgb x (1+ (* y 2)))))))))))

(defun ebox-image--valid-grid-p (text columns rows)
  "Whether TEXT is a safe COLUMNS by ROWS truecolor converter result."
  (and (stringp text)
       (= (length text) (+ (* columns rows) (1- rows)))
       (cl-loop for i below (length text)
                always
                (if (= (% i (1+ columns)) columns)
                    (= (aref text i) ?\n)
                  (and (= (aref text i) ?▀)
                       (let ((face (get-text-property i 'face text)))
                         (cl-every
                          (lambda (key)
                            (let ((color (plist-get face key)))
                              (and (stringp color)
                                   (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color))))
                          '(:foreground :background))))))))

(cl-defun ebox-image-prepare (source columns rows &key (adapter 'auto)
                                   (frame (selected-frame)) inset
                                   (converters ebox-image-converters))
  "Prepare SOURCE for an integer COLUMNS by ROWS character area.
Return an opaque reusable value; inspect it with `ebox-image-info'.  SOURCE
is a local file or an Emacs image descriptor containing :file or :data.
ADAPTER is auto, text, or placeholder.  Auto tries graphics on FRAME with a
usable image type and font metrics, then CONVERTERS, then a monochrome ASCII
placeholder.  Text skips graphics.  Placeholder skips both.  CONVERTERS obeys
`ebox-image-converters'.  Missing/corrupt images also become placeholders.
INSET is nil or (TOP . BOTTOM), pixels below one line height that a graphics
image leaves empty above and below it inside its rows; the image scales
into the rest, and the gap shows the box background.
This is the only I/O/decoding step: call outside the render/commit hot path.
Repeat after source or frame/font changes; identical preparations are cached."
  (unless (and (integerp columns) (> columns 0) (integerp rows) (> rows 0))
    (error "Ebox image columns and rows must be positive integers"))
  (unless (memq adapter '(auto text placeholder))
    (error "Unknown Ebox image adapter: %S" adapter))
  (unless (or (null inset)
              (and (consp inset) (natnump (car inset)) (natnump (cdr inset))))
    (error "Ebox image inset must be nil or (TOP . BOTTOM) pixels"))
  (unless (and (proper-list-p converters)
               (cl-every (lambda (entry)
                           (and (consp entry) (symbolp (car entry))
                                (functionp (cdr entry)))) converters))
    (error "Invalid Ebox image converter protocol"))
  (pcase-let* ((`(,owned ,identity) (ebox-image--source source))
               (metrics (and (eq adapter 'auto) (ebox-image--metrics frame)))
               (key (list identity columns rows adapter metrics inset
                          (and metrics image-types) (copy-tree converters)))
               (cached (gethash key ebox-image--cache)))
    (or cached
        (let ((text (and metrics
                         (ignore-errors
                           (ebox-image--graphics owned columns rows metrics frame inset))))
              (selected 'graphics) converter)
          (unless text
            (setq selected 'text)
            (unless (eq adapter 'placeholder)
              (catch 'converted
                (dolist (entry converters)
                  (let ((result (ignore-errors
                                  (funcall (cdr entry) owned columns rows))))
                    (when (ignore-errors (ebox-image--valid-grid-p result columns rows))
                      ;; Rebuild just the allowed properties: converters cannot
                      ;; inject display, keymap or ownership into publication.
                      (setq text (substring-no-properties result)
                            converter (car entry))
                      (dotimes (i (length result))
                        (unless (= (aref result i) ?\n)
                          (let ((face (get-text-property i 'face result)))
                            (put-text-property
                             i (1+ i) 'face
                             (list :foreground (copy-sequence (plist-get face :foreground))
                                   :background (copy-sequence (plist-get face :background)))
                             text))))
                      (throw 'converted t)))))))
          (unless text
            (setq selected 'placeholder
                  text (ebox-image--grid columns rows ?. (lambda (_x _y) nil))))
          (let ((prepared (ebox-image--make-prepared
                           :columns columns :rows rows :adapter selected
                           :converter converter :text text)))
            (when (>= (hash-table-count ebox-image--cache) ebox-image--cache-limit)
              (clrhash ebox-image--cache))
            (puthash key prepared ebox-image--cache)
            prepared)))))

(defun ebox-image--check (prepared)
  "Validate PREPARED and return it."
  (unless (ebox-image--prepared-p prepared)
    (error "Expected a value from ebox-image-prepare"))
  prepared)

(defun ebox-image-info (prepared)
  "Return PREPARED's adapter, converter, columns and rows as a fresh plist."
  (ebox-image--check prepared)
  (list :adapter (ebox-image--prepared-adapter prepared)
        :converter (ebox-image--prepared-converter prepared)
        :columns (ebox-image--prepared-columns prepared)
        :rows (ebox-image--prepared-rows prepared)))

(defun ebox-image-content (prepared)
  "Return an owned character string for PREPARED, without any I/O.
Lines are separated by newlines.  Graphics display values are shared
descriptors and slices: do not mutate those nested values."
  (ebox-image--check prepared)
  (copy-sequence (ebox-image--prepared-text prepared)))

(defun ebox-image--lines (prepared)
  "Return PREPARED's raster as a list of line strings."
  (or (ebox-image--prepared-lines prepared)
      (setf (ebox-image--prepared-lines prepared)
            (split-string (ebox-image--prepared-text prepared) "\n"))))

(defun ebox-image--width (prepared)
  "Return PREPARED's raster width in pixels."
  (let ((width (ebox-image--prepared-width prepared)))
    (if (and width (eq (car width) ebox--width-epoch)) (cdr width)
      (cdr (setf (ebox-image--prepared-width prepared)
                 (cons ebox--width-epoch
                       (apply #'max 0 (mapcar #'ebox-string-pixel-width
                                              (ebox-image--lines prepared)))))))))

(provide 'ebox-image)
;;; ebox-image.el ends here
