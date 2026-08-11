;;; ebox-grid.el --- Grid formatting context for Ebox -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Grid is a two-dimensional layout node.  It deliberately reuses Ebox's
;; existing pixel/line units, box renderer, and retained tree identity rather
;; than introducing a second styling or measurement model.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ebox-layout)
(require 'ebox-flex)

(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox-create "ebox" (&rest plist))
(declare-function ebox-render "ebox-layout" (node))
(declare-function ebox--lines-concat-horizontal "ebox" (&rest strings))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-string-height "ebox" (string))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox--lines-align-vertical "ebox-layout" (string height align))
(declare-function ebox--flex-spacing "ebox-flex" (mode leftover count base-gap))
(declare-function ebox--render-with-cache "ebox-incremental" (node &optional force cache-probe))
(defvar ebox--region-box-table)

(defconst ebox--grid-layout-prop-keys
  '(:grid-template-columns :grid-template-rows
    :grid-auto-columns :grid-auto-rows :grid-auto-flow
    :grid-column-gap :grid-row-gap :gap
    :justify-items :align-items :justify-content :align-content)
  "Properties owned by the grid formatting context.")

(defconst ebox--grid-item-prop-keys
  '(:grid-column :grid-row :grid-column-span :grid-row-span)
  "Properties that describe a child's position in a grid.")

(defun ebox-grid--split-attrs (items)
  "Split grid ITEMS into a property plist and child list."
  (let (props children)
    (while items
      (let ((item (pop items)))
        (if (keywordp item)
            (progn
              (unless items
                (error "ebox-grid: missing value for %S" item))
              (push item props)
              (push (pop items) props))
          (push item children))))
    (cons (nreverse props) (nreverse children))))

(defun ebox-grid--track-form-p (value)
  "Return non-nil when VALUE is one composite track expression."
  (and (consp value)
       (memq (car value) '(fr minmax repeat))))

(defun ebox-grid--track-list (value)
  "Return VALUE as a list of track expressions."
  (cond
   ((null value) nil)
   ((ebox-grid--track-form-p value) (list value))
   ((or (numberp value) (symbolp value)) (list value))
   (t value)))

(defun ebox-grid--expand-repeat (tracks)
  "Expand REPEAT expressions in TRACKS."
  (cl-mapcan
   (lambda (track)
     (if (and (consp track) (eq (car track) 'repeat))
         (let ((count (cadr track))
               (value (caddr track)))
           (unless (and (null (cdddr track))
                        (integerp count) (> count 0) value)
             (error "ebox-grid: invalid repeat track %S" track))
           (make-list count value))
       (list track)))
   tracks))

(defun ebox-grid--normalize-track (value axis)
  "Normalize one track VALUE for AXIS (`columns' or `rows')."
  (setq value (if (and (consp value) (eq (car value) 'quote))
                  (cadr value)
                value))
  (cond
   ((eq value 'auto) '(:kind auto :factor 0))
   ((and (symbolp value)
         (string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)fr\\'"
                       (symbol-name value)))
    (list :kind 'fr :factor
          (string-to-number (match-string 1 (symbol-name value)))))
   ((and (consp value) (eq (car value) 'fr))
    (unless (and (numberp (cadr value)) (> (cadr value) 0))
      (error "ebox-grid: invalid fractional track %S" value))
    (list :kind 'fr :factor (cadr value)))
   ((and (consp value) (eq (car value) 'minmax))
    (unless (and (consp (cdr value))
                 (consp (cddr value))
                 (null (cdddr value)))
      (error "ebox-grid: invalid minmax track %S" value))
    (let ((minimum (ebox-grid--normalize-track (cadr value) axis))
          (maximum (ebox-grid--normalize-track (caddr value) axis)))
      (when (and (eq (plist-get maximum :kind) 'fixed)
                 (eq (plist-get minimum :kind) 'fixed)
                 (> (plist-get minimum :size) (plist-get maximum :size)))
        (error "ebox-grid: minmax minimum exceeds maximum: %S" value))
      (list :kind 'minmax :min minimum :max maximum)))
   ((eq axis 'columns)
    (list :kind 'fixed
          :size (ebox--nonnegative-horizontal-size-pixels value 0)))
   (t
    (let ((lines (ebox--flex-line-value value 0)))
      (list :kind 'fixed :size lines)))))

(defun ebox-grid--normalize-tracks (value axis)
  "Normalize a track template VALUE along AXIS."
  (mapcar (lambda (track) (ebox-grid--normalize-track track axis))
          (ebox-grid--expand-repeat (ebox-grid--track-list value))))

(defun ebox-grid--gap-pair (props)
  "Return normalized (ROW-GAP . COLUMN-GAP) from grid PROPS."
  (let* ((pair (ebox--flex-gap-pair (plist-get props :gap)))
         (row (if (plist-member props :grid-row-gap)
                  (plist-get props :grid-row-gap)
                (car pair)))
         (column (if (plist-member props :grid-column-gap)
                     (plist-get props :grid-column-gap)
                   (cdr pair))))
    (cons (or (ebox--flex-line-value row 0) 0)
          (or (ebox--nonnegative-horizontal-size-pixels column 0) 0))))

(defun ebox-grid--visual-props-p (props)
  "Return non-nil when PROPS contains visible box behavior."
  (cl-loop for (key _value) on props by #'cddr
           thereis (not (memq key (append ebox--grid-layout-prop-keys
                                           '(:width :height :box-sizing)
                                           ebox--grid-item-prop-keys)))))

(defun ebox-grid--wrapper (props)
  "Create a visual wrapper for grid PROPS, or return nil."
  (when (ebox-grid--visual-props-p props)
    (when (plist-member props :content)
      (error "ebox-grid: grid cannot combine :content with child nodes"))
    (apply #'ebox-create
           (append (ebox--preformatted-box-props props)
                   (list :content "")))))

;;;###autoload
(defun ebox-grid-fr (factor)
  "Return a fractional grid track with FACTOR weight."
  (unless (and (numberp factor) (> factor 0))
    (error "ebox-grid-fr: FACTOR must be positive: %S" factor))
  (list 'fr factor))

;;;###autoload
(defun ebox-grid-item (node &rest props)
  "Return NODE with grid placement PROPS attached.
Supported properties are `:grid-column', `:grid-row',
`:grid-column-span', and `:grid-row-span'."
  (unless (and (listp node) (plist-member node :ebox-type))
    (error "ebox-grid-item: NODE is not an Ebox node: %S" node))
  (let ((copy (copy-sequence node))
        (declarations (ebox-style-compile-declarations props t)))
    (while props
      (let* ((key (pop props))
             (value (progn
                      (unless props
                        (error "ebox-grid-item: missing value for %S" key))
                      (pop props))))
        (unless (memq key ebox--grid-item-prop-keys)
          (error "ebox-grid-item: unsupported property %S" key))
        (plist-put copy key value)))
    (plist-put copy :ebox-style-declarations
               (append (plist-get copy :ebox-style-declarations)
                       declarations))
    copy))

(defun ebox-grid--placement-part (value default)
  "Return (START SPAN) parsed from placement VALUE and DEFAULT."
  (cond
   ((null value) (list default 1))
   ((numberp value)
    (if (> value 0)
        (list value 1)
      (error "ebox-grid: placement starts at one: %S" value)))
   ((and (consp value) (numberp (car value)))
    (let ((start (car value))
          (tail (cdr value)))
      (unless (> start 0)
        (error "ebox-grid: placement starts at one: %S" value))
      (cond
       ((null tail) (list start 1))
       ((and (eq (car tail) :span) (numberp (cadr tail)))
        (list start (cadr tail)))
       ((numberp (car tail))
        (list start (- (car tail) start)))
       (t (error "ebox-grid: invalid placement %S" value)))))
   (t (error "ebox-grid: invalid placement %S" value))))

(defun ebox-grid--placement (child)
  "Return CHILD placement as (ROW COL ROW-SPAN COL-SPAN)."
  (let* ((row (ebox-grid--placement-part (plist-get child :grid-row) 0))
         (column (ebox-grid--placement-part
                  (plist-get child :grid-column) 0))
         (row-span (or (plist-get child :grid-row-span) (cadr row)))
         (column-span (or (plist-get child :grid-column-span) (cadr column))))
    (dolist (part (list row column))
      (when (or (not (integerp (car part))) (< (car part) 0)
                (not (integerp (cadr part))) (< (cadr part) 1))
        (error "ebox-grid: invalid placement %S" part)))
    (unless (and (integerp row-span) (> row-span 0)
                 (integerp column-span) (> column-span 0))
      (error "ebox-grid: grid spans must be positive integers"))
    (list (car row) (car column) row-span column-span)))

(defun ebox-grid--occupancy (rows columns)
  "Return an empty ROWS by COLUMNS occupancy matrix."
  (let ((matrix (make-vector rows nil)))
    (cl-loop for row from 0 below rows
             do (aset matrix row (make-vector columns nil))
             finally return matrix)))

(defun ebox-grid--grow (matrix rows columns)
  "Grow MATRIX to at least ROWS and COLUMNS and return it."
  (let* ((result matrix)
         (existing-columns
          (if (> (length result) 0)
              (length (aref result 0))
            0))
         (target-columns (max columns existing-columns)))
    (when (> columns 0)
      (dotimes (row (length result))
        (when (< (length (aref result row)) target-columns)
          (setf (aref result row)
                (vconcat (aref result row)
                         (make-vector
                          (- target-columns (length (aref result row)))
                          nil))))))
    (when (> rows (length result))
      (setq result
            (vconcat result
                     (make-vector (- rows (length result))
                                  (make-vector target-columns nil)))))
    result))

(defun ebox-grid--free-p (matrix row column row-span column-span)
  "Return non-nil when a placement rectangle is free in MATRIX."
  (and (> row 0) (> column 0)
       (cl-loop for r from (1- row) below (+ (1- row) row-span)
                always (cl-loop for c from (1- column)
                                below (+ (1- column) column-span)
                                always (not (aref (aref matrix r) c))))))

(defun ebox-grid--mark (matrix entry row column row-span column-span)
  "Mark ENTRY in placement rectangle MATRIX."
  (cl-loop for r from (1- row) below (+ (1- row) row-span) do
           (cl-loop for c from (1- column)
                    below (+ (1- column) column-span) do
                    (setf (aref (aref matrix r) c) entry))))

(defun ebox-grid--find-position (matrix placement flow)
  "Find a free position for PLACEMENT in MATRIX using FLOW."
  (let ((row (nth 0 placement))
        (column (nth 1 placement))
        (row-span (nth 2 placement))
        (column-span (nth 3 placement)))
    (cl-labels
        ((free-at-p (r c)
           (and (<= (+ r row-span -1) (length matrix))
                (<= (+ c column-span -1)
                    (length (aref matrix 0)))
                (ebox-grid--free-p matrix r c row-span column-span)))
         (scan-row (r start)
           (cl-loop for c from start to (length (aref matrix 0))
                    when (free-at-p r c) return (list r c)))
         (scan-column (c start)
           (cl-loop for r from start to (length matrix)
                    when (free-at-p r c) return (list r c)))
         (scan-flow ()
           (or (if (eq flow 'column)
                   (cl-loop for c from 1 to (length (aref matrix 0))
                            thereis (scan-column c 1))
                 (cl-loop for r from 1 to (length matrix)
                          thereis (scan-row r 1)))
               (if (eq flow 'column)
                   (list 1 (1+ (length (aref matrix 0))))
                 (list (1+ (length matrix)) 1)))))
      (cond
       ((and (> row 0) (> column 0)) (list row column))
       ((> row 0)
        (or (scan-row row (if (> column 0) column 1))
            (list (1+ (length matrix)) 1)))
       ((> column 0)
        (or (scan-column column 1)
            (list (1+ (length matrix)) 1)))
       (t (scan-flow))))))

(defun ebox-grid--place-children (children columns rows flow)
  "Place CHILDREN and return (ENTRIES MATRIX ROWS COLUMNS)."
  (let ((matrix (ebox-grid--occupancy rows columns))
        entries)
    (dolist (child children)
      (let* ((placement (ebox-grid--placement child))
             (row-span (nth 2 placement))
             (column-span (nth 3 placement))
             (row (nth 0 placement))
             (column (nth 1 placement))
             (explicit-p (and (> row 0) (> column 0)))
             (candidate-row (if (> row 0) row 1))
             (candidate-column (if (> column 0) column 1)))
        (setq matrix (ebox-grid--grow matrix
                                      (+ candidate-row row-span -1)
                                      (+ candidate-column column-span -1)))
        (if (ebox-grid--free-p matrix candidate-row candidate-column
                               row-span column-span)
            (setq row candidate-row column candidate-column)
          (when explicit-p
            (error "ebox-grid: overlapping explicit placement at row %S column %S"
                   row column))
          (let ((position (ebox-grid--find-position
                           matrix (list row column row-span column-span) flow)))
            (setq row (car position) column (cadr position))
            (setq matrix (ebox-grid--grow matrix (+ row row-span -1)
                                          (+ column column-span -1)))))
        (let ((entry (list :node child :row row :column column
                           :row-span row-span :column-span column-span)))
          (ebox-grid--mark matrix entry row column row-span column-span)
          (push entry entries))))
    (list (nreverse entries) matrix (length matrix)
          (length (aref matrix 0)))))

(defun ebox-grid--track-intrinsic (track axis entries rendered key slot-index)
  "Return intrinsic size for TRACK from RENDERED grid ENTRIES."
  (pcase (plist-get track :kind)
    ('fixed (plist-get track :size))
    ('fr 0)
    ('minmax
     (ebox-grid--track-intrinsic (plist-get track :min)
                                  axis entries rendered key slot-index))
    (_ (let ((position (1+ slot-index))
             (best 0))
         (dolist (entry entries best)
           (when (and (<= (plist-get entry key) position)
                      (< position
                         (+ (plist-get entry key)
                            (plist-get entry
                                      (if (eq key :column)
                                          :column-span
                                        :row-span)))))
             (let* ((node (plist-get entry :node))
                    (string (gethash node rendered))
                    (value (if (eq axis 'columns)
                               (ebox--string-pixel-width string)
                             (ebox-string-height string))))
               (setq best (max best value)))))))))

(defun ebox-grid--sum (values)
  "Return the numeric sum of VALUES."
  (apply #'+ (or values '(0))))

(defun ebox-grid--track-max (track)
  "Return TRACK's fixed maximum, or nil when it is unbounded."
  (pcase (plist-get track :kind)
    ('fixed (plist-get track :size))
    ('minmax (ebox-grid--track-max (plist-get track :max)))
    (_ nil)))

(defun ebox-grid--clamp-track-size (track size)
  "Clamp SIZE to TRACK's fixed maximum when one exists."
  (if-let ((maximum (ebox-grid--track-max track)))
      (min size maximum)
    size))

(defun ebox-grid--resolve-sizes
    (tracks count axis entries rendered gap available &optional auto-track)
  "Resolve TRACKS to COUNT sizes along AXIS using AUTO-TRACK for implicit tracks."
  (let* ((auto-track (or auto-track '(:kind auto :factor 0)))
         (tracks (append tracks nil))
         (tracks (append tracks
                         (make-list (max 0 (- count (length tracks)))
                                    auto-track)))
         (count (length tracks))
         (sizes (cl-loop for track in tracks
                         for index from 0
                         collect (ebox-grid--clamp-track-size
                                  track
                                  (ebox-grid--track-intrinsic
                                   track axis entries rendered
                                   (if (eq axis 'columns) :column :row)
                                   index))))
         (fr-total (apply #'+
                          (mapcar (lambda (track)
                                    (if (eq (plist-get track :kind) 'fr)
                                        (plist-get track :factor) 0))
                                  tracks)))
         (used (+ (ebox-grid--sum sizes) (* gap (max 0 (1- count))))))
    (when (and available (> fr-total 0))
      (let ((remaining (max 0 (- available used))))
        (cl-loop for track in tracks
                 for index from 0
                 when (eq (plist-get track :kind) 'fr)
                 do (setf (nth index sizes)
                          (floor (* remaining
                                    (/ (float (plist-get track :factor))
                                       fr-total)))))))
    sizes))

(defun ebox-grid--distribute (amount count)
  "Return COUNT integer shares that sum to AMOUNT."
  (let ((base (if (> count 0) (/ amount count) 0))
        (remainder (if (> count 0) (% amount count) 0)))
    (cl-loop for index from 0 below count
             collect (+ base (if (< index remainder) 1 0)))))

(defun ebox-grid--content-layout (sizes gap available alignment)
  "Return track SIZES and content spacing for AVAILABLE space."
  (let* ((natural (+ (ebox-grid--sum sizes)
                     (* gap (max 0 (1- (length sizes))))))
         (target (max natural (or available natural)))
         (leftover (- target natural)))
    (if (and (> leftover 0) (memq alignment '(stretch normal)))
        (let ((extra (ebox-grid--distribute leftover (length sizes))))
          (list :sizes (cl-mapcar #'+ sizes extra)
                :leading 0 :between gap :trailing 0
                :target target))
      (let ((spacing (ebox--flex-spacing
                      (or alignment 'start) leftover (length sizes) gap)))
        (list :sizes sizes
              :leading (nth 0 spacing)
              :between (nth 1 spacing)
              :trailing (nth 2 spacing)
              :target target)))))

(defun ebox-grid--entry-size (entry sizes gap)
  "Return the target pixel/line size for ENTRY across SIZES."
  (let* ((start (1- (plist-get entry :column)))
         (end (min (length sizes)
                   (+ start (plist-get entry :column-span))))
         (base (ebox-grid--sum (seq-subseq sizes start end)))
         (extra (* gap (max 0 (1- (plist-get entry :column-span))))))
    (+ base extra)))

(defun ebox-grid--auto-width-node-p (node)
  "Return non-nil when NODE derives its width from the active viewport."
  (let ((width (plist-get node :width)))
    (or (null width) (eq width 'auto))))

(defun ebox-grid--entry-source (entry rendered width props)
  "Return ENTRY's content rendered within WIDTH when it is auto-sized.

Stretching is the default grid item alignment.  Re-render an auto-sized
child at its assigned width for that alignment, while preserving its natural
size for start/center/end alignment unless it would overflow its track."
  (let* ((node (plist-get entry :node))
         (source (gethash node rendered))
         (auto-width-p (ebox-grid--auto-width-node-p node))
         (justify (or (plist-get props :justify-items) 'stretch))
         (stretch-p (memq justify '(normal stretch)))
         (overflow-p (> (ebox--string-max-pixel-width source) width)))
    (if (and auto-width-p (or stretch-p overflow-p))
        (let ((ebox-viewport-width width))
          (ebox--render-with-cache node))
      source)))

(defun ebox-grid--row-entry-size (entry sizes gap)
  "Return the target line size for ENTRY across row SIZES."
  (let* ((start (1- (plist-get entry :row)))
         (end (min (length sizes)
                   (+ start (plist-get entry :row-span))))
         (base (ebox-grid--sum (seq-subseq sizes start end)))
         (extra (* gap (max 0 (1- (plist-get entry :row-span))))))
    (+ base extra)))

(defun ebox-grid--align (string width height justify align)
  "Align STRING to WIDTH and HEIGHT using JUSTIFY and ALIGN."
  (let ((result (ebox--lines-justify
                 string width
                 (pcase justify
                   ((or 'end 'right) 'right)
                   ('center 'center)
                   (_ 'left)))))
    (ebox--lines-align-vertical
     result height
     (pcase align
       ((or 'end 'bottom) 'bottom)
       ('center 'center)
       (_ 'top)))))

(defun ebox-grid--entry-string (entry rendered widths heights col-gap row-gap props)
  "Render and align ENTRY within its grid rectangle."
  (let* ((width (ebox-grid--entry-size entry widths col-gap))
         (height (ebox-grid--row-entry-size entry heights row-gap))
         (source (ebox-grid--entry-source entry rendered width props))
         (justify (or (plist-get props :justify-items) 'stretch))
         (align (or (plist-get props :align-items) 'stretch)))
    (ebox-grid--align source width height justify align)))

(defun ebox-grid--sized-rendered-entries (entries rendered widths gap props)
  "Render ENTRIES at their resolved column widths for later row sizing."
  (let ((sized (make-hash-table :test 'eq)))
    (dolist (entry entries)
      (let* ((node (plist-get entry :node))
             (width (ebox-grid--entry-size entry widths gap)))
        (puthash node
                 (ebox-grid--entry-source entry rendered width props)
                 sized)))
    sized))

(defun ebox-grid--entry-at (matrix row column)
  "Return entry occupying ROW and COLUMN in MATRIX."
  (and (< row (length matrix))
       (< column (length (aref matrix row)))
       (aref (aref matrix row) column)))

(defun ebox-grid--entry-start-p (entry row column)
  "Return non-nil when ENTRY starts at zero-based ROW and COLUMN."
  (and (= row (1- (plist-get entry :row)))
       (= column (1- (plist-get entry :column)))))

(defun ebox-grid--blank (width height)
  "Return a blank grid area of WIDTH pixels and HEIGHT lines."
  (or (ebox--pixel-blank width height)
      (ebox-lines-join (make-list (max 1 height) ""))))

(defun ebox-grid--slice (string offset height)
  "Return HEIGHT lines from STRING beginning at OFFSET."
  (ebox-lines-join
   (append (seq-take (nthcdr offset (ebox-string-lines string)) height)
           (make-list (max 0 (- height
                                (length (seq-take
                                         (nthcdr offset (ebox-string-lines string))
                                         height))))
                      ""))))

(defun ebox-grid--render (entries matrix column-layout row-layout props rendered)
  "Render placed grid ENTRIES from MATRIX and resolved track layouts."
  (let* ((widths (plist-get column-layout :sizes))
         (heights (plist-get row-layout :sizes))
         (col-gap (plist-get column-layout :between))
         (row-gap (plist-get row-layout :between))
         (total-width (plist-get column-layout :target))
         (strings (make-hash-table :test 'eq))
         result)
    (dolist (entry entries)
      (puthash entry
               (ebox-grid--entry-string entry rendered widths heights
                                        col-gap row-gap props)
               strings))
    (dotimes (row (length heights))
      (let ((parts nil)
            (column 0))
        (while (< column (length widths))
          (let ((entry (ebox-grid--entry-at matrix row column)))
            (if (and entry (ebox-grid--entry-start-p entry row column))
                (let* ((string (gethash entry strings))
                       (start (1- (plist-get entry :row)))
                       (offset (+ (ebox-grid--sum
                                   (seq-subseq heights start row))
                                  (* row-gap (- row start))))
                       (height (nth row heights)))
                  (push (ebox-grid--slice string offset height) parts)
                  (setq column (+ column (plist-get entry :column-span))))
              (let ((width (nth column widths)))
                (push (ebox-grid--blank width (nth row heights)) parts)
                (setq column (1+ column))))
            (when (< column (length widths))
              (push (ebox-pixel-space col-gap) parts))))
        (setq result
              (append result
                      (list (apply #'ebox--lines-concat-horizontal
                                   (append
                                    (when (> (plist-get column-layout :leading) 0)
                                      (list (ebox-pixel-space
                                             (plist-get column-layout :leading))))
                                    (nreverse parts)
                                    (when (> (plist-get column-layout :trailing) 0)
                                      (list (ebox-pixel-space
                                             (plist-get column-layout :trailing)))))))))
        (when (< row (1- (length heights)))
          (setq result
                (append result
                        (list (ebox-grid--blank total-width row-gap)))))
        ))
    (ebox-lines-join
     (append
      (when (> (plist-get row-layout :leading) 0)
        (list (ebox-grid--blank total-width
                                (plist-get row-layout :leading))))
      result
      (when (> (plist-get row-layout :trailing) 0)
        (list (ebox-grid--blank total-width
                                (plist-get row-layout :trailing))))))))

(defun ebox--render-grid-box (node rendered)
  "Render grid NODE's optional visual wrapper around RENDERED."
  (if-let ((box (plist-get node :box)))
      (let ((copy (copy-sequence box))
            (region-id (ebox--ensure-region-id box)))
        (plist-put copy :region-id region-id)
        (plist-put copy :content rendered)
        (plist-put copy :ebox-content-node nil)
        (plist-put copy :ebox-content-width-exact-p t)
        (prog1 (ebox-render copy)
          (puthash region-id box ebox--region-box-table)))
    rendered))

(defun ebox--render-grid (node)
  "Render GRID NODE to a propertized string."
  (let* ((props (plist-get node :raw-props))
         (children (plist-get node :children))
         (columns (ebox-grid--normalize-tracks
                   (plist-get props :grid-template-columns) 'columns))
         (rows (ebox-grid--normalize-tracks
                (plist-get props :grid-template-rows) 'rows))
         (auto-columns (car (ebox-grid--normalize-tracks
                             (plist-get props :grid-auto-columns) 'columns)))
         (auto-rows (car (ebox-grid--normalize-tracks
                          (plist-get props :grid-auto-rows) 'rows)))
         (gaps (ebox-grid--gap-pair props))
         (flow (or (plist-get props :grid-auto-flow) 'row))
         (placed (ebox-grid--place-children children
                                             (max 1 (length columns))
                                             (max 1 (length rows)) flow))
         (entries (nth 0 placed))
         (matrix (nth 1 placed))
         (row-count (nth 2 placed))
         (column-count (nth 3 placed))
         (available (ebox--nonnegative-horizontal-size-pixels
                     (plist-get props :width)
                     (ebox--viewport-pixel-width nil)))
         (wrapper (plist-get node :box))
         (height (ebox--flex-line-value (plist-get props :height) nil))
         (rendered (make-hash-table :test 'eq)))
    (when wrapper
      (setq available (ebox--box-sizing-content-pixel wrapper available)))
    (unless (memq flow '(row column))
      (error "ebox-grid: :grid-auto-flow must be `row' or `column'"))
    (dolist (entry entries)
      (let ((child (plist-get entry :node)))
        (let ((ebox-viewport-width nil)
              (ebox--intrinsic-layout-measurement t))
          (puthash child (ebox--render-with-cache child) rendered))))
    (let* ((widths (ebox-grid--resolve-sizes columns column-count 'columns
                                             entries rendered (cdr gaps)
                                             available auto-columns))
           (column-layout
            (ebox-grid--content-layout
             widths (cdr gaps) available
             (or (plist-get props :justify-content) 'start)))
           (sized-rendered
            (ebox-grid--sized-rendered-entries
             entries rendered (plist-get column-layout :sizes)
             (plist-get column-layout :between) props))
           (heights (ebox-grid--resolve-sizes rows row-count 'rows
                                              entries sized-rendered (car gaps)
                                              height auto-rows))
           (row-layout
            (ebox-grid--content-layout
             heights (car gaps) height
             (or (plist-get props :align-content) 'start)))
           (body (ebox-grid--render entries matrix column-layout row-layout
                                    props sized-rendered)))
      (ebox--render-grid-box node body))))

;;;###autoload
(defun ebox-grid (&rest items)
  "Return a two-dimensional grid layout node from ITEMS.

Grid properties include `:grid-template-columns', `:grid-template-rows',
`:grid-auto-flow', `:gap', `:grid-row-gap', `:grid-column-gap',
`:justify-items', `:align-items', `:width', and `:height'.  Track sizes use
Ebox pixel/line units, `auto', `(fr FACTOR)', or symbols such as `1fr'.
Children may carry `:grid-column' and `:grid-row' placement properties.
`ebox-grid-fr' is a convenient constructor for fractional tracks."
  (let* ((split (ebox-grid--split-attrs items))
         (raw-props (car split))
         (children (delq nil (cdr split)))
         (box-props (cl-loop for (key value) on raw-props by #'cddr
                             unless (memq key ebox--grid-layout-prop-keys)
                             collect key and collect value))
         (wrapper (ebox-grid--wrapper box-props))
         (node (list :ebox-type 'grid
                     :display '(block grid)
                     :props raw-props
                     :raw-props raw-props
                     :ebox-style-declarations
                     (ebox-style-compile-declarations raw-props)
                     :box wrapper
                     :children children)))
    (when wrapper
      (plist-put wrapper :ebox-style-wrapper t))
    (dolist (key '(:id :class :selector-state :selector-attributes :key))
      (when (plist-member raw-props key)
        (plist-put node key (plist-get raw-props key))))
    node))

(provide 'ebox-grid)

;;; ebox-grid.el ends here
