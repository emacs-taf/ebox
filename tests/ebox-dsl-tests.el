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

(defun ebox-dsl-test--tree-count (node predicate)
  "Count nodes below NODE for which PREDICATE returns non-nil."
  (if (or (stringp node) (not (listp node)))
      0
    (+ (if (funcall predicate node) 1 0)
       (cl-loop for child in (ebox-tree-node-children node)
                sum (ebox-dsl-test--tree-count child predicate)))))

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

(ert-deftest ebox-canonical-row-box-retains-and-renders-typed-children ()
  "A Row Box should retain one Box identity around all typed children."
  (let* ((left (ebox-text-create :value "A" :source-handle 'left))
         (right (ebox-text-create :value "B" :source-handle 'right))
         (box (ebox-box-create :layout (ebox-row-layout-create)
                               :children (list left right)
                               :source-handle 'row)))
    (should (ebox-box-node-p box))
    (should (eq (ebox-node-source-handle box) 'row))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout box)) 'row))
    (should (equal (ebox-box-node-children box) (list left right)))
    (should (eq (ebox-tree-node-children box)
                (ebox-box-node-children box)))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 3))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 3))
    (should-not (plist-member box :ebox-content-node))
    (should (equal (ebox--computed-display box) '(block row)))
    (should (string= (ebox-dsl-test--plain box) "AB"))))

(ert-deftest ebox-canonical-column-box-retains-and-renders-typed-children ()
  "A Column Box should retain one Box identity around all typed children."
  (let* ((top (ebox-text-create :value "A"))
         (bottom (ebox-text-create :value "B"))
         (box (ebox-box-create :layout (ebox-column-layout-create)
                               :children (list top bottom))))
    (should (ebox-box-node-p box))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout box)) 'column))
    (should (equal (ebox-box-node-children box) (list top bottom)))
    (should (eq (ebox-tree-node-children box)
                (ebox-box-node-children box)))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 3))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 3))
    (should-not (plist-member box :ebox-content-node))
    (should (equal (ebox--computed-display box) '(block column)))
    (should (string= (ebox-dsl-test--plain box) "A\nB"))))

(ert-deftest ebox-canonical-flex-box-uses-one-box-identity-and-child-list ()
  "A FlexConfig should select the Box algorithm without a Flex runtime node."
  (let* ((left (ebox-text-create :value "A"))
         (right (ebox-text-create :value "B"))
         (layout (ebox-flex-layout-create))
         (box (ebox-box-create :layout layout
                               :children (list left right)
                               :width '(120)))
         (rendered (ebox-render box)))
    (should
     (equal (ebox-layout-config-props layout)
            '(:flex-direction row :flex-wrap nowrap
              :justify-content flex-start :align-items stretch
              :align-content stretch :row-gap 0 :column-gap 0)))
    (should-not (plist-member (ebox-layout-config-props layout) :width))
    (should-not (plist-member (ebox-layout-config-props layout) :height))
    (should (ebox-box-node-p box))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout box)) 'flex))
    (should (eq (ebox-tree-node-children box)
                (ebox-box-node-children box)))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 3))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 3))
    (should
     (= (ebox-dsl-test--tree-count
         box (lambda (node) (eq (plist-get node :ebox-type) 'flex)))
        0))
    (should-not (plist-member box :ebox-content-node))
    (should (equal (ebox--computed-display box) '(block flex)))
    (should (string= (string-trim-right
                      (substring-no-properties rendered))
                     "AB"))
    (should (= (ebox--string-pixel-width rendered) 120))))

(ert-deftest ebox-canonical-flex-revalidates-the-typed-config-boundary ()
  "Mutated or extra FlexConfig properties should fail before rendering."
  (let ((invalid-direction (ebox-flex-layout-create))
        (extra-frame-prop (ebox-flex-layout-create))
        (cross-kind-props (ebox-flex-layout-create)))
    (setf (ebox-layout-config-props invalid-direction)
          '(:flex-direction bogus :flex-wrap nowrap
            :justify-content flex-start :align-items stretch
            :align-content stretch :row-gap 0 :column-gap 0))
    (setf (ebox-layout-config-props extra-frame-prop)
          (append (ebox-layout-config-props extra-frame-prop)
                  '(:width 999)))
    (setf (ebox-layout-config-kind cross-kind-props) 'row)
    (should-error
     (ebox-box-create :layout invalid-direction :children nil)
     :type 'error)
    (should-error
     (ebox-box-create :layout extra-frame-prop :children nil)
     :type 'error)
    (should-error
     (ebox-box-create :layout cross-kind-props :children nil)
     :type 'error)))

(ert-deftest ebox-canonical-box-detaches-validated-layout-config ()
  "Caller and accessor mutations should not alter a constructed Box."
  (let* ((source-layout (ebox-flex-layout-create))
         (box (ebox-box-create
               :layout source-layout
               :children (list (ebox-text-create :value "A")
                               (ebox-text-create :value "B"))))
         (exposed-layout (ebox-box-node-layout box)))
    (should-not (fboundp 'ebox-layout-config-validator))
    (setf (ebox-layout-config-props source-layout) '(:flex-direction bogus))
    (setf (ebox-layout-config-props exposed-layout) '(:width 999))
    (should (string= (string-trim-right
                      (substring-no-properties (ebox-render box)))
                     "AB"))
    (should (equal (ebox-layout-config-props (ebox-box-node-layout box))
                   ebox--flex-default-config-props))))

(ert-deftest ebox-flex-layout-create-normalizes-the-complete-config-schema ()
  "The typed Flex constructor should emit one canonical closed property set."
  (let ((layout
         (ebox-flex-layout-create
          :flex-direction 'column-reverse
          :flex-wrap 'wrap
          :justify-content 'space-between
          :align-items 'center
          :align-content 'end
          :row-gap '(2)
          :column-gap '(8))))
    (should
     (equal (ebox-layout-config-props layout)
            '(:flex-direction column-reverse :flex-wrap wrap
              :justify-content space-between :align-items center
              :align-content end :row-gap 2 :column-gap 8)))
    (should (ebox-flex-layout-config-props-p
             (ebox-layout-config-props layout)))
    (should (ebox-box-node-p
             (ebox-box-create :layout layout :children nil)))))

(ert-deftest ebox-flex-layout-create-validates-values-and-rejects-author-sugar ()
  "FlexConfig should accept its value domain and reject sugar or foreign props."
  (dolist (direction ebox--flex-direction-values)
    (should (ebox-flex-layout-create :flex-direction direction)))
  (dolist (wrap ebox--flex-wrap-values)
    (should (ebox-flex-layout-create :flex-wrap wrap)))
  (dolist (justify ebox--flex-justify-content-values)
    (should (ebox-flex-layout-create :justify-content justify)))
  (dolist (align ebox--flex-align-items-values)
    (should (ebox-flex-layout-create :align-items align)))
  (dolist (align ebox--flex-align-content-values)
    (should (ebox-flex-layout-create :align-content align)))
  (dolist (plist '((:flex-direction bogus)
                   (:flex-wrap reverse)
                   (:justify-content bogus)
                   (:align-items bogus)
                   (:align-content bogus)
                   (:row-gap -1)
                   (:column-gap (-1))
                   (:flex-flow (row wrap))
                   (:gap 1)
                   (:width 100)
                   (:flex-direction row :flex-direction column)))
    (should-error (apply #'ebox-flex-layout-create plist) :type 'error)))

(ert-deftest ebox-flex-config-validation-does-not-reparse-canonical-pixels ()
  "Boundary validation should preserve physical pixels under non-unit fonts."
  (cl-letf (((symbol-function 'ebox--space-pixel-width) (lambda () 8)))
    (let* ((layout (ebox-flex-layout-create :column-gap '(8)))
           (box (ebox-box-create :layout layout :children nil)))
      (should (= (plist-get (ebox-layout-config-props layout) :column-gap) 8))
      (should (= (plist-get
                  (ebox-layout-config-props (ebox-box-node-layout box))
                  :column-gap)
                 8)))))

(ert-deftest ebox-canonical-flex-projects-one-box-frame-constraint ()
  "Typed and legacy Flex should derive the same content size from BoxFrame."
  (dolist (sizing '(border-box content-box))
    (let* ((typed
            (ebox-box-create
             :layout (ebox-flex-layout-create)
             :children (list (ebox-text-create :value "A")
                             (ebox-text-create :value "B"))
             :width '(140) :padding '(0 (10)) :box-sizing sizing))
           (legacy
            (ebox-flex
             :width '(140) :padding '(0 (10)) :box-sizing sizing
             (ebox-text-create :value "A")
             (ebox-text-create :value "B")))
           (typed-rendered (ebox-render typed))
           (legacy-rendered (ebox-render legacy)))
      (should
       (string=
        (string-trim-right (substring-no-properties typed-rendered))
        (string-trim-right (substring-no-properties legacy-rendered))))
      (should (= (ebox--string-pixel-width typed-rendered)
                 (ebox--string-pixel-width legacy-rendered))))))

(ert-deftest ebox-canonical-grid-box-uses-one-box-identity-and-child-list ()
  "A GridConfig should select the Box algorithm without a Grid runtime node."
  (let* ((layout (ebox-grid-layout-create))
         (box (ebox-box-create
               :layout layout
               :children (list (ebox-text-create :value "A")
                               (ebox-text-create :value "B"))
               :width '(120)))
         (rendered (ebox-render box)))
    (should (equal (ebox-layout-config-props layout)
                   ebox--grid-default-config-props))
    (should-not (plist-member (ebox-layout-config-props layout) :width))
    (should-not (plist-member (ebox-layout-config-props layout) :height))
    (should (ebox-box-node-p box))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout box)) 'grid))
    (should (eq (ebox-tree-node-children box)
                (ebox-box-node-children box)))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 3))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 3))
    (should
     (= (ebox-dsl-test--tree-count
         box (lambda (node) (eq (plist-get node :ebox-type) 'grid)))
        0))
    (should-not (plist-member box :ebox-content-node))
    (should (equal (ebox--computed-display box) '(block grid)))
    (should (string=
             (replace-regexp-in-string
              "[[:space:]]" "" (substring-no-properties rendered))
             "AB"))
    (should (equal (mapcar #'ebox--string-pixel-width
                           (ebox-string-lines rendered))
                   '(120 120 120)))))

(ert-deftest ebox-canonical-grid-consumes-direct-child-placement ()
  "Grid placement should stay on child Boxes without grid-item wrappers."
  (let* ((later
          (ebox-box-create :layout (ebox-normal-layout-create)
                           :children (list (ebox-text-create :value "A"))
                           :grid-row 2))
         (earlier
          (ebox-box-create :layout (ebox-normal-layout-create)
                           :children (list (ebox-text-create :value "B"))
                           :grid-row 1))
         (box (ebox-box-create :layout (ebox-grid-layout-create)
                               :children (list later earlier)))
         (rendered (substring-no-properties (ebox-render box))))
    (should (string=
             (replace-regexp-in-string "[[:space:]]" "" rendered)
             "BA"))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 5))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 5))))

(ert-deftest ebox-canonical-participation-validates-the-final-parent-context ()
  "Participation should be legal only under its matching direct parent layout."
  (cl-labels
      ((child (&rest props)
         (apply #'ebox-box-create
                :layout (ebox-normal-layout-create)
                :children (list (ebox-text-create :value "A"))
                props))
       (parent (layout child)
         (ebox-box-create :layout layout :children (list child))))
    (should (stringp
             (ebox-render
              (parent (ebox-flex-layout-create) (child :flex-grow 1)))))
    (should (stringp
             (ebox-render
              (parent (ebox-grid-layout-create) (child :grid-row 1)))))
    (should-error
     (ebox-render (child :flex-grow 1)) :type 'error)
    (should-error
     (ebox-render
      (parent (ebox-normal-layout-create) (child :flex-grow 1)))
     :type 'error)
    (should-error
     (ebox-render
      (parent (ebox-flex-layout-create) (child :grid-row 1)))
     :type 'error)
    (should-error
     (ebox-render
      (parent (ebox-grid-layout-create) (child :flex-grow 1)))
     :type 'error)
    (let ((text (ebox-text-create :value "A")))
      (plist-put text :flex-grow 1)
      (should-error
       (ebox-render (parent (ebox-flex-layout-create) text)) :type 'error))
    ;; The final candidate is authoritative after ECSS projection too.
    (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
      (ebox-style-add-rule "box" (list :flex-grow 1))
      (should-error
       (ebox-render
        (parent (ebox-normal-layout-create) (child)))
       :type 'error))
    ;; Detached Flex geometry retains its final parent during computed style.
    (let ((ebox-style-stylesheet (ecss-stylesheet-create))
          (detached (child)))
      (plist-put detached :class "detached-flex-item")
      (ebox-style-add-rule ".detached-flex-item" (list :flex-grow 1))
      (let ((ebox--render-root-parent-kind 'flex))
        (should (stringp (ebox-render detached))))
      ;; The dynamic context is exact and cannot authorize a later root.
      (should-error (ebox-render detached) :type 'error))
    (let ((ebox-style-stylesheet (ecss-stylesheet-create))
          (detached (child)))
      (plist-put detached :class "detached-flex-item")
      (ebox-style-add-rule ".detached-flex-item" (list :grid-row 1))
      (let ((ebox--render-root-parent-kind 'flex))
        (should-error (ebox-render detached) :type 'error)))
    ;; A real legacy adapter exempts only its two exact duplicate nodes.
    (let* ((illegal-grandchild (child :flex-grow 1))
           (nested (parent (ebox-normal-layout-create) illegal-grandchild))
           (adapter (ebox-flex-item nested :flex-grow 1 :padding 1)))
      ;; The obsolete mutable depth field must have no authority.
      (plist-put adapter :ebox-flex-item-adapter-depth 99)
      (should-error
       (ebox-render (ebox-flex :width '(100) adapter))
       :type 'error))
    ;; Provenance binds the exact constructor-time source identities.
    (let* ((adapter (ebox-flex-item (ebox-create :content "original")))
           (replacement (ebox-create :content "replacement")))
      (plist-put replacement :flex-grow 1)
      (plist-put adapter :node replacement)
      (should-error
       (ebox-render (ebox-column adapter)) :type 'error))
    (let* ((adapter (ebox-flex-item (ebox-create :content "original")))
           (source (plist-get adapter :node))
           (replacement (ebox-create :content "replacement")))
      (plist-put replacement :flex-grow 1)
      (setq adapter
            (ebox-tree-copy-with-direct-child-replacements
             adapter (list (cons source replacement))))
      (should-error
       (ebox-render (ebox-column adapter)) :type 'error))
    (let* ((adapter
            (ebox-flex-item (ebox-create :content "original") :padding 1))
           (wrapper (plist-get adapter :node))
           (replacement (ebox-create :content "replacement")))
      (plist-put replacement :flex-grow 1)
      (plist-put wrapper :ebox-content-node replacement)
      (should-error
       (ebox-render (ebox-column adapter)) :type 'error))
    ;; Internal layout and parent participation are orthogonal facts.
    (should
     (stringp
      (ebox-render
       (parent
        (ebox-grid-layout-create)
        (ebox-box-create
         :layout (ebox-flex-layout-create)
         :children (list (ebox-text-create :value "A"))
         :grid-row 1)))))))

(ert-deftest ebox-canonical-grid-revalidates-the-typed-config-boundary ()
  "GridConfig must reject frame properties and cross-kind property sets."
  (let ((extra-frame-prop (ebox-grid-layout-create))
        (cross-kind-props (ebox-grid-layout-create)))
    (setf (ebox-layout-config-props extra-frame-prop)
          (append (ebox-layout-config-props extra-frame-prop)
                  '(:width 999)))
    (setf (ebox-layout-config-kind cross-kind-props) 'column)
    (should-error
     (ebox-box-create :layout extra-frame-prop :children nil)
     :type 'error)
    (should-error
     (ebox-box-create :layout cross-kind-props :children nil)
     :type 'error)))

(ert-deftest ebox-canonical-grid-projects-one-box-frame-constraint ()
  "Typed and legacy Grid should derive the same content size from BoxFrame."
  (dolist (sizing '(border-box content-box))
    (let* ((typed
            (ebox-box-create
             :layout (ebox-grid-layout-create)
             :children (list (ebox-text-create :value "A")
                             (ebox-text-create :value "B"))
             :width '(140) :padding '(0 (10)) :box-sizing sizing))
           (legacy
            (ebox-grid
             :width '(140) :padding '(0 (10)) :box-sizing sizing
             (ebox-text-create :value "A")
             (ebox-text-create :value "B")))
           (typed-rendered (ebox-render typed))
           (legacy-rendered (ebox-render legacy)))
      (should (string= (substring-no-properties typed-rendered)
                       (substring-no-properties legacy-rendered)))
      (should
       (equal (mapcar #'ebox--string-pixel-width
                      (ebox-string-lines typed-rendered))
              (mapcar #'ebox--string-pixel-width
                      (ebox-string-lines legacy-rendered)))))))

(ert-deftest ebox-grid-layout-create-normalizes-the-complete-config-schema ()
  "The typed Grid constructor should emit one canonical closed property set."
  (let* ((layout
          (ebox-grid-layout-create
           :grid-template-columns '((20) 1fr)
           :grid-template-rows '(1 auto)
           :grid-auto-columns '((30))
           :grid-auto-rows '(2)
           :grid-auto-flow 'column
           :row-gap '(2) :column-gap '(8)
           :justify-items 'center :align-items 'end
           :justify-content 'space-between :align-content 'center))
         (props (ebox-layout-config-props layout)))
    (should (equal (plist-get props :grid-template-columns)
                   '((:kind fixed :size 20) (:kind fr :factor 1))))
    (should (equal (plist-get props :grid-template-rows)
                   '((:kind fixed :size 1) (:kind auto :factor 0))))
    (should (equal (plist-get props :grid-auto-columns)
                   '(:kind fixed :size 30)))
    (should (equal (plist-get props :grid-auto-rows)
                   '(:kind fixed :size 2)))
    (should (= (plist-get props :row-gap) 2))
    (should (= (plist-get props :column-gap) 8))
    (should (ebox-grid-layout-config-props-p props))
    (should (ebox-box-node-p
             (ebox-box-create :layout layout :children nil)))))

(ert-deftest ebox-grid-layout-create-validates-values-and-rejects-author-sugar ()
  "GridConfig should accept its value domain and reject sugar or foreign props."
  (dolist (flow '(row column))
    (should (ebox-grid-layout-create :grid-auto-flow flow)))
  (dolist (value ebox--grid-justify-items-values)
    (should (ebox-grid-layout-create :justify-items value)))
  (dolist (value ebox--grid-align-items-values)
    (should (ebox-grid-layout-create :align-items value)))
  (dolist (value ebox--grid-content-alignment-values)
    (should (ebox-grid-layout-create :justify-content value))
    (should (ebox-grid-layout-create :align-content value)))
  (dolist (plist '((:grid-auto-flow diagonal)
                   (:grid-template-columns (bogus))
                   (:grid-template-rows (bogus))
                   (:grid-template-columns (0fr))
                   (:grid-template-columns (0.0fr))
                   (:grid-template-columns ((fr 0)))
                   (:grid-template-columns ((minmax (fr 1) auto)))
                   (:grid-template-columns
                    ((minmax (minmax (10) (20)) auto)))
                   (:grid-auto-columns ((10) (20)))
                   (:row-gap -1)
                   (:column-gap (-1))
                   (:gap 1)
                   (:grid-row-gap 1)
                   (:width 100)
                   (:align-items bogus)
                   (:grid-auto-flow row :grid-auto-flow column)))
    (should-error (apply #'ebox-grid-layout-create plist) :type 'error)))

(ert-deftest ebox-grid-config-validation-does-not-reparse-canonical-pixels ()
  "Grid boundary validation should preserve physical pixels under GUI fonts."
  (cl-letf (((symbol-function 'ebox--space-pixel-width) (lambda () 8)))
    (let* ((layout
            (ebox-grid-layout-create
             :grid-template-columns '((20)) :column-gap '(8)))
           (box (ebox-box-create :layout layout :children nil))
           (props (ebox-layout-config-props (ebox-box-node-layout box))))
      (should (= (plist-get props :column-gap) 8))
      (should (= (plist-get (car (plist-get props :grid-template-columns))
                            :size)
                 20)))))

(ert-deftest ebox-grid-config-boundary-rejects-forged-minmax-roles ()
  "Trusted Grid validation should enforce minmax roles after mutation."
  (let ((fr-minimum (ebox-grid-layout-create))
        (nested-minimum (ebox-grid-layout-create)))
    (setf (ebox-layout-config-props fr-minimum)
          (plist-put (ebox-layout-config-props fr-minimum)
                     :grid-template-columns
                     '((:kind minmax
                        :min (:kind fr :factor 1)
                        :max (:kind auto :factor 0)))))
    (setf (ebox-layout-config-props nested-minimum)
          (plist-put (ebox-layout-config-props nested-minimum)
                     :grid-template-columns
                     '((:kind minmax
                        :min (:kind minmax
                              :min (:kind fixed :size 1)
                              :max (:kind fixed :size 2))
                        :max (:kind auto :factor 0)))))
    (should-error
     (ebox-box-create :layout fr-minimum :children nil) :type 'error)
    (should-error
     (ebox-box-create :layout nested-minimum :children nil) :type 'error)))

(ert-deftest ebox-canonical-flex-consumes-direct-child-participation ()
  "Flex participation should stay on child Boxes without item wrappers."
  (let* ((left-text (ebox-text-create :value "A"))
         (right-text (ebox-text-create :value "B"))
         (left (ebox-box-create :layout (ebox-normal-layout-create)
                                :children (list left-text)
                                :order 2))
         (right (ebox-box-create :layout (ebox-normal-layout-create)
                                 :children (list right-text)
                                 :order 1))
         (box (ebox-box-create :layout (ebox-flex-layout-create)
                               :children (list left right)))
         (rendered (substring-no-properties (ebox-render box))))
    (should (string= (string-trim-right rendered) "BA"))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 5))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 5))
    (should
     (= (ebox-dsl-test--tree-count
         box (lambda (node) (eq (plist-get node :ebox-type) 'flex-item)))
        0))))

(ert-deftest ebox-canonical-row-and-column-never-collapse-single-child-boxes ()
  "A one-child Row or Column should preserve its canonical Box boundary."
  (let* ((child (ebox-text-create :value "A"))
         (row (ebox-box-create :layout (ebox-row-layout-create)
                               :children (list child)))
         (column (ebox-box-create :layout (ebox-column-layout-create)
                                  :children (list child))))
    (should (ebox-box-node-p row))
    (should (ebox-box-node-p column))
    (should-not (eq row child))
    (should-not (eq column child))
    (should (equal (ebox-tree-node-children row) (list child)))
    (should (equal (ebox-tree-node-children column) (list child)))
    (should (= (ebox-dsl-test--tree-count row (lambda (_node) t)) 2))
    (should (= (ebox-dsl-test--tree-count column (lambda (_node) t)) 2))
    (should (string= (ebox-dsl-test--plain row) "A"))
    (should (string= (ebox-dsl-test--plain column) "A"))))

(ert-deftest ebox-canonical-empty-layout-boxes-have-no-runtime-child ()
  "Empty layout Boxes should not synthesize layout identities."
  (dolist (layout (list (ebox-row-layout-create)
                        (ebox-column-layout-create)
                        (ebox-flex-layout-create)
                        (ebox-grid-layout-create)))
    (let ((box (ebox-box-create :layout layout :children nil)))
      (should (ebox-box-node-p box))
      (should-not (ebox-tree-node-children box))
      (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 1))
      (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 1))
      (should (string= (ebox-dsl-test--plain box) "")))))

(ert-deftest ebox-canonical-box-copy-keeps-one-authoritative-child-list ()
  "A copied Box should expose exactly its copied runtime children."
  (let* ((left (ebox-text-create :value "A"))
         (right (ebox-text-create :value "B"))
         (source (ebox-box-create :layout (ebox-row-layout-create)
                                  :children (list left right)))
         (copy (ebox-tree-copy-node-structure source))
         (copied-children (ebox-tree-node-children copy)))
    (should (eq copied-children (ebox-box-node-children copy)))
    (should-not (eq copied-children (ebox-box-node-children source)))
    (should-not (eq (car copied-children) left))
    (should-not (eq (cadr copied-children) right))
    (should (= (ebox-dsl-test--tree-count copy (lambda (_node) t)) 3))
    (should (= (ebox-dsl-test--tree-count copy #'ebox-node-kind) 3))))

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
