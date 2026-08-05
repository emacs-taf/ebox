;;; ebox-style.el --- CSS-like style model for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns style property registration, shorthand expansion, computed style, and
;; dirty-effect classification.  It does not own Emacs buffer text properties.

;;; Code:

(require 'cl-lib)

(cl-defstruct (ebox-style-property
               (:constructor ebox-style-property-create))
  name aliases initial inherited group parser compute dirty-kind signature
  backend-mapper)

(defconst ebox-style--border-styles
  '(none hidden dotted dashed solid double groove ridge inset outset)
  "Valid CSS border-style keywords accepted by Ebox style parsing.")

(defun ebox-style--property-definitions ()
  "Return registered CSS-like property definitions."
  (list
   (ebox-style-property-create
    :name :color :group 'paint :dirty-kind 'paint :signature 'paint)
   (ebox-style-property-create
    :name :background-color :aliases '(:bgcolor)
    :group 'paint :dirty-kind 'paint :signature 'paint)
   (ebox-style-property-create
    :name :border-color :group 'paint :dirty-kind 'paint :signature 'paint)
   (ebox-style-property-create
    :name :border-width :group 'geometry :dirty-kind 'geometry
    :signature 'layout)
   (ebox-style-property-create
    :name :padding-block-start :aliases '(:padding-top)
    :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :padding-inline-end :aliases '(:padding-right)
    :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :padding-block-end :aliases '(:padding-bottom)
    :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :padding-inline-start :aliases '(:padding-left)
    :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :margin-block-start :aliases '(:margin-top)
    :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :margin-inline-end :aliases '(:margin-right)
    :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :margin-block-end :aliases '(:margin-bottom)
    :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :margin-inline-start :aliases '(:margin-left)
    :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :width :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :height :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :min-width :group 'geometry :dirty-kind 'geometry
    :signature 'layout)
   (ebox-style-property-create
    :name :max-width :group 'geometry :dirty-kind 'geometry
    :signature 'layout)
   (ebox-style-property-create
    :name :display :group 'structure :dirty-kind 'structure
    :signature 'structure)
   (ebox-style-property-create
    :name :gap :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :row-gap :group 'geometry :dirty-kind 'geometry :signature 'layout)
   (ebox-style-property-create
    :name :column-gap :group 'geometry :dirty-kind 'geometry
    :signature 'layout)
   (ebox-style-property-create
    :name :flex-direction :group 'geometry :dirty-kind 'geometry
    :signature 'layout)
   (ebox-style-property-create
    :name :flex-wrap :group 'geometry :dirty-kind 'geometry
    :signature 'layout)
   (ebox-style-property-create
    :name :justify-content :group 'geometry :dirty-kind 'geometry
    :signature 'layout)
   (ebox-style-property-create
    :name :align-items :group 'geometry :dirty-kind 'geometry
    :signature 'layout)
   (ebox-style-property-create
    :name :align-content :group 'geometry :dirty-kind 'geometry
    :signature 'layout)))

(defvar ebox-style--property-table nil
  "Hash table from canonical property names and aliases to metadata.")

(defun ebox-style--ensure-property-table ()
  "Return the canonical style property registry table."
  (or ebox-style--property-table
      (let ((table (make-hash-table :test 'eq)))
        (dolist (property (ebox-style--property-definitions))
          (puthash (ebox-style-property-name property) property table)
          (dolist (alias (ebox-style-property-aliases property))
            (puthash alias property table)))
        (setq ebox-style--property-table table))))

(defun ebox-style-property (name)
  "Return registered style metadata for canonical property or alias NAME."
  (gethash name (ebox-style--ensure-property-table)))

(defun ebox-style-canonical-name (name)
  "Return canonical CSS-like longhand property name for NAME."
  (when-let ((property (ebox-style-property name)))
    (ebox-style-property-name property)))

(defun ebox-style--put (plist key value)
  "Return PLIST with KEY set to VALUE."
  (plist-put plist key value))

(defun ebox-style--split-trbl (value)
  "Split VALUE using CSS TRBL rules into top, right, bottom, left."
  (cond
   ((null value) (list nil nil nil nil))
   ((atom value) (list value value value value))
   ((and (listp value) (keywordp (car value)))
    (list (plist-get value :top) (plist-get value :right)
          (plist-get value :bottom) (plist-get value :left)))
   ((listp value)
    (pcase (length value)
      (1 (list (nth 0 value) (nth 0 value) (nth 0 value) (nth 0 value)))
      (2 (list (nth 0 value) (nth 1 value) (nth 0 value) (nth 1 value)))
      (3 (list (nth 0 value) (nth 1 value) (nth 2 value) (nth 1 value)))
      (_ (list (nth 0 value) (nth 1 value) (nth 2 value) (nth 3 value)))))
   (t (list value value value value))))

(defun ebox-style--split-pair (value)
  "Split VALUE into a start/end pair."
  (cond
   ((null value) (list nil nil))
   ((atom value) (list value value))
   ((and (listp value) (= 1 (length value)))
    (list (nth 0 value) (nth 0 value)))
   ((listp value) (list (nth 0 value) (nth 1 value)))
   (t (list value value))))

(defun ebox-style--wsc-classify (item)
  "Classify border shorthand ITEM as width, style, or color."
  (cond
   ((numberp item) (cons 'width item))
   ((and (listp item) (numberp (car item)) (null (cdr item)))
    (cons 'width item))
   ((memq item ebox-style--border-styles) (cons 'style item))
   (t (cons 'color item))))

(defun ebox-style--split-wsc (value)
  "Split VALUE into border width, style, and color."
  (cond
   ((null value) (list nil nil nil))
   ((eq value t)
    (list '(1) 'solid (frame-parameter nil 'foreground-color)))
   ((atom value)
    (let ((classified (ebox-style--wsc-classify value)))
      (pcase (car classified)
        ('width (list (cdr classified) nil nil))
        ('style (list nil (cdr classified) nil))
        ('color (list '(1) 'solid (cdr classified))))))
   ((keywordp (car value))
    (list (plist-get value :width)
          (plist-get value :style)
          (plist-get value :color)))
   ((listp value)
    (let (width style color)
      (dolist (item value)
        (let ((classified (ebox-style--wsc-classify item)))
          (pcase (car classified)
            ('width (setq width (cdr classified)))
            ('style (setq style (cdr classified)))
            ('color (setq color (cdr classified))))))
      (list (or width '(1)) (or style 'solid) color)))
   (t (list '(1) 'solid value))))

(defun ebox-style--atom-consp (list)
  "Return non-nil when LIST is a strict dotted pair of atoms."
  (and (consp list)
       (atom (car list))
       (cdr list)
       (atom (cdr list))))

(defun ebox-style--parse-color (color)
  "Resolve COLOR, returning nil for an unspecified Emacs color."
  (let ((resolved
         (cond
          ((eq t color) (face-attribute 'default :foreground nil t))
          ((null color) nil)
          ((stringp color) color)
          ((ebox-style--atom-consp color)
           (pcase (frame-parameter nil 'background-mode)
             ('light (car color))
             ('dark (cdr color))
             (_ (car color))))
          (t color))))
    (unless (member resolved '(nil unspecified unspecified-fg unspecified-bg
                                  "unspecified" "unspecified-fg"
                                  "unspecified-bg"))
      resolved)))

(defun ebox-style--expand-canonical-property (property value)
  "Return canonical CSS-like longhand entries for PROPERTY and VALUE."
  (pcase property
    (:bgcolor (list :background-color (ebox-style--parse-color value)))
    (:background-color
     (list :background-color (ebox-style--parse-color value)))
    (:color (list :color (ebox-style--parse-color value)))
    (:padding
     (pcase-let ((`(,top ,right ,bottom ,left)
                  (ebox-style--split-trbl value)))
       (list :padding-block-start top
             :padding-inline-end right
             :padding-block-end bottom
             :padding-inline-start left)))
    (:padding-inline
     (pcase-let ((`(,start ,end) (ebox-style--split-pair value)))
       (list :padding-inline-start start :padding-inline-end end)))
    (:padding-block
     (pcase-let ((`(,start ,end) (ebox-style--split-pair value)))
       (list :padding-block-start start :padding-block-end end)))
    (:padding-top (list :padding-block-start value))
    (:padding-right (list :padding-inline-end value))
    (:padding-bottom (list :padding-block-end value))
    (:padding-left (list :padding-inline-start value))
    (:margin
     (pcase-let ((`(,top ,right ,bottom ,left)
                  (ebox-style--split-trbl value)))
       (list :margin-block-start top
             :margin-inline-end right
             :margin-block-end bottom
             :margin-inline-start left)))
    (:margin-inline
     (pcase-let ((`(,start ,end) (ebox-style--split-pair value)))
       (list :margin-inline-start start :margin-inline-end end)))
    (:margin-block
     (pcase-let ((`(,start ,end) (ebox-style--split-pair value)))
       (list :margin-block-start start :margin-block-end end)))
    (:margin-top (list :margin-block-start value))
    (:margin-right (list :margin-inline-end value))
    (:margin-bottom (list :margin-block-end value))
    (:margin-left (list :margin-inline-start value))
    (:border
     (pcase-let ((`(,width ,style ,color) (ebox-style--split-wsc value)))
       (append (when width (list :border-width width))
               (when style (list :border-style style))
               (when color
                 (list :border-color (ebox-style--parse-color color))))))
    (:border-color
     (list :border-color (ebox-style--parse-color value)))
    (_
     (if-let ((canonical (ebox-style-canonical-name property)))
         (list canonical value)
       nil))))

(defun ebox-style-expand-shorthands (plist)
  "Expand PLIST to CSS-like canonical longhand properties."
  (let (expanded)
    (while plist
      (let ((property (pop plist))
            (value (pop plist)))
        (setq expanded
              (nconc expanded
                     (ebox-style--expand-canonical-property
                      property value)))))
    expanded))

(defun ebox-style-compute (plist)
  "Return computed canonical style for PLIST."
  (let ((expanded (ebox-style-expand-shorthands plist))
        computed)
    (while expanded
      (let ((property (pop expanded))
            (value (pop expanded)))
        (when (ebox-style-property property)
          (setq computed
                (ebox-style--put computed property value)))))
    computed))

(defun ebox-style-dirty-kind (name)
  "Return dirty kind for canonical property or alias NAME."
  (when-let ((property (ebox-style-property name)))
    (ebox-style-property-dirty-kind property)))

(defun ebox-style-signature (computed-style groups)
  "Return deterministic signature for COMPUTED-STYLE filtered by GROUPS."
  (let (entries)
    (while computed-style
      (let* ((property-name (pop computed-style))
             (value (pop computed-style))
             (property (ebox-style-property property-name))
             (group (and property (ebox-style-property-signature property))))
        (when (and property
                   (or (null groups)
                       (memq group groups)
                       (memq (ebox-style-property-group property) groups)))
          (push (cons property-name value) entries))))
    (setq entries
          (sort entries
                (lambda (a b)
                  (string< (symbol-name (car a))
                           (symbol-name (car b))))))
    (apply #'append
           (mapcar (lambda (entry)
                     (list (car entry) (cdr entry)))
                   entries))))

(defconst ebox-style-ebox-property-rules
  '((:padding :expand (:padding-top :padding-right
                                    :padding-bottom :padding-left)
              :mode trbl)
    (:padding-inline :expand (:padding-left :padding-right) :mode pair)
    (:padding-block :expand (:padding-top :padding-bottom) :mode pair)
    (:padding-top :to :padding-top-height :conv line)
    (:padding-right :to :padding-right-pixel :conv pixel)
    (:padding-bottom :to :padding-bottom-height :conv line)
    (:padding-left :to :padding-left-pixel :conv pixel)
    (:margin :expand (:margin-top :margin-right
                                  :margin-bottom :margin-left)
             :mode trbl)
    (:margin-inline :expand (:margin-left :margin-right) :mode pair)
    (:margin-block :expand (:margin-top :margin-bottom) :mode pair)
    (:margin-top :to :margin-top-height :conv line)
    (:margin-right :to :margin-right-pixel :conv pixel)
    (:margin-bottom :to :margin-bottom-height :conv line)
    (:margin-left :to :margin-left-pixel :conv pixel)
    (:border :expand (:border-top :border-right
                                  :border-bottom :border-left)
             :mode same)
    (:border-top :expand (:border-top-width
                          :border-top-style
                          :border-top-color)
                 :mode wsc)
    (:border-right :expand (:border-right-width
                            :border-right-style
                            :border-right-color)
                   :mode wsc)
    (:border-bottom :expand (:border-bottom-width
                             :border-bottom-style
                             :border-bottom-color)
                    :mode wsc)
    (:border-left :expand (:border-left-width
                           :border-left-style
                           :border-left-color)
                  :mode wsc)
    (:border-width :expand (:border-top-width :border-right-width
                                              :border-bottom-width
                                              :border-left-width)
                   :mode trbl)
    (:border-style :expand (:border-top-style :border-right-style
                                              :border-bottom-style
                                              :border-left-style)
                   :mode trbl)
    (:border-color :expand (:border-top-color :border-right-color
                                              :border-bottom-color
                                              :border-left-color)
                   :mode trbl)
    (:border-top-width :to :border-top-p :conv bool)
    (:border-top-style :to nil)
    (:border-top-color :to :border-top-color :conv color)
    (:border-bottom-width :to :border-bottom-p :conv bool)
    (:border-bottom-style :to nil)
    (:border-bottom-color :to :border-bottom-color :conv color)
    (:border-left-width :to :border-left-pixel :conv pixel)
    (:border-left-style :to nil)
    (:border-left-color :to :border-left-color :conv color)
    (:border-right-width :to :border-right-pixel :conv pixel)
    (:border-right-style :to nil)
    (:border-right-color :to :border-right-color :conv color)
    (:width :to :width :conv preferred-size)
    (:min-width :to :min-width :conv min-size)
    (:max-width :to :max-width :conv max-size)
    (:height :to :height)
    (:min-height :to :min-height)
    (:max-height :to :max-height)
    (:content :to :content)
    (:box-sizing :to :box-sizing)
    (:color :to :color :conv color)
    (:background-color :to :bgcolor :conv color)
    (:bgcolor :to :bgcolor :conv color)
    (:text-align :to :text-align)
    (:vertical-align :to :vertical-align :conv vertical-align)
    (:overflow :to :overflow)
    (:wrap-mode :to :wrap-mode)
    (:display :to nil)
    (:visibility :to :visibility))
  "Compatibility rules that expand public Ebox properties to engine keys.")

(defun ebox-style--negative-numeric-size-p (value)
  "Return non-nil when VALUE is or starts with a negative number."
  (or (and (numberp value) (< value 0))
      (and (consp value)
           (numberp (car value))
           (< (car value) 0))))

(defun ebox-style--convert (value converter)
  "Convert VALUE using Ebox engine CONVERTER."
  (pcase converter
    ('pixel (or (ebox--nonnegative-horizontal-size-pixels value nil) 0))
    ('size-pixel (or (ebox--nonnegative-horizontal-size-pixels value nil) 0))
    ('preferred-size
     (ebox--normalize-horizontal-size-value
      value ebox--preferred-size-keywords))
    ('min-size
     (ebox--normalize-horizontal-size-value
      value ebox--min-size-keywords))
    ('max-size
     (ebox--normalize-horizontal-size-value
      value ebox--max-size-keywords))
    ('line
     (if (numberp value)
         (progn
           (when (< value 0)
             (error "ebox: line values cannot be negative: %S" value))
           value)
       0))
    ('bool
     (when (ebox-style--negative-numeric-size-p value)
       (error "ebox: border width values cannot be negative: %S" value))
     (and value (not (eq value 0))))
    ('vertical-align (if (eq value 'middle) 'center value))
    ('color (ebox-style--parse-color value))
    (_ value)))

(defconst ebox-style--nonnegative-edge-longhands
  '(:padding-left-pixel :padding-right-pixel
    :padding-top-height :padding-bottom-height
    :margin-left-pixel :margin-right-pixel
    :margin-top-height :margin-bottom-height
    :border-left-pixel :border-right-pixel
    :border-top-p :border-bottom-p)
  "Engine edge longhands that cannot represent negative geometry.")

(defun ebox-style--validate-edge-longhands (plist)
  "Return PLIST after rejecting negative normalized engine edges."
  (let ((tail plist))
    (while tail
      (let ((property (pop tail))
            (value (pop tail)))
        (when (and (memq property ebox-style--nonnegative-edge-longhands)
                   (ebox-style--negative-numeric-size-p value))
          (error "ebox: %S cannot be negative: %S" property value))))
    plist))

(defun ebox-style--split-value (value mode n)
  "Split VALUE according to MODE for N targets."
  (pcase mode
    ('trbl (ebox-style--split-trbl value))
    ('pair (ebox-style--split-pair value))
    ('wsc (ebox-style--split-wsc value))
    ('same (make-list n value))
    (_ (make-list n value))))

(defun ebox-style--get-ebox-rule (property)
  "Return Ebox compatibility expansion rule for PROPERTY."
  (cdr (assq property ebox-style-ebox-property-rules)))

(defun ebox-style-expand-ebox-property (property value)
  "Expand public Ebox PROPERTY with VALUE to engine longhands."
  (let ((rule (ebox-style--get-ebox-rule property)))
    (cond
     ((null rule) (list property value))
     ((plist-get rule :expand)
      (let* ((targets (plist-get rule :expand))
             (mode (plist-get rule :mode))
             (parts (ebox-style--split-value value mode (length targets))))
        (cl-mapcan #'ebox-style-expand-ebox-property targets parts)))
     ((plist-member rule :to)
      (let ((target (plist-get rule :to))
            (converter (plist-get rule :conv)))
        (if target
            (list target (ebox-style--convert value converter))
          nil)))
     (t (list property value)))))

(defun ebox-style-expand-ebox-plist (plist)
  "Expand PLIST using Ebox compatibility property rules."
  (let (expanded)
    (while plist
      (let ((property (pop plist))
            (value (pop plist)))
        (setq expanded
              (nconc expanded
                     (ebox-style-expand-ebox-property property value)))))
    (ebox-style--validate-edge-longhands expanded)))

(provide 'ebox-style)

;;; ebox-style.el ends here
