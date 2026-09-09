;;; ebox-flex.el --- Flex formatting context for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Owns flex container and item normalization, line breaking, sizing, and
;; rendering decisions.  It does not own generic property expansion or buffer
;; patch execution.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-layout-config)
(require 'ebox-layout)
(require 'ebox-size)

(declare-function ebox--flex-fragment-allocation-key
                  "ebox-fragment"
                  (source axis main cross align viewport &optional render-context))
(declare-function ebox--flex-fragment-retention-lookup
                  "ebox-fragment" (key))
(declare-function ebox--flex-fragment-retention-store
                  "ebox-fragment" (key entry side-effects))
(declare-function ebox--render-cache-render-with-scroll-actions
                  "ebox-incremental" (node))
(declare-function ebox--viewport-height-dependent-subtree-p
                  "ebox-incremental" (node))
(declare-function ebox--viewport-dependent-subtree-p
                  "ebox-incremental" (node))
(declare-function ebox--viewport-dependent-size-value-p
                  "ebox-incremental" (value &optional nil-dependent))
(declare-function ebox--render-cacheable-node-p
                  "ebox-incremental" (node))
(declare-function ebox--render-cache-node-body-signature
                  "ebox-incremental" (node))
(declare-function ebox--render-cache-node-signature
                  "ebox-incremental" (node))
(declare-function ebox--render-cache-lookup
                  "ebox-incremental" (cache-key signature))
(declare-function ebox--render-cache-store
                  "ebox-incremental"
                  (cache-key signature rendered &optional side-effects))
(declare-function ebox--render-with-cache
                  "ebox-incremental" (node &optional force cache-probe))
(declare-function ebox-node-factory--create-from-properties
                  "ebox-node-factory" (&rest plist))
(declare-function ebox-get "ebox" (box property))
(declare-function ebox--ensure-node-id "ebox" (node))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox--runtime-node-ids "ebox" (node))
(declare-function ebox-region-ids "ebox" (node))
(declare-function ebox-string-height "ebox" (string))
(declare-function ebox-string-lines "ebox" (string))
(declare-function ebox-lines-join "ebox" (lines))
(declare-function ebox--maplines "ebox" (function string))
(declare-function ebox--line-has-non-content-properties-p
                  "ebox" (line))
(declare-function ebox--line-content-metadata-uniform-p "ebox" (line))
(declare-function ebox--lines-concat-horizontal "ebox" (&rest strings))
(declare-function ebox--lines-stack-vertical "ebox" (&rest strings))
(declare-function ebox--pixel-border
                  "ebox-buffer-backend"
                  (pixel-width height &optional color))
(declare-function ebox--propertize-colors
                  "ebox-buffer-backend" (string color bgcolor))
(declare-function ebox--propertize-overline
                  "ebox-buffer-backend" (string &optional color))
(declare-function ebox--propertize-underline
                  "ebox-buffer-backend" (string &optional color))
(declare-function ebox--propertize-region
                  "ebox-buffer-backend" (string property region-id))
(declare-function ebox--propertize-content-line
                  "ebox-buffer-backend" (line region-id idx fallback))
(declare-function ebox--add-content-owner
                  "ebox-buffer-backend" (string region-id))

(defvar ebox--propertize-private-content-line-p)
(defvar ebox--flex-content-min-width-table)
(defvar ebox--render-region-id)
(defvar ebox--region-box-table)
(defvar ebox-fragment-flex-retention-rerender-count)
(defvar ebox--flex-native-size-lines-backend :unknown
  "Cached optional pure geometry backend for batched Flex line sizing.")

(defconst ebox--flex-item-prop-keys
  '(:order :flex :flex-grow :flex-shrink :flex-basis :align-self)
  "Properties that belong to flex item metadata.")

(defconst ebox--flex-container-layout-prop-keys
  '(:flex-direction :flex-wrap :flex-flow
    :justify-content :align-items :align-content
    :gap :row-gap :column-gap)
  "Properties that belong only to flex container layout.")

(defconst ebox--flex-config-prop-keys
  '(:flex-direction :flex-wrap :justify-content
    :align-items :align-content :row-gap :column-gap)
  "Canonical property order stored in a typed FlexConfig.")

(defconst ebox--flex-direction-values
  '(row row-reverse column column-reverse)
  "Supported canonical FlexConfig direction values.")

(defconst ebox--flex-wrap-values
  '(nowrap wrap wrap-reverse)
  "Supported canonical FlexConfig wrapping values.")

(defconst ebox--flex-justify-content-values
  '(normal start end flex-start flex-end center stretch
    space-between space-around space-evenly)
  "Supported canonical FlexConfig main-axis alignment values.")

(defconst ebox--flex-align-items-values
  '(normal start end stretch flex-start flex-end center baseline)
  "Supported canonical FlexConfig item alignment values.")

(defconst ebox--flex-align-content-values
  '(normal start end stretch flex-start flex-end center
    space-between space-around space-evenly)
  "Supported canonical FlexConfig line alignment values.")

(defconst ebox--flex-container-neutral-box-prop-keys
  '(:width :height :box-sizing)
  "Flex box properties that do not create visible wrapping by themselves.")

(defun ebox--build-split-attrs (items)
  "Split constructor ITEMS into (PROPS . CHILDREN)."
  (let (props children)
    (while items
      (let ((item (pop items)))
        (if (keywordp item)
            (if items
                (let ((value (pop items)))
                  (push item props)
                  (push value props))
              (error "ebox-build: missing value for %S" item))
          (push item children))))
    (cons (nreverse props) (nreverse children))))

(defun ebox--plist-keep-keys (plist keys)
  "Return a copy of PLIST containing only entries whose key is in KEYS."
  (let (result)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (when (memq key keys)
          (setq result (append result (list key value))))))
    result))

(defun ebox--plist-remove-keys (plist keys)
  "Return a copy of PLIST without entries whose key is in KEYS."
  (let (result)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (unless (memq key keys)
          (setq result (append result (list key value))))))
    result))

(defun ebox--flex-visual-box-props-p (props)
  "Return non-nil when PROPS contains visible box behavior."
  (cl-loop for (key _value) on props by #'cddr
           thereis
           (not (memq key ebox--flex-container-neutral-box-prop-keys))))

(defun ebox--preformatted-box-props (props)
  "Return PROPS with wrapping disabled unless explicitly set.
Use this when a box receives already-rendered layout text as its content.
That text is preformatted and must not be sent through the default wrapper."
  (if (plist-member props :wrap-mode)
      props
    (append props (list :wrap-mode nil))))

(defun ebox--flex-make-wrapper-box (props)
  "Return a flex container wrapper box for PROPS, or nil."
  (when (and props (ebox--flex-visual-box-props-p props))
    (when (plist-member props :content)
      (error "ebox-flex: flex cannot combine :content with child nodes"))
    (apply #'ebox-node-factory--create-from-properties
           (append (ebox--preformatted-box-props props)
                   (list :content "")))))

(defun ebox--flex-container-content-props (props raw-props wrapper-box)
  "Return flex layout PROPS adjusted to WRAPPER-BOX's content area."
  (let ((props (copy-sequence props)))
    (when wrapper-box
      (when (or (plist-member raw-props :width)
                (and (null (plist-get props :width))
                     (ebox--viewport-pixel-width nil)))
        (when-let* ((content-viewport
                    (ebox--wrapper-content-viewport-pixel wrapper-box)))
          (plist-put props :width (list 'px content-viewport))))
      (when (and (plist-member raw-props :height)
                 (ebox--resolve-size-content-height
                  wrapper-box (ebox-get wrapper-box :height) nil))
        (plist-put props :height (list 'lh (ebox--content-height wrapper-box 0)))))
    (ebox--layout-used-gaps
     props (ebox--flex-horizontal-value (plist-get props :width))
     (ebox--flex-line-value (plist-get props :height)) wrapper-box)))

(defconst ebox--preferred-size-keywords
  '(auto min-content max-content fit-content stretch)
  "Supported CSS preferred-size keywords.")

(defconst ebox--min-size-keywords
  '(auto min-content max-content fit-content stretch)
  "Supported CSS min-size keywords.")

(defconst ebox--max-size-keywords
  '(none min-content max-content fit-content stretch)
  "Supported CSS max-size keywords.")

(defun ebox--normalize-horizontal-size-value (value allowed-keywords)
  "Validate VALUE as a width-like size without resolving relative units.
ALLOWED-KEYWORDS is the CSS keyword set valid for the property being parsed."
  (cond
   ((null value) nil)
   ((memq value allowed-keywords) value)
   ((ebox-size-value-p value nil t) value)
   (t (error "ebox: unsupported size %S; use (UNIT NUMBER) or a size keyword"
             value))))

(defun ebox--flex-horizontal-value (value &optional default)
  "Resolve VALUE as horizontal pixels, or return DEFAULT when unresolved."
  (cond
   ((null value) (or default (ebox--viewport-pixel-width nil)))
   ((memq value '(auto stretch))
    (or default (ebox--viewport-pixel-width nil)))
   ((numberp value) value)
   (t (or (ebox--size-pixels value nil 'width) default))))

(defun ebox--flex-line-value (value &optional default)
  "Resolve VALUE as whole display lines, using DEFAULT when unresolved."
  (cond
   ((null value) default)
   ((eq value 'auto) default)
   ((numberp value) (max 0 (floor value)))
   ((ebox-size-value-p value nil t)
    (if-let* ((pixels (ebox--size-pixels value nil 'height)))
        (max 0 (floor (/ pixels (float (ebox--size-line-height nil)))))
      default))
   (t default)))

(defun ebox--flex-main-value (axis value &optional default)
  "Return VALUE in AXIS units."
  (if (eq axis 'row)
      (ebox--flex-horizontal-value value default)
    (ebox--flex-line-value value default)))

(defun ebox--flex-cross-value (axis value &optional default)
  "Return VALUE in cross-axis units for AXIS."
  (if (eq axis 'row)
      (ebox--flex-line-value value default)
    (ebox--flex-horizontal-value value default)))

(defun ebox--flex-gap-pair (gap)
  "Return (ROW-GAP . COLUMN-GAP) raw values from GAP shorthand."
  (cond
   ((and (proper-list-p gap)
         (= (length gap) 2)
         (not (ebox-size-value-p gap nil t)))
    (cons (nth 0 gap) (nth 1 gap)))
   (t (cons gap gap))))

(defun ebox--flex-enum-value (value default allowed property)
  "Return VALUE or DEFAULT after checking ALLOWED values for PROPERTY."
  (let ((resolved (or value default)))
    (unless (memq resolved allowed)
      (error "Ebox FlexConfig %S has invalid value: %S" property resolved))
    resolved))

(defun ebox--flex-row-gap-value (value)
  "Return canonical, unresolved FlexConfig row gap VALUE."
  (ebox-size-validate-for-axis (or value '(lh 0)) :row-gap 'block))

(defun ebox--flex-column-gap-value (value)
  "Return canonical, unresolved FlexConfig column gap VALUE."
  (ebox-size-validate-for-axis (or value '(px 0)) :column-gap 'inline))

(defun ebox--layout-used-gap (value axis available &optional box)
  "Resolve gap VALUE along AXIS against AVAILABLE using BOX font metrics.
AVAILABLE is pixels for width and display lines for height.  Indefinite
percentage gaps contribute zero.  Numbers are private, already used values."
  (if (numberp value)
      value
    (let* ((line-height (ebox--size-line-height box))
           (ebox-viewport-width (if (eq axis 'width) available
                                  ebox-viewport-width))
           (ebox--css-containing-height
            (if (eq axis 'height) (and available (* available line-height))
              ebox--css-containing-height))
           (percent-base (if (eq axis 'height)
                             (and available (* available line-height))
                           available))
           (pixels (or (ebox--size-pixels
                        (or value '(px 0)) box axis (or percent-base 0)) 0)))
      (max 0 (floor (if (eq axis 'height)
                       (/ pixels (float line-height))
                     pixels))))))

(defun ebox--layout-used-gaps (props width height &optional box)
  "Return a copy of PROPS with used gaps for WIDTH, HEIGHT, and BOX.
Only the private render configuration contains numeric gap values."
  (let ((result (copy-sequence props)))
    (plist-put result :row-gap
               (ebox--layout-used-gap (plist-get props :row-gap)
                                      'height height box))
    (plist-put result :column-gap
               (ebox--layout-used-gap (plist-get props :column-gap)
                                      'width width box))
    result))

(defun ebox--flex-normalize-config-props (props)
  "Normalize FlexConfig PROPS to explicit layout-owned fields."
  (let* ((flow (plist-get props :flex-flow))
         (flow-values (if (listp flow) flow (list flow)))
         (flow-direction (cl-find-if
                          (lambda (value)
                            (memq value '(row row-reverse column column-reverse)))
                          flow-values))
         (flow-wrap (cl-find-if
                     (lambda (value)
                       (memq value '(nowrap wrap wrap-reverse)))
                     flow-values))
         (gap-pair (ebox--flex-gap-pair (plist-get props :gap)))
         (direction
          (ebox--flex-enum-value
           (or (plist-get props :flex-direction) flow-direction)
           'row ebox--flex-direction-values :flex-direction))
         (wrap
          (ebox--flex-enum-value
           (or (plist-get props :flex-wrap) flow-wrap)
           'nowrap ebox--flex-wrap-values :flex-wrap))
         (justify
          (ebox--flex-enum-value
           (plist-get props :justify-content) 'flex-start
           ebox--flex-justify-content-values :justify-content))
         (align-items
          (ebox--flex-enum-value
           (plist-get props :align-items) 'stretch
           ebox--flex-align-items-values :align-items))
         (align-content
          (ebox--flex-enum-value
           (plist-get props :align-content) 'stretch
           ebox--flex-align-content-values :align-content))
         (row-gap
          (if (plist-member props :row-gap)
              (plist-get props :row-gap)
            (car gap-pair)))
         (column-gap
          (if (plist-member props :column-gap)
              (plist-get props :column-gap)
            (cdr gap-pair))))
    (list :flex-direction direction
          :flex-wrap wrap
          :justify-content justify
          :align-items align-items
          :align-content align-content
          :row-gap (ebox--flex-row-gap-value row-gap)
          :column-gap (ebox--flex-column-gap-value column-gap))))

(defun ebox--flex-normalize-container-props (props)
  "Normalize legacy flex container PROPS to config plus frame constraints."
  (append (ebox--flex-normalize-config-props props)
          (list :width (plist-get props :width)
                :height (plist-get props :height))))

(defconst ebox--flex-default-config-props
  (ebox--flex-normalize-config-props nil)
  "Computed default property set for FlexConfig.")

(defun ebox--flex-validate-config-input (plist)
  "Return canonical FlexConfig input PLIST after surface validation."
  (unless (and (proper-list-p plist) (zerop (% (length plist) 2)))
    (error "Ebox FlexConfig properties must be an even plist: %S" plist))
  (let ((seen (make-hash-table :test 'eq)))
    (cl-loop for (key _value) on plist by #'cddr
             unless (memq key ebox--flex-config-prop-keys)
             do (error "Ebox FlexConfig does not accept %S" key)
             do (when (gethash key seen)
                  (error "Duplicate Ebox FlexConfig property: %S" key))
             do (puthash key t seen)))
  plist)

(defun ebox-flex-layout-config-props-p (props)
  "Return non-nil when PROPS are canonical validated FlexConfig data."
  (and (proper-list-p props)
       (zerop (% (length props) 2))
       (let ((cursor props)
             (keys ebox--flex-config-prop-keys)
             valid)
         (setq valid t)
         (while (and valid keys)
           (setq valid (eq (car cursor) (car keys))
                 cursor (cddr cursor)
                 keys (cdr keys)))
         (and valid (null cursor)))
       (memq (plist-get props :flex-direction)
             ebox--flex-direction-values)
       (memq (plist-get props :flex-wrap)
             ebox--flex-wrap-values)
       (memq (plist-get props :justify-content)
             ebox--flex-justify-content-values)
       (memq (plist-get props :align-items)
             ebox--flex-align-items-values)
       (memq (plist-get props :align-content)
             ebox--flex-align-content-values)
       (let ((row-gap (plist-get props :row-gap))
             (column-gap (plist-get props :column-gap)))
         (and (ebox-size-value-for-axis-p row-gap 'block)
              (ebox-size-value-for-axis-p column-gap 'inline)))))

;;;###autoload
(defun ebox-flex-layout-create (&rest plist)
  "Return a typed FlexConfig from canonical evaluated PLIST.
PLIST accepts direction, wrap, alignment, and row/column gap longhands.
Author shorthands such as `:flex-flow' and `:gap' are normalized before this
programmatic port and are therefore rejected here."
  (ebox--flex-validate-config-input plist)
  (ebox-layout-config--create
   :kind 'flex
   :props (ebox--flex-normalize-config-props plist)))

(defun ebox--flex-axis (props)
  "Return main axis for normalized flex PROPS."
  (if (memq (plist-get props :flex-direction) '(column column-reverse))
      'column
    'row))

(defun ebox--flex-reverse-p (props)
  "Return non-nil when normalized flex PROPS reverse visual order."
  (memq (plist-get props :flex-direction) '(row-reverse column-reverse)))

(defun ebox--flex-nonnegative-factor (value property)
  "Return VALUE as a non-negative flex factor for PROPERTY."
  (unless (numberp value)
    (error "ebox: %S must be a non-negative number: %S" property value))
  (when (< value 0)
    (error "ebox: %S cannot be negative: %S" property value))
  value)

(defun ebox--flex-apply-shorthand (props)
  "Return normalized item props from raw flex item PROPS."
  (let ((order 0)
        (grow 0)
        (shrink 1)
        (basis 'auto)
        (align-self 'auto))
    (when (plist-member props :flex)
      (let ((flex (plist-get props :flex)))
        (cond
         ((numberp flex)
          (setq grow flex shrink 1 basis '(% 0)))
         ((eq flex 'none)
          (setq grow 0 shrink 0 basis 'auto))
         ((eq flex 'auto)
          (setq grow 1 shrink 1 basis 'auto))
         ((eq flex 'initial)
          (setq grow 0 shrink 1 basis 'auto))
         ((listp flex)
          (setq grow (or (nth 0 flex) grow)
                shrink (or (nth 1 flex) shrink)
                basis (if (> (length flex) 2) (nth 2 flex) basis))))))
    (when (plist-member props :order)
      (setq order (plist-get props :order)))
    (when (plist-member props :flex-grow)
      (setq grow (plist-get props :flex-grow)))
    (when (plist-member props :flex-shrink)
      (setq shrink (plist-get props :flex-shrink)))
    (when (plist-member props :flex-basis)
      (setq basis (plist-get props :flex-basis)))
    (when (plist-member props :align-self)
      (setq align-self (plist-get props :align-self)))
    (setq grow (ebox--flex-nonnegative-factor grow :flex-grow)
          shrink (ebox--flex-nonnegative-factor shrink :flex-shrink))
    (list :order (or order 0)
          :flex-grow grow
          :flex-shrink shrink
          :flex-basis (or basis 'auto)
          :align-self (or align-self 'auto))))

(defun ebox--flex-item-props (item)
  "Return normalized flex item metadata for ITEM."
  (ebox--flex-apply-shorthand (ebox--flex-participation-props item)))

(defun ebox--flex-validate-item-bases (props children)
  "Validate CHILDREN's flex bases against the parent direction in PROPS."
  (let ((axis (if (eq (ebox--flex-axis props) 'row) 'inline 'block)))
    (dolist (child children)
      (let ((basis (plist-get (ebox--flex-item-props child) :flex-basis)))
        (unless (memq basis '(auto content min-content max-content fit-content stretch))
          (ebox-size-validate-for-axis basis :flex-basis axis)))))
  children)

(defun ebox--flex-string-width (string)
  "Return STRING's layout width, excluding separately observed visible ink."
  (or (ebox--rendered-intrinsic-size string :width)
      (ebox--string-max-pixel-width string)))

(defun ebox--flex-source-width (source rendered)
  "Return SOURCE's layout width when RENDERED has no height to carry it."
  (if (and (ebox--flex-box-source-p source)
           (zerop (ebox-string-height rendered)))
      (let ((ebox--inline-auto-width-intrinsic-p t))
        (ebox--total-pixel source))
    (ebox--flex-string-width rendered)))

(defun ebox--flex-string-main (string axis)
  "Return STRING main-axis size for AXIS."
  (if (eq axis 'row)
      (ebox--flex-string-width string)
    (or (ebox--rendered-intrinsic-size string :height)
        (ebox-string-height string))))

(defun ebox--flex-string-cross (string axis)
  "Return STRING cross-axis size for AXIS."
  (if (eq axis 'row)
      (or (ebox--rendered-intrinsic-size string :height)
          (ebox-string-height string))
    (ebox--flex-string-width string)))

(defun ebox--flex-inline-viewport (axis main-size cross-size)
  "Return the inline viewport available to a flex item."
  (if (eq axis 'row)
      main-size
    cross-size))

(defun ebox--flex-composite-source-p (source)
  "Return non-nil when SOURCE is a layout subtree rather than a single box."
  (and (listp source)
       (not (stringp source))
       (when-let* ((kind (ebox-tree-layout-kind source)))
         (not (eq kind 'normal)))))

(defun ebox--flex-natural-measurement-source-p (source)
  "Return non-nil when SOURCE has a viewport-independent outer measure pass."
  (memq (ebox-tree-layout-kind source) '(normal row column)))

(defun ebox--flex-natural-render-reusable-p (source)
  "Return non-nil when SOURCE's natural render is independent of item width."
  (and (ebox--flex-natural-measurement-source-p source)
       (not (cl-some #'ebox--viewport-dependent-subtree-p
                     (ebox-tree-layout-children source)))))

(defun ebox--flex-box-source-p (source)
  "Return non-nil when SOURCE owns Box geometry for Flex sizing."
  (and (listp source)
       (not (stringp source))
       (eq (plist-get source :ebox-type) 'box)
       (not (eq (plist-get source :ebox-kind) 'text))))

(defun ebox--flex-bind-source-viewport (_source viewport thunk)
  "Call THUNK in SOURCE's detached Flex-item render context.
When VIEWPORT is non-nil it is the containing block assigned by the Flex
parent and therefore applies to SOURCE's complete subtree, including a
canonical Box with responsive descendants.  Intrinsic measurement passes nil
explicitly.  The Flex parent context is always bound because SOURCE remains a
direct Flex participant while rendered as a detached geometry root."
  (let ((ebox--render-root-parent-kind 'flex))
    (if viewport
        (let ((ebox-viewport-width viewport))
          (funcall thunk))
      (funcall thunk))))

(defvar ebox--flex-sized-render-observation-table
  (make-hash-table :test 'eq :weakness 'key)
  "Weak map from render caches to repeated composite sized-render contexts.")

(defconst ebox--flex-sized-render-observation-limit 2048
  "Maximum observed composite sized-render contexts retained per cache.")

(defun ebox--flex-scoped-sized-render-signature
    (source axis main cross align viewport)
  "Return a cache signature after SOURCE repeats in one sized VIEWPORT.
AXIS, MAIN, CROSS, and ALIGN identify the computed flex item geometry.  A
composite source is rendered with VIEWPORT bound locally, so the ambient root
width cannot affect that final output.  The first occurrence is only observed;
this avoids signature and retained-cost work for one-off responsive sizes."
  (when (and ebox--render-cache-table
             (numberp viewport)
             (or (ebox--flex-composite-source-p source)
                 (ebox--viewport-dependent-subtree-p source)))
    (let* ((observations
            (or (gethash ebox--render-cache-table
                         ebox--flex-sized-render-observation-table)
                (let ((table (make-hash-table :test 'equal)))
                  (puthash ebox--render-cache-table table
                           ebox--flex-sized-render-observation-table)
                  table)))
           (context
            (list (ebox--ensure-node-id source)
                  axis main cross align viewport
                  ebox--intrinsic-layout-measurement
                  ebox--inline-auto-width-intrinsic-p)))
      (if (gethash context observations)
          (let ((ebox-viewport-width viewport))
            (list (ebox--current-display-signature)
                  viewport ebox-viewport-height
                  ebox--intrinsic-layout-measurement
                  ebox--inline-auto-width-intrinsic-p
                  ebox--render-region-id
                  ebox--scroll-window-initial-lookahead-lines-override
                  ebox--scroll-window-render-disabled
                  (ebox--render-cache-node-body-signature source)))
        (when (>= (hash-table-count observations)
                  ebox--flex-sized-render-observation-limit)
          (clrhash observations))
        (puthash context t observations)
        nil))))

(defun ebox--flex-render-source-for-measurement (source viewport)
  "Render SOURCE for flex base-size measurement under VIEWPORT.
Direct Normal, Row, and Column boxes are measured at their natural width.
Nested Flex/Grid formatting contexts receive VIEWPORT so responsive descendants
can resolve against their containing block without conflating every non-Normal
layout with viewport dependence."
  (if (memq (ebox-tree-layout-kind source) '(flex grid))
      (ebox--flex-bind-source-viewport
       source viewport
       (lambda ()
         (let ((ebox--intrinsic-layout-measurement t))
           (ebox--render-with-cache source))))
    (ebox--flex-bind-source-viewport
     source nil
     (lambda ()
       (let ((ebox-viewport-width nil))
         (ebox--render-with-cache source))))))

(defun ebox--flex-measured-render-context-compatible-p
    (source measured-viewport final-viewport)
  "Return non-nil when SOURCE's measured render fits FINAL-VIEWPORT."
  (or (ebox--flex-natural-render-reusable-p source)
      (equal measured-viewport final-viewport)
      (not (ebox--viewport-dependent-subtree-p source))))

(defun ebox--flex-box-min-main (box rendered axis)
  "Return BOX's minimum renderable main-axis size for AXIS.
RENDERED is BOX rendered at its natural size.  Automatic minima use content
only for non-scrollable overflow; explicit minima bypass that constraint."
  (let* ((horizontal (eq axis 'row))
         (side (if horizontal (ebox--side-pixel box) (ebox--side-height box)))
         (minimum (ebox-get box (if horizontal :min-width :min-height)))
         (declared (if horizontal
                       (ebox--resolve-size-content-pixel box minimum 0)
                     (ebox--resolve-size-content-height box minimum 0)))
         (automatic (and (not (ebox--flex-explicit-min-main-p box axis))
                         (not (memq (ebox-get box :overflow)
                                    '(auto scroll hidden))))))
    (if (not automatic)
        (+ side (or declared 0))
      (let* ((content-min
              (if (and horizontal
                       (ebox-style-soft-wrap-p (ebox-get box :wrap-mode)))
                  (ebox--content-min-pixel box)
                (max 0 (- (ebox--flex-string-main rendered axis) side))))
             (preferred (ebox-get box (if horizontal :width :height)))
             (definite (and (or (numberp preferred)
                                (ebox-size-value-p preferred nil t))
                            (ebox--flex-box-main-constraint
                             box axis (if horizontal :width :height))))
             (maximum (ebox--flex-box-main-constraint
                       box axis (if horizontal :max-width :max-height))))
        (when (and horizontal (hash-table-p ebox--flex-content-min-width-table))
          (puthash box content-min ebox--flex-content-min-width-table))
        (max side (min (+ side content-min)
                       (or definite most-positive-fixnum)
                       (or maximum most-positive-fixnum)))))))

(defun ebox--flex-explicit-min-main-p (box axis)
  "Return non-nil when BOX declares a main-axis minimum explicitly."
  (not (memq (ebox-get box (if (eq axis 'row) :min-width :min-height))
             '(nil auto))))

(defun ebox--flex-box-main-constraint (box axis property)
  "Return BOX's total main-axis size constraint from PROPERTY."
  (when (plist-member box property)
    (if (eq axis 'row)
        (when-let* ((content-size
                    (ebox--resolve-size-content-pixel
                     box (ebox-get box property) nil)))
          (+ (ebox--side-pixel box) content-size))
      (when-let* ((block-size
                  (ebox--resolve-size-content-height
                   box (ebox-get box property) nil)))
        (+ (ebox--side-height box) block-size)))))

(defun ebox--flex-min-main (source rendered axis)
  "Return SOURCE's minimum main-axis size for flex layout on AXIS."
  (if (ebox--flex-box-source-p source)
      (ebox--flex-box-min-main source rendered axis)
    (ebox--flex-string-main rendered axis)))

(defun ebox--flex-max-main (source axis)
  "Return SOURCE's maximum main-axis size for flex layout on AXIS."
  (when (ebox--flex-box-source-p source)
    (ebox--flex-box-main-constraint
     source axis (if (eq axis 'row) :max-width :max-height))))

(defun ebox--flex-box-content-basis-main (box rendered axis)
  "Return BOX's flex-basis:content main size for AXIS."
  (if (eq axis 'row)
      (+ (ebox--side-pixel box)
         (ebox--content-max-pixel box))
    (ebox--flex-string-main rendered axis)))

(defun ebox--flex-basis-main (source rendered axis basis)
  "Return SOURCE's flex base size for AXIS from BASIS."
  (cond
   ((eq basis 'auto)
    (if (eq axis 'row)
        (ebox--flex-source-width source rendered)
      (ebox--flex-string-main rendered axis)))
   ((eq basis 'content)
    (if (ebox--flex-box-source-p source)
        (ebox--flex-box-content-basis-main source rendered axis)
      (ebox--flex-string-main rendered axis)))
   ((ebox--flex-box-source-p source)
    (let* ((normalized
            (ebox--normalize-horizontal-size-value
             basis ebox--preferred-size-keywords))
           (content-size
            (if (eq axis 'row)
                (or (ebox--resolve-size-content-pixel source normalized nil)
                    (ebox--content-max-pixel source))
              (or (ebox--resolve-size-content-height source normalized nil)
                  (max 0 (- (ebox--flex-string-main rendered axis)
                            (ebox--side-height source)))))))
      (+ (if (eq axis 'row) (ebox--side-pixel source)
           (ebox--side-height source)) content-size)))
   (t
    (ebox--flex-main-value axis basis 0))))

(defun ebox--flex-clamp-main (size min-main max-main)
  "Clamp SIZE by MIN-MAIN and MAX-MAIN using CSS min-wins ordering."
  (let ((min-main (max 0 (or min-main 0)))
        (size (max 0 (or size 0))))
    (max min-main
         (min (or max-main 999999999) size))))

(defun ebox--flex-recache-source-boxes (node)
  "Map rendered region ids back to source boxes in NODE."
  (when (listp node)
    (unless (and ebox--render-recached-source-node-cache
                 (gethash node ebox--render-recached-source-node-cache))
      (when ebox--render-recached-source-node-cache
        (puthash node t ebox--render-recached-source-node-cache))
      (pcase (plist-get node :ebox-type)
        ('box
         (when-let* ((region-id (ebox-get node :region-id)))
           (puthash region-id node ebox--region-box-table))
         (dolist (child (ebox-tree-node-children node))
           (ebox--flex-recache-source-boxes child)))
        ('concat
         (dolist (child (ebox--layout-children node))
           (ebox--flex-recache-source-boxes child)))
        ('stack
         (dolist (child (ebox--layout-children node))
           (ebox--flex-recache-source-boxes child)))
        ('flex
         (dolist (child (ebox-tree-layout-children node))
           (ebox--flex-recache-source-boxes child)))))))

(defun ebox--flex-box-main-margin (box axis)
  "Return BOX's total margin on AXIS."
  (if (eq axis 'row)
      (+ (ebox-get box :margin-left-pixel)
         (ebox-get box :margin-right-pixel))
    (+ (floor (ebox-get box :margin-top-height))
       (floor (ebox-get box :margin-bottom-height)))))

(defun ebox--flex-box-main-property (box axis target)
  "Return a box width/height property for margin-box TARGET on AXIS."
  (let* ((horizontal (eq axis 'row))
         (outer-size
          (if (eq (ebox-get box :box-sizing) 'border-box)
              (ebox--flex-box-main-margin box axis)
            (if horizontal
                (ebox--side-pixel box)
              (ebox--side-height box)))))
    (max 0 (- target outer-size))))

(defun ebox--flex-copy-put-size (copy property value)
  "Set COPY's layout-computed size PROPERTY to VALUE."
  (plist-put copy property value))

(defun ebox--flex-freeze-containing-sizes (source copy)
  "Freeze SOURCE's used sizes in COPY before assigning its item viewport.
Percentage edges and constraints refer to the flex container.  They must not
be recalculated against the smaller viewport assigned to the item itself."
  (dolist (property '(:padding-left-pixel :padding-right-pixel
                      :padding-top-height :padding-bottom-height
                      :margin-left-pixel :margin-right-pixel
                      :margin-top-height :margin-bottom-height
                      :border-left-pixel :border-right-pixel
                      :border-top-pixel :border-bottom-pixel))
    (when (consp (plist-get source property))
      (plist-put copy property (ebox-get source property))))
  (dolist (property '(:width :min-width :max-width :height :min-height :max-height))
    (let ((value (plist-get source property)))
      (when (consp value)
        (let* ((vertical (memq property '(:height :min-height :max-height)))
               (pixels (ebox--size-pixels value source (if vertical 'height 'width))))
          (when pixels
            (plist-put copy property
                       (if vertical (/ pixels (float (ebox--size-line-height source)))
                         pixels)))))))
  copy)

(defun ebox--flex-copy-node-for-size (node axis main cross stretch)
  "Return NODE or a copy with flex-computed MAIN/CROSS size."
  (if (ebox--flex-box-source-p node)
      (let ((copy (ebox--flex-freeze-containing-sizes
                   node (copy-sequence node))))
        (ebox--ensure-region-id node)
        (plist-put copy :region-id (ebox-get node :region-id))
        (when main
          (if (eq axis 'row)
              (ebox--flex-copy-put-size
               copy :width (ebox--flex-box-main-property node axis main))
            (ebox--flex-copy-put-size
             copy :height (ebox--flex-box-main-property node axis main))))
        (when (and cross stretch)
          (if (eq axis 'row)
              (ebox--flex-copy-put-size
               copy :height (ebox--flex-box-main-property node 'column cross))
            (ebox--flex-copy-put-size
             copy :width (ebox--flex-box-main-property node 'row cross))))
        copy)
    node))

(defun ebox--flex-measure-cacheable-p (source props)
  "Return non-nil when SOURCE and PROPS have stable flex measurements."
  (and (or (ebox--flex-natural-measurement-source-p source)
           (ebox--render-cacheable-node-p source))
       (not (ebox--viewport-dependent-size-value-p
             (plist-get props :flex-basis)))))

(defun ebox--flex-measure-cache-probe (source props axis)
  "Return one exact flex measurement cache probe for SOURCE.
The result is nil when SOURCE cannot use the persistent measurement cache;
  otherwise it carries the key, signature, and any cached measurement so a
  caller can pass the same miss context to the renderer."
  (let ((natural-source-p (ebox--flex-natural-measurement-source-p source)))
    ;; `ebox--flex-render-source-for-measurement' renders a direct Box with no
    ;; ambient inline viewport.  Compute the cache proof in that exact same
    ;; context so a root resize cannot invalidate an unchanged natural size.
    (let ((ebox-viewport-width (if natural-source-p nil ebox-viewport-width)))
      (when (ebox--flex-measure-cacheable-p source props)
        (let* ((cache-key
                (list (ebox--ensure-node-id source) 'flex-measure axis props))
               (signature (ebox--flex-render-cache-signature source)))
          (list :cache-key cache-key
                :signature signature
                :cached (ebox--render-cache-lookup cache-key signature)))))))

(defun ebox--flex-measure-cache-value (probe)
  "Return a copied cached measurement from PROBE, or nil on a miss."
  (when-let* ((cached (plist-get probe :cached)))
    (copy-sequence cached)))

(defun ebox--flex-render-cache-signature (node)
  "Return NODE's flex cache signature after stabilizing runtime identity."
  (ebox--render-cache-node-signature node))

(defun ebox--flex-cached-measurement (source props axis &optional probe)
  "Return SOURCE's warm persistent flex measurement, or nil."
  (ebox--flex-measure-cache-value
   (or probe (ebox--flex-measure-cache-probe source props axis))))

(defun ebox--flex-measure-source
    (source props axis &optional viewport probe)
  "Return intrinsic flex measurement plist for SOURCE on AXIS.
PROBE reuses the caller's exact measurement cache lookup when supplied."
  (let* ((probe (or probe (ebox--flex-measure-cache-probe source props axis)))
         (persistent-cache-key (plist-get probe :cache-key))
         (persistent-signature (plist-get probe :signature))
         (persistent-cached (plist-get probe :cached)))
    (if persistent-cached
        (copy-sequence persistent-cached)
      (let* ((rendered (progn
                         (ebox-region-ids source)
                         (prog1
                             (ebox--flex-render-source-for-measurement
                              source viewport)
                           (ebox--flex-recache-source-boxes source))))
             (rendered-main (if (eq axis 'row)
                                (ebox--flex-source-width source rendered)
                              (ebox--flex-string-main rendered axis)))
             (rendered-cross (if (eq axis 'column)
                                 (ebox--flex-source-width source rendered)
                               (ebox--flex-string-cross rendered axis)))
             (basis (plist-get props :flex-basis))
             (min-main (ebox--flex-min-main source rendered axis))
             (max-main (ebox--flex-max-main source axis))
             (base (ebox--flex-basis-main source rendered axis basis))
             (hypothetical (ebox--flex-clamp-main
                            base min-main max-main))
             (measurement (list :rendered rendered
                                :render-main rendered-main
                                :render-cross rendered-cross
                                :render-viewport viewport
                                :min-main min-main
                                :max-main max-main
                                :hypothetical hypothetical
                                :base (max 0 base)
                                :target hypothetical)))
        (when persistent-cache-key
          (ebox--render-cache-store persistent-cache-key
                                    persistent-signature
                                    measurement))
        (copy-sequence measurement)))))

(defun ebox--flex-fixed-basis-value-p (basis)
  "Return non-nil when BASIS is a context-free numeric flex size."
  (and (ebox-size-value-p basis nil t)
       (not (cl-intersection (ebox-size-dependencies basis)
                             '(percent viewport-width viewport-height)))))

(defun ebox--flex-definite-property (box axis value)
  "Return definite VALUE in AXIS units using BOX font metrics.
Context-dependent declarations remain outside the render reuse proof."
  (cond
   ((numberp value) value)
   ((ebox--flex-fixed-basis-value-p value)
    (when-let* ((pixels (ebox--size-pixels value box
                                         (if (eq axis 'row) 'width 'height))))
      (if (eq axis 'row) pixels
        (/ pixels (float (ebox--size-line-height box))))))))

(defun ebox--flex-unrendered-measurement (source props axis)
  "Return SOURCE flex metrics that do not require intrinsic rendering.
An explicit numeric basis fixes the base size.  Wrapped boxes on a row axis
derive their minimum from declared constraints and the widest grapheme, while
box heights use declared line constraints.  In those cases the final sized
render can be the first render instead of rendering the whole subtree once for
measurement and immediately rendering it again at the computed size."
  (let ((basis (plist-get props :flex-basis)))
    (when (and (ebox--flex-box-source-p source)
               (ebox--flex-fixed-basis-value-p basis)
               (if (eq axis 'row)
                   (ebox-style-soft-wrap-p (ebox-get source :wrap-mode))
                 (or (ebox--flex-explicit-min-main-p source axis)
                     (memq (ebox-get source :overflow) '(auto scroll hidden)))))
      (let* ((min-main (ebox--flex-min-main source "" axis))
             (max-main (ebox--flex-max-main source axis))
             (base (ebox--flex-basis-main source "" axis basis))
             (hypothetical
              (ebox--flex-clamp-main base min-main max-main)))
        (list :min-main min-main
              :max-main max-main
              :hypothetical hypothetical
              :base (max 0 base)
              :target hypothetical)))))

(defun ebox--flex-item-measurement (source props axis &optional viewport)
  "Return flex item metrics for SOURCE and PROPS on AXIS.
Prefer an existing complete measurement, then metadata-only fixed-basis
metrics, and render intrinsically only when layout semantics require it."
  (let* ((probe (ebox--flex-measure-cache-probe source props axis))
         (cached (ebox--flex-measure-cache-value probe)))
    (or cached
        (ebox--flex-unrendered-measurement source props axis)
        (ebox--flex-measure-source source props axis viewport probe))))

(defun ebox--flex-record-composite-intrinsic-size (rendered parts width height)
  "Record WIDTH and HEIGHT for empty RENDERED or separate PARTS extents."
  (if (or (string-empty-p rendered)
          (cl-some (lambda (part)
                     (or (ebox--rendered-intrinsic-size part :width)
                         (ebox--rendered-intrinsic-size part :height)))
                   parts))
      (ebox--record-rendered-intrinsic-size rendered width height)
    rendered))

(defun ebox--flex-pad-width (string width &optional align owner-id)
  "Pad every line of STRING to WIDTH pixels."
  (let ((align (or align 'flex-start)))
    (ebox--flex-record-composite-intrinsic-size
     (ebox--maplines
     (lambda (line)
       (let* ((line-width (ebox--string-pixel-width line))
              (extra (max 0 (- width line-width)))
              (left (pcase align
                      ((or 'flex-end 'end 'right 'self-end) extra)
                      ('center (/ extra 2))
                      (_ 0))))
         (let ((left-space (ebox-pixel-space left))
               (right-space (ebox-pixel-space (- extra left))))
           (when owner-id
             (setq left-space
                   (ebox--add-content-owner left-space owner-id))
             (setq right-space
                   (ebox--add-content-owner right-space owner-id)))
           (concat left-space line right-space))))
      string)
     (list string) width (ebox--rendered-intrinsic-size string :height))))

(defun ebox--flex-pad-height (string height offset width &optional owner-id)
  "Pad STRING vertically to HEIGHT using blank lines of WIDTH pixels."
  (let* ((lines (ebox-string-lines string))
         (current (length lines))
         (extra (max 0 (- height current)))
         (top (max 0 (min extra offset)))
         (bottom (- extra top))
         (blank (ebox-pixel-space width))
         (blank (if owner-id
                    (ebox--add-content-owner blank owner-id)
                  blank)))
    (ebox--flex-record-composite-intrinsic-size
     (ebox-lines-join
      (append (make-list top blank)
              lines
              (make-list bottom blank)))
     (list string) (ebox--rendered-intrinsic-size string :width) height)))

(defun ebox--flex-sized-entry (rendered main cross)
  "Return a sized flex render entry for RENDERED."
  (list :rendered rendered :main main :cross cross))

(defun ebox--flex-normalize-sized-entry (entry axis)
  "Return ENTRY as a sized render entry for AXIS."
  (if (and (listp entry) (plist-member entry :rendered))
      entry
    (ebox--flex-sized-entry
     entry
     (ebox--flex-string-main entry axis)
     (ebox--flex-string-cross entry axis))))

(defun ebox--flex-sized-entry-rendered (entry)
  "Return rendered string from sized ENTRY."
  (plist-get entry :rendered))

(defun ebox--flex-sized-entry-cross (entry)
  "Return cross-axis size from sized ENTRY."
  (plist-get entry :cross))

(defun ebox--flex-horizontal-sized-lines (rendered width height)
  "Return RENDERED lines padded to HEIGHT using known WIDTH."
  (let* ((lines (ebox-string-lines rendered))
         (current (length lines)))
    (if (>= current height)
        lines
      (append lines
              (make-list (- height current)
                         (ebox-pixel-space width))))))

(defun ebox--flex-lines-concat-horizontal-sized (parts &optional target-height)
  "Concatenate PARTS horizontally using known part widths.
Each item in PARTS is a cons cell (RENDERED . WIDTH)."
  (setq parts (cl-remove-if-not #'car parts))
  (when parts
    (let* ((height
            (max (or target-height 0)
                 (apply #'max
                        (mapcar (lambda (part)
                                  (ebox-string-height (car part)))
                                parts))))
           (line-lists
            (mapcar (lambda (part)
                      (ebox--flex-horizontal-sized-lines
                       (car part) (cdr part) height))
                    parts)))
      (ebox-lines-join
       (apply #'cl-mapcar #'concat line-lists)))))

(defun ebox--flex-cross-offset (align extra)
  "Return cross-axis offset for ALIGN and EXTRA space."
  (pcase align
    ((or 'flex-end 'end 'self-end 'right 'bottom) extra)
    ('center (/ extra 2))
    (_ 0)))

(defun ebox--flex-resolved-align (item container-align)
  "Return ITEM align-self resolved against CONTAINER-ALIGN."
  (let ((align (plist-get (plist-get item :props) :align-self)))
    (if (or (null align) (eq align 'auto))
        container-align
      align)))

(defun ebox--flex-pad-sized-entry-cross (entry axis main cross align)
  "Return sized ENTRY padded to CROSS for AXIS and ALIGN."
  (let ((rendered (ebox--flex-sized-entry-rendered entry))
        (entry-main (plist-get entry :main))
        (entry-cross (ebox--flex-sized-entry-cross entry)))
    (if (eq axis 'row)
        (let* ((rendered-width (ebox--flex-string-width rendered))
               (width (max (or main rendered-width) rendered-width))
               (extra (max 0 (- cross entry-cross)))
               (offset (ebox--flex-cross-offset align extra)))
          (ebox--flex-sized-entry
           (ebox--flex-pad-height rendered cross offset width)
           (or main entry-main)
           cross))
      (ebox--flex-sized-entry
       (ebox--flex-pad-width rendered cross align)
       (or main entry-main)
       cross))))

(defun ebox--flex-render-sized-entry (item axis main cross container-align)
  "Render flex ITEM with MAIN and optional CROSS size.
Return a sized render entry containing the rendered string and dimensions."
  (let* ((source (plist-get item :source))
         (source-box-p (ebox--flex-box-source-p source))
         (allocation-owner
          (and source-box-p (ebox--ensure-region-id source)))
         (align (ebox--flex-resolved-align item container-align))
         (stretch (memq align '(stretch normal)))
         (render-main (plist-get item :render-main))
         (render-cross (plist-get item :render-cross))
         (render-viewport (plist-get item :render-viewport))
         (item-viewport (ebox--flex-inline-viewport axis main cross))
         (can-use-measured
          (and (plist-member item :rendered)
               (or (null main) (= main render-main))
               (or (not (and cross stretch))
                   (null cross)
                   (= cross render-cross))
               (ebox--flex-measured-render-context-compatible-p
                source render-viewport item-viewport)))
         (cache-key (list axis main cross align))
         (render-cache (plist-get item :render-cache))
         (cached (assoc cache-key render-cache))
         (natural-cached
          (and cross
               (assoc (list axis main nil align) render-cache)))
         (natural-entry
          (and natural-cached
               (ebox--flex-normalize-sized-entry
                (cdr natural-cached) axis)))
         (natural-viewport
          (and natural-entry
               (ebox--flex-inline-viewport axis main nil)))
         (natural-context-compatible-p
          (and natural-entry
               (ebox--flex-measured-render-context-compatible-p
                source natural-viewport item-viewport)))
         (local-entry
          (or (and cached
                   (ebox--flex-normalize-sized-entry (cdr cached) axis))
              (and natural-context-compatible-p
                   (= cross (ebox--flex-sized-entry-cross natural-entry))
                   (or (not stretch)
                       (not source-box-p)
                       ;; A definite cross size already equal to the assigned
                       ;; Box property leaves its complete geometry unchanged.
                       ;; Auto/relative sizes and overflow-expanded output
                       ;; still need the final stretched Box render.
                       (let ((declared-cross
                              (ebox--flex-definite-property
                               source (if (eq axis 'row) 'column 'row)
                               (ebox-get source (if (eq axis 'row)
                                                    :height :width)))))
                         (and (numberp declared-cross)
                              (= declared-cross
                                 (ebox--flex-box-main-property
                                  source (if (eq axis 'row) 'column 'row)
                                  cross)))))
                   natural-entry)))
         (persistent-signature
          (and (not local-entry)
               (or (and (ebox--render-cacheable-node-p source)
                        (ebox--flex-render-cache-signature source))
                   (ebox--flex-scoped-sized-render-signature
                    source axis main cross align item-viewport))))
         (persistent-cache-key
          (and persistent-signature
               (list (ebox--ensure-node-id source)
                     'flex-sized axis main cross align
                     (and (ebox--flex-composite-source-p source)
                          ebox--intrinsic-layout-measurement))))
         (persistent-cached
          (and persistent-cache-key
               (ebox--render-cache-lookup persistent-cache-key
                                          persistent-signature))))
    (cond
     (local-entry
      (prog1 local-entry
        (ebox--flex-recache-source-boxes source)))
     (persistent-cached
      (let ((entry
             (ebox--flex-normalize-sized-entry persistent-cached axis)))
        (plist-put item :render-cache
                   (cons (cons cache-key entry)
                         (plist-get item :render-cache)))
        (prog1 entry
          (ebox--flex-recache-source-boxes source))))
     ((and natural-context-compatible-p
           (> cross (ebox--flex-sized-entry-cross natural-entry))
           (or (not stretch)
               (not source-box-p)))
      (let ((entry
             (ebox--flex-pad-sized-entry-cross
              natural-entry axis main cross align)))
        (ebox--flex-recache-source-boxes source)
        (plist-put item :render-cache
                   (cons (cons cache-key entry)
                         (plist-get item :render-cache)))
        (when persistent-cache-key
          (ebox--render-cache-store persistent-cache-key
                                    persistent-signature
                                    entry))
        entry))
     (t
      (let* ((node (unless can-use-measured
                     (ebox--flex-copy-node-for-size
                      source axis main cross stretch)))
             (fragment-key
              (and (not can-use-measured)
                   (listp source)
                   (not (stringp source))
                   (numberp item-viewport)
                   (ebox--flex-fragment-allocation-key
                    source axis main cross align item-viewport
                    (list :intrinsic-layout-measurement
                          ebox--intrinsic-layout-measurement
                          :inline-auto-width-intrinsic
                          ebox--inline-auto-width-intrinsic-p
                          :scroll-window-render-disabled
                          ebox--scroll-window-render-disabled
                          :viewport-height-dependent
                          (if (fboundp
                               'ebox--viewport-height-dependent-subtree-p)
                              (ebox--viewport-height-dependent-subtree-p source)
                            :unknown)))))
             (fragment-entry
              (and fragment-key
                   (ebox--flex-fragment-retention-lookup fragment-key)))
             fragment-side-effects
             (rendered
              (cond
               (can-use-measured
                (plist-get item :rendered))
               (fragment-entry
                (ebox--flex-sized-entry-rendered fragment-entry))
               ((and fragment-key
                     (fboundp 'ebox--render-cache-render-with-scroll-actions))
                (ebox--flex-bind-source-viewport
                 source item-viewport
                 (lambda ()
                   (pcase-let ((`(,captured-rendered ,captured-side-effects)
                                (ebox--render-cache-render-with-scroll-actions
                                 (or node source))))
                     (setq fragment-side-effects captured-side-effects)
                     captured-rendered))))
               (t
                (ebox--flex-bind-source-viewport
                 source item-viewport
                 (lambda () (ebox--render-node (or node source))))))))
        (ebox--flex-recache-source-boxes source)
        (when (and (not fragment-entry)
                   main
                   (not (and can-use-measured (= main render-main))))
          (if (eq axis 'row)
              (setq rendered
                    (ebox--flex-pad-width
                     rendered main nil allocation-owner))
            (setq rendered
                  (ebox--flex-pad-height
                   rendered main 0 (ebox--flex-string-width rendered)))))
        (when (and (not fragment-entry)
                   cross
                   (not (and can-use-measured (= cross render-cross))))
          (if (eq axis 'row)
              (let* ((rendered-width
                      (if can-use-measured
                          render-main
                        (ebox--flex-string-width rendered)))
                      (width (max (or main rendered-width) rendered-width))
                      (extra (max 0 (- cross (ebox-string-height rendered))))
                      (offset (ebox--flex-cross-offset align extra)))
                (setq rendered
                      (ebox--flex-pad-height
                       rendered cross offset width allocation-owner)))
            (setq rendered
                  (ebox--flex-pad-width
                   rendered cross align allocation-owner))))
        (let ((entry
               (ebox--flex-sized-entry
                rendered
                (or (and fragment-entry (plist-get fragment-entry :main))
                    (if (eq axis 'row)
                        (or main (if can-use-measured
                                     render-main
                                   (ebox--flex-string-width rendered)))
                      (or main (ebox--flex-string-main rendered axis))))
                (or (and fragment-entry (plist-get fragment-entry :cross))
                    (if (eq axis 'row)
                        (or cross (if can-use-measured
                                      render-cross
                                    (ebox--flex-string-cross rendered axis)))
                      (or cross (if can-use-measured
                                    render-cross
                                  (ebox--flex-string-width rendered))))))))
          (plist-put item :render-cache
                     (cons (cons cache-key entry)
                           (plist-get item :render-cache)))
          (when (and fragment-key (not fragment-entry))
            (cl-incf ebox-fragment-flex-retention-rerender-count)
            (ebox--flex-fragment-retention-store
             fragment-key entry fragment-side-effects))
          (when persistent-cache-key
            (ebox--render-cache-store persistent-cache-key
                                      persistent-signature
                                      entry))
          entry))))))

(defun ebox--flex-render-sized-item (item axis main cross container-align)
  "Render flex ITEM with MAIN and optional CROSS size."
  (ebox--flex-sized-entry-rendered
   (ebox--flex-render-sized-entry item axis main cross container-align)))

(defun ebox--flex-distribute (amount weights)
  "Distribute AMOUNT across WEIGHTS, retaining fractional free space.
Whole amounts retain the established deterministic remainder order."
  (let* ((amount (max 0 amount))
         (positive (cl-remove-if-not (lambda (weight) (> weight 0)) weights))
         (total (apply #'+ (or positive '(0)))))
    (cond
     ((or (<= amount 0) (<= total 0)) (make-list (length weights) 0))
     ((/= amount (floor amount))
      (mapcar (lambda (weight) (* amount (/ (float (max 0 weight)) total)))
              weights))
     (t
      (setq amount (floor amount))
      (let* ((shares
              (mapcar (lambda (weight)
                        (if (> weight 0)
                            (floor (/ (* amount (float weight)) total))
                          0))
                      weights))
             (remaining (- amount (apply #'+ shares))))
        (while (> remaining 0)
          (cl-loop for weight in weights
                   for cell on shares
                   while (> remaining 0)
                   when (> weight 0)
                   do (cl-incf (car cell))
                   and do (cl-decf remaining)))
        shares)))))

(defun ebox--flex-sum (numbers)
  "Return the sum of NUMBERS."
  (apply #'+ (or numbers '(0))))

(defun ebox--flex-factor (item mode)
  "Return ITEM's raw flex factor for MODE."
  (plist-get (plist-get item :props)
             (if (eq mode 'grow) :flex-grow :flex-shrink)))

(defun ebox--flex-distribution-weight (item mode)
  "Return ITEM's flex free-space distribution weight for MODE."
  (if (eq mode 'grow)
      (ebox--flex-factor item mode)
    (* (plist-get item :base)
       (ebox--flex-factor item mode))))

(defun ebox--flex-effective-free-space (initial-free free factor-total)
  "Return FREE adjusted by the Flexbox partial-fill rule."
  (if (and (> factor-total 0) (< factor-total 1))
      (let ((partial (* initial-free factor-total)))
        (if (< (abs partial) (abs free))
            partial
          free))
    free))

(defun ebox--flex-line-free-space (line targets frozen available)
  "Return free space in LINE using flex bases for unfrozen items."
  (- available
     (cl-loop for item in line
              for index from 0
              sum (if (aref frozen index)
                      (aref targets index)
                    (plist-get item :base)))))

(defun ebox--flex-collect-items (children axis &optional viewport)
  "Return sorted flex item metadata from CHILDREN for AXIS."
  (let ((items
         (cl-loop for child in children
                  for index from 0
                  for source = child
                  for props = (ebox--flex-item-props child)
                  for measurement = (ebox--flex-item-measurement
                                     source props axis viewport)
                  collect (append (list :source source
                                        :props props
                                        :index index)
                                  measurement))))
    (sort items
          (lambda (a b)
            (let ((ao (plist-get (plist-get a :props) :order))
                  (bo (plist-get (plist-get b :props) :order)))
              (if (= ao bo)
                  (< (plist-get a :index) (plist-get b :index))
                (< ao bo)))))))

(defun ebox--flex-default-order-p (children)
  "Return non-nil when CHILDREN use source order without item ordering."
  (cl-every (lambda (child)
              (= (plist-get (ebox--flex-item-props child) :order) 0))
            children))

(defun ebox--flex-collect-items-for-source-ids
    (children source-ids axis &optional viewport)
  "Return flex item metadata for SOURCE-IDS only, preserving child order."
  (let ((source-set (make-hash-table :test 'equal))
        items)
    (dolist (source-id source-ids)
      (puthash source-id t source-set))
    (cl-loop for child in children
             for index from 0
             for source = child
             for source-id = (plist-get source :node-id)
             when (gethash source-id source-set)
             do (let* ((props (ebox--flex-item-props child))
                       (measurement (ebox--flex-item-measurement
                                     source props axis viewport)))
                  (push (append (list :source source
                                      :props props
                                      :index index)
                                measurement)
                        items)))
    (nreverse items)))

(defun ebox--flex-item-source-ids (items)
  "Return source node ids for flex ITEMS."
  (mapcar (lambda (item)
            (plist-get (plist-get item :source) :node-id))
          items))

(defun ebox--flex-break-lines (items main-limit main-gap wrap)
  "Break ITEMS into flex lines using MAIN-LIMIT, MAIN-GAP, and WRAP."
  (if (or (eq wrap 'nowrap) (null main-limit))
      (list items)
    (let (lines current current-size)
      (dolist (item items)
        (let* ((base (plist-get item :hypothetical))
               (next-size (+ (or current-size 0)
                             (if current main-gap 0)
                             base)))
          (if (and current (> next-size main-limit))
              (progn
                (push (nreverse current) lines)
                (setq current (list item)
                      current-size base))
            (push item current)
            (setq current-size next-size))))
      (when current
        (push (nreverse current) lines))
      (nreverse lines))))

(defun ebox--flex-native-size-lines-backend ()
  "Return the optional native Flex geometry function, or nil."
  (when (eq ebox--flex-native-size-lines-backend :unknown)
    (setq ebox--flex-native-size-lines-backend
          (when (require 'ebox-native-reflow nil t)
            (when (and (fboundp 'ebox-native-reflow-layout-ready-p)
                       (ebox-native-reflow-layout-ready-p)
                       (fboundp 'ebox-native-reflow-flex-size-lines))
              #'ebox-native-reflow-flex-size-lines))))
  (unless (eq ebox--flex-native-size-lines-backend :unknown)
    ebox--flex-native-size-lines-backend))

(defun ebox--flex-size-lines (lines main-limit main-gap)
  "Return sized copies for LINES using the pure geometry boundary when safe.
The Elisp scalar algorithm remains the exact fallback and owns all item
metadata and rendering decisions."
  (or (when (and main-limit (integerp main-gap))
        (when-let* ((backend (ebox--flex-native-size-lines-backend)))
          (funcall backend lines main-limit main-gap)))
      (mapcar (lambda (line)
                (ebox--flex-size-line line main-limit main-gap))
              lines)))

(defun ebox--flex-size-line (line main-limit main-gap)
  "Return LINE items with computed target main sizes."
  (let* ((count (length line))
         (gap-total (* main-gap (max 0 (1- count))))
         (available (and main-limit (- main-limit gap-total)))
         (targets (vconcat (mapcar (lambda (item)
                                      (plist-get item :hypothetical))
                                    line))))
    (when available
      (let* ((hypothetical-total
              (ebox--flex-sum (mapcar (lambda (item)
                                         (plist-get item :hypothetical))
                                       line)))
             (mode (if (< hypothetical-total available) 'grow 'shrink))
             (frozen (make-vector count nil)))
        (cl-loop for item in line
                 for index from 0
                 for base = (plist-get item :base)
                 for hypothetical = (plist-get item :hypothetical)
                 for factor = (ebox--flex-factor item mode)
                 do (aset targets index base)
                 when (or (<= (or factor 0) 0)
                          (and (eq mode 'grow) (> base hypothetical))
                          (and (eq mode 'shrink) (< base hypothetical)))
                 do (progn
                      (aset targets index hypothetical)
                      (aset frozen index t)))
        (let ((initial-free
               (ebox--flex-line-free-space line targets frozen available)))
          (let ((done nil))
            (while (not done)
              (let* ((free (ebox--flex-line-free-space
                            line targets frozen available))
                     (active-indices
                      (cl-loop for index below count
                               unless (aref frozen index)
                               collect index))
                     (weights
                      (mapcar
                       (lambda (index)
                         (ebox--flex-distribution-weight (nth index line) mode))
                       active-indices))
                     (weight-total (ebox--flex-sum weights))
                     (factor-total
                      (ebox--flex-sum
                       (mapcar (lambda (index)
                                 (ebox--flex-factor (nth index line) mode))
                               active-indices)))
                     (effective-free
                      (ebox--flex-effective-free-space
                       initial-free free factor-total)))
                (cond
                 ((or (null active-indices)
                      (<= weight-total 0)
                      (and (eq mode 'grow) (< effective-free 0))
                      (and (eq mode 'shrink) (> effective-free 0)))
                  (setq done t))
                 (t
                  (let ((deltas (ebox--flex-distribute
                                 (abs effective-free) weights))
                        min-violations
                        max-violations
                        (total-violation 0))
                    (cl-mapc
                     (lambda (index delta)
                       (let* ((item (nth index line))
                              (base (plist-get item :base))
                              (candidate (if (eq mode 'grow)
                                             (+ base delta)
                                           (- base delta)))
                              (clamped (ebox--flex-clamp-main
                                        candidate
                                        (plist-get item :min-main)
                                        (plist-get item :max-main)))
                              (adjustment (- clamped candidate)))
                         (aset targets index clamped)
                         (cond
                          ((> adjustment 0)
                           (push index min-violations))
                          ((< adjustment 0)
                           (push index max-violations)))
                         (cl-incf total-violation adjustment)))
                     active-indices deltas)
	                    (cond
	                     ((= total-violation 0)
	                      (dolist (index active-indices)
	                        (aset frozen index t)))
	                     ((> total-violation 0)
	                      (dolist (index (or min-violations active-indices))
	                        (aset frozen index t)))
	                     (t
	                      (dolist (index (or max-violations active-indices))
	                        (aset frozen index t)))))))))))))
    (setq targets (vconcat (ebox-size-quantize (append targets nil))))
    (cl-loop for item in line
             for index from 0
             collect (let ((copy (copy-sequence item)))
                       (plist-put copy :target (aref targets index))
                       copy))))

(defun ebox--flex-line-main-size (line main-gap)
  "Return total main size for LINE."
  (+ (apply #'+ (mapcar (lambda (item)
                          (plist-get item :target))
                        line))
     (* main-gap (max 0 (1- (length line))))))

(defun ebox--flex-spacing (mode leftover count base-gap)
  "Return (LEADING BETWEEN TRAILING) spacing for MODE."
  (setq leftover (max 0 leftover))
  (pcase mode
    ((or 'flex-end 'end 'right 'bottom)
     (list leftover base-gap 0))
    ('center
     (let ((lead (/ leftover 2)))
       (list lead base-gap (- leftover lead))))
    ('space-between
     (if (> count 1)
         (list 0 (+ base-gap (/ leftover (1- count))) 0)
       (list 0 base-gap leftover)))
    ('space-around
     (let* ((unit (if (> count 0) (/ leftover count) 0))
            (lead (/ unit 2)))
       (list lead (+ base-gap unit) (- leftover lead (* unit (max 0 (1- count)))))))
    ('space-evenly
     (let ((unit (if (> count 0) (/ leftover (1+ count)) 0)))
       (list unit (+ base-gap unit) unit)))
    (_ (list 0 base-gap leftover))))

(defun ebox--flex-line-cross (line axis container-align)
  "Return natural cross size for LINE."
  (let ((sizes
         (mapcar
          (lambda (item)
            (ebox--flex-sized-entry-cross
             (ebox--flex-render-sized-entry
              item axis (plist-get item :target) nil container-align)))
          line)))
    (apply #'max (or sizes '(0)))))

(defun ebox--flex-layout-cross (crosses container-cross cross-gap align single-line)
  "Return plist describing cross-axis line placement."
  (let* ((count (length crosses))
         (natural (+ (apply #'+ crosses)
                     (* cross-gap (max 0 (1- count)))))
         (leftover (if container-cross (- container-cross natural) 0)))
    (cond
     ((and container-cross single-line (= count 1))
      (list :crosses (list container-cross)
            :leading 0 :between cross-gap :trailing 0))
     ((and container-cross (> leftover 0) (memq align '(stretch normal)))
      (let ((extra (ebox--flex-distribute leftover (make-list count 1))))
        (list :crosses (cl-mapcar #'+ crosses extra)
              :leading 0 :between cross-gap :trailing 0)))
     (t
      (let ((spacing (ebox--flex-spacing align leftover count cross-gap)))
        (list :crosses crosses
              :leading (nth 0 spacing)
              :between (nth 1 spacing)
              :trailing (nth 2 spacing)))))))

(defun ebox--flex-render-row-line (line line-cross main-size main-gap justify align)
  "Render one row-axis flex LINE."
  (let* ((line-main (ebox--flex-line-main-size line main-gap))
         (target-main (or main-size line-main))
         (leftover (- target-main line-main))
         (spacing (ebox--flex-spacing justify leftover (length line) main-gap))
         (leading (nth 0 spacing))
         (between (nth 1 spacing))
         (trailing (nth 2 spacing))
         (parts (when (> leading 0)
                  (list (cons (ebox--pixel-blank leading line-cross) leading)))))
    (cl-loop for item in line
             for tail on line
             for main = (plist-get item :target)
             for entry = (ebox--flex-render-sized-entry
                          item 'row main line-cross align)
             do (push (cons (ebox--flex-sized-entry-rendered entry)
                            main)
                      parts)
             when (and (cdr tail) (> between 0))
             do (push (cons (ebox--pixel-blank between line-cross) between) parts))
    (when (> trailing 0)
      (push (cons (ebox--pixel-blank trailing line-cross) trailing) parts))
    (setq parts (nreverse parts))
    (ebox--flex-record-composite-intrinsic-size
     (ebox--flex-lines-concat-horizontal-sized parts line-cross)
     (mapcar #'car parts) target-main line-cross)))

(defun ebox--flex-render-column-line (line line-cross main-size main-gap justify align)
  "Render one column-axis flex LINE."
  (let* ((line-main (ebox--flex-line-main-size line main-gap))
         (target-main (or main-size line-main))
         (leftover (- target-main line-main))
         (spacing (ebox--flex-spacing justify leftover (length line) main-gap))
         (leading (nth 0 spacing))
         (between (nth 1 spacing))
         pieces)
    (when (> leading 0)
      (push (ebox--pixel-blank line-cross leading) pieces))
    (cl-loop for item in line
             for tail on line
             do (push (ebox--flex-render-sized-item
                       item 'column (plist-get item :target) line-cross align)
                      pieces)
             unless (null (cdr tail))
             do (when (> between 0)
                  (push (ebox--pixel-blank line-cross between) pieces)))
    (setq pieces (nreverse pieces))
    (let ((result (apply #'ebox--lines-stack-vertical pieces)))
      (ebox--flex-record-composite-intrinsic-size
       (ebox--flex-pad-height result target-main 0 line-cross)
       pieces line-cross target-main))))

(defun ebox--render-flex-row (lines props main-size cross-size main-gap cross-gap)
  "Render flex LINES for a row-axis container."
  (let* ((align (plist-get props :align-items))
         (justify (plist-get props :justify-content))
         (align-content (plist-get props :align-content))
         (single-line (eq (plist-get props :flex-wrap) 'nowrap))
         (sized (ebox--flex-size-lines lines main-size main-gap))
         (line-mains (mapcar (lambda (line)
                               (ebox--flex-line-main-size line main-gap))
                             sized))
         (container-main (or main-size (apply #'max (or line-mains '(0)))))
         (crosses (if (and cross-size single-line)
                      (list cross-size)
                    (mapcar (lambda (line)
                              (ebox--flex-line-cross line 'row align))
                            sized)))
         (cross-layout (ebox--flex-layout-cross
                        crosses cross-size cross-gap align-content
                        single-line))
         (adjusted-crosses (plist-get cross-layout :crosses))
         (leading (plist-get cross-layout :leading))
         (between (plist-get cross-layout :between))
         (rendered-lines
          (cl-mapcar (lambda (line cross)
                       (ebox--flex-render-row-line
                        line cross container-main main-gap justify align))
                     sized adjusted-crosses))
         pieces)
    (when (> leading 0)
      (push (ebox--pixel-blank container-main leading) pieces))
    (cl-loop for rendered in rendered-lines
             for tail on rendered-lines
             do (push rendered pieces)
             unless (null (cdr tail))
             do (when (> between 0)
                  (push (ebox--pixel-blank container-main between) pieces)))
    (let ((result (apply #'ebox--lines-stack-vertical (nreverse pieces))))
      (ebox--flex-record-composite-intrinsic-size
       (if cross-size
           (ebox--flex-pad-height result cross-size 0 container-main)
         result)
       rendered-lines container-main
       (or cross-size (+ leading (ebox--flex-sum adjusted-crosses)
                         (* between (max 0 (1- (length adjusted-crosses))))
                         (plist-get cross-layout :trailing)))))))

(defun ebox--render-flex-column (lines props main-size cross-size main-gap cross-gap)
  "Render flex LINES for a column-axis container."
  (let* ((align (plist-get props :align-items))
         (justify (plist-get props :justify-content))
         (align-content (plist-get props :align-content))
         (single-line (eq (plist-get props :flex-wrap) 'nowrap))
         (sized (ebox--flex-size-lines lines main-size main-gap))
         (crosses (if (and cross-size single-line)
                      (list cross-size)
                    (mapcar (lambda (line)
                              (ebox--flex-line-cross line 'column align))
                            sized)))
         (cross-layout (ebox--flex-layout-cross
                        crosses cross-size cross-gap align-content
                        single-line))
         (adjusted-crosses (plist-get cross-layout :crosses))
         (leading (plist-get cross-layout :leading))
         (between (plist-get cross-layout :between))
         (rendered-columns
          (cl-mapcar (lambda (line cross)
                       (ebox--flex-render-column-line
                        line cross main-size main-gap justify align))
                     sized adjusted-crosses))
         (height (max (or main-size 0)
                      (apply #'max (mapcar #'ebox-string-height
                                          (or rendered-columns '(""))))))
         (parts (when (> leading 0)
                  (list (ebox--pixel-blank leading height)))))
    (cl-loop for rendered in rendered-columns
             for tail on rendered-columns
             do (push rendered parts)
             when (and (cdr tail) (> between 0))
             do (push (ebox--pixel-blank between height) parts))
    (let ((result (apply #'ebox--lines-concat-horizontal (nreverse parts))))
      (ebox--flex-record-composite-intrinsic-size
       (if cross-size
           (ebox--flex-pad-width result cross-size)
         result)
       rendered-columns
       (or cross-size (+ leading (ebox--flex-sum adjusted-crosses)
                         (* between (max 0 (1- (length adjusted-crosses))))
                         (plist-get cross-layout :trailing)))
       (or main-size
           (apply #'max (mapcar (lambda (column)
                                  (ebox--flex-string-main column 'column))
                                (or rendered-columns '("")))))))))

(defun ebox--render-flex-box (node rendered)
  "Render flex NODE's container box around RENDERED, when present."
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

(defun ebox--render-flex-children (config constraints children &optional box)
  "Render Flex CONFIG under resolved CONSTRAINTS over flat CHILDREN.
Width is in pixels and height in lines; nil means unbounded, including an
intrinsic max-content measurement.  Author units and viewport defaults have
already been resolved by the Box or legacy adapter.  BOX supplies font metrics."
  (let* ((constraints
          (list :width (when-let* ((width (plist-get constraints :width)))
                         (floor width))
                :height (when-let* ((height (plist-get constraints :height)))
                          (floor height))))
         (props (ebox--layout-used-gaps
                config (plist-get constraints :width)
                (plist-get constraints :height) box))
         (axis (ebox--flex-axis props))
         (main-size (if (eq axis 'row)
                        (plist-get constraints :width)
                      (plist-get constraints :height)))
         (cross-size (if (eq axis 'row)
                         (plist-get constraints :height)
                       (plist-get constraints :width)))
         ;; Nil is an explicit unbounded containing block, not permission for
         ;; a deeper responsive Flex to recover this Box's outer viewport.
         (ebox-viewport-width (plist-get constraints :width))
         (ebox--css-containing-height
          (and (plist-get constraints :height)
               (* (plist-get constraints :height) (ebox--size-line-height box))))
         (inline-viewport (ebox--flex-inline-viewport
                           axis main-size cross-size))
         (items (ebox--flex-collect-items children axis inline-viewport))
         (items (if (ebox--flex-reverse-p props)
                    (nreverse items)
                  items))
         (row-gap (or (ebox--flex-line-value (plist-get props :row-gap) 0) 0))
         ;; Only this private used configuration contains numeric gaps.
         (column-gap (or (plist-get props :column-gap) 0))
         (main-gap (if (eq axis 'row) column-gap row-gap))
         (cross-gap (if (eq axis 'row) row-gap column-gap))
         (lines (ebox--flex-break-lines
                 items main-size main-gap (plist-get props :flex-wrap))))
    (when (eq (plist-get props :flex-wrap) 'wrap-reverse)
      (setq lines (nreverse lines)))
    (if (eq axis 'row)
        (ebox--render-flex-row lines props main-size cross-size
                               main-gap cross-gap)
      (ebox--render-flex-column lines props main-size cross-size
                                main-gap cross-gap))))

(defun ebox--flex-box-constraints (box)
  "Project BOX content dimensions to resolved private FlexConstraints."
  (list :width (ebox--wrapper-content-viewport-pixel box)
        :height (when-let* ((height (ebox--resolve-size-content-height
                                    box (ebox-get box :height) nil)))
                  (floor height))))

(defun ebox--flex-legacy-constraints (props)
  "Resolve legacy PROPS' author units and defaults to FlexConstraints."
  (list :width (ebox--flex-horizontal-value (plist-get props :width))
        :height (ebox--flex-line-value (plist-get props :height))))

(defun ebox--render-flex-box-children (box props children)
  "Render canonical BOX Flex PROPS over flat CHILDREN."
  (ebox--render-flex-children
   props
   (ebox--flex-box-constraints box)
   children box))

(defun ebox--render-flex (node)
  "Render legacy flex NODE to a propertized string."
  (let ((props (ebox--flex-container-content-props
                (plist-get node :props)
                (plist-get node :raw-props)
                (plist-get node :box))))
    (ebox--render-flex-box
     node
     (ebox--render-flex-children
      (ebox--plist-remove-keys props '(:width :height))
      (ebox--flex-legacy-constraints props)
      (ebox-tree-layout-children node)))))

(defun ebox--flex-prewarm-sized-item (node _target-width)
  "Prepare one fixed-cross flex item phase and yield to the event loop.
Intrinsic measurement and final sized rendering each process one child per
slice.  The prefix-local state retains geometry between slices, while sized
renders enter the ordinary persistent cache so the final full flex render only
assembles already-rendered items."
  (let ((entry (gethash node ebox--scroll-window-prewarm-state)))
    (unless entry
      (let* ((props (ebox--flex-container-content-props
                     (plist-get node :props)
                     (plist-get node :raw-props)
                     (plist-get node :box)))
             (axis (ebox--flex-axis props))
         (children (ebox-tree-layout-children node))
             (main-size (ebox--flex-main-value
                         axis (plist-get props
                                         (if (eq axis 'row)
                                             :width :height))))
             (cross-size (ebox--flex-cross-value
                          axis (plist-get props
                                          (if (eq axis 'row)
                                              :height :width))))
             (wrap (plist-get props :flex-wrap)))
        (when (and main-size cross-size
                   (eq wrap 'nowrap)
                   (> (length children) 1)
                   (not (ebox--flex-reverse-p props))
                   (ebox--flex-default-order-p children))
          (let* ((row-gap (or (ebox--flex-line-value
                               (plist-get props :row-gap) 0) 0))
                 (column-gap (or (plist-get props :column-gap) 0)))
            (setq entry
                  (list :children children
                        :measure-index 0
                        :measured nil
                        :items nil
                        :render-index 0
                        :axis axis
                        :main-size main-size
                        :main-gap (if (eq axis 'row) column-gap row-gap)
                        :cross-size cross-size
                        :align (plist-get props :align-items)
                        :viewport
                        (ebox--flex-inline-viewport
                         axis main-size cross-size)))
            (puthash node entry ebox--scroll-window-prewarm-state)))))
    (when entry
      (let* ((children (plist-get entry :children))
             (measure-index (plist-get entry :measure-index)))
        (cond
         ((< measure-index (length children))
          (let* ((child (nth measure-index children))
                 (source child)
                 (props (ebox--flex-item-props child))
                 (measurement
                  (ebox--flex-item-measurement
                   source props (plist-get entry :axis)
                   (plist-get entry :viewport))))
            (plist-put entry :measured
                       (cons (append (list :source source
                                           :props props
                                           :index measure-index)
                                     measurement)
                             (plist-get entry :measured)))
            (plist-put entry :measure-index (1+ measure-index))
            t))
         (t
          (unless (plist-get entry :items)
            (plist-put entry :items
                       (ebox--flex-size-line
                        (nreverse (plist-get entry :measured))
                        (plist-get entry :main-size)
                        (plist-get entry :main-gap))))
          (let* ((items (plist-get entry :items))
                 (render-index (plist-get entry :render-index)))
            (when (< render-index (length items))
              (let ((item (nth render-index items)))
                (ebox--flex-render-sized-entry
                 item (plist-get entry :axis) (plist-get item :target)
                 (plist-get entry :cross-size) (plist-get entry :align)))
              (plist-put entry :render-index (1+ render-index))
              t))))))))

(defun ebox--flex-window-canonical-node-p (node)
  "Return non-nil when NODE is one canonical Flex Layout Box."
  (and (eq (plist-get node :ebox-kind) 'box)
       (when-let* ((config (plist-get node :ebox-layout-config)))
         (eq (ebox-layout-config-kind config) 'flex))))

(defun ebox--flex-window-box (node)
  "Return NODE's Box wrapper for lazy Flex rendering."
  (if (ebox--flex-window-canonical-node-p node)
      node
    (plist-get node :box)))

(defun ebox--flex-window-props (node)
  "Return NODE's Flex properties with resolved dimensions for lazy rows."
  (if (ebox--flex-window-canonical-node-p node)
      (let ((constraints (ebox--flex-box-constraints node)))
        (append
         (ebox--layout-used-gaps
          (ebox-layout-config-props (plist-get node :ebox-layout-config))
          (plist-get constraints :width) (plist-get constraints :height) node)
         constraints))
    (let ((props (ebox--flex-container-content-props
                  (plist-get node :props)
                  (plist-get node :raw-props)
                  (plist-get node :box))))
      (append (ebox--plist-remove-keys props '(:width :height))
              (ebox--flex-legacy-constraints props)))))

(defun ebox--flex-window-wrapper-supported-p (box)
  "Return non-nil when BOX can safely wrap an incomplete flex prefix."
  (or (null box)
      (and (memq (ebox-get box :height) '(nil auto))
           (or (memq (ebox-get box :min-height) '(nil auto))
               (equal (ebox-get box :min-height) 0)
               (and (ebox-size-value-p (ebox-get box :min-height) nil t)
                    (equal (ebox--size-pixels
                            (ebox-get box :min-height) box 'height) 0)))
           (memq (ebox-get box :max-height) '(nil none))
           (or (ebox-style-no-soft-wrap-p (ebox-get box :wrap-mode))
               (ebox--flex-window-canonical-node-p box))
           (eq (ebox-get box :text-align) 'left)
           (eq (ebox-get box :vertical-align) 'top))))

(defun ebox--flex-window-wrapper-copy (box complete)
  "Return BOX copy adjusted for a flex prefix.
When COMPLETE is nil, trailing vertical chrome is suppressed so the result is
a prefix of the eventual full wrapper render."
  (let ((copy (copy-sequence box)))
    (when (ebox--flex-window-canonical-node-p copy)
      ;; The lazy producer has already rendered the Flex children.  Lower the
      ;; private wrapper copy to Normal content so the generic Box painter
      ;; applies only this Box's chrome and ownership once.
      (cl-remf copy :children)
      (cl-remf copy :ebox-child-sequence)
      (plist-put copy :ebox-layout-config (ebox-normal-layout-create))
      (plist-put copy :display
                 (list (or (car-safe (plist-get copy :display)) 'block)
                       'flow)))
    (unless complete
      (plist-put copy :padding-bottom-height 0)
      (plist-put copy :margin-bottom-height 0)
      (plist-put copy :border-bottom-pixel 0))
    copy))

(defun ebox--flex-window-complete-prefix-supported-p (box)
  "Return non-nil when BOX completion can patch an existing prefix."
  (or (null box)
      (and (= (floor (ebox-get box :padding-bottom-height)) 0)
           (= (floor (ebox-get box :margin-bottom-height)) 0))))

(defun ebox--flex-window-complete-tail-line (box line)
  "Return LINE with BOX's completion-only bottom border applied."
  (if (not box)
      line
    (let ((region-id (ebox--ensure-region-id box)))
      (puthash region-id box ebox--region-box-table)
      (if (> (ebox-get box :border-bottom-pixel) 0)
          (propertize
           (ebox--propertize-underline
            line (ebox-get box :border-bottom-color))
           'ebox-bb region-id)
        line))))

(defun ebox--flex-window-complete-prefix-lines (box lines &optional line-tail)
  "Return complete wrapper LINES by adding bottom border chrome for BOX."
  (if (not box)
      lines
    (progn
      (when lines
        (let ((tail (or line-tail (last lines))))
          (setcar tail
                  (ebox--flex-window-complete-tail-line
                   box (car tail)))))
      lines)))

(defun ebox--flex-window-render-box-lines (node content complete limit)
  "Return NODE flex wrapper lines around CONTENT up to LIMIT."
  (let* ((rendered
          (if-let* ((box (ebox--flex-window-box node)))
              (let ((copy (ebox--flex-window-wrapper-copy box complete))
                    (region-id (ebox--ensure-region-id box)))
                (plist-put copy :region-id region-id)
                (plist-put copy :content content)
                (plist-put copy :ebox-content-node nil)
                (plist-put copy :ebox-content-width-exact-p t)
                (prog1 (ebox--render-node copy)
                  (puthash region-id box ebox--region-box-table)))
            content))
         (lines (ebox-string-lines rendered)))
    (seq-take lines limit)))

(defun ebox--flex-window-render-wrapper-chunk-lines
    (box content-lines start-index include-top)
  "Render BOX wrapper around newly appended CONTENT-LINES.
START-INDEX is the first content-line index inside BOX.  INCLUDE-TOP means
the chunk begins at the wrapper top and should include top chrome."
  (if (not box)
      content-lines
    (let* ((region-id (ebox--ensure-region-id box))
           (content-pixel (ebox--content-pixel box))
           (padding-line-filler (ebox-pixel-space content-pixel))
           (padding-left (ebox-get box :padding-left-pixel))
           (padding-right (ebox-get box :padding-right-pixel))
           (padding-top (if include-top
                            (floor (ebox-get box :padding-top-height))
                          0))
           (margin-left (ebox-get box :margin-left-pixel))
           (margin-right (ebox-get box :margin-right-pixel))
           (margin-top (if include-top
                           (floor (ebox-get box :margin-top-height))
                         0))
           (border-left-pixel (ebox-get box :border-left-pixel))
           (border-left-color (ebox-get box :border-left-color))
           (border-right-pixel (ebox-get box :border-right-pixel))
           (border-right-color (ebox-get box :border-right-color))
           (border-top-p (and include-top
                              (> (ebox-get box :border-top-pixel) 0)))
           (border-top-color (ebox-get box :border-top-color))
           (color (and (ebox-style--text-paint-owner-p box)
                       (ebox-get box :color)))
           (bgcolor (ebox-get box :bgcolor))
           (inner-height (+ (length content-lines) padding-top))
           result)
      (puthash region-id box ebox--region-box-table)
      (if (and (= margin-left 0)
               (= margin-right 0)
               (= margin-top 0))
          (ebox--window-render-flat-wrapper-chunk-lines
           box content-lines start-index region-id padding-line-filler
           include-top)
        (progn
          (setq result
                (ebox-lines-join
                 (cl-loop for line in content-lines
                          for idx from start-index
                          collect (ebox--propertize-content-line
                                   line region-id idx padding-line-filler))))
        (setq result
              (ebox--maplines
               (lambda (line)
                 (if (and (string-empty-p (string-trim line))
                          (ebox--line-content-metadata-uniform-p line)
                          (not (ebox--line-has-non-content-properties-p line)))
                     (let ((content-id
                            (get-text-property 0 'ebox-content line))
                           (content-idx
                            (get-text-property 0 'ebox-content-idx line)))
                       (if content-id
                           (propertize padding-line-filler
                                       'ebox-content content-id
                                       'ebox-content-idx content-idx
                                       'ebox-content-owner region-id)
                         (propertize padding-line-filler
                                     'ebox-content region-id
                                     'ebox-content-idx 0
                                     'ebox-content-owner region-id)))
                   line))
               result))
        (when (> padding-top 0)
          (setq result
                (ebox--lines-stack-vertical
                 (ebox--propertize-region
                  (ebox--pixel-blank content-pixel padding-top)
                  'ebox-pt region-id)
                 result)))
        (let ((pl-str (when (> padding-left 0)
                        (ebox--propertize-region
                         (ebox--pixel-blank padding-left inner-height)
                         'ebox-pl region-id)))
              (pr-str (when (> padding-right 0)
                        (ebox--propertize-region
                         (ebox--pixel-blank padding-right inner-height)
                         'ebox-pr region-id))))
          (when (or pl-str pr-str)
            (setq result
                  (ebox--lines-concat-horizontal pl-str result pr-str))))
        (when (or color bgcolor)
          (setq result
                (ebox--maplines
                 (lambda (line)
                   (ebox--propertize-colors line color bgcolor))
                 result)))
        (when (or (> border-left-pixel 0) (> border-right-pixel 0))
          (let ((bl-str (when (> border-left-pixel 0)
                          (ebox--propertize-region
                           (ebox--pixel-border border-left-pixel
                                               inner-height border-left-color)
                           'ebox-bl region-id)))
                (br-str (when (> border-right-pixel 0)
                          (ebox--propertize-region
                           (ebox--pixel-border border-right-pixel
                                               inner-height border-right-color)
                           'ebox-br region-id))))
            (setq result
                  (ebox--lines-concat-horizontal bl-str result br-str))))
        (when border-top-p
          (let ((lines (ebox-string-lines result)))
            (setf (car lines)
                  (propertize
                   (ebox--propertize-overline (car lines) border-top-color)
                   'ebox-bt region-id))
            (setq result (ebox-lines-join lines))))
        (ebox--apply-surface-properties
         result (ebox-get box :surface-properties))
        (when (or (> margin-left 0) (> margin-right 0))
          (let* ((box-height (ebox-string-height result))
                 (ml-str (when (> margin-left 0)
                           (ebox--propertize-region
                            (ebox--pixel-blank margin-left box-height)
                            'ebox-ml region-id)))
                 (mr-str (when (> margin-right 0)
                           (ebox--propertize-region
                            (ebox--pixel-blank margin-right box-height)
                            'ebox-mr region-id))))
            (setq result
                  (ebox--lines-concat-horizontal ml-str result mr-str))))
        (when (> margin-top 0)
          (setq result
                (ebox--lines-stack-vertical
                 (ebox--propertize-region
                  (ebox--pixel-blank (ebox--total-pixel box) margin-top)
                  'ebox-mt region-id)
                 result)))
          (ebox-string-lines result))))))

(defun ebox--flex-window-definite-main (source axis)
  "Return SOURCE's definite main size for prefix flex rendering."
  (when (and (eq axis 'row)
             (ebox--flex-box-source-p source)
             (plist-member source :width))
    (ebox--flex-box-main-constraint source axis :width)))

(defun ebox--flex-window-cheap-item (child axis index)
  "Return cheap flex item metadata for CHILD, or nil when unsupported."
  (let* ((source child)
         (props (ebox--flex-item-props child))
         (basis (plist-get props :flex-basis))
         (main (ebox--flex-window-definite-main source axis))
         (measurement
          (and (null main)
               (ebox--flex-cached-measurement source props axis)))
         (main (or main (plist-get measurement :hypothetical))))
    (when (and source
               main
               (= (or (plist-get props :order) 0) 0)
               (= (or (plist-get props :flex-grow) 0) 0)
               (eq basis 'auto))
      (if measurement
          (append (list :source source :props props :index index)
                  measurement)
        ;; The frozen definite width is only legal while its line does
        ;; not overflow: a wrapping box with nonzero flex-shrink would
        ;; compress in the full renderer, so mark it for the line
        ;; assembler's overflow check.
        (list :source source
              :props props
              :index index
              :min-main main
              :max-main main
              :hypothetical main
              :base main
              :target main
              :window-frozen-shrinkable
              (and (ebox-style-soft-wrap-p
                    (ebox-get source :wrap-mode))
                   (not (zerop (or (plist-get props :flex-shrink) 1)))
                   t))))))

(defun ebox--flex-window-supported-p
    (node props axis main-size cross-size children)
  "Return non-nil when NODE can use prefix flex rendering."
  (and (eq axis 'row)
       main-size
       (null cross-size)
       (memq (plist-get props :flex-wrap) '(wrap nowrap))
       (not (ebox--flex-reverse-p props))
       (ebox--flex-default-order-p children)
       (ebox--flex-window-wrapper-supported-p
        (ebox--flex-window-box node))))

(defun ebox--flex-window-lines-from-pieces (pieces)
  "Return flex content string from already rendered row PIECES."
  (if pieces
      (apply #'ebox--lines-stack-vertical (reverse pieces))
    ""))

(defun ebox--flex-window-top-chrome-lines (box)
  "Return wrapper top chrome line count for partial flex rendering."
  (if box
      (+ (floor (ebox-get box :margin-top-height))
         (floor (ebox-get box :padding-top-height)))
    0))

(defun ebox--flex-window-prefix-line-count (node pieces)
  "Return visible line count for NODE prefix PIECES without wrapper rerender."
  (+ (ebox--flex-window-top-chrome-lines (ebox--flex-window-box node))
     (if pieces
         (ebox-string-height
          (ebox--flex-window-lines-from-pieces pieces))
       0)))

(defun ebox--flex-window-cacheable-p (node)
  "Return non-nil when NODE flex window output can use render cache."
  (and ebox--render-cache-table
       (ebox--render-cacheable-node-p node)))

(defun ebox--flex-window-cache-context (node)
  "Return render cache context for NODE's flex window output."
  (when (ebox--flex-window-cacheable-p node)
    (list :node-id (ebox--ensure-node-id node)
          :signature (ebox--flex-render-cache-signature node))))

(defun ebox--flex-window-cache-lookup (node limit &optional cache-context)
  "Return cached flex window render for NODE and LIMIT, or nil."
  (when-let* ((cache-context
              (or cache-context (ebox--flex-window-cache-context node))))
    (let* ((node-id (plist-get cache-context :node-id))
           (signature (plist-get cache-context :signature))
           (complete-key (list node-id 'flex-window 'complete))
           (complete (ebox--render-cache-lookup complete-key signature)))
      (or (when complete
            (let* ((lines (plist-get complete :lines))
                   (line-count (or (plist-get complete :line-count)
                                   (length lines)))
                   (result-lines (if (<= line-count limit)
                                     lines
                                   (seq-take lines limit)))
                   (result-count (min line-count limit)))
              (list :lines result-lines
                    :line-count result-count
                    :line-tail (if (= result-count line-count)
                                   (or (plist-get complete :line-tail)
                                       (last lines))
                                 (last result-lines))
                    :complete (<= line-count limit)
                    :completion-prefix-tail-rewrite-count
                    (plist-get
                     complete :completion-prefix-tail-rewrite-count))))
          (when-let* ((prefix (ebox--render-cache-lookup
                              (list node-id 'flex-window 'prefix)
                              signature)))
            (let* ((lines (plist-get prefix :lines))
                   (line-count (or (plist-get prefix :line-count)
                                   (length lines))))
              (when (>= line-count limit)
                (let ((result-lines
                       (if (= line-count limit)
                           lines
                         (seq-take lines limit))))
                  (list :lines result-lines
                        :line-count limit
                        :line-tail (if (= line-count limit)
                                       (or (plist-get prefix :line-tail)
                                           (last lines))
                                     (last result-lines))
                        :complete nil)))))
          (when-let* ((exact
                      (ebox--render-cache-lookup
                       (list node-id 'flex-window limit)
                       signature)))
            (let* ((lines (plist-get exact :lines))
                   (line-count (or (plist-get exact :line-count)
                                   (length lines))))
              ;; An incomplete result that did not fill LIMIT must resume
              ;; from the prefix seed instead of becoming a permanent
              ;; no-progress exact-limit hit.
              (when (or (plist-get exact :complete)
                        (>= line-count limit))
                exact)))))))

(defun ebox--flex-window-prefix-cache-lookup (node &optional cache-context)
  "Return NODE's cached incomplete flex prefix state, or nil."
  (when-let* ((cache-context
              (or cache-context (ebox--flex-window-cache-context node))))
    (let* ((node-id (plist-get cache-context :node-id))
           (signature (plist-get cache-context :signature)))
      (ebox--render-cache-lookup
       (list node-id 'flex-window 'prefix)
       signature))))

(defun ebox--flex-window-prefix-cache-store
    (node pieces next-index result &optional cache-context)
  "Store NODE incomplete flex prefix PIECES through NEXT-INDEX."
  (when-let* ((cache-context
              (and result
                   (or cache-context
                       (ebox--flex-window-cache-context node)))))
    (let* ((node-id (plist-get cache-context :node-id))
           (signature (plist-get cache-context :signature)))
      (ebox--render-cache-store
       (list node-id 'flex-window 'prefix)
       signature
       (list :pieces pieces
             :piece-count (length pieces)
             :next-index next-index
             :lines (plist-get result :all-lines)
             :line-count (plist-get result :all-line-count)
             :line-tail (plist-get result :all-line-tail)
             :content-lines (plist-get result :content-lines)
             :content-line-count
             (plist-get result :content-line-count)
             :content-line-tail
             (plist-get result :content-line-tail)
             :prefix-line-count
             (plist-get result :all-line-count)))))
  result)

(defun ebox--flex-window-cache-store
    (node limit result &optional cache-context)
  "Store NODE flex window RESULT for LIMIT when possible."
  (when-let* ((cache-context
              (and result
                   (or cache-context
                       (ebox--flex-window-cache-context node)))))
    (let* ((node-id (plist-get cache-context :node-id))
           (signature (plist-get cache-context :signature))
           (key (if (plist-get result :source-complete)
                    (list node-id 'flex-window 'complete)
                  (list node-id 'flex-window limit))))
      (ebox--render-cache-store
       key signature
       (list :lines (if (plist-get result :source-complete)
                        (plist-get result :all-lines)
                      (plist-get result :lines))
             :line-count (if (plist-get result :source-complete)
                             (plist-get result :all-line-count)
                           (plist-get result :line-count))
             :line-tail (if (plist-get result :source-complete)
                            (plist-get result :all-line-tail)
                          (plist-get result :line-tail))
             :complete (plist-get result :source-complete)
             :completion-prefix-tail-rewrite-count
             (plist-get result
                        :completion-prefix-tail-rewrite-count)))))
  result)

(defun ebox--flex-window-completion-prefix-tail-rewrite-count (node)
  "Return how many cached prefix tail lines completion rewrites for NODE."
  (let ((box (ebox--flex-window-box node)))
    (if (and box
             (> (ebox-get box :border-bottom-pixel) 0)
             (= (floor (ebox-get box :padding-bottom-height)) 0))
        1
      0)))

(defun ebox--flex-window-result (node pieces source-complete limit
                                      &optional seed)
  "Return flex window result for NODE prefix PIECES."
  (let* ((cached-lines (plist-get seed :lines))
         (cached-line-count
          (or (plist-get seed :line-count)
              (length cached-lines)))
         (cached-line-tail
          (or (plist-get seed :line-tail)
              (last cached-lines)))
         (cached-content-lines (plist-get seed :content-lines))
         (cached-content-count
          (or (plist-get seed :content-line-count)
              (length cached-content-lines)))
         (cached-content-tail
          (or (plist-get seed :content-line-tail)
              (last cached-content-lines)))
         (cached-piece-count
          (or (plist-get seed :piece-count)
              (length (plist-get seed :pieces))))
         (piece-count (length pieces))
         (new-piece-count (- piece-count cached-piece-count))
         (can-append
          (and cached-lines
               cached-content-lines
               (>= new-piece-count 0)))
         (seedless-chunk-p
          (and (null seed)
               (> piece-count 0)))
         (chunk-wrapper-p
          (or can-append seedless-chunk-p))
         (new-content-lines
          (when (and chunk-wrapper-p (> new-piece-count 0))
            (ebox-string-lines
             (ebox--flex-window-lines-from-pieces
              (seq-take pieces new-piece-count)))))
         (content
          (unless chunk-wrapper-p
            (ebox--flex-window-lines-from-pieces pieces)))
         (prospective-content-count
          (if chunk-wrapper-p
              (+ cached-content-count (length new-content-lines))
            (length (ebox-string-lines content))))
         (prefix-line-count
          (+ (ebox--flex-window-top-chrome-lines
              (ebox--flex-window-box node))
             prospective-content-count))
         (source-complete-visible-p
          (and source-complete
               (> prefix-line-count limit)))
         (effective-source-complete
          (and source-complete
               (not source-complete-visible-p)))
         (wrapper-lines
          (and chunk-wrapper-p new-content-lines
               (ebox--flex-window-render-wrapper-chunk-lines
                (ebox--flex-window-box node)
                new-content-lines cached-content-count seedless-chunk-p)))
         (prospective-line-count
          (+ cached-line-count (length wrapper-lines)))
         (completion-prefix-supported-p
          (and chunk-wrapper-p effective-source-complete
               (ebox--flex-window-complete-prefix-supported-p
                (ebox--flex-window-box node))))
         (exact-append-p
          (or completion-prefix-supported-p
              (and chunk-wrapper-p (not effective-source-complete))))
         (fallback-content
          (unless exact-append-p
            (or content (ebox--flex-window-lines-from-pieces pieces))))
         (fallback-content-lines
          (and fallback-content (ebox-string-lines fallback-content)))
         (fallback-lines
          (unless exact-append-p
            (ebox--flex-window-render-box-lines
             node fallback-content effective-source-complete
             most-positive-fixnum)))
         (prospective-tail
          (or (last wrapper-lines) cached-line-tail))
         (completed-tail-line
          (and completion-prefix-supported-p prospective-tail
               (ebox--flex-window-complete-tail-line
                (ebox--flex-window-box node) (car prospective-tail))))
         content-lines
         content-line-count
         content-line-tail
         all-lines
         all-line-count
         all-line-tail
         appended-lines)
    ;; Wrapper rendering, full fallback rendering, and completion face
    ;; construction above can signal.  Mutate cached prefixes only after all
    ;; of them have succeeded so cache count/tail metadata remains atomic.
    (if exact-append-p
        (let ((inhibit-quit t))
          (pcase-let ((`(,new-lines ,new-tail)
                       (ebox--line-list-append!
                        cached-content-lines cached-content-tail
                        new-content-lines)))
            (setq content-lines new-lines
                  content-line-tail new-tail
                  content-line-count prospective-content-count))
          (pcase-let ((`(,new-lines ,new-tail)
                       (ebox--line-list-append!
                        cached-lines cached-line-tail wrapper-lines)))
            (setq all-lines new-lines
                  all-line-tail new-tail
                  all-line-count prospective-line-count
                  appended-lines wrapper-lines))
          (when completed-tail-line
            (setcar all-line-tail completed-tail-line)))
      (setq content-lines fallback-content-lines
            content-line-count (length fallback-content-lines)
            content-line-tail (last fallback-content-lines)
            all-lines fallback-lines
            all-line-count (length fallback-lines)
            all-line-tail (last fallback-lines)
            appended-lines nil))
      (let* ((result-lines (if (<= all-line-count limit)
                               all-lines
                             (seq-take all-lines limit)))
             (result-count (min all-line-count limit))
             (result-tail (if (= result-count all-line-count)
                              all-line-tail
                            (last result-lines)))
             (rewrite-count
              (if (and completion-prefix-supported-p
                       (= result-count cached-line-count))
                  (ebox--flex-window-completion-prefix-tail-rewrite-count
                   node)
                0))
             (rewrite-range
              (and (> rewrite-count 0)
                   (cons (- cached-line-count rewrite-count)
                         cached-line-count)))
             (event-append-count (- result-count cached-line-count))
             (event-appended-lines
              (and (>= event-append-count 0)
                   (eq result-lines all-lines)
                   (seq-take appended-lines
                             event-append-count)))
             (prefix-exact-p
              (and can-append
                   (eq result-lines cached-lines)
                   (<= cached-line-count result-count))))
        (list :lines result-lines
              :line-count result-count
              :line-tail result-tail
              :all-lines all-lines
              :all-line-count all-line-count
              :all-line-tail all-line-tail
              :content-lines content-lines
              :content-line-count content-line-count
              :content-line-tail content-line-tail
              :source-complete effective-source-complete
              :complete (and effective-source-complete
                             (<= all-line-count limit))
              :completion-prefix-tail-rewrite-count rewrite-count
              :prefix-delta
              (list :exact-p prefix-exact-p
                    :base-count cached-line-count
                    :rewrite-range rewrite-range
                    :rewrite-lines
                    (and rewrite-range
                         (if (= rewrite-count 1)
                             (list (car result-tail))
                           (seq-subseq result-lines
                                       (car rewrite-range)
                                       (cdr rewrite-range))))
                    :append-lines event-appended-lines)))))

(defun ebox--render-flex-window-lines (node limit)
  "Render NODE's row-wrap flex prefix up to LIMIT lines.
Return nil when the flex container needs the normal full renderer."
  (let ((cache-context (ebox--flex-window-cache-context node)))
    (or (ebox--flex-window-cache-lookup node limit cache-context)
        (ebox--flex-window-cache-store
         node limit
         (catch 'unsupported
           (let* ((props (ebox--flex-window-props node))
                  (axis (ebox--flex-axis props))
                  (children (ebox-tree-layout-children node))
                  (main-size (if (eq axis 'row)
                                 (plist-get props :width)
                               (plist-get props :height)))
                  (cross-size (if (eq axis 'row)
                                  (plist-get props :height)
                                (plist-get props :width)))
                  (wrap (plist-get props :flex-wrap)))
             (unless (ebox--flex-window-supported-p
                      node props axis main-size cross-size children)
               (throw 'unsupported nil))
             (let* ((align (plist-get props :align-items))
                    (justify (plist-get props :justify-content))
                    (row-gap (or (ebox--flex-line-value
                                  (plist-get props :row-gap) 0)
                                 0))
                    (column-gap (or (plist-get props :column-gap) 0))
                    (main-gap column-gap)
                    (cross-gap row-gap)
                    current
                    current-size
                    (seed (ebox--flex-window-prefix-cache-lookup
                           node cache-context))
                    (pieces (copy-sequence (plist-get seed :pieces)))
                    (index (or (plist-get seed :next-index) 0))
                    (visible-line-count
                     (or (plist-get seed :prefix-line-count)
                         (ebox--flex-window-top-chrome-lines
                          (ebox--flex-window-box node))))
                    result
                    complete)
               (cl-labels
                   ((flush-line ()
                      (when current
                        (let ((add-gap (and pieces (> cross-gap 0))))
                          (when add-gap
                            (push (ebox--pixel-blank main-size cross-gap)
                                  pieces))
                        ;; Match the full renderer's content containing block
                        ;; only while sizing/rendering children.  The wrapper
                        ;; below still resolves against its outer viewport.
                        (let* ((ebox-viewport-width main-size)
                               (line (nreverse current))
                               (line-main
                                (+ (cl-reduce
                                    #'+ line
                                    :key (lambda (item)
                                           (plist-get item :base))
                                    :initial-value 0)
                                   (* main-gap
                                      (max 0 (1- (length line))))))
                               (sized
                                (progn
                                  ;; A frozen definite width cannot
                                  ;; shrink here, but the full renderer
                                  ;; would compress it on an overflowing
                                  ;; line; publishing the frozen
                                  ;; geometry would diverge, so use the
                                  ;; full-render fallback instead.
                                  (when (and (> line-main main-size)
                                             (cl-some
                                              (lambda (item)
                                                (plist-get
                                                 item
                                                 :window-frozen-shrinkable))
                                              line))
                                    (throw 'unsupported nil))
                                  (ebox--flex-size-line
                                   line main-size main-gap)))
                               (line-cross (ebox--flex-line-cross
                                            sized 'row align))
                               (rendered
                                (ebox--flex-render-row-line
                                 sized line-cross main-size main-gap justify
                                 align)))
                            (push rendered pieces)
                            (setq visible-line-count
                                  (+ visible-line-count
                                     (if add-gap cross-gap 0)
                                     (ebox-string-height rendered)))))
                        (setq current nil
                              current-size nil))))
                 (catch 'enough
                   (while (< index (length children))
                     (let* ((child (nth index children))
                            (item (let ((ebox-viewport-width main-size))
                                    (or (ebox--flex-window-cheap-item
                                         child axis index)
                                        (throw 'unsupported nil))))
                            (base (plist-get item :hypothetical))
                            (next-size (+ (or current-size 0)
                                          (if current main-gap 0)
                                          base)))
                       (if (and current
                                (not (eq wrap 'nowrap))
                                (> next-size main-size))
                           (progn
                             (flush-line)
                             (when (>= visible-line-count limit)
                               (setq result
                                     (ebox--flex-window-result
                                      node pieces nil limit seed))
                               (ebox--flex-window-prefix-cache-store
                                node pieces index result cache-context)
                               (throw 'enough nil))
                             (setq current (list item)
                                   current-size base)
                             (setq index (1+ index)))
                         (push item current)
                         (setq current-size next-size)
                         (setq index (1+ index)))))
                   (flush-line)
                   (setq complete t))
                 (or result
                     (setq result
                           (ebox--flex-window-result
                            node pieces complete limit seed)))
                 (if (plist-get result :source-complete)
                     (ebox--flex-window-cache-store
                      node limit result cache-context)
                   (ebox--flex-window-prefix-cache-store
                    node pieces index result cache-context))))))
         cache-context))))

(ebox--register-window-line-renderer 'flex #'ebox--render-flex-window-lines)
(ebox--register-window-line-prewarmer 'flex #'ebox--flex-prewarm-sized-item)

(defun ebox--flex-render-row-line-for-child-ids
    (node child-ids &optional min-item-main)
  "Return a row-line render plist for CHILD-IDS inside flex NODE.
MIN-ITEM-MAIN is the old row's summed item footprint.  When supplied, the
known-row render is used only if the new item footprint is not smaller."
  (let* ((props (ebox--flex-container-content-props
                 (plist-get node :props)
                 (plist-get node :raw-props)
                 (plist-get node :box)))
         (axis (ebox--flex-axis props))
         (wrap (plist-get props :flex-wrap))
         (main-size (ebox--flex-horizontal-value (plist-get props :width)))
         (cross-size nil))
    (when (and child-ids
               main-size
               (eq axis 'row)
               (memq wrap '(wrap nowrap))
               (null (ebox--flex-line-value (plist-get props :height)))
               (not (ebox--flex-reverse-p props)))
      (let* ((children (ebox-tree-layout-children node))
             (inline-viewport (ebox--flex-inline-viewport
                               axis main-size cross-size))
             (row-gap (or (ebox--flex-line-value
                           (plist-get props :row-gap) 0)
                          0))
             (column-gap (or (plist-get props :column-gap) 0))
             (main-gap column-gap))
        (when (ebox--flex-default-order-p children)
          (let* ((items (ebox--flex-collect-items-for-source-ids
                         children child-ids axis inline-viewport))
                 (item-ids (ebox--flex-item-source-ids items))
                 (gap-total (* main-gap (max 0 (1- (length items)))))
                 (line-main (ebox--flex-line-main-size items main-gap))
                 (item-main (- line-main gap-total)))
            (when (and (= (length items) (length child-ids))
                       (equal item-ids child-ids)
                       (or (= (length items) 1)
                           (<= line-main main-size))
                       (or (null min-item-main)
                           (>= item-main min-item-main)))
              (let* ((sized (ebox--flex-size-line items main-size main-gap))
                     (align (plist-get props :align-items))
                     (justify (plist-get props :justify-content))
                     (line-cross (ebox--flex-line-cross sized 'row align))
                     (rendered
                      (ebox--flex-render-row-line
                       sized line-cross main-size main-gap justify align)))
                (list :rendered rendered
                      :item-ids (ebox--flex-item-source-ids sized)
                      :main main-size
                      :cross line-cross
                      :row-gap row-gap
                      :known-row-rerender t)))))))))

(defun ebox--flex-render-row-line-for-child (node child-id)
  "Return a row-line render plist for CHILD-ID inside flex NODE.
Return nil when NODE's flex configuration needs a full rerender."
  (let* ((props (ebox--flex-container-content-props
                 (plist-get node :props)
                 (plist-get node :raw-props)
                 (plist-get node :box)))
         (axis (ebox--flex-axis props))
         (wrap (plist-get props :flex-wrap))
         (main-size (ebox--flex-horizontal-value (plist-get props :width))))
    (when (and (eq axis 'row)
               (memq wrap '(wrap nowrap))
               main-size
               (null (ebox--flex-line-value (plist-get props :height))))
      (let* ((children (ebox-tree-layout-children node))
             (cross-size nil)
             (inline-viewport (ebox--flex-inline-viewport
                               axis main-size cross-size))
             (items (ebox--flex-collect-items children axis inline-viewport))
             (items (if (ebox--flex-reverse-p props)
                        (nreverse items)
                      items))
             (row-gap (or (ebox--flex-line-value
                           (plist-get props :row-gap) 0)
                          0))
             (column-gap (or (plist-get props :column-gap) 0))
             (main-gap column-gap)
             (lines (ebox--flex-break-lines items main-size main-gap wrap)))
        (when (eq wrap 'wrap-reverse)
          (setq lines (nreverse lines)))
        (when-let* ((line
                    (cl-find-if
                     (lambda (candidate)
                       (cl-some
                        (lambda (item)
                          (equal (plist-get
                                  (plist-get item :source)
                                  :node-id)
                                 child-id))
                        candidate))
                     lines)))
          (let* ((sized (ebox--flex-size-line line main-size main-gap))
                 (line-mains
                  (mapcar (lambda (candidate)
                            (ebox--flex-line-main-size
                             (ebox--flex-size-line candidate main-size main-gap)
                             main-gap))
                          lines))
                 (container-main
                  (or main-size (apply #'max (or line-mains '(0)))))
                 (align (plist-get props :align-items))
                 (justify (plist-get props :justify-content))
                 (line-cross (ebox--flex-line-cross sized 'row align))
                 (rendered
                  (ebox--flex-render-row-line
                   sized line-cross container-main main-gap justify align)))
            (list :rendered rendered
                  :item-ids
                  (mapcar (lambda (item)
                            (plist-get (plist-get item :source) :node-id))
                          sized)
                  :main container-main
                  :cross line-cross
                  :row-gap row-gap)))))))

(provide 'ebox-flex)

;;; ebox-flex.el ends here
