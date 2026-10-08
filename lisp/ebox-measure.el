;;; ebox-measure.el --- Pixel measurement for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Measures display widths of text under one face.  Plain characters are
;; measured once per font face and cached; grapheme clusters, display
;; properties and caller faces fall back to `string-pixel-width'.  The
;; measuring buffer's face remapping (including text scale) selects the cache.

;;; Code:

(require 'cl-lib)

(defvar ebox--measure-buffer nil
  "Buffer whose face remapping applies to measurements, or nil.")

(defvar ebox--width-tables (make-hash-table :test 'eq :weakness 'key)
  "Map of remapping identity to per-face width tables.")

(defvar ebox--default-width-table (make-hash-table :test 'equal)
  "Per-face width tables without buffer face remapping.")

(defvar ebox--cluster-width-cache (make-hash-table :test 'equal)
  "Width cache for multi-character clusters keyed by (FACE . STRING).")

(defvar ebox--width-epoch 0
  "Counter incremented whenever measurement caches are cleared.")

(defun ebox--remap-key ()
  "Return the remapping identity of the measuring buffer, or nil."
  (and ebox--measure-buffer (buffer-live-p ebox--measure-buffer)
       (buffer-local-value 'face-remapping-alist ebox--measure-buffer)))

(defconst ebox--paint-only-attributes
  '(:foreground :background :distant-foreground :underline :overline
    :strike-through :extend :stipple)
  "Face attributes that never change glyph advances.")

(defun ebox--width-face (face)
  "Return the face whose metrics FACE shares for width measurement.
A plist naming only paint attributes measures like the default face, and a
list of faces drops such members."
  (cond ((atom face) face)
        ((keywordp (car face))
         (let ((rest face))
           (while (and rest (memq (car rest) ebox--paint-only-attributes))
             (setq rest (cddr rest)))
           (and rest face)))
        (t (let ((kept (delq nil (mapcar #'ebox--width-face face))))
             (if (cdr kept) kept (car kept))))))

(defun ebox--merge-face (own face)
  "Return the face list painting text face OWN over node FACE."
  (cond ((null face) own)
        ((and (consp own) (not (keywordp (car own)))) (append own (list face)))
        (t (list own face))))

(defvar ebox--face-memo (make-vector 3 nil)
  "The last [REMAP-KEY FACE TABLE] lookup of `ebox--face-table'.")

(defun ebox--face-table (face)
  "Return the width table of FACE for the current measuring context.
Faces with equal width attributes share one table: painting conses fresh
face plists, which must not re-measure every character."
  (let ((key (ebox--remap-key))
        (memo ebox--face-memo))
    (if (and (aref memo 2) (eq face (aref memo 1)) (eq key (aref memo 0)))
        (aref memo 2)
      (let* ((tables (if key
                         (or (gethash key ebox--width-tables)
                             (puthash key (make-hash-table :test 'equal)
                                      ebox--width-tables))
                       ebox--default-width-table))
             (table
              (or (gethash face tables)
                  (puthash face
                           (let ((width-face (ebox--width-face face)))
                             (or (gethash width-face tables)
                                 (puthash width-face
                                          (cons (make-vector 128 nil)
                                                (make-hash-table :test 'eq))
                                          tables)))
                           tables))))
        (aset memo 0 key)
        (aset memo 1 face)
        (aset memo 2 table)
        table))))

(defun ebox--measure-raw (string)
  "Measure STRING with `string-pixel-width' in the measuring buffer."
  (if (and ebox--measure-buffer (buffer-live-p ebox--measure-buffer))
      (string-pixel-width string ebox--measure-buffer)
    (string-pixel-width string)))

(defun ebox--char-width (char face)
  "Return the pixel width of CHAR displayed with FACE."
  (let* ((table (ebox--face-table face)))
    (if (< char 128)
        (let ((vector (car table)))
          (or (aref vector char)
              (aset vector char
                    (ebox--measure-raw
                     (if face (propertize (string char) 'face face)
                       (string char))))))
      (let ((hash (cdr table)))
        (or (gethash char hash)
            (puthash char
                     (ebox--measure-raw
                      (if face (propertize (string char) 'face face)
                        (string char)))
                     hash))))))

(defconst ebox--width-probe (concat (number-sequence 32 126) "汉")
  "Characters whose widths identify a face's horizontal metrics.")

(defun ebox--face-widths (face)
  "Return the widths of `ebox--width-probe' under FACE, measured once."
  (let ((table (cdr (ebox--face-table face))))
    (or (gethash 'probe table)
        (puthash 'probe (mapcar (lambda (char) (ebox--char-width char face))
                                ebox--width-probe)
                 table))))

(defun ebox--same-widths-p (a b)
  "Return non-nil when faces A and B give the probe characters equal widths.
A monospaced font keeps its advance across weights, so a weight change
under it repaints without moving text."
  (or (eq a b) (equal (ebox--face-widths a) (ebox--face-widths b))))

(defsubst ebox--cjk-char-p (char)
  "Return non-nil when CHAR breaks like a CJK ideograph."
  (and (>= char #x2E80)
       (or (<= char #x303F)
           (and (>= char #x3040) (<= char #x30FF))
           (and (>= char #x3400) (<= char #x4DBF))
           (and (>= char #x4E00) (<= char #x9FFF))
           (and (>= char #xAC00) (<= char #xD7AF))
           (and (>= char #xF900) (<= char #xFAFF))
           (and (>= char #xFF00) (<= char #xFFEF))
           (and (>= char #x20000) (<= char #x2FFFF)))))

(defsubst ebox--extension-char-p (char)
  "Return non-nil when CHAR extends the previous grapheme cluster."
  (and (>= char #x300)
       (or (<= char #x36F)
           (and (>= char #x1AB0) (<= char #x1AFF))
           (and (>= char #x1DC0) (<= char #x1DFF))
           (and (>= char #x20D0) (<= char #x20FF))
           (and (>= char #xFE00) (<= char #xFE0F))
           (and (>= char #xFE20) (<= char #xFE2F))
           (and (>= char #x1F3FB) (<= char #x1F3FF))
           (and (>= char #xE0100) (<= char #xE01EF))
           (eq char #x200D))))

(defsubst ebox--regional-indicator-p (char)
  "Return non-nil when CHAR is a regional indicator."
  (and (>= char #x1F1E6) (<= char #x1F1FF)))

(defun ebox--cluster-end (string start end)
  "Return the end of the grapheme cluster at START in STRING before END."
  (let ((next (1+ start)))
    (if (and (< (aref string start) 128)
             (or (>= next end) (< (aref string next) 128)))
        next
      (when (and (< next end)
                 (ebox--regional-indicator-p (aref string start))
                 (ebox--regional-indicator-p (aref string next)))
        (setq next (1+ next)))
      (while (and (< next end)
                  (or (ebox--extension-char-p (aref string next))
                      (eq (aref string (1- next)) #x200D)))
        (setq next (1+ next)))
      next)))

(defun ebox--plain-string-p (string)
  "Return non-nil when STRING carries no text properties."
  (and (null (text-properties-at 0 string))
       (null (next-property-change 0 string))))

(defun ebox--fixed-space-width (display)
  "Return the fixed pixel width of DISPLAY space spec, or nil."
  (when (and (eq (car-safe display) 'space)
             (not (plist-member (cdr display) :align-to)))
    (let ((width (plist-get (cdr display) :width)))
      (and (consp width) (numberp (car width)) (null (cdr width))
           (car width)))))

(defvar ebox--image-widths (make-hash-table :test 'eq :weakness 'key)
  "Map of image display specification to (REMAP-KEY . WIDTH).")

(defun ebox--display-width (string start end &optional face)
  "Measure display run START..END of STRING under FACE.
Fixed spaces need no measurement, and an image keeps its width while its
specification object and the measuring buffer's remapping stay the same."
  (let ((display (get-text-property start 'display string)))
    (or (ebox--fixed-space-width display)
        (if (eq (car-safe display) 'image)
            (let ((key (ebox--remap-key))
                  (cached (gethash display ebox--image-widths)))
              (if (and cached (eq (car cached) key))
                  (cdr cached)
                (cdr (puthash display
                              (cons key (ebox--measure-raw
                                         (substring string start end)))
                              ebox--image-widths))))
          (ebox--segment-width string start end face)))))

(defun ebox--segment-width (string start end face)
  "Measure STRING from START to END under FACE, honoring its properties."
  (let ((segment (substring string start end)))
    (when face
      (add-face-text-property 0 (length segment) face t segment))
    (ebox--measure-raw segment)))

(defun ebox--cluster-width (string start next face)
  "Return the width of cluster START..NEXT in plain STRING under FACE."
  (if (= next (1+ start))
      (ebox--char-width (aref string start) face)
    (let* ((text (substring-no-properties string start next))
           (key (cons face text)))
      (or (gethash key ebox--cluster-width-cache)
          (puthash key (ebox--measure-raw
                        (if face (propertize text 'face face) text))
                   ebox--cluster-width-cache)))))

(defun ebox--units (string face)
  "Return STRING's display units as a list of (START END WIDTH).
Plain grapheme clusters, runs sharing one replacing display property, and
fixed display spaces are one unit each.  FACE is the node's font face."
  (let ((pos 0) (len (length string)) units)
    (if (ebox--plain-string-p string)
        (while (< pos len)
          (let ((next (ebox--cluster-end string pos len)))
            (push (list pos next (ebox--cluster-width string pos next face))
                  units)
            (setq pos next)))
      (while (< pos len)
        (let* ((display (get-text-property pos 'display string))
               (space (and display (ebox--fixed-space-width display)))
               (next (if display
                         (or (next-single-property-change pos 'display string len)
                             len)
                       (ebox--cluster-end string pos len)))
               (width
                (cond (space space)
                      (display (ebox--display-width string pos next face))
                      ((get-text-property pos 'face string)
                       (ebox--cluster-width
                        string pos next
                        (ebox--merge-face (get-text-property pos 'face string)
                                          face)))
                      (t (ebox--cluster-width string pos next face)))))
          (push (list pos next width) units)
          (setq pos next))))
    (nreverse units)))

(defun ebox--text-width (string face)
  "Return the display width of one-line STRING under FACE."
  (if (and (ebox--plain-string-p string))
      (let ((pos 0) (len (length string)) (total 0))
        (while (< pos len)
          (let ((char (aref string pos)))
            (if (and (< char 128)
                     (let ((next (1+ pos)))
                       (or (>= next len) (< (aref string next) 128))))
                (setq total (+ total (ebox--char-width char face))
                      pos (1+ pos))
              (let ((next (ebox--cluster-end string pos len)))
                (setq total (+ total (ebox--cluster-width string pos next face))
                      pos next)))))
        total)
    (let ((total 0))
      (dolist (unit (ebox--units string face) total)
        (setq total (+ total (nth 2 unit)))))))

(defun ebox--line-width (line)
  "Return the display width of composed LINE, honoring its own faces."
  (let ((pos 0) (len (length line)) (total 0))
    (while (< pos len)
      (let* ((display (get-text-property pos 'display line))
             (space (and display (ebox--fixed-space-width display)))
             (next (if display
                       (or (next-single-property-change pos 'display line len) len)
                     (min (or (next-single-property-change pos 'face line len) len)
                          (or (next-single-property-change pos 'display line len)
                              len)))))
        (setq total
              (+ total
                 (cond (space space)
                       (display (ebox--display-width line pos next))
                       (t (ebox--text-width
                           (substring-no-properties line pos next)
                           (get-text-property pos 'face line))))))
        (setq pos next)))
    total))

(defvar ebox--space-cache (make-hash-table :test 'equal)
  "Interned pixel spaces keyed by (WIDTH . FACE).")

(defvar ebox--pad-displays (make-hash-table :test 'eq :weakness 'key)
  "Display specifications of interned pixel spaces.")

(defun ebox--space (width &optional face)
  "Return a one-character space WIDTH pixels wide painted with FACE.
Return the empty string when WIDTH is not positive."
  (if (<= width 0)
      ""
    (let ((key (cons width face)))
      (or (gethash key ebox--space-cache)
          (puthash key
                   (let* ((display (list 'space :width (list width)))
                          (string (propertize " " 'display display)))
                     (puthash display t ebox--pad-displays)
                     (when face (put-text-property 0 1 'face face string))
                     string)
                   ebox--space-cache)))))

(defun ebox--pad-display (string pos)
  "Return the interned pad display of STRING's character at POS, or nil."
  (let ((display (get-text-property pos 'display string)))
    (and display (gethash display ebox--pad-displays) display)))

(defun ebox--props-same-p (a b)
  "Return non-nil when text property lists A and B paint alike.
Painting conses fresh faces, which compare by value.  Display values compare
by identity, since Emacs joins adjacent characters with `eq' displays and the
buffer must keep exactly the composed line's objects; other values, such as
node records, compare by identity because `equal' would descend into the
tree they link to."
  (while (and a b (eq (car a) (car b))
              (let ((x (cadr a)) (y (cadr b)))
                (or (eq x y)
                    (and (eq (car a) 'face) (equal x y)))))
    (setq a (cddr a) b (cddr b)))
  (and (null a) (null b)))

(defvar ebox--pad-twins (make-hash-table :test 'eq :weakness 'key)
  "The alternate display of each interned pad display, in both directions.")

(defvar ebox--twin-strings (make-hash-table :test 'eq :weakness 'key)
  "One-character strings whose first pad shows its alternate display.")

(defun ebox--pad-twin (display)
  "Return the interned alternate of pad DISPLAY, an equal but distinct object."
  (or (gethash display ebox--pad-twins)
      (let ((twin (copy-sequence display)))
        (puthash twin t ebox--pad-displays)
        (puthash twin display ebox--pad-twins)
        (puthash display twin ebox--pad-twins))))

(defun ebox--twin-first (part display)
  "Return PART with its first character showing DISPLAY's alternate.
PART starts with pad DISPLAY.  When its second character already shows the
alternate, the first receives a fresh copy instead."
  (let ((twin (ebox--pad-twin display)))
    (if (= (length part) 1)
        (or (gethash part ebox--twin-strings)
            (puthash part (let ((copy (copy-sequence part)))
                            (put-text-property 0 1 'display twin copy)
                            copy)
                     ebox--twin-strings))
      (let ((copy (copy-sequence part)))
        (put-text-property 0 1 'display
                           (if (eq (get-text-property 1 'display part) twin)
                               (copy-sequence display)
                             twin)
                           copy)
        copy))))

(defun ebox--join-parts (parts)
  "Return the nonempty strings of PARTS as they compose one line.
PARTS is a tree: each element is a string or a nested list of parts, so a
node shares its children's cached parts without copying them.  Emacs draws
consecutive characters whose `display' values are `eq' as one element, so
two interned pads meeting at a junction would collapse into one.  Each
string is free of such pairs and only the junctions are examined: a string
starting with the pad that ends the previous one shows that pad's interned
alternate, which keeps the line's display objects stable across rewrites."
  (let ((kept nil) (last nil) (stack nil) (rest parts))
    (while (or rest stack)
      (if (null rest)
          (setq rest (pop stack))
        (let ((part (car rest)))
          (setq rest (cdr rest))
          (if (consp part)
              (progn (when rest (push rest stack))
                     (setq rest part))
            (let ((n (length part)))
              (when (> n 0)
                (when last
                  (let ((first (get-text-property 0 'display part)))
                    (when (eq first last)
                      (setq part (ebox--twin-first part first)))))
                (setq last (ebox--pad-display part (1- n)))
                (push part kept)))))))
    (nreverse kept)))

(defun ebox--join (parts)
  "Concatenate the strings PARTS into one composed line.
See `ebox--join-parts'."
  (let ((kept (ebox--join-parts parts)))
    (cond ((null kept) "")
          ((null (cdr kept)) (car kept))
          (t (apply #'concat kept)))))

(defun ebox--join-fresh (parts)
  "Return a new string composing PARTS, which the caller may modify.
See `ebox--join'."
  (let ((kept (ebox--join-parts parts)))
    (if (cdr kept) (apply #'concat kept) (copy-sequence (or (car kept) "")))))

(defun ebox-pixel-space (pixel-width)
  "Return a display space PIXEL-WIDTH pixels wide."
  (ebox--space (or pixel-width 0)))

(defun ebox-string-pixel-width (string)
  "Return the display pixel width of STRING's first line."
  (let* ((source (or string ""))
         (newline (string-search "\n" source)))
    (ebox--line-width (if newline (substring source 0 newline) source))))

(defun ebox-clear-cache ()
  "Clear pixel width caches after font or named face metrics change."
  (clrhash ebox--width-tables)
  (clrhash ebox--default-width-table)
  (clrhash ebox--cluster-width-cache)
  (clrhash ebox--space-cache)
  (clrhash ebox--image-widths)
  (fillarray ebox--face-memo nil)
  (cl-incf ebox--width-epoch))

(provide 'ebox-measure)

;;; ebox-measure.el ends here
