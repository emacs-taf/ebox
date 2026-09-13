;;; ebox-dsl-tests.el --- Ebox DSL tests -*- lexical-binding: t; -*-

(require 'ert)

(ert-deftest ebox-local-ecss-renders-nested-scopes ()
  "Actual publication consumes local rules and keeps outside nodes isolated."
  (let* ((input (ebox-build
                 '(box
                   (box :ecss (("&" :color "#111111")
                               (".item" :color "#223344")
                               (".item.active" :color "#00aa00"))
                        (box :class "item" "outer")
                        (box :ecss ((".item" :color "#aa0000"))
                             (box :class "item" "inner")
                             (box :class '("item" "active") "active")))
                   (box :color "#777777" :class '("item" "active") "outside"))))
         (text (ebox-render input)))
    (let (colors)
      (dotimes (position (length text))
        (when-let* ((face (get-text-property position 'face text))
                    (color (plist-get face :foreground)))
          (cl-pushnew color colors :test #'equal)))
      (dolist (color '("#223344" "#aa0000" "#00aa00" "#777777"))
        (should (member color colors))))))

(ert-deftest ebox-dsl-exposes-selector-states-to-ecss ()
  "Public DSL state metadata reaches the generic ECSS subject adapter."
  (let* ((input (ebox-build '(box :states '(checked emphasized) "Checked")))
         (node (ebox-canonical-input--single-root input "state test"))
         (index (ebox-tree-source-index
                 node nil nil (ebox-canonical-input--source-index input)))
         (subject (ebox-tree-node-subject
                   index node)))
    (should (equal (ecss-subject-states subject)
                   '("checked" "emphasized")))
    (should (ecss-selector-match-p ":checked" subject))
    (should-not (ecss-selector-match-p ":disabled" subject))))

(ert-deftest ebox-dsl-rejects-malformed-selector-state-metadata ()
  "Selector state metadata remains a token list at the author boundary."
  (should-error (ebox-build '(box :states '((checked)) "Invalid"))))

(load-file (expand-file-name "../ebox.el" (file-name-directory (or load-file-name buffer-file-name))))
(load-file (expand-file-name "ebox-fixtures.el"
                             (file-name-directory (or load-file-name
                                                      buffer-file-name))))

(defun ebox-dsl-test--constructor-input (tag plist)
  "Return `(BUILDER . PLIST)' for typed constructor TAG and PLIST."
  (let* ((style-keys
         (cl-loop for (key _value) on plist by #'cddr
                   when (and (not (memq key
                                        '(:value :layout :children :outer
                                          :source-handle :owned-facts)))
                             (ebox-style--property key))
                   collect key))
         (style-props
          (cl-loop for (key value) on plist by #'cddr
                   when (memq key style-keys) append (list key value)))
         (declarations
          (and style-props (ebox-style-compile-form
                            tag (ebox-test--explicit-sizes tag style-props))))
         (plist
          (cl-loop for (key value) on plist by #'cddr
                   unless (memq key style-keys) append (list key value)))
         (values
         (cl-loop for (key value) on plist by #'cddr
                  when (eq key :source-handle)
                  collect value))
        (builder (ebox-source-builder-create)))
    (when (plist-member plist :children)
      (setq plist
            (plist-put
             (copy-sequence plist) :children
             (mapcar (lambda (child)
                       (ebox-test--normalize-child builder child))
                     (plist-get plist :children)))))
    (when (<= (length values) 1)
      (let* ((provided (car values))
             (identity
              (if (ebox-source-handle-p provided)
                  (ebox-source-handle-id provided)
                provided))
             (handle
              (ebox-source-builder-bind
               builder :identity identity :declarations declarations
               :provenance '(:adapter ebox-dsl-test))))
        (setq plist (plist-put (copy-sequence plist) :source-handle handle))))
    (setq plist
          (append plist
                  (list :owned-facts
                        (ebox-canonical-facts-from-declarations
                         tag declarations))))
    (cons builder plist)))

(defun ebox-dsl-test--text-create (&rest plist)
  "Create a canonical Text input with an explicit source boundary."
  (let* ((input (ebox-dsl-test--constructor-input 'text plist))
         (builder (car input))
         (node (apply #'ebox-text-create (cdr input)))
         (index (ebox-source-builder-finish builder)))
    (ebox-canonical-input-create (list node) index)))

(defun ebox-dsl-test--box-create (&rest plist)
  "Create a canonical Box input with an explicit source boundary."
  (let* ((layout (plist-get plist :layout))
         (tag (if (and (ebox-layout-config-p layout)
                       (not (eq (ebox-layout-config-kind layout) 'normal)))
                  (ebox-layout-config-kind layout)
                'box))
         (input (ebox-dsl-test--constructor-input tag plist))
         (builder (car input))
         (node
          (apply #'ebox-box-create :source-builder builder (cdr input)))
         (index (ebox-source-builder-finish builder)))
    (ebox-canonical-input-create (list node) index)))

(defun ebox-dsl-test--revise-source (input &rest facts)
  "Return INPUT with its root source immutably rebound by FACTS."
  (let* ((node (ebox-test-root input))
         (handle (ebox-node-source-handle node))
         (index (ebox-test-source-index input))
         (binding (apply #'ebox-source-index-rebind index handle facts)))
    (plist-put node :ebox-source-handle (cdr binding))
    (ebox-canonical-input-create (list node) (car binding))))

(defun ebox-dsl-test--plain (input)
  "Render canonical INPUT and strip text properties."
  (substring-no-properties (ebox-render input)))

(defun ebox-dsl-test--root (input)
  "Return INPUT's canonical root node."
  (ebox-canonical-input--single-root input "Ebox DSL test"))

(defun ebox-dsl-test--line-widths (input)
  "Return rendered pixel widths for canonical INPUT line by line."
  (mapcar #'ebox--string-pixel-width (ebox-string-lines (ebox-render input))))

(defun ebox-dsl-test--display-line-widths (input)
  "Return rendered display pixel widths for canonical INPUT line by line."
  (mapcar #'ebox--string-pixel-width (ebox-string-lines (ebox-render input))))

(defun ebox-dsl-test--tree-count (node predicate)
  "Count nodes below NODE for which PREDICATE returns non-nil."
  (when (ebox-canonical-input-p node)
    (setq node (ebox-dsl-test--root node)))
  (if (or (stringp node) (not (listp node)))
      0
    (+ (if (funcall predicate node) 1 0)
       (cl-loop for child in (ebox-tree-node-children node)
                sum (ebox-dsl-test--tree-count child predicate)))))

(ert-deftest ebox-style-expands-ebox-aliases-to-canonical-longhands ()
  "Approved aliases and shorthands should produce canonical longhands."
  (let ((style (ebox-style-compute
                (list :bgcolor "#ffffff"
                      :padding '((lh 1) (ch 2))
                      :margin-left '(ch 3)
                      :border "#333333"))))
    (should (equal (plist-get style :background-color) "#ffffff"))
    (should (equal (plist-get style :padding-block-start) '(lh 1)))
    (should (equal (plist-get style :padding-inline-end) '(ch 2)))
    (should (equal (plist-get style :padding-block-end) '(lh 1)))
    (should (equal (plist-get style :padding-inline-start) '(ch 2)))
    (should (equal (plist-get style :margin-left) '(ch 3)))
    (should (equal (plist-get style :border-color) "#333333"))))

(ert-deftest ebox-style-classifies-incremental-effects ()
  "Style metadata should classify paint and layout effects."
  (should (eq (ebox-style-dirty-kind :background-color) 'paint))
  (should (eq (ebox-style-dirty-kind :border-color) 'paint))
  (should (eq (ebox-style-dirty-kind :padding-inline-start) 'geometry))
  (should (eq (ebox-style-dirty-kind :width) 'geometry))
  (should (eq (ebox-style-dirty-kind :outer) 'structure))
  (should-not (ebox-style-dirty-kind :layout))
  (should-not (ebox-style-dirty-kind :display)))

(ert-deftest ebox-typed-form-projects-outer-and-layout-to-display ()
  "A typed Box form should project its two axes to one display pair."
  (let ((node (ebox-build '(flex :outer inline "A"))))
    (should (equal (ebox--computed-display (ebox-dsl-test--root node))
                   '(inline flex)))))

(ert-deftest ebox-inline-outer-participates-in-the-cascade ()
  "An inline outer declaration should outrank a matching stylesheet rule."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
    (ebox-style-add-rule ".card" '(:outer block))
    (let ((node (ebox-dsl-test--root
                 (ebox-build '(box :class "card" :outer inline "A")))))
      (should (equal (ebox--computed-display node) '(inline flow))))))

(ert-deftest ebox-style-unrelated-facts-preserve-typed-layout-config ()
  "Unrelated computed facts must not replace direct typed layout values."
  (dolist (case '((flex
                   (flex :flex-direction column :column-gap (px 6) "A"))
                  (grid
                   (grid :grid-template-columns ((px 40) (px 60))
                         :column-gap (px 4) "A"))))
    (let* ((kind (car case))
           (input (ebox-build (cadr case)))
           (node (ebox-dsl-test--root input))
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

(ert-deftest ebox-canonical-property-vocabulary-is-the-only-author-path ()
  "The frozen G4b vocabulary should have one canonical spelling and owner."
  (dolist (entry '((:font-size . ebox/font-size)
                   (:font-style . ebox/font-style)
                   (:text-decoration-line . ebox/text-decoration-line)
                   (:text-decoration-color . ebox/text-decoration-color)
                   (:text-decoration-style . ebox/text-decoration-style)
                   (:item-gap . ebox/item-gap)
                   (:cross-align . ebox/cross-align)
                   (:justify-self . ebox/justify-self)))
    (should (eq (ebox-style-schema-id (car entry)) (cdr entry))))
  (should (eq (ebox-style-schema-id :bgcolor)
              (ebox-style-schema-id :background-color)))
  (should (eq (ebox-style-schema-id :font-slant)
              (ebox-style-schema-id :font-style)))
  (dolist (entry '((:padding-top . ebox/padding-top)
                   (:padding-right . ebox/padding-right)
                   (:padding-bottom . ebox/padding-bottom)
                   (:padding-left . ebox/padding-left)
                   (:margin-top . ebox/margin-top)
                   (:margin-right . ebox/margin-right)
                   (:margin-bottom . ebox/margin-bottom)
                   (:margin-left . ebox/margin-left)))
    (should (eq (ebox-style-schema-id (car entry)) (cdr entry))))
  (should-not (eq (ebox-style-schema-id :padding-top)
                  (ebox-style-schema-id :padding-block-start)))
  (should-not (eq (ebox-style-schema-id :margin-left)
                  (ebox-style-schema-id :margin-inline-start)))
  (dolist (name '(:font :font-height :border-bottom-p
                  :grid-row-gap :grid-column-gap :vertical-align
                  :display :layout :content :surface-properties :face
                  :padding-top-height :padding-right-pixel
                  :padding-bottom-height :padding-left-pixel
                  :margin-top-height :margin-right-pixel
                  :margin-bottom-height :margin-left-pixel
                  :border-right-pixel :border-left-pixel))
    (should-not (ebox-style-schema-id name)))
  (dolist (name '(:border-top-p :grid-column-span :grid-row-span))
    (should (plist-get (ebox-style-property name) :shorthand))))

(ert-deftest ebox-normal-text-align-is-not-a-layout-wide-property ()
  "Only the Normal Box form owns text alignment author input."
  (should (ebox-build '(box :text-align center "A")))
  (dolist (tag '(row column flex grid))
    (should-error
     (ebox-build (list tag :text-align 'center "A"))
     :type 'error)))

(ert-deftest ebox-edge-projection-uses-one-ecss-winner-order ()
  "Logical and physical edges conflict locally and cascade across sources."
  (should-error
   (ebox-style-compile-declarations
    '(:padding-left (px 4) :padding-inline-start (px 8)) t)
   :type 'ecss-invalid-declaration)
  (let* ((base (ebox-style-compile-declarations '(:padding ((lh 0) (px 8))) t))
         (override
          (ebox-style-compile-declarations '(:padding-left (px 24)) t))
         (style
          (ebox-style-compute-subject
           (ecss-subject-create :type "box")
           (ebox-style-merge-declarations base override))))
    (should (equal (plist-get (ebox-style--box-values style) :padding-left)
                   '(px 24))))
  (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
    (ebox-style-add-rule ".card" '(:margin-inline-start (px 2)))
    (ebox-style-add-rule "#target" '(:margin-left (px 6)))
    (let ((style
           (ebox-style-compute-subject
            (ecss-subject-create
             :type "box" :id "target" :classes '("card"))
            nil)))
      (should (equal (plist-get (ebox-style--box-values style) :margin-left)
                     '(px 6))))))

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

(ert-deftest ebox-author-declaration-is-one-atomic-normalization-group ()
  "One author group rejects overlaps while later cascade groups may override."
  (dolist (declarations
           '((:padding ((lh 1) (ch 1)) :padding-left (ch 2))
             (:border "red" :border-top none)
             (:gap ((lh 1) (ch 1)) :row-gap (lh 2))
             (:flex-flow (row wrap) :flex-wrap nowrap)
             (:flex (1 1 auto) :flex-grow 2)
             (:border-top-p t :border-top-style none)))
    (should-error
     (ebox-style-compile-declarations declarations t)
     :type 'ecss-invalid-declaration))
  (should
   (equal
    (ebox-style-merge-declarations
     (ebox-style-compile-declarations '(:gap ((lh 1) (ch 1))) t)
     (ebox-style-compile-declarations '(:row-gap (lh 2)) t))
    '(ebox/row-gap (lh 2) ebox/column-gap (ch 1)))))

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
    (should (equal '(text box)
                   (plist-get (ebox-style-property :bgcolor) :contexts)))))

(ert-deftest ebox-style-border-present-is-a-typed-shorthand-not-an-alias ()
  "The concise border boolean should expand to canonical width and style."
  (should
   (equal (ebox-style-compile-declarations '(:border-top-p t) t)
          '(ebox/border-top-width (px 1) ebox/border-top-style solid)))
  (should
   (equal (ebox-style-compile-declarations '(:border-top-p nil) t)
          '(ebox/border-top-width (px 0) ebox/border-top-style none)))
  (should (eq (ebox-style-canonical-name :border-top-p) :border-top-p)))

(ert-deftest ebox-border-width-requires-an-explicit-length ()
  "Border declarations retain explicit lengths and reject singleton syntax."
  (should
   (equal
    (ebox-style-compile-declarations '(:border ((px 1) solid "#687386")) t)
    '(ebox/border-top-width (px 1) ebox/border-top-style solid
      ebox/border-top-color "#687386"
      ebox/border-right-width (px 1) ebox/border-right-style solid
      ebox/border-right-color "#687386"
      ebox/border-bottom-width (px 1) ebox/border-bottom-style solid
      ebox/border-bottom-color "#687386"
      ebox/border-left-width (px 1) ebox/border-left-style solid
      ebox/border-left-color "#687386")))
  (should-error
   (ebox-style-compile-declarations
    '(:border ((1) solid "#687386")) t)
   :type 'error))

(ert-deftest ebox-border-engine-projection-keeps-exact-pixels ()
  "Border projection must not reinterpret pixels as character columns."
  (cl-letf (((symbol-function 'ebox--size-character-width)
             (lambda (&optional _box) 7)))
    (let ((projected
           (ebox-style--expand-engine-plist
            '(:border-left-width (px 1) :border-left-style solid
              :border-right-width (px 2) :border-right-style solid
              :padding-left (ch 1) :margin-right (px 3)))))
      (should (equal projected
                     '(:border-left-pixel (px 1) :border-left-style solid
                       :border-right-pixel (px 2) :border-right-style solid
                       :padding-left-pixel (ch 1) :margin-right-pixel (px 3))))
      (should (= (ebox-get projected :border-left-pixel) 1))
      (should (= (ebox-get projected :border-right-pixel) 2))
      (should (= (ebox-get projected :padding-left-pixel) 7))
      (should (= (ebox-get projected :margin-right-pixel) 3))))
  (should
   (equal
    (ebox-style--expand-engine-plist
     '(:border-left-width (px 2) :border-left-style none))
    '(:border-left-pixel 0 :border-left-style none)))
  (should
   (equal
    (ebox-style--expand-engine-plist
     '(:border-top-width (px 2) :border-top-style solid))
    '(:border-top-pixel (px 2) :border-top-style solid))))

(ert-deftest ebox-style-declaration-cache-expands-shorthand-once ()
  "A cached declaration should not expand its shorthand again."
  (let ((calls 0)
        (original (symbol-function 'ebox-style--padding-shorthand)))
    (clrhash ebox-style--declaration-cache)
    (cl-letf (((symbol-function 'ebox-style--padding-shorthand)
               (lambda (value)
                 (cl-incf calls)
                 (funcall original value))))
      (ebox-style-compile-declarations '(:padding ((lh 1) (ch 1))) t)
      (ebox-style-compile-declarations '(:padding ((lh 1) (ch 1))) t))
    (should (= calls 1))))

(ert-deftest ebox-style-border-present-rejects-owned-longhand-conflicts ()
  "One source should not mix the boolean border shorthand with its outputs."
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-p t :border-top-width (px 2)) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-style dashed :border-top-p t) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-p t :border-top ((px 2) dashed "red")) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-top-p t :border-width (px 2)) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-style dashed :border-top-p t) t)
   :type 'error)
  (should-error
   (ebox-style-compile-declarations
    '(:border-bottom-p t :border ((px 1) solid "red")) t)
   :type 'error))

(ert-deftest ebox-canonical-text-constructor-is-renderable-and-typed ()
  "A canonical TextNode should retain its kind, source, and string value."
  (let* ((input (ebox-dsl-test--text-create
                 :value "Hello" :source-handle 'source-text))
         (node (ebox-dsl-test--root input)))
    (should (ebox-text-node-p node))
    (should-not (ebox-box-node-p node))
    (should (eq (ebox-source-handle-id (ebox-node-source-handle node))
                'source-text))
    (should (string= (ebox-text-node-value node) "Hello"))
    (should (string= (ebox-dsl-test--plain input) "Hello"))
    (should-not (ebox-tree-node-visible-overflow-p node))))

(ert-deftest ebox-canonical-text-constructor-rejects-non-text-shapes ()
  "A canonical TextNode should have exactly one string payload."
  (should-error (ebox-dsl-test--text-create :value 7) :type 'error)
  (should-error (ebox-dsl-test--text-create :value "A" :content "B") :type 'error)
  (should-error (ebox-dsl-test--text-create :value "A" :children nil) :type 'error)
  (let* ((builder (ebox-source-builder-create))
         (handle (ebox-source-builder-bind builder :declarations nil)))
    (should-error
     (ebox-text-create
      :value "A" :source-handle handle
      :owned-facts (ebox-canonical-facts-from-declarations 'text nil)
      :color "red")
     :type 'error))
  (should-error (ebox-text-create :value "A") :type 'error)
  (should-error
   (ebox-text-create :value "A" :source-handle 'raw-source)
   :type 'error)
  (should-error (ebox-build '(text :wrap-mode none "A")) :type 'error)
  (should-error
   (ebox-dsl-test--text-create :value "A" :value "B")
   :type 'error)
  (should-error
   (ebox-dsl-test--text-create :value "A" :source-handle 'a :source-handle 'b)
   :type 'error))

(ert-deftest ebox-canonical-box-uses-registered-runtime-defaults ()
  "A Box should materialize the definite defaults consumed by layout."
  (let* ((input (ebox-dsl-test--box-create
                 :layout (ebox-normal-layout-create) :children nil))
         (box (ebox-dsl-test--root input)))
    (should (eq (ebox-get box :overflow) 'scroll))
    (dolist (property '(:padding-left-pixel :padding-right-pixel
                        :padding-top-height :padding-bottom-height
                        :margin-left-pixel :margin-right-pixel
                        :margin-top-height :margin-bottom-height
                        :border-left-pixel :border-right-pixel))
      (should (zerop (ebox-get box property))))))

(ert-deftest ebox-render-cache-signature-ignores-derived-layout-proofs ()
  "A render must not invalidate its own canonical node cache key."
  (let* ((node (ebox-dsl-test--root
                (ebox-build '(box :width '(px 80) "Stable"))))
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
            (should (eq (ebox-style-node-specified-value
                         root :wrap-mode nil
                         (plist-get (ebox--buffer-render-state buffer)
                                    :source-index))
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
          (ebox-dsl-test--box-create
           :layout (ebox-normal-layout-create)
           :children (list (ebox-dsl-test--text-create :value "AB"))
           :width (list width) :wrap-mode 'char))
         (none-box
          (ebox-dsl-test--box-create
           :layout (ebox-normal-layout-create)
           :children (list (ebox-dsl-test--text-create :value "AB"))
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
       (ebox-dsl-test--box-create
        :layout (ebox-normal-layout-create)
        :children (list (ebox-dsl-test--text-create :value "paragraph"))
        :width '(100) :wrap-mode 'kp)))
    (should (equal justify-args '("paragraph" 100)))))

(ert-deftest ebox-canonical-normal-box-renders-inline-runs-and-blocks ()
  "Normal should retain typed children and honor inline/block boundaries."
  (let* ((text-input
          (ebox-dsl-test--text-create :value "A" :source-handle 'source-text))
         (text (ebox-dsl-test--root text-input))
         (second-text-input (ebox-dsl-test--text-create :value "B"))
         (second-text (ebox-dsl-test--root second-text-input))
         (inline-input
          (ebox-dsl-test--box-create
           :layout (ebox-normal-layout-create) :outer 'inline
           :width '(100)
           :children (list (ebox-dsl-test--text-create :value "A B"))))
         (inline (ebox-dsl-test--root inline-input))
         (block-input
          (ebox-dsl-test--box-create
           :layout (ebox-normal-layout-create)
           :children (list (ebox-dsl-test--text-create :value "C"))))
         (block (ebox-dsl-test--root block-input))
         (tail-input (ebox-dsl-test--text-create :value "D"))
         (tail (ebox-dsl-test--root tail-input))
         (layout (ebox-normal-layout-create))
         (box-input
          (ebox-dsl-test--box-create
           :layout layout
           :children (list text-input second-text-input inline-input
                           block-input tail-input)
           :source-handle 'source-box
           :width '(50) :overflow 'visible))
         (box (ebox-dsl-test--root box-input))
         (rendered (ebox-render box-input))
         (rendered-lines (ebox-string-lines rendered))
         (lines (mapcar (lambda (line)
                          (string-trim-right
                           (substring-no-properties line)))
                        rendered-lines)))
    (should (ebox-box-node-p box))
    (should-not (ebox-text-node-p box))
    (should (eq (ebox-source-handle-id (ebox-node-source-handle box))
                'source-box))
    (should (eq (ebox-layout-config-kind
                 (ebox-box-node-layout box))
                'normal))
    (should (equal (ebox-box-node-children box)
                   (list text second-text inline block tail)))
    (should (equal (ebox--computed-display text) '(inline flow)))
    (should (equal lines '("AB" "A B" "C" "D")))
    (should (>= (ebox--string-pixel-width (nth 1 rendered-lines)) 100))
    (let ((ebox-style-stylesheet (ecss-stylesheet-create)))
      (let* ((revised-text
              (ebox-dsl-test--revise-source
               text-input :class "fixed-inline-text"))
             (revised-box
              (ebox-dsl-test--box-create
               :layout layout
               :children (list revised-text second-text-input inline-input
                               block-input tail-input)
               :source-handle 'source-box
               :width '(50) :overflow 'visible)))
      (ebox-style-add-rule ".fixed-inline-text" (list :outer 'block))
        (should-error (ebox-render revised-box) :type 'error)))
    (cl-labels
        ((normal-lines
          (value &optional width)
          (mapcar #'substring-no-properties
                  (ebox-string-lines
                   (ebox-render
                    (apply #'ebox-dsl-test--box-create
                           :layout (ebox-normal-layout-create)
                           :children (list (ebox-dsl-test--text-create :value value))
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
              (ebox-dsl-test--box-create
               :layout (ebox-normal-layout-create) :outer 'inline
               :width '(10)
               :children (list (ebox-dsl-test--text-create :value "I"))))
             (zero-parent
              (ebox-dsl-test--box-create
               :layout (ebox-normal-layout-create) :width '(0)
               :overflow 'visible :children (list inline-zero))))
        (should (= (ebox-string-height (ebox-render zero-parent)) 1))))))

(ert-deftest ebox-canonical-row-box-retains-and-renders-typed-children ()
  "A Row Box should retain one Box identity around all typed children."
  (let* ((left-input
          (ebox-dsl-test--text-create :value "A" :source-handle 'left))
         (right-input
          (ebox-dsl-test--text-create :value "B\nB\nB" :source-handle 'right))
         (left (ebox-dsl-test--root left-input))
         (right (ebox-dsl-test--root right-input))
         (box-input
          (ebox-dsl-test--box-create
           :layout (ebox-row-layout-create :item-gap '(px 5) :cross-align 'center)
           :children (list left-input right-input)
           :source-handle 'row))
         (box (ebox-dsl-test--root box-input)))
    (should (ebox-box-node-p box))
    (should (eq (ebox-source-handle-id (ebox-node-source-handle box))
                'row))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout box)) 'row))
    (should (equal (ebox-layout-config-props (ebox-box-node-layout box))
                   '(:item-gap (px 5) :cross-align center)))
    (should (equal (ebox-box-node-children box) (list left right)))
    (should (eq (ebox-tree-node-children box)
                (ebox-box-node-children box)))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 3))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 3))
    (should-not (plist-member box :ebox-content-node))
    (should (equal (ebox--computed-display box) '(block row)))
    (let* ((rendered (ebox-render box-input))
           (lines (ebox-string-lines rendered))
           (middle (nth 1 lines)))
      (should-not (string-match-p "A" (substring-no-properties (car lines))))
      (should (string-match-p "A.*B" (substring-no-properties middle)))
      (should (= (ebox--string-pixel-width middle)
                 (+ (ebox--string-pixel-width "A") 5
                    (ebox--string-pixel-width "B")))))))

(ert-deftest ebox-canonical-column-box-retains-and-renders-typed-children ()
  "A Column Box should retain one Box identity around all typed children."
  (let* ((top-input (ebox-dsl-test--text-create :value "A"))
         (bottom-input (ebox-dsl-test--text-create :value "BBB"))
         (top (ebox-dsl-test--root top-input))
         (bottom (ebox-dsl-test--root bottom-input))
         (box-input
          (ebox-dsl-test--box-create
           :layout (ebox-column-layout-create :item-gap '(lh 1) :cross-align 'end)
           :children (list top-input bottom-input)))
         (box (ebox-dsl-test--root box-input)))
    (should (ebox-box-node-p box))
    (should (eq (ebox-layout-config-kind (ebox-box-node-layout box)) 'column))
    (should (equal (ebox-layout-config-props (ebox-box-node-layout box))
                   '(:item-gap (lh 1) :cross-align end)))
    (should (equal (ebox-box-node-children box) (list top bottom)))
    (should (eq (ebox-tree-node-children box)
                (ebox-box-node-children box)))
    (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 3))
    (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 3))
    (should-not (plist-member box :ebox-content-node))
    (should (equal (ebox--computed-display box) '(block column)))
    (should (= (ebox-string-height (ebox-render box-input)) 3))
    (let ((lines (ebox-string-lines (ebox-render box-input))))
      (should (string-prefix-p " " (substring-no-properties (car lines))))
      (should (= (ebox--string-pixel-width (car lines))
                 (ebox--string-pixel-width (nth 2 lines)))))))

(ert-deftest ebox-canonical-simple-axis-config-validates-closed-schema ()
  "Row/Column configs should distinguish defaults from invalid explicit values."
  (dolist (constructor '(ebox-row-layout-create ebox-column-layout-create))
    (should (equal (ebox-layout-config-props (funcall constructor))
                   (list :item-gap
                         (if (eq constructor 'ebox-column-layout-create)
                             '(lh 0)
                           '(px 0))
                         :cross-align 'stretch)))
    (dolist (plist '((:item-gap nil) (:item-gap -1)
                     (:cross-align nil) (:cross-align bogus)
                     (:gap 1) (:item-gap 1 :item-gap 2)))
      (should-error (apply constructor plist) :type 'error))))

(ert-deftest ebox-canonical-flex-box-uses-one-box-identity-and-child-list ()
  "A FlexConfig should select the Box algorithm without a Flex runtime node."
  (let* ((left (ebox-dsl-test--text-create :value "A"))
         (right (ebox-dsl-test--text-create :value "B"))
         (layout (ebox-flex-layout-create))
         (input (ebox-dsl-test--box-create :layout layout
                                :children (list left right)
                                :width '(120)))
         (box (ebox-dsl-test--root input))
         (rendered (ebox-render input)))
    (should
     (equal (ebox-layout-config-props layout)
            '(:flex-direction row :flex-wrap nowrap
              :justify-content flex-start :align-items stretch
              :align-content stretch :row-gap (lh 0) :column-gap (px 0))))
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
     (ebox-dsl-test--box-create :layout invalid-direction :children nil)
     :type 'error)
    (should-error
     (ebox-dsl-test--box-create :layout extra-frame-prop :children nil)
     :type 'error)
    (should-error
     (ebox-dsl-test--box-create :layout cross-kind-props :children nil)
     :type 'error)))

(ert-deftest ebox-canonical-box-detaches-validated-layout-config ()
  "Caller and accessor mutations should not alter a constructed Box."
  (let* ((source-layout (ebox-flex-layout-create))
         (input (ebox-dsl-test--box-create
                 :layout source-layout
                 :children (list (ebox-dsl-test--text-create :value "A")
                                 (ebox-dsl-test--text-create :value "B"))))
         (box (ebox-dsl-test--root input))
         (exposed-layout (ebox-box-node-layout box)))
    (should-not (fboundp 'ebox-layout-config-validator))
    (setf (ebox-layout-config-props source-layout) '(:flex-direction bogus))
    (setf (ebox-layout-config-props exposed-layout) '(:width 999))
    (should (string= (string-trim-right
                      (substring-no-properties (ebox-render input)))
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
          :row-gap '(lh 2)
          :column-gap '(px 8))))
    (should
     (equal (ebox-layout-config-props layout)
            '(:flex-direction column-reverse :flex-wrap wrap
              :justify-content space-between :align-items center
              :align-content end :row-gap (lh 2) :column-gap (px 8))))
    (should (ebox-flex-layout-config-props-p
             (ebox-layout-config-props layout)))
    (should (ebox-box-node-p
             (ebox-dsl-test--root
              (ebox-dsl-test--box-create :layout layout :children nil))))))

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
    (let* ((layout (ebox-flex-layout-create :column-gap '(px 8)))
           (box (ebox-dsl-test--root
                 (ebox-dsl-test--box-create
                  :layout layout :children nil))))
      (should (equal (plist-get (ebox-layout-config-props layout) :column-gap)
                     '(px 8)))
      (should (equal (plist-get
                      (ebox-layout-config-props (ebox-box-node-layout box))
                      :column-gap)
                     '(px 8))))))

(ert-deftest ebox-canonical-grid-box-uses-one-box-identity-and-child-list ()
  "A GridConfig should select the Box algorithm without a Grid runtime node."
  (let* ((layout (ebox-grid-layout-create))
         (input (ebox-dsl-test--box-create
                 :layout layout
                 :children (list (ebox-dsl-test--text-create :value "A")
                                 (ebox-dsl-test--text-create :value "B"))
                 :width '(120)))
         (box (ebox-dsl-test--root input))
         (rendered (ebox-render input)))
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
                   ;; Two rows with the default zero gap occupy two lines.
                   '(120 120)))))

(ert-deftest ebox-canonical-grid-consumes-direct-child-placement ()
  "Grid placement should stay on child Boxes without grid-item wrappers."
  (let* ((later
          (ebox-dsl-test--box-create :layout (ebox-normal-layout-create)
                           :children (list (ebox-dsl-test--text-create :value "A"))
                           :grid-row 2))
         (earlier
          (ebox-dsl-test--box-create :layout (ebox-normal-layout-create)
                           :children (list (ebox-dsl-test--text-create :value "B"))
                           :grid-row 1))
         (box (ebox-dsl-test--box-create :layout (ebox-grid-layout-create)
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
         (apply #'ebox-dsl-test--box-create
                :layout (ebox-normal-layout-create)
                :children (list (ebox-dsl-test--text-create :value "A"))
                props))
       (parent (layout child)
         (ebox-dsl-test--box-create :layout layout :children (list child))))
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
    (let ((text (ebox-dsl-test--text-create :value "A")))
      (plist-put (ebox-dsl-test--root text) :flex-grow 1)
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
      (setq detached
            (ebox-dsl-test--revise-source
             detached :class "detached-flex-item"))
      (ebox-style-add-rule ".detached-flex-item" (list :flex-grow 1))
      (let ((ebox--render-root-parent-kind 'flex))
        (should (stringp (ebox-render detached))))
      ;; The dynamic context is exact and cannot authorize a later root.
      (should-error (ebox-render detached) :type 'error))
    (let ((ebox-style-stylesheet (ecss-stylesheet-create))
          (detached (child)))
      (setq detached
            (ebox-dsl-test--revise-source
             detached :class "detached-flex-item"))
      (ebox-style-add-rule ".detached-flex-item" (list :grid-row 1))
      (let ((ebox--render-root-parent-kind 'flex))
        (should-error (ebox-render detached) :type 'error)))
    ;; Internal layout and parent participation are orthogonal facts.
    (should
     (stringp
      (ebox-render
       (parent
        (ebox-grid-layout-create)
        (ebox-dsl-test--box-create
         :layout (ebox-flex-layout-create)
         :children (list (ebox-dsl-test--text-create :value "A"))
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
     (ebox-dsl-test--box-create :layout extra-frame-prop :children nil)
     :type 'error)
    (should-error
     (ebox-dsl-test--box-create :layout cross-kind-props :children nil)
     :type 'error)))

(ert-deftest ebox-grid-layout-create-normalizes-the-complete-config-schema ()
  "The typed Grid constructor should emit one canonical closed property set."
  (let* ((layout
          (ebox-grid-layout-create
           :grid-template-columns '((px 20) (fr 1))
           :grid-template-rows '((lh 1) auto)
           :grid-auto-columns '((px 30))
           :grid-auto-rows '((lh 2))
           :grid-auto-flow 'column
           :row-gap '(lh 2) :column-gap '(px 8)
           :justify-items 'center :align-items 'end
           :justify-content 'space-between :align-content 'center))
         (props (ebox-layout-config-props layout)))
    (should (equal (plist-get props :grid-template-columns)
                   '((:kind fixed :size (px 20)) (:kind fr :factor 1))))
    (should (equal (plist-get props :grid-template-rows)
                   '((:kind fixed :size (lh 1)) (:kind auto :factor 0))))
    (should (equal (plist-get props :grid-auto-columns)
                   '(:kind fixed :size (px 30))))
    (should (equal (plist-get props :grid-auto-rows)
                   '(:kind fixed :size (lh 2))))
    (should (equal (plist-get props :row-gap) '(lh 2)))
    (should (equal (plist-get props :column-gap) '(px 8)))
    (should (ebox-grid-layout-config-props-p props))
    (should (ebox-box-node-p
             (ebox-dsl-test--root
              (ebox-dsl-test--box-create :layout layout :children nil))))))

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
  (dolist (value '(min-content max-content))
    (should (ebox-grid-layout-create :grid-template-columns (list value)))
    (should (ebox-grid-layout-create :grid-template-rows (list value)))
    (should (ebox-grid-layout-create :grid-auto-columns value))
    (should (ebox-grid-layout-create :grid-auto-rows value)))
  (should
   (ebox-grid-layout-create
    :grid-template-columns '((repeat 2 (auto (fr 1))))))
  (dolist (plist '((:grid-auto-flow diagonal)
                   (:grid-template-columns (bogus))
                   (:grid-template-rows (bogus))
                   (:grid-template-columns (0fr))
                   (:grid-template-columns (0.0fr))
                   (:grid-template-columns (1fr))
                   (:grid-template-columns (fr 1))
                   (:grid-template-columns min-content)
                   (:grid-template-columns ((fr 0)))
                   (:grid-template-columns ((minmax (fr 1) auto)))
                   (:grid-template-columns
                    ((minmax (minmax (10) (20)) auto)))
                   (:grid-template-columns ((repeat 0 auto)))
                   (:grid-auto-columns ((repeat 2 auto)))
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
             :grid-template-columns '((px 20)) :column-gap '(px 8)))
           (box (ebox-dsl-test--root
                 (ebox-dsl-test--box-create :layout layout :children nil)))
           (props (ebox-layout-config-props (ebox-box-node-layout box))))
      (should (equal (plist-get props :column-gap) '(px 8)))
      (should (equal (plist-get (car (plist-get props :grid-template-columns))
                                :size)
                     '(px 20))))))

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
     (ebox-dsl-test--box-create :layout fr-minimum :children nil) :type 'error)
    (should-error
     (ebox-dsl-test--box-create :layout nested-minimum :children nil) :type 'error)))

(ert-deftest ebox-canonical-flex-consumes-direct-child-participation ()
  "Flex participation should stay on child Boxes without item wrappers."
  (let* ((left-text (ebox-dsl-test--text-create :value "A"))
         (right-text (ebox-dsl-test--text-create :value "B"))
         (left (ebox-dsl-test--box-create :layout (ebox-normal-layout-create)
                                :children (list left-text)
                                :order 2))
         (right (ebox-dsl-test--box-create :layout (ebox-normal-layout-create)
                                 :children (list right-text)
                                 :order 1))
         (box (ebox-dsl-test--box-create :layout (ebox-flex-layout-create)
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
  (let* ((child-input (ebox-dsl-test--text-create :value "A"))
         (child (ebox-dsl-test--root child-input))
         (row-input
          (ebox-dsl-test--box-create :layout (ebox-row-layout-create)
                                     :children (list child-input)))
         (column-input
          (ebox-dsl-test--box-create :layout (ebox-column-layout-create)
                                     :children (list child-input)))
         (row (ebox-dsl-test--root row-input))
         (column (ebox-dsl-test--root column-input)))
    (should (ebox-box-node-p row))
    (should (ebox-box-node-p column))
    (should-not (eq row child))
    (should-not (eq column child))
    (should (equal (ebox-tree-node-children row) (list child)))
    (should (equal (ebox-tree-node-children column) (list child)))
    (should (= (ebox-dsl-test--tree-count row (lambda (_node) t)) 2))
    (should (= (ebox-dsl-test--tree-count column (lambda (_node) t)) 2))
    (should (string= (ebox-dsl-test--plain row-input) "A"))
    (should (string= (ebox-dsl-test--plain column-input) "A"))))

(ert-deftest ebox-canonical-empty-layout-boxes-have-no-runtime-child ()
  "Empty layout Boxes should not synthesize layout identities."
  (dolist (layout (list (ebox-row-layout-create)
                        (ebox-column-layout-create)
                        (ebox-flex-layout-create)
                        (ebox-grid-layout-create)))
    (let* ((input (ebox-dsl-test--box-create
                   :layout layout :children nil))
           (box (ebox-dsl-test--root input)))
      (should (ebox-box-node-p box))
      (should-not (ebox-tree-node-children box))
      (should (= (ebox-dsl-test--tree-count box (lambda (_node) t)) 1))
      (should (= (ebox-dsl-test--tree-count box #'ebox-node-kind) 1))
      (should (string= (ebox-dsl-test--plain input) "")))))

(ert-deftest ebox-canonical-box-copy-keeps-one-authoritative-child-list ()
  "A copied Box should expose exactly its copied runtime children."
  (let* ((left-input (ebox-dsl-test--text-create :value "A"))
         (right-input (ebox-dsl-test--text-create :value "B"))
         (left (ebox-dsl-test--root left-input))
         (right (ebox-dsl-test--root right-input))
         (source-input
          (ebox-dsl-test--box-create :layout (ebox-row-layout-create)
                                     :children (list left-input right-input)))
         (source (ebox-dsl-test--root source-input))
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
  (let* ((builder (ebox-source-builder-create))
         (handle (ebox-source-builder-bind builder :declarations nil)))
    (should-error
     (ebox-box-create
      :layout (ebox-normal-layout-create) :children nil
      :source-handle handle
      :owned-facts (ebox-canonical-facts-from-declarations 'box nil)
      :bgcolor "red")
     :type 'error)))

(ert-deftest ebox-build-projects-source-style-without-polluting-canonical-geometry ()
  "Track the G4 boundary: author paint must leave canonical Box geometry."
  :expected-result :failed
  (let ((node (ebox-dsl-test--root
               (ebox-build '(box :background-color "red" "Paint")))))
    (should-not (ebox-get node :bgcolor))))

(ert-deftest ebox-canonical-box-requires-unique-reserved-fields ()
  "Typed Box reserved fields should never be missing or duplicated."
  (let ((normal (ebox-normal-layout-create)))
    (should-error (ebox-dsl-test--box-create :children nil) :type 'error)
    (should-error
     (ebox-dsl-test--box-create :layout normal :layout normal :children nil)
     :type 'error)
    (should-error
     (ebox-dsl-test--box-create :layout normal :children nil :children nil)
     :type 'error)
    (should-error
     (ebox-dsl-test--box-create :layout normal :outer nil :children nil)
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
           (node (ebox-dsl-test--root (ebox-build form))))
      (should (eq (ebox-node-kind node) kind))
      (should (ebox-source-handle-p (ebox-node-source-handle node)))
      (should (symbolp
               (ebox-source-handle-id (ebox-node-source-handle node))))
      (should-not
       (eq (ebox-source-handle-id (ebox-node-source-handle node))
           (intern-soft
            (symbol-name
             (ebox-source-handle-id
              (ebox-node-source-handle node))))))
      (when layout-kind
        (should
         (eq (ebox-layout-config-kind (ebox-box-node-layout node))
             layout-kind)))))
  (let ((inline-row (ebox-build '(row :outer inline "A" "B"))))
    (should (equal (ebox--computed-display (ebox-dsl-test--root inline-row))
                   '(inline row)))))

(ert-deftest ebox-build-gives-equal-forms-distinct-source-identities ()
  "Structurally equal author forms must not share opaque source identity."
  (let* ((node (ebox-dsl-test--root
                (ebox-build '(row (box "same") (box "same")))))
         (children (ebox-box-node-children node)))
    (should-not
     (equal
      (ebox-source-handle-id
       (ebox-node-source-handle (car children)))
      (ebox-source-handle-id
       (ebox-node-source-handle (cadr children)))))))

(ert-deftest ebox-build-validates-form-owned-config-and-direct-participation ()
  "Layout config belongs to its form; item roles belong to direct child Boxes."
  (let* ((flex
          (ebox-build
           '(flex :width '(px 300) :gap '((lh 1) (px 5))
             (box :flex 1 "A")
             "B")))
         (flex-child (car (ebox-box-node-children
                           (ebox-dsl-test--root flex))))
         (grid
          (ebox-build
           '(grid :grid-template-columns '((px 20) (px 20))
             (box :grid-column '(1 :span 2) "Header"))))
         (grid-child (car (ebox-box-node-children
                           (ebox-dsl-test--root grid)))))
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
   (ebox-build (ebox-test-box (ebox-test-text "raw runtime node")))
   :type 'error)
  (should-error
   (ebox-build
    (list 'box :color (tp-computed (lambda () "#112233")) "dynamic"))
   :type 'error)
  (should-error
   (ebox-build
   (list 'box :color
          (tp-paint-slot-create '(:foreground "#112233")) "slot"))
   :type 'error))

(ert-deftest ebox-build-rejects-explicit-nil-outside-boolean-grammar ()
  "Internal nil initial values must not widen the public author grammar."
  (dolist (form
           '((text :color nil "A")
             (text :font-size nil "A")
             (grid :grid-template-columns nil "A")
             (grid :grid-template-rows nil "A")
             (grid :grid-auto-columns nil "A")
             (grid :grid-auto-rows nil "A")))
    (should-error (ebox-build form) :type 'error))
  (should (ebox-build '(box :border-top-p nil "A"))))

(ert-deftest ebox-source-metadata-uses-the-frozen-public-grammar ()
  "Key, class, and id should remain source facts with closed value domains."
  (should
   (ebox-build
    '(box :key stable :id 42 :class (card selected) "Valid")))
  (dolist (form '((box :key nil "bad")
                  (box :key (not stable) "bad")
                  (box :id nil "bad")
                  (box :id 1.5 "bad")
                  (box :class (card 2) "bad")
                  (box :class (card . selected) "bad")))
    (should-error (ebox-build form) :type 'error)))

(provide 'ebox-dsl-tests)
;;; ebox-dsl-tests.el ends here
