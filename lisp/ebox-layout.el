;;; ebox-layout.el --- Retained layout and line composition -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Layout assigns each node a margin box measured in pixels horizontally and
;; lines vertically, positioned in its parent's content box.  Containers keep
;; their flow items (child nodes or anonymous paragraphs) sorted by line, so
;; a vertical stack absorbs a child's height change by shifting later items
;; and reports only that child's lines as damage.  Horizontal containers,
;; definite heights and absolutely positioned overlays relayout their own
;; children, which are cached, and damage only their own line range.
;;
;; `ebox--node-parts' composes one line of a margin box on demand as a flat
;; list of its descendants' strings and caches it on the node; paragraphs
;; cache their wrapped lines.  A root line is concatenated once by
;; `ebox--join', and every line is exactly the box width in pixels.

;;; Code:

(require 'cl-lib)
(require 'ebox-node)

(declare-function ebox--layout-flex "ebox-flex" (node geo cbh))
(declare-function ebox--layout-grid "ebox-flex" (node geo cbh))
(declare-function ebox--grid-intrinsic "ebox-flex" (node))
(declare-function ebox--flex-natural "ebox-flex" (node geo))

;;;; Layout records

(ebox--defstruct (ebox-geo (:constructor ebox-geo--make) (:copier nil))
  "Resolved box metrics and content items of one laid-out node."
  (ml 0) (mr 0) (mt 0) (mb 0) (bl 0) (br 0) (pl 0) (pr 0) (pt 0) (pb 0)
  (bw 0) (bh 0) (cw 0) (vh 0) (ch 0) (scroll 0)
  items (n 0) stack kind gap iused nat)

(defmacro ebox--do-items (spec &rest body)
  "Bind (VAR GEO) to each of GEO's N items in order and run BODY.
Stacked items are a chunked sequence; other layouts keep a vector."
  (declare (indent 1))
  (let ((items (make-symbol "items")) (i (make-symbol "i")))
    `(let ((,items (ebox-geo-items ,(cadr spec))))
       (if (recordp ,items)
           (ebox--seq-do (,(car spec) ,items) ,@body)
         (dotimes (,i (ebox-geo-n ,(cadr spec)))
           (let ((,(car spec) (aref ,items ,i)))
             ,@body))))))

(defsubst ebox--set-items (geo items)
  "Store vector ITEMS as GEO's unstacked items."
  (dotimes (i (length items))
    (let ((item (aref items i)))
      (when (ebox-node-p item) (setf (ebox-node-irun item) nil))))
  (setf (ebox-geo-items geo) items
        (ebox-geo-n geo) (length items)))

(ebox--defstruct (ebox-para (:constructor ebox-para--make) (:copier nil))
  "Anonymous paragraph of inline nodes inside one block owner."
  owner nodes (x 0) (y 0) (w 0) (h 0) lines run (pos 0) pieces key)

(defvar ebox--vacated (make-hash-table :test 'eq :weakness 'key)
  "Host border-box line spans, (Y . H), that departed overlays covered.")

(defvar ebox--damage nil
  "Damage records (ITEM FROM OLD NEW) collected by the current layout.")

(defvar ebox--record t
  "Non-nil when layout should record damage for relaid nodes.")

(defvar ebox--decorate-function nil
  "Function of NODE and LINE returning LINE with interaction properties.")

(defsubst ebox--hidden-p (node)
  "Return non-nil when NODE does not paint."
  (ebox-cs-hidden (ebox-node-cs node)))

(defsubst ebox--abs-p (node)
  "Return non-nil when NODE is absolutely positioned below a parent."
  (and (ebox-cs-abs (ebox-node-cs node)) (ebox-node-parent node) t))

(defun ebox--inline-p (node)
  "Return non-nil when NODE participates in inline formatting."
  (or (eq (ebox-node-tag node) 'text)
      (and (eq (ebox-node-tag node) 'box)
           (eq (ebox-cs-outer (ebox-node-cs node)) 'inline)
           (let ((ok t))
             (ebox--do-kids (child node)
               (unless (or (ebox--abs-p child) (ebox--inline-p child))
                 (setq ok nil)))
             ok))))

;;;; Text units

;; A text node caches its measurement in a vector
;; [FONTFACE TEXT EPOCH WRAP MAXW MINW NEWLINE UNITS].  UNITS is computed
;; only when a paragraph must break: a flat vector [END WIDTH KIND ...]
;; of display units, each starting where the previous one ends.

(defun ebox--text-meas (node)
  "Return text NODE's measurement vector under its font and wrap mode."
  (let* ((cs (ebox-node-cs node))
         (fontface (ebox-cs-fontface cs))
         (wrap (ebox-cs-wrap cs))
         (text (ebox-node-text node))
         (m (ebox-node-meas node)))
    (if (and m (eq (aref m 0) fontface) (eq (aref m 1) text)
             (eq (aref m 2) ebox--width-epoch) (eq (aref m 3) wrap))
        m
      (unless m
        (setq m (make-vector 8 nil))
        (setf (ebox-node-meas node) m))
      (aset m 0 fontface) (aset m 1 text) (aset m 2 ebox--width-epoch) (aset m 3 wrap)
      (aset m 7 nil)
      (if (ebox--plain-string-p text)
          (ebox--measure-plain m text fontface wrap)
        (ebox--measure-units m text (ebox--unit-vector text fontface) wrap))
      m)))

(defsubst ebox--word-step (word w ch wrap)
  "Return the unbreakable run width after a unit of width W starting with CH."
  (cond ((memq wrap '(none nowrap)) (+ word w))
        ((eq wrap 'char) w)
        ((memq ch '(?\s ?\t)) 0)
        ((ebox--cjk-char-p ch) w)
        (t (+ word w))))

(defun ebox--measure-plain (m text face wrap)
  "Store MAXW, MINW and NEWLINE of property-free TEXT under FACE in M."
  (let* ((table (ebox--face-table face))
         (ascii (car table)) (wide (cdr table))
         (len (length text)) (pos 0)
         (maxw 0) (minw 0) (line 0) (word 0) (newline nil))
    (while (< pos len)
      (let* ((ch (aref text pos))
             (next (if (and (< ch 128)
                            (or (= (1+ pos) len) (< (aref text (1+ pos)) 128)))
                       (1+ pos)
                     (ebox--cluster-end text pos len)))
             (w (if (= next (1+ pos))
                    (or (if (< ch 128) (aref ascii ch) (gethash ch wide))
                        (ebox--char-width ch face))
                  (ebox--cluster-width text pos next face))))
        (if (eq ch ?\n)
            (setq maxw (max maxw line) line 0 word 0 newline t)
          (setq line (+ line w)
                word (ebox--word-step word w ch wrap)
                minw (max minw word)))
        (setq pos next)))
    (aset m 4 (max maxw line))
    (aset m 5 minw)
    (aset m 6 newline)))

(defun ebox--measure-units (m text units wrap)
  "Store TEXT's widths from its unit vector UNITS under WRAP in M."
  (let ((maxw 0) (minw 0) (line 0) (word 0) (newline nil)
        (i 0) (n (length units)) (start 0))
    (while (< i n)
      (let ((ch (aref text start)) (w (aref units (1+ i))))
        (if (eq ch ?\n)
            (setq maxw (max maxw line) line 0 word 0 newline t)
          (setq line (+ line w)
                word (ebox--word-step word w ch wrap)
                minw (max minw word))))
      (setq start (aref units i) i (+ i 3)))
    (aset m 4 (max maxw line))
    (aset m 5 minw)
    (aset m 6 newline)
    (aset m 7 units)))

(defun ebox--unit-vector (text face)
  "Return TEXT's display units under FACE as a flat [END WIDTH KIND ...]."
  (let* ((units (ebox--units text face))
         (v (make-vector (* 3 (length units)) nil))
         (i 0))
    (dolist (u units)
      (aset v i (nth 1 u))
      (aset v (+ i 1) (nth 2 u))
      (aset v (+ i 2) (ebox--unit-kind text u))
      (setq i (+ i 3)))
    v))

(defun ebox--text-unit-vector (node)
  "Return text NODE's cached unit vector."
  (let ((m (ebox--text-meas node)))
    (or (aref m 7)
        (aset m 7 (ebox--unit-vector (ebox-node-text node) (aref m 0))))))

;;;; Inline pieces

(defun ebox--run-face (node)
  "Return the face painted on NODE's text."
  (ebox-cs-face (ebox-node-cs node)))

(defun ebox--decorate-text (text face node)
  "Return TEXT carrying FACE (after its own faces) and NODE ownership."
  (let ((string (copy-sequence text)) (len (length text)))
    (when (> len 0)
      (if (and face (ebox--plain-string-p text))
          (put-text-property 0 len 'face face string)
        (when face (add-face-text-property 0 len face t string)))
      (put-text-property 0 len 'ebox-node node string))
    string))

(defun ebox--hidden-text (node)
  "Return hidden text NODE's characters displayed as blank space.
The characters stay, so hidden text breaks exactly like visible text."
  (let* ((text (ebox-node-text node))
         (units (ebox--text-unit-vector node))
         (blank (substring-no-properties text))
         (i 0) (n (length units)) (start 0))
    (while (< i n)
      (let ((end (aref units i)))
        (unless (eq (aref text start) ?\n)
          (put-text-property start end 'display
                             (list 'space :width (list (aref units (1+ i))))
                             blank))
        (setq start end i (+ i 3))))
    blank))

(defun ebox--push-pad (pieces width face)
  "Push a pad piece WIDTH pixels wide painted with FACE onto PIECES."
  (if (> width 0) (cons (cons (ebox--space width face) width) pieces) pieces))

(defun ebox--node-pieces (node pieces)
  "Push NODE's inline pieces onto PIECES in reverse order and return them."
  (let ((mark pieces))
    (cond
     ((ebox--abs-p node) nil)
     ((eq (ebox-node-tag node) 'text)
      (push (cons (if (ebox--hidden-p node)
                      (ebox--hidden-text node)
                    (ebox--decorate-text (ebox-node-text node) (ebox--run-face node) node))
                  node)
            pieces))
     (t
      (let* ((cs (ebox-node-cs node))
             (parent (ebox-node-parent node))
             (parent-face (and parent (ebox-cs-padface (ebox-node-cs parent))))
             (padface (ebox-cs-padface cs)))
        (setq pieces (ebox--push-pad pieces (ebox--hpx (ebox-cs-ml cs) cs 0) parent-face))
        (when (ebox-cs-blc cs)
          (setq pieces (ebox--push-pad pieces 1 (ebox--border-face (ebox-cs-blc cs)))))
        (setq pieces (ebox--push-pad pieces (ebox--hpx (ebox-cs-pl cs) cs 0) padface))
        (ebox--do-kids (child node) (setq pieces (ebox--node-pieces child pieces)))
        (setq pieces (ebox--push-pad pieces (ebox--hpx (ebox-cs-pr cs) cs 0) padface))
        (when (ebox-cs-brc cs)
          (setq pieces (ebox--push-pad pieces 1 (ebox--border-face (ebox-cs-brc cs)))))
        (setq pieces (ebox--push-pad pieces (ebox--hpx (ebox-cs-mr cs) cs 0) parent-face)))))
    (when (and (ebox-node-inter node) ebox--decorate-function)
      (let ((cell pieces))
        (while (and cell (not (eq cell mark)))
          (setcar (car cell) (funcall ebox--decorate-function node (caar cell)))
          (setq cell (cdr cell)))))
    pieces))

(defun ebox--inline-key (node key)
  "Push the values NODE's inline pieces depend on onto KEY and return it."
  (setq key (cons (ebox-node-cs node)
                  (cons (ebox-node-text node) (cons (ebox-node-inter node) key))))
  (ebox--do-kids (kid node) (setq key (ebox--inline-key kid key)))
  key)

(defun ebox--para-cached-pieces (para)
  "Return PARA's inline pieces, rebuilding them when an inline node changed."
  (let ((key (list ebox--width-epoch (ebox-node-cs (ebox-para-owner para)))))
    (dolist (node (ebox-para-nodes para)) (setq key (ebox--inline-key node key)))
    (let ((old (ebox-para-key para)) (new key))
      (while (and old new (eq (car old) (car new))) (setq old (cdr old) new (cdr new)))
      (if (and (null old) (null new) (ebox-para-pieces para))
          (ebox-para-pieces para)
        (setf (ebox-para-key para) key
              (ebox-para-pieces para) (ebox--para-pieces (ebox-para-nodes para)))))))

(defun ebox--para-pieces (nodes)
  "Return inline pieces for NODES as (STRING . SOURCE) in order.
SOURCE is the text node a string displays, or a pad's pixel width."
  (let (pieces)
    (dolist (node nodes) (setq pieces (ebox--node-pieces node pieces)))
    (nreverse pieces)))

(defun ebox--piece-units (piece)
  "Return PIECE's unit vector."
  (let ((source (cdr piece)))
    (if (integerp source) (vector 1 source 'glue) (ebox--text-unit-vector source))))

(defun ebox--pieces-line-width (pieces)
  "Return the width of PIECES on one line, or nil when one has a newline."
  (let ((total 0))
    (catch 'newline
      (dolist (piece pieces total)
        (let ((source (cdr piece)))
          (setq total
                (+ total
                   (if (integerp source) source
                     (let ((m (ebox--text-meas source)))
                       (when (aref m 6) (throw 'newline nil))
                       (aref m 4))))))))))

(defun ebox--border-face (color)
  "Return the side border face for COLOR."
  (ebox--intern-face (list :background (if (eq color 'default) "gray50" color))))

;;;; Line breaking

(defun ebox--unit-kind (string unit)
  "Classify UNIT of STRING for line breaking."
  (or (nth 3 unit)
      (let ((ch (aref string (car unit))))
        (cond ((eq ch ?\n) 'newline)
              ((memq ch '(?\s ?\t)) 'space)
              ((ebox--cjk-char-p ch) 'cjk)
              (t 'word)))))

(defun ebox--break-lines (pieces width wrap clip)
  "Break PIECES into lines no wider than WIDTH under WRAP mode.
Return a list of (STRING . PIXELS).  Words wrap as a whole, CJK and `char'
mode wrap per cluster, a word wider than WIDTH splits per cluster and a
space that does not fit ends its line and is dropped.  Under `none' or
`nowrap' only newlines break; CLIP then drops units beyond WIDTH."
  (let* ((np (length pieces))
         (pstr (make-vector np nil))
         (pbase (make-vector (1+ np) 0))
         (n 0) (k 0) uvecs)
    (dolist (piece pieces)
      (let ((uvec (ebox--piece-units piece)))
        (aset pstr k (car piece))
        (aset pbase k n)
        (setq n (+ n (/ (length uvec) 3)) k (1+ k))
        (push uvec uvecs)))
    (aset pbase np n)
    (let ((uv (if (cdr uvecs) (apply #'vconcat (nreverse uvecs)) (or (car uvecs) [])))
          (nowrap (memq wrap '(none nowrap)))
          (char-mode (eq wrap 'char))
          (lines nil) (ls 0) (cur 0) (i 0) (newline-last t) (stop nil))
      (cl-flet ((emit (from to w)
                  (let ((p 0) parts)
                    (while (< from to)
                      (while (>= from (aref pbase (1+ p))) (setq p (1+ p)))
                      (let* ((base (aref pbase p))
                             (end (min to (aref pbase (1+ p))))
                             (s (aref pstr p))
                             (cs (if (= from base) 0 (aref uv (* 3 (1- from)))))
                             (ce (aref uv (* 3 (1- end)))))
                        (push (if (and (= cs 0) (= ce (length s))) s (substring s cs ce))
                              parts)
                        (setq from end)))
                    (push (cons (ebox--join (nreverse parts)) w) lines))))
        (while (< i n)
          (let ((kind (aref uv (+ (* 3 i) 2))) (w (aref uv (1+ (* 3 i)))))
            (setq newline-last nil)
            (cond
             ((eq kind 'newline)
              (emit ls (or stop i) cur)
              (setq i (1+ i) ls i cur 0 newline-last t stop nil))
             (nowrap
              (when (and clip (not stop) (> (+ cur w) width))
                (setq stop i))
              (unless stop (setq cur (+ cur w)))
              (setq i (1+ i)))
             ((or char-mode (memq kind '(cjk glue space)))
              (cond
               ((and (eq kind 'space) (not char-mode) (> (+ cur w) width))
                (when (< ls i) (emit ls i cur))
                (setq i (1+ i) ls i cur 0))
               (t
                (when (> (+ cur w) width)
                  (when (< ls i) (emit ls i cur))
                  (setq ls i cur 0))
                (setq cur (+ cur w) i (1+ i)))))
             (t
              (let ((j i) (run 0))
                (while (and (< j n) (eq (aref uv (+ (* 3 j) 2)) 'word))
                  (setq run (+ run (aref uv (1+ (* 3 j)))) j (1+ j)))
                (cond
                 ((> run width)
                  (while (< i j)
                    (let ((cw (aref uv (1+ (* 3 i)))))
                      (when (> (+ cur cw) width)
                        (when (< ls i) (emit ls i cur))
                        (setq ls i cur 0))
                      (setq cur (+ cur cw) i (1+ i)))))
                 ((<= (+ cur run) width)
                  (setq cur (+ cur run) i j))
                 (t
                  (when (< ls i) (emit ls i cur))
                  (setq ls i cur run i j))))))))
        (cond
         (stop (emit ls stop cur))
         ((or (< ls n) newline-last (null lines)) (emit ls n cur))))
      (nreverse lines))))

(defun ebox--reset-geo (geo)
  "Return GEO with every field restored to its initial value."
  (setf (ebox-geo-ml geo) 0 (ebox-geo-mr geo) 0 (ebox-geo-mt geo) 0 (ebox-geo-mb geo) 0
        (ebox-geo-bl geo) 0 (ebox-geo-br geo) 0 (ebox-geo-pl geo) 0 (ebox-geo-pr geo) 0
        (ebox-geo-pt geo) 0 (ebox-geo-pb geo) 0 (ebox-geo-bw geo) 0 (ebox-geo-bh geo) 0
        (ebox-geo-cw geo) 0 (ebox-geo-vh geo) 0 (ebox-geo-ch geo) 0 (ebox-geo-scroll geo) 0
        (ebox-geo-items geo) nil (ebox-geo-n geo) 0 (ebox-geo-stack geo) nil
        (ebox-geo-kind geo) nil (ebox-geo-gap geo) nil (ebox-geo-iused geo) nil
        (ebox-geo-nat geo) nil)
  geo)

(defun ebox--box-metrics (node cbw &optional reuse)
  "Return a geometry record of NODE's edges against CBW pixels.
The record is fresh unless REUSE, a geometry record, is given to reset."
  (let* ((cs (ebox-node-cs node))
         (geo (if reuse (ebox--reset-geo reuse) (ebox-geo--make))))
    (if (eq (ebox-node-tag node) 'text)
        geo
      (setf (ebox-geo-ml geo) (max 0 (or (ebox--px (ebox-cs-ml cs) cs cbw) 0))
            (ebox-geo-mr geo) (max 0 (or (ebox--px (ebox-cs-mr cs) cs cbw) 0))
            (ebox-geo-pl geo) (max 0 (or (ebox--px (ebox-cs-pl cs) cs cbw) 0))
            (ebox-geo-pr geo) (max 0 (or (ebox--px (ebox-cs-pr cs) cs cbw) 0))
            (ebox-geo-mt geo) (max 0 (or (ebox--lines (ebox-cs-mt cs) cs nil) 0))
            (ebox-geo-mb geo) (max 0 (or (ebox--lines (ebox-cs-mb cs) cs nil) 0))
            (ebox-geo-pt geo) (max 0 (or (ebox--lines (ebox-cs-pt cs) cs nil) 0))
            (ebox-geo-pb geo) (max 0 (or (ebox--lines (ebox-cs-pb cs) cs nil) 0))
            (ebox-geo-bl geo) (ebox-cs-bl cs)
            (ebox-geo-br geo) (ebox-cs-br cs))
      geo)))

(defsubst ebox--h-extras (geo)
  "Return horizontal border and padding pixels of GEO."
  (+ (ebox-geo-bl geo) (ebox-geo-br geo) (ebox-geo-pl geo) (ebox-geo-pr geo)))

(defsubst ebox--h-margins (geo)
  "Return horizontal margin pixels of GEO."
  (+ (ebox-geo-ml geo) (ebox-geo-mr geo)))

(defsubst ebox--hpx (spec cs cbw)
  "Return horizontal edge SPEC of CS in pixels against CBW, at least 0."
  (max 0 (or (ebox--px spec cs cbw) 0)))

(defun ebox--node-h-extras (node cbw)
  "Return NODE's horizontal border and padding pixels against CBW."
  (if (eq (ebox-node-tag node) 'text) 0
    (let ((cs (ebox-node-cs node)))
      (+ (ebox-cs-bl cs) (ebox-cs-br cs)
         (ebox--hpx (ebox-cs-pl cs) cs cbw) (ebox--hpx (ebox-cs-pr cs) cs cbw)))))

(defun ebox--node-h-margins (node cbw)
  "Return NODE's horizontal margin pixels against CBW."
  (if (eq (ebox-node-tag node) 'text) 0
    (let ((cs (ebox-node-cs node)))
      (+ (ebox--hpx (ebox-cs-ml cs) cs cbw) (ebox--hpx (ebox-cs-mr cs) cs cbw)))))

;;;; Intrinsic sizes

(defun ebox--intrinsic (node)
  "Return (MIN . MAX) content-box intrinsic widths of NODE."
  (or (ebox-node-intr node)
      (setf (ebox-node-intr node) (ebox--compute-intrinsic node))))

(defun ebox--outer-intrinsic (node cbw &optional record)
  "Return (MIN . MAX) margin-box widths of NODE against CBW.
RECORD notes the result as the widths NODE's container laid it out from.
A fixed width does not read NODE's content."
  (let* ((cs (ebox-node-cs node))
         (extras (ebox--node-h-extras node cbw))
         (margins (ebox--node-h-margins node cbw))
         (width (ebox-cs-width cs))
         (fixed (and (not (eq (ebox-node-tag node) 'text)) (ebox--px width cs cbw)))
         minc maxc)
    (if fixed
        (setq minc (if (eq (ebox-cs-box-sizing cs) 'content-box) (+ fixed extras) fixed)
              maxc minc)
      (let ((content (ebox--intrinsic node)))
        (setq minc (+ (car content) extras)
              maxc (+ (cdr content) extras))
        (pcase width
          ('min-content (setq maxc minc))
          ('max-content (setq minc maxc)))))
    (let ((lo (ebox--px (ebox-cs-min-width cs) cs cbw))
          (hi (ebox--px (ebox-cs-max-width cs) cs cbw)))
      (when hi (setq minc (min minc hi) maxc (min maxc hi)))
      (when lo (setq minc (max minc lo) maxc (max maxc lo))))
    (let ((result (cons (+ minc margins) (+ maxc margins))))
      (when record (setf (ebox-node-seen node) result))
      result)))

(defun ebox--contribution (node)
  "Return NODE's margin-box intrinsic widths without a containing width.
The result is cached until NODE's computed style or intrinsic widths change."
  (let ((cache (ebox-node-contrib node))
        (cs (ebox-node-cs node)))
    (if (and cache (eq (car cache) cs) (eq (cadr cache) (ebox-node-intr node)))
        (cddr cache)
      (let ((size (ebox--outer-intrinsic node nil)))
        (unless (ebox-cs-vunits cs)
          (setf (ebox-node-contrib node) (cons cs (cons (ebox-node-intr node) size))))
        size))))

(defun ebox--para-intrinsic (nodes)
  "Return (MIN . MAX) widths of an inline paragraph of NODES."
  (let ((minw 0) (maxw 0) (line 0))
    (cl-labels
        ((visit (node)
           (cond
            ((ebox--abs-p node) nil)
            ((eq (ebox-node-tag node) 'text)
             (let ((m (ebox--text-meas node)))
               (setq minw (max minw (aref m 5)))
               (if (aref m 6)
                   (let* ((units (ebox--text-unit-vector node))
                          (i 0) (n (length units)))
                     (while (< i n)
                       (if (eq (aref units (+ i 2)) 'newline)
                           (setq maxw (max maxw line) line 0)
                         (setq line (+ line (aref units (1+ i)))))
                       (setq i (+ i 3))))
                 (setq line (+ line (aref m 4))))))
            (t
             (progn
               (setq line (+ line (ebox--node-h-margins node 0) (ebox--node-h-extras node 0)))
               (ebox--do-kids (child node) (visit child)))))))
      (mapc #'visit nodes))
    (cons minw (max maxw line))))

(defun ebox--flow-groups (node)
  "Return NODE's in-flow children grouped as nodes and inline lists."
  (let (groups run)
    (ebox--do-kids (child node)
      (cond ((ebox--abs-p child) nil)
            ((ebox--inline-p child) (push child run))
            (t (when run (push (nreverse run) groups) (setq run nil))
               (push child groups))))
    (when run (push (nreverse run) groups))
    (nreverse groups)))

(defun ebox--compute-intrinsic (node)
  "Compute (MIN . MAX) content intrinsic widths of NODE."
  (pcase (ebox-node-tag node)
    ('text (ebox--para-intrinsic (list node)))
    ('image (let ((w (ebox--image-width node))) (cons w w)))
    (tag
     (let* ((cs (ebox-node-cs node))
            (horizontal (or (eq tag 'row)
                            (and (eq tag 'flex)
                                 (memq (ebox--cv cs 'ebox/flex-direction)
                                       '(row row-reverse)))))
            (gap (if (eq tag 'row) (or (ebox--px (ebox-cs-gap cs) cs nil) 0)
                   (or (ebox--px (ebox--cv cs 'ebox/column-gap) cs nil) 0)))
            (minw 0) (maxw 0) (count 0))
       (cond
        ((eq tag 'grid) (ebox--grid-intrinsic node))
        (t
         (cl-flet ((add (size)
                     (setq count (1+ count))
                     (if horizontal
                         (setq minw (if (and (eq tag 'flex)
                                             (not (eq (ebox--cv cs 'ebox/flex-wrap) 'nowrap)))
                                        (max minw (car size))
                                      (+ minw (car size)))
                               maxw (+ maxw (cdr size)))
                       (setq minw (max minw (car size)) maxw (max maxw (cdr size))))))
           (if (eq tag 'box)
               (dolist (group (ebox--flow-groups node))
                 (add (if (consp group) (ebox--para-intrinsic group)
                        (ebox--contribution group))))
             (ebox--do-kids (kid node)
               (unless (ebox--abs-p kid) (add (ebox--contribution kid))))))
         (when (and horizontal (> count 1))
           (setq maxw (+ maxw (* gap (1- count))))
           (unless (and (eq tag 'flex) (not (eq (ebox--cv cs 'ebox/flex-wrap) 'nowrap)))
             (setq minw (+ minw (* gap (1- count))))))
         (cons minw maxw)))))))

;;;; Layout entry

(defsubst ebox--constraint (node)
  "Return NODE's last layout constraint vector, or nil."
  (ebox-node-avail node))

(defun ebox--layout (node avail mode cbh &optional fh)
  "Lay out NODE's margin box within AVAIL pixels.
MODE is stretch, shrink or exact; CBH is the containing height in lines or
nil; FH forces the border-box height in lines.  Return non-nil when NODE's
geometry or its children's sizes may have changed."
  (let ((key (ebox--constraint node))
        (dirty (ebox-node-dirty node)))
    ;; Only percentage and stretch block sizes read CBH; dropping it otherwise
    ;; keeps cached layouts valid when an ancestor's definite height changes.
    (unless (ebox-cs-vcbh (ebox-node-cs node)) (setq cbh nil))
    (if (and key (zerop (logand dirty 3))
             (eql (aref key 0) avail) (eq (aref key 1) mode)
             (eql (aref key 2) cbh) (eql (aref key 3) fh))
        (let ((old-h (ebox-node-h node))
              (moved
               (when (/= 0 (logand dirty ebox--d-desc))
                 (let ((used (ebox-geo-iused (ebox-node-layout node))))
                   (if (and used (not (equal used (ebox--intrinsic node))))
                       ;; NODE's own width follows its content, which changed.
                       (progn (ebox--layout-full node avail mode cbh fh) t)
                     (ebox--relayout-partial node))))))
          (when (/= 0 (logand (ebox-node-dirty node) ebox--d-paint))
            ;; A paint-only restyle keeps geometry and repaints NODE's lines.
            (ebox--repaint node)
            (when ebox--record (ebox--damage-whole node old-h)))
          moved)
      (ebox--layout-full node avail mode cbh fh)
      t)))

(defun ebox--repaint (node)
  "Rebuild the cached paragraph lines below NODE and clear its paint dirt."
  (setf (ebox-node-dirty node) (logand (ebox-node-dirty node) (lognot ebox--d-paint)))
  (ebox--uncache node)
  (let ((geo (ebox-node-layout node)))
    (when geo
      (ebox--do-items (item geo)
        (when (ebox-para-p item)
          (ebox--layout-para item (ebox-para-w item))))))
  (ebox--do-kids (kid node) (ebox--repaint kid)))

(defun ebox--natural-h (node avail mode cbh)
  "Return NODE's margin-box height laid out without a forced height.
A NODE stretched under the same constraints reports the natural height
recorded when it was stretched, keeping its stretched layout; dirty
descendants settle at the stretched constraints first and the natural height
is measured again from the children's recorded sizes."
  (let ((key (ebox--constraint node))
        (geo (ebox-node-layout node))
        (dirty (ebox-node-dirty node)))
    (unless (ebox-cs-vcbh (ebox-node-cs node)) (setq cbh nil))
    (if (and key (aref key 3) (ebox-geo-nat geo)
             (zerop (logand dirty 3))
             (eql (aref key 0) avail) (eq (aref key 1) mode) (eql (aref key 2) cbh)
             (or (zerop (logand dirty ebox--d-desc))
                 (progn
                   (ebox--layout node avail mode cbh (aref key 3))
                   (let ((natural (ebox--stretched-natural node)))
                     (when natural
                       (setf (ebox-geo-nat (ebox-node-layout node)) natural))))))
        (ebox-geo-nat (ebox-node-layout node))
      (ebox--layout node avail mode cbh)
      (ebox-node-h node))))

(defun ebox--place-h (node avail mode cbh natural lines)
  "Lay out NODE stretched to LINES margin-box lines unless NATURAL fits.
NATURAL is NODE's height from `ebox--natural-h'."
  (if (or (null lines) (= natural lines))
      (ebox--layout node avail mode cbh)
    (let ((geo (ebox-node-layout node)))
      (ebox--layout node avail mode cbh
                    (max 0 (- lines (ebox-geo-mt geo) (ebox-geo-mb geo))))
      (setf (ebox-geo-nat (ebox-node-layout node)) natural))))

(defun ebox--stretched-natural (node)
  "Return NODE's natural margin-box height after a stretched relayout.
Return nil when NODE's content depends on its forced height."
  (let* ((key (ebox--constraint node))
         (geo (ebox-node-layout node))
         (tag (ebox-node-tag node))
         (content
          (and (memq tag '(box column row text image flex))
               (not (catch 'found
                      (ebox--do-kids (kid node)
                        (when (ebox-cs-vcbh (ebox-node-cs kid)) (throw 'found t)))
                      nil))
               (if (eq tag 'flex) (ebox--flex-natural node geo) (ebox-geo-ch geo)))))
    (when content
      (+ (ebox-geo-mt geo) (ebox-geo-mb geo)
         (if (eq tag 'text) content
           (ebox--resolve-height node geo content (aref key 2) nil))))))

(defun ebox--recorded-natural (node)
  "Return NODE's natural margin-box height recorded by its last layout."
  (let ((key (ebox--constraint node)))
    (or (and key (aref key 3) (ebox-geo-nat (ebox-node-layout node)))
        (ebox-node-h node))))

(defun ebox--drop-dkids (node)
  "Forget NODE's pending dirty children and structural operations."
  (dolist (kid (ebox-node-dkids node))
    (setf (ebox-node-dirty kid) (logand (ebox-node-dirty kid) (lognot ebox--d-queued))))
  (setf (ebox-node-dkids node) nil
        (ebox-node-ops node) nil))

(defun ebox--layout-places (node)
  "Return NODE's own geometry and its children's places, for damage checks."
  (let* ((geo (ebox-node-layout node))
         (places (list (ebox-node-w node) (ebox-node-h node) (ebox-geo-bw geo)
                       (ebox-geo-bh geo) (ebox-geo-scroll geo))))
    (ebox--do-kids (kid node)
      (setq places (cons (ebox-node-h kid)
                         (cons (ebox-node-w kid)
                               (cons (ebox-node-y kid)
                                     (cons (ebox-node-x kid) (cons kid places)))))))
    places))

(defun ebox--layout-full (node avail mode cbh fh)
  "Lay out NODE completely and record its damage.
A container whose own style is unchanged and whose relayout leaves its size
and every child's place unchanged records only its children's damage."
  (let* ((old-h (ebox-node-h node))
         (fresh (null (ebox-node-layout node)))
         (precise (and ebox--record (not fresh)
                       (zerop (logand (ebox-node-dirty node) 7))
                       (memq (ebox-node-tag node) '(column row flex grid))))
         (before (and precise (ebox--layout-places node)))
         (inner nil))
    (unless (zerop (logand (ebox-node-dirty node) 3))
      (setf (ebox-node-intr node) nil))
    (ebox--uncache node)
    (let ((ebox--record precise) (ebox--damage nil))
      (ebox--do-layout node avail mode cbh fh)
      (setq inner ebox--damage))
    (ebox--drop-dkids node)
    (remhash node ebox--vacated)
    (setf (ebox-node-avail node) (vector avail mode cbh fh)
          (ebox-node-dirty node) (logand (ebox-node-dirty node) ebox--d-queued))
    (when (and ebox--record (not fresh))
      (if (and precise (equal before (ebox--layout-places node)))
          (setq ebox--damage (nconc inner ebox--damage))
        (ebox--damage-whole node old-h)))))

(defun ebox--damage-owner (item)
  "Return the node whose lines damage ITEM concerns."
  (cond ((ebox-para-p item) (ebox-para-owner item))
        ((consp item) (nth 1 item))
        (t item)))

(defun ebox--damage-whole (node old-h)
  "Record that every line of NODE changed; it had OLD-H lines.
The entry supersedes earlier damage inside NODE; `ebox--damage-prune' drops
that damage once, when the pass ends."
  (push (list node 0 old-h (ebox-node-h node)) ebox--damage))

(defun ebox--damage-prune (damages)
  "Return DAMAGES without entries superseded by a later whole-node entry.
DAMAGES is newest first; a whole-node entry, whose item is a node, covers
earlier damage owned by that node or its descendants."
  (let ((whole nil) (kept nil))
    (dolist (damage damages)
      (let ((owner (ebox--damage-owner (car damage))) (covered nil))
        (when whole
          (let ((node owner))
            (while (and node (not covered))
              (if (gethash node whole) (setq covered t)
                (setq node (ebox-node-parent node))))))
        (unless covered
          (push damage kept)
          (when (ebox-node-p (car damage))
            (unless whole (setq whole (make-hash-table :test 'eq)))
            (puthash (car damage) t whole)))))
    (nreverse kept)))

(defsubst ebox--item-h (item)
  "Return ITEM's height in lines."
  (if (ebox-para-p item) (ebox-para-h item) (ebox-node-h item)))

(defsubst ebox--item-w (item)
  "Return ITEM's width in pixels."
  (if (ebox-para-p item) (ebox-para-w item) (ebox-node-w item)))

(defsubst ebox--item-y (item)
  "Return ITEM's top line in its container's content box.
A stacked item stores its line relative to its run's offset."
  (if (ebox-para-p item)
      (let ((run (ebox-para-run item)))
        (if run (+ (ebox-para-y item) (ebox-run-dy run)) (ebox-para-y item)))
    (let ((run (ebox-node-irun item)))
      (if run (+ (ebox-node-y item) (ebox-run-dy run)) (ebox-node-y item)))))

(defun ebox--item-ref (item run pos old)
  "Record that stacked ITEM sits at POS of RUN.
An item arriving from OLD, another run, keeps its line."
  (if (ebox-para-p item)
      (progn
        (when (and old (not (eq old run)))
          (setf (ebox-para-y item)
                (+ (ebox-para-y item) (- (ebox-run-dy old) (ebox-run-dy run)))))
        (setf (ebox-para-run item) run (ebox-para-pos item) pos))
    (when (and old (not (eq old run)))
      (setf (ebox-node-y item)
            (+ (ebox-node-y item) (- (ebox-run-dy old) (ebox-run-dy run)))))
    (setf (ebox-node-irun item) run (ebox-node-ipos item) pos)))

(defun ebox--item-run (item)
  "Return the run holding stacked ITEM, or nil."
  (if (ebox-para-p item) (ebox-para-run item) (ebox-node-irun item)))

(defun ebox--item-pos (item)
  "Return stacked ITEM's position in its run."
  (if (ebox-para-p item) (ebox-para-pos item) (ebox-node-ipos item)))

(defun ebox--release-items (items)
  "Detach the stacked ITEMS sequence's items from their runs."
  (when (recordp items)
    (ebox--seq-do (item items)
      (if (ebox-para-p item) (setf (ebox-para-run item) nil) (setf (ebox-node-irun item) nil)))))

(defsubst ebox--item-x (item)
  "Return ITEM's left pixel in its container's content box."
  (if (ebox-para-p item) (ebox-para-x item) (ebox-node-x item)))

;;;; Full layout of one node

(defun ebox--resolve-width (node geo avail mode)
  "Return NODE's border-box width for AVAIL margin-box pixels under MODE."
  (let* ((cs (ebox-node-cs node))
         (extras (ebox--h-extras geo))
         (space (max 0 (- avail (ebox--h-margins geo))))
         (width (ebox-cs-width cs))
         (fixed (ebox--px width cs avail))
         (bw
          (cond
           ((eq mode 'exact) space)
           (fixed (if (eq (ebox-cs-box-sizing cs) 'content-box) (+ fixed extras) fixed))
           ((eq width 'stretch) space)
           ((eq width 'min-content)
            (+ (car (setf (ebox-geo-iused geo) (ebox--intrinsic node))) extras))
           ((eq width 'max-content)
            (+ (cdr (setf (ebox-geo-iused geo) (ebox--intrinsic node))) extras))
           ((or (eq width 'fit-content) (eq mode 'shrink)
                (and (consp width) (eq (car width) 'fit-content)))
            (let ((size (setf (ebox-geo-iused geo) (ebox--intrinsic node))))
              (min (+ (cdr size) extras) (max (+ (car size) extras) space))))
           (t space)))
         (lo (ebox--px (ebox-cs-min-width cs) cs avail))
         (hi (ebox--px (ebox-cs-max-width cs) cs avail)))
    (unless (eq mode 'exact)
      (when hi (setq bw (min bw (if (eq (ebox-cs-box-sizing cs) 'content-box)
                                    (+ hi extras) hi))))
      (when lo (setq bw (max bw (if (eq (ebox-cs-box-sizing cs) 'content-box)
                                    (+ lo extras) lo)))))
    (max bw extras)))

(defun ebox--resolve-height (node geo content cbh fh)
  "Return NODE's border-box height for CONTENT lines.
CBH is the containing height or nil; FH forces the result."
  (let* ((cs (ebox-node-cs node))
         (extras (+ (ebox-geo-pt geo) (ebox-geo-pb geo)))
         (natural (+ content extras))
         (fixed (ebox--lines (ebox-cs-height cs) cs cbh))
         (bh (cond (fh fh)
                   (fixed (if (eq (ebox-cs-box-sizing cs) 'content-box) (+ fixed extras) fixed))
                   ((and (eq (ebox-cs-height cs) 'stretch) cbh)
                    (max 0 (- cbh (ebox-geo-mt geo) (ebox-geo-mb geo))))
                   (t natural)))
         (lo (ebox--lines (ebox-cs-min-height cs) cs cbh))
         (hi (ebox--lines (ebox-cs-max-height cs) cs cbh)))
    (unless fh
      (when hi (setq bh (min bh hi)))
      (when lo (setq bh (max bh lo))))
    (when (and (eq (ebox-cs-overflow cs) 'visible) (> natural bh))
      (setq bh natural))
    (max bh extras)))

(defun ebox--definite-height (node geo cbh fh)
  "Return NODE's definite content height in lines, or nil."
  (let* ((cs (ebox-node-cs node))
         (fixed (or fh (ebox--lines (ebox-cs-height cs) cs cbh))))
    (when fixed
      (max 0 (- fixed (if (and (not fh) (eq (ebox-cs-box-sizing cs) 'content-box)) 0
                        (+ (ebox-geo-pt geo) (ebox-geo-pb geo))))))))

(defun ebox--pos-extent (geo content)
  "Return CONTENT lines extended to the bottom of GEO's positioned items.
Items overflowing their container make it a clipping or growing box."
  (ebox--do-items (item geo)
    (setq content (max content (+ (ebox--item-y item) (ebox-node-h item)))))
  content)

(defvar ebox--old-items nil
  "Items of the layout `ebox--do-layout' is replacing, for reuse.")

(defun ebox--do-layout (node avail mode cbh fh)
  "Compute NODE's geometry and items for the given constraints."
  (let* ((old (ebox-node-layout node))
         (ebox--old-items (and old (ebox-geo-items old)))
         (geo (ebox--box-metrics node avail old))
         (tag (ebox-node-tag node))
         (bw (if (eq tag 'text)
                 (if (eq mode 'shrink)
                     (let ((size (setf (ebox-geo-iused geo) (ebox--intrinsic node))))
                       (min (cdr size) (max (car size) avail)))
                   avail)
               (ebox--resolve-width node geo avail mode)))
         (cw (max 0 (- bw (ebox--h-extras geo))))
         (inner-cbh (ebox--definite-height node geo cbh fh))
         (content
          (progn
            (setf (ebox-geo-cw geo) cw (ebox-geo-bw geo) bw
                  (ebox-node-layout node) geo)
            (pcase tag
              ('text (ebox--layout-para-items node geo (list node)))
              ('image (ebox--layout-image node geo))
              ('box (ebox--layout-flow node geo inner-cbh))
              ('column (ebox--layout-column node geo inner-cbh))
              ('row (ebox--layout-row node geo inner-cbh))
              ('flex (ebox--layout-flex node geo inner-cbh))
              ('grid (ebox--layout-grid node geo inner-cbh)))))
         (content (if (eq (ebox-geo-kind geo) 'pos)
                      (ebox--pos-extent geo content)
                    content))
         (bh (if (eq tag 'text) content
               (ebox--resolve-height node geo content cbh fh))))
    (setf (ebox-geo-ch geo) content
          (ebox-geo-bh geo) bh
          (ebox-geo-vh geo) (max 0 (- bh (ebox-geo-pt geo) (ebox-geo-pb geo)))
          (ebox-geo-scroll geo)
          (max 0 (min (ebox-node-scroll node)
                      (- content (max 0 (- bh (ebox-geo-pt geo) (ebox-geo-pb geo))))))
          (ebox-node-w node) (+ bw (ebox--h-margins geo))
          (ebox-node-h node) (+ bh (ebox-geo-mt geo) (ebox-geo-mb geo)))
    (ebox--layout-overlays node)
    node))

;;;; Paragraph and flow layout

(defsubst ebox--align-left (align free)
  "Return the left offset of a line with FREE pixels under ALIGN."
  (pcase align
    ('center (/ (max 0 free) 2))
    ((or 'right 'end) (max 0 free))
    (_ 0)))

(defun ebox--layout-para (para width)
  "Wrap PARA's inline nodes to WIDTH pixels and cache its lines."
  (let* ((owner (ebox-para-owner para))
         (cs (ebox-node-cs owner))
         (wrap (ebox-cs-wrap cs))
         (clip (eq (ebox-cs-overflow cs) 'hidden))
         (pieces (ebox--para-cached-pieces para))
         (padface (ebox-cs-padface cs))
         (align (ebox-cs-align cs))
         (one (ebox--pieces-line-width pieces))
         (old (ebox-para-lines para))
         lines)
    (if (and one (or (<= one width) (and (memq wrap '(none nowrap)) (not clip))))
        ;; Everything fits on one line: no breaking is needed.
        (let* ((free (- width one))
               (left (ebox--align-left align free))
               (strings (mapcar #'car pieces)))
          (unless (and (zerop left) (<= free 0))
            (setq strings (cons (ebox--space left padface)
                                (nconc strings (list (ebox--space (- free left) padface))))))
          (setq lines (if (and old (= (length old) 1)) old (make-vector 1 nil)))
          (aset lines 0 (ebox--join strings)))
      (let* ((broken (ebox--break-lines pieces width wrap clip))
             (i 0))
        (setq lines (make-vector (length broken) nil))
        (dolist (line broken)
          (let* ((free (- width (cdr line)))
                 (left (ebox--align-left align free)))
            (aset lines i
                  (if (and (zerop left) (<= free 0)) (car line)
                    (ebox--join (list (ebox--space left padface) (car line)
                                      (ebox--space (- free left) padface)))))
            (setq i (1+ i))))))
    (setf (ebox-para-lines para) lines
          (ebox-para-w para) width
          (ebox-para-h para) (length lines))
    ;; Inline nodes never pass through `ebox--layout'; the paragraph owns them.
    (dolist (node (ebox-para-nodes para)) (ebox--clean-subtree node))
    para))


(defun ebox--layout-para-items (node geo nodes)
  "Lay out NODES as NODE's single paragraph; return its height.
The paragraph NODE's previous layout held for the same NODES is reused."
  (let* ((old ebox--old-items)
         (prev (and (recordp old) (= (ebox-seq-n old) 1) (ebox--seq-ref old 0)))
         (para (and prev (ebox-para-p prev) (eq (ebox-para-owner prev) node)
                    (let ((a (ebox-para-nodes prev)) (b nodes))
                      (while (and a b (eq (car a) (car b))) (setq a (cdr a) b (cdr b)))
                      (and (null a) (null b)))
                    prev)))
    (if para
        (setf (ebox-para-x para) 0 (ebox-para-y para) 0)
      (setq para (ebox-para--make :owner node :nodes nodes)))
    (ebox--layout-para para (ebox-geo-cw geo))
    (if (eq para prev)
        (setf (ebox-run-dy (ebox-para-run para)) 0
              (ebox-geo-items geo) old (ebox-geo-n geo) 1)
      (ebox--release-items old)
      (setf (ebox-geo-items geo) (ebox--seq-build (list para) #'ebox--item-ref)
            (ebox-geo-n geo) 1))
    (setf (ebox-geo-stack geo) t
          (ebox-geo-kind geo) 'stack)
    (ebox-para-h para)))

(defun ebox--stack-items (geo items gap)
  "Stack the list ITEMS with GAP lines between them in GEO; return the height."
  (let ((y 0) (first t))
    (ebox--release-items ebox--old-items)
    (dolist (item items)
      (unless first (setq y (+ y gap)))
      (setq first nil)
      (if (ebox-para-p item) (setf (ebox-para-y item) y) (setf (ebox-node-y item) y))
      (setq y (+ y (ebox--item-h item))))
    (setf (ebox-geo-items geo) (ebox--seq-build items #'ebox--item-ref)
          (ebox-geo-n geo) (length items))
    (setf (ebox-geo-stack geo) t
          (ebox-geo-kind geo) 'stack
          (ebox-geo-gap geo) gap)
    y))

(defun ebox--cross-x (node cw align)
  "Return NODE's x in CW content pixels for cross ALIGN."
  (let ((free (- cw (ebox-node-w node))))
    (pcase align
      ('center (max 0 (/ free 2)))
      ('end (max 0 free))
      (_ 0))))

(defun ebox--layout-flow (node geo cbh)
  "Lay out box NODE's block and inline children; return content height."
  (let* ((cw (ebox-geo-cw geo))
         (groups (ebox--flow-groups node))
         items)
    (if (and groups (null (cdr groups)) (consp (car groups)))
        (ebox--layout-para-items node geo (car groups))
      (dolist (group groups)
        (if (consp group)
            (push (ebox--layout-para (ebox-para--make :owner node :nodes group) cw) items)
          (ebox--layout group cw 'stretch cbh)
          (setf (ebox-node-x group) 0)
          (push group items)))
      (ebox--stack-items geo (nreverse items) 0))))

(defun ebox--layout-column (node geo cbh)
  "Lay out column NODE; return content height."
  (let* ((cs (ebox-node-cs node))
         (cw (ebox-geo-cw geo))
         (cross (ebox-cs-cross cs))
         (gap (or (ebox--lines (ebox-cs-gap cs) cs cbh) 0))
         items)
    (ebox--do-kids (child node)
      (unless (ebox--abs-p child)
        (ebox--layout child cw (if (eq cross 'stretch) 'stretch 'shrink) cbh)
        (setf (ebox-node-x child) (ebox--cross-x child cw cross))
        (push child items)))
    (ebox--stack-items geo (nreverse items) gap)))

(defun ebox--layout-row (node geo cbh)
  "Lay out row NODE; return content height."
  (let* ((cs (ebox-node-cs node))
         (cw (ebox-geo-cw geo))
         (cross (ebox-cs-cross cs))
         (gap (or (ebox--px (ebox-cs-gap cs) cs cw) 0))
         (x 0) (height 0) items)
    (ebox--do-kids (child node)
      (unless (ebox--abs-p child)
        (when items (setq x (+ x gap)))
        (let* ((avail (max 0 (- cw x)))
               (natural (ebox--natural-h child avail 'shrink cbh)))
          (setf (ebox-node-x child) x (ebox-node-y child) 0)
          (setq x (+ x (ebox-node-w child))
                height (max height natural))
          (push (list child avail natural) items))))
    (setq items (nreverse items))
    (pcase-dolist (`(,child ,avail ,natural) items)
      (ebox--place-h child avail 'shrink cbh natural
                     (and (eq cross 'stretch) (< natural height)
                          (memq (ebox-cs-height (ebox-node-cs child)) '(auto nil))
                          (not (eq (ebox-node-tag child) 'text))
                          height)))
    (setq items (mapcar #'car items))
    (dolist (child items)
      (setf (ebox-node-y child)
            (pcase cross
              ('center (/ (- height (ebox-node-h child)) 2))
              ('end (- height (ebox-node-h child)))
              (_ 0))))
    (ebox--set-items geo (vconcat items))
    (setf (ebox-geo-stack geo) nil
          (ebox-geo-kind geo) 'pos)
    height))

;;;; Partial relayout

(defvar ebox--shift nil
  "Cons (UP . DOWN) of line shifts applied by the current partial relayout.")

(defun ebox--note-shift (delta)
  "Accumulate a stack shift of DELTA lines into `ebox--shift'."
  (when (and ebox--shift (/= delta 0))
    (if (< delta 0)
        (setcar ebox--shift (+ (car ebox--shift) delta))
      (setcdr ebox--shift (+ (cdr ebox--shift) delta)))))

(defun ebox--stack-capable-p (_node geo)
  "Return non-nil when GEO's node can absorb child height changes by shifting."
  (ebox-geo-stack geo))

(defun ebox--stack-resize (node geo delta)
  "Grow stack NODE's content by DELTA lines; return nil when it must relayout.
A box whose height does not follow its content repaints its own lines."
  (or (zerop delta)
      (let* ((key (ebox--constraint node))
             (ch (+ (ebox-geo-ch geo) delta))
             (bh (ebox--resolve-height node geo ch (aref key 2) (aref key 3)))
             (vh (max 0 (- bh (ebox-geo-pt geo) (ebox-geo-pb geo))))
             (old-h (ebox-node-h node)))
        (when (= (ebox-geo-scroll geo) (max 0 (min (ebox-node-scroll node) (- ch vh))))
          (setf (ebox-geo-ch geo) ch
                (ebox-geo-bh geo) bh
                (ebox-geo-vh geo) vh
                (ebox-node-h node) (+ bh (ebox-geo-mt geo) (ebox-geo-mb geo)))
          (when (and ebox--record (/= (- (ebox-node-h node) old-h) delta))
            (ebox--damage-whole node old-h))
          t))))

(defun ebox--shift-after (geo item delta)
  "Shift GEO's stacked items after ITEM, or all when ITEM is nil, by DELTA lines.
Items in ITEM's run move one by one; later runs move by their offset."
  (let* ((seq (ebox-geo-items geo))
         (runs (ebox-seq-runs seq))
         (nr (ebox-seq-nr seq))
         (run (and item (ebox--item-run item)))
         (r (if run (ebox--seq-find-run seq run) -1)))
    (when run
      (let ((vec (ebox-run-vec run)) (i (1+ (ebox--item-pos item))) (n (ebox-run-n run)))
        (while (< i n)
          (let ((moved (aref vec i)))
            (if (ebox-para-p moved)
                (setf (ebox-para-y moved) (+ (ebox-para-y moved) delta))
              (setf (ebox-node-y moved) (+ (ebox-node-y moved) delta))))
          (setq i (1+ i)))))
    (setq r (1+ r))
    (while (< r nr)
      (let ((later (aref runs r)))
        (setf (ebox-run-dy later) (+ (ebox-run-dy later) delta)))
      (setq r (1+ r)))))

(defun ebox--stacked-p (geo item)
  "Return non-nil when ITEM is one of GEO's stacked items."
  (let ((run (ebox--item-run item)) (seq (ebox-geo-items geo)))
    (and run (recordp seq)
         (eq (aref (ebox-run-vec run) (ebox--item-pos item)) item)
         (let ((r (ebox--seq-find-run seq run)))
           (and r (eq (aref (ebox-seq-runs seq) r) run))))))

(defun ebox--absorb (node geo changed)
  "Absorb CHANGED (ITEM OLD-W OLD-H) height changes in stack NODE.
Return non-nil on success."
  (when (ebox--stack-capable-p node geo)
    (let ((cs (ebox-node-cs node)) (delta-total 0))
      (catch 'fail
        (dolist (entry changed)
          (let ((item (car entry)))
            (unless (ebox--stacked-p geo item) (throw 'fail nil))
            (when (and (not (ebox-para-p item))
                       (/= (nth 1 entry) (ebox-node-w item)))
              ;; Width changes only move the item inside the content box.
              (if (and (eq (ebox-node-tag node) 'column)
                       (not (memq (ebox-cs-width cs) '(min-content max-content fit-content)))
                       (not (eq (aref (ebox--constraint node) 1) 'shrink)))
                  (setf (ebox-node-x item)
                        (ebox--cross-x item (ebox-geo-cw geo) (ebox-cs-cross cs)))
                (throw 'fail nil)))
            (let ((delta (- (ebox--item-h item) (nth 2 entry))))
              (unless (zerop delta)
                (ebox--shift-after geo item delta)
                (ebox--note-shift delta)
                (setq delta-total (+ delta-total delta))))))
        ;; Child nodes recorded their own damage; paragraphs do not.
        (dolist (entry changed)
          (when (and ebox--record (ebox-para-p (car entry)))
            (setq ebox--damage
                  (cons (list (car entry) 0 (nth 2 entry) (ebox--item-h (car entry)))
                        ebox--damage))))
        (ebox--stack-resize node geo delta-total)))))

(defun ebox--para-of (geo node)
  "Return the paragraph of GEO containing inline NODE, or nil."
  (catch 'found
    (ebox--do-items (item geo)
      (when (and (ebox-para-p item)
                 (cl-some (lambda (n) (ebox-node-ancestor-p n node))
                          (ebox-para-nodes item)))
        (throw 'found item)))
    nil))

(defun ebox--clean-subtree (node)
  "Clear layout dirt below inline NODE after its paragraph relayout.
Absolutely positioned descendants stay dirty; their host lays them out."
  (ebox--drop-dkids node)
  (setf (ebox-node-dirty node) (logand (ebox-node-dirty node) ebox--d-queued))
  (ebox--do-kids (child node)
    (unless (ebox--abs-p child) (ebox--clean-subtree child))))

(defun ebox--content-stable-p (geo kid)
  "Return non-nil when KID's relayout cannot move its siblings in GEO's node.
Flex and grid containers size children from the intrinsic widths recorded
in their seen slot, so a kid whose margin-box intrinsic widths changed,
including through a dirty descendant, requires relaying out NODE."
  (or (not (eq (ebox-geo-kind geo) 'pos))
      (let ((seen (ebox-node-seen kid)))
        (or (null seen) (equal seen (ebox--outer-intrinsic kid (ebox-geo-cw geo)))))))

(defun ebox--border-damage (node geo old-bh)
  "Repaint NODE's border lines whose position moved since OLD-BH lines.
Top and bottom borders decorate the first and last border-box lines, so a
height change moves them without changing the lines it inserted or deleted."
  (let* ((cs (ebox-node-cs node))
         (bh (ebox-geo-bh geo))
         (delta (- bh old-bh))
         (mt (ebox-geo-mt geo)))
    (when (and ebox--record (/= delta 0) (> bh 0))
      (when (ebox-cs-bbot cs)
        (push (list (list 'lines node (+ mt (1- bh)) 'border) 0 1 1) ebox--damage)
        (when (and (> delta 0) (> old-bh 0))
          (push (list (list 'lines node (+ mt (1- old-bh)) 'border) 0 1 1) ebox--damage)))
      (when (ebox-cs-btop cs)
        (push (list (list 'lines node mt 'border) 0 1 1) ebox--damage)
        (when (and (> delta 0) (< delta bh))
          (push (list (list 'lines node (+ mt delta) 'border) 0 1 1) ebox--damage))))))

(defun ebox--relayout-partial (node)
  "Relayout NODE's dirty descendants while its constraints are unchanged."
  (let* ((geo (ebox-node-layout node))
         (old-bh (ebox-geo-bh geo))
         (kids (ebox-node-dkids node))
         (ops (reverse (ebox-node-ops node)))
         (ebox--shift (cons 0 0))
         changed full)
    (setf (ebox-node-dkids node) nil
          (ebox-node-ops node) nil)
    (ebox--uncache node)
    (dolist (kid kids)
      (setf (ebox-node-dirty kid) (logand (ebox-node-dirty kid) (lognot ebox--d-queued))))
    (setf (ebox-node-dirty node) (logand (ebox-node-dirty node) (lognot ebox--d-desc)))
    (when ops
      (unless (ebox--apply-ops node geo ops)
        (setq full t)))
    (unless full
      (dolist (kid kids)
        (when (and (not full)
                   (eq (ebox-node-parent kid) node)
                   (not (zerop (logand (ebox-node-dirty kid) 15)))
                   (not (ebox--abs-p kid))
                   (or (ebox--content-stable-p geo kid) (progn (setq full t) nil)))
          (let* ((flow (eq (ebox-node-tag node) 'box))
                 (para (and flow (ebox--inline-p kid) (ebox--para-of geo kid))))
            (cond
             (para
              (let ((oh (ebox-para-h para)))
                (ebox--layout-para para (ebox-para-w para))
                (if (= oh (ebox-para-h para))
                    (when ebox--record
                      (setq ebox--damage (cons (list para 0 oh oh) ebox--damage)))
                  (push (list para (ebox-para-w para) oh) changed))))
             ((and flow (ebox--inline-p kid)) (setq full t))
             (t
              (let* ((ow (ebox-node-w kid)) (oh (ebox-node-h kid))
                     (key (ebox--constraint kid))
                     (nat (and key (aref key 3) (ebox-geo-nat (ebox-node-layout kid)))))
                (if (null key)
                    (setq full t)
                  (when (and (ebox--layout kid (aref key 0) (aref key 1) (aref key 2)
                                           (aref key 3))
                             (aref key 3))
                    ;; NODE derived KID's forced height from KID's natural
                    ;; height; measure again when that may have changed.
                    (let ((new (ebox--stretched-natural kid)))
                      (setf (ebox-geo-nat (ebox-node-layout kid)) new)
                      (unless (and new nat (= new nat))
                        (setq full t))))
                  (unless (and (= ow (ebox-node-w kid)) (= oh (ebox-node-h kid)))
                    (push (list kid ow oh) changed))))))))))
    (when (and changed (not full))
      (unless (ebox--absorb node geo (nreverse changed))
        (setq full t)))
    (if full
        (let ((key (ebox--constraint node)))
          (setf (ebox-node-intr node) nil)
          (ebox--layout-full node (aref key 0) (aref key 1) (aref key 2) (aref key 3))
          t)
      (ebox--border-damage node geo old-bh)
      (ebox--relayout-overlays node ebox--shift)
      (and (or changed ops) t))))

(defun ebox--apply-ops (node geo ops)
  "Apply structural OPS to stack NODE incrementally; nil requests full layout."
  (when (and (memq (ebox-node-tag node) '(column))
             (ebox--stack-capable-p node geo)
             (< (length ops) 64)
             (cl-every (lambda (op) (memq (car op) '(insert remove))) ops))
    (let* ((cs (ebox-node-cs node))
           (cw (ebox-geo-cw geo))
           (cross (ebox-cs-cross cs))
           (gap (or (ebox-geo-gap geo) 0))
           (key (ebox--constraint node))
           (cbh (and key (ebox--definite-height node geo (aref key 2) (aref key 3))))
           (total 0)
           recorded)
      (catch 'fail
        (dolist (op ops)
          (let ((items (ebox-geo-items geo)) (n (ebox-geo-n geo)))
            (pcase op
              (`(insert ,child)
               ;; A moved child keeps its layout but has left the items.
               (when (or (not (eq (ebox-node-parent child) node)) (ebox--abs-p child)
                         (ebox--inline-p child) (ebox--stacked-p geo child))
                 (throw 'fail nil))
               (let* ((prev (ebox--prev-stacked node geo child))
                      (index (if (eq prev 'none) (throw 'fail nil)
                               (if prev (+ (ebox-run-start (ebox-node-irun prev))
                                           (ebox-node-ipos prev) 1)
                                 0)))
                      (prev (and (ebox-node-p prev) prev))
                      (y (if prev (+ (ebox--item-y prev) (ebox--item-h prev) gap) 0)))
                 (ebox--layout child cw (if (eq cross 'stretch) 'stretch 'shrink) cbh)
                 (setf (ebox-node-irun child) nil
                       (ebox-node-x child) (ebox--cross-x child cw cross))
                 (let* ((h (ebox-node-h child))
                        (extra (if (> n 0) gap 0))
                        (delta (+ h extra))
                        (run (ebox--seq-insert items index child #'ebox--item-ref)))
                   (setf (ebox-node-y child) (- y (ebox-run-dy run))
                         (ebox-geo-n geo) (1+ n))
                   (ebox--shift-after geo child delta)
                   (ebox--note-shift delta)
                   (setq total (+ total delta))
                   (when ebox--record
                     (let ((start (if prev (- y extra) y)))
                       (setq recorded (ebox--shift-recorded recorded start 0 delta))
                       (push (list (list 'lines node start) 0 0 delta) recorded)
                       (push (car recorded) ebox--damage))))))
              (`(remove ,child ,_old-y ,old-h)
               (unless (ebox--stacked-p geo child) (throw 'fail nil))
               (let* ((run (ebox-node-irun child))
                      (index (+ (ebox-run-start run) (ebox-node-ipos child)))
                      (old-y (ebox--item-y child))
                      (prev (and (> index 0) (ebox--seq-ref items (1- index)))))
                 (let* ((last (= index (1- n)))
                        (extra (if (> n 1) gap 0))
                        (delta (+ old-h extra))
                        (start (if (and last (> index 0)) (- old-y extra) old-y)))
                   (ebox--seq-delete items run (ebox-node-ipos child) #'ebox--item-ref)
                   (setf (ebox-node-irun child) nil
                         (ebox-geo-n geo) (1- n))
                   (if prev
                       (ebox--shift-after geo prev (- delta))
                     (ebox--shift-after geo nil (- delta)))
                   (ebox--note-shift (- delta))
                   (setq total (- total delta))
                   (when ebox--record
                     (setq recorded (ebox--shift-recorded recorded start delta 0))
                     (push (list (list 'lines node start) 0 delta 0) recorded)
                     (push (car recorded) ebox--damage))))))))
        (ebox--stack-resize node geo total)))))

(defun ebox--shift-recorded (recorded start old new)
  "Move RECORDED line damages past an edit of OLD lines to NEW at START.
Each damage is stated in the lines that exist after it, so a later edit
before it moves it.  Throw `fail' when the edit overlaps a recorded range."
  (let ((delta (- new old)) (end (+ start old)))
    (dolist (damage recorded recorded)
      (let* ((item (car damage)) (at (nth 2 item)) (lines (nth 3 damage)))
        (cond ((>= at end) (setf (nth 2 item) (+ at delta)))
              ((and (zerop lines) (>= at start)) (setf (nth 2 item) start))
              ((<= (+ at lines) start))
              (t (throw 'fail nil)))))))

(defun ebox--prev-stacked (node geo child)
  "Return the stacked item of GEO that CHILD follows, nil when it comes first.
The items are NODE's laid-out in-flow children, so CHILD follows the
nearest such sibling before it.  Return the symbol none when that sibling
is not one of GEO's items."
  (let ((prev (ebox--prev-kid child)) found)
    (while (and prev (not found))
      (if (and (ebox-node-layout prev) (not (ebox--abs-p prev)))
          (setq found prev)
        (setq prev (ebox--prev-kid prev))))
    (cond ((null found) nil)
          ((and (eq (ebox-node-parent found) node) (ebox--stacked-p geo found)) found)
          (t 'none))))

;;;; Images

(declare-function ebox-image--lines "ebox-image" (image))
(declare-function ebox-image--width "ebox-image" (image))

(defun ebox--image-width (node)
  "Return image NODE's content width in pixels."
  (ebox-image--width (ebox-node-image node)))

(defun ebox--layout-image (node geo)
  "Lay out image NODE; return its content height."
  (let ((lines (ebox-image--lines (ebox-node-image node))))
    (setf (ebox-geo-kind geo) 'image)
    (ebox--set-items geo (vconcat lines))
    (length lines)))

;;;; Overlays (absolutely positioned descendants)

(defun ebox--host-cs-p (cs)
  "Return non-nil when a node styled CS hosts absolutely positioned nodes.
Inline boxes may lack box geometry of their own, so they never host."
  (and (not (memq (ebox-cs-position cs) '(static nil)))
       (not (eq (ebox-cs-outer cs) 'inline))))

(defun ebox--host-of (node)
  "Return the positioning host of absolutely positioned NODE."
  (if (eq (ebox--cv (ebox-node-cs node) 'ebox/layer) 'root)
      (ebox-node-root node)
    (let ((parent (ebox-node-parent node)))
      (while (and (ebox-node-parent parent)
                  (not (ebox--host-cs-p (ebox-node-cs parent))))
        (setq parent (ebox-node-parent parent)))
      parent)))

(defun ebox--register-overlay (node)
  "Register absolutely positioned NODE with its host."
  (let* ((host (ebox--host-of node))
         (list (ebox-node-overlays host)))
    (unless (memq node list)
      (setf (ebox-node-overlays host) (append list (list node))))
    (setf (ebox-node-host node) host)
    host))

(defun ebox--live-overlays (host)
  "Return HOST's overlays that are still attached under it."
  (let ((list (ebox-node-overlays host)) live)
    (dolist (node list)
      (when (and (ebox-node-cs node) (ebox--abs-p node)
                 (eq (ebox-node-host node) host)
                 (ebox-node-ancestor-p host node))
        (push node live)))
    (setq live (nreverse live))
    (unless (= (length live) (length list))
      (setf (ebox-node-overlays host) live))
    live))

(defun ebox--doc-path (node)
  "Return NODE's child-index path from its root."
  (let (path)
    (while (ebox-node-parent node)
      (push (ebox-node-index node) path)
      (setq node (ebox-node-parent node)))
    path))

(defun ebox--doc-before-p (a b)
  "Return non-nil when node A precedes node B in document order."
  (let ((pa (ebox--doc-path a)) (pb (ebox--doc-path b)))
    (while (and pa pb (= (car pa) (car pb)))
      (setq pa (cdr pa) pb (cdr pb)))
    (if (and pa pb) (< (car pa) (car pb)) (and pb t))))

(defun ebox--ordered-overlays (host)
  "Return HOST's live overlays, kept in document order for equal z-index."
  (let ((live (ebox--live-overlays host)))
    (when (cdr live)
      (setq live (sort (copy-sequence live) #'ebox--doc-before-p))
      (setf (ebox-node-overlays host) live))
    live))

(defun ebox--root-xy (node)
  "Return (X . Y) of NODE's margin box in root margin-box coordinates."
  (let ((parent (ebox-node-parent node)))
    (cond
     ((null parent) (cons 0 0))
     ((null (ebox-node-layout node)) (ebox--root-xy parent))
     ((ebox--abs-p node)
      (let* ((host (ebox-node-host node))
             (hgeo (ebox-node-layout host))
             (origin (ebox--root-xy host)))
        (cons (+ (car origin) (ebox-geo-ml hgeo) (ebox-node-x node))
              (+ (cdr origin) (ebox-geo-mt hgeo) (ebox-node-y node)))))
     (t
      (let* ((geo (ebox-node-layout parent))
             (origin (ebox--root-xy parent)))
        (cons (+ (car origin) (ebox-geo-ml geo) (ebox-geo-bl geo) (ebox-geo-pl geo)
                 (ebox-node-x node))
              (+ (cdr origin) (ebox-geo-mt geo) (ebox-geo-pt geo)
                 (- (ebox-geo-scroll geo)) (ebox--item-y node))))))))

(defun ebox--find-anchor (host id)
  "Find the node with ID under HOST's root tree."
  (let ((name (ebox--token id)) found)
    (catch 'done
      (ebox-node-walk (ebox-node-root host)
                      (lambda (node)
                        (when (equal (ebox-node-id node) name)
                          (setq found node) (throw 'done nil)))))
    found))

(defvar ebox--anchor-targets (make-hash-table :test 'eq :weakness 'key)
  "The resolved anchor target of each anchored overlay.")

(defun ebox--anchor-target (host node id)
  "Return the node with ID that overlay NODE in HOST is anchored to."
  (let ((cached (gethash node ebox--anchor-targets)))
    (if (and cached (equal (ebox-node-id cached) (ebox--token id))
             (eq (ebox-node-root cached) (ebox-node-root host)))
        cached
      (let ((found (ebox--find-anchor host id)))
        (if found
            (puthash node found ebox--anchor-targets)
          (remhash node ebox--anchor-targets))
        found))))

(defun ebox--place-overlay (host node)
  "Resolve absolutely positioned NODE's origin in HOST's border box."
  (let* ((cs (ebox-node-cs node))
         (hgeo (ebox-node-layout host))
         (width (ebox-geo-bw hgeo))
         (height (ebox-geo-bh hgeo))
         (x (+ (ebox-geo-bl hgeo)
               (or (ebox--px (ebox--cv cs 'ebox/left) cs
                             (- width (ebox-geo-bl hgeo) (ebox-geo-br hgeo)))
                   0)))
         (y (or (ebox--lines (ebox--cv cs 'ebox/top) cs height) 0))
         (anchor (ebox--cv cs 'ebox/anchor)))
    (if (not anchor)
        (cons x y)
      (let ((target (ebox--anchor-target host node anchor)))
        ;; An anchor inside the overlay itself would follow its own placement.
        (when (and target (ebox-node-layout target) (not (ebox--hidden-p target))
                   (not (ebox-node-ancestor-p node target)))
          (let* ((target-xy (ebox--root-xy target))
                 (host-xy (ebox--root-xy host))
                 (hgeo* (ebox-node-layout host))
                 (tgeo (ebox-node-layout target))
                 (tx (- (+ (car target-xy) (ebox-geo-ml tgeo))
                        (car host-xy) (ebox-geo-ml hgeo*)))
                 (ty (- (+ (cdr target-xy) (ebox-geo-mt tgeo))
                        (cdr host-xy) (ebox-geo-mt hgeo*)))
                 (tw (ebox-geo-bw tgeo)) (th (ebox-geo-bh tgeo))
                 (lw (ebox-node-w node)) (lh (ebox-node-h node))
                 (placement (or (ebox--cv cs 'ebox/placement) 'bottom-start))
                 (above (memq placement '(top-start top-end)))
                 (left (+ tx x (if (memq placement '(bottom-end top-end)) (- tw lw) 0)))
                 (top (+ y ty (if above (- lh) th)))
                 (other (+ y ty (if above th (- lh)))))
            (when (and (or (< top 0) (> (+ top lh) height))
                       (>= other 0) (<= (+ other lh) height))
              (setq top other))
            (cons (max 0 (min left (max 0 (- width lw))))
                  (max 0 (min top (max 0 (- height lh)))))))))))

(defun ebox--layout-overlay (host node)
  "Lay out and place overlay NODE in HOST; return non-nil when it changed."
  (let* ((hgeo (ebox-node-layout host))
         (old (list (ebox-node-x node) (ebox-node-y node) (ebox-node-w node) (ebox-node-h node)
                    (ebox-node-placed node)))
         (ebox--record nil))
    (ebox--layout node (ebox-geo-bw hgeo) 'shrink (ebox-geo-bh hgeo))
    (let ((origin (ebox--place-overlay host node)))
      (setf (ebox-node-x node) (if origin (car origin) 0)
            (ebox-node-y node) (if origin (cdr origin) 0))
      (setf (ebox-node-placed node) (and origin t))
      (not (equal old (list (ebox-node-x node) (ebox-node-y node) (ebox-node-w node)
                            (ebox-node-h node) (and origin t)))))))

(defun ebox--layout-overlays (host)
  "Lay out every overlay registered on HOST after its flow layout."
  (dolist (node (ebox--ordered-overlays host))
    (setf (ebox-node-dirty node) (logior (ebox-node-dirty node) ebox--d-layout))
    (ebox--layout-overlay host node)))

(defun ebox--relayout-overlays (host &optional shift)
  "Relayout HOST's overlays and record damage for those that changed.
SHIFT is (UP . DOWN), the extreme line shifts HOST's flow content received;
lines that showed an overlay before the shift must be repainted as well."
  (let* ((moved (and shift (or (/= 0 (car shift)) (/= 0 (cdr shift)))))
         (before (ebox--live-overlays host))
         (after (ebox--ordered-overlays host))
         ;; Overlays repaint in their new stacking order.
         (reordered (not (cl-every #'eq before after)))
         (up (if moved (car shift) 0))
         (down (if moved (cdr shift) 0)))
    (when ebox--record
      (dolist (span (gethash host ebox--vacated))
        (ebox--overlay-damage host (+ (car span) up) (+ (cdr span) (- down up)))))
    (remhash host ebox--vacated)
    (dolist (node after)
      (let* ((oy (ebox-node-y node)) (oh (ebox-node-h node))
             (was-placed (ebox-node-placed node))
             (dirty (or reordered (/= 0 (ebox-node-dirty node))))
             (changed (ebox--layout-overlay host node)))
        (when (and ebox--record (or changed dirty (and moved (or was-placed (ebox-node-placed node)))))
          (let* ((hgeo (ebox-node-layout host))
                 (up (if moved (car shift) 0)) (down (if moved (cdr shift) 0))
                 (top (+ (ebox-geo-mt hgeo) (min (+ oy up) (ebox-node-y node))))
                 (bottom (+ (ebox-geo-mt hgeo)
                            (max (+ oy oh down) (+ (ebox-node-y node) (ebox-node-h node)))))
                 (top (max 0 (min top (ebox-node-h host))))
                 (bottom (max top (min bottom (ebox-node-h host)))))
            (when (> bottom top)
              (push (list (list 'lines host top 'border) 0 (- bottom top) (- bottom top))
                    ebox--damage))))))))

(defun ebox--overlay-damage (host y h)
  "Record damage for HOST's border-box lines Y to Y+H under an overlay."
  (let* ((hgeo (ebox-node-layout host))
         (top (max 0 (min (+ (ebox-geo-mt hgeo) y) (ebox-node-h host))))
         (bottom (max top (min (+ top h) (ebox-node-h host)))))
    (when (> bottom top)
      (push (list (list 'lines host top 'border) 0 (- bottom top) (- bottom top))
            ebox--damage))))

(defun ebox--anchored-p (node)
  "Return non-nil when NODE is an anchored overlay."
  (let ((cs (ebox-node-cs node)))
    (and cs (ebox-cs-abs cs) (ebox-node-parent node) (ebox--cv cs 'ebox/anchor) t)))

(defun ebox--collect-anchored (root)
  "Return the anchored overlays under ROOT."
  (let (found)
    (ebox-node-walk root (lambda (node) (when (ebox--anchored-p node) (push node found))))
    found))

(defun ebox--place-anchored (root overlays)
  "Place anchored OVERLAYS of ROOT after layout and return the live ones.
Anchor targets may move without relaying out an overlay's host, and a target
may sit inside another overlay, so placement repeats until it settles."
  (let* ((live (cl-remove-if-not
                (lambda (node)
                  (let ((host (ebox-node-host node)))
                    (and (ebox--anchored-p node) host
                         (ebox-node-layout host) (ebox-node-layout node)
                         (ebox-node-ancestor-p host node)
                         (eq (ebox-node-root node) root))))
                overlays))
         (rounds (1+ (length live)))
         (moved t))
    (while (and moved (> rounds 0))
      (setq moved nil rounds (1- rounds))
      (dolist (node live)
        (let* ((host (ebox-node-host node))
               (origin (ebox--place-overlay host node))
               (x (if origin (car origin) 0))
               (y (if origin (cdr origin) 0)))
          (unless (and (= x (ebox-node-x node)) (= y (ebox-node-y node))
                       (eq (and origin t) (ebox-node-placed node)))
            (when (and ebox--record (ebox-node-placed node))
              (ebox--overlay-damage host (ebox-node-y node) (ebox-node-h node)))
            (setf (ebox-node-x node) x (ebox-node-y node) y
                  (ebox-node-placed node) (and origin t))
            (when (and ebox--record origin)
              (ebox--overlay-damage host y (ebox-node-h node)))
            (setq moved t)))))
    live))

;;;; Composition

(defsubst ebox--parent-padface (node)
  "Return the face of the area around NODE's border box."
  (let ((parent (ebox-node-parent node)))
    (and parent (ebox-cs-padface (ebox-node-cs parent)))))

(defun ebox--item-parts (item i tail)
  "Return the strings of line I of ITEM's margin box followed by TAIL."
  (if (ebox-para-p item)
      (let ((lines (ebox-para-lines item)))
        (cons (if (< i (length lines)) (aref lines i)
                (ebox--space (ebox-para-w item)
                             (ebox-cs-padface (ebox-node-cs (ebox-para-owner item)))))
              tail))
    (cons (ebox--node-parts item i) tail)))

(defun ebox--find-item (geo ci)
  "Return the stacked item in GEO covering content line CI, or nil."
  (let* ((seq (ebox-geo-items geo))
         (runs (ebox-seq-runs seq))
         (lo 0) (hi (1- (ebox-seq-nr seq))))
    ;; The last run whose first item starts at or before CI.
    (while (< lo hi)
      (let ((mid (/ (+ lo hi 1) 2)))
        (if (<= (ebox--item-y (aref (ebox-run-vec (aref runs mid)) 0)) ci)
            (setq lo mid)
          (setq hi (1- mid)))))
    (when (>= hi 0)
      (let* ((run (aref runs lo)) (vec (ebox-run-vec run)) (dy (ebox-run-dy run))
             (lo 0) (hi (1- (ebox-run-n run))) found)
        (while (and (<= lo hi) (not found))
          (let* ((mid (/ (+ lo hi) 2))
                 (item (aref vec mid))
                 (y (+ dy (if (ebox-para-p item) (ebox-para-y item) (ebox-node-y item)))))
            (cond ((< ci y) (setq hi (1- mid)))
                  ((>= ci (+ y (ebox--item-h item))) (setq lo (1+ mid)))
                  (t (setq found item)))))
        found))))

(defun ebox--content-parts (node geo ci tail)
  "Return the strings of content line CI of NODE followed by TAIL.
The strings span the content width CW in pixels."
  (let* ((cw (ebox-geo-cw geo))
         (padface (ebox-cs-padface (ebox-node-cs node)))
         (items (ebox-geo-items geo)))
    (pcase (ebox-geo-kind geo)
      ('image (cons (if (< ci (ebox-geo-n geo)) (aref items ci) (ebox--space cw padface))
                    tail))
      ('stack
       (let ((item (ebox--find-item geo ci)))
         (if (null item)
             (cons (ebox--space cw padface) tail)
           (let ((x (ebox--item-x item)))
             (cons (ebox--space x padface)
                   (ebox--item-parts item (- ci (ebox--item-y item))
                                     (cons (ebox--space (- cw x (ebox--item-w item)) padface)
                                           tail)))))))
      (_
       (let ((cursor 0) (hits nil) (sorted t) (last -1) (shown nil))
         (dotimes (i (ebox-geo-n geo))
           (let* ((item (aref items i))
                  (y (ebox--item-y item)))
             (when (and (>= ci y) (< ci (+ y (ebox--item-h item))))
               (when (< (ebox--item-x item) last) (setq sorted nil))
               (setq last (ebox--item-x item))
               (push item hits))))
         (setq hits (nreverse hits))
         (unless sorted
           (setq hits (sort hits (lambda (a b) (< (ebox--item-x a) (ebox--item-x b))))))
         ;; Items overlapping an earlier one are not shown; SHOWN holds the
         ;; rest with the gap before each, last first.
         (dolist (item hits)
           (let ((x (ebox--item-x item)))
             (when (>= x cursor)
               (push (cons (- x cursor) item) shown)
               (setq cursor (+ x (ebox--item-w item))))))
         (setq tail (cons (ebox--space (- cw cursor) padface) tail))
         (dolist (entry shown tail)
           (setq tail (cons (ebox--space (car entry) padface)
                            (ebox--item-parts (cdr entry)
                                              (- ci (ebox--item-y (cdr entry)))
                                              tail)))))))))

(defun ebox--border-parts (node geo bi tail)
  "Return the strings of border-box line BI of NODE followed by TAIL.
Overlays and top or bottom borders decorate the whole border-box line, which
is then joined into one string."
  (let* ((cs (ebox-node-cs node))
         (padface (ebox-cs-padface cs))
         (pt (ebox-geo-pt geo))
         (top (and (ebox-cs-btop cs) (= bi 0)))
         (bottom (and (ebox-cs-bbot cs) (= bi (1- (ebox-geo-bh geo)))))
         (whole (or top bottom (ebox-node-overlays node)))
         (parts (if whole nil tail)))
    (when (ebox-cs-brc cs)
      (push (ebox--space 1 (ebox--border-face (ebox-cs-brc cs))) parts))
    (setq parts
          (if (or (< bi pt) (>= bi (+ pt (ebox-geo-vh geo))))
              (cons (ebox--space (- (ebox-geo-bw geo) (ebox-geo-bl geo) (ebox-geo-br geo))
                                 padface)
                    parts)
            (cons (ebox--space (ebox-geo-pl geo) padface)
                  (ebox--content-parts
                   node geo (+ (- bi pt) (ebox-geo-scroll geo))
                   (cons (ebox--space (ebox-geo-pr geo) padface) parts)))))
    (when (ebox-cs-blc cs)
      (push (ebox--space 1 (ebox--border-face (ebox-cs-blc cs))) parts))
    (if (not whole)
        parts
      (let ((line (ebox--join parts)))
        (when (ebox-node-overlays node)
          (setq line (ebox--apply-overlays node geo bi line)))
        (when (or top bottom)
          (setq line (copy-sequence line))
          (when top
            (add-face-text-property 0 (length line)
                                    (list :overline (let ((c (ebox-cs-btc cs)))
                                                      (if (eq c 'default) t c)))
                                    t line))
          (when bottom
            (add-face-text-property 0 (length line)
                                    (list :underline
                                          (list :position t
                                                :color (let ((c (ebox-cs-bbc cs)))
                                                         (if (eq c 'default) 'foreground-color c))))
                                    t line)))
        (cons line tail)))))

(defconst ebox--line-cache-max 256
  "Largest margin-box height whose composed lines a node caches.")

(defun ebox--uncache (node)
  "Forget the composed lines of NODE and of every box composing them.
A box composes a child's line only through `ebox--node-parts', which leaves
the child's LINES non-nil, so a box whose LINES is nil has no composed line
on any ancestor and the walk stops there."
  (while (and node (ebox-node-lines node))
    (setf (ebox-node-lines node) nil)
    (when (ebox--abs-p node) (ebox--uncache (ebox-node-host node)))
    (setq node (ebox-node-parent node))))

(defun ebox--node-parts (node i)
  "Return the strings composing line I of NODE's margin box.
The list is cached on NODE and shared; callers copy it before changing it."
  (let* ((cache (ebox-node-lines node))
         (hit (and (vectorp cache) (< i (length cache)) (aref cache i))))
    (or hit
        (let ((parts (or (ebox--compose-parts node i) (list ""))))
          (cond
           ((vectorp cache) (when (< i (length cache)) (aset cache i parts)))
           ((<= (ebox-node-h node) ebox--line-cache-max)
            (let ((vec (make-vector (ebox-node-h node) nil)))
              (when (< i (length vec)) (aset vec i parts))
              (setf (ebox-node-lines node) vec)))
           (t (setf (ebox-node-lines node) t)))
          parts))))

(defun ebox--node-line (node i)
  "Return line I of NODE's margin box as one string."
  (ebox--join (ebox--node-parts node i)))

(defun ebox--compose-parts (node i)
  "Compose the strings of line I of NODE's margin box.
A node composes its margins, borders, padding and items into one flat list of
its descendants' strings, so a line is concatenated once when it is written.
An interactive node joins its line to carry its interaction properties."
  (let* ((geo (ebox-node-layout node))
         (mt (ebox-geo-mt geo))
         (parts
          (if (or (< i mt) (>= i (+ mt (ebox-geo-bh geo))) (ebox--hidden-p node))
              (list (ebox--space (ebox-node-w node) (ebox--parent-padface node)))
            (let* ((ml (ebox-geo-ml geo)) (mr (ebox-geo-mr geo))
                   (face (and (or (> ml 0) (> mr 0)) (ebox--parent-padface node))))
              (cons (ebox--space ml face)
                    (ebox--border-parts node geo (- i mt)
                                        (list (ebox--space mr face))))))))
    (if (and (ebox-node-inter node) ebox--decorate-function)
        (list (funcall ebox--decorate-function node (ebox--join parts)))
      parts)))

(defun ebox--char-px (string pos)
  "Return (NEXT . WIDTH) of the display unit at POS in composed STRING."
  (let* ((display (get-text-property pos 'display string))
         (space (and display (ebox--fixed-space-width display))))
    (cond
     (space (cons (1+ pos) space))
     (display
      (let ((next (or (next-single-property-change pos 'display string) (length string))))
        (cons next (ebox--measure-raw (substring string pos next)))))
     (t (let ((next (ebox--cluster-end string pos (length string))))
          (cons next
                (if (= next (1+ pos))
                    (ebox--char-width (aref string pos) (get-text-property pos 'face string))
                  (ebox--measure-raw (substring string pos next)))))))))

(defun ebox--split-at (string x)
  "Split composed STRING at pixel X; return (LEFT . RIGHT).
A unit straddling X is replaced by spaces of the two partial widths."
  (let ((pos 0) (px 0) (len (length string)) result)
    (while (and (< pos len) (not result))
      (pcase-let ((`(,next . ,w) (ebox--char-px string pos)))
        (cond
         ((= px x) (setq result (cons (substring string 0 pos) (substring string pos))))
         ((> (+ px w) x)
          (let ((face (get-text-property pos 'face string)))
            (setq result (cons (ebox--join (list (substring string 0 pos)
                                                 (ebox--space (- x px) face)))
                               (ebox--join (list (ebox--space (- (+ px w) x) face)
                                                 (substring string next)))))))
         (t (setq px (+ px w) pos next)))))
    (or result
        (if (>= x px) (cons (ebox--join (list string (ebox--space (- x px) nil))) "")
          (cons string "")))))

(defun ebox--splice (base x segment width)
  "Replace pixels X..X+WIDTH of BASE with SEGMENT."
  (let* ((head (ebox--split-at base x))
         (tail (ebox--split-at (cdr head) width)))
    (ebox--join (list (car head) segment (cdr tail)))))

(defun ebox--apply-overlays (host geo bi line)
  "Splice HOST's overlays intersecting border-box line BI into LINE.
Border decorations are applied afterwards, so they continue across overlays."
  (let ((overlays (ebox--live-overlays host))
        (bw (ebox-geo-bw geo)))
    (when overlays
      (setq overlays
            (sort (copy-sequence overlays)
                  (lambda (a b) (< (ebox-cs-z (ebox-node-cs a)) (ebox-cs-z (ebox-node-cs b))))))
      (dolist (node overlays)
        (when (and (ebox-node-placed node)
                   (not (ebox--hidden-p node)))
          (let ((row (- bi (ebox-node-y node))))
            (when (and (>= row 0) (< row (ebox-node-h node)))
              (let* ((x (ebox-node-x node))
                     (skip (max 0 (- x)))
                     (x (max 0 x))
                     (w (min (- (ebox-node-w node) skip) (max 0 (- bw x)))))
                (when (> w 0)
                  (let ((segment (ebox--node-line node row)))
                    (when (> skip 0)
                      (setq segment (cdr (ebox--split-at segment skip))))
                    (when (< w (- (ebox-node-w node) skip))
                      (setq segment (car (ebox--split-at segment w))))
                    (setq line (ebox--splice line x segment w))))))))))
    line))

(defun ebox--root-line (root i)
  "Return line I of ROOT as written to a buffer."
  (ebox--node-line root i))

(defun ebox--root-parts (root i)
  "Return the strings that line I of ROOT writes to a buffer, in order."
  (ebox--join-parts (ebox--node-parts root i)))

(defun ebox--node-lines (node from to)
  "Return NODE's margin-box lines FROM (inclusive) TO (exclusive)."
  (let (lines)
    (cl-loop for i from from below to
             do (push (ebox--node-line node i) lines))
    (nreverse lines)))

;;;; Damage to root lines

(defun ebox--item-top-in-root (item)
  "Return ITEM's first line in root margin-box coordinates."
  (cond
   ((ebox-para-p item)
    (let* ((owner (ebox-para-owner item))
           (geo (ebox-node-layout owner)))
      (+ (ebox--item-y item) (ebox-geo-mt geo) (ebox-geo-pt geo) (- (ebox-geo-scroll geo))
         (ebox--item-top-in-root owner))))
   ((null (ebox-node-parent item)) 0)
   ((ebox--abs-p item)
    (let ((host (ebox-node-host item)))
      (+ (ebox-node-y item) (ebox-geo-mt (ebox-node-layout host))
         (ebox--item-top-in-root host))))
   (t
    (let* ((owner (ebox-node-parent item))
           (geo (ebox-node-layout owner)))
      (+ (ebox--item-y item) (ebox-geo-mt geo) (ebox-geo-pt geo) (- (ebox-geo-scroll geo))
         (ebox--item-top-in-root owner))))))

(defun ebox--clip-parent (node)
  "Return the node whose content box positions NODE: its host or parent."
  (if (and (ebox-node-cs node) (ebox--abs-p node))
      (ebox-node-host node)
    (ebox-node-parent node)))

(defun ebox--clip-range (range node)
  "Restrict root-line RANGE (START OLD NEW WHOLE) to the lines NODE's clips show.
NODE is the innermost node whose content box holds RANGE; every clipping
node from NODE outward keeps only its visible content lines, and a height
change shifts the clipped lines below it.  Return nil when no shown line
changes."
  (pcase-let ((`(,start ,old ,new ,whole) range))
    (while (and node start)
      (let ((geo (ebox-node-layout node)))
        (when (and geo (or (> (ebox-geo-ch geo) (ebox-geo-vh geo))
                           (> (ebox-geo-scroll geo) 0)))
          (let* ((top (+ (ebox--item-top-in-root node) (ebox-geo-mt geo) (ebox-geo-pt geo)))
                 (end (+ top (ebox-geo-vh geo)))
                 (from (max start top))
                 (to (if (= old new) (min (+ start new) end) end)))
            (if (< from to)
                (setq start from old (- to from) new (- to from) whole nil)
              (setq start nil)))))
      (setq node (ebox--clip-parent node)))
    (and start (list start old new whole))))

(defun ebox--damage-range (damage)
  "Return (START OLD NEW WHOLE) root lines for DAMAGE (ITEM FROM OLD NEW), or nil.
WHOLE is non-nil when the range covers a whole node's margin box.  Ranges
inside scrolling or clipped containers keep only their shown lines; nil
means the damage is not shown."
  (pcase-let ((`(,item ,from ,old ,new) damage))
    (cond
     ((and (consp item) (eq (car item) 'lines))
      (let* ((node (nth 1 item))
             (geo (ebox-node-layout node))
             (border (eq (nth 3 item) 'border))
             (start (if border
                        (nth 2 item)
                      (+ (nth 2 item) (ebox-geo-mt geo) (ebox-geo-pt geo)
                         (- (ebox-geo-scroll geo))))))
        (ebox--clip-range (list (+ (ebox--item-top-in-root node) start from) old new nil)
                          (if border (ebox--clip-parent node) node))))
     ((ebox-para-p item)
      (ebox--clip-range (list (+ (ebox--item-top-in-root item) from) old new nil)
                        (ebox-para-owner item)))
     (t
      (ebox--clip-range (list (+ (ebox--item-top-in-root item) from) old new (= from 0))
                        (ebox--clip-parent item))))))

(defun ebox--damage-live-p (damage root)
  "Return non-nil when DAMAGE's owner is laid out under ROOT."
  (let ((node (ebox--damage-owner (car damage))))
    (and (ebox-node-layout node) (eq (ebox-node-root node) root))))

(defun ebox--root-edits (root damages)
  "Convert DAMAGES under ROOT to sorted, merged (START OLD NEW) edits.
START is in post-layout lines; applying edits in order transforms the old
lines into the new ones.  Return the symbol `full' when ranges overlap in a
way that cannot be expressed as ordered line replacements."
  (let ((ranges (delq nil (mapcar #'ebox--damage-range
                                  (cl-remove-if-not (lambda (d) (ebox--damage-live-p d root))
                                                    damages))))
        (height (ebox-node-h root))
        merged)
    ;; Overlays may extend past the root; only its lines exist.
    (setq ranges (delq nil (mapcar (lambda (r)
                                     (cond ((/= (nth 1 r) (nth 2 r)) r)
                                           ((>= (car r) height) nil)
                                           ((> (+ (car r) (nth 2 r)) height)
                                            (let ((n (- height (car r))))
                                              (list (car r) n n (nth 3 r))))
                                           (t r)))
                                   ranges)))
    (setq ranges (sort ranges (lambda (a b)
                                (or (< (car a) (car b))
                                    (and (= (car a) (car b)) (> (nth 2 a) (nth 2 b)))))))
    (catch 'full
      (dolist (range ranges)
        (let* ((prev (car merged))
               (prev-end (and prev (+ (car prev) (nth 2 prev))))
               (end (+ (car range) (nth 2 range))))
          (cond
           ((or (null prev) (>= (car range) prev-end))
            (push (copy-sequence range) merged))
           ((and (<= end prev-end)
                 (or (= (nth 1 range) (nth 2 range)) (nth 3 prev)))
            ;; Nested in lines the previous edit already rewrites.
            nil)
           ((or (= (nth 1 prev) (nth 2 prev)) (= (nth 1 range) (nth 2 range)))
            (let ((delta (+ (- (nth 2 prev) (nth 1 prev)) (- (nth 2 range) (nth 1 range))))
                  (span (- (max prev-end end) (car prev))))
              (setf (nth 1 prev) (- span delta)
                    (nth 2 prev) span
                    (nth 3 prev) nil)))
           (t (throw 'full 'full)))))
      (mapcar (lambda (edit) (list (car edit) (nth 1 edit) (nth 2 edit)))
              (nreverse merged)))))

(provide 'ebox-layout)

;;; ebox-layout.el ends here
