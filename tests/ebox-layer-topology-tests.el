;;; ebox-layer-topology-tests.el --- Layer subtree acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise retained layered topology through public source and publication APIs.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defun ebox-layer-topology-test--input (&rest specs)
  "Build SPECS as (REF TAG STYLE INTERACTIONS CONTENT CLASS RULES SCOPES ROOTS).
Children can contain (:range REF SPEC...) using the public source builder."
  (let ((builder (ebox-source-builder-create)))
    (cl-labels
        ((node (spec)
           (if (eq (car spec) :range)
               (apply #'ebox-child-range (cadr spec) (mapcar #'node (cddr spec)))
             (pcase-let* ((`(,ref ,tag ,style ,interactions ,content . ,rest) spec)
                          (declarations (ebox-style-compile-form tag style))
                          (handle (ebox-source-builder-bind
                                   builder :identity ref :key ref :id ref
                                   :class (car rest) :interactions interactions
                                   :ecss (ebox-style-compile-rules (cadr rest))
                                   :ecss-scopes (nth 2 rest)
                                   :ecss-scope-roots (nth 3 rest)
                                   :declarations declarations))
                          (facts (ebox-canonical-facts-from-declarations
                                  tag declarations interactions)))
               (if (eq tag 'text)
                   (ebox-text-create :value content :source-handle handle
                                     :owned-facts facts)
                 (apply #'ebox-box-create
                        (append
                         (ebox-canonical-box-configuration tag declarations)
                         (list :source-handle handle :owned-facts facts
                               :source-builder builder
                               :children (mapcar #'node content)))))))))
      (let ((roots (mapcar #'node specs)))
        (ebox-canonical-input-create roots (ebox-source-builder-finish builder))))))

(defun ebox-layer-topology-test--controls (variant maps)
  "Return VARIANT's child controls, using the stable native MAPS."
  (mapcar
   (lambda (ref)
     `(,ref box (:width (ch 18) :height (lh 1))
            (:keymap ,(alist-get ref maps) :tab-index 0
             :help-echo ,(symbol-name ref) :pointer hand)
            ((,(intern (format "%s-value" ref)) text nil nil
              ,(pcase ref ('alpha "Alpha中é") ('beta "Beta") (_ "Gamma"))))
            ,(if (eq ref 'gamma) '(control extended) '(control))))
   (pcase variant
     ('compact '(alpha))
     ('reordered '(beta alpha))
     (_ '(alpha beta gamma)))))

(defun ebox-layer-topology-test--pane (variant maps)
  "Return the stable positioned pane with VARIANT's topology and native MAPS."
  `(settings column
             (:position absolute :left (ch 8) :top (lh 1)
              :width (ch 18) :height (lh ,(if (eq variant 'compact) 2 5))
              :z-index 3 :background-color "#ddeeff" :color "#223344")
             (:keymap ,(alist-get 'settings maps) :help-echo "settings")
             ((heading text nil nil "Settings")
              (:range controls ,@(ebox-layer-topology-test--controls variant maps)))))

(defun ebox-layer-topology-test--document (variant maps &optional relational)
  "Build a fixed canvas with VARIANT and unchanged panes using MAPS.
RELATIONAL adds selectors whose effects cross the replaced pane boundary."
  (ebox-layer-topology-test--input
   `(canvas box (:width (ch 36) :height (lh 8) :color "#223344") nil
            ((peer column (:position absolute :left (ch 0) :top (lh 0)
                           :width (ch 6) :height (lh 6)
                           :background-color "#eeeeee")
                   (:keymap ,(alist-get 'peer maps) :help-echo "peer")
                   ((peer-control box (:height (lh 1))
                                  (:keymap ,(alist-get 'peer-control maps)
                                   :tab-index 0 :help-echo "peer-control")
                                  ((peer-value text nil nil "Peer")))))
             (under box (:position absolute :left (ch 8) :top (lh 4)
                         :width (ch 8) :height (lh 1)
                         :background-color "#f0e0d0")
                    (:keymap ,(alist-get 'under maps) :tab-index 0
                     :help-echo "under")
                    ((under-value text nil nil "Under")))
             ,(ebox-layer-topology-test--pane variant maps)
             (right box (:position absolute :left (ch 28) :top (lh 0)
                         :width (ch 8) :height (lh 6))
                    (:keymap ,(alist-get 'right maps) :help-echo "right")
                    ((right-value text nil nil "Right"))))
            nil
            ,(when relational
               '(("#settings .control:nth-child(3)" :color "#3355cc")
                 ("#settings:has(.extended) + #right" :color "#cc3344")
                 ("#canvas:has(.extended)" :font-weight bold))))))

(defun ebox-layer-topology-test--shape (text)
  "Return TEXT's visible content and public Emacs display properties."
  (list (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect
                 (mapcar (lambda (property) (get-text-property position property text))
                         '(face font-lock-face display help-echo keymap mouse-face pointer)))))

(defun ebox-layer-topology-test--assert-fresh (expected)
  "Compare the current mounted output and Host bounds with EXPECTED in Elisp."
  (let* ((actual (current-buffer))
         (shape (ebox-layer-topology-test--shape (buffer-string)))
         (snapshot (plist-get (ebox-surface-buffer-snapshot actual) :input))
         (refs '(canvas peer peer-control peer-value under under-value settings
                        heading alpha alpha-value beta beta-value gamma gamma-value
                        right right-value)))
    (should (equal shape (ebox-layer-topology-test--shape (ebox-render snapshot))))
    (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p) (lambda () nil)))
      (with-temp-buffer
        (unwind-protect
            (progn
              (ebox-render-to-buffer (current-buffer) expected)
              (should (equal shape (ebox-layer-topology-test--shape (buffer-string))))
              (dolist (ref refs)
                (ert-info ((format "Host bounds for %S" ref))
                  (should (equal (ebox-host-ref-bounds actual ref)
                                 (ebox-host-ref-bounds (current-buffer) ref))))))
          (ebox-unmount-buffer (current-buffer)))))))

(defun ebox-layer-topology-test--candidate (previous next maps range)
  "Replace PREVIOUS with NEXT using MAPS, through a Range when RANGE is non-nil."
  (let ((candidate (ebox-candidate-begin (current-buffer))))
    (if range
        (progn
          (ebox-candidate-replace-range-ref
           candidate 'controls
           (apply #'ebox-layer-topology-test--input
                  (ebox-layer-topology-test--controls next maps)))
          (ebox-candidate-update-host-properties
           candidate 'settings
           (ebox-layer-topology-test--input (ebox-layer-topology-test--pane previous maps))
           (ebox-layer-topology-test--input (ebox-layer-topology-test--pane next maps))))
      (ebox-candidate-replace-host-ref
       candidate 'settings
       (ebox-layer-topology-test--input (ebox-layer-topology-test--pane next maps))))
    candidate))

(defun ebox-layer-topology-test--exercise (relational)
  "Exercise layered replacement, selectors, ownership and rollback.
RELATIONAL enables style effects extending into otherwise unchanged siblings."
  (let* ((ebox-viewport-width 800) (ebox-viewport-height 12)
         events
         (maps (mapcar
                (lambda (ref)
                  (cons ref (ebox-keymap-create :activate (lambda () (push ref events)))))
                '(peer peer-control under settings alpha beta gamma right)))
         (variant 'compact))
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             (current-buffer) (ebox-layer-topology-test--document variant maps relational))
            (ebox-focus 'peer-control)
            (dolist (change '((expanded . t) (compact) (reordered . t) (expanded)))
              (let ((next (car change)) (range (cdr change)))
                (ebox-commit (current-buffer)
                             (ebox-layer-topology-test--candidate variant next maps range))
                (setq variant next)
                (should (eq 'peer-control (ebox-focused-host-ref)))
                (should (= 1 (length (ebox-selector-query-buffer
                                     (current-buffer) "#peer-control:focus"))))
                (should (= (length (ebox-layer-topology-test--controls variant maps))
                           (length (ebox-selector-query-buffer
                                    (current-buffer) "#settings > .control"))))
                (should (= (if (eq variant 'expanded) 1 0)
                           (length (ebox-selector-query-buffer
                                    (current-buffer) "#settings:has(.extended) + #right"))))
                (dolist (ref '(peer-control alpha right))
                  (let ((position (ebox-host-ref-position (current-buffer) ref)))
                    (should position)
                    (should (equal (get-text-property position 'help-echo) (symbol-name ref)))
                    (should (commandp (lookup-key (get-text-property position 'keymap)
                                                   (kbd "RET"))))
                    (ebox-activate position)
                    (should (eq ref (car events)))))
                (ebox-layer-topology-test--assert-fresh
                 (ebox-layer-topology-test--document variant maps relational))))
            ;; A compact pane reveals the retained lower owner.  Rejecting a
            ;; growing structural replacement must retain its focus and source.
            (ebox-commit (current-buffer)
                         (ebox-layer-topology-test--candidate variant 'compact maps t))
            (setq variant 'compact)
            (ebox-focus 'under)
            (let ((before (buffer-string))
                  (revision (ebox-surface-buffer-revision (current-buffer)))
                  (snapshot (ebox-surface-buffer-snapshot (current-buffer)))
                  (bounds (ebox-host-ref-bounds (current-buffer) 'under))
                  (report (ebox-buffer-update-report (current-buffer)))
                  (position (point)))
              (should-error
               (ebox-commit
                (current-buffer)
                (ebox-layer-topology-test--candidate variant 'expanded maps nil)
                (lambda (_report) (error "Reject layered subtree replacement"))))
              (should (equal-including-properties before (buffer-string)))
              (should (= revision (ebox-surface-buffer-revision (current-buffer))))
              (should (equal report (ebox-buffer-update-report (current-buffer))))
              (should (equal bounds (ebox-host-ref-bounds (current-buffer) 'under)))
              (should (= position (point)))
              (should (eq 'under (ebox-focused-host-ref)))
              (let ((after (ebox-surface-buffer-snapshot (current-buffer))))
                (should (equal (plist-get snapshot :mount-id) (plist-get after :mount-id)))
                (should (equal (ebox-layer-topology-test--shape
                                (ebox-render (plist-get snapshot :input)))
                               (ebox-layer-topology-test--shape
                                (ebox-render (plist-get after :input))))))
              (should-not (ebox-selector-query-buffer (current-buffer) ".extended")))
            (ebox-commit (current-buffer)
                         (ebox-layer-topology-test--candidate variant 'expanded maps nil))
            (should-not (ebox-focused-host-ref))
            (should-not (ebox-host-ref-position (current-buffer) 'under))
            (should-not (ebox-selector-query-buffer (current-buffer) ":focus"))
            (ebox-layer-topology-test--assert-fresh
             (ebox-layer-topology-test--document 'expanded maps relational))
            (ebox-commit (current-buffer)
                         (ebox-layer-topology-test--candidate 'expanded 'compact maps t))
            (ebox-activate (ebox-host-ref-position (current-buffer) 'under))
            (should (eq 'under (car events)))
            ;; A later ordinary update must resolve the accepted source, after
            ;; both rejected and successful structural generations.
            (ebox-region-update "alpha-value" :content "Current")
            (should (string-match-p "Current"
                                    (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (ebox-selector-query-buffer (current-buffer) "#beta, #gamma"))
            (ebox-layer-topology-test--assert-fresh
             (plist-get (ebox-surface-buffer-snapshot (current-buffer)) :input)))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-layer-topology-preserves-publication-without-native ()
  "Pane subtree and Range replacements retain sibling ownership and rollback."
  (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p) (lambda () nil)))
    (ebox-layer-topology-test--exercise nil)))

(ert-deftest ebox-layer-topology-native-matches-elisp-publication ()
  "Native layered replacements match Elisp pixels, properties and live bounds."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (ebox-layer-topology-test--exercise nil))

(ert-deftest ebox-layer-topology-preserves-relational-style-effects ()
  "Structural selectors update retained siblings and inherited paint atomically."
  (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p) (lambda () nil)))
    (ebox-layer-topology-test--exercise t)))

(ert-deftest ebox-layer-topology-native-preserves-relational-style-effects ()
  "Native topology updates retain complete structural-selector style effects."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (ebox-layer-topology-test--exercise t))

(defun ebox-layer-topology-test--scope-controls (expanded scope)
  "Return controls whose SCOPE membership grows when EXPANDED is non-nil."
  `((alpha box (:height (lh 1)) nil ((alpha-value text nil nil "Alpha"))
           (owned) nil (,scope))
    ,@(when expanded
        `((beta box (:height (lh 1)) nil ((beta-value text nil nil "Beta"))
                (owned) nil (,scope))))
    ;; Matching a selector does not confer membership in the shared scope.
    (gamma box (:height (lh 1)) nil ((gamma-value text nil nil "Outside")) (owned))))

(defun ebox-layer-topology-test--scope-pane (expanded color scope)
  "Return a pane with EXPANDED controls, inherited COLOR and shared SCOPE."
  `(settings column (:position absolute :left (ch 8) :top (lh 1)
                     :width (ch 18) :height (lh ,(if expanded 5 3))
                     :background-color "#eeeeee" :color ,color)
             nil ((heading text nil nil "Heading")
                  (:range controls ,@(ebox-layer-topology-test--scope-controls expanded scope)))
             nil nil nil (,scope)))

(defun ebox-layer-topology-test--scope-document (expanded color scope)
  "Build a pane with EXPANDED controls and COLOR beside an unchanged SCOPE root."
  (ebox-layer-topology-test--input
   `(canvas box (:width (ch 36) :height (lh 8)) nil
            ((peer column (:position absolute :width (ch 6) :height (lh 3)) nil
                   ((peer-control box (:height (lh 1)) (:tab-index 0)
                                  ((peer-value text nil nil "Peer")) (owned) nil (,scope)))
                   nil nil nil (,scope))
             ,(ebox-layer-topology-test--scope-pane expanded color scope)))))

(defun ebox-layer-topology-test--exercise-scope ()
  "Change pane membership and inherited paint while retaining another scope root."
  (let ((ebox-viewport-width 800) (ebox-viewport-height 12)
        (scope (ebox-style-scope-create '((".owned" :color "#bb2233"))))
        (color "#223344") expanded)
    (with-temp-buffer
      (unwind-protect
          (progn
            (ebox-render-to-buffer
             (current-buffer) (ebox-layer-topology-test--scope-document expanded color scope))
            (ebox-focus 'peer-control)
            (dolist (next '(t nil t nil))
              (let* ((next-color (if next "#336655" "#223344"))
                     (before (ebox-layer-topology-test--shape (buffer-string)))
                     (revision (ebox-surface-buffer-revision (current-buffer))))
                (cl-labels
                    ((candidate ()
                       (let ((candidate (ebox-candidate-begin (current-buffer))))
                         (ebox-candidate-replace-range-ref
                          candidate 'controls
                          (apply #'ebox-layer-topology-test--input
                                 (ebox-layer-topology-test--scope-controls next scope)))
                         (ebox-candidate-update-host-properties
                          candidate 'settings
                          (ebox-layer-topology-test--input
                           (ebox-layer-topology-test--scope-pane expanded color scope))
                          (ebox-layer-topology-test--input
                           (ebox-layer-topology-test--scope-pane next next-color scope)))
                         candidate)))
                  (should-error
                   (ebox-commit (current-buffer) (candidate)
                                (lambda (_report) (error "Reject scope membership change"))))
                  (should (equal before (ebox-layer-topology-test--shape (buffer-string))))
                  (should (= revision (ebox-surface-buffer-revision (current-buffer))))
                  (should (eq 'peer-control (ebox-focused-host-ref)))
                  (ebox-commit (current-buffer) (candidate)))
                (setq expanded next color next-color)
                (should (eq 'peer-control (ebox-focused-host-ref)))
                (should (= (if expanded 3 2)
                           (length (ebox-selector-query-buffer
                                    (current-buffer) "#settings > .owned"))))
                (dolist (ref '(peer-control alpha heading gamma))
                  (let* ((position (ebox-host-ref-position (current-buffer) ref))
                         (face (get-text-property position 'face))
                         (foreground
                          (or (plist-get face :foreground)
                              (cl-loop for layer in face
                                       when (and (listp layer) (plist-get layer :foreground))
                                       return (plist-get layer :foreground)))))
                    (should (equal foreground
                                   (if (memq ref '(peer-control alpha)) "#bb2233" color)))))
                (ebox-layer-topology-test--assert-fresh
                 (ebox-layer-topology-test--scope-document expanded color scope)))))
        (ebox-unmount-buffer (current-buffer))))))

(ert-deftest ebox-layer-topology-retains-shared-scope-membership ()
  "Changing pane members preserves other scope roots and inherited child paint."
  (cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p) (lambda () nil)))
    (ebox-layer-topology-test--exercise-scope)))

(ert-deftest ebox-layer-topology-native-retains-shared-scope-membership ()
  "Native pane membership, height and inheritance changes match fresh Elisp output."
  (skip-unless (ebox-native-reflow-layout-ready-p))
  (ebox-layer-topology-test--exercise-scope))

(provide 'ebox-layer-topology-tests)
;;; ebox-layer-topology-tests.el ends here
