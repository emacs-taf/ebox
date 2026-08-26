;;; ebox-dsl-tests.el --- Ebox DSL tests -*- lexical-binding: t; -*-

(require 'ert)

(load-file (expand-file-name "../ebox.el" (file-name-directory (or load-file-name buffer-file-name))))

(defun ebox-dsl-test--plain (node)
  "Render NODE and strip text properties."
  (substring-no-properties (ebox-render node)))

(defun ebox-dsl-test--line-widths (node)
  "Return rendered pixel widths for NODE line by line."
  (mapcar #'ebox--string-pixel-width (ebox-string-lines (ebox-render node))))

(defun ebox-dsl-test--display-line-widths (node)
  "Return rendered display pixel widths for NODE line by line."
  (mapcar #'ebox--string-pixel-width (ebox-string-lines (ebox-render node))))

(ert-deftest ebox-style-expands-ebox-aliases-to-canonical-longhands ()
  "Existing Ebox aliases should normalize to CSS-like longhand properties."
  (let ((style (ebox-style-compute
                (list :bgcolor "#ffffff"
                      :padding '(1 2)
                      :margin-left 3
                      :border "#333333"))))
    (should (equal (plist-get style :background-color) "#ffffff"))
    (should (= (plist-get style :padding-block-start) 1))
    (should (= (plist-get style :padding-inline-end) 2))
    (should (= (plist-get style :padding-block-end) 1))
    (should (= (plist-get style :padding-inline-start) 2))
    (should (= (plist-get style :margin-inline-start) 3))
    (should (equal (plist-get style :border-color) "#333333"))))

(ert-deftest ebox-style-classifies-incremental-effects ()
  "Style metadata should classify paint and layout effects."
  (should (eq (ebox-style-dirty-kind :background-color) 'paint))
  (should (eq (ebox-style-dirty-kind :border-color) 'paint))
  (should (eq (ebox-style-dirty-kind :padding-inline-start) 'geometry))
  (should (eq (ebox-style-dirty-kind :width) 'geometry))
  (should (eq (ebox-style-dirty-kind :outer) 'structure))
  (should (eq (ebox-style-dirty-kind :layout) 'structure))
  (should (eq (ebox-style-dirty-kind :display) 'structure)))

(ert-deftest ebox-style-projects-public-box-axes-to-internal-display ()
  "Computed outer/layout properties should project to one display pair."
  (let* ((style
          (ebox-style-compute-subject
           (ecss-subject-create :type "box")
           (ebox-style-compile-declarations
            '(:outer inline :layout flex))))
         (node (ebox-build '(box "A"))))
    (ebox-style-apply-computed node style)
    (should (equal (ebox--computed-display node) '(inline flex)))))

(ert-deftest ebox-style-strict-cache-does-not-hide-unknown-properties ()
  "Strict declaration validation should remain exact after an empty cache hit."
  (ebox-style-compile-declarations nil t)
  (should-error
   (ebox-style-compile-declarations '(:not-an-ebox-property 1) t)
   :type 'error))

(ert-deftest ebox-style-aliases-share-one-canonical-property-id ()
  "A concise alias should disappear before canonical declarations."
  (should
   (equal (ebox-style-compile-declarations '(:bgcolor "red") t)
          (ebox-style-compile-declarations '(:background-color "red") t))))

(ert-deftest ebox-style-rejects-canonical-and-alias-duplicates ()
  "One declaration source should not spell one property twice."
  (should-error
   (ebox-style-compile-declarations
    '(:bgcolor "red" :background-color "blue") t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:background-color "red" :bgcolor "blue") t)
   :type 'error))

(ert-deftest ebox-style-property-registry-rejects-alias-collisions ()
  "An alias should never shadow another canonical property."
  (let ((ebox-style--property-table nil)
        (ebox-style--property-definitions
         '((:name :first :id ebox/first :aliases (:second))
           (:name :second :id ebox/second))))
    (should-error (ebox-style--ensure-property-table) :type 'error)))

(ert-deftest ebox-style-border-present-is-a-typed-shorthand-not-an-alias ()
  "The concise border boolean should expand to canonical width and style."
  (should
   (equal (ebox-style-compile-declarations '(:border-top-p t) t)
          '(ebox/border-top-width 1 ebox/border-top-style solid)))
  (should
   (equal (ebox-style-compile-declarations '(:border-top-p nil) t)
          '(ebox/border-top-width 0 ebox/border-top-style none)))
  (should (eq (ebox-style-canonical-name :border-top-p) :border-top-p)))

(ert-deftest ebox-style-exclusive-check-does-not-reexpand-ordinary-shorthands ()
  "Conflict validation should leave the declaration cache effective."
  (let ((calls 0)
        (original (symbol-function 'ebox-style--padding-shorthand)))
    (clrhash ebox-style--declaration-cache)
    (cl-letf (((symbol-function 'ebox-style--padding-shorthand)
               (lambda (value)
                 (cl-incf calls)
                 (funcall original value))))
      (ebox-style-compile-declarations '(:padding 1) t)
      (ebox-style-compile-declarations '(:padding 1) t))
    (should (= calls 1))))

(ert-deftest ebox-style-border-present-rejects-owned-longhand-conflicts ()
  "One source should not mix the boolean border shorthand with its outputs."
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-p t :border-top-width 2) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-style dashed :border-top-p t) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-p t :border-top (2 dashed "red")) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-p t :border-width 2) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-style dashed :border-top-p t) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-bottom-p t :border (1 solid "red")) t)
   :type 'error))

(ert-deftest ebox-canonical-text-constructor-is-renderable-and-typed ()
  "A canonical TextNode should retain its kind, source, and string value."
  (let ((node (ebox-text-create :value "Hello" :source-handle 'source-text)))
    (should (ebox-text-node-p node))
    (should-not (ebox-box-node-p node))
    (should (eq (ebox-node-source-handle node) 'source-text))
    (should (string= (ebox-text-node-value node) "Hello"))
    (should (string= (ebox-dsl-test--plain node) "Hello"))))

(ert-deftest ebox-canonical-text-constructor-rejects-non-text-shapes ()
  "A canonical TextNode should have exactly one string payload."
  (should-error (ebox-text-create :value 7) :type 'error)
  (should-error (ebox-text-create :value "A" :content "B") :type 'error)
  (should-error (ebox-text-create :value "A" :children nil) :type 'error)
  (should-error (ebox-text-create :value "A" :color "red") :type 'error)
  (should-error
   (ebox-text-create :value "A" :value "B")
   :type 'error)
  (should-error
   (ebox-text-create :value "A" :source-handle 'a :source-handle 'b)
   :type 'error))

(ert-deftest ebox-canonical-normal-box-renders-one-typed-text-child ()
  "A canonical BoxNode should retain typed Layout and child source facts."
  (let* ((text (ebox-text-create :value "A" :source-handle 'source-text))
         (layout (ebox-normal-layout-create))
         (box (ebox-box-create :layout layout
                               :children (list text)
                               :source-handle 'source-box)))
    (should (ebox-box-node-p box))
    (should-not (ebox-text-node-p box))
    (should (eq (ebox-node-source-handle box) 'source-box))
    (should (eq (ebox-layout-config-kind
                 (ebox-box-node-layout box))
                'normal))
    (should (equal (ebox-box-node-children box) (list text)))
    (should (string= (ebox-dsl-test--plain box) "A"))))

(ert-deftest ebox-canonical-box-rejects-paint-only-properties ()
  "Canonical Box geometry should not duplicate paint-only state."
  (should-error
   (ebox-box-create :layout (ebox-normal-layout-create)
                    :bgcolor "red")
   :type 'error))

(ert-deftest ebox-canonical-box-requires-unique-reserved-fields ()
  "Typed Box reserved fields should never be missing or duplicated."
  (let ((normal (ebox-normal-layout-create)))
    (should-error (ebox-box-create :children nil) :type 'error)
    (should-error
     (ebox-box-create :layout normal :layout normal :children nil)
     :type 'error)
    (should-error
     (ebox-box-create :layout normal :children nil :children nil)
     :type 'error)
    (should-error
     (ebox-box-create :layout normal :outer nil :children nil)
     :type 'error)))

(ert-deftest ebox-build-normalizes-text-author-forms ()
  "The Ebox DSL should normalize explicit and bare Text forms."
  (let ((text (ebox-build '(text "A")))
        (bare (ebox-build "B")))
    (should (ebox-text-node-p text))
    (should (ebox-text-node-p bare))
    (should (string= (ebox-dsl-test--plain text) "A"))
    (should (string= (ebox-dsl-test--plain bare) "B"))))

(ert-deftest ebox-build-text-requires-one-string-payload ()
  "The Ebox Text form should reject empty, multiple, and nested payloads."
  (should-error (ebox-build '(text)) :type 'error)
  (should-error (ebox-build '(text "A" "B")) :type 'error)
  (should-error (ebox-build '(text (text "A"))) :type 'error)
  (should-error (ebox-build '(text :color "red" "A")) :type 'error)
  (should-error (ebox-build '(text :wrap-mode garbage "A")) :type 'error))

(ert-deftest ebox-dsl-module-preserves-public-build-syntax ()
  "Extracted DSL compiler should preserve existing ebox-build syntax."
  (let ((node (ebox-build
               '(column :padding 1 :bgcolor "linen"
                 (row
                  (box :content "A" :width (40))
                  (box :content "B" :width (40)))))))
    (should (eq (plist-get node :ebox-type) 'box))
    (should (string-match-p "A" (ebox-render node)))
    (should (string-match-p "B" (ebox-render node)))))

(ert-deftest ebox-build-creates-box-from-keyword-plist ()
  "A `(box ...)' form should compile to a normal Ebox box node."
  (let ((node (ebox-build '(box :content "Hello" :width (120) :border t))))
    (should (eq (plist-get node :ebox-type) 'box))
    (should (string-match-p "Hello" (ebox-dsl-test--plain node)))))

(ert-deftest ebox-build-uses-string-child-as-box-content ()
  "A simple string child should be shorthand for box content."
  (let ((node (ebox-build '(box :width (120) "Hello"))))
    (should (eq (plist-get node :ebox-type) 'box))
    (should (string-match-p "Hello" (ebox-dsl-test--plain node)))))

(ert-deftest ebox-build-resolves-viewport-width-from-dynamic-binding ()
  "The DSL should allow box widths to follow the current render viewport."
  (let* ((ebox-viewport-width 320)
         (node (ebox-build
                '(box :content "Viewport"
                  :width (viewport)
                  :box-sizing border-box
                  :border t))))
    (should (= (car (ebox-dsl-test--line-widths node)) 320))))

(ert-deftest ebox-build-resolves-viewport-height-from-dynamic-binding ()
  "The DSL should allow box heights to follow the current render viewport."
  (let* ((ebox-viewport-height 3)
         (node (ebox-build
                '(box :content "One\nTwo\nThree\nFour"
                  :height (viewport-height)
                  :overflow scroll))))
    (should (= (length (ebox-string-lines (ebox-render node))) 3))))

(ert-deftest ebox-build-resolves-viewport-height-arithmetic-expression ()
  "The DSL should allow viewport-relative height expressions."
  (let* ((ebox-viewport-height 6)
         (node (ebox-build
                '(box :content "One\nTwo\nThree\nFour"
                  :height (- (viewport-height) 2)
                  :overflow scroll))))
    (should (= (length (ebox-string-lines (ebox-render node))) 4))))

(ert-deftest ebox-build-unquotes-static-list-property-values ()
  "The DSL should accept quoted list values used by `etaf-view' forms."
  (let* ((node (ebox-build
                '(grid :width '(120)
                   :grid-template-columns '((40) 1fr)
                   :gap '(0 (4))
                   (box :content "A")
                   (box :content "B"))))
         (props (plist-get node :raw-props))
         (line (car (ebox-string-lines (ebox-render node)))))
    (should (equal (plist-get props :width) '(120)))
    (should (equal (plist-get props :grid-template-columns)
                   '((40) 1fr)))
    (should (= (ebox--string-pixel-width line) 120))))

(ert-deftest ebox-build-composes-fixed-viewport-shell-around-scrollbox ()
  "A fixed viewport shell can reserve chrome while an inner box scrolls."
  (let* ((ebox-viewport-height 6)
         (node (ebox-build
                '(column :height (viewport-height)
                  (box :content "top" :height 1)
                  (box :id "root" :height (- (viewport-height) 2)
                   :overflow scroll
                   (column
                    (box :content "A" :height 1)
                    (box :content "B" :height 1)
                    (box :content "C" :height 1)
                    (box :content "D" :height 1)
                    (box :content "E" :height 1)))
                  (box :content "bottom" :height 1)))))
    (should (= (length (ebox-string-lines (ebox-render node))) 6))))

(ert-deftest ebox-build-composes-row-and-column-layouts ()
  "Row and column forms should compose existing lazy layout nodes."
  (let* ((node (ebox-build
                '(column
                  (box :content "Header" :width (180))
                  (row
                   (box :content "Left" :width (80))
                   (spacer :width (20))
                   (box :content "Right" :width (80))))))
         (plain (ebox-dsl-test--plain node)))
    (should (eq (plist-get node :ebox-type) 'stack))
    (should (string-match-p "Header" plain))
    (should (string-match-p "Left.*Right" plain))
    (should (= (length (ebox-region-ids node)) 4))))

(ert-deftest ebox-build-wraps-child-layout-with-box-properties ()
  "A node with child layout may still apply box properties to the wrapper."
  (let* ((node (ebox-build
                '(box :width (240) :box-sizing border-box
                  :padding (1 20) :border t :bgcolor "#222222"
                  (row
                   (box :content "A" :width (80))
                   (box :content "B" :width (80))))))
         (plain (ebox-dsl-test--plain node)))
    (should (eq (plist-get node :ebox-type) 'box))
    (should (equal (ebox-get node :bgcolor) "#222222"))
    (should (string-match-p "A.*B" plain))
    (dolist (width (ebox-dsl-test--line-widths node))
      (should (= width 240)))))

(ert-deftest ebox-build-box-wrapper-preserves-preformatted-child-layout ()
  "A box wrapping child layout should not rewrap rendered children."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'ekp) t)))
            ((symbol-function 'ekp-pixel-justify)
             (lambda (text _width)
               (if (string-match-p "\n" text)
                   "REWRAPPED"
                 text))))
    (let* ((node (ebox-build
                  '(box :width (220) :box-sizing border-box
                    (row
                     (box :content "Left" :width (80) :height 2)
                     (box :content "Right" :width (80) :height 2)))))
           (plain (ebox-dsl-test--plain node)))
      (should-not (string-match-p "REWRAPPED" plain))
      (should (string-match-p "Left.*Right" plain))
      (dolist (width (ebox-dsl-test--line-widths node))
        (should (= width 220))))))

(ert-deftest ebox-build-row-wrapper-preserves-preformatted-layout ()
  "Row box properties should not rewrap the rendered child layout."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'ekp) t)))
            ((symbol-function 'ekp-pixel-justify)
             (lambda (text _width)
               (if (string-match-p "\n" text)
                   "REWRAPPED"
                 text))))
    (let* ((node (ebox-build
                  '(row :width (220) :box-sizing border-box
                    (box :content "Left" :width (80) :height 2)
                    (box :content "Right" :width (80) :height 2))))
           (plain (ebox-dsl-test--plain node)))
      (should-not (string-match-p "REWRAPPED" plain))
      (should (string-match-p "Left.*Right" plain))
      (dolist (width (ebox-dsl-test--line-widths node))
        (should (= width 220))))))

(ert-deftest ebox-build-column-wrapper-preserves-preformatted-layout ()
  "Column box properties should not rewrap the rendered child layout."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'ekp) t)))
            ((symbol-function 'ekp-pixel-justify)
             (lambda (text _width)
               (if (string-match-p "\n" text)
                   "REWRAPPED"
                 text))))
    (let* ((node (ebox-build
                  '(column :width (180) :box-sizing border-box
                    (box :content "Top" :width (120))
                    (box :content "Bottom" :width (120)))))
           (plain (ebox-dsl-test--plain node)))
      (should-not (string-match-p "REWRAPPED" plain))
      (should (string-match-p "Top" plain))
      (should (string-match-p "Bottom" plain))
      (dolist (width (ebox-dsl-test--line-widths node))
        (should (= width 180))))))

(ert-deftest ebox-build-padded-column-wrapper-stays-inside-viewport ()
  "A padded layout wrapper should not let preformatted children overflow."
  (let* ((ebox-viewport-width 320)
         (node (ebox-build
                '(column :padding 1
                  (box :content "Child width follows the viewport"
                       :wrap-mode word))))
         (widths (ebox-dsl-test--display-line-widths node)))
    (should (cl-every (lambda (width)
                        (<= width ebox-viewport-width))
                      widths))))

(ert-deftest ebox-build-wrapper-explicit-width-bounds-child-layout-viewport ()
  "A wrapper's explicit width should be the containing block for child layouts."
  (let* ((ebox-viewport-width 360)
         (node (ebox-build
                '(column :width (180)
                  (box :content "alpha beta gamma delta epsilon zeta eta theta"
                       :wrap-mode word))))
         (widths (ebox-dsl-test--line-widths node)))
    (dolist (width widths)
      (should (<= width 180)))))

(ert-deftest ebox-build-column-contains-auto-row-children ()
  "A column wrapper must not let an auto-width row child duplicate its viewport."
  (let* ((node (ebox-build
                '(column :width (120)
                  (row
                   (box :content "Left" :border t)
                   (box :content "Right" :border t))
                  (box :content "Body" :border t))))
         (widths (ebox-dsl-test--line-widths node)))
    (should (cl-every (lambda (width) (<= width 120)) widths))))

(ert-deftest ebox-row-keeps-explicit-viewport-widths-intrinsic-context ()
  "Row intrinsic sizing must not change explicit viewport-sized children."
  (let* ((ebox-viewport-width 120)
         (node (ebox-row
                (ebox-create :content "Left" :width 'viewport)
                (ebox-create :content "Right" :width 'stretch)))
         (widths (ebox-dsl-test--line-widths node)))
    (should (equal widths '(240)))))

(ert-deftest ebox-row-keeps-composite-column-intrinsic-width ()
  "A composite column child must not consume the row viewport as auto width."
  (let* ((ebox-viewport-width 120)
         (node (ebox-row
                (ebox-column
                 (ebox-create :content "Top")
                 (ebox-create :content "Bottom"))
                (ebox-create :content "Tail")))
         (widths (ebox-dsl-test--line-widths node)))
    (should (cl-every (lambda (width) (<= width 120)) widths))))

(ert-deftest ebox-build-lazy-column-contains-auto-row-children ()
  "Lazy column windows must apply the same intrinsic row sizing rule."
  (let* ((ebox-viewport-width 120)
         (ebox-viewport-height 4)
         (node (ebox-build
                '(box :width (viewport)
                  :height (viewport-height)
                  :overflow scroll
                  (column
                   (row
                    (box :content "Left" :border t)
                    (box :content "Right" :border t))
                   (box :content "Body" :border t)))))
         (widths (ebox-dsl-test--line-widths node)))
    (should (cl-every (lambda (width) (<= width 120)) widths))))

(ert-deftest ebox-build-wrapper-viewport-width-bounds-child-layout-viewport ()
  "A wrapper's `(viewport)' width should pass its content box to child layouts."
  (let ((cases
         '((box :width (viewport)
            :padding-inline (20)
            :border-left (10)
            :border-right (10)
            (box :content "alpha beta gamma delta epsilon zeta eta theta"
                 :wrap-mode word))
           (column :width (viewport)
            :padding-inline (20)
            :border-left (10)
            :border-right (10)
            (box :content "alpha beta gamma delta epsilon zeta eta theta"
                 :wrap-mode word))
           (row :width (viewport)
            :padding-inline (20)
            :border-left (10)
            :border-right (10)
            (box :content "alpha beta gamma delta epsilon zeta eta theta"
                 :wrap-mode word)
            (spacer :width (0) :height 1)))))
    (dolist (dsl cases)
      (let* ((ebox-viewport-width 240)
             (node (ebox-build dsl))
             (widths (ebox-dsl-test--line-widths node)))
        (dolist (width widths)
          (should (<= width ebox-viewport-width)))))))

(ert-deftest ebox-build-lazy-scroll-prefix-bounds-wrapper-child-viewport ()
  "Lazy scroll prefix rendering should preserve wrapper content viewport."
  (let* ((ebox-viewport-width 320)
         (ebox-viewport-height 5)
         (node (ebox-build
                '(box :id "root"
                  :width (viewport)
                  :height (- (viewport-height) 1)
                  :box-sizing border-box
                  :overflow scroll
                  (column :width (viewport)
                   :box-sizing border-box
                   :padding (1 (18))
                   (box :content "One"
                        :width (viewport)
                        :box-sizing border-box
                        :border t)
                   (box :content "Two"
                        :width (viewport)
                        :box-sizing border-box
                        :border t)
                   (box :content "Three"
                        :width (viewport)
                        :box-sizing border-box
                        :border t)
                   (box :content "Four"
                        :width (viewport)
                        :box-sizing border-box
                        :border t)))))
         (widths (ebox-dsl-test--line-widths node)))
    (dolist (width widths)
      (should (<= width ebox-viewport-width)))))

(ert-deftest ebox-build-tags-map-to-css-like-display ()
  "DSL container tags should expose CSS-like outer/inner display values."
  (let ((box-node (ebox-build '(box :content "A")))
        (row-node (ebox-build '(row (box :content "A") (box :content "B"))))
        (column-node (ebox-build
                      '(column (box :content "A") (box :content "B"))))
        (flex-node (ebox-build '(flex (box :content "A") (box :content "B")))))
    (should (equal (ebox--computed-display box-node) '(block flow)))
    (should (equal (ebox--computed-display row-node) '(block row)))
    (should (equal (ebox--computed-display column-node) '(block column)))
    (should (equal (ebox--computed-display flex-node) '(block flex)))))

(ert-deftest ebox-build-box-uses-orthogonal-outer-and-layout-axes ()
  "Canonical Box DSL should select outer participation and child layout."
  (let ((normal (ebox-build '(box :outer inline :layout normal "A")))
        (row (ebox-build
              '(box :outer inline :layout row
                (box "A")
                (box "B"))))
        (column (ebox-build
                 '(box :outer block :layout column
                   (box "A")
                   (box "B")))))
    (should (equal (ebox--computed-display normal) '(inline flow)))
    (should (equal (ebox--computed-display row) '(inline row)))
    (should (equal (ebox--computed-display column) '(block column)))
    (should (string= (ebox-dsl-test--plain row) "AB"))
    (should (string= (ebox-dsl-test--plain column) "A\nB"))))

(ert-deftest ebox-build-box-rejects-invalid-axis-values ()
  "Canonical Box DSL should reject unknown outer and layout values."
  (should-error (ebox-build '(box :outer floating "A")) :type 'error)
  (should-error (ebox-build '(box :layout masonry "A")) :type 'error))

(ert-deftest ebox-build-box-layout-consumes-direct-flex-item-properties ()
  "Canonical Flex Box should consume participation props from child Boxes."
  (let* ((node (ebox-build
                '(box :layout flex :width (300)
                  (box :flex-grow 1 :flex-basis (80) "A")
                  (box :flex-grow 2 :flex-basis (80) "B"))))
         (children (plist-get node :children)))
    (should (equal (ebox--computed-display node) '(block flex)))
    (should (= (plist-get (car children) :flex-grow) 1))
    (should (= (plist-get (cadr children) :flex-grow) 2))
    (should (string-match-p "A" (ebox-dsl-test--plain node)))
    (should (string-match-p "B" (ebox-dsl-test--plain node)))))

(ert-deftest ebox-build-box-layout-consumes-direct-grid-item-properties ()
  "Canonical Grid Box should consume placement props from child Boxes."
  (let* ((node (ebox-build
                '(box :layout grid :grid-template-columns ((20) (20))
                  (box :grid-column (1 :span 2) "Header"))))
         (child (car (plist-get node :children))))
    (should (equal (ebox--computed-display node) '(block grid)))
    (should (equal (plist-get child :grid-column) '(1 :span 2)))
    (should (string-match-p "Header" (ebox-dsl-test--plain node)))))

(ert-deftest ebox-build-wrapper-child-layout-rerenders-on-runtime-viewport-change ()
  "A DSL wrapper box should rerender child layout content on viewport resize."
  (let ((node (let ((ebox-viewport-width 96))
                (ebox-build
                 '(column :padding 1 :bgcolor "linen"
                   (box :content "This child text should wrap again when the preview becomes narrow."
                        :wrap-mode word)))))
        buffer)
    (unwind-protect
        (progn
          (setq buffer
                (let ((ebox-viewport-width 96))
                  (ebox-render-to-buffer
                   (generate-new-buffer-name " *ebox-dsl-test*")
                   node)))
          (let ((wide-text (with-current-buffer buffer
                             (buffer-substring-no-properties
                              (point-min) (point-max))))
                (wide-height (with-current-buffer buffer
                               (count-lines (point-min) (point-max)))))
            (ebox-rerender-buffer-with-context buffer 36)
            (let ((narrow-text (with-current-buffer buffer
                                 (buffer-substring-no-properties
                                  (point-min) (point-max))))
                  (narrow-height (with-current-buffer buffer
                                   (count-lines (point-min) (point-max)))))
              (should-not (string= wide-text narrow-text))
              (should (> narrow-height wide-height)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest ebox-build-item-is-flex-participation-sugar ()
  "DSL item should attach flex participation to its child semantics."
  (let* ((node (ebox-build
                '(flex :width (300)
                  (item :flex 1 (box :content "A"))
                  (box :content "B" :flex 1))))
         (rendered (let ((ebox-viewport-width 300))
                     (ebox-render node))))
    (should (string-match-p "A" (substring-no-properties rendered)))
    (should (string-match-p "B" (substring-no-properties rendered)))))

(ert-deftest ebox-build-keeps-pre-render-region-ids-available ()
  "The DSL should not break the pre-render region-id workflow."
  (let* ((node (ebox-build
                '(row
                  (box :content "One" :width (80))
                  (box :content "Two" :width (80)))))
         (ids (ebox-region-ids node)))
    (should (= (length ids) 2))
    (should (cl-every #'identity ids))))

(ert-deftest ebox-build-wrapper-region-ids-include-child-layout ()
  "A wrapper box should keep both its own region id and child layout ids."
  (let* ((node (ebox-build
                '(column :padding 1
                  (box :content "One")
                  (box :content "Two"))))
         (ids (ebox-region-ids node)))
    (should (= (length ids) 3))
    (should (cl-every #'identity ids))))

(ert-deftest ebox-build-rejects-invalid-dsl ()
  "Bad forms should fail loudly instead of producing surprising nodes."
  (should-error (ebox-build '(unknown :content "Nope")) :type 'error)
  (should-error (ebox-build '(box :content)) :type 'error)
  (should-error (ebox-build '(spacer :width (20) (box :content "bad"))) :type 'error))

(provide 'ebox-dsl-tests)
;;; ebox-dsl-tests.el ends here
