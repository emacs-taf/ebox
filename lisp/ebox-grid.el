;;; ebox-grid.el --- Grid formatting context for Ebox -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Grid is a two-dimensional layout node.  It deliberately reuses Ebox's
;; shared CSS size expressions, box renderer, and retained tree identity rather
;; than introducing a second styling or measurement model.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ebox-layout-config)
(require 'ebox-layout)
(require 'ebox-flex)

(declare-function ebox--viewport-dependent-subtree-p "ebox-incremental" (node))
(declare-function ebox--viewport-height-dependent-subtree-p "ebox-incremental" (node))
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox-box-node-p "ebox-canonical" (node))
(declare-function ebox-get "ebox" (box property))
(declare-function ebox-node-factory--create-from-properties
                  "ebox-node-factory" (&rest plist))
(declare-function ebox-render "ebox-layout" (node))
(declare-function ebox--lines-concat-horizontal "ebox" (&rest strings))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-string-height "ebox" (string))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox--side-pixel "ebox-layout" (box &optional side))
(declare-function ebox--content-min-pixel "ebox-layout" (box))
(declare-function ebox--content-max-pixel "ebox-layout" (box))
(declare-function ebox--line-min-content-pixel "ebox-layout" (line))
(declare-function ebox--lines-align-vertical "ebox-layout" (string height align))
(declare-function ebox--flex-spacing "ebox-flex" (mode leftover count base-gap))
(declare-function ebox--render-with-cache "ebox-incremental" (node &optional force cache-probe))
(declare-function ebox--record-rendered-intrinsic-size
                  "ebox-layout" (body width height))
(declare-function ebox--rendered-intrinsic-size
                  "ebox-layout" (rendered axis))
(defvar ebox--region-box-table)

(defconst ebox--grid-layout-prop-keys
  '(:grid-template-columns :grid-template-rows
    :grid-auto-columns :grid-auto-rows :grid-auto-flow
    :column-gap :row-gap :gap
    :justify-items :align-items :justify-content :align-content)
  "Properties owned by the grid formatting context.")

(defconst ebox--grid-config-prop-keys
  '(:grid-template-columns :grid-template-rows
    :grid-auto-columns :grid-auto-rows :grid-auto-flow
    :row-gap :column-gap
    :justify-items :align-items :justify-content :align-content)
  "Canonical property order stored in a typed GridConfig.")

(defconst ebox--grid-justify-items-values
  '(stretch start end center)
  "Supported canonical GridConfig inline item alignment values.")

(defconst ebox--grid-align-items-values
  '(normal start end stretch flex-start flex-end center baseline)
  "Supported canonical GridConfig block item alignment values.")

(defconst ebox--grid-content-alignment-values
  '(normal start end stretch flex-start flex-end center
    space-between space-around space-evenly)
  "Supported canonical GridConfig content alignment values.")

(defconst ebox--grid-item-prop-keys
  '(:grid-column :grid-row :justify-self)
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
       (or (memq (car value) '(fr minmax repeat))
           (ebox-size-value-p value nil t))))

(defun ebox-grid--track-list (value)
  "Return VALUE as a list of track expressions."
  (cond
   ((null value) nil)
   ((ebox-grid--track-form-p value) (list value))
   ((symbolp value) (list value))
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
           (let ((body
                  (cond
                   ((or (ebox-grid--track-form-p value)
                        (symbolp value))
                    (list value))
                   ((proper-list-p value) value)
                   (t (error "ebox-grid: invalid repeat body %S" value)))))
             (cl-loop repeat count
                      append (ebox-grid--expand-repeat body))))
       (list track)))
   tracks))

(defun ebox-grid--normalize-track (value axis &optional property)
  "Normalize track VALUE for AXIS, reporting errors against PROPERTY."
  (setq property (or property (if (eq axis 'columns)
                                  :grid-template-columns :grid-template-rows)))
  (cond
   ((eq value 'auto) '(:kind auto :factor 0))
   ((memq value '(min-content max-content))
    (list :kind value))
   ((and (consp value) (eq (car value) 'fr))
    (unless (and (proper-list-p value) (= (length value) 2)
                 (numberp (cadr value)) (> (cadr value) 0))
      (error "ebox-grid: invalid fractional track %S" value))
    (list :kind 'fr :factor (cadr value)))
   ((and (consp value) (eq (car value) 'minmax))
    (unless (and (consp (cdr value))
                 (consp (cddr value))
                 (null (cdddr value)))
      (error "ebox-grid: invalid minmax track %S" value))
    (let ((minimum (ebox-grid--normalize-track (cadr value) axis property))
          (maximum (ebox-grid--normalize-track (caddr value) axis property)))
      (unless (memq (plist-get minimum :kind)
                    '(fixed auto min-content max-content))
        (error "ebox-grid: minmax minimum must be fixed or auto: %S" value))
      (unless (memq (plist-get maximum :kind)
                    '(fixed auto min-content max-content fr))
        (error "ebox-grid: minmax maximum cannot be nested: %S" value))
      (list :kind 'minmax :min minimum :max maximum)))
   ((ebox-size-value-p value nil t)
    (list :kind 'fixed :size
          (ebox-size-validate-for-axis
           value property (if (eq axis 'columns) 'inline 'block))))
   (t (error "ebox-grid: unsupported %S track: %S" axis value))))

(defun ebox-grid--normalize-tracks (value axis &optional property)
  "Normalize track template VALUE along AXIS for optional PROPERTY."
  (mapcar (lambda (track) (ebox-grid--normalize-track track axis property))
          (ebox-grid--expand-repeat (ebox-grid--track-list value))))

(defun ebox-grid--gap-pair (props)
  "Return normalized (ROW-GAP . COLUMN-GAP) from grid PROPS."
  (let* ((pair (ebox--flex-gap-pair (plist-get props :gap)))
         (row (cond
               ((plist-member props :row-gap) (plist-get props :row-gap))
               (t (car pair))))
         (column (cond
                  ((plist-member props :column-gap)
                   (plist-get props :column-gap))
                  (t (cdr pair)))))
    (cons (ebox--flex-row-gap-value row)
          (ebox--flex-column-gap-value column))))

(defun ebox-grid--enum-value (value default allowed property)
  "Return VALUE or DEFAULT after checking ALLOWED values for PROPERTY."
  (let ((resolved (or value default)))
    (unless (memq resolved allowed)
      (error "Ebox GridConfig %S has invalid value: %S" property resolved))
    resolved))

(defun ebox-grid--one-auto-track (value axis property)
  "Return VALUE normalized as zero or one auto track for AXIS and PROPERTY."
  (let ((tracks (ebox-grid--normalize-tracks value axis property)))
    (when (> (length tracks) 1)
      (error "Ebox GridConfig %S accepts at most one track" property))
    (car tracks)))

(defun ebox-grid--normalize-config-props (props)
  "Normalize GridConfig PROPS once to canonical layout-owned facts."
  (dolist (property '(:grid-template-columns :grid-template-rows))
    (when-let* ((value (plist-get props property)))
      (unless (and (proper-list-p value)
                   value
                   (not (ebox-grid--track-form-p value)))
        (error "Ebox GridConfig %S requires a nonempty track list: %S"
               property value))))
  (let ((gaps (ebox-grid--gap-pair props)))
    (list
   :grid-template-columns
   (ebox-grid--normalize-tracks
    (plist-get props :grid-template-columns) 'columns)
   :grid-template-rows
   (ebox-grid--normalize-tracks
    (plist-get props :grid-template-rows) 'rows)
   :grid-auto-columns
   (ebox-grid--one-auto-track
    (plist-get props :grid-auto-columns) 'columns :grid-auto-columns)
   :grid-auto-rows
   (ebox-grid--one-auto-track
    (plist-get props :grid-auto-rows) 'rows :grid-auto-rows)
   :grid-auto-flow
   (ebox-grid--enum-value
    (plist-get props :grid-auto-flow) 'row '(row column) :grid-auto-flow)
   :row-gap (car gaps)
   :column-gap (cdr gaps)
   :justify-items
   (ebox-grid--enum-value
    (plist-get props :justify-items) 'stretch
    ebox--grid-justify-items-values :justify-items)
   :align-items
   (ebox-grid--enum-value
    (plist-get props :align-items) 'stretch
    ebox--grid-align-items-values :align-items)
   :justify-content
   (ebox-grid--enum-value
    (plist-get props :justify-content) 'flex-start
    ebox--grid-content-alignment-values :justify-content)
   :align-content
     (ebox-grid--enum-value
      (plist-get props :align-content) 'stretch
      ebox--grid-content-alignment-values :align-content))))

(defconst ebox--grid-default-config-props
  (ebox-grid--normalize-config-props nil)
  "Computed default property set for GridConfig.")

(defun ebox-grid--canonical-atomic-track-p (track allowed-kinds &optional axis)
  "Return non-nil when TRACK has an ALLOWED-KINDS kind and valid AXIS units."
  (and (proper-list-p track)
       (memq (plist-get track :kind) allowed-kinds)
       (pcase (plist-get track :kind)
         ('auto (equal track '(:kind auto :factor 0)))
         ('min-content (equal track '(:kind min-content)))
         ('max-content (equal track '(:kind max-content)))
         ('fixed
          (let ((size (plist-get track :size)))
            (and (ebox-size-value-for-axis-p
                  size (pcase axis ('columns 'inline) ('rows 'block) (_ 'length)))
                 (equal track (list :kind 'fixed :size size)))))
         ('fr
          (let ((factor (plist-get track :factor)))
            (and (numberp factor) (> factor 0)
                 (equal track (list :kind 'fr :factor factor)))))
         (_ nil))))

(defun ebox-grid--canonical-track-p (track &optional axis)
  "Return non-nil when TRACK is canonical, including optional AXIS units."
  (or (ebox-grid--canonical-atomic-track-p
       track '(fixed auto min-content max-content fr) axis)
      (and (proper-list-p track)
           (eq (plist-get track :kind) 'minmax)
           (ebox-grid--canonical-atomic-track-p
            (plist-get track :min) '(fixed auto min-content max-content) axis)
           (ebox-grid--canonical-atomic-track-p
            (plist-get track :max)
            '(fixed auto min-content max-content fr) axis)
           (equal track
                  (list :kind 'minmax
                        :min (plist-get track :min)
                        :max (plist-get track :max))))))

(defun ebox-grid-layout-config-props-p (props)
  "Return non-nil when PROPS are canonical validated GridConfig data."
  (and (proper-list-p props)
       (zerop (% (length props) 2))
       (let ((cursor props) (keys ebox--grid-config-prop-keys) valid)
         (setq valid t)
         (while (and valid keys)
           (setq valid (eq (car cursor) (car keys))
                 cursor (cddr cursor)
                 keys (cdr keys)))
         (and valid (null cursor)))
       (cl-every (lambda (track) (ebox-grid--canonical-track-p track 'columns))
                 (plist-get props :grid-template-columns))
       (cl-every (lambda (track) (ebox-grid--canonical-track-p track 'rows))
                 (plist-get props :grid-template-rows))
       (let ((auto-column (plist-get props :grid-auto-columns))
             (auto-row (plist-get props :grid-auto-rows)))
         (and (or (null auto-column)
                  (ebox-grid--canonical-track-p auto-column 'columns))
              (or (null auto-row)
                  (ebox-grid--canonical-track-p auto-row 'rows))))
       (memq (plist-get props :grid-auto-flow) '(row column))
       (let ((row-gap (plist-get props :row-gap))
             (column-gap (plist-get props :column-gap)))
         (and (ebox-size-value-for-axis-p row-gap 'block)
              (ebox-size-value-for-axis-p column-gap 'inline)))
       (memq (plist-get props :justify-items)
             ebox--grid-justify-items-values)
       (memq (plist-get props :align-items)
             ebox--grid-align-items-values)
       (memq (plist-get props :justify-content)
             ebox--grid-content-alignment-values)
       (memq (plist-get props :align-content)
             ebox--grid-content-alignment-values)))

(defun ebox-grid--validate-config-input (plist)
  "Return canonical GridConfig input PLIST after surface validation."
  (unless (and (proper-list-p plist) (zerop (% (length plist) 2)))
    (error "Ebox GridConfig properties must be an even plist: %S" plist))
  (let ((seen (make-hash-table :test 'eq)))
    (cl-loop for (key _value) on plist by #'cddr
             unless (memq key ebox--grid-config-prop-keys)
             do (error "Ebox GridConfig does not accept %S" key)
             do (when (gethash key seen)
                  (error "Duplicate Ebox GridConfig property: %S" key))
             do (puthash key t seen)))
  plist)

;;;###autoload
(defun ebox-grid-layout-create (&rest plist)
  "Return a typed GridConfig from canonical evaluated PLIST.
Author `:gap' sugar is expanded before this programmatic port.  Removed
grid-gap aliases are rejected at the author schema boundary."
  (ebox-grid--validate-config-input plist)
  (let ((props (ebox-grid--normalize-config-props plist)))
    (unless (ebox-grid-layout-config-props-p props)
      (error "Ebox GridConfig normalization produced invalid data: %S" props))
    (ebox-layout-config--create :kind 'grid :props props)))

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
    (apply #'ebox-node-factory--create-from-properties
           (append (ebox--preformatted-box-props props)
                   (list :content "")))))

(defun ebox-grid--placement-part (value default)
  "Return (START SPAN) parsed from placement VALUE and DEFAULT."
  (cond
   ((null value) (list default 1))
   ((numberp value)
    (if (> value 0)
        (list value 1)
      (error "ebox-grid: placement starts at one: %S" value)))
   ((and (proper-list-p value)
         (eq (car value) :span)
         (integerp (cadr value))
         (null (cddr value)))
    (list default (cadr value)))
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
         (row-span (cadr row))
         (column-span (cadr column)))
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
                     (ebox-grid--occupancy (- rows (length result))
                                           target-columns))))
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
          (if (> (length matrix) 0) (length (aref matrix 0)) columns))))

(defun ebox-grid--string-min-content-pixel (string)
  "Return STRING's widest unbreakable run in pixels."
  (let ((best 0))
    (dolist (line (ebox-string-lines string) best)
      (setq best (max best (ebox--line-min-content-pixel line))))))

(defun ebox-grid--entry-intrinsic-size (entry rendered axis mode)
  "Return ENTRY's intrinsic size from RENDERED for AXIS and MODE."
  (let* ((node (plist-get entry :node))
         (string (gethash node rendered)))
    (if (eq mode 'auto-min)
        (let* ((horizontal (eq axis 'columns))
               (span (plist-get entry (if horizontal :column-span :row-span))))
          (if (ebox-box-node-p node)
              (if (and (> (or span 1) 1)
                       (not (ebox--flex-explicit-min-main-p
                             node (if horizontal 'row 'column))))
                  0
                (/ (ebox--flex-box-min-main
                    node (or string "") (if horizontal 'row 'column))
                   (float (or span 1))))
            (if horizontal
                (or (ebox--rendered-intrinsic-size string :width)
                    (ebox-grid--string-min-content-pixel (or string "")))
              (or (ebox--rendered-intrinsic-size string :height)
                  (ebox-string-height (or string ""))))))
      (if (eq axis 'rows)
          (or (ebox--rendered-intrinsic-size string :height)
              (ebox-string-height string))
        (pcase mode
          ('min-content
           (if (ebox-box-node-p node)
               (+ (ebox--side-pixel node) (ebox--content-min-pixel node))
             (or (ebox--rendered-intrinsic-size string :width)
                 (ebox-grid--string-min-content-pixel string))))
          ('max-content
           (if (ebox-box-node-p node)
               (+ (ebox--side-pixel node) (ebox--content-max-pixel node))
             (or (ebox--rendered-intrinsic-size string :width)
                 (ebox--string-max-pixel-width string))))
          (_ (if (and (ebox-box-node-p node)
                      (zerop (ebox-string-height string)))
                 (ebox--flex-source-width node string)
               (or (ebox--rendered-intrinsic-size string :width)
                   (ebox--string-pixel-width string)))))))))

(defun ebox-grid--track-intrinsic (track axis entries rendered key slot-index)
  "Return intrinsic size for TRACK from RENDERED grid ENTRIES."
  (pcase (plist-get track :kind)
    ('fixed (plist-get track :size))
    ('minmax
     (ebox-grid--track-intrinsic (plist-get track :min)
                                  axis entries rendered key slot-index))
    (_ (let ((position (1+ slot-index))
             (mode (if (eq (plist-get track :kind) 'fr)
                       'auto-min (plist-get track :kind)))
             (best 0))
         (dolist (entry entries best)
           (when (and (<= (plist-get entry key) position)
                      (< position
                         (+ (plist-get entry key)
                            (plist-get entry
                                      (if (eq key :column)
                                          :column-span
                                        :row-span)))))
             (let ((value
                    (ebox-grid--entry-intrinsic-size
                     entry rendered axis mode)))
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

(defun ebox-grid--track-flex-factor (track)
  "Return TRACK's flexible maximum factor, or zero when it is fixed.

`minmax' tracks commonly use a zero minimum with a fractional maximum for
responsive layouts.  Treat that maximum as a real flexible track instead of
letting the grid fall back to each child's intrinsic width."
  (pcase (plist-get track :kind)
    ('fr (plist-get track :factor))
    ('minmax (ebox-grid--track-flex-factor (plist-get track :max)))
    (_ 0)))

(defun ebox-grid--clamp-track-size (track size)
  "Clamp SIZE to TRACK's fixed maximum when one exists."
  (if-let* ((maximum (ebox-grid--track-max track)))
      (min size maximum)
    size))

(defun ebox-grid--used-track (track axis available &optional box)
  "Resolve TRACK for AXIS and AVAILABLE using BOX's font metrics.
An indefinite percentage track participates as auto.  Canonical source
descriptors remain unresolved, so subsequent layouts can use a new context."
  (pcase (plist-get track :kind)
    ('fixed
     (let* ((horizontal (eq axis 'columns))
            (line-height (ebox--size-line-height box))
            (ebox-viewport-width (if horizontal available ebox-viewport-width))
            (ebox--css-containing-height
             (if horizontal ebox--css-containing-height
               (and available (* available line-height))))
            (value (plist-get track :size))
            (pixels (if (numberp value) value
                      (ebox--size-pixels value box
                                         (if horizontal 'width 'height)))))
       (if pixels
           (list :kind 'fixed :size
                 (max 0 (if (or horizontal (numberp value)) pixels
                          (/ pixels (float line-height)))))
         '(:kind auto :factor 0))))
    ('minmax
     (let ((minimum (ebox-grid--used-track
                     (plist-get track :min) axis available box))
           (maximum (ebox-grid--used-track
                     (plist-get track :max) axis available box)))
       ;; CSS ignores a maximum below the minimum once both are definite.
       (when (and (eq (plist-get minimum :kind) 'fixed)
                  (eq (plist-get maximum :kind) 'fixed)
                  (< (plist-get maximum :size) (plist-get minimum :size)))
         (setq maximum minimum))
       (list :kind 'minmax :min minimum :max maximum)))
    (_ track)))

(defun ebox-grid--resolve-sizes
    (tracks count axis entries rendered gap available &optional auto-track box)
  "Resolve TRACKS to COUNT sizes along AXIS within AVAILABLE space.
ENTRIES and RENDERED supply intrinsic content, GAP is the used gap, BOX
supplies font metrics, and AUTO-TRACK describes implicit tracks."
  (let* ((auto-track (ebox-grid--used-track
                     (or auto-track '(:kind auto :factor 0)) axis available box))
         (tracks (mapcar (lambda (track)
                           (ebox-grid--used-track track axis available box))
                         tracks))
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
         (flexible (cl-loop for track in tracks for index from 0
                            when (> (ebox-grid--track-flex-factor track) 0)
                            collect index)))
    (when (and (null available) flexible)
      (let ((fraction
             (cl-loop for index in flexible
                      for factor = (ebox-grid--track-flex-factor (nth index tracks))
                      maximize
                      (/ (float
                          (max (nth index sizes)
                               (ebox-grid--track-intrinsic
                                '(:kind max-content) axis entries rendered
                                (if (eq axis 'columns) :column :row) index)))
                         (max 1 factor)))))
        (dolist (index flexible)
          (setf (nth index sizes)
                (* fraction (ebox-grid--track-flex-factor (nth index tracks)))))))
    (when (and available flexible)
      (let ((remaining
             (- available (* gap (max 0 (1- count)))
                (cl-loop for size in sizes for index from 0
                         unless (memq index flexible) sum size))))
        (while flexible
          (let* ((factor-total
                  (cl-loop for index in flexible
                           sum (ebox-grid--track-flex-factor (nth index tracks))))
                 (fraction (/ (float (max 0 remaining)) (max 1 factor-total)))
                 (frozen
                  (cl-remove-if-not
                   (lambda (index)
                     (> (nth index sizes)
                        (* fraction (ebox-grid--track-flex-factor
                                     (nth index tracks)))))
                   flexible)))
            (if frozen
                (dolist (index frozen)
                  (setq remaining (- remaining (nth index sizes))
                        flexible (delq index flexible)))
              (dolist (index flexible)
                (setf (nth index sizes)
                      (* fraction (ebox-grid--track-flex-factor (nth index tracks)))))
              (setq flexible nil))))))
    (ebox-size-quantize sizes)))

(defun ebox-grid--content-independent-columns-p (tracks count available &optional children)
  "Return non-nil when TRACKS determine COUNT widths without cell content.
Require a definite AVAILABLE width and explicit fixed/fr tracks.  CHILDREN
must have zero automatic minima when fractional tracks are present."
  (and (numberp available) (> available 0)
       (>= (length tracks) count)
       (cl-every (lambda (track)
                   (memq (plist-get track :kind) '(fixed fr)))
                 tracks)
       (or (cl-every (lambda (track) (eq (plist-get track :kind) 'fixed)) tracks)
           (cl-every
            (lambda (child)
              (and (ebox-box-node-p child)
                   (or (and (memq (ebox-get child :min-width) '(nil auto))
                            (memq (ebox-get child :overflow) '(auto scroll hidden)))
                       (equal (ebox-get child :min-width) 0)
                       (equal (ebox-get child :min-width) '(px 0)))))
            children))))

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

(defun ebox-grid--final-content-layout (sizes gap-value axis available alignment box)
  "Lay out SIZES with GAP-VALUE on AXIS in AVAILABLE space for BOX.
ALIGNMENT positions tracks.  Cyclic percentage gaps contribute zero during
intrinsic sizing, then resolve against that intrinsic size for final layout.
The resulting gap may overflow the unchanged intrinsic container extent."
  (let* ((gap (ebox--layout-used-gap gap-value axis available box))
         (cyclic (and (null available)
                      (ebox-size-value-p gap-value nil t)
                      (memq 'percent (ebox-size-dependencies gap-value))))
         (intrinsic (+ (ebox-grid--sum sizes)
                       (* gap (max 0 (1- (length sizes))))))
         (used-gap (if cyclic
                       (ebox--layout-used-gap gap-value axis intrinsic box)
                     gap))
         (layout (ebox-grid--content-layout sizes used-gap available alignment)))
    (when cyclic
      (plist-put layout :target intrinsic)
      (plist-put layout :intrinsic-size intrinsic))
    layout))

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
    ;; `stretch' is a containing-block width.  Treating it
    ;; as intrinsic leaves fractional Grid tracks empty and makes composite
    ;; cards hug their natural width instead of filling the assigned track.
    (or (null width) (memq width '(auto stretch)))))

(defun ebox-grid--entry-source (entry rendered width props)
  "Return ENTRY's content rendered within its containing WIDTH.

Stretching is the default grid item alignment.  Re-render an auto-sized
child at its assigned width for that alignment, while preserving its natural
size for start/center/end alignment unless it would overflow its track."
  (let* ((node (plist-get entry :node))
         (source (gethash node rendered))
         (auto-width-p (ebox-grid--auto-width-node-p node))
         (justify (or (plist-get props :justify-items) 'stretch))
         (stretch-p (memq justify '(normal stretch))))
    (unless (or (and auto-width-p stretch-p) (stringp source))
      (error "ebox-grid: Grid item requires missing intrinsic output"))
    (if (or (and auto-width-p
                 (or stretch-p (> (ebox--string-max-pixel-width source) width)))
            (and (not auto-width-p)
                 (ebox--viewport-dependent-subtree-p node)))
        (let ((ebox-viewport-width width)
              (ebox--render-root-parent-kind 'grid))
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
                 (if (or (null string) (string-empty-p string))
                     (ebox-grid--blank width height)
                   string)
                 width
                 (pcase justify
                   ((or 'end 'right) 'right)
                   ('center 'center)
                   (_ 'left)))))
    (ebox--lines-align-vertical
     result height
     (pcase align
       ((or 'end 'flex-end 'bottom) 'bottom)
       ('center 'center)
       (_ 'top)))))

(defun ebox-grid--entry-string (entry rendered widths heights col-gap row-gap props)
  "Size and align ENTRY's width-sized RENDERED output within its rectangle.
WIDTHS and HEIGHTS hold track sizes separated by COL-GAP and ROW-GAP.
PROPS provides the container's item alignment defaults.
An auto-height Box stretches its own geometry and paint to the assigned rows.
Its normal Box renderer still owns margins, padding, and min/max constraints."
  (let* ((width (ebox-grid--entry-size entry widths col-gap))
         (height (ebox-grid--row-entry-size entry heights row-gap))
         (node (plist-get entry :node))
         (source (gethash node rendered))
         (justify (or (plist-get props :justify-items) 'stretch))
         (self (plist-get node :align-self))
         (align (if (memq self '(nil auto))
                    (or (plist-get props :align-items) 'stretch)
                  self))
         (stretch-p (and (memq align '(normal stretch))
                         (ebox-box-node-p node)
                         (memq (ebox-get node :height) '(nil auto)))))
    (when (or (and stretch-p (/= height (ebox-string-height source)))
              (ebox--viewport-height-dependent-subtree-p node))
      (let* ((ebox-viewport-width width)
             (ebox--css-containing-height
              (* height (ebox--size-line-height)))
             (ebox--render-root-parent-kind 'grid)
             ;; Height assignment must not stretch the other axis when its
             ;; already sized output fits the track under start/center/end.
             (ebox--inline-auto-width-intrinsic-p
              (and (not (memq justify '(normal stretch)))
                   (< (ebox--string-max-pixel-width source) width)))
             (sized (if stretch-p (copy-sequence node) node)))
        (when stretch-p
          (plist-put sized :region-id (ebox--ensure-region-id node))
          (plist-put sized :height 'stretch))
        (setq source (ebox--render-with-cache sized))
        (when stretch-p
          (puthash (ebox-get node :region-id) node ebox--region-box-table))))
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
  "Return non-nil when ENTRY's slice starts at zero-based ROW and COLUMN."
  (let ((start (1- (plist-get entry :row))))
    (and (<= start row)
         (< row (+ start (plist-get entry :row-span)))
         (= column (1- (plist-get entry :column))))))

(defun ebox-grid--blank (width height)
  "Return a blank grid area of WIDTH pixels and HEIGHT lines."
  (or (ebox--pixel-blank width height)
      (ebox-lines-join (make-list (max 0 height) ""))))

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
      (let* ((row-height (nth row heights))
             (gap-after (if (< row (1- (length heights))) row-gap 0))
             (height (+ row-height gap-after))
             (parts nil)
             (column 0))
        (when (and (> height 0) (null widths))
          (push (ebox-grid--blank total-width height) parts))
        (while (and (> height 0) (< column (length widths)))
          (let ((entry (ebox-grid--entry-at matrix row column)))
            (if (and entry (ebox-grid--entry-start-p entry row column))
                (let* ((string (gethash entry strings))
                       (start (1- (plist-get entry :row)))
                       (offset (+ (ebox-grid--sum
                                   (seq-subseq heights start row))
                                  (* row-gap (- row start))))
                       (continues-p
                        (> (+ start (plist-get entry :row-span)) (1+ row)))
                       (slice-height (if continues-p height row-height))
                       (piece (and (> slice-height 0)
                                   (ebox-grid--slice
                                    string offset slice-height))))
                  ;; A spanning cell owns the intervening gap lines too.
                  ;; Other cells leave that same area blank after clipping
                  ;; their output to the allocated row height.
                  (when (and (> gap-after 0) (not continues-p))
                    (let ((gap (ebox-grid--blank
                                (ebox-grid--entry-size entry widths col-gap)
                                gap-after)))
                      (setq piece (if piece
                                      (ebox-lines-join (list piece gap))
                                    gap))))
                  (push piece parts)
                  (setq column (+ column (plist-get entry :column-span))))
              (let ((width (nth column widths)))
                (push (ebox-grid--blank width height) parts)
                (setq column (1+ column))))
            (when (and (< column (length widths)) (> col-gap 0))
              (push (ebox-pixel-space col-gap) parts))))
        (when parts
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
                                             (plist-get column-layout :trailing))))))))))
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
  (if-let* ((box (plist-get node :box)))
      (let ((copy (copy-sequence box))
            (region-id (ebox--ensure-region-id box)))
        (plist-put copy :region-id region-id)
        (plist-put copy :content rendered)
        (plist-put copy :ebox-content-node nil)
        (plist-put copy :ebox-content-width-exact-p t)
        (prog1 (ebox--render-node copy)
          (puthash region-id box ebox--region-box-table)))
    rendered))

(defun ebox-grid--legacy-constraints (props wrapper)
  "Return private GridConstraints from legacy PROPS and WRAPPER."
  (let ((width (ebox--nonnegative-horizontal-size-pixels
                (plist-get props :width)
                (ebox--viewport-pixel-width nil)))
        (height (ebox--flex-line-value (plist-get props :height) nil)))
    (when wrapper
      (setq width (ebox--box-sizing-content-pixel wrapper width)))
    (list :width width :height height)))

(defun ebox-grid--box-constraints (box)
  "Project BOX content dimensions to private GridConstraints."
  (list :width (ebox--wrapper-content-viewport-pixel box)
        :height (ebox--resolve-size-content-height
                 box (ebox-get box :height) nil)))

(defun ebox--render-grid-children (config constraints children &optional box)
  "Render Grid CONFIG under CONSTRAINTS over CHILDREN using BOX font metrics."
  (let* ((props (ebox--layout-used-gaps
                config (plist-get constraints :width)
                (plist-get constraints :height) box))
         (columns (plist-get props :grid-template-columns))
         (rows (plist-get props :grid-template-rows))
         (auto-columns (plist-get props :grid-auto-columns))
         (auto-rows (plist-get props :grid-auto-rows))
         (gaps (cons (plist-get props :row-gap)
                     (plist-get props :column-gap)))
         (flow (or (plist-get props :grid-auto-flow) 'row))
         (placed (ebox-grid--place-children children
                                             (if children (max 1 (length columns))
                                               (length columns))
                                             (if children (max 1 (length rows))
                                               (length rows)) flow))
         (entries (nth 0 placed))
         (matrix (nth 1 placed))
         (row-count (nth 2 placed))
         (column-count (nth 3 placed))
         (available (when-let* ((width (plist-get constraints :width)))
                      (floor width)))
         (height (when-let* ((height (plist-get constraints :height)))
                   (floor height)))
         (ebox--css-containing-height
          (and height (* height (ebox--size-line-height box))))
         (content-independent-p
          (and (ebox-grid--content-independent-columns-p
                columns column-count available children)
               (memq (or (plist-get props :justify-items) 'stretch)
                     '(normal stretch))))
         (rendered (make-hash-table :test 'eq)))
    (unless (memq flow '(row column))
      (error "ebox-grid: :grid-auto-flow must be `row' or `column'"))
    (dolist (entry entries)
      (let ((child (plist-get entry :node)))
        ;; Neither column sizing nor unconditional stretch consumes this
        ;; natural output.  The final Box render still resolves its own
        ;; min/max constraints before its output is used to size rows.
        (unless (and content-independent-p
                     (ebox-box-node-p child)
                     (ebox-grid--auto-width-node-p child))
          (let ((ebox-viewport-width nil)
                (ebox--intrinsic-layout-measurement t))
            (puthash child (ebox--render-with-cache child) rendered)))))
    (let* ((widths (ebox-grid--resolve-sizes columns column-count 'columns
                                             entries rendered (cdr gaps)
                                             available auto-columns box))
           (column-layout
            (ebox-grid--final-content-layout
             widths (plist-get config :column-gap) 'width available
             (or (plist-get props :justify-content) 'start) box))
           (sized-rendered
            (ebox-grid--sized-rendered-entries
             entries rendered (plist-get column-layout :sizes)
             (plist-get column-layout :between) props))
           (heights (ebox-grid--resolve-sizes rows row-count 'rows
                                              entries sized-rendered (car gaps)
                                              height auto-rows box))
           (row-layout
            (ebox-grid--final-content-layout
             heights (plist-get config :row-gap) 'height height
             (or (plist-get props :align-content) 'start) box))
           (body (ebox-grid--render entries matrix column-layout row-layout
                                    props sized-rendered)))
      (ebox--record-rendered-intrinsic-size
       body (or (plist-get column-layout :intrinsic-size)
                (and (string-empty-p body)
                     (plist-get column-layout :target)))
       (plist-get row-layout :intrinsic-size)))))

(defun ebox--render-grid-box-children (box config children)
  "Render canonical BOX Grid CONFIG over flat CHILDREN."
  (ebox--render-grid-children
   config (ebox-grid--box-constraints box) children box))

(defun ebox--render-grid (node)
  "Render legacy GRID NODE to a propertized string."
  (let* ((props (plist-get node :raw-props))
         (wrapper (plist-get node :box)))
    (ebox--render-grid-box
     node
     (ebox--render-grid-children
      (or (plist-get node :ebox-grid-config)
          (error "Ebox Grid node lacks canonical config"))
      (ebox-grid--legacy-constraints props wrapper)
      (ebox-tree-layout-children node)))))

(provide 'ebox-grid)

;;; ebox-grid.el ends here
