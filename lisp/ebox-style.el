;;; ebox-style.el --- CSS-like style model for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns style property registration, shorthand expansion, computed style, and
;; dirty-effect classification.  It does not own Emacs buffer text properties.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ecss)
(require 'tp)
(require 'ebox-source)
(require 'ebox-selector-view)
(require 'ebox-layout-config)
(require 'ebox-size)

(defvar ebox--longhand)
(declare-function ebox-selector-parse "ebox-selector" (selector))
(declare-function ebox-node-factory--create-from-properties
                  "ebox-node-factory" (&rest plist))
(declare-function ebox--flex-normalize-container-props
                  "ebox-flex" (props))
(declare-function ebox-grid--normalize-config-props
                  "ebox-grid" (props))
(declare-function ecss-stylesheet-create "ecss" ())

(defun ebox-style--create-stylesheet ()
  "Return one private ECSS stylesheet for Ebox style state."
  (ecss-stylesheet-create))

(defconst ebox-style--border-styles
  '(none solid)
  "Valid CSS border-style keywords accepted by Ebox style parsing.")

(defconst ebox-style--default-foreground 'ebox/default-foreground
  "Internal paint consequence that blocks an inherited foreground.")

(defconst ebox-style--property-definitions
  '((:name :color :id ebox/color :initial nil :inherits t
     :contexts (text box) :group paint :dirty-kind paint :signature paint
     :normalizer color :validator color
     :engine-projection (:to :color :conv color))
    (:name :background-color :id ebox/background-color :aliases (:bgcolor)
     :initial nil :contexts (text box) :group paint :dirty-kind paint
     :signature paint :normalizer color :validator color
     :engine-projection (:to :bgcolor :conv color))
    (:name :font-family :id ebox/font-family :initial nil :inherits t
     :contexts (text box) :group typography :dirty-kind geometry :signature layout
     :validator font-family)
    (:name :font-size :id ebox/font-size
     :initial nil :inherits t :contexts (text box) :group typography
     :dirty-kind geometry :signature layout :validator font-size)
    (:name :font-weight :id ebox/font-weight :initial normal :inherits t
     :contexts (text box) :group typography :dirty-kind geometry :signature layout
     :validator font-weight)
    (:name :font-style :id ebox/font-style :aliases (:font-slant)
     :initial normal :inherits t
     :contexts (text box) :group typography :dirty-kind geometry :signature layout
     :validator font-style)
    (:name :text-decoration-line :id ebox/text-decoration-line :initial none
     :contexts (text box) :group paint :dirty-kind paint :signature paint
     :validator text-decoration-line)
    (:name :text-decoration-color :id ebox/text-decoration-color
     :initial currentColor :contexts (text box) :group paint :dirty-kind paint
     :signature paint :normalizer color :validator color
     :engine-projection (:to :text-decoration-color :conv color))
    (:name :text-decoration-style :id ebox/text-decoration-style :initial solid
     :contexts (text box) :group paint :dirty-kind paint :signature paint
     :validator text-decoration-style)
    (:name :box-sizing :id ebox/box-sizing :initial border-box
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout)
    (:name :position :id ebox/position :initial static
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator position
     :runtime-default t)
    (:name :left :id ebox/left :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator signed-size :runtime-default t)
    (:name :top :id ebox/top :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator signed-size :runtime-default t)
    (:name :z-index :id ebox/z-index :initial 0
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator integer
     :runtime-default t)
    (:name :layer :id ebox/layer :initial local
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator layer
     :runtime-default t)
    (:name :anchor :id ebox/anchor :initial nil
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator anchor
     :runtime-default t)
    (:name :placement :id ebox/placement :initial bottom-start
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout :validator placement
     :runtime-default t)
    (:name :width :id ebox/width :initial auto
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator horizontal-size
     :engine-projection (:to :width :conv preferred-size))
    (:name :min-width :id ebox/min-width :initial auto
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator min-horizontal-size
     :engine-projection (:to :min-width :conv min-size))
    (:name :max-width :id ebox/max-width :initial none
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator max-horizontal-size
     :engine-projection (:to :max-width :conv max-size))
    (:name :height :id ebox/height :initial auto
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator vertical-size)
    (:name :min-height :id ebox/min-height :initial auto
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator min-vertical-size)
    (:name :max-height :id ebox/max-height :initial none
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator max-vertical-size)
    (:name :padding-top :id ebox/padding-top :initial (lh 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size
     :engine-projection (:to :padding-top-height :conv line))
    (:name :padding-right :id ebox/padding-right :initial (px 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size
     :engine-projection (:to :padding-right-pixel :conv pixel))
    (:name :padding-bottom :id ebox/padding-bottom :initial (lh 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size
     :engine-projection (:to :padding-bottom-height :conv line))
    (:name :padding-left :id ebox/padding-left :initial (px 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size
     :engine-projection (:to :padding-left-pixel :conv pixel))
    (:name :padding-block-start :id ebox/padding-block-start :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size
     :engine-projection (:to :padding-top-height :conv line))
    (:name :padding-inline-end :id ebox/padding-inline-end :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size
     :engine-projection (:to :padding-right-pixel :conv pixel))
    (:name :padding-block-end :id ebox/padding-block-end :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size
     :engine-projection (:to :padding-bottom-height :conv line))
    (:name :padding-inline-start :id ebox/padding-inline-start :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size
     :engine-projection (:to :padding-left-pixel :conv pixel))
    (:name :margin-top :id ebox/margin-top :initial (lh 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size
     :engine-projection (:to :margin-top-height :conv line))
    (:name :margin-right :id ebox/margin-right :initial (px 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size
     :engine-projection (:to :margin-right-pixel :conv pixel))
    (:name :margin-bottom :id ebox/margin-bottom :initial (lh 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size
     :engine-projection (:to :margin-bottom-height :conv line))
    (:name :margin-left :id ebox/margin-left :initial (px 0)
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size
     :engine-projection (:to :margin-left-pixel :conv pixel))
    (:name :margin-block-start :id ebox/margin-block-start :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size
     :engine-projection (:to :margin-top-height :conv line))
    (:name :margin-inline-end :id ebox/margin-inline-end :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size
     :engine-projection (:to :margin-right-pixel :conv pixel))
    (:name :margin-block-end :id ebox/margin-block-end :initial (lh 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size
     :engine-projection (:to :margin-bottom-height :conv line))
    (:name :margin-inline-start :id ebox/margin-inline-start :initial (px 0)
     :contexts (box row column flex grid) :group geometry
     :dirty-kind geometry :signature layout
     :size-axis inline :validator nonnegative-size
     :engine-projection (:to :margin-left-pixel :conv pixel))
    (:name :border-top-width :id ebox/border-top-width
     :initial (px 0) :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis stroke :validator border-width
     :engine-projection (:to :border-top-pixel :conv border-pixel))
    (:name :border-right-width :id ebox/border-right-width
     :initial (px 0) :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis stroke :validator border-width
     :engine-projection (:to :border-right-pixel :conv border-pixel))
    (:name :border-bottom-width :id ebox/border-bottom-width
     :initial (px 0) :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis stroke :validator border-width
     :engine-projection (:to :border-bottom-pixel :conv border-pixel))
    (:name :border-left-width :id ebox/border-left-width
     :initial (px 0) :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis stroke :validator border-width
     :engine-projection (:to :border-left-pixel :conv border-pixel))
    (:name :border-top-style :id ebox/border-top-style :initial none
     :contexts (box row column flex grid) :group structure
     :dirty-kind structure :signature layout :validator border-style)
    (:name :border-right-style :id ebox/border-right-style :initial none
     :contexts (box row column flex grid) :group structure
     :dirty-kind structure :signature layout :validator border-style)
    (:name :border-bottom-style :id ebox/border-bottom-style :initial none
     :contexts (box row column flex grid) :group structure
     :dirty-kind structure :signature layout :validator border-style)
    (:name :border-left-style :id ebox/border-left-style :initial none
     :contexts (box row column flex grid) :group structure
     :dirty-kind structure :signature layout :validator border-style)
    (:name :border-top-color :id ebox/border-top-color :initial currentColor
     :contexts (box row column flex grid) :group paint
     :dirty-kind paint :signature paint
     :normalizer color :validator color
     :engine-projection (:to :border-top-color :conv color))
    (:name :border-right-color :id ebox/border-right-color :initial currentColor
     :contexts (box row column flex grid) :group paint
     :dirty-kind paint :signature paint
     :normalizer color :validator color
     :engine-projection (:to :border-right-color :conv color))
    (:name :border-bottom-color :id ebox/border-bottom-color
     :initial currentColor :contexts (box row column flex grid)
     :group paint :dirty-kind paint :signature paint
     :normalizer color :validator color
     :engine-projection (:to :border-bottom-color :conv color))
    (:name :border-left-color :id ebox/border-left-color :initial currentColor
     :contexts (box row column flex grid) :group paint
     :dirty-kind paint :signature paint
     :normalizer color :validator color
     :engine-projection (:to :border-left-color :conv color))
    (:name :text-align :id ebox/text-align :initial left :inherits t
     :contexts (box)
     :author-contexts (box)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :overflow :id ebox/overflow :initial scroll
     :contexts (box row column flex grid) :group structure
     :dirty-kind geometry :signature layout
     :impacts (geometry paint) :projections (layout paint))
    (:name :wrap-mode :id ebox/wrap-mode :initial word :inherits t
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :validator wrap-mode)
    (:name :visibility :id ebox/visibility :initial visible :inherits t
     :contexts (box row column flex grid)
     :group paint :dirty-kind paint :signature paint)
    (:name :outer :id ebox/outer :initial block
     :contexts (box row column flex grid)
     :group structure :dirty-kind structure :signature structure
     :validator outer :impacts (structure geometry)
     :projections (structure layout)
     :engine-projection (:to nil))
    (:name :item-gap :id ebox/item-gap :initial (px 0) :contexts (row column)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis main :validator nonnegative-size)
    (:name :cross-align :id ebox/cross-align :initial stretch
     :contexts (row column) :group geometry :dirty-kind geometry
     :signature layout :validator cross-align)
    (:name :flex-direction :id ebox/flex-direction :initial row
     :contexts (flex) :group geometry :dirty-kind geometry :signature layout
     :validator flex-direction)
    (:name :flex-wrap :id ebox/flex-wrap :initial nowrap :contexts (flex)
     :group geometry :dirty-kind geometry :signature layout
     :validator flex-wrap)
    (:name :justify-content :id ebox/justify-content :initial flex-start
     :contexts (flex grid) :group geometry :dirty-kind geometry
     :signature layout :validator justify-content)
    (:name :align-items :id ebox/align-items :initial stretch
     :contexts (flex grid) :group geometry :dirty-kind geometry
     :signature layout :validator align-items)
    (:name :align-content :id ebox/align-content :initial stretch
     :contexts (flex grid) :group geometry :dirty-kind geometry
     :signature layout :validator align-content)
    (:name :justify-items :id ebox/justify-items :initial stretch
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :validator justify-items)
    (:name :row-gap :id ebox/row-gap :initial (lh 0)
     :contexts (flex grid) :group geometry :dirty-kind geometry :signature layout
     :size-axis block :validator nonnegative-size)
    (:name :column-gap :id ebox/column-gap
     :initial (px 0) :contexts (flex grid) :group geometry :dirty-kind geometry
     :signature layout :size-axis inline :validator nonnegative-size)
    (:name :order :id ebox/order :initial 0 :contexts (item)
     :group geometry :dirty-kind geometry :signature layout :validator order)
    (:name :flex-grow :id ebox/flex-grow :initial 0 :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator flex-factor)
    (:name :flex-shrink :id ebox/flex-shrink :initial 1 :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator flex-factor)
    (:name :flex-basis :id ebox/flex-basis :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :size-axis length :validator preferred-size)
    (:name :align-self :id ebox/align-self :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator align-self)
    (:name :justify-self :id ebox/justify-self :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator justify-self)
    (:name :grid-template-columns :id ebox/grid-template-columns :initial nil
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :size-grammar tracks :size-axis inline :validator grid-track-list)
    (:name :grid-template-rows :id ebox/grid-template-rows :initial nil
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :size-grammar tracks :size-axis block :validator grid-track-list)
    (:name :grid-auto-columns :id ebox/grid-auto-columns :initial auto
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :size-grammar tracks :size-axis inline :validator grid-track)
    (:name :grid-auto-rows :id ebox/grid-auto-rows :initial auto
     :contexts (grid) :group geometry :dirty-kind geometry :signature layout
     :size-grammar tracks :size-axis block :validator grid-track)
    (:name :grid-auto-flow :id ebox/grid-auto-flow :initial row
     :contexts (grid) :group structure :dirty-kind structure :signature layout
     :validator grid-auto-flow)
    (:name :grid-column :id ebox/grid-column :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator grid-placement)
    (:name :grid-row :id ebox/grid-row :initial auto :contexts (item)
     :group geometry :dirty-kind geometry :signature layout
     :validator grid-placement)
    (:name :grid-column-span :id ebox/grid-column-span
     :shorthand grid-column-span :validator positive-integer
     :contexts (item) :group geometry :dirty-kind geometry :signature layout)
    (:name :grid-row-span :id ebox/grid-row-span
     :shorthand grid-row-span :validator positive-integer
     :contexts (item) :group geometry :dirty-kind geometry :signature layout)
    (:name :padding :id ebox/padding :shorthand padding
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :engine-projection
     (:expand (:padding-top :padding-right :padding-bottom :padding-left)
      :mode trbl))
    (:name :padding-inline :id ebox/padding-inline :shorthand padding-inline
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :engine-projection (:expand (:padding-left :padding-right) :mode pair))
    (:name :padding-block :id ebox/padding-block :shorthand padding-block
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :engine-projection (:expand (:padding-top :padding-bottom) :mode pair))
    (:name :margin :id ebox/margin :shorthand margin
     :contexts (box row column flex grid)
     :impacts (geometry) :projections (layout)
     :engine-projection
     (:expand (:margin-top :margin-right :margin-bottom :margin-left)
      :mode trbl))
    (:name :margin-inline :id ebox/margin-inline :shorthand margin-inline
     :contexts (box row column flex grid)
     :impacts (geometry) :projections (layout)
     :engine-projection (:expand (:margin-left :margin-right) :mode pair))
    (:name :margin-block :id ebox/margin-block :shorthand margin-block
     :contexts (box row column flex grid)
     :impacts (geometry) :projections (layout)
     :engine-projection (:expand (:margin-top :margin-bottom) :mode pair))
    (:name :border :id ebox/border :shorthand border
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :engine-projection
     (:expand (:border-top :border-right :border-bottom :border-left)
      :mode same))
    (:name :border-top :id ebox/border-top :shorthand border-top
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :engine-projection
     (:expand (:border-top-width :border-top-style :border-top-color)
      :mode wsc))
    (:name :border-right :id ebox/border-right :shorthand border-right
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :engine-projection
     (:expand (:border-right-width :border-right-style :border-right-color)
      :mode wsc))
    (:name :border-bottom :id ebox/border-bottom :shorthand border-bottom
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :engine-projection
     (:expand (:border-bottom-width :border-bottom-style :border-bottom-color)
      :mode wsc))
    (:name :border-left :id ebox/border-left :shorthand border-left
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :engine-projection
     (:expand (:border-left-width :border-left-style :border-left-color)
      :mode wsc))
    (:name :border-top-p :id ebox/border-top-p
     :shorthand border-top-present :validator boolean
     :contexts (box row column flex grid)
     :impacts (geometry paint) :projections (layout paint)
     :group structure :dirty-kind structure :signature layout)
    (:name :border-width :id ebox/border-width :shorthand border-width
     :contexts (box row column flex grid)
     :group geometry :dirty-kind geometry :signature layout
     :engine-projection
     (:expand (:border-top-width :border-right-width
               :border-bottom-width :border-left-width)
      :mode trbl))
    (:name :border-style :id ebox/border-style :shorthand border-style
     :contexts (box row column flex grid)
     :group structure :dirty-kind structure :signature layout
     :engine-projection
     (:expand (:border-top-style :border-right-style
               :border-bottom-style :border-left-style)
      :mode trbl))
    (:name :border-color :id ebox/border-color :shorthand border-color
     :contexts (box row column flex grid)
     :group paint :dirty-kind paint :signature paint
     :engine-projection
     (:expand (:border-top-color :border-right-color
               :border-bottom-color :border-left-color)
      :mode trbl))
    (:name :gap :id ebox/gap :shorthand gap
     :contexts (flex grid)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :flex-flow :id ebox/flex-flow :shorthand flex-flow
     :contexts (flex)
     :group geometry :dirty-kind geometry :signature layout)
    (:name :flex :id ebox/flex :shorthand flex
     :contexts (item)
     :group geometry :dirty-kind geometry :signature layout))
  "Canonical Ebox property schemas and public aliases.")

(defconst ebox-style--internal-engine-projection-rules
  '((:display :to nil))
  "Projection rules for engine-only fields outside the public schema.")

(defconst ebox-style--engine-projection-modes '(trbl pair wsc same)
  "Closed set of shorthand split modes used by engine projection.")

(defconst ebox-style--engine-projection-converters
  '(pixel size-pixel border-pixel preferred-size min-size max-size line color)
  "Closed set of value converters used by engine projection.")

(define-error 'ebox-style-schema-error "Invalid Ebox style schema")

(defun ebox-style--definition-for-name (name &optional definitions)
  "Return NAME's canonical entry from DEFINITIONS or the package definitions."
  (cl-find-if
   (lambda (property)
     (or (eq name (plist-get property :name))
         (eq name (plist-get property :id))
         (memq name (plist-get property :aliases))))
   (or definitions ebox-style--property-definitions)))

(defun ebox-style--definition-engine-targets
    (property &optional definitions stack)
  "Return private engine targets derived from PROPERTY in DEFINITIONS."
  (let* ((definitions (or definitions ebox-style--property-definitions))
         (name (plist-get property :name))
         (rule (plist-get property :engine-projection)))
    (when (memq name stack)
      (signal 'ebox-style-schema-error
              (list :engine-projection-cycle (reverse (cons name stack)))))
    (cond
     ((null rule) (list name))
     ((plist-get rule :expand)
      (delete-dups
       (cl-mapcan
        (lambda (target)
          (let ((definition
                 (ebox-style--definition-for-name target definitions)))
            (unless definition
              (signal 'ebox-style-schema-error
                      (list :unknown-engine-target target :property name)))
            (ebox-style--definition-engine-targets
             definition definitions (cons name stack))))
        (plist-get rule :expand))))
     ((plist-member rule :to)
      (when-let* ((target (plist-get rule :to))) (list target)))
     (t (list name)))))

(defun ebox-style--validate-engine-projection-definitions (definitions)
  "Validate engine projection metadata in DEFINITIONS and return t."
  (let ((lookup-keys (make-hash-table :test #'eq)))
    (dolist (property definitions)
      (let ((name (plist-get property :name))
            (id (plist-get property :id))
            (rule (plist-get property :engine-projection)))
        (unless (and (keywordp name) (symbolp id))
          (signal 'ebox-style-schema-error
                  (list :malformed-property-identity property)))
        (dolist (entry
                 (append (list (cons name :name) (cons id :id))
                         (mapcar (lambda (alias) (cons alias :alias))
                                 (plist-get property :aliases))))
          (unless (symbolp (car entry))
            (signal 'ebox-style-schema-error
                    (list :malformed-lookup-key entry :property name)))
          (when-let* ((existing (gethash (car entry) lookup-keys)))
            (signal 'ebox-style-schema-error
                    (list :lookup-key-collision (car entry)
                          :existing existing
                          :incoming (list :property name :role (cdr entry)))))
          (puthash (car entry)
                   (list :property name :role (cdr entry))
                   lookup-keys))
        (when rule
          (unless (proper-list-p rule)
            (signal 'ebox-style-schema-error
                    (list :malformed-engine-rule name rule)))
          (let ((expand (plist-get rule :expand))
                (to-present (plist-member rule :to))
                (converter (plist-get rule :conv)))
            (when (eq (not (null expand)) (not (null to-present)))
              (signal 'ebox-style-schema-error
                      (list :ambiguous-engine-rule name rule)))
            (when expand
              (unless (and (proper-list-p expand) expand
                           (memq (plist-get rule :mode)
                                 ebox-style--engine-projection-modes))
                (signal 'ebox-style-schema-error
                        (list :malformed-engine-expansion name rule))))
            (when (and to-present
                       (plist-get rule :to)
                       (not (keywordp (plist-get rule :to))))
              (signal 'ebox-style-schema-error
                      (list :malformed-engine-target name rule)))
            (when (and converter
                       (not (memq converter
                                  ebox-style--engine-projection-converters)))
              (signal 'ebox-style-schema-error
                      (list :unknown-engine-converter name converter))))))
      (ebox-style--definition-engine-targets property definitions))
    (dolist (entry ebox-style--internal-engine-projection-rules)
      (when (ebox-style--definition-for-name (car entry) definitions)
        (signal 'ebox-style-schema-error
                (list :public-rule-in-internal-table (car entry)))))
    t))

(defconst ebox-style--engine-projection-schema-valid-p
  (ebox-style--validate-engine-projection-definitions
   ebox-style--property-definitions)
  "Non-nil after the package engine projection schema validates.")

(defvar ebox-style-schemas)
(defvar ebox-style--property-index)

(defconst ebox-style--declaration-cache-max-entries 512
  "Maximum canonical declaration compilations retained by Ebox.")

(defvar ebox-style--declaration-cache
  (make-hash-table :test 'equal)
  "Bounded memo table for canonical Ebox declaration compilation.")

(defun ebox-style--property (name)
  "Return registry-owned style metadata for internal NAME lookup."
  (gethash name ebox-style--property-index))

(defun ebox-style-property (name)
  "Return detached style metadata for canonical property or alias NAME."
  (ecss-schema-set-property-metadata ebox-style-schemas name))

(defun ebox-style-canonical-name (name)
  "Return canonical CSS-like longhand property name for NAME."
  (when-let* ((property (ebox-style--property name)))
    (plist-get property :name)))

(defun ebox-style-property-accepted-p (tag name)
  "Return non-nil when author form TAG accepts property NAME."
  (when-let* ((property (ebox-style--property name)))
    (ebox-style--form-property-allowed-p tag property)))

(defun ebox-style-schema-id (name)
  "Return namespaced ECSS schema id for Ebox property NAME."
  (when-let* ((property (ebox-style--property name)))
    (plist-get property :id)))

(defun ebox-style--put (plist key value)
  "Return PLIST with KEY set to VALUE."
  (plist-put plist key value))

(defun ebox-style--atomic-size-form-p (value)
  "Return non-nil when VALUE denotes one size expression before validation.
Keep malformed unit and function forms intact so their target property reports
the invalid value and its allowed units instead of a shorthand arity error."
  (and (consp value)
       (memq (car value) '(px ch vw lh vh % calc min max clamp))))

(defun ebox-style--split-trbl (value)
  "Split VALUE using CSS TRBL rules into top, right, bottom, left."
  (cond
   ((null value) (list nil nil nil nil))
   ((ebox-style--atomic-size-form-p value) (make-list 4 value))
   ((atom value) (list value value value value))
   ((and (listp value) (keywordp (car value)))
    (list (plist-get value :top) (plist-get value :right)
          (plist-get value :bottom) (plist-get value :left)))
   ((listp value)
    (pcase (length value)
      (1 (list (nth 0 value) (nth 0 value) (nth 0 value) (nth 0 value)))
      (2 (list (nth 0 value) (nth 1 value) (nth 0 value) (nth 1 value)))
      (3 (list (nth 0 value) (nth 1 value) (nth 2 value) (nth 1 value)))
      (4 (list (nth 0 value) (nth 1 value) (nth 2 value) (nth 3 value)))
      (_ (error "Ebox four-side shorthand requires one to four values: %S"
                value))))
   (t (list value value value value))))

(defun ebox-style--split-pair (value)
  "Split VALUE into a start/end pair."
  (cond
   ((null value) (list nil nil))
   ((ebox-style--atomic-size-form-p value) (list value value))
   ((atom value) (list value value))
   ((listp value)
    (pcase (length value)
      (1 (list (nth 0 value) (nth 0 value)))
      (2 (list (nth 0 value) (nth 1 value)))
      (_ (error "Ebox pair shorthand requires one or two values: %S" value))))
   (t (list value value))))

(defun ebox-style--wsc-classify (item)
  "Classify border shorthand ITEM as width, style, or color."
  (cond
   ((ebox-style--atomic-size-form-p item) (cons 'width item))
   ((memq item ebox-style--border-styles) (cons 'style item))
   ((or (stringp item) (tp-paint-slot-p item)) (cons 'color item))
   (t (error "Invalid Ebox border component: %S" item))))

(defun ebox-style--split-wsc (value)
  "Split VALUE into border width, style, and color."
  (cond
   ((null value) (list nil nil nil))
   ((ebox-style--atomic-size-form-p value) (list value 'solid nil))
   ((atom value)
    (let ((classified (ebox-style--wsc-classify value)))
      (pcase (car classified)
        ('width (list (cdr classified) nil nil))
        ('style (list '(px 1) (cdr classified) nil))
        ('color (list '(px 1) 'solid (cdr classified))))))
   ((proper-list-p value)
    (let (width style color width-p style-p color-p)
      (dolist (item value)
        (let ((classified (ebox-style--wsc-classify item)))
          (pcase (car classified)
            ('width
             (when width-p (error "Duplicate Ebox border width in %S" value))
             (setq width-p t width (cdr classified)))
            ('style
             (when style-p (error "Duplicate Ebox border style in %S" value))
             (setq style-p t style (cdr classified)))
            ('color
             (when color-p (error "Duplicate Ebox border color in %S" value))
             (setq color-p t color (cdr classified))))))
      (list (or width '(px 1)) (or style 'solid) color)))
   (t (error "Ebox border must be a color or proper component list: %S"
             value))))

(defun ebox-style--atom-consp (list)
  "Return non-nil when LIST is a strict dotted pair of atoms."
  (and (consp list)
       (atom (car list))
       (cdr list)
       (atom (cdr list))))

(defun ebox-style--parse-color (color)
  "Return a detached canonical COLOR value without consulting a frame."
  (if (stringp color) (copy-sequence color) color))

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

(defun ebox-style--border-present-declarations (side value)
  "Return canonical boolean border declarations for SIDE and VALUE."
  (unless (memq value '(nil t))
    (error "Ebox border-%s-p must be boolean: %S" side value))
  (list (intern (format "ebox/border-%s-width" side))
        (list 'px (if value 1 0))
        (intern (format "ebox/border-%s-style" side))
        (if value 'solid 'none)))

(defun ebox-style--border-top-present-shorthand (value)
  "Expand boolean top-border VALUE to canonical width and style."
  (ebox-style--border-present-declarations 'top value))

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

(defun ebox-style--grid-column-span-shorthand (value)
  "Expand Grid column span VALUE into canonical auto placement."
  (unless (and (integerp value) (> value 0))
    (error "Ebox grid-column-span must be a positive integer: %S" value))
  (list 'ebox/grid-column (list :span value)))

(defun ebox-style--grid-row-span-shorthand (value)
  "Expand Grid row span VALUE into canonical auto placement."
  (unless (and (integerp value) (> value 0))
    (error "Ebox grid-row-span must be a positive integer: %S" value))
  (list 'ebox/grid-row (list :span value)))

(defun ebox-style--flex-flow-shorthand (value)
  "Expand flex-flow VALUE to direction and wrapping longhands."
  (unless (and (proper-list-p value) (= (length value) 2))
    (error "Ebox flex-flow requires one direction and one wrap value: %S"
           value))
  (let ((values value) direction wrap)
    (setq direction
          (cl-find-if (lambda (item)
                        (memq item '(row row-reverse column column-reverse)))
                      values)
          wrap (cl-find-if (lambda (item)
                             (memq item '(nowrap wrap wrap-reverse)))
                           values))
    (unless (and direction wrap)
      (error "Ebox flex-flow requires one direction and one wrap value: %S"
             value))
    (list 'ebox/flex-direction direction 'ebox/flex-wrap wrap)))

(defun ebox-style--flex-shorthand (value)
  "Expand flex item VALUE to grow, shrink, and basis longhands."
  (pcase value
    ((and (pred numberp) (guard (>= value 0)))
     (list 'ebox/flex-grow value 'ebox/flex-shrink 1
           'ebox/flex-basis '(% 0)))
    ('none '(ebox/flex-grow 0 ebox/flex-shrink 0 ebox/flex-basis auto))
    ('auto '(ebox/flex-grow 1 ebox/flex-shrink 1 ebox/flex-basis auto))
    ('initial '(ebox/flex-grow 0 ebox/flex-shrink 1 ebox/flex-basis auto))
    ((and (pred proper-list-p) (guard (= (length value) 3)))
     (list 'ebox/flex-grow (nth 0 value)
           'ebox/flex-shrink (nth 1 value)
           'ebox/flex-basis (nth 2 value)))
    (_ (error "Ebox flex requires none, auto, initial, a factor, or (grow shrink basis): %S"
              value))))

(defun ebox-style--normalizer (name)
  "Return schema normalizer named NAME."
  (pcase name
    ('color #'ebox-style--parse-color)
    (_ #'identity)))

(defun ebox-style--negative-numeric-size-p (value)
  "Return non-nil when VALUE is or starts with a negative number."
  (or (and (numberp value) (< value 0))
      (and (consp value)
           (numberp (car value))
           (< (car value) 0))))

(defun ebox-style--nonnegative-size-p (value)
  "Return non-nil when VALUE is a canonical nonnegative length-percentage."
  (ebox-size-value-p value nil t))

(defconst ebox-style--preferred-size-keywords
  '(auto min-content max-content fit-content stretch)
  "CSS preferred and minimum size keywords in the supported subset.")

(defconst ebox-style--maximum-size-keywords
  '(none min-content max-content fit-content stretch)
  "CSS maximum size keywords in the supported subset.")

(defun ebox-style--horizontal-size-p (value)
  "Return non-nil when VALUE is a canonical horizontal size."
  (or (memq value ebox-style--preferred-size-keywords)
      (ebox-size-value-for-axis-p value 'inline)))

(defun ebox-style--preferred-size-p (value)
  "Return non-nil when VALUE is a size whose parent axis is not known yet."
  (or (memq value ebox-style--preferred-size-keywords)
      (ebox-style--nonnegative-size-p value)))

(defun ebox-style--min-horizontal-size-p (value)
  "Return non-nil when VALUE is a canonical minimum horizontal size."
  (ebox-style--horizontal-size-p value))

(defun ebox-style--max-horizontal-size-p (value)
  "Return non-nil when VALUE is a canonical maximum horizontal size."
  (or (memq value ebox-style--maximum-size-keywords)
      (ebox-size-value-for-axis-p value 'inline)))

(defun ebox-style--vertical-size-p (value)
  "Return non-nil when VALUE is a canonical vertical size."
  (or (memq value ebox-style--preferred-size-keywords)
      (ebox-size-value-for-axis-p value 'block)))

(defun ebox-style--min-vertical-size-p (value)
  "Return non-nil when VALUE is a canonical minimum vertical size."
  (ebox-style--vertical-size-p value))

(defun ebox-style--max-vertical-size-p (value)
  "Return non-nil when VALUE is a canonical maximum vertical size."
  (or (memq value ebox-style--maximum-size-keywords)
      (ebox-size-value-for-axis-p value 'block)))

(defun ebox-style--nonnegative-number-p (value)
  "Return non-nil when VALUE is nil or a non-negative number."
  (or (null value) (and (numberp value) (>= value 0))))

(defun ebox-style--positive-integer-p (value)
  "Return non-nil when VALUE is nil or a positive integer."
  (or (null value) (and (integerp value) (> value 0))))

(defun ebox-style--grid-placement-p (value)
  "Return non-nil when VALUE is a valid public Grid placement."
  (or (null value)
      (eq value 'auto)
      (and (integerp value) (> value 0))
      (and (proper-list-p value)
           (pcase value
             (`(,start)
              (and (integerp start) (> start 0)))
             (`(,start :span ,span)
              (and (integerp start) (> start 0)
                   (integerp span) (> span 0)))
             (`(:span ,span)
              (and (integerp span) (> span 0)))
             (`(,start ,end)
              (and (integerp start) (> start 0)
                   (integerp end) (> end start)))))))

(defun ebox-style--outer-p (value)
  "Return non-nil when VALUE is an Ebox outer participation value."
  (memq value '(inline block)))

(defun ebox-style--signed-size-p (value &optional axis)
  "Return non-nil when VALUE is a signed typed length in size AXIS.
Leave fractional and contextual lengths unresolved until used placement."
  (and (ebox-size-value-p value t)
       (let ((units (cdr (assq (or axis 'length) ebox-size-axis-units))))
         (cl-labels ((valid-p (expression)
                       (or (atom expression)
                           (if (memq (car expression) '(px ch vw lh vh %))
                               (memq (car expression) units)
                             (cl-every #'valid-p (cdr expression))))))
           (valid-p value)))))

(defun ebox-style--position-p (value)
  "Return non-nil when VALUE is a supported positioning mode."
  (memq value '(static relative absolute)))

(defun ebox-style--layer-p (value)
  "Return non-nil when VALUE is a supported layer paint target."
  (memq value '(local root)))

(defun ebox-style--anchor-p (value)
  "Return non-nil when VALUE is nil or a semantic symbol or string id."
  (or (symbolp value) (stringp value)))

(defun ebox-style--placement-p (value)
  "Return non-nil when VALUE is a supported anchor placement."
  (memq value '(bottom-start bottom-end top-start top-end)))

(defun ebox-style--font-family-p (value)
  "Return non-nil when VALUE is an Ebox font family."
  (or (null value)
      (and (stringp value) (not (string-empty-p value)))
      (symbolp value)))

(defun ebox-style--color-p (value)
  "Return non-nil when VALUE is a canonical or deferred color fact."
  (or (null value) (stringp value) (eq value 'currentColor)
      (tp-paint-slot-p value)))

(defun ebox-style--font-size-p (value)
  "Return non-nil when VALUE is a positive CSS reference-pixel size."
  (or (null value) (and (numberp value) (> value 0))))

(defun ebox-style--font-weight-p (value)
  "Return non-nil when VALUE is a canonical CSS font weight."
  (or (null value)
      (memq value '(normal bold bolder lighter
                    100 200 300 400 500 600 700 800 900))))

(defun ebox-style--font-style-p (value)
  "Return non-nil when VALUE is a canonical CSS font style."
  (or (null value) (memq value '(normal italic oblique))))

(defun ebox-style--border-width-p (value)
  "Return non-nil when VALUE is a nonnegative length without percentages."
  (ebox-size-value-p value nil nil))

(defun ebox-style--border-style-p (value)
  "Return non-nil when VALUE is a supported canonical border style."
  (memq value '(none solid)))

(defun ebox-style--text-decoration-line-p (value)
  "Return non-nil when VALUE is a canonical text-decoration line set."
  (let ((values (if (listp value) value (list value))))
    (or (equal values '(none))
        (and values
             (cl-every (lambda (item)
                         (memq item '(underline overline line-through)))
                       values)
             (= (length values)
                (length (delete-dups (copy-sequence values))))))))

(defun ebox-style--text-decoration-style-p (value)
  "Return non-nil when VALUE is a canonical text-decoration style."
  (memq value '(solid double dotted dashed wavy)))

(defun ebox-style--nonnegative-integer-p (value)
  "Return non-nil when VALUE is a nonnegative integer."
  (and (integerp value) (>= value 0)))

(defun ebox-style--cross-align-p (value)
  "Return non-nil when VALUE is a Row/Column cross alignment."
  (memq value '(start center end stretch)))

(defun ebox-style--flex-direction-p (value)
  "Return non-nil when VALUE is a canonical Flex direction."
  (memq value '(row row-reverse column column-reverse)))

(defun ebox-style--flex-wrap-p (value)
  "Return non-nil when VALUE is a canonical Flex wrapping mode."
  (memq value '(nowrap wrap wrap-reverse)))

(defun ebox-style--justify-content-p (value)
  "Return non-nil when VALUE is a canonical content justification."
  (memq value '(normal start end flex-start flex-end center stretch
                space-between space-around space-evenly)))

(defun ebox-style--align-items-p (value)
  "Return non-nil when VALUE is a canonical item alignment."
  (memq value '(normal start end stretch flex-start flex-end center baseline)))

(defun ebox-style--align-content-p (value)
  "Return non-nil when VALUE is a canonical multi-line alignment."
  (memq value '(normal start end stretch flex-start flex-end center
                space-between space-around space-evenly)))

(defun ebox-style--justify-items-p (value)
  "Return non-nil when VALUE is a canonical Grid item justification."
  (memq value '(stretch start end center)))

(defun ebox-style--align-self-p (value)
  "Return non-nil when VALUE is a canonical parent-relative alignment."
  (memq value '(auto normal start end stretch flex-start flex-end
                center baseline)))

(defun ebox-style--grid-auto-flow-p (value)
  "Return non-nil when VALUE is a canonical Grid auto-flow axis."
  (memq value '(row column)))

(defun ebox-style--grid-fixed-track-p (value)
  "Return non-nil when VALUE is a nonnegative Grid track size expression."
  (ebox-style--nonnegative-size-p value))

(defun ebox-style--grid-fr-track-p (value)
  "Return non-nil when VALUE is one positive fractional Grid track."
  (and (proper-list-p value) (= (length value) 2)
       (eq (car value) 'fr)
       (numberp (cadr value)) (> (cadr value) 0)))

(defun ebox-style--grid-track-p (value &optional allow-repeat)
  "Return non-nil when VALUE is one Grid track.
ALLOW-REPEAT permits a top-level repeat expression."
  (cond
   ((memq value '(auto min-content max-content)) t)
   ((ebox-style--grid-fixed-track-p value) t)
   ((ebox-style--grid-fr-track-p value) t)
   ((and (proper-list-p value) (= (length value) 3)
         (eq (car value) 'minmax))
    (let ((minimum (cadr value)) (maximum (caddr value)))
      (and (not (and (consp minimum)
                     (memq (car minimum) '(minmax repeat))))
           (not (and (consp maximum)
                     (memq (car maximum) '(minmax repeat))))
           (ebox-style--grid-track-p minimum nil)
           (not (ebox-style--grid-fr-track-p minimum))
           (ebox-style--grid-track-p maximum nil))))
   ((and allow-repeat (proper-list-p value) (= (length value) 3)
         (eq (car value) 'repeat)
         (integerp (cadr value)) (> (cadr value) 0))
    (let ((body (caddr value)))
      (or (ebox-style--grid-track-p body nil)
          (and (proper-list-p body) body
               (cl-every (lambda (track)
                           (ebox-style--grid-track-p track nil))
                         body)))))
   (t nil)))

(defun ebox-style--grid-track-list-p (value)
  "Return non-nil when VALUE is a valid Grid track list."
  (or (null value)
      (and (proper-list-p value) value
           (cl-every (lambda (track)
                       (ebox-style--grid-track-p track t))
                     value))))

(defun ebox-style--grid-auto-track-p (value)
  "Return non-nil when VALUE denotes at most one implicit Grid track."
  (or (null value)
      (ebox-style--grid-track-p value nil)
      (and (proper-list-p value) (= (length value) 1)
           (ebox-style--grid-track-p (car value) nil))))

(defun ebox-style--order-p (value)
  "Return non-nil when VALUE is an integer parent ordering key."
  (integerp value))

(defun ebox-style--justify-self-p (value)
  "Return non-nil when VALUE is a canonical Grid self alignment."
  (memq value '(auto stretch start end center)))

(defun ebox-style--wrap-mode-p (value)
  "Return non-nil when VALUE is a public Box wrapping mode."
  (memq value '(word char kp none)))

(defun ebox-style-no-soft-wrap-p (value)
  "Return non-nil when wrap VALUE disables soft line breaking.
`none' is the canonical author value; nil is retained only for private
generated wrappers that already contain exact line breaks."
  (memq value '(nil none)))

(defun ebox-style-soft-wrap-p (value)
  "Return non-nil when wrap VALUE performs soft line breaking."
  (memq value '(word char kp)))

(defun ebox-style--validator (name)
  "Return schema validator named NAME."
  (pcase name
    ('preferred-size #'ebox-style--preferred-size-p)
    ('horizontal-size #'ebox-style--horizontal-size-p)
    ('min-horizontal-size #'ebox-style--min-horizontal-size-p)
    ('max-horizontal-size #'ebox-style--max-horizontal-size-p)
    ('vertical-size #'ebox-style--vertical-size-p)
    ('min-vertical-size #'ebox-style--min-vertical-size-p)
    ('max-vertical-size #'ebox-style--max-vertical-size-p)
    ('nonnegative-size #'ebox-style--nonnegative-size-p)
    ('nonnegative-number #'ebox-style--nonnegative-number-p)
    ('positive-integer #'ebox-style--positive-integer-p)
    ('grid-placement #'ebox-style--grid-placement-p)
    ('outer #'ebox-style--outer-p)
    ('signed-size #'ebox-style--signed-size-p)
    ('position #'ebox-style--position-p)
    ('integer #'integerp)
    ('layer #'ebox-style--layer-p)
    ('anchor #'ebox-style--anchor-p)
    ('placement #'ebox-style--placement-p)
    ('font-family #'ebox-style--font-family-p)
    ('color #'ebox-style--color-p)
    ('font-size #'ebox-style--font-size-p)
    ('font-weight #'ebox-style--font-weight-p)
    ('font-style #'ebox-style--font-style-p)
    ('border-width #'ebox-style--border-width-p)
    ('border-style #'ebox-style--border-style-p)
    ('text-decoration-line #'ebox-style--text-decoration-line-p)
    ('text-decoration-style #'ebox-style--text-decoration-style-p)
    ('nonnegative-integer #'ebox-style--nonnegative-integer-p)
    ('cross-align #'ebox-style--cross-align-p)
    ('flex-direction #'ebox-style--flex-direction-p)
    ('flex-wrap #'ebox-style--flex-wrap-p)
    ('justify-content #'ebox-style--justify-content-p)
    ('align-items #'ebox-style--align-items-p)
    ('align-content #'ebox-style--align-content-p)
    ('justify-items #'ebox-style--justify-items-p)
    ('align-self #'ebox-style--align-self-p)
    ('grid-auto-flow #'ebox-style--grid-auto-flow-p)
    ('grid-track-list #'ebox-style--grid-track-list-p)
    ('grid-track #'ebox-style--grid-auto-track-p)
    ('order #'ebox-style--order-p)
    ('flex-factor #'ebox-style--nonnegative-number-p)
    ('justify-self #'ebox-style--justify-self-p)
    ('wrap-mode #'ebox-style--wrap-mode-p)
    ('boolean (lambda (value) (memq value '(nil t))))
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
     (border-top-present . ebox-style--border-top-present-shorthand)
     (border-width . ebox-style--border-width-shorthand)
     (border-style . ebox-style--border-style-shorthand)
     (border-color . ebox-style--border-color-shorthand)
     (gap . ebox-style--gap-shorthand)
     (grid-column-span . ebox-style--grid-column-span-shorthand)
     (grid-row-span . ebox-style--grid-row-span-shorthand)
     (flex-flow . ebox-style--flex-flow-shorthand)
     (flex . ebox-style--flex-shorthand))))

(defun ebox-style--size-axis (property &optional tag)
  "Return PROPERTY's size domain for author TAG when known."
  (let ((axis (plist-get property :size-axis)))
    (if (eq axis 'main)
        (pcase tag ('row 'inline) ('column 'block) (_ 'length))
      axis)))

(defun ebox-style--size-value-valid-p (property value &optional tag)
  "Return non-nil when PROPERTY's VALUE respects TAG's size domain.
Grid track wrappers are traversed after their structural validator succeeds."
  (let ((axis (ebox-style--size-axis property tag)))
    (or (null axis)
        (if (eq (plist-get property :size-grammar) 'tracks)
            (cl-labels
                ((valid-p (entry)
                   (cond
                    ((atom entry) t)
                    ((eq (car entry) 'fr) t)
                    ((memq (car entry) '(minmax repeat))
                     (cl-every #'valid-p (cdr entry)))
                    ((ebox-size-value-p entry)
                     (ebox-size-value-for-axis-p entry axis))
                    (t (cl-every #'valid-p entry)))))
              (valid-p value))
          (if (eq (plist-get property :validator) 'signed-size)
              (ebox-style--signed-size-p value axis)
            (or (symbolp value)
                (ebox-size-value-for-axis-p value axis)))))))

(defun ebox-style--schema-validator (property)
  "Return PROPERTY's grammar and unit-domain validator."
  (let ((validator (ebox-style--validator (plist-get property :validator))))
    (if (plist-get property :size-axis)
        (lambda (value)
          (and (funcall validator value)
               (ebox-style--size-value-valid-p property value)))
      validator)))

(defun ebox-style--schema-options (property)
  "Return ECSS registration options for PROPERTY metadata."
  (let ((options (list :initial (plist-get property :initial)
                       :inherits (plist-get property :inherits)
                       :normalizer (ebox-style--normalizer
                                    (plist-get property :normalizer))
                       :validator (ebox-style--schema-validator property)
                       :equality #'equal)))
    (when-let* ((shorthand (ebox-style--shorthand
                           (plist-get property :shorthand))))
      (setq options (plist-put options :shorthand shorthand)))
    options))

(defun ebox-style--schema-impacts (property)
  "Return immutable impact classes for PROPERTY metadata."
  (let ((name (plist-get property :name))
        (group (plist-get property :group)))
    (or (plist-get property :impacts)
        (and (eq group 'typography) '(geometry paint))
        (and (or (string-prefix-p ":padding" (symbol-name name))
                 (and (string-prefix-p ":border" (symbol-name name))
                      (not (string-suffix-p "-color" (symbol-name name)))
                      (not (eq name :border-color))))
             '(geometry paint))
        (list (plist-get property :dirty-kind)))))

(defun ebox-style--schema-projections (property)
  "Return immutable projection owners for PROPERTY metadata."
  (let ((name (plist-get property :name))
        (group (plist-get property :group))
        (contexts (plist-get property :contexts)))
    (or (plist-get property :projections)
        (cond
         ((eq group 'typography) '(measurement paint))
         ((memq 'item contexts) '(parent-participation))
         ((or (string-prefix-p ":padding" (symbol-name name))
              (and (string-prefix-p ":border" (symbol-name name))
                   (not (string-suffix-p "-color" (symbol-name name)))
                   (not (eq name :border-color))))
          '(layout paint))
         ((eq group 'paint) '(paint))
         ((eq group 'structure) '(structure layout))
         (t '(layout))))))

(defun ebox-style--schema-domain-owner (property)
  "Return the domain owner of PROPERTY's computed projection."
  (let ((name (plist-get property :name))
        (group (plist-get property :group))
        (contexts (plist-get property :contexts)))
    (cond
     ((eq group 'typography) 'font-metrics-projection)
     ((memq 'item contexts) 'direct-parent-layout)
     ((eq group 'paint) 'tp-contribution)
     ((or (memq name '(:gap :flex-flow))
          (cl-some
           (lambda (tag)
             (memq name (ebox-layout-config-property-names tag)))
           '(row column flex grid)))
      'ebox-layout-config)
     (t 'ebox-box-frame))))

(defun ebox-style--schema-metadata (property)
  "Return detached, complete registry metadata for PROPERTY."
  (let ((metadata (copy-tree property)))
    (setq metadata
          (plist-put metadata :namespace
                     (if (memq (plist-get property :name)
                               '(:wrap-mode :item-gap :cross-align
                                 :border-top-p :grid-column-span
                                 :grid-row-span :layer :anchor :placement))
                         'ebox
                       'css)))
    (setq metadata
          (plist-put metadata :owner
                     (ebox-style--schema-domain-owner property)))
    (setq metadata
          (plist-put metadata :impacts
                     (ebox-style--schema-impacts property)))
    (setq metadata
          (plist-put metadata :engine-targets
                     (ebox-style--definition-engine-targets property)))
    (plist-put metadata :projections
               (ebox-style--schema-projections property))))

(defun ebox-style--schema-definition (property)
  "Return one ECSS package definition for Ebox PROPERTY metadata."
  (append
   (list :id (plist-get property :id)
         :aliases
         (cons (plist-get property :name)
               (copy-sequence (plist-get property :aliases)))
         :impacts (ebox-style--schema-impacts property)
         :projections (ebox-style--schema-projections property)
         :metadata (ebox-style--schema-metadata property))
   (ebox-style--schema-options property)))

(defconst ebox-style--schema-package
  (ecss-schema-package-create
   'ebox
   (mapcar #'ebox-style--schema-definition
           ebox-style--property-definitions))
  "Immutable Ebox property package registered with ECSS.")

(defconst ebox-style--property-index
  (let ((table (make-hash-table :test #'eq)))
    (dolist (source ebox-style--property-definitions table)
      (let ((property (ebox-style--schema-metadata source)))
        (puthash (plist-get property :id) property table)
        (puthash (plist-get property :name) property table)
        (dolist (alias (plist-get property :aliases))
          (puthash alias property table)))))
  "Ebox-owned immutable lookup index over property definitions.")

(defconst ebox-style-schemas
  (ecss-schema-set-compose ebox-style--schema-package)
  "Immutable Ebox-only surface schema set.")

(defvar ebox-style--closed-computed-cache (make-hash-table :test #'equal)
  "Bounded cache of selector-free, dependency-free computed styles.")

(defvar ebox-style--closed-inheritance-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Computed-style keyed canonical inheritance projections.")

(defconst ebox-style--closed-computed-cache-limit 512
  "Maximum selector-free computed styles retained across projections.")

(declare-function tp-computed-p "tp-style" (value))

(defun ebox-style--closed-declarations-p (declarations)
  "Return non-nil when DECLARATIONS contain no deferred source or ECSS tag."
  (cl-loop for (_property value) on declarations by #'cddr
           never (or (tp-computed-p value)
                     (ecss-declaration-value-tagged-p value))))

(defvar ebox-style-stylesheet (ebox-style--create-stylesheet)
  "Isolated ECSS stylesheet containing Ebox layout and paint rules.")

(defvar ebox-style--scopes nil
  "Mounted ECSS scopes for the current candidate or retained computation.")

(defvar ebox-style--scope-cache (make-hash-table :test 'eq :weakness 'key)
  "Source-index keyed mounted scope snapshots.")

(defvar ebox-style--scope-source-signatures (make-hash-table :test 'eq :weakness 'key)
  "Immutable source identity, rule, and membership facts per mounted scope.")

(cl-defun ebox-style-scope-create (rules &key (origin 'author))
  "Create an immutable shared scope from ordered RULES at ORIGIN.
RULES use the same syntax and Ebox schema as `ebox-style-compile-rules'.
Attach the returned object to source bindings through `:ecss-scopes' for
membership and `:ecss-scope-roots' for roots.  Each root mounts independently;
only members within that root can receive rules.  No roots means no rules."
  (let ((sheet (ecss-stylesheet-create)))
    (ecss-stylesheet-declare-layers sheet nil origin)
    (dolist (rule (ebox-style-compile-rules rules))
      (ecss-stylesheet-add-rule sheet ebox-style-schemas (car rule) (cdr rule)
                                :origin origin))
    (ebox-style--make-scope :identity (make-symbol "ebox-style-scope")
                            :stylesheet sheet)))

(cl-defun ebox-style-scope-with-rules (scope rules &key (origin 'author))
  "Return a new RULES snapshot preserving SCOPE's membership identity.
ORIGIN follows `ebox-style-scope-create'.  Install the returned description
on roots; existing members need no rebinding.  Each root uses its own rule
snapshot.  Neither SCOPE nor previously constructed inputs are modified."
  (unless (ebox-style-scope-p scope)
    (error "Expected an Ebox shared style scope"))
  (let ((next (ebox-style-scope-create rules :origin origin)))
    (setf (ebox-style-scope-identity next) (ebox-style-scope-identity scope))
    next))

(defun ebox-style--shared-source-scopes (source-index)
  "Mount shared scope roots and memberships from SOURCE-INDEX."
  (let ((roots (make-hash-table :test #'eq))
        (members (make-hash-table :test #'eq))
        order scopes)
    (dolist (handle (ebox-source-index-handles source-index))
      (let ((record (ebox-source--index-record source-index handle)))
        (dolist (scope (ebox-source-record-ecss-scopes record))
          (push handle (gethash (ebox-style-scope-identity scope) members)))
        (dolist (scope (ebox-source-record-ecss-scope-roots record))
          (unless (gethash scope roots) (push scope order))
          (push handle (gethash scope roots)))))
    (dolist (description (nreverse order))
      (let* ((targets (reverse (gethash (ebox-style-scope-identity description) members)))
             (subjects (mapcar (lambda (handle)
                                 (ebox-source--index-subject source-index handle))
                               targets))
             (identities (mapcar #'ebox-source--handle-id-view targets)))
        (dolist (handle (nreverse (gethash description roots)))
          (let ((scope (ecss-scope-create
                        (ebox-source--index-subject source-index handle)
                        (ebox-style-scope-stylesheet description)
                        :subjects subjects)))
            (puthash scope
                     (list :rules (list (ebox-style-scope-identity description)
                                        (ebox-style-scope-stylesheet description))
                           :root (ebox-source--handle-id-view handle)
                           :targets identities)
                     ebox-style--scope-source-signatures)
            (push scope scopes)))))
    (nreverse scopes)))

(defun ebox-style-source-scopes (source-index &optional root)
  "Mount SOURCE-INDEX local styles on its canonical selector subjects."
  (when (and source-index (or (ebox-source--index-subjects source-index) root))
    (when (and root (null (ebox-source--index-selector-view source-index)))
      (setq source-index
            (ebox-tree-source-index root t nil source-index)))
    (let* ((missing (make-symbol "missing"))
           (cached (gethash source-index ebox-style--scope-cache missing)))
      (if (not (eq cached missing)) cached
        (let (subjects scopes shared-p)
          (dolist (handle (ebox-source-index-handles source-index))
            (when-let* ((record (ebox-source--index-record source-index handle)))
              (when (ebox-source-record-ecss-scope-roots record)
                (setq shared-p t))
              (when-let* ((rules (ebox-source-record-ecss record)))
                (let ((sheet (ecss-stylesheet-create))
                      (subject (ebox-source--index-subject source-index handle)))
                  (unless subject (error "Local ECSS requires indexed subjects"))
                  (dolist (rule rules)
                    (ecss-stylesheet-add-rule
                     sheet ebox-style-schemas (car rule) (cdr rule)))
                  (push (ecss-scope-create
                         subject sheet
                         :subjects
                         (let ((targets (ebox-source-record-ecss-targets record)))
                           (if (eq targets t) t
                             (when (and targets (null subjects))
                               (setq subjects (make-hash-table :test #'equal))
                               (dolist (target (ebox-source-index-handles source-index))
                                 (puthash (ebox-source--handle-id-view target)
                                          (ebox-source--index-subject source-index target)
                                          subjects)))
                             (mapcar
                              (lambda (identity)
                                (or (gethash identity subjects)
                                    (error "Ebox ECSS target is absent: %S" identity)))
                              targets))))
                        scopes)
                  (puthash (car scopes)
                           (list :rules rules
                                 :root (ebox-source--handle-id-view handle)
                                 :targets (ebox-source-record-ecss-targets record))
                           ebox-style--scope-source-signatures)))))
          (setq scopes (nconc (nreverse scopes)
                              (and shared-p
                                   (ebox-style--shared-source-scopes source-index))))
          (puthash source-index scopes ebox-style--scope-cache)
          scopes)))))

(defun ebox-style-cascade-active-p ()
  "Return non-nil when the Ebox stylesheet contains cascade rules.
Inline declarations are compiled into Ebox engine properties while nodes are
created, so a surface with no stylesheet rules does not need a per-node ECSS
cascade pass during its initial static projection."
  (or ebox-style--scopes
      (not (null (ecss-stylesheet-rules ebox-style-stylesheet)))))

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

(defun ebox-style--declaration-value-equal-p (left right)
  "Return non-nil when declaration values LEFT and RIGHT are equivalent.
TP paint slots are stable paint addresses.  Their installation flag and
current face specification belong to TP publication state, not to the Ebox
author declaration that references the slot."
  (if (and (tp-paint-slot-p left) (tp-paint-slot-p right))
      (eq (tp-paint-slot-face left) (tp-paint-slot-face right))
    (equal-including-properties left right)))

(defun ebox-style-declarations-equal-p (left right)
  "Return non-nil when canonical declaration plists LEFT and RIGHT are equal."
  (let ((left left)
        (right right)
        equal-p)
    (setq equal-p t)
    (while (and equal-p left right)
      (setq equal-p
            (and (eq (car left) (car right))
                 (ebox-style--declaration-value-equal-p
                  (cadr left) (cadr right)))
            left (cddr left)
            right (cddr right)))
    (and equal-p (null left) (null right))))

(defconst ebox-style--inherited-properties
  (cl-loop for property in ebox-style--property-definitions
           when (plist-get property :inherits)
           collect (plist-get property :id))
  "Canonical ECSS properties inherited according to the shared schema.")

(defun ebox-style--inherited-declarations-changed-p (old new)
  "Return non-nil when OLD and NEW change descendant style inputs.
The inherited property domain comes only from the canonical schema.  ECSS
custom properties also participate because a descendant `var' expression may
consume them even though Ebox does not interpret their names."
  (or
   (cl-some
    (lambda (property)
      (let ((old-entry (plist-member old property))
            (new-entry (plist-member new property)))
        (not (and (eq (not (null old-entry)) (not (null new-entry)))
                  (ebox-style--declaration-value-equal-p
                   (cadr old-entry) (cadr new-entry))))))
    ebox-style--inherited-properties)
   (not
    (ebox-style-declarations-equal-p
     (cl-loop for (property value) on old by #'cddr
              when (ebox-style--custom-property-p property)
              append (list property value))
     (cl-loop for (property value) on new by #'cddr
              when (ebox-style--custom-property-p property)
              append (list property value))))))

(defun ebox-style--valid-plist-p (plist)
  "Return non-nil when PLIST is a proper even-length list."
  (and (proper-list-p plist) (zerop (% (length plist) 2))))

(defun ebox-style--validate-no-duplicate-properties (plist)
  "Reject duplicate canonical properties in author PLIST."
  (let ((seen (make-hash-table :test 'eq)))
    (cl-loop for (name _value) on plist by #'cddr
             for property = (ebox-style--property name)
             for id = (and property (plist-get property :id))
             when id
             do (when-let* ((previous (gethash id seen)))
                  (error
                   "Duplicate Ebox property %S via %S and %S"
                   (plist-get property :name) previous name))
             and do (puthash id name seen)))
  plist)

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
                      (append canonical (list property value)))
             else if strict
             do (setq canonical
                      (append canonical
                              (list 'ebox-style/unknown-property
                                    property value))))
    (list strict canonical)))

(defun ebox-style--static-invalid-declaration-p (validator value)
  "Return non-nil when VALIDATOR rejects static VALUE."
  (pcase validator
    ('preferred-size (not (ebox-style--preferred-size-p value)))
    ('nonnegative-number
     (and (numberp value) (< value 0)))
    ('horizontal-size (not (ebox-style--horizontal-size-p value)))
    ('min-horizontal-size (not (ebox-style--min-horizontal-size-p value)))
    ('max-horizontal-size (not (ebox-style--max-horizontal-size-p value)))
    ('vertical-size (not (ebox-style--vertical-size-p value)))
    ('min-vertical-size (not (ebox-style--min-vertical-size-p value)))
    ('max-vertical-size (not (ebox-style--max-vertical-size-p value)))
    ('nonnegative-size (not (ebox-style--nonnegative-size-p value)))
    ('signed-size (not (ebox-style--signed-size-p value)))
    ('position (not (ebox-style--position-p value)))
    ('integer (not (integerp value)))
    ('layer (not (ebox-style--layer-p value)))
    ('anchor (not (ebox-style--anchor-p value)))
    ('placement (not (ebox-style--placement-p value)))
    ('positive-integer
     (and (numberp value) (not (ebox-style--positive-integer-p value))))
    ('grid-placement
     (and (or (numberp value) (proper-list-p value))
          (not (ebox-style--grid-placement-p value))))
    ('font-family (not (ebox-style--font-family-p value)))
    ('color (not (ebox-style--color-p value)))
    ('font-size (not (ebox-style--font-size-p value)))
    ('font-weight (not (ebox-style--font-weight-p value)))
    ('font-style (not (ebox-style--font-style-p value)))
    ('border-width (not (ebox-style--border-width-p value)))
    ('border-style (not (ebox-style--border-style-p value)))
    ('text-decoration-line
     (not (ebox-style--text-decoration-line-p value)))
    ('text-decoration-style
     (not (ebox-style--text-decoration-style-p value)))
    ('nonnegative-integer
     (not (ebox-style--nonnegative-integer-p value)))
    ('cross-align (not (ebox-style--cross-align-p value)))
    ('flex-direction (not (ebox-style--flex-direction-p value)))
    ('flex-wrap (not (ebox-style--flex-wrap-p value)))
    ('justify-content (not (ebox-style--justify-content-p value)))
    ('align-items (not (ebox-style--align-items-p value)))
    ('align-content (not (ebox-style--align-content-p value)))
    ('justify-items (not (ebox-style--justify-items-p value)))
    ('align-self (not (ebox-style--align-self-p value)))
    ('grid-auto-flow (not (ebox-style--grid-auto-flow-p value)))
    ('grid-track-list (not (ebox-style--grid-track-list-p value)))
    ('grid-track (not (ebox-style--grid-auto-track-p value)))
    ('order (not (ebox-style--order-p value)))
    ('flex-factor
     (and (numberp value) (not (ebox-style--nonnegative-number-p value))))
    ('justify-self (not (ebox-style--justify-self-p value)))
    ('wrap-mode
     (not (ebox-style--wrap-mode-p value)))))

(defun ebox-style--validate-declaration-values (declarations &optional tag)
  "Return DECLARATIONS after static value and author TAG axis validation."
  (cl-loop for (property value) on declarations by #'cddr
           for schema = (ebox-style--property property)
           for validator = (and schema (plist-get schema :validator))
           for axis = (ebox-style--size-axis schema tag)
           unless (ecss-declaration-value-valid-p
                   value
                   (lambda (concrete)
                     (and (not (ebox-style--static-invalid-declaration-p
                                validator concrete))
                          (ebox-style--size-value-valid-p schema concrete tag))))
           do (if axis
                  (signal 'ebox-size-error
                          (list
                           (format "Invalid value for %S; allowed units: %S"
                                   (plist-get schema :name)
                                   (cdr (assq axis ebox-size-axis-units)))
                           value))
                (error "ebox: invalid value for %S: %S"
                       (plist-get schema :name) value)))
  declarations)

(defconst ebox-style--edge-projection-groups
  '((:padding-top ebox/padding-top ebox/padding-block-start)
    (:padding-right ebox/padding-right ebox/padding-inline-end)
    (:padding-bottom ebox/padding-bottom ebox/padding-block-end)
    (:padding-left ebox/padding-left ebox/padding-inline-start)
    (:margin-top ebox/margin-top ebox/margin-block-start)
    (:margin-right ebox/margin-right ebox/margin-inline-end)
    (:margin-bottom ebox/margin-bottom ebox/margin-block-end)
    (:margin-left ebox/margin-left ebox/margin-inline-start))
  "Canonical facts sharing one fixed horizontal-tb/ltr physical edge.")

(defconst ebox-style--edge-projection-targets
  (cl-loop for (target . properties) in ebox-style--edge-projection-groups
           append (mapcar (lambda (property) (cons property target))
                          properties))
  "Canonical edge property to fixed physical projection target.")

(defun ebox-style--validate-edge-projection-conflicts (declarations)
  "Reject canonical DECLARATIONS that target one physical edge twice."
  (let ((seen (make-hash-table :test #'eq)))
    (cl-loop for (property _value) on declarations by #'cddr
             for target = (alist-get property
                                    ebox-style--edge-projection-targets)
             when target
             do (when-let* ((previous (gethash target seen)))
                  (signal 'ecss-invalid-declaration
                          (list :duplicate-edge-target target
                                :first-property previous
                                :second-property property)))
             and do (puthash target property seen)))
  declarations)

(defun ebox-style-compile-declarations (plist &optional strict)
  "Compile Ebox PLIST aliases to ECSS schema declarations.
When STRICT is non-nil, reject properties outside the Ebox style domain."
  (unless (ebox-style--valid-plist-p plist)
    (user-error "Ebox style declarations must be an even property list"))
  (ebox-style--validate-no-duplicate-properties plist)
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
                (ebox-style--validate-edge-projection-conflicts
                 (ecss-expand-declarations ebox-style-schemas canonical)))))
          (when (>= (hash-table-count ebox-style--declaration-cache)
                    ebox-style--declaration-cache-max-entries)
            (clrhash ebox-style--declaration-cache))
          (puthash cache-key compiled ebox-style--declaration-cache)
          (copy-sequence compiled))))))

(defun ebox-style--form-property-allowed-p (tag property)
  "Return non-nil when author TAG accepts PROPERTY metadata."
  (let ((contexts (plist-get property :contexts))
        (author-contexts (plist-get property :author-contexts)))
    (if author-contexts
        (memq tag author-contexts)
      (or (memq tag contexts)
          (and (not (eq tag 'text))
               (or (memq 'box contexts) (memq 'item contexts)))))))

(defun ebox-style-validate-form-declarations (tag declarations)
  "Validate canonical DECLARATIONS for Text/Box author TAG."
  (unless (memq tag '(text box row column flex grid))
    (error "Unknown Ebox author form: %S" tag))
  (unless (ebox-style--valid-plist-p declarations)
    (error "Ebox canonical declarations must be an even plist: %S"
           declarations))
  (let ((seen (make-hash-table :test #'eq)))
    (cl-loop for (id _value) on declarations by #'cddr
             for property = (ebox-style--property id)
             unless (or (ebox-style--custom-property-p id)
                        (and property (eq id (plist-get property :id))))
             do (error "Ebox declaration is not a canonical property ID: %S"
                       id)
             do (when (gethash id seen)
                  (error "Duplicate canonical Ebox declaration: %S" id))
             do (puthash id t seen)
             unless (or (ebox-style--custom-property-p id)
                        (ebox-style--form-property-allowed-p tag property))
             do (error "Ebox %S does not accept %S"
                       tag (plist-get property :name))))
  (ebox-style--validate-declaration-values declarations tag)
  declarations)

(defun ebox-style--validate-author-values (plist)
  "Reject values in author PLIST outside the public property grammars.
An ECSS schema may use nil as an internal initial value, but nil is not an
author value unless the public grammar is boolean or an optional anchor."
  (unless (ebox-style--valid-plist-p plist)
    (user-error "Ebox style declarations must be an even property list"))
  (cl-loop for (name value) on plist by #'cddr
           for property = (ebox-style--property name)
           when (and property
                     (null value)
                     (not (memq (plist-get property :validator)
                                '(boolean anchor))))
           do (error "ebox: invalid value for %S: nil"
                     (plist-get property :name)))
  plist)

(defun ebox-style-compile-form (tag plist)
  "Compile evaluated author PLIST once and validate it for TAG."
  (ebox-style-validate-form-declarations
   tag
   (ebox-style-compile-declarations
    (ebox-style--validate-author-values plist) t)))

(defun ebox-style--deferred-declarations-p (declarations)
  "Return whether DECLARATIONS need ECSS before engine projection."
  (cl-loop for (property value) on declarations by #'cddr
           thereis (or (ebox-style--custom-property-p property)
                       (ecss-declaration-value-tagged-p value))))

(defun ebox-style--concrete-declarations (declarations)
  "Return DECLARATIONS that are safe for provisional engine fields.
Source records retain the complete input for authoritative ECSS computation."
  (cl-loop for (property value) on declarations by #'cddr
           unless (or (ebox-style--custom-property-p property)
                      (ecss-declaration-value-tagged-p value))
           append (list property value)))

(defun ebox-style-declaration-properties (declarations predicate)
  "Return canonical author properties in DECLARATIONS matching PREDICATE."
  (cl-loop for (id value) on declarations by #'cddr
           for property = (or (ebox-style--property id)
                              (unless (ebox-style--custom-property-p id)
                                (error "Unknown canonical Ebox property: %S" id)))
           when (and property (funcall predicate property))
           append (list (plist-get property :name) value)))

(defun ebox-style-declarations-require-projection-p
    (declarations predicate)
  "Return non-nil when DECLARATIONS include facts outside PREDICATE."
  (cl-loop for (id _value) on declarations by #'cddr
           for property = (or (ebox-style--property id)
                              (unless (ebox-style--custom-property-p id)
                                (error "Unknown canonical Ebox property: %S" id)))
           thereis (or (null property) (not (funcall predicate property)))))

(defun ebox-style-merge-declarations (base overrides)
  "Merge canonical BASE and OVERRIDES through ECSS property schemas."
  (ecss-merge-declarations ebox-style-schemas base overrides))

(defun ebox-style-compile-rules (rules)
  "Compile ordered RULES through ECSS syntax and the strict Ebox schema.
Return detached (SELECTOR-AST . DECLARATIONS) rules suitable for the :ecss
field of `ebox-source-builder-bind'.  RULES uses (SELECTOR PROPERTY VALUE ...)
entries, with string selectors and inert declaration values.  This function
mutates no input or stylesheet and evaluates no declaration values."
  (mapcar (lambda (rule)
            (cons (ecss-selector-parse (car rule))
                  (ebox-style-compile-declarations (cdr rule) t)))
          (ecss-validate-rules rules)))

(cl-defun ebox-style-add-rule
    (selector declarations &key (origin 'author) layer scope)
  "Add SELECTOR rule with Ebox DECLARATIONS to the isolated stylesheet.
ORIGIN, LAYER, and SCOPE use ECSS cascade semantics."
  (ecss-stylesheet-add-rule
   ebox-style-stylesheet ebox-style-schemas (ebox-style--selector selector)
   (ebox-style-compile-declarations declarations t)
   :origin origin :layer layer
   :scope (and scope (ebox-style--selector scope))))

(defun ebox-style-compute-subject (subject declarations &optional parent-style)
  "Compute SUBJECT style from DECLARATIONS and optional PARENT-STYLE via ECSS."
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
              :scopes ebox-style--scopes :adapter ebox-selector-view-adapter
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
    ebox/text-decoration-line ebox/text-decoration-color
    ebox/text-decoration-style ebox/visibility
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
             (not (ebox-style--deferred-declarations-p old-declarations))
             (not (ebox-style--deferred-declarations-p new-declarations))
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
             (not (ebox-style--deferred-declarations-p declarations))
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

(defvar ebox-style--computed-snapshot-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Immutable Ebox projection snapshots keyed by computed style identity.")

(defun ebox-style--computed-snapshot (style &optional specified-p)
  "Return one internal immutable ECSS snapshot for STYLE projection.
When SPECIFIED-P is non-nil, include declaration-winner facts.  Ebox
materializes each immutable computed style once per snapshot shape; callers
must treat the returned values as read-only."
  (let* ((entry
          (or (gethash style ebox-style--computed-snapshot-cache)
              (let ((created (vector nil nil)))
                (puthash style created ebox-style--computed-snapshot-cache)
                created)))
         (index (if specified-p 1 0))
         (snapshot (aref entry index)))
    (or snapshot
        (let* ((other (aref entry (- 1 index)))
               (values (if other (nth 0 other)
                         (ecss-computed-style-values style)))
               (active (if other (nth 1 other)
                         (ecss-computed-style-active-properties style)))
               (created
                (list values active
                      (and specified-p
                           (ecss-computed-style-specified-properties style)))))
          (aset entry index created)
          created))))

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

(defun ebox-style--project-edge-values (style values snapshot)
  "Resolve logical/physical VALUES through STYLE's cross-property winners.
SNAPSHOT supplies the already-read computed value table."
  (let* ((edge-names
          (mapcar (lambda (entry)
                    (ebox-style-canonical-name (car entry)))
                  ebox-style--edge-projection-targets))
         (result
          (cl-loop for (property value) on values by #'cddr
                   unless (memq property edge-names)
                   append (list property value))))
    (dolist (group ebox-style--edge-projection-groups result)
      (let* ((target (car group))
             (winner
              (ecss-computed-style-precedence-winner style (cdr group))))
        (when winner
          (setq result
                (plist-put result target
                           (plist-get (car snapshot) winner))))))))

(defun ebox-style--specified-property-p (style property)
  "Return non-nil when STYLE PROPERTY has a declaration winner."
  (ecss-computed-style-specified-p style property))

(defun ebox-style--node-declarations-from-record (node record)
  "Return NODE's author declarations from borrowed immutable source RECORD."
  (let ((declarations
         (and record (ebox-source-record-declarations record))))
    (if (memq (plist-get node :ebox-type) '(flex grid))
        (ebox-style-merge-declarations
         declarations
         (plist-get (plist-get node :box) :ebox-style-overrides))
      declarations)))

(defun ebox-style-node-declarations (source-index node)
  "Return NODE's immutable author declarations from candidate SOURCE-INDEX.
Private generated layout nodes have no author source and therefore contribute
no declarations of their own."
  (ebox-style--node-declarations-from-record
   node
   (when-let* ((handle (plist-get node :ebox-source-handle)))
     (ebox-source--index-record source-index handle))))

(defun ebox-style-node-specified-value
    (node name &optional missing source-index)
  "Return NODE's canonical specified value for author property NAME.
Return MISSING when NAME is valid but not specified.  Aliases resolve to the
same canonical property id, so callers never inspect backend plist fields.
NODE may be a canonical input with one root.  A mounted raw node requires its
explicit generation SOURCE-INDEX; facts are never recovered from its handle."
  (when (ebox-canonical-input-p node)
    (setq source-index (ebox-canonical-input--source-index node)
          node (ebox-canonical-input--single-root
                node "ebox-style-node-specified-value")))
  (unless (ebox-source-index-p source-index)
    (error "Ebox specified-value lookup requires a source index"))
  (let ((id (or (ebox-style-schema-id name)
                (error "Unknown Ebox property: %S" name)))
        (declarations (ebox-style-node-declarations source-index node)))
    (if (plist-member declarations id)
        (plist-get declarations id)
      missing)))

(defun ebox-style--remove-style-properties (plist)
  "Return PLIST without Ebox style or ECSS custom properties."
  (cl-loop for (property value) on plist by #'cddr
           unless (or (ebox-style--property property)
                      (ebox-style--custom-property-p property))
           append (list property value)))

(defvar ebox-style--box-runtime-defaults)

(defun ebox-style--reset-box-engine-style (box)
  "Reset BOX engine style fields to their declared defaults."
  (cl-loop for (property value) on ebox--longhand by #'cddr
           unless (memq property '(:content :scroll-offset))
           do (plist-put box property (copy-tree value)))
  (unless (eq (plist-get box :ebox-kind) 'text)
    (cl-loop for (property value) on ebox-style--box-runtime-defaults by #'cddr
             do (plist-put box property (copy-tree value))))
  box)

(defun ebox-style--apply-engine-values (box values)
  "Project public style VALUES into BOX engine fields."
  (ebox-style--reset-box-engine-style box)
  (let ((expanded
         (ebox-style--expand-engine-plist
          (ebox-style--without-font-values values))))
    (cl-loop for (property value) on expanded by #'cddr
             do (plist-put box property value)))
  box)

(defvar ebox-style--box-engine-longhand-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Computed-style keyed expanded engine longhands for canonical Box nodes.")

(defvar ebox-style--text-engine-longhand-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Computed-style keyed expanded engine longhands for canonical Text nodes.")

(defun ebox-style--cached-engine-longhands (style text-p snapshot)
  "Return STYLE's expanded engine longhands for TEXT-P and SNAPSHOT."
  (let* ((cache (if text-p
                    ebox-style--text-engine-longhand-cache
                  ebox-style--box-engine-longhand-cache))
         (missing (make-symbol "ebox-engine-longhands-missing"))
         (cached (gethash style cache missing)))
    (if (not (eq cached missing))
        cached
      (let ((expanded
             (ebox-style--expand-engine-plist
              (ebox-style--without-font-values
               (if text-p
                   (ebox-style--text-values style snapshot)
                 (ebox-style--box-values style snapshot))))))
        (puthash style expanded cache)
        expanded))))

(defun ebox-style--apply-engine-longhands (box longhands)
  "Project already expanded LONGHANDS into BOX engine fields."
  (ebox-style--reset-box-engine-style box)
  (cl-loop for (property value) on longhands by #'cddr
           do (plist-put box property value))
  box)

(defun ebox-style--box-values (style &optional snapshot)
  "Return computed box values ready for Ebox engine projection."
  (let* ((snapshot (or snapshot (ebox-style--computed-snapshot style)))
         (values
          (ebox-style--project-edge-values
           style (ebox-style--context-values style 'box nil snapshot)
           snapshot)))
    (when (and (ebox-style--snapshot-active-p snapshot :color)
               (null (plist-get values :color)))
      (setq values
            (plist-put values :color ebox-style--default-foreground)))
    values))

(defun ebox-style--text-values (style snapshot)
  "Return computed STYLE values owned by canonical Text."
  (let ((values (ebox-style--context-values style 'text nil snapshot)))
    (when (and (ebox-style--snapshot-active-p snapshot :color)
               (null (plist-get values :color)))
      (setq values
            (plist-put values :color ebox-style--default-foreground)))
    ;; Wrap policy is authored only by Box, then inherited as Text's
    ;; measurement input without creating a second Text author property.
    (when (ebox-style--snapshot-active-p snapshot :wrap-mode)
      (setq values
            (plist-put values :wrap-mode
                       (plist-get (car snapshot) 'ebox/wrap-mode))))
    values))

(defconst ebox-style--font-property-names
  '(:font-family :font-size :font-weight :font-style)
  "Canonical font inputs owned by one FontMetricsProjection.")

(defun ebox-style--without-font-values (values)
  "Return computed VALUES without canonical font inputs."
  (cl-loop for (property value) on values by #'cddr
           unless (memq property ebox-style--font-property-names)
           append (list property value)))

(defun ebox-style--closed-inheritance-values (style &optional snapshot)
  "Return STYLE's immutable canonical inheritance projection."
  (let* ((missing (make-symbol "ebox-inheritance-missing"))
         (cached (gethash style ebox-style--closed-inheritance-cache missing)))
    (if (not (eq cached missing))
        cached
      (let* ((snapshot (or snapshot (ebox-style--computed-snapshot style)))
             (values (ebox-style--box-values style snapshot))
             result)
        (dolist (property '(:color :wrap-mode))
          (when (plist-member values property)
            (setq result
                  (plist-put result property (plist-get values property)))))
        (puthash style result ebox-style--closed-inheritance-cache)
        result))))

(defun ebox-style-apply-closed-inheritance (node style &optional snapshot)
  "Apply only closed computed inheritance from STYLE to fresh canonical NODE."
  (let ((values (ebox-style--closed-inheritance-values style snapshot)))
    (plist-put node :ebox-computed-style style)
    (cl-loop for (property value) on values by #'cddr
             do (plist-put node property value)))
  node)

(defun ebox-style--text-paint-owner-p (node)
  "Return non-nil when NODE materializes inherited text paint itself.
Canonical Text owns typography and foreground paint.  Canonical Box retains
those computed facts for inheritance but materializes only box paint such as
background and borders.  Legacy runtime boxes keep their established behavior
until their private encoding is removed."
  (not (eq (plist-get node :ebox-kind) 'box)))

(defconst ebox-style--container-wrapper-neutral-properties
  '(:width :height :box-sizing :color
    :font-family :font-size :font-weight :font-style)
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
  (let ((wrapper
         (ebox-node-factory--create-from-properties
          :content "" :wrap-mode nil :key 'ebox/style-wrapper)))
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

(defun ebox-style--apply-container (node style &optional snapshot)
  "Apply computed STYLE to Flex or Grid NODE."
  (let* ((type (plist-get node :ebox-type))
         (metadata
          (ebox-style--remove-style-properties (plist-get node :raw-props)))
         (values
          (append (ebox-style--context-values style 'box nil snapshot)
                  (ebox-style--context-values style type nil snapshot)))
         (raw (append metadata values)))
    (plist-put node :raw-props raw)
    (plist-put node :props
               (if (eq type 'flex)
                   (ebox--flex-normalize-container-props raw)
                 raw))
    (when (eq type 'grid)
      (plist-put node :ebox-grid-config
                 (ebox-grid--normalize-config-props raw)))
    (ebox-style--apply-container-wrapper node style snapshot)))

(defun ebox-style--layout-config-values (style kind snapshot)
  "Return specified STYLE values owned by KIND's typed LayoutConfig."
  (let ((names (ebox-layout-config-property-names kind)))
    (cl-loop for (property value)
             on (ebox-style--context-values style kind t snapshot)
             by #'cddr
             when (memq property names)
             append (list property value))))

(defun ebox-style--merge-layout-config-values (base overrides)
  "Return detached BASE LayoutConfig values updated by OVERRIDES."
  (let ((result (copy-tree base)))
    (cl-loop for (property value) on overrides by #'cddr
             do (setq result (plist-put result property value)))
    result))

(defun ebox-style--normalize-layout-config-overrides (kind overrides)
  "Return specified KIND OVERRIDES in canonical LayoutConfig form."
  (when overrides
    (let* ((config (ebox-layout-config-for-form kind overrides))
           (normalized (ebox-layout-config-props config))
           (names (cl-loop for (name _value) on overrides by #'cddr
                           collect name)))
      (cl-loop for name in names
               append (list name (plist-get normalized name))))))

(defun ebox-style--apply-typed-layout-config (node style snapshot)
  "Project computed STYLE child-layout facts into typed Box NODE."
  (let* ((current (plist-get node :ebox-layout-config))
         (kind (and current (ebox-layout-config-kind current)))
         (current-properties
          (and current
               (eq kind (ebox-layout-config-kind current))
               (ebox-layout-config-props current)))
         (overrides
          (and (memq kind '(flex grid))
               (ebox-style--layout-config-values style kind snapshot)))
         (properties
          (ebox-style--merge-layout-config-values
           current-properties
           (ebox-style--normalize-layout-config-overrides kind overrides))))
    (when overrides
      (plist-put node :ebox-layout-config
                 (ebox-layout-config-with-props current properties)))
    (plist-put node :display
               (list (or (car-safe (plist-get node :display)) 'block)
                     (if (eq kind 'normal) 'flow kind)))))

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

(defconst ebox-style--item-projection-properties
  '(:order :flex-grow :flex-shrink :flex-basis :align-self
    :grid-column :grid-row :justify-self)
  "Canonical node fields owned by computed parent participation style.")

(defun ebox-style--transfer-node-property (old new property)
  "Transfer style-owned PROPERTY presence and value from OLD to NEW."
  (if (plist-member old property)
      (plist-put new property (plist-get old property))
    (ebox-style--delete-node-property new property)))

(defun ebox-style--computed-projection-transferable-p (old new style)
  "Return non-nil when OLD's STYLE projection is exact for canonical NEW.
Display axes and typed layout config combine style with the fresh node's base
structure.  They must already agree; otherwise the ordinary projection path
recomputes that combination from NEW."
  (and (memq (plist-get new :ebox-kind) '(text box))
       (eq (plist-get old :ebox-kind) (plist-get new :ebox-kind))
       (eq (plist-get old :ebox-type) (plist-get new :ebox-type))
       (eq style (plist-get old :ebox-computed-style))
       (equal (plist-get old :display) (plist-get new :display))
       (equal (plist-get old :ebox-layout-config)
              (plist-get new :ebox-layout-config))))

(defun ebox-style--transfer-computed-projection (old new style)
  "Transfer OLD's materialized STYLE projection onto fresh canonical NEW.
OLD and NEW must have the same canonical kind and source-stable computed
style.  Content, children, source/runtime identity, and scroll state remain
owned by NEW; only fields owned by the unchanged computed style are shared."
  (unless (ebox-style--computed-projection-transferable-p old new style)
    (error "Ebox computed projection transfer requires source-stable peers"))
  (plist-put new :ebox-computed-style style)
  (cl-loop for (property _value) on ebox--longhand by #'cddr
           unless (memq property '(:content :scroll-offset))
           do (ebox-style--transfer-node-property old new property))
  (when (eq (plist-get new :ebox-kind) 'box)
    (cl-loop for (property _value) on ebox-style--box-runtime-defaults by #'cddr
             do (ebox-style--transfer-node-property old new property)))
  (dolist (property ebox-style--item-projection-properties)
    (ebox-style--transfer-node-property old new property))
  new)

(defun ebox-style--apply-item (node style &optional snapshot)
  "Apply computed Flex/Grid item fields from STYLE to NODE."
  (let ((values (ebox-style--context-values style 'item nil snapshot)))
    (dolist (property ebox-style--item-projection-properties)
      (ebox-style--delete-node-property node property))
    (cl-loop for (property value) on values by #'cddr
             do (plist-put node property value)))
  node)

(defun ebox-style--apply-display-axes (node style)
  "Apply computed public outer participation from STYLE to NODE."
  (let ((outer-specified-p
         (ebox-style--specified-property-p style 'ebox/outer)))
    (if (eq (plist-get node :ebox-kind) 'text)
        (progn
          (when outer-specified-p
            (error "Ebox Text is fixed inline and rejects display axes"))
          (plist-put node :display '(inline flow)))
      (when outer-specified-p
        (let ((display (or (plist-get node :display) '(block flow))))
          (plist-put node :display
                     (list (ebox-style-computed-value style :outer)
                           (cadr display)))))))
  node)

(defun ebox-style-apply-computed (node style &optional snapshot)
  "Apply ECSS computed STYLE consequences to semantic Ebox NODE."
  (unless (ecss-computed-style-p style)
    (signal 'wrong-type-argument (list 'ecss-computed-style-p style)))
  (let* ((type (plist-get node :ebox-type))
         (config (plist-get node :ebox-layout-config))
         (kind (and config (ebox-layout-config-kind config)))
         (snapshot (or snapshot (ebox-style--computed-snapshot style t))))
    (plist-put node :ebox-computed-style style)
    (ebox-style--apply-display-axes node style)
    (cond
     ((or (memq (plist-get node :ebox-kind) '(text box))
          (eq type 'box))
       (ebox-style--apply-engine-longhands
        node
        (ebox-style--cached-engine-longhands
         style (eq (plist-get node :ebox-kind) 'text) snapshot))
       (when (eq (plist-get node :ebox-kind) 'box)
         (ebox-style--apply-typed-layout-config node style snapshot)))
     ((memq (or kind type) '(flex grid))
      (ebox-style--apply-container node style snapshot)))
    (ebox-style--apply-item node style snapshot))
  node)

(defun ebox-style-dirty-kind (name)
  "Return dirty kind for canonical property or alias NAME."
  (when-let* ((property (ebox-style--property name)))
    (plist-get property :dirty-kind)))

(defun ebox-style-signature (computed-style groups)
  "Return deterministic signature for COMPUTED-STYLE filtered by GROUPS."
  (let (entries)
    (while computed-style
      (let* ((property-name (pop computed-style))
             (value (pop computed-style))
             (property (ebox-style--property property-name))
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

(defun ebox-style--convert (value converter)
  "Project VALUE with CONVERTER without resolving contextual size units.
Layout owns used pixel/line values.  Computed style and its cached engine
projection retain expressions so viewport, container, and font changes can
resolve them again.  Numeric zero remains valid for private generated edges."
  (pcase converter
    ((or 'pixel 'size-pixel 'border-pixel 'line) (or value 0))
    ('color (ebox-style--parse-color value))
    (_ value)))

(defconst ebox-style--nonnegative-edge-longhands
  '(:padding-left-pixel :padding-right-pixel
    :padding-top-height :padding-bottom-height
    :margin-left-pixel :margin-right-pixel
    :margin-top-height :margin-bottom-height
    :border-left-pixel :border-right-pixel
    :border-top-pixel :border-bottom-pixel)
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

(defun ebox-style--apply-border-used-widths (plist)
  "Return PLIST with border widths resolved against their styles.
Canonical width remains in the computed style; private engine pixels are the
used geometry and become zero when the corresponding style is not `solid'."
  (dolist (side '(top right bottom left) plist)
    (let ((width-key (intern (format ":border-%s-pixel" side)))
          (style-key (intern (format ":border-%s-style" side))))
      (when (or (plist-member plist width-key)
                (plist-member plist style-key))
        (unless (eq (plist-get plist style-key) 'solid)
          (setq plist (plist-put plist width-key 0)))))))

(defun ebox-style--split-value (value mode n)
  "Split VALUE according to MODE for N targets."
  (pcase mode
    ('trbl (ebox-style--split-trbl value))
    ('pair (ebox-style--split-pair value))
    ('wsc (ebox-style--split-wsc value))
    ('same (make-list n value))
    (_ (make-list n value))))

(defun ebox-style--get-ebox-rule (property)
  "Return Ebox private engine projection rule for PROPERTY."
  (or (when-let* ((definition (ebox-style--property property)))
        (plist-get definition :engine-projection))
      (cdr (assq property ebox-style--internal-engine-projection-rules))))

(defun ebox-style--expand-engine-property (property value)
  "Expand public Ebox PROPERTY with VALUE to engine longhands."
  (let ((rule (ebox-style--get-ebox-rule property)))
    (cond
     ((null rule) (list property value))
     ((plist-get rule :expand)
      (let* ((targets (plist-get rule :expand))
             (mode (plist-get rule :mode))
             (parts (ebox-style--split-value value mode (length targets))))
        (cl-mapcan #'ebox-style--expand-engine-property targets parts)))
     ((plist-member rule :to)
      (let ((target (plist-get rule :to))
            (converter (plist-get rule :conv)))
        (if target
            (list target (ebox-style--convert value converter))
          nil)))
     (t (list property value)))))

(defun ebox-style--engine-projection-targets (property)
  "Return private engine keys potentially projected from PROPERTY."
  (if-let* ((definition (ebox-style--property property)))
      (copy-sequence (plist-get definition :engine-targets))
    (let ((rule
           (cdr (assq property ebox-style--internal-engine-projection-rules))))
      (if (and rule (plist-member rule :to))
          (when-let* ((target (plist-get rule :to))) (list target))
        (list property)))))

(defun ebox-style--expand-engine-plist (plist)
  "Project canonical PLIST into private Ebox runtime fields."
  (let (expanded)
    (while plist
      (let ((property (pop plist))
            (value (pop plist)))
        (setq expanded
              (nconc expanded
                     (ebox-style--expand-engine-property property value)))))
    (ebox-style--apply-border-used-widths
     (ebox-style--validate-edge-longhands expanded))))

(defconst ebox-style--box-runtime-defaults
  (ebox-style--expand-engine-plist
   (cl-loop for property in ebox-style--property-definitions
            when (plist-get property :runtime-default)
            append (list (plist-get property :name)
                         (copy-tree (plist-get property :initial)))))
  "Schema-owned defaults for additional Box runtime style fields.
Reset and source-stable transfer share this registration.  Canonical Text
does not materialize these box-only placement facts.")

(defun ebox-style--border-delta-value
    (declarations full-declarations style name)
  "Return border NAME from delta, complete declarations, STYLE, or initial."
  (let* ((definition (ebox-style--property name))
         (id (plist-get definition :id)))
    (cond
     ((plist-member declarations id) (plist-get declarations id))
     ((plist-member full-declarations id) (plist-get full-declarations id))
     ((and style (ecss-computed-style-p style))
      (ebox-style-computed-value style name))
     (t (copy-tree (plist-get definition :initial))))))

(defun ebox-style--expand-engine-delta
    (declarations full-declarations current-style)
  "Project canonical DECLARATIONS against CURRENT-STYLE.
Ordinary properties remain change-local.  Border width/style pairs are
completed from FULL-DECLARATIONS and CURRENT-STYLE before deriving their used
engine pixels."
  (setq declarations (ebox-style--concrete-declarations declarations)
        full-declarations (ebox-style--concrete-declarations full-declarations))
  (let (ordinary affected-sides)
    (cl-loop for (id value) on declarations by #'cddr
             for definition = (ebox-style--property id)
             for name = (plist-get definition :name)
             for side = (cl-loop for candidate in '(top right bottom left)
                                 when (memq name
                                            (list
                                             (intern (format
                                                      ":border-%s-width"
                                                      candidate))
                                             (intern (format
                                                      ":border-%s-style"
                                                      candidate))))
                                 return candidate)
             if side do (cl-pushnew side affected-sides)
             else do (setq ordinary (append ordinary (list name value))))
    (let ((expanded (ebox-style--expand-engine-plist ordinary)))
      (dolist (side (nreverse affected-sides) expanded)
        (let ((width-name (intern (format ":border-%s-width" side)))
              (style-name (intern (format ":border-%s-style" side))))
          (setq expanded
                (append
                 expanded
                 (ebox-style--expand-engine-plist
                  (list width-name
                        (ebox-style--border-delta-value
                         declarations full-declarations
                         current-style width-name)
                        style-name
                        (ebox-style--border-delta-value
                         declarations full-declarations
                         current-style style-name))))))))))

(provide 'ebox-style)

;;; ebox-style.el ends here
