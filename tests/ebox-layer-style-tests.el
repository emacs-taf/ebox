;;; ebox-layer-style-tests.el --- Layer style boundary tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'ebox-style)
(require 'ebox)

(defconst ebox-layer-style-test--defaults
  '(:position static :left (px 0) :top (lh 0)
    :z-index 0 :layer local :anchor nil :placement bottom-start)
  "Initial values of the public layer style properties.")

(defconst ebox-layer-style-test--values
  '(:position absolute :left (ch -1.25) :top (lh -0.5)
    :z-index -2 :layer root :anchor menu-button :placement top-end)
  "Nondefault layer declarations covering every public layer property.")

(ert-deftest ebox-layer-style-schema-owns-geometry-facts ()
  "Layer properties use box geometry projections without item participation."
  (cl-loop for (name initial) on ebox-layer-style-test--defaults by #'cddr
           for property = (ebox-style-property name)
           do (should (equal (plist-get property :initial) initial))
           do (should (equal (plist-get property :contexts)
                             '(box row column flex grid)))
           do (should-not (plist-get property :inherits))
           do (should (eq (plist-get property :signature) 'layout))
           do (should (eq (ebox-style-dirty-kind name) 'geometry))
           do (should (equal (plist-get property :impacts) '(geometry)))
           do (should (equal (plist-get property :projections) '(layout)))
           do (should (equal (plist-get property :engine-targets) (list name)))
           do (should (eq (plist-get property :owner) 'ebox-box-frame)))
  (dolist (name '(:layer :anchor :placement))
    (should (eq (plist-get (ebox-style-property name) :namespace) 'ebox))))

(ert-deftest ebox-layer-style-accepts-existing-box-layouts-only ()
  "Every box layout accepts layer facts, while Text rejects every property."
  (dolist (tag '(box row column flex grid))
    (let ((compiled (ebox-style-compile-form
                     tag ebox-layer-style-test--values)))
      (cl-loop for (name value) on ebox-layer-style-test--values by #'cddr
               do (should (equal (plist-get compiled (ebox-style-schema-id name))
                                 value)))))
  (cl-loop for (name value) on ebox-layer-style-test--defaults by #'cddr
           do (should-error (ebox-style-compile-form 'text (list name value)))))

(ert-deftest ebox-layer-style-enums-and-anchor-grammar ()
  "Public enums, signed integer depth, and optional semantic anchors compile."
  (dolist (case '((:position static relative absolute)
                  (:z-index -100 0 100)
                  (:layer local root)
                  (:anchor nil menu-button "menu-button")
                  (:placement bottom-start bottom-end top-start top-end)))
    (dolist (value (cdr case))
      (should (equal (ebox-style-compile-form 'box (list (car case) value))
                     (list (ebox-style-schema-id (car case)) value))))))

(ert-deftest ebox-layer-style-rejects-invalid-static-declarations ()
  "Invalid layer values signal at both DSL and stylesheet boundaries."
  (dolist (case '((:position nil t fixed sticky normal "absolute" (absolute))
                  (:z-index nil t auto 1.0 -1.5 "2" (px 2) (lambda () 2))
                  (:layer nil t absolute global "root" (root))
                  (:anchor 1 1.5 (target) (:id target) [target])
                  (:placement nil t bottom center left "top-end" (top-end))))
    (dolist (value (cdr case))
      (ert-info ((format "%S rejects %S" (car case) value))
        (should-error (ebox-style-compile-form 'box (list (car case) value)))
        (should-error (ebox-style-compile-declarations
                       (list (car case) value) t))))))

(ert-deftest ebox-layer-style-signed-offset-axis-matrix ()
  "Signed offsets accept only typed lengths from their rendering axis."
  (dolist (case '((:left inline) (:top block)))
    (dolist (unit '(px ch vw lh vh %))
      (dolist (amount '(-2 -0.25 0 0.25 2))
        (let ((declarations (list (car case) (list unit amount))))
          (ert-info ((format "%S" declarations))
            (if (memq unit (cdr (assq (cadr case) ebox-size-axis-units)))
                (should (ebox-style-compile-form 'box declarations))
              (should-error (ebox-style-compile-form 'box declarations)
                            :type 'ebox-size-error)))))))
  (dolist (name '(:left :top))
    (dolist (value '(nil auto none 0 -2 0.25 (2) (px) (lh 1 2)
                    (em 1) (px "1") (lh -1.0e+INF) (px 0.0e+NaN)
                    (calc 2) (calc (/ (% 2) 0))))
      (should-error (ebox-style-compile-form 'box (list name value))))))

(ert-deftest ebox-layer-style-offset-expressions-preserve-axis-and-sign ()
  "Expression operands keep axis validation even when they cancel out."
  (dolist (case '((:left (calc (- (ch 1) (% 50))))
                  (:left (min (px -2) (vw -10)))
                  (:left (clamp (ch -3) (% -20) (px 4)))
                  (:top (calc (+ (lh -0.5) (vh 10))))
                  (:top (max (lh -2) (% -30)))
                  (:top (clamp (lh -3) (% -20) (vh 4)))))
    (should (equal (ebox-style-compile-form 'box case)
                   (list (ebox-style-schema-id (car case)) (cadr case)))))
  (dolist (case '((:left (calc (* 0 (lh -1))))
                  (:left (min (ch -1) (vh 0)))
                  (:top (calc (* 0 (px -1))))
                  (:top (max (lh -1) (vw 0)))))
    (should-error (ebox-style-compile-form 'box case) :type 'ebox-size-error)))

(ert-deftest ebox-layer-style-defaults-do-not-inherit ()
  "A child starts with layer defaults despite its parent's layer facts."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (subject (ecss-subject-create :type "box"))
         (parent (ebox-style-compute-subject
                  subject (ebox-style-compile-form
                           'box ebox-layer-style-test--values)))
         (child (ebox-style-compute-subject subject nil parent)))
    (cl-loop for (name initial) on ebox-layer-style-test--defaults by #'cddr
             do (should (equal (ebox-style-computed-value child name)
                               initial)))))

(ert-deftest ebox-layer-style-projection-preserves-contextual-offsets ()
  "Projection retains signed fractional lengths for final used placement."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (style (ebox-style-compute-subject
                 (ecss-subject-create :type "box")
                 (ebox-style-compile-form
                  'box ebox-layer-style-test--values)))
         (snapshot (ebox-style--computed-snapshot style))
         (projected (ebox-style--expand-engine-plist
                     (ebox-style--box-values style snapshot)))
         (text (ebox-style--text-values style snapshot))
         (item (ebox-style--context-values style 'item)))
    (cl-loop for (name value) on ebox-layer-style-test--values by #'cddr
             do (should (equal (plist-get projected name) value))
             do (should-not (plist-member text name))
             do (should-not (plist-member item name)))))

(ert-deftest ebox-layer-style-changes-exclude-paint-only-proof ()
  "A change to any layer declaration changes the layout signature."
  (cl-loop for (name value) on ebox-layer-style-test--values by #'cddr
           for old = (ebox-style-compile-form
                      'box (list name (plist-get
                                       ebox-layer-style-test--defaults name)))
           for new = (ebox-style-compile-form 'box (list name value))
           do (should-not (ebox-style--paint-declarations-equivalent-p old new))
           do (should-not (equal (ebox-style-signature old '(layout))
                                 (ebox-style-signature new '(layout))))
           do (should-not (ebox-style-signature new '(paint)))))

(ert-deftest ebox-layer-style-runtime-removal-restores-defaults ()
  "Removing or resetting declarations clears every old box layer fact."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (subject (ecss-subject-create :type "box"))
         (positioned (ebox-style-compute-subject
                      subject (ebox-style-compile-form
                               'box ebox-layer-style-test--values))))
    (dolist (tag '(box row column flex grid))
      (dolist (declarations (list nil ebox-layer-style-test--defaults))
        (let* ((node (ebox-canonical-input--single-root
                      (ebox-build (list tag "Unchanged")) "layer style test"))
               (children (ebox-tree-node-children node))
               (config (plist-get node :ebox-layout-config))
               (reset (ebox-style-compute-subject
                       subject (ebox-style-compile-form 'box declarations))))
          (ebox-style-apply-computed node positioned)
          (ebox-style-apply-computed node reset)
          (cl-loop for (name initial) on ebox-layer-style-test--defaults by #'cddr
                   do (should (equal (plist-get node name) initial)))
          (should (equal (ebox-tree-node-children node) children))
          (should (equal (plist-get node :ebox-layout-config) config)))))))

(ert-deftest ebox-layer-style-runtime-transfer-preserves-current-projection ()
  "Source-stable transfers copy layer values and restore cleared defaults."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (subject (ecss-subject-create :type "box")))
    (dolist (tag '(box row column flex grid))
      (dolist (declarations (list ebox-layer-style-test--values nil))
        (let* ((old (ebox-canonical-input--single-root
                     (ebox-build (list tag "Old")) "layer style test"))
               (new (ebox-canonical-input--single-root
                     (ebox-build (list tag "New")) "layer style test"))
               (children (ebox-tree-node-children new))
               (style (ebox-style-compute-subject
                       subject (ebox-style-compile-form 'box declarations))))
          ;; Start both nodes with stale nondefaults, so copying a cleared
          ;; projection must overwrite them as well as retaining active facts.
          (ebox-style-apply-computed
           old (ebox-style-compute-subject
                subject (ebox-style-compile-form
                         'box ebox-layer-style-test--values)))
          (ebox-style-apply-computed old style)
          (ebox-style-apply-computed
           new (ebox-style-compute-subject
                subject (ebox-style-compile-form
                         'box (if declarations
                                  ebox-layer-style-test--defaults
                                ebox-layer-style-test--values))))
          (ebox-style--transfer-computed-projection old new style)
          (cl-loop for (name value)
                   on (or declarations ebox-layer-style-test--defaults) by #'cddr
                   do (should (equal (plist-get new name) value)))
          (should (equal (ebox-tree-node-children new) children)))))))

(ert-deftest ebox-layer-style-stylesheet-updates-reset-runtime-projection ()
  "Changing and removing a rule updates the same canonical node's fields."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (node (ebox-canonical-input--single-root
                (ebox-build '(box :class "panel" "Panel")) "layer style test"))
         (subject (ecss-subject-create :type "box" :classes '("panel"))))
    (dolist (values (list ebox-layer-style-test--values
                         '(:position relative :left (px 3)
                           :top (lh 2) :z-index 10 :layer local :anchor nil
                           :placement bottom-end)
                         ebox-layer-style-test--defaults))
      (ebox-style-add-rule ".panel" values)
      (ebox-style-apply-computed
       node (ebox-style-compute-subject subject nil))
      (cl-loop for (name value) on values by #'cddr
               do (should (equal (plist-get node name) value))))
    (ebox-style-add-rule ".panel" ebox-layer-style-test--values)
    (ebox-style-apply-computed node (ebox-style-compute-subject subject nil))
    (setq ebox-style-stylesheet (ecss-stylesheet-create))
    (ebox-style-apply-computed node (ebox-style-compute-subject subject nil))
    (cl-loop for (name value) on ebox-layer-style-test--defaults by #'cddr
             do (should (equal (plist-get node name) value)))))

(ert-deftest ebox-layer-style-runtime-defaults-stay-off-text ()
  "Applying a style with layer facts does not materialize them onto Text."
  (let* ((ebox-style-stylesheet (ecss-stylesheet-create))
         (node (ebox-canonical-input--single-root
                (ebox-build '(text "Text")) "layer style test"))
         (style (ebox-style-compute-subject
                 (ecss-subject-create :type "text")
                 (ebox-style-compile-form
                  'box ebox-layer-style-test--values))))
    (ebox-style-apply-computed node style)
    (cl-loop for (name _value) on ebox-layer-style-test--defaults by #'cddr
             do (should-not (plist-member node name)))))

(provide 'ebox-layer-style-tests)
;;; ebox-layer-style-tests.el ends here
