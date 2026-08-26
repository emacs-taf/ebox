;;; ebox-style.el --- CSS-like style model for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns style property registration, shorthand expansion, computed style, and
;; dirty-effect classification.  It does not own Emacs buffer text properties.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ecss)
(require 'tp-style)

(defvar ebox--longhand)
(declare-function ebox-selector-parse "ebox-selector" (selector))
(declare-function ebox-create "ebox" (&rest plist))
(declare-function ebox--flex-normalize-container-props
                  "ebox-flex" (props))
(declare-function ebox--normalize-horizontal-size-value
                  "ebox-flex" (value allowed-keywords))
(declare-function ebox--nonnegative-horizontal-size-pixels
                  "ebox-layout" (value &optional default))
(declare-function ecss-schema-set-create "ecss" ())
(declare-function ecss-stylesheet-create "ecss" ())

(defvar ebox--preferred-size-keywords)
(defvar ebox--min-size-keywords)
(defvar ebox--max-size-keywords)

(defun ebox-style--create-schema-set ()
  "Return one private ECSS schema set for Ebox style state."
  (ecss-schema-set-create))

(defun ebox-style--create-stylesheet ()
  "Return one private ECSS stylesheet for Ebox style state."
  (ecss-stylesheet-create))

(defconst ebox-style--border-styles
  '(none hidden dotted dashed solid double groove ridge inset outset)
  "Valid CSS border-style keywords accepted by Ebox style parsing.")

(defconst ebox-style--default-foreground 'ebox/default-foreground
  "Internal paint consequence that blocks an inherited foreground.")

(defconst ebox-style--property-definitions
  '((:name :color :id ebox/color :initial nil :inherits t
     :contexts (box) :group paint :dirty-kind paint :signature paint
     :normalizer color)
    (:name :background-color :id ebox/background-color :aliases (:bgcolor)
     :initial nil :contexts (box) :group paint :dirty-kind paint
     :signature paint :normalizer color)
    (:name :font :id ebox/font :initial nil :inherits t :contexts (box)
     :group typography :dirty-kind geometry :signature layout
     :validator font)
    (:name :font-family :id ebox/font-family :initial nil :inherits t
     :contexts (box) :group typography :dirty-kind geometry :signature layout
     :validator font-family)
    (:name :font-height :id ebox/font-height :aliases (:font-size)
     :initial nil :inherits t :contexts (box) :group typography
     :dirty-kind geometry :signature layout :validator font-height)
    (:name :font-weight :id ebox/font-weight :initial nil :inherits t
     :contexts (box) :group typography :dirty-kind geometry :signature layout
     :validator font-attribute)
    (:name :font-slant :id ebox/font-slant :initial nil :inherits t
     :contexts (box) :group typography :dirty-kind geometry :signature layout
     :validator font-attribute)
    (:name :box-sizing :id ebox/box-sizing :initial border-box
     :contexts (box) :group geometry :dirty-kind geometry :signature layout)
    (:name :width :id ebox/width :initial nil :contexts (box flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :validator horizontal-size)
    (:name :min-width :id ebox/min-width :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator horizontal-size)
    (:name :max-width :id ebox/max-width :initial nil :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator horizontal-size)
    (:name :height :id ebox/height :initial nil :contexts (box flex grid)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :min-height :id ebox/min-height :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :max-height :id ebox/max-height :initial nil :contexts (box)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :padding-block-start :id ebox/padding-block-start
     :aliases (:padding-top :padding-top-height) :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :padding-inline-end :id ebox/padding-inline-end
     :aliases (:padding-right :padding-right-pixel) :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :padding-block-end :id ebox/padding-block-end
     :aliases (:padding-bottom :padding-bottom-height) :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :padding-inline-start :id ebox/padding-inline-start
     :aliases (:padding-left :padding-left-pixel) :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :margin-block-start :id ebox/margin-block-start
     :aliases (:margin-top :margin-top-height) :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :margin-inline-end :id ebox/margin-inline-end
     :aliases (:margin-right :margin-right-pixel) :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :margin-block-end :id ebox/margin-block-end
     :aliases (:margin-bottom :margin-bottom-height) :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :margin-inline-start :id ebox/margin-inline-start
     :aliases (:margin-left :margin-left-pixel) :initial 0 :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :border-top-width :id ebox/border-top-width
     :aliases (:border-top-p) :initial nil :contexts (box)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :border-right-width :id ebox/border-right-width
     :aliases (:border-right-pixel) :initial nil :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :border-bottom-width :id ebox/border-bottom-width
     :aliases (:border-bottom-p) :initial nil :contexts (box)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :border-left-width :id ebox/border-left-width
     :aliases (:border-left-pixel) :initial nil :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :border-top-style :id ebox/border-top-style :initial nil
     :contexts (box) :group structure :dirty-kind structure :signature layout)
    (:name :border-right-style :id ebox/border-right-style :initial nil
     :contexts (box) :group structure :dirty-kind structure :signature layout)
    (:name :border-bottom-style :id ebox/border-bottom-style :initial nil
     :contexts (box) :group structure :dirty-kind structure :signature layout)
    (:name :border-left-style :id ebox/border-left-style :initial nil
     :contexts (box) :group structure :dirty-kind structure :signature layout)
    (:name :border-top-color :id ebox/border-top-color :initial nil
     :contexts (box) :group paint :dirty-kind paint :signature paint
     :normalizer color)
    (:name :border-right-color :id ebox/border-right-color :initial nil
     :contexts (box) :group paint :dirty-kind paint :signature paint
     :normalizer color)
    (:name :border-bottom-color :id ebox/border-bottom-color :initial nil
     :contexts (box) :group paint :dirty-kind paint :signature paint
     :normalizer color)
    (:name :border-left-color :id ebox/border-left-color :initial nil
     :contexts (box) :group paint :dirty-kind paint :signature paint
     :normalizer color)
    (:name :text-align :id ebox/text-align :initial left :contexts (box)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :vertical-align :id ebox/vertical-align :initial top :contexts (box)
     :group geometry :dirty-kind geometry :signature layout
     :normalizer vertical-align)
    (:name :overflow :id ebox/overflow :initial scroll :contexts (box)
     :group structure :dirty-kind geometry :signature layout)
    (:name :wrap-mode :id ebox/wrap-mode :initial word :contexts (box)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :visibility :id ebox/visibility :initial visible :contexts (box)
     :group paint :dirty-kind paint :signature paint)
    (:name :display :id ebox/display :initial nil :contexts (node)
     :group structure :dirty-kind structure :signature structure
     :validator display)
    (:name :outer :id ebox/outer :initial block :contexts (node)
     :group structure :dirty-kind structure :signature structure
     :validator outer)
    (:name :layout :id ebox/layout :initial normal :contexts (node)
     :group structure :dirty-kind structure :signature structure
     :validator layout)
    (:name :flex-direction :id ebox/flex-direction :initial nil
     :contexts (flex) :group geometry :dirty-kind geometry :signature layout)
    (:name :flex-wrap :id ebox/flex-wrap :initial nil :contexts (flex)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :justify-content :id ebox/justify-content :initial nil
     :contexts (flex grid) :group geometry :dirty-kind geometry :signature layout)
    (:name :align-items :id ebox/align-items :initial nil
     :contexts (flex grid) :group geometry :dirty-kind geometry :signature layout)
    (:name :align-content :id ebox/align-content :initial nil
     :contexts (flex grid) :group geometry :dirty-kind geometry :signature layout)
    (:name :justify-items :id ebox/justify-items :initial nil
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout)
    (:name :row-gap :id ebox/row-gap :aliases (:grid-row-gap) :initial nil
     :contexts (flex grid) :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-size)
    (:name :column-gap :id ebox/column-gap :aliases (:grid-column-gap)
     :initial nil :contexts (flex grid) :group geometry :dirty-kind geometry
     :signature layout :validator nonnegative-size)
    (:name :order :id ebox/order :initial nil :contexts (item)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :flex-grow :id ebox/flex-grow :initial nil :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-number)
    (:name :flex-shrink :id ebox/flex-shrink :initial nil :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator nonnegative-number)
    (:name :flex-basis :id ebox/flex-basis :initial nil :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator horizontal-size)
    (:name :align-self :id ebox/align-self :initial nil :contexts (item)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :grid-template-columns :id ebox/grid-template-columns :initial nil
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout)
    (:name :grid-template-rows :id ebox/grid-template-rows :initial nil
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout)
    (:name :grid-auto-columns :id ebox/grid-auto-columns :initial nil
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout)
    (:name :grid-auto-rows :id ebox/grid-auto-rows :initial nil
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout)
    (:name :grid-auto-flow :id ebox/grid-auto-flow :initial nil
     :contexts (grid) :group structure :dirty-kind structure :signature layout)
    (:name :grid-column :id ebox/grid-column :initial nil :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator grid-placement)
    (:name :grid-row :id ebox/grid-row :initial nil :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator grid-placement)
    (:name :grid-column-span :id ebox/grid-column-span :initial nil
     :contexts (item) :group geometry :dirty-kind geometry :signature layout
     :validator positive-integer)
    (:name :grid-row-span :id ebox/grid-row-span :initial nil
     :contexts (item) :group geometry :dirty-kind geometry :signature layout
     :validator positive-integer)
    (:name :padding :id ebox/padding :shorthand padding)
    (:name :padding-inline :id ebox/padding-inline :shorthand padding-inline)
    (:name :padding-block :id ebox/padding-block :shorthand padding-block)
    (:name :margin :id ebox/margin :shorthand margin)
    (:name :margin-inline :id ebox/margin-inline :shorthand margin-inline)
    (:name :margin-block :id ebox/margin-block :shorthand margin-block)
    (:name :border :id ebox/border :shorthand border)
    (:name :border-top :id ebox/border-top :shorthand border-top)
    (:name :border-right :id ebox/border-right :shorthand border-right)
    (:name :border-bottom :id ebox/border-bottom :shorthand border-bottom)
    (:name :border-left :id ebox/border-left :shorthand border-left)
    (:name :border-width :id ebox/border-width :shorthand border-width
     :group geometry :dirty-kind geometry :signature layout)
    (:name :border-style :id ebox/border-style :shorthand border-style
     :group structure :dirty-kind structure :signature layout)
    (:name :border-color :id ebox/border-color :shorthand border-color
     :group paint :dirty-kind paint :signature paint)
    (:name :gap :id ebox/gap :shorthand gap
     :group geometry :dirty-kind geometry :signature layout)
    (:name :flex-flow :id ebox/flex-flow :shorthand flex-flow
     :group geometry :dirty-kind geometry :signature layout)
    (:name :flex :id ebox/flex :shorthand flex
     :group geometry :dirty-kind geometry :signature layout))
  "Canonical Ebox property schemas and public aliases.")

(defvar ebox-style--property-table nil
  "Hash table from canonical property names and aliases to metadata.")

(defvar ebox-style-schemas (ebox-style--create-schema-set)
  "ECSS property schemas for the isolated Ebox style domain.")

(defvar ebox-style--registered-schemas nil
  "Schema-set object whose Ebox properties are already registered.
`ecss-schema-set-property' returns a detached schema copy, so probing it on
every `ebox-create' needlessly copies the entire property metadata domain.")

(defconst ebox-style--declaration-cache-max-entries 512
  "Maximum canonical declaration compilations retained by Ebox.")

(defvar ebox-style--declaration-cache
  (make-hash-table :test 'equal)
  "Bounded memo table for canonical Ebox declaration compilation.")

(defun ebox-style--ensure-property-table ()
  "Return the canonical style property registry table."
  (or ebox-style--property-table
      (let ((table (make-hash-table :test 'eq)))
        (dolist (property ebox-style--property-definitions)
          (puthash (plist-get property :name) property table)
          (puthash (plist-get property :id) property table)
          (dolist (alias (plist-get property :aliases))
            (puthash alias property table)))
        (setq ebox-style--property-table table))))

(defun ebox-style-property (name)
  "Return registered style metadata for canonical property or alias NAME."
  (gethash name (ebox-style--ensure-property-table)))

(defun ebox-style-canonical-name (name)
  "Return canonical CSS-like longhand property name for NAME."
  (when-let* ((property (ebox-style-property name)))
    (plist-get property :name)))

(defun ebox-style-schema-id (name)
  "Return namespaced ECSS schema id for Ebox property NAME."
  (when-let* ((property (ebox-style-property name)))
    (plist-get property :id)))

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

(defun ebox-style--trbl-declarations (properties value)
  "Expand VALUE across four namespaced PROPERTIES."
  (cl-loop for property in properties
           for part in (ebox-style--split-trbl value)
           append (list property part)))

(defun ebox-style--pair-declarations (properties value)
  "Expand VALUE across two namespaced PROPERTIES."
  (cl-loop for property in properties
           for part in (ebox-style--split-pair value)
           append (list property part)))

(defun ebox-style--padding-shorthand (value)
  "Expand padding VALUE to namespaced logical longhands."
  (ebox-style--trbl-declarations
   '(ebox/padding-block-start ebox/padding-inline-end
     ebox/padding-block-end ebox/padding-inline-start)
   value))

(defun ebox-style--padding-inline-shorthand (value)
  "Expand inline padding VALUE to namespaced longhands."
  (ebox-style--pair-declarations
   '(ebox/padding-inline-start ebox/padding-inline-end) value))

(defun ebox-style--padding-block-shorthand (value)
  "Expand block padding VALUE to namespaced longhands."
  (ebox-style--pair-declarations
   '(ebox/padding-block-start ebox/padding-block-end) value))

(defun ebox-style--margin-shorthand (value)
  "Expand margin VALUE to namespaced logical longhands."
  (ebox-style--trbl-declarations
   '(ebox/margin-block-start ebox/margin-inline-end
     ebox/margin-block-end ebox/margin-inline-start)
   value))

(defun ebox-style--margin-inline-shorthand (value)
  "Expand inline margin VALUE to namespaced longhands."
  (ebox-style--pair-declarations
   '(ebox/margin-inline-start ebox/margin-inline-end) value))

(defun ebox-style--margin-block-shorthand (value)
  "Expand block margin VALUE to namespaced longhands."
  (ebox-style--pair-declarations
   '(ebox/margin-block-start ebox/margin-block-end) value))

(defconst ebox-style--border-sides '(top right bottom left)
  "Physical border sides in CSS shorthand order.")

(defun ebox-style--border-side-declarations (side value)
  "Expand border VALUE for SIDE to three namespaced longhands."
  (pcase-let ((`(,width ,style ,color) (ebox-style--split-wsc value)))
    (list (intern (format "ebox/border-%s-width" side)) width
          (intern (format "ebox/border-%s-style" side)) style
          (intern (format "ebox/border-%s-color" side)) color)))

(defun ebox-style--border-shorthand (value)
  "Expand border VALUE directly to all namespaced side longhands."
  (cl-mapcan (lambda (side)
               (ebox-style--border-side-declarations side value))
             ebox-style--border-sides))

(defun ebox-style--border-top-shorthand (value)
  "Expand top border VALUE to namespaced longhands."
  (ebox-style--border-side-declarations 'top value))

(defun ebox-style--border-right-shorthand (value)
  "Expand right border VALUE to namespaced longhands."
  (ebox-style--border-side-declarations 'right value))

(defun ebox-style--border-bottom-shorthand (value)
  "Expand bottom border VALUE to namespaced longhands."
  (ebox-style--border-side-declarations 'bottom value))

(defun ebox-style--border-left-shorthand (value)
  "Expand left border VALUE to namespaced longhands."
  (ebox-style--border-side-declarations 'left value))

(defun ebox-style--border-component-shorthand (component value)
  "Expand border COMPONENT VALUE across all physical sides."
  (ebox-style--trbl-declarations
   (mapcar (lambda (side)
             (intern (format "ebox/border-%s-%s" side component)))
           ebox-style--border-sides)
   value))

(defun ebox-style--border-width-shorthand (value)
  "Expand border width VALUE across all physical sides."
  (ebox-style--border-component-shorthand 'width value))

(defun ebox-style--border-style-shorthand (value)
  "Expand border style VALUE across all physical sides."
  (ebox-style--border-component-shorthand 'style value))

(defun ebox-style--border-color-shorthand (value)
  "Expand border color VALUE across all physical sides."
  (ebox-style--border-component-shorthand 'color value))

(defun ebox-style--gap-shorthand (value)
  "Expand gap VALUE to row and column gaps."
  (ebox-style--pair-declarations '(ebox/row-gap ebox/column-gap) value))

(defun ebox-style--flex-flow-shorthand (value)
  "Expand flex-flow VALUE to direction and wrapping longhands."
  (let ((values (if (listp value) value (list value))) direction wrap)
    (setq direction
          (cl-find-if (lambda (item)
                        (memq item '(row row-reverse column column-reverse)))
                      values)
          wrap (cl-find-if (lambda (item)
                             (memq item '(nowrap wrap wrap-reverse)))
                           values))
    (list 'ebox/flex-direction direction 'ebox/flex-wrap wrap)))

(defun ebox-style--flex-shorthand (value)
  "Expand flex item VALUE to grow, shrink, and basis longhands."
  (pcase value
    ((pred numberp) (list 'ebox/flex-grow value 'ebox/flex-shrink 1
                          'ebox/flex-basis 0))
    ('none '(ebox/flex-grow 0 ebox/flex-shrink 0 ebox/flex-basis auto))
    ('auto '(ebox/flex-grow 1 ebox/flex-shrink 1 ebox/flex-basis auto))
    ('initial '(ebox/flex-grow 0 ebox/flex-shrink 1 ebox/flex-basis auto))
    ((pred listp)
     (list 'ebox/flex-grow (or (nth 0 value) 0)
           'ebox/flex-shrink (or (nth 1 value) 1)
           'ebox/flex-basis (if (> (length value) 2) (nth 2 value) 'auto)))
    (_ '(ebox/flex-grow 0 ebox/flex-shrink 1 ebox/flex-basis auto))))

(defun ebox-style--normalizer (name)
  "Return schema normalizer named NAME."
  (pcase name
    ('color #'ebox-style--parse-color)
    ('vertical-align (lambda (value) (if (eq value 'middle) 'center value)))
    (_ #'identity)))

(defun ebox-style--negative-numeric-size-p (value)
  "Return non-nil when VALUE is or starts with a negative number."
  (or (and (numberp value) (< value 0))
      (and (consp value)
           (numberp (car value))
           (< (car value) 0))))

(defun ebox-style--nonnegative-size-p (value)
  "Return non-nil when VALUE is not a negative numeric size."
  (not (ebox-style--negative-numeric-size-p value)))

(defun ebox-style--nonnegative-number-p (value)
  "Return non-nil when VALUE is nil or a non-negative number."
  (or (null value) (and (numberp value) (>= value 0))))

(defun ebox-style--positive-integer-p (value)
  "Return non-nil when VALUE is nil or a positive integer."
  (or (null value) (and (integerp value) (> value 0))))

(defun ebox-style--grid-placement-p (value)
  "Return non-nil when VALUE is a valid public Grid placement."
  (or (null value)
      (and (integerp value) (> value 0))
      (and (proper-list-p value)
           (pcase value
             (`(,start)
              (and (integerp start) (> start 0)))
             (`(,start :span ,span)
              (and (integerp start) (> start 0)
                   (integerp span) (> span 0)))
             (`(,start ,end)
              (and (integerp start) (> start 0)
                   (integerp end) (> end start)))))))

(defun ebox-style--display-p (value)
  "Return non-nil when VALUE is nil or an Ebox display pair."
  (or (null value)
      (and (listp value) (= (length value) 2)
           (cl-every #'symbolp value))))

(defun ebox-style--outer-p (value)
  "Return non-nil when VALUE is an Ebox outer participation value."
  (memq value '(inline block)))

(defun ebox-style--layout-p (value)
  "Return non-nil when VALUE is an Ebox child layout value."
  (memq value '(normal row column flex grid)))

(defun ebox-style--font-p (value)
  "Return non-nil when VALUE is an Ebox font face specification."
  (or (null value) (symbolp value) (stringp value) (proper-list-p value)))

(defun ebox-style--font-family-p (value)
  "Return non-nil when VALUE is an Ebox font family."
  (or (null value) (stringp value) (symbolp value)))

(defun ebox-style--font-height-p (value)
  "Return non-nil when VALUE is an Emacs face height."
  (or (null value) (numberp value) (functionp value)))

(defun ebox-style--font-attribute-p (value)
  "Return non-nil when VALUE is a symbolic font attribute."
  (or (null value) (symbolp value)))

(defun ebox-style--validator (name)
  "Return schema validator named NAME."
  (pcase name
    ((or 'horizontal-size 'nonnegative-size)
     #'ebox-style--nonnegative-size-p)
    ('nonnegative-number #'ebox-style--nonnegative-number-p)
    ('positive-integer #'ebox-style--positive-integer-p)
    ('grid-placement #'ebox-style--grid-placement-p)
    ('display #'ebox-style--display-p)
    ('outer #'ebox-style--outer-p)
    ('layout #'ebox-style--layout-p)
    ('font #'ebox-style--font-p)
    ('font-family #'ebox-style--font-family-p)
    ('font-height #'ebox-style--font-height-p)
    ('font-attribute #'ebox-style--font-attribute-p)
    (_ (lambda (_value) t))))

(defun ebox-style--shorthand (name)
  "Return shorthand expander named NAME."
  (alist-get
   name
   '((padding . ebox-style--padding-shorthand)
     (padding-inline . ebox-style--padding-inline-shorthand)
     (padding-block . ebox-style--padding-block-shorthand)
     (margin . ebox-style--margin-shorthand)
     (margin-inline . ebox-style--margin-inline-shorthand)
     (margin-block . ebox-style--margin-block-shorthand)
     (border . ebox-style--border-shorthand)
     (border-top . ebox-style--border-top-shorthand)
     (border-right . ebox-style--border-right-shorthand)
     (border-bottom . ebox-style--border-bottom-shorthand)
     (border-left . ebox-style--border-left-shorthand)
     (border-width . ebox-style--border-width-shorthand)
     (border-style . ebox-style--border-style-shorthand)
     (border-color . ebox-style--border-color-shorthand)
     (gap . ebox-style--gap-shorthand)
     (flex-flow . ebox-style--flex-flow-shorthand)
     (flex . ebox-style--flex-shorthand))))

(defun ebox-style--schema-options (property)
  "Return ECSS registration options for PROPERTY metadata."
  (let ((options (list :initial (plist-get property :initial)
                       :inherits (plist-get property :inherits)
                       :normalizer (ebox-style--normalizer
                                    (plist-get property :normalizer))
                       :validator (ebox-style--validator
                                   (plist-get property :validator))
                       :equality #'equal)))
    (when-let* ((shorthand (ebox-style--shorthand
                           (plist-get property :shorthand))))
      (setq options (plist-put options :shorthand shorthand)))
    options))

(defvar ebox-style--closed-computed-cache (make-hash-table :test #'equal)
  "Bounded cache of selector-free, dependency-free computed styles.")

(defconst ebox-style--closed-computed-cache-limit 512
  "Maximum selector-free computed styles retained across projections.")

(declare-function tp-computed-p "tp-style" (value))

(defun ebox-style--closed-declarations-p (declarations)
  "Return non-nil when DECLARATIONS contain no computed value source."
  (cl-loop for (_property value) on declarations by #'cddr
           never (tp-computed-p value)))

(defun ebox-style-register-properties ()
  "Register the complete namespaced Ebox property domain with ECSS."
  (dolist (property ebox-style--property-definitions)
    (apply #'ecss-schema-set-define
           ebox-style-schemas (plist-get property :id)
           (ebox-style--schema-options property)))
  (clrhash ebox-style--closed-computed-cache)
  (setq ebox-style--registered-schemas ebox-style-schemas))

(defun ebox-style--ensure-properties ()
  "Ensure Ebox property schemas exist in the isolated ECSS schema set."
  (unless (eq ebox-style--registered-schemas ebox-style-schemas)
    ;; Only the first call for a new schema-set needs to inspect/register the
    ;; domain.  Avoid the detached `ecss-schema-set-property' accessor on the
    ;; hot `ebox-create' path; it recursively copies schema metadata.
    (if (ecss-schema-set-property ebox-style-schemas 'ebox/color)
        (setq ebox-style--registered-schemas ebox-style-schemas)
      (ebox-style-register-properties))))

(defvar ebox-style-stylesheet (ebox-style--create-stylesheet)
  "Isolated ECSS stylesheet containing Ebox layout and paint rules.")

(defun ebox-style-cascade-active-p ()
  "Return non-nil when the Ebox stylesheet contains cascade rules.
Inline declarations are compiled into Ebox engine properties while nodes are
created, so a surface with no stylesheet rules does not need a per-node ECSS
cascade pass during its initial static projection."
  (not (null (ecss-stylesheet-rules ebox-style-stylesheet))))

(defun ebox-style-reset-rules ()
  "Clear all rules and cascade layers in `ebox-style-stylesheet'."
  (ecss-stylesheet-clear ebox-style-stylesheet))

(defun ebox-style--selector (selector)
  "Return ECSS selector AST compiled from Ebox SELECTOR."
  (if (stringp selector)
      (progn
        (require 'ebox-selector)
        (ebox-selector-parse selector))
    selector))

(defun ebox-style--custom-property-p (property)
  "Return non-nil when PROPERTY names an ECSS custom property."
  (and (symbolp property)
       (string-prefix-p "--" (symbol-name property))))

(defun ebox-style--valid-plist-p (plist)
  "Return non-nil when PLIST is a proper even-length list."
  (and (proper-list-p plist) (zerop (% (length plist) 2))))

(defun ebox-style--declaration-cache-key (plist strict)
  "Return a stable style-only cache key for PLIST and STRICT.
Non-style node properties such as content, Host references, and callbacks do
not affect declaration compilation and are intentionally excluded."
  (let (canonical)
    (cl-loop for (property value) on plist by #'cddr
             for schema = (ebox-style-schema-id property)
             if schema
             do (setq canonical
                      (append canonical (list schema value)))
             else if (ebox-style--custom-property-p property)
             do (setq canonical
                      (append canonical (list property value))))
    (list strict canonical)))

(defun ebox-style--static-invalid-declaration-p (validator value)
  "Return non-nil when VALIDATOR rejects static VALUE."
  (pcase validator
    ('nonnegative-number
     (and (numberp value) (< value 0)))
    ((or 'horizontal-size 'nonnegative-size)
     (ebox-style--negative-numeric-size-p value))
    ('positive-integer
     (and (numberp value) (not (ebox-style--positive-integer-p value))))
    ('grid-placement
     (and (or (numberp value) (proper-list-p value))
          (not (ebox-style--grid-placement-p value))))))

(defun ebox-style--validate-declaration-values (declarations)
  "Return DECLARATIONS after static Ebox-owned value validation."
  (cl-loop for (property value) on declarations by #'cddr
           for schema = (ebox-style-property property)
           for validator = (and schema (plist-get schema :validator))
           when (ebox-style--static-invalid-declaration-p validator value)
           do (error "ebox: invalid value for %S: %S"
                     (plist-get schema :name) value))
  declarations)

(defun ebox-style-compile-declarations (plist &optional strict)
  "Compile Ebox PLIST aliases to ECSS schema declarations.
When STRICT is non-nil, reject properties outside the Ebox style domain."
  (ebox-style--ensure-properties)
  (unless (ebox-style--valid-plist-p plist)
    (user-error "Ebox style declarations must be an even property list"))
  (let* ((cache-key (ebox-style--declaration-cache-key plist strict))
         (missing (make-symbol "ebox-style-declaration-cache-missing"))
         (cached (gethash cache-key ebox-style--declaration-cache missing)))
    (if (not (eq cached missing))
        ;; Canonical declaration plists are immutable after compilation;
        ;; return a fresh top-level plist so callers own their list spine
        ;; without re-running ECSS's recursive boundary copier.
        (copy-sequence cached)
      (let ((canonical (cadr cache-key)))
        (when strict
          (cl-loop for (property _value) on plist by #'cddr
                   unless (or (ebox-style-schema-id property)
                              (ebox-style--custom-property-p property))
                   do (user-error "Unknown Ebox style property: %S"
                                  property)))
        (let ((compiled
               (ebox-style--validate-declaration-values
                (ecss-merge-declarations ebox-style-schemas canonical))))
          (when (>= (hash-table-count ebox-style--declaration-cache)
                    ebox-style--declaration-cache-max-entries)
            (clrhash ebox-style--declaration-cache))
          (puthash cache-key compiled ebox-style--declaration-cache)
          (copy-sequence compiled))))))

(defun ebox-style-merge-declarations (base overrides)
  "Merge canonical BASE and OVERRIDES through ECSS property schemas."
  (ebox-style--ensure-properties)
  (ecss-merge-declarations ebox-style-schemas base overrides))

(cl-defun ebox-style-add-rule
    (selector declarations &key (origin 'author) layer scope)
  "Add SELECTOR rule with Ebox DECLARATIONS to the isolated stylesheet.
ORIGIN, LAYER, and SCOPE use ECSS cascade semantics."
  (ebox-style--ensure-properties)
  (ecss-stylesheet-add-rule
   ebox-style-stylesheet ebox-style-schemas (ebox-style--selector selector)
   (ebox-style-compile-declarations declarations t)
   :origin origin :layer layer
   :scope (and scope (ebox-style--selector scope))))

(defun ebox-style-compute-subject (subject declarations &optional parent-style)
  "Compute SUBJECT style from DECLARATIONS and optional PARENT-STYLE via ECSS."
  (ebox-style--ensure-properties)
  (let* ((closed-p
          (and (not (ebox-style-cascade-active-p))
               (ebox-style--closed-declarations-p declarations)))
         (key (and closed-p (list declarations parent-style)))
         (missing (make-symbol "ebox-closed-style-cache-missing"))
         (cached (and key (gethash key ebox-style--closed-computed-cache
                                   missing))))
    (if (and key (not (eq cached missing)))
        cached
      (let ((style
             (ecss-compute-style
              ebox-style-schemas subject :declarations declarations
              :stylesheet ebox-style-stylesheet :parent-style parent-style
              :value-resolver #'tp-resolve-value)))
        (when key
          (when (>= (hash-table-count ebox-style--closed-computed-cache)
                    ebox-style--closed-computed-cache-limit)
            (clrhash ebox-style--closed-computed-cache))
          (puthash key style ebox-style--closed-computed-cache))
        style))))

(defconst ebox-style--theme-delta-properties
  '(ebox/color ebox/background-color)
  "Canonical paint properties eligible for a declaration-only Theme delta.")

(defconst ebox-style--paint-delta-properties
  '(ebox/color ebox/background-color
    ebox/border-top-color ebox/border-right-color
    ebox/border-bottom-color ebox/border-left-color)
  "Canonical paint properties that may change without changing geometry.")

(defun ebox-style--without-theme-delta-properties (declarations)
  "Return DECLARATIONS without the canonical Theme paint properties."
  (cl-loop for (property value) on declarations by #'cddr
           unless (memq property ebox-style--theme-delta-properties)
           append (list property value)))

(defun ebox-style--without-paint-delta-properties (declarations)
  "Return DECLARATIONS without canonical paint-only properties."
  (cl-loop for (property value) on declarations by #'cddr
           unless (memq property ebox-style--paint-delta-properties)
           append (list property value)))

(defun ebox-style--paint-declarations-equivalent-p (old new)
  "Return non-nil when OLD and NEW differ only in paint declarations.
All paint properties retain presence parity; layout, structure, and typography
declarations must remain identical."
  (and (equal (ebox-style--without-paint-delta-properties old)
              (ebox-style--without-paint-delta-properties new))
       (cl-every
        (lambda (property)
          (= (if (plist-member old property) 1 0)
             (if (plist-member new property) 1 0)))
        ebox-style--paint-delta-properties)))

(defun ebox-style--theme-declarations-equivalent-p (old new)
  "Return non-nil when OLD and NEW differ only in explicit Theme paint values.
Both paint properties must retain presence parity and an explicit foreground
winner is required so parent inherited geometry/paint cannot be stale."
  (and (equal (ebox-style--without-theme-delta-properties old)
              (ebox-style--without-theme-delta-properties new))
       (cl-every
        (lambda (property)
          (= (if (plist-member old property) 1 0)
             (if (plist-member new property) 1 0)))
        ebox-style--theme-delta-properties)
       (plist-member old 'ebox/color)
       (plist-member new 'ebox/color)))

(defconst ebox-style--inherited-properties
  '(ebox/color ebox/font ebox/font-family ebox/font-height
    ebox/font-weight ebox/font-slant)
  "Inherited ECSS properties whose parent values guard Theme deltas.")

(defun ebox-style--inherited-style-signature (style)
  "Return the inherited-value fingerprint of computed STYLE, or nil.
The fingerprint deliberately contains only values that can flow from a
parent into a descendant, plus custom properties which can feed any
`var' expression.  A Theme delta may reuse a computed style only when this
fingerprint is unchanged between the old and candidate parent."
  (when (ecss-computed-style-p style)
    (list
     :inherited
     (mapcar (lambda (property)
               (cons property (ecss-computed-style-value style property)))
             ebox-style--inherited-properties)
     :custom-properties (ecss-computed-style-custom-properties style))))

(defun ebox-style--theme-delta-computed
    (style old-declarations new-declarations
           &optional old-parent-style new-parent-style)
  "Return a cheap STYLE copy for a safe Theme paint-only declaration delta.
OLD-DECLARATIONS and NEW-DECLARATIONS are the canonical ECSS plists.
OLD-PARENT-STYLE and NEW-PARENT-STYLE are the previous and candidate
computed parent styles, when the subject has an inherited parent.

The cascade selector facts and every non-Theme declaration must be unchanged;
both Theme properties must keep the same explicit-presence state, and the
inherited parent fingerprint must be unchanged.  In that case only the
computed values and winner metadata for those properties change.  Any other
shape returns nil so the caller uses the full ECSS computation."
  (when (and (ecss-computed-style-p style)
             (ebox-style--theme-declarations-equivalent-p
              old-declarations new-declarations))
    (let ((changed-p
           (cl-some
            (lambda (property)
              (and (plist-member old-declarations property)
                   (plist-member new-declarations property)
                   (not (equal (plist-get old-declarations property)
                               (plist-get new-declarations property)))))
            ebox-style--theme-delta-properties)))
      (when (and changed-p
                 (equal (ebox-style--inherited-style-signature
                         old-parent-style)
                        (ebox-style--inherited-style-signature
                         new-parent-style)))
        (let ((values (copy-tree (ecss-computed-style-values style)))
              (active (copy-sequence
                       (ecss-computed-style-active-properties style)))
              (specified (copy-sequence
                          (ecss-computed-style-specified-properties style))))
          (dolist (property ebox-style--theme-delta-properties)
            (let ((id (ebox-style-schema-id property)))
              (when (plist-member new-declarations property)
                (setf values
                      (plist-put values id
                                 (copy-tree (plist-get new-declarations property))))
                (cl-pushnew id active)
                (cl-pushnew id specified))))
          (ecss-computed-style-copy-with-values
           style values :active-properties active :specified-properties specified))))))

(defun ebox-style--inherited-style-signature-without-theme-color (style)
  "Return STYLE's inherited fingerprint excluding the Theme color value.
The caller uses this to prove that a parent update changes only the inherited
foreground value; fonts, custom properties, and all other inherited facts must
  remain identical before a computed child style may be copied."
  (when (ecss-computed-style-p style)
    (list
     :inherited
     (mapcar
      (lambda (property)
        (cons property (ecss-computed-style-value style property)))
      (delq 'ebox/color (copy-sequence ebox-style--inherited-properties)))
     :custom-properties (ecss-computed-style-custom-properties style))))

(defun ebox-style--theme-parent-delta-computed
    (style declarations old-parent-style new-parent-style)
  "Return a copied STYLE when a static parent changes only Theme color.
For an explicit child color, STYLE is reusable unchanged.  For an inherited
child color, the copied value follows NEW-PARENT-STYLE.  OLD-PARENT-STYLE and
NEW-PARENT-STYLE must have identical non-color inherited fingerprints; any
provenance or parent-shape mismatch returns nil for normal ECSS computation."
  (when (and (ecss-computed-style-p style)
             (proper-list-p declarations)
             (ecss-computed-style-p old-parent-style)
             (ecss-computed-style-p new-parent-style)
             (equal
              (ebox-style--inherited-style-signature-without-theme-color
               old-parent-style)
              (ebox-style--inherited-style-signature-without-theme-color
               new-parent-style)))
    (if (ecss-computed-style-specified-p style 'ebox/color)
        (ecss-computed-style-copy-with-values
         style (ecss-computed-style-values style))
      (when (and (equal (ecss-computed-style-value
                         style 'ebox/color)
                        (ecss-computed-style-value
                         old-parent-style 'ebox/color))
                 (not (equal (ecss-computed-style-value
                              old-parent-style 'ebox/color)
                             (ecss-computed-style-value
                              new-parent-style 'ebox/color))))
        (let ((values (copy-tree (ecss-computed-style-values style))))
          (setq values
                (plist-put values 'ebox/color
                           (copy-tree
                            (ecss-computed-style-value
                             new-parent-style 'ebox/color))))
          (ecss-computed-style-copy-with-values style values))))))

(defun ebox-style--theme-inherited-delta-computed
    (style declarations old-parent-style new-parent-style)
  "Return a copied STYLE when only inherited Theme color changed.
This compatibility entry point requires STYLE to inherit its color; explicit
child colors are handled by `ebox-style--theme-parent-delta-computed'."
  (when (and (ecss-computed-style-p style)
             (not (ecss-computed-style-specified-p style 'ebox/color)))
    (ebox-style--theme-parent-delta-computed
     style declarations old-parent-style new-parent-style)))

(defun ebox-style--public-computed-values (style)
  "Return STYLE values using canonical public Ebox property names."
  (let ((values (ecss-computed-style-values style)) result)
    (dolist (property ebox-style--property-definitions)
      (unless (plist-get property :shorthand)
        (setq result
              (plist-put result (plist-get property :name)
                         (plist-get values (plist-get property :id))))))
    result))

(defun ebox-style--common-border-value (style component)
  "Return common border COMPONENT in STYLE, or nil when sides differ."
  (let ((values
         (mapcar (lambda (side)
                   (plist-get style
                              (intern (format ":border-%s-%s" side component))))
                 ebox-style--border-sides)))
    (when (cl-every (lambda (value) (equal value (car values))) (cdr values))
      (car values))))

(defun ebox-style--add-border-aggregates (style)
  "Add uniform border shorthand facts to public computed STYLE."
  (dolist (component '(width style color) style)
    (when-let* ((value (ebox-style--common-border-value style component)))
      (setq style
            (plist-put style (intern (format ":border-%s" component)) value)))))

(defun ebox-style-compute (plist)
  "Return canonical public computed style for inline PLIST through ECSS."
  (let ((style
         (ecss-compute-style
          ebox-style-schemas (ecss-subject-create :type "box")
          :declarations (ebox-style-compile-declarations plist)
          :rules nil :value-resolver #'tp-resolve-value)))
    (ebox-style--add-border-aggregates
     (ebox-style--public-computed-values style))))

(defun ebox-style-expand-shorthands (plist)
  "Expand PLIST to canonical public longhands through ECSS schemas."
  (ebox-style-compute plist))

(defun ebox-style-computed-active-p (style property)
  "Return non-nil when computed STYLE actively contributes PROPERTY."
  (memq (ebox-style-schema-id property)
        (ecss-computed-style-active-properties style)))

(defun ebox-style-computed-value (style property)
  "Return computed STYLE value for public Ebox PROPERTY."
  (plist-get (ecss-computed-style-values style)
             (ebox-style-schema-id property)))

(defun ebox-style--computed-snapshot (style &optional specified-p)
  "Return one detached ECSS values snapshot for STYLE projection.
When SPECIFIED-P is non-nil, include declaration-winner facts."
  (list (ecss-computed-style-values style)
        (ecss-computed-style-active-properties style)
        (and specified-p
             (ecss-computed-style-specified-properties style))))

(defun ebox-style--snapshot-active-p (snapshot property)
  "Return non-nil when SNAPSHOT actively contributes PROPERTY."
  (memq (ebox-style-schema-id property) (nth 1 snapshot)))

(defun ebox-style--context-values
    (style context &optional specified-only snapshot)
  "Return public STYLE values for CONTEXT.
When SPECIFIED-ONLY is non-nil, exclude initial and inherited-only facts.
SNAPSHOT reuses a previously detached ECSS values snapshot when supplied."
  (let* ((snapshot
          (or snapshot
              (ebox-style--computed-snapshot style specified-only)))
         (values (nth 0 snapshot))
         (active (nth 1 snapshot))
        (specified
         (and specified-only
              (nth 2 snapshot)))
        result)
    (dolist (property ebox-style--property-definitions)
      (let ((id (plist-get property :id)))
        (when (and (not (plist-get property :shorthand))
                   (memq context (plist-get property :contexts))
                   (memq id active)
                   (or (not specified-only)
                       (memq id specified)))
          (setq result
                (plist-put result (plist-get property :name)
                           (plist-get values id))))))
    result))

(defun ebox-style--specified-property-p (style property)
  "Return non-nil when STYLE PROPERTY has a declaration winner."
  (ecss-computed-style-specified-p style property))

(defun ebox-style-node-declarations (node)
  "Return canonical ECSS declarations stored on semantic Ebox NODE."
  (let ((declarations (plist-get node :ebox-style-declarations)))
    (if (memq (plist-get node :ebox-type) '(flex grid))
        (ebox-style-merge-declarations
         declarations
         (plist-get (plist-get node :box) :ebox-style-overrides))
      (copy-sequence declarations))))

(defun ebox-style--remove-style-properties (plist)
  "Return PLIST without Ebox style or ECSS custom properties."
  (cl-loop for (property value) on plist by #'cddr
           unless (or (ebox-style-property property)
                      (ebox-style--custom-property-p property))
           append (list property value)))

(defun ebox-style--reset-box-engine-style (box)
  "Reset BOX engine style fields to their declared defaults."
  (cl-loop for (property value) on ebox--longhand by #'cddr
           unless (memq property '(:content :scroll-offset))
           do (plist-put box property (copy-tree value)))
  box)

(defun ebox-style--apply-engine-values (box values)
  "Project public style VALUES into BOX engine fields."
  (ebox-style--reset-box-engine-style box)
  (let ((expanded (ebox-style-expand-ebox-plist values)))
    (cl-loop for (property value) on expanded by #'cddr
             do (plist-put box property value)))
  box)

(defun ebox-style--box-values (style &optional snapshot)
  "Return computed box values ready for Ebox engine projection."
  (let* ((snapshot (or snapshot (ebox-style--computed-snapshot style)))
         (values (ebox-style--context-values style 'box nil snapshot)))
    (when (and (ebox-style--snapshot-active-p snapshot :color)
               (null (plist-get values :color)))
      (setq values
            (plist-put values :color ebox-style--default-foreground)))
    values))

(defconst ebox-style--container-wrapper-neutral-properties
  '(:width :height :box-sizing :color
    :font :font-family :font-height :font-weight :font-slant)
  "Container properties that do not require an internal visual wrapper.")

(defun ebox-style--container-wrapper-needed-p (style &optional snapshot)
  "Return non-nil when STYLE needs a visual container wrapper."
  (cl-loop for (property value)
           on (ebox-style--context-values style 'box t snapshot) by #'cddr
           thereis (and value
                        (not (memq
                              property
                              ebox-style--container-wrapper-neutral-properties)))))

(defun ebox-style--new-container-wrapper ()
  "Return a stable internal box for container-owned box paint."
  (let ((wrapper (ebox-create :content "" :wrap-mode nil
                              :key 'ebox/style-wrapper)))
    (plist-put wrapper :ebox-style-wrapper t)
    (plist-put wrapper :ebox-style-generated-wrapper t)
    wrapper))

(defun ebox-style--container-wrapper (node style &optional snapshot)
  "Return NODE wrapper required by STYLE, updating NODE ownership."
  (let ((wrapper (plist-get node :box))
        (needed (ebox-style--container-wrapper-needed-p style snapshot)))
    (cond
     (needed
      (unless wrapper
        (setq wrapper (ebox-style--new-container-wrapper))
        (plist-put node :box wrapper))
      wrapper)
     ((and wrapper (plist-get wrapper :ebox-style-generated-wrapper))
      (plist-put node :box nil)
      nil)
     (t wrapper))))

(defun ebox-style--apply-container-wrapper (node style &optional snapshot)
  "Apply computed STYLE to NODE's internal visual wrapper."
  (when-let* ((wrapper (ebox-style--container-wrapper node style snapshot)))
    (ebox-style--apply-engine-values
     wrapper
     (ebox-style--box-values style snapshot))
    (unless (ebox-style--specified-property-p style 'ebox/wrap-mode)
      (plist-put wrapper :wrap-mode nil))))

(defun ebox-style--grid-values (values)
  "Translate canonical container VALUES to Grid engine property names."
  (let ((row-present (plist-member values :row-gap))
        (column-present (plist-member values :column-gap)))
    (when row-present
      (setq values
            (plist-put values :grid-row-gap (plist-get values :row-gap))))
    (when column-present
      (setq values
            (plist-put values :grid-column-gap
                       (plist-get values :column-gap))))
    (cl-loop for (property value) on values by #'cddr
             unless (memq property '(:row-gap :column-gap))
             append (list property value))))

(defun ebox-style--apply-container (node style &optional snapshot)
  "Apply computed STYLE to Flex or Grid NODE."
  (let* ((type (plist-get node :ebox-type))
         (metadata
          (ebox-style--remove-style-properties (plist-get node :raw-props)))
         (values
          (append (ebox-style--context-values style 'box nil snapshot)
                  (ebox-style--context-values style type nil snapshot)))
         (raw (append metadata
                      (if (eq type 'grid)
                          (ebox-style--grid-values values)
                        values))))
    (plist-put node :raw-props raw)
    (plist-put node :props
               (if (eq type 'flex)
                   (ebox--flex-normalize-container-props raw)
                 raw))
    (ebox-style--apply-container-wrapper node style snapshot)))

(defun ebox-style--delete-node-property (node property)
  "Delete PROPERTY from NODE in place while preserving NODE identity."
  (when (eq (car node) property)
    (error "Ebox internal node property cannot occupy plist head: %S" property))
  (let ((tail node))
    (while (cddr tail)
      (if (eq (caddr tail) property)
          (setcdr (cdr tail) (cddddr tail))
        (setq tail (cddr tail)))))
  node)

(defun ebox-style--apply-item (node style &optional snapshot)
  "Apply computed Flex/Grid item fields from STYLE to NODE."
  (let ((values (ebox-style--context-values style 'item nil snapshot)))
    (dolist (property '(:order :flex-grow :flex-shrink :flex-basis :align-self
                        :grid-column :grid-row
                        :grid-column-span :grid-row-span))
      (ebox-style--delete-node-property node property))
    (cl-loop for (property value) on values by #'cddr
             do (plist-put node property value)))
  node)

(defun ebox-style--apply-display-axes (node style snapshot)
  "Apply computed display and public axes from STYLE SNAPSHOT to NODE."
  (when (ebox-style--snapshot-active-p snapshot :display)
    (plist-put node :display
               (ebox-style-computed-value style :display)))
  (let* ((outer-specified-p
          (ebox-style--specified-property-p style 'ebox/outer))
         (layout-specified-p
          (ebox-style--specified-property-p style 'ebox/layout)))
    (when (or outer-specified-p layout-specified-p)
      (let* ((display (or (plist-get node :display) '(block flow)))
             (outer (if outer-specified-p
                        (ebox-style-computed-value style :outer)
                      (car display)))
             (layout (if layout-specified-p
                         (ebox-style-computed-value style :layout)
                       (cadr display))))
        (plist-put node :display
                   (list outer (if (eq layout 'normal) 'flow layout))))))
  node)

(defun ebox-style-apply-computed (node style)
  "Apply ECSS computed STYLE consequences to semantic Ebox NODE."
  (unless (ecss-computed-style-p style)
    (signal 'wrong-type-argument (list 'ecss-computed-style-p style)))
  (let* ((type (plist-get node :ebox-type))
         (snapshot
          (ebox-style--computed-snapshot style (memq type '(flex grid)))))
    (plist-put node :ebox-computed-style style)
    (ebox-style--apply-display-axes node style snapshot)
    (pcase type
      ('box
       (ebox-style--apply-engine-values
        node
        (ebox-style--box-values style snapshot)))
      ((or 'flex 'grid)
       (ebox-style--apply-container node style snapshot)))
    (ebox-style--apply-item node style snapshot))
  node)

(defun ebox-style-sync-flex-item (item)
  "Synchronize internal Flex ITEM props from its semantic source style."
  (when (eq (plist-get item :ebox-type) 'flex-item)
    (when-let* ((source (plist-get item :node)))
      (let* ((source-style (plist-get source :ebox-computed-style))
             (child-style
              (when-let* ((child (plist-get source :ebox-content-node)))
                (plist-get child :ebox-computed-style)))
             (values
              (append
               (and source-style
                    (ebox-style--context-values source-style 'item))
               (and child-style
                    (ebox-style--context-values child-style 'item)))))
        (when (or source-style child-style)
          (plist-put item :props values)))))
  item)

(defun ebox-style-dirty-kind (name)
  "Return dirty kind for canonical property or alias NAME."
  (when-let* ((property (ebox-style-property name)))
    (plist-get property :dirty-kind)))

(defun ebox-style-signature (computed-style groups)
  "Return deterministic signature for COMPUTED-STYLE filtered by GROUPS."
  (let (entries)
    (while computed-style
      (let* ((property-name (pop computed-style))
             (value (pop computed-style))
             (property (ebox-style-property property-name))
             (group (and property (plist-get property :signature))))
        (when (and property
                   (or (null groups)
                       (memq group groups)
                       (memq (plist-get property :group) groups)))
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

(ebox-style-register-properties)

(defconst ebox-style-ebox-property-rules
  '((:padding :expand (:padding-top :padding-right
                                    :padding-bottom :padding-left)
              :mode trbl)
    (:padding-inline :expand (:padding-left :padding-right) :mode pair)
    (:padding-block :expand (:padding-top :padding-bottom) :mode pair)
    (:padding-top :to :padding-top-height :conv line)
    (:padding-block-start :to :padding-top-height :conv line)
    (:padding-right :to :padding-right-pixel :conv pixel)
    (:padding-inline-end :to :padding-right-pixel :conv pixel)
    (:padding-bottom :to :padding-bottom-height :conv line)
    (:padding-block-end :to :padding-bottom-height :conv line)
    (:padding-left :to :padding-left-pixel :conv pixel)
    (:padding-inline-start :to :padding-left-pixel :conv pixel)
    (:margin :expand (:margin-top :margin-right
                                  :margin-bottom :margin-left)
             :mode trbl)
    (:margin-inline :expand (:margin-left :margin-right) :mode pair)
    (:margin-block :expand (:margin-top :margin-bottom) :mode pair)
    (:margin-top :to :margin-top-height :conv line)
    (:margin-block-start :to :margin-top-height :conv line)
    (:margin-right :to :margin-right-pixel :conv pixel)
    (:margin-inline-end :to :margin-right-pixel :conv pixel)
    (:margin-bottom :to :margin-bottom-height :conv line)
    (:margin-block-end :to :margin-bottom-height :conv line)
    (:margin-left :to :margin-left-pixel :conv pixel)
    (:margin-inline-start :to :margin-left-pixel :conv pixel)
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
