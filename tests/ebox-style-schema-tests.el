;;; ebox-style-schema-tests.el --- M2a style schema truth gates -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'benchmark)
(require 'ebox)
(require 'ebox-fixtures)

(defconst ebox-style-schema-test--legacy-nondefault-rules
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
                          :border-top-style :border-top-color)
                 :mode wsc)
    (:border-right :expand (:border-right-width
                            :border-right-style :border-right-color)
                   :mode wsc)
    (:border-bottom :expand (:border-bottom-width
                             :border-bottom-style :border-bottom-color)
                    :mode wsc)
    (:border-left :expand (:border-left-width
                           :border-left-style :border-left-color)
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
    (:border-top-width :to :border-top-pixel :conv border-pixel)
    (:border-top-color :to :border-top-color :conv color)
    (:border-bottom-width :to :border-bottom-pixel :conv border-pixel)
    (:border-bottom-color :to :border-bottom-color :conv color)
    (:border-left-width :to :border-left-pixel :conv border-pixel)
    (:border-left-color :to :border-left-color :conv color)
    (:border-right-width :to :border-right-pixel :conv border-pixel)
    (:border-right-color :to :border-right-color :conv color)
    (:width :to :width :conv preferred-size)
    (:min-width :to :min-width :conv min-size)
    (:max-width :to :max-width :conv max-size)
    (:outer :to nil)
    (:color :to :color :conv color)
    (:background-color :to :bgcolor :conv color)
    (:bgcolor :to :bgcolor :conv color)
    (:text-decoration-color :to :text-decoration-color :conv color)
    (:display :to nil))
  "Non-default projection rules from the pre-E4 engine table.")

(defun ebox-style-schema-test--legacy-rule (property)
  "Return pre-E4 projection rule for PROPERTY."
  (cdr (assq property ebox-style-schema-test--legacy-nondefault-rules)))

(defun ebox-style-schema-test--current-explicit-rules ()
  "Return every definition-owned and internal non-default projection rule."
  (append
   (cl-mapcan
    (lambda (definition)
      (when-let* ((rule (plist-get definition :engine-projection)))
        (mapcar (lambda (name) (cons name (copy-tree rule)))
                (cons (plist-get definition :name)
                      (copy-sequence (plist-get definition :aliases))))))
    ebox-style--property-definitions)
   (copy-tree ebox-style--internal-engine-projection-rules)))

(defun ebox-style-schema-test--sorted-rules (rules)
  "Return a stable detached ordering of projection RULES."
  (sort (copy-tree rules)
        (lambda (left right)
          (string< (symbol-name (car left))
                   (symbol-name (car right))))))

(defun ebox-style-schema-test--legacy-rule-comparisons (property)
  "Return comparisons needed by the pre-E4 linear lookup for PROPERTY."
  (let ((comparisons 0))
    (catch 'found
      (dolist (entry ebox-style-schema-test--legacy-nondefault-rules)
        (cl-incf comparisons)
        (when (eq property (car entry))
          (throw 'found comparisons))))
    comparisons))

(defun ebox-style-schema-test--legacy-expand-property (property value)
  "Expand pre-E4 PROPERTY and VALUE into private engine fields."
  (let ((rule (ebox-style-schema-test--legacy-rule property)))
    (cond
     ((null rule) (list property value))
     ((plist-get rule :expand)
      (let* ((targets (plist-get rule :expand))
             (parts
              (ebox-style--split-value
               value (plist-get rule :mode) (length targets))))
        (cl-mapcan #'ebox-style-schema-test--legacy-expand-property
                   targets parts)))
     ((plist-member rule :to)
      (when-let* ((target (plist-get rule :to)))
        (list target
              (ebox-style--convert value (plist-get rule :conv)))))
     (t (list property value)))))

(defun ebox-style-schema-test--legacy-expand-plist (plist)
  "Project PLIST through the complete pre-E4 artifact table."
  (let (expanded)
    (cl-loop for (property value) on plist by #'cddr
             do (setq expanded
                      (nconc
                       expanded
                       (ebox-style-schema-test--legacy-expand-property
                        property value))))
    (ebox-style--apply-border-used-widths
     (ebox-style--validate-edge-longhands expanded))))

(ert-deftest ebox-style-schema-is-the-only-public-projection-truth ()
  "Every public property exposes one schema-owned engine projection."
  (should ebox-style--engine-projection-schema-valid-p)
  (should-not (boundp 'ebox-style--engine-projection-rules))
  (dolist (definition ebox-style--property-definitions)
    (let* ((name (plist-get definition :name))
           (metadata (ebox-style-property name))
           (targets (ebox-style--engine-projection-targets name)))
      (should (equal (plist-get metadata :engine-projection)
                     (plist-get definition :engine-projection)))
      (should (equal (plist-get metadata :engine-targets) targets))
      (should (equal (plist-get metadata :impacts)
                     (ebox-style--schema-impacts definition)))
      (should (equal (plist-get metadata :projections)
                     (ebox-style--schema-projections definition)))
      (should (plist-get metadata :owner))
      (when-let* ((expanded
                   (plist-get (plist-get definition :engine-projection)
                              :expand)))
        (dolist (target expanded)
          (let ((target-definition
                 (ebox-style--definition-for-name target)))
            (should target-definition))))
      (dolist (alias (plist-get definition :aliases))
        (should (equal (ebox-style--engine-projection-targets alias)
                       targets))))))

(ert-deftest ebox-style-schema-retains-only-engine-internal-exceptions ()
  "Only fields outside the public vocabulary may use the internal rule table."
  (should
   (equal (mapcar #'car ebox-style--internal-engine-projection-rules)
          '(:display)))
  (dolist (entry ebox-style--internal-engine-projection-rules)
    (should-not (ebox-style--definition-for-name (car entry))))
  (should
   (equal
    (ebox-style-schema-test--sorted-rules
     (ebox-style-schema-test--current-explicit-rules))
    (ebox-style-schema-test--sorted-rules
     ebox-style-schema-test--legacy-nondefault-rules)))
  (dolist (entry ebox-style-schema-test--legacy-nondefault-rules)
    (let ((name (car entry))
          (rule (cdr entry)))
      (if (eq name :display)
          (should (equal (ebox-style--get-ebox-rule name) rule))
        (should (ebox-style--definition-for-name name))
        (should (equal (ebox-style--get-ebox-rule name) rule))))))

(ert-deftest ebox-style-schema-preserves-pre-e4-engine-artifacts ()
  "Definition-owned projection remains property-for-property equivalent."
  (dolist
      (fixture
       '((:padding (1 (2) 3 (4))
          :margin (5 (6) 7 (8))
          :padding-inline ((9) (10))
          :margin-block (11 12))
         (:border (2 solid "#123456")
          :border-width (1 2 3 4)
          :border-style (solid solid none solid)
          :border-color ("#111111" "#222222" "#333333" "#444444"))
         (:width (240) :min-width (40) :max-width none
          :height 4 :min-height 1 :max-height 8
          :outer block :display flex)
         (:color "#102030" :background-color "#405060"
          :bgcolor "#708090" :text-decoration-color "#A0B0C0"
          :text-decoration-line underline :visibility hidden)
         (:padding-block-start 2 :padding-inline-end (3)
          :padding-block-end 4 :padding-inline-start (5)
          :margin-block-start 6 :margin-inline-end (7)
          :margin-block-end 8 :margin-inline-start (9))))
    (should
     (equal (ebox-style--expand-engine-plist (copy-tree fixture))
            (ebox-style-schema-test--legacy-expand-plist
             (copy-tree fixture))))))

(ert-deftest ebox-style-schema-malformed-projections-fail-fast ()
  "Ambiguous, missing, or cyclic projection declarations are rejected."
  (let ((ambiguous (copy-tree ebox-style--property-definitions))
        (missing (copy-tree ebox-style--property-definitions))
        (cyclic (copy-tree ebox-style--property-definitions))
        (alias-name-collision (copy-tree ebox-style--property-definitions))
        (id-name-collision (copy-tree ebox-style--property-definitions))
        (alias-id-collision (copy-tree ebox-style--property-definitions)))
    (plist-put (car ambiguous) :engine-projection
               '(:expand (:color) :mode same :to :color))
    (should-error
     (ebox-style--validate-engine-projection-definitions ambiguous)
     :type 'ebox-style-schema-error)
    (plist-put (car missing) :engine-projection
               '(:expand (:not-an-ebox-property) :mode same))
    (should-error
     (ebox-style--validate-engine-projection-definitions missing)
     :type 'ebox-style-schema-error)
    (plist-put (car cyclic) :engine-projection
               '(:expand (:color) :mode same))
    (should-error
     (ebox-style--validate-engine-projection-definitions cyclic)
     :type 'ebox-style-schema-error)
    (plist-put (car alias-name-collision) :aliases
               (list (plist-get (nth 1 alias-name-collision) :name)))
    (should-error
     (ebox-style--validate-engine-projection-definitions alias-name-collision)
     :type 'ebox-style-schema-error)
    (plist-put (nth 1 id-name-collision) :id
               (plist-get (car id-name-collision) :name))
    (should-error
     (ebox-style--validate-engine-projection-definitions id-name-collision)
     :type 'ebox-style-schema-error)
    (plist-put (car alias-id-collision) :aliases
               (list (plist-get (nth 1 alias-id-collision) :id)))
    (should-error
     (ebox-style--validate-engine-projection-definitions alias-id-collision)
     :type 'ebox-style-schema-error)))

(ert-deftest ebox-style-schema-performance-uses-one-lookup-per-property ()
  "Schema-owned lookup improves parent linear scans to O(1) per property."
  (let ((names
         (mapcar (lambda (definition) (plist-get definition :name))
                 ebox-style--property-definitions))
        (lookups 0)
        (legacy-comparisons 0)
        (original (symbol-function 'ebox-style--property))
        benchmark)
    (cl-letf (((symbol-function 'ebox-style--property)
               (lambda (&rest arguments)
                 (cl-incf lookups)
                 (apply original arguments))))
      (setq benchmark
            (benchmark-run
              1
              (dotimes (_iteration 100)
                (dolist (name names)
                  (ebox-style--engine-projection-targets name))))))
    (dotimes (_iteration 100)
      (dolist (name names)
        (cl-incf legacy-comparisons
                 (ebox-style-schema-test--legacy-rule-comparisons name))))
    (should (= lookups (* 100 (length names))))
    (should (> legacy-comparisons (* 2 lookups)))
    (should (< (car benchmark) 2.0))))

(provide 'ebox-style-schema-tests)

;;; ebox-style-schema-tests.el ends here
