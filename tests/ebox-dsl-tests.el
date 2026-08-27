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

(ert-deftest ebox-typed-form-projects-outer-and-layout-to-display ()
  "A typed Box form should project its two axes to one display pair."
  (let ((node (ebox-build '(flex :outer inline "A"))))
    (should (equal (ebox--computed-display node) '(inline flex)))))

(ert-deftest ebox-style-unrelated-facts-preserve-typed-layout-config ()
  "Unrelated computed facts must not replace direct typed layout values."
  (dolist (case '((flex
                   (flex :flex-direction column :column-gap (6) "A"))
                  (grid
                   (grid :grid-template-columns ((40) (60))
                         :column-gap (4) "A"))))
    (let* ((kind (car case))
           (node (ebox-build (cadr case)))
           (before (copy-tree (plist-get node :ebox-layout-config)))
           (style
            (ebox-style-compute-subject
             (ecss-subject-create :type (symbol-name kind))
             (ebox-style-compile-declarations '(:color "#123456")))))
      (ebox-style-apply-computed node style)
      (should (equal (plist-get node :ebox-layout-config) before)))))

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

(ert-deftest ebox-style-preserves-ordered-shorthand-longhand-normalization ()
  "Ebox author pairs remain ordered normalization groups before cutover."
  (let ((border-then-top
         (ebox-style-compile-declarations
          '(:border "red" :border-top none) t))
        (top-then-border
         (ebox-style-compile-declarations
          '(:border-top none :border "red") t)))
    (should (eq 'none
                (plist-get border-then-top 'ebox/border-top-style)))
    (should (equal "red"
                   (plist-get border-then-top 'ebox/border-right-color)))
    (should (eq 'solid
                (plist-get top-then-border 'ebox/border-top-style)))
    (should (equal "red"
                   (plist-get top-then-border 'ebox/border-top-color)))))

(ert-deftest ebox-style-property-registry-rejects-alias-collisions ()
  "An alias should never shadow another canonical property."
  (should-error
   (ecss-schema-package-create
    'ebox
    (mapcar
     #'ebox-style--schema-definition
     '((:name :first :id ebox/first :aliases (:second)
        :group paint :dirty-kind paint :signature paint)
       (:name :second :id ebox/second
        :group paint :dirty-kind paint :signature paint))))
   :type 'ecss-invalid-property-schema)
  (should (eq 'ebox/background-color
              (ecss-schema-set-canonical-id ebox-style-schemas :bgcolor)))
  (should (eq :background-color
              (plist-get
               (ecss-schema-set-property-metadata
                ebox-style-schemas :bgcolor)
               :name)))
  (let ((metadata (ebox-style-property :bgcolor)))
    (setf (plist-get metadata :name) :damaged)
    (setcar (plist-get metadata :contexts) 'damaged)
    (should (eq :background-color
                (plist-get (ebox-style-property :bgcolor) :name)))
    (should (equal '(box)
                   (plist-get (ebox-style-property :bgcolor) :contexts)))))

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
    (should (string= (ebox-dsl-test--plain node) "Hello"))
    (should-not (ebox-tree-node-visible-overflow-p node))))

(ert-deftest ebox-canonical-text-constructor-rejects-non-text-shapes ()
  "A canonical TextNode should have exactly one string payload."
  (should-error (ebox-text-create :value 7) :type 'error)
  (should-error (ebox-text-create :value "A" :content "B") :type 'error)
  (should-error (ebox-text-create :value "A" :children nil) :type 'error)
  (should-error (ebox-text-create :value "A" :color "red") :type 'error)
  (should-error (ebox-build '(text :wrap-mode none "A")) :type 'error)
  (should-error
   (ebox-text-create :value "A" :value "B")
   :type 'error)
  (should-error
   (ebox-text-create :value "A" :source-handle 'a :source-handle 'b)
   :type 'error))

(ert-deftest ebox-canonical-box-uses-registered-runtime-defaults ()
  "A Box should materialize the definite defaults consumed by layout."
  (let ((box (ebox-box-create
              :layout (ebox-normal-layout-create) :children nil)))
    (should (eq (ebox-get box :overflow) 'scroll))
    (dolist (property '(:padding-left-pixel :padding-right-pixel
                        :padding-top-height :padding-bottom-height
                        :margin-left-pixel :margin-right-pixel
                        :margin-top-height :margin-bottom-height
                        :border-left-pixel :border-right-pixel))
      (should (zerop (ebox-get box property))))))

(ert-deftest ebox-render-cache-signature-ignores-derived-layout-proofs ()
  "A render must not invalidate its own canonical node cache key."
  (let* ((node (ebox-build '(box :width '(80) "Stable")))
         (before
          (let ((ebox--render-cache-signature-cache
                 (make-hash-table :test 'eq)))
            (ebox--render-cache-node-signature node))))
    (plist-put node :ebox-content-width-exact-p t)
    (plist-put node :ebox-content-layout-complete-p t)
    (let ((after
           (let ((ebox--render-cache-signature-cache
                  (make-hash-table :test 'eq)))
             (ebox--render-cache-node-signature node))))
      (should (equal-including-properties before after)))))

(ert-deftest ebox-canonical-box-materializes-inherited-foreground-once ()
  "A canonical Text should be the sole foreground paint owner under Box."
  (let* ((rendered (ebox-render (ebox-build '(box :color "#123456" "A"))))
         (face (get-text-property 0 'face rendered)))
    (should (equal face '(:foreground "#123456")))))

(ert-deftest ebox-box-owns-wrap-policy-consumed-by-text ()
  "Box declarations should become inherited Text measurement input."
  (let ((buffer (generate-new-buffer " *ebox-wrap-owner*")))
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-build '(box :wrap-mode none "Page 1 / 3")))
          (let* ((root (plist-get (ebox--buffer-render-state buffer)
                                  :root-node))
                 (text (car (ebox-box-node-children root))))
            (should (eq (ebox-style-node-specified-value root :wrap-mode)
                        'none))
            (should (eq (plist-get root :wrap-mode) 'none))
            (should (eq (plist-get text :wrap-mode) 'none))))
      (kill-buffer buffer))))

(ert-deftest ebox-box-wrap-modes-preserve-word-char-kp-and-none ()
  "Keep every established Box wrapping algorithm behind one property."
  (dolist (mode '(word char kp none))
    (let ((node (ebox-build `(box :wrap-mode ,mode "A B"))))
      (should (eq (ebox-style-node-specified-value node :wrap-mode) mode))))
  (should-error (ebox-build '(box :wrap-mode arbitrary "A")) :type 'error)
  (let* ((width (ebox--string-pixel-width "A"))
         (char-box
          (ebox-box-create
           :layout (ebox-normal-layout-create)
           :children (list (ebox-text-create :value "AB"))
           :width (list width) :wrap-mode 'char))
         (none-box
          (ebox-box-create
           :layout (ebox-normal-layout-create)
           :children (list (ebox-text-create :value "AB"))
           :width (list width) :wrap-mode 'none)))
    (should (= (length (ebox-string-lines (ebox-render char-box))) 2))
    (should (= (length (ebox-string-lines (ebox-render none-box))) 1)))
  (let (justify-args)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (eq feature 'ekp)))
              ((symbol-function 'ekp-pixel-justify)
               (lambda (text width)
                 (setq justify-args (list text width))
                 text)))
      (ebox-render
       (ebox-box-create
        :layout (ebox-normal-layout-create)
        :children (list (ebox-text-create :value "paragraph"))
        :width '(100) :wrap-mode 'kp)))
    (should (equal justify-args '("paragraph" 100)))))

(ert-deftest ebox-canonical-normal-box-renders-inline-runs-and-blocks ()
  "Normal should retain typed children and honor inline/block boundaries."
  (let* ((text (ebox-text-create :value "A" :source-handle 'source-text))
         (second-text (ebox-text-create :value "B"))
         (inline
          (ebox-box-create
           :layout (ebox-normal-layout-create) :outer 'inline
           :width '(100)
           :children (list (ebox-text-create :value "A B"))))
         (block
          (ebox-box-create
           :layout (ebox-normal-layout-create)
           :children (list (ebox-text-create :value "C"))))
         (tail (ebox-text-create :value "D"))
         (layout (ebox-normal-layout-create))
         (box (ebox-box-create :layout layout
                               :children (list text second-text inline block tail)
                               :source-handle 'source-box
                               :width '(50) :overflow 'visible))
         (rendered (ebox-render box))
         (rendered-lines (ebox-string-lines rendered))
         (lines (mapcar (lambda (line)
                          (string-trim-right
                           (substring-no-properties line)))
                        rendered-lines)))
    (should (ebox-box-node-p box))
    (should-not (ebox-text-node-p box))
    (should (eq (ebox-node-source-handle box) 'source-box))
    (should (eq (ebox-layout-config-kind
                 (ebox-box-node-layout box))
                'normal))
    (should (equal (ebox-box-node-children box)
                   (list text second-text inline block tail)))
    (should (equal (ebox--computed-display text) '(inline flow)))
    (should (equal lines '("AB" "A B" "C" "D")))
    (should (>= (ebox--string-pixel-width (nth 1 rendered-lines)) 100))
    (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
      (plist-put text :class "fixed-inline-text")
      (ebox-style-add-rule ".fixed-inline-text" (list :outer 'block))
      (should-error (ebox-render box) :type 'error))
    (cl-labels
        ((normal-lines
          (value &optional width)
          (mapcar #'substring-no-properties
                  (ebox-string-lines
                   (ebox-render
                    (apply #'ebox-box-create
                           :layout (ebox-normal-layout-create)
                           :children (list (ebox-text-create :value value))
                           (when width
                             (list :width (list width)
                                   :overflow 'visible))))))))
      (dolist (case '(("A\n\nB" ("A" "" "B"))
                      ("\nA" ("" "A"))
                      ("A\n" ("A" ""))
                      ("\n" ("" ""))))
        (should (equal (mapcar #'string-trim-right
                               (normal-lines (car case)))
                       (cadr case))))
      (should (equal (normal-lines "  A") '("  A")))
      (should (equal (normal-lines " ") '(" ")))
      (should
       (equal (mapcar #'string-trim-right
                      (normal-lines
                       "abcdef x" (* 5 (ebox--string-pixel-width "a"))))
              '("abcde" "f x")))
      (should
       (= (length
           (normal-lines
            (make-string 10 ?\s)
            (* 5 (ebox--string-pixel-width " "))))
          2))
      (should (= (length (normal-lines "word" 0)) 1))
      (should (= (length (normal-lines " " 0)) 1))
      (let* ((inline-zero
              (ebox-box-create
               :layout (ebox-normal-layout-create) :outer 'inline
               :width '(10)
               :children (list (ebox-text-create :value "I"))))
             (zero-parent
              (ebox-box-create
               :layout (ebox-normal-layout-create) :width '(0)
               :overflow 'visible :children (list inline-zero))))
        (should (= (ebox-string-height (ebox-render zero-parent)) 1))))))

(ert-deftest ebox-canonical-row-box-retains-and-renders-typed-children ()
  "A Row Box should retain one Box identity around all typed children."
  (let* ((left (ebox-text-create :value "A" :source-handle 'left))
         (right (ebox-text-create :value "B\nB\nB" :source-handle 'right))
         (box (ebox-box-create :layout (ebox-row-layout-create
                                        :item-gap 5 :cross-align 'center)
                               :children (list left right)
                               :source-handle 'row)))
    (should (ebox-box-node-p box))
    (should (eq (ebox-node-source-handle box) 'row))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout box)) 'row))
    (should (equal (ebox-layout-config-props (ebox-box-node-layout box))
                   '(:item-gap 5 :cross-align center)))
    (should (equal (ebox-box-node-children box) (list left right)))
    (should (eq (ebox-tree-node-children box)
                (ebox-box-node-children box)))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 3))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 3))
    (should-not (plist-member box :ebox-content-node))
    (should (equal (ebox--computed-display box) '(block row)))
    (let* ((rendered (ebox-render box))
           (lines (ebox-string-lines rendered))
           (middle (nth 1 lines)))
      (should-not (string-match-p "A" (substring-no-properties (car lines))))
      (should (string-match-p "A.*B" (substring-no-properties middle)))
      (should (= (ebox--string-pixel-width middle)
                 (+ (ebox--string-pixel-width "A") 5
                    (ebox--string-pixel-width "B")))))))

(ert-deftest ebox-canonical-column-box-retains-and-renders-typed-children ()
  "A Column Box should retain one Box identity around all typed children."
  (let* ((top (ebox-text-create :value "A"))
         (bottom (ebox-text-create :value "BBB"))
         (box (ebox-box-create :layout (ebox-column-layout-create
                                        :item-gap 1 :cross-align 'end)
                               :children (list top bottom))))
    (should (ebox-box-node-p box))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout box)) 'column))
    (should (equal (ebox-layout-config-props (ebox-box-node-layout box))
                   '(:item-gap 1 :cross-align end)))
    (should (equal (ebox-box-node-children box) (list top bottom)))
    (should (eq (ebox-tree-node-children box)
                (ebox-box-node-children box)))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 3))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 3))
    (should-not (plist-member box :ebox-content-node))
    (should (equal (ebox--computed-display box) '(block column)))
    (should (= (ebox-string-height (ebox-render box)) 3))
    (let ((lines (ebox-string-lines (ebox-render box))))
      (should (string-prefix-p " " (substring-no-properties (car lines))))
      (should (= (ebox--string-pixel-width (car lines))
                 (ebox--string-pixel-width (nth 2 lines)))))))

(ert-deftest ebox-canonical-simple-axis-config-validates-closed-schema ()
  "Row/Column configs should distinguish defaults from invalid explicit values."
  (dolist (constructor '(ebox-row-layout-create ebox-column-layout-create))
    (should (equal (ebox-layout-config-props (funcall constructor))
                   '(:item-gap 0 :cross-align stretch)))
    (dolist (plist '((:item-gap nil) (:item-gap -1)
                     (:cross-align nil) (:cross-align bogus)
                     (:gap 1) (:item-gap 1 :item-gap 2)))
      (should-error (apply constructor plist) :type 'error))))

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

(ert-deftest ebox-build-projects-source-style-without-polluting-canonical-geometry ()
  "Track the G4 boundary: author paint must leave canonical Box geometry."
  :expected-result :failed
  (let ((node (ebox-build '(box :background-color "red" "Paint"))))
    (should-not (ebox-get node :bgcolor))))

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

(ert-deftest ebox-build-normalizes-the-complete-author-grammar ()
  "Every public author form should lower to one canonical Text/Box model."
  (dolist (case
           '(("plain" text nil)
             ((text "styled") text nil)
             ((box) box normal)
             ((row "A" "B") box row)
             ((column "A" "B") box column)
             ((flex "A" "B") box flex)
             ((grid "A" "B") box grid)))
    (let* ((form (nth 0 case))
           (kind (nth 1 case))
           (layout-kind (nth 2 case))
           (node (ebox-build form)))
      (should (eq (ebox-node-kind node) kind))
      (should (symbolp (ebox-node-source-handle node)))
      (should-not (intern-soft
                   (symbol-name (ebox-node-source-handle node))))
      (when layout-kind
        (should
         (eq (ebox-layout-config-kind (ebox-box-node-layout node))
             layout-kind)))))
  (let ((inline-row (ebox-build '(row :outer inline "A" "B"))))
    (should (equal (ebox--computed-display inline-row) '(inline row)))))

(ert-deftest ebox-build-gives-equal-forms-distinct-source-identities ()
  "Structurally equal author forms must not share opaque source identity."
  (let* ((node (ebox-build '(row (box "same") (box "same"))))
         (children (ebox-box-node-children node)))
    (should-not (equal (plist-get (car children) :host-ref)
                       (plist-get (cadr children) :host-ref)))))

(ert-deftest ebox-build-validates-form-owned-config-and-direct-participation ()
  "Layout config belongs to its form; item roles belong to direct child Boxes."
  (let* ((flex
          (ebox-build
           '(flex :width '(300) :gap '(1 (5))
             (box :flex 1 "A")
             "B")))
         (flex-child (car (ebox-box-node-children flex)))
         (grid
          (ebox-build
           '(grid :grid-template-columns '((20) (20))
             (box :grid-column '(1 :span 2) "Header"))))
         (grid-child (car (ebox-box-node-children grid))))
    (should (= (plist-get flex-child :flex-grow) 1))
    (should (equal (plist-get grid-child :grid-column) '(1 :span 2)))
    (should (string-match-p "A.*B"
                            (substring-no-properties (ebox-render flex))))
    (should (string-match-p "Header"
                            (substring-no-properties (ebox-render grid)))))
  (dolist (form
           '((box :flex-direction row)
             (row :gap 1)
             (column :grid-template-columns ((10)))
             (flex :grid-template-columns ((10)))
             (grid :flex-direction row)))
    (should-error (ebox-build form) :type 'error))
  (should-error
   (ebox-render (ebox-build '(box :flex-grow 1 "wrong parent")))
   :type 'error))

(ert-deftest ebox-build-rejects-removed-and-private-author-syntax ()
  "The author boundary should have one grammar and no runtime passthrough."
  (dolist (form
           '((ebox "A")
             (spacer :width (20))
             (item (box "A"))
             (grid-item (box "A"))
             (box :content "A")
             (box :layout flex "A")
             (box :display (block flex) "A")
             (box :ebox-type box "A")
             (box :ebox-content-node nil)
             (text)
             (text "A" "B")
             (text (box "A"))
             (text :width (10) "A")
             (row :item-gap -1)
             (unknown "A")))
    (should-error (ebox-build form) :type 'error))
  (should-error
   (ebox-build (ebox-test-box :content "raw runtime node"))
   :type 'error))

(provide 'ebox-dsl-tests)
;;; ebox-dsl-tests.el ends here
