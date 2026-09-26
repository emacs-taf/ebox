;;; ebox-elastic.el --- Elastic raster resize model -*- lexical-binding: t; -*-

;;; Commentary:
;; Learn how a positioned panel's rendered rows respond to a size change and
;; replay that response without rendering.  A width change of a framed panel
;; whose children keep their size only widens fixed pixel spaces: one per row,
;; or two equal halves around a centered child.  A height change inserts or
;; removes copies of one filler row between a fixed prefix and suffix.  The
;; model is learned from two ordinary renders, checked against the current
;; rows before every use, and verified by the caller at the extreme sizes.

;;; Code:

(require 'cl-lib)
(require 'ebox-measure)

(cl-defstruct (ebox-elastic--row (:constructor ebox-elastic--make-row))
  "Shape of one rendered row and how it follows the panel size.
TEXT is the property-free row.  RUNS are the positions of the elastic
spaces, or nil while the width response is unknown; BASE plus the panel
width is their total pixel width.  CEIL is the run receiving the odd pixel
when two runs share the width and ADJUST each run's constant offset from
the equal split.  DISPLAYS lists the other `display' values by position
and SEGMENTS the pixel widths of the fixed text between runs."
  text runs base ceil adjust displays segments)

(cl-defstruct (ebox-elastic--model (:constructor ebox-elastic--make-model))
  "Learned size response of one panel.
ROWS are the row shapes captured at width WREF and height (length ROWS).
PREFIX and SUFFIX bound the filler rows when a height model is known; the
filler rows are copies of the row at FILLER.  SHIFTS gives for each row
the positions whose row number follows the panel height and
FILLER-SHIFTS the same for filler rows.  WLOW..WHIGH and HLOW..HHIGH are the
verified inclusive size ranges."
  rows wref prefix suffix filler shifts filler-shifts wlow whigh hlow hhigh)

(defconst ebox-elastic--ignored-properties '(ebox--prepared-owners)
  "Transient annotation properties that never distinguish rendered rows.")

(defun ebox-elastic--space-width (display)
  "Return N when DISPLAY is exactly `(space :width (N))', else nil."
  (pcase display
    (`(space :width (,width)) (and (integerp width) (>= width 0) width))))

(defun ebox-elastic--properties (row position)
  "Return ROW's properties at POSITION without ignored annotations."
  (let ((plist (text-properties-at position row)) out)
    (while plist
      (unless (memq (car plist) ebox-elastic--ignored-properties)
        (push (car plist) out) (push (cadr plist) out))
      (setq plist (cddr plist)))
    (nreverse out)))

(defun ebox-elastic--plist-equal-except-display-p (a b)
  "Whether property lists A and B agree on every property except `display'."
  (and (= (length a) (length b))
       (let ((ok t) (rest a))
         (while (and ok rest)
           (let ((property (car rest)) (value (cadr rest)))
             (unless (eq property 'display)
               (let ((cell (plist-member b property)))
                 (setq ok (and cell (equal value (cadr cell)))))))
           (setq rest (cddr rest)))
         ok)))

(defun ebox-elastic--isolated-run-p (row position)
  "Whether ROW's `display' at POSITION is one replacement unit of one char."
  (let ((display (get-text-property position 'display row)))
    (and (= (aref row position) ?\s)
         (not (and (> position 0)
                   (eq display (get-text-property (1- position) 'display row))))
         (not (and (< (1+ position) (length row))
                   (eq display (get-text-property (1+ position) 'display row)))))))

(defun ebox-elastic--scan-displays (row runs)
  "Return ROW's non-run `display' values as a list of (POSITION . VALUE)."
  (let ((position 0) (limit (length row)) out)
    (while (< position limit)
      (let ((display (get-text-property position 'display row)))
        (when (and display (not (memq position runs)))
          (push (cons position display) out)))
      (setq position (or (next-single-property-change position 'display row) limit)))
    (nreverse out)))

(defun ebox-elastic--scan-segments (row runs)
  "Return the pixel widths of ROW's fixed text between RUNS."
  (let ((start 0) out)
    (dolist (run runs)
      (push (ebox--substring-pixel-width row start run) out)
      (setq start (1+ run)))
    (push (ebox--substring-pixel-width row start (length row)) out)
    (vconcat (nreverse out))))

(defun ebox-elastic--learn-row (a b delta)
  "Return the shape of row A whose width grows by DELTA into row B, or nil."
  (when (and (= (length a) (length b)) (string= a b) (/= delta 0))
    (let ((position 0) (limit (length a)) (ok t) runs deltas)
      (while (and ok (< position limit))
        (let ((pa (ebox-elastic--properties a position))
              (pb (ebox-elastic--properties b position)))
          (if (not (ebox-elastic--plist-equal-except-display-p pa pb))
              (setq ok nil)
            (let ((da (plist-get pa 'display)) (db (plist-get pb 'display)))
              (unless (equal da db)
                (let ((na (ebox-elastic--space-width da)) (nb (ebox-elastic--space-width db)))
                  (if (and na nb (ebox-elastic--isolated-run-p a position)
                           (ebox-elastic--isolated-run-p b position)
                           (> (* (- nb na) delta) 0))
                      (progn (push position runs) (push (- nb na) deltas))
                    (setq ok nil)))))))
        (setq position (1+ position)))
      (setq runs (nreverse runs) deltas (nreverse deltas))
      (when (and ok runs (<= (length runs) 2) (= (apply #'+ deltas) delta))
        (let* ((widths (mapcar (lambda (run) (ebox-elastic--space-width
                                              (get-text-property run 'display a)))
                               runs))
               (total (apply #'+ widths))
               ceil adjust)
          (cond
           ((= (length runs) 1) (setq adjust (vector 0)))
           ((> (abs (- (car deltas) (cadr deltas))) 1) (setq ok nil))
           (t
            ;; The run holding the larger half at an odd total owns the odd
            ;; pixel.  Two even totals leave the owner unknown until an odd
            ;; total is rendered.
            (let* ((wb (mapcar (lambda (run) (ebox-elastic--space-width
                                              (get-text-property run 'display b)))
                               runs))
                   (tb (apply #'+ wb)))
              (cond
               ((cl-oddp total)
                (setq ceil (if (> (car widths) (cadr widths)) 0 1)))
               ((cl-oddp tb)
                (setq ceil (if (> (car wb) (cadr wb)) 0 1)))))
            (setq adjust (vector (- (car widths) (if (eq ceil 0) (ceiling total 2) (floor total 2)))
                                 (- (cadr widths) (if (eq ceil 1) (ceiling total 2) (floor total 2)))))
            (unless (cl-every #'zerop adjust) (setq ok nil))))
          (when ok
            (ebox-elastic--make-row
             :text (substring-no-properties a) :runs runs :base total :ceil ceil :adjust adjust
             :displays (ebox-elastic--scan-displays a runs)
             :segments (ebox-elastic--scan-segments a runs))))))))

(defun ebox-elastic--fixed-row (row)
  "Return the shape of ROW while its width response is unknown."
  (ebox-elastic--make-row :text (substring-no-properties row)
                          :displays (ebox-elastic--scan-displays row nil)
                          :segments (ebox-elastic--scan-segments row nil)))

(defun ebox-elastic--row-widths (shape width reference)
  "Return SHAPE's run widths when the panel is WIDTH wide.
REFERENCE is the width at which SHAPE's base total was captured.  Return
nil when SHAPE has no width response or two runs share an odd total whose
owner of the odd pixel is not yet known."
  (let ((total (and (ebox-elastic--row-runs shape)
                    (+ (ebox-elastic--row-base shape) (- width reference)))))
    (cond
     ((null total) nil)
     ((= (length (ebox-elastic--row-runs shape)) 1)
      (list total))
     ((and (cl-oddp total) (null (ebox-elastic--row-ceil shape))) nil)
     (t
      (let ((ceil (ebox-elastic--row-ceil shape)))
        (list (+ (if (eq ceil 0) (ceiling total 2) (floor total 2)) (aref (ebox-elastic--row-adjust shape) 0))
              (+ (if (eq ceil 1) (ceiling total 2) (floor total 2)) (aref (ebox-elastic--row-adjust shape) 1))))))))

(defun ebox-elastic--row-matches-p (shape row width reference)
  "Whether ROW at panel WIDTH still has SHAPE captured at REFERENCE width."
  (and (string= row (ebox-elastic--row-text shape))
       (or (ebox-elastic--row-runs shape) (= width reference))
       (let* ((runs (ebox-elastic--row-runs shape))
              (widths (ebox-elastic--row-widths shape width reference))
              (ok (or (null runs) (and widths t))))
         (cl-loop for run in runs for expected in widths
                  do (unless (and (>= expected 0)
                                  (eql expected (ebox-elastic--space-width (get-text-property run 'display row))))
                       (setq ok nil)))
         (and ok
              (equal (ebox-elastic--scan-displays row runs) (ebox-elastic--row-displays shape))
              (equal (ebox-elastic--scan-segments row runs) (ebox-elastic--row-segments shape))))))

(defun ebox-elastic--learn-width (rows-a width-a rows-b width-b)
  "Learn row shapes from ROWS-A at WIDTH-A and ROWS-B at WIDTH-B.
Return a vector of shapes referenced to WIDTH-A, or nil when any row
changes other than by growing its elastic spaces."
  (when (and (/= width-a width-b) rows-a (= (length rows-a) (length rows-b)))
    (let ((shapes (cl-loop for a in rows-a for b in rows-b
                           collect (ebox-elastic--learn-row a b (- width-b width-a)))))
      (and (cl-every #'identity shapes) (vconcat shapes)))))

(defun ebox-elastic--strip (row)
  "Return ROW without ignored annotation properties."
  (let ((copy (copy-sequence row)))
    (dolist (property ebox-elastic--ignored-properties)
      (remove-text-properties 0 (length copy) (list property nil) copy))
    copy))

(defun ebox-elastic--rows-equal-p (a b)
  "Whether rows A and B are equal apart from ignored annotations."
  (equal-including-properties (ebox-elastic--strip a) (ebox-elastic--strip b)))

(defconst ebox-elastic--shifting-property 'ebox-content-idx
  "Property whose value counts a row's index within its content cell.")

(defun ebox-elastic--rows-shifted (a b delta)
  "Return how row B is row A moved DELTA rows down, or nil.
The rows must agree apart from ignored annotations and every
`ebox-elastic--shifting-property' value of B must be A's or A's plus
DELTA.  The result is (t . POSITIONS) with the positions that moved."
  (let ((property ebox-elastic--shifting-property))
    (and (= (length a) (length b)) (/= delta 0)
         (let ((sa (ebox-elastic--strip a)) (sb (ebox-elastic--strip b))
               (ok t) (position 0) positions)
           (remove-text-properties 0 (length sa) (list property nil) sa)
           (remove-text-properties 0 (length sb) (list property nil) sb)
           (when (equal-including-properties sa sb)
             (while (and ok (< position (length a)))
               (let ((va (get-text-property position property a))
                     (vb (get-text-property position property b)))
                 (cond
                  ((and (integerp va) (eql vb (+ va delta))) (push position positions))
                  ((equal va vb))
                  (t (setq ok nil))))
               (setq position (1+ position)))
             (and ok (cons t (nreverse positions))))))))

(defun ebox-elastic--shift-row (row delta positions)
  "Return a copy of ROW whose POSITIONS are moved DELTA rows down.
Return nil when a position carries no row number to move."
  (let ((copy (copy-sequence row)) (property ebox-elastic--shifting-property))
    (if (zerop delta)
        copy
      (catch 'unshiftable
        (dolist (position positions)
          (let ((value (and (< position (length copy))
                            (get-text-property position property copy))))
            (unless (integerp value) (throw 'unshiftable nil))
            (put-text-property position (1+ position) property (+ value delta) copy)))
        copy))))

(defun ebox-elastic--learn-height (rows-a rows-b)
  "Learn the height response between ROWS-A and ROWS-B rendered at one width.
Return (PREFIX SUFFIX FROM SHIFTS FILLER-SHIFTS) counted on the shorter
list, or nil.  The taller list equals the shorter one with FROM's row
repeated between PREFIX and SUFFIX and every later row moved down.  FROM
is PREFIX - 1 or PREFIX.  SHIFTS is a vector over the shorter list giving
the positions whose row number moves; FILLER-SHIFTS lists them for the
repeated row."
  (let* ((short (if (<= (length rows-a) (length rows-b)) rows-a rows-b))
         (long (if (eq short rows-a) rows-b rows-a))
         (va (vconcat short)) (vb (vconcat long))
         (delta (- (length vb) (length va)))
         (shifts (make-vector (length va) nil))
         (prefix 0) (suffix 0) (ok t))
    (when (> delta 0)
      (while (and (< prefix (length va))
                  (ebox-elastic--rows-equal-p (aref va prefix) (aref vb prefix)))
        (setq prefix (1+ prefix)))
      (while (and ok (< suffix (- (length va) prefix)))
        (let* ((index (- (length va) suffix 1))
               (shifted (ebox-elastic--rows-shifted (aref va index) (aref vb (+ index delta)) delta)))
          (if shifted
              (progn (aset shifts index (cdr shifted)) (setq suffix (1+ suffix)))
            (setq ok nil))))
      (let* ((from (cl-find-if
                    (lambda (from)
                      (and (>= from 0) (< from (length va))
                           (cl-loop for index from prefix below (- (length vb) suffix)
                                    always (or (= index from)
                                               (ebox-elastic--rows-shifted
                                                (aref va from) (aref vb index) (- index from))))))
                    (list (1- prefix) prefix)))
             (filler (and from (ebox-elastic--rows-shifted
                                (aref va from) (aref vb (+ from delta)) delta))))
        (and filler (list prefix suffix from shifts (cdr filler)))))))

(defun ebox-elastic--source-index (model index height new-height)
  "Return the row of a HEIGHT-tall panel that becomes row INDEX at NEW-HEIGHT.
The row is copied from MODEL's height response and moved by the
difference of the two indices."
  (let ((prefix (ebox-elastic--model-prefix model))
        (suffix (ebox-elastic--model-suffix model)))
    (cond
     ((or (null prefix) (= height new-height)) index)
     ((< index prefix) index)
     ((>= index (- new-height suffix)) (- height (- new-height index)))
     (t (ebox-elastic--model-filler model)))))

(defun ebox-elastic--shifts-at (model index height)
  "Return the positions of MODEL's row INDEX at HEIGHT that carry a row number."
  (let* ((rows (ebox-elastic--model-rows model))
         (prefix (ebox-elastic--model-prefix model))
         (suffix (ebox-elastic--model-suffix model)))
    (cond
     ((or (null prefix) (< index prefix)) nil)
     ((>= index (- height suffix))
      (aref (ebox-elastic--model-shifts model) (- (length rows) (- height index))))
     (t (ebox-elastic--model-filler-shifts model)))))

(defun ebox-elastic--reindex (model height)
  "Return MODEL's row shapes and shifts re-indexed for a panel HEIGHT tall.
Return (ROWS . SHIFTS), or nil when MODEL cannot describe HEIGHT."
  (let ((rows (ebox-elastic--model-rows model))
        (prefix (ebox-elastic--model-prefix model))
        (suffix (ebox-elastic--model-suffix model)))
    (cond
     ((= height (length rows)) (cons rows (ebox-elastic--model-shifts model)))
     ((and prefix (>= height (+ prefix suffix)))
      (let ((new-rows (make-vector height nil)) (new-shifts (make-vector height nil)))
        (dotimes (index height)
          (aset new-rows index (ebox-elastic--shape-at model index height))
          (aset new-shifts index (ebox-elastic--shifts-at model index height)))
        (cons new-rows new-shifts))))))

(defun ebox-elastic--shape-at (model index height)
  "Return MODEL's row shape for row INDEX of a panel HEIGHT rows tall."
  (let* ((rows (ebox-elastic--model-rows model))
         (prefix (ebox-elastic--model-prefix model))
         (suffix (ebox-elastic--model-suffix model)))
    (cond
     ((null prefix) (and (= height (length rows)) (aref rows index)))
     ((< index prefix) (aref rows index))
     ((>= index (- height suffix)) (aref rows (- (length rows) (- height index))))
     (t (aref rows (ebox-elastic--model-filler model))))))

(defun ebox-elastic--matches-p (model rows width height)
  "Whether ROWS are MODEL's shape for a panel WIDTH by HEIGHT."
  (let ((prefix (ebox-elastic--model-prefix model))
        (suffix (ebox-elastic--model-suffix model))
        (reference (ebox-elastic--model-wref model)))
    (and (= (length rows) height)
         (if prefix (>= height (+ prefix suffix)) (= height (length (ebox-elastic--model-rows model))))
         (cl-loop for row in rows for index from 0
                  always (let ((shape (ebox-elastic--shape-at model index height)))
                           (and shape (ebox-elastic--row-matches-p shape row width reference)))))))

(defun ebox-elastic--synthesize (model rows height new-width new-height)
  "Return MODEL's rows for NEW-WIDTH by NEW-HEIGHT from ROWS at HEIGHT.
ROWS must already match MODEL.  Return nil when NEW-HEIGHT is outside the
learned height response or a row's width response is still incomplete."
  (let* ((prefix (ebox-elastic--model-prefix model))
         (suffix (ebox-elastic--model-suffix model))
         (reference (ebox-elastic--model-wref model))
         (source (vconcat rows))
         out)
    (when (if prefix (>= new-height (+ prefix suffix)) (= new-height height))
      (dotimes (index new-height)
        (let* ((from (ebox-elastic--source-index model index height new-height))
               (shape (ebox-elastic--shape-at model index new-height))
               (widths (ebox-elastic--row-widths shape new-width reference))
               (copy (ebox-elastic--shift-row (aref source from) (- index from)
                                              (ebox-elastic--shifts-at model index new-height))))
          (unless (and copy (or (null (ebox-elastic--row-runs shape)) widths)) (setq out 'unknown))
          (unless (eq out 'unknown)
            (cl-loop for run in (ebox-elastic--row-runs shape)
                     for value in widths
                     do (put-text-property run (1+ run) 'display (list 'space :width (list value)) copy))
            (push copy out))))
      (and (listp out) (nreverse out)))))

(defvar ebox-elastic--models (make-hash-table :test #'eq :weakness 'key)
  "Learned size responses by panel node.")

(defun ebox-elastic--model (node signature)
  "Return NODE's learned model for display SIGNATURE, or nil."
  (let ((entry (gethash node ebox-elastic--models)))
    (and entry (equal (car entry) signature) (cdr entry))))

(defun ebox-elastic--remember (node signature model)
  "Retain MODEL as NODE's size response for display SIGNATURE."
  (if model
      (puthash node (cons signature model) ebox-elastic--models)
    (remhash node ebox-elastic--models))
  model)

(defun ebox-elastic--in-range-p (model width height)
  "Whether WIDTH by HEIGHT lies inside MODEL's verified size range."
  (and (<= (ebox-elastic--model-wlow model) width (ebox-elastic--model-whigh model))
       (<= (ebox-elastic--model-hlow model) height (ebox-elastic--model-hhigh model))))

(defun ebox-elastic--width-floor (model)
  "Return the smallest width at which every elastic run of MODEL stays visible."
  (let ((floor 0) (reference (ebox-elastic--model-wref model)))
    (cl-loop for shape across (ebox-elastic--model-rows model)
             when (ebox-elastic--row-runs shape)
             do (setq floor (max floor (- reference (ebox-elastic--row-base shape)))))
    floor))

(provide 'ebox-elastic)
;;; ebox-elastic.el ends here
