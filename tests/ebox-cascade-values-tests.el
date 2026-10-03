;;; ebox-cascade-values-tests.el --- ECSS values through rendering -*- lexical-binding: t; -*-

;;; Commentary:
;; Final paint and layout consume computed values, including retained updates.

;;; Code:
(require 'ert)
(require 'ebox)
(require 'ecss)

(defun ebox-cascade-value-test--color (rendered)
  "Read the observable foreground of RENDERED text."
  (plist-get (get-text-property 0 'face rendered) :foreground))

(defun ebox-cascade-value-test--appearance (rendered)
  "Return RENDERED text and visible display/face properties."
  (cons (substring-no-properties rendered)
        (cl-loop for position below (length rendered)
                 collect (list (get-text-property position 'display rendered)
                               (get-text-property position 'face rendered)))))

(ert-deftest ebox-cascade-values-compute-inline-tags-before-paint ()
  "Inline special values never become raw Emacs face values."
  (dolist (entry (list (cons (ecss-important "#ff0000") "#ff0000")
                       (cons (ecss-wide-value 'inherit) "#00ff00")
                       (cons (ecss-var '--missing "#ff0000") "#ff0000")))
    (should (equal (cdr entry)
                   (ebox-cascade-value-test--color
                    (ebox-render
                     (ebox-build
                      (list 'box :color "#00ff00"
                            (list 'text :color (car entry) "Cascade"))))))))
  (should-error (ebox-build (list 'text :color (ecss-important 42) "Invalid"))))

(ert-deftest ebox-cascade-values-share-inline-and-rule-importance ()
  "Author important rules beat ordinary inline input; important inline wins ties."
  (let ((rules (list (list ".target" :color (ecss-important "#ff0000")))))
    (dolist (entry (list (cons "#00ff00" "#ff0000")
                         (cons (ecss-important "#0000ff") "#0000ff")))
      (should (equal (cdr entry)
                     (ebox-cascade-value-test--color
                      (ebox-render
                       (ebox-build
                        (list 'box :ecss rules
                              (list 'text :class "target" :color (car entry)
                                    "Cascade"))))))))))

(ert-deftest ebox-cascade-values-resolve-before-geometry ()
  "Tagged dimensions and shorthand importance reach layout only after computation."
  (dolist (entry (list (list :width '(ch 8) (ecss-important '(ch 8)))
                       (list :padding '((lh 1) (ch 2))
                             (ecss-important '((lh 1) (ch 2))))))
    (should (equal
             (ebox-cascade-value-test--appearance
              (ebox-render (ebox-build (list 'box (car entry) (cadr entry) "Box"))))
             (ebox-cascade-value-test--appearance
              (ebox-render (ebox-build (list 'box (car entry) (caddr entry) "Box")))))))
  (dolist (entry '((:flex-direction column) (:justify-content center) (:align-items center)))
    (should
     (equal
      (ebox-cascade-value-test--appearance
       (ebox-render (ebox-build (list 'flex :width '(ch 20) (car entry) (cadr entry)
                                      '(box "One") '(box "Two")))))
      (ebox-cascade-value-test--appearance
       (ebox-render (ebox-build (list 'flex :width '(ch 20) (car entry)
                                      (ecss-important (cadr entry))
                                      '(box "One") '(box "Two"))))))))
  (should (string-match-p
           "Box" (ebox-render
                  (ebox-build (list 'box :width (ecss-wide-value 'initial) "Box"))))))

(ert-deftest ebox-cascade-values-update-inherited-custom-properties ()
  "Retained variable consumers follow source updates and keep valid output on error."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      (list 'box :id "root" '--brand "#0000ff"
            (list 'text :id "label" :color (ecss-var '--brand) "Cascade"))))
    (should (equal "#0000ff" (ebox-cascade-value-test--color (buffer-string))))
    (ebox-region-update "root" '--brand "#ff0000")
    (should (equal "#ff0000" (ebox-cascade-value-test--color (buffer-string))))
    (ebox-region-update "label" :color (ecss-important "#00ff00"))
    (should (equal "#00ff00" (ebox-cascade-value-test--color (buffer-string))))
    (ebox-region-update "label" :color (ecss-var '--brand))
    (should (equal "#ff0000" (ebox-cascade-value-test--color (buffer-string))))
    (should-error (ebox-region-update "label" :color (ecss-important 42)))
    (should (equal "#ff0000" (ebox-cascade-value-test--color (buffer-string))))))

(ert-deftest ebox-cascade-values-update-inherited-geometry ()
  "A custom length update changes retained geometry exactly like fresh computation."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer)
     (ebox-build
      (list 'box :id "root" '--span '(ch 8)
            (list 'box :id "item" :width (ecss-var '--span) "Box"))))
    (ebox-region-update "root" '--span '(ch 12))
    (let ((expected (ebox-render (ebox-build '(box (box :width (ch 12) "Box")))))
          (actual (buffer-string)))
      (should (equal (substring-no-properties expected)
                     (substring-no-properties actual)))
      (dotimes (position (length expected))
        (should (equal (get-text-property position 'display expected)
                       (get-text-property position 'display actual)))))
    (ebox-region-update "item" :width (ecss-important '(ch 16)))
    (let ((expected (ebox-render (ebox-build '(box (box :width (ch 16) "Box")))))
          (actual (buffer-string)))
      (should (equal (substring-no-properties expected)
                     (substring-no-properties actual)))
      (dotimes (position (length expected))
        (should (equal (get-text-property position 'display expected)
                       (get-text-property position 'display actual)))))))

(ert-deftest ebox-canonical-configuration-preserves-deferred-layout-values ()
  "Canonical producers share the DSL's concrete layout and deferred cascade."
  (let* ((properties (list :flex-direction (ecss-important 'column)
                           :outer (ecss-wide-value 'initial) :width '(ch 10)))
         (declarations (ebox-style-compile-form 'flex properties))
         (configuration (ebox-canonical-box-configuration 'flex declarations))
         (builder (ebox-source-builder-create))
         (handle (ebox-source-builder-bind builder :declarations declarations))
         (children (ebox-build '(box "Child")))
         (node (apply #'ebox-box-create
                      (append configuration
                              (list :children (ebox-canonical-input-import-roots
                                               children (ebox-canonical-input-roots children) builder)
                                    :source-handle handle :source-builder builder
                                    :owned-facts (ebox-canonical-facts-from-declarations
                                                  'flex declarations)))))
         (input (ebox-canonical-input-create (list node) (ebox-source-builder-finish builder))))
    (should (equal (ebox-cascade-value-test--appearance (ebox-render input))
                   (ebox-cascade-value-test--appearance
                    (ebox-render (ebox-build (append (list 'flex) properties '((box "Child"))))))))
    (plist-put configuration :outer 'invalid)
    (should (eq 'block (plist-get (ebox-canonical-box-configuration 'flex declarations) :outer))))
  (should-error (ebox-canonical-box-configuration 'text nil))
  (should-error (ebox-canonical-box-configuration 'row '(ebox/flex-direction column)))
  (should-error (ebox-canonical-box-configuration 'flex '(ebox/flex-direction invalid))))

(defun ebox-cascade-value-test--retained-input (color extra &optional weight)
  "Build a retained tree with COLOR, optional EXTRA sibling and font WEIGHT."
  (ebox-build
   `(column :id "root" :width (ch 30) :color ,color :font-weight ,(or weight 'normal)
      (box :id "fixed" :color "#116633" (text "Explicit"))
      (box :id "inherited" (text "Inherited"))
      ,@(when extra '((text :id "extra" :color "#773311" "Extra"))))))

(ert-deftest ebox-cascade-values-retain-styles-through-structural-updates ()
  "Stable explicit paint and inherited paint stay fresh across sibling changes."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-cascade-value-test--retained-input "#224466" nil))
    (dolist (change '(("#224466" t normal) ("#224466" nil normal)
                      ("#662244" t normal) ("#882211" nil bold)
                      ("#224466" t normal)))
      (let ((input (apply #'ebox-cascade-value-test--retained-input change)))
        (ebox-commit (current-buffer) input)
        (should (equal (ebox-cascade-value-test--appearance (buffer-string))
                       (ebox-cascade-value-test--appearance (ebox-render input))))))
    ;; A later parent mutation still reaches the retained inherited binding.
    (ebox-region-update "root" :color "#225588")
    (should
     (equal (ebox-cascade-value-test--appearance (buffer-string))
            (ebox-cascade-value-test--appearance
             (ebox-render (ebox-cascade-value-test--retained-input "#225588" t)))))))

(ert-deftest ebox-cascade-values-reject-inherited-change-without-poisoning-reuse ()
  "Rejected parent paint and sibling changes restore later style dependencies."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-cascade-value-test--retained-input "#224466" nil))
    (ebox-commit (current-buffer) (ebox-cascade-value-test--retained-input "#224466" t))
    (let ((before (buffer-string))
          (revision (ebox-surface-buffer-revision (current-buffer))))
      (should-error
       (ebox-commit (current-buffer)
                    (ebox-cascade-value-test--retained-input "#AA3311" nil)
                    (lambda (_report) (error "Reject parent paint"))))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (equal-including-properties before (buffer-string))))
    (dolist (color '("#337799" "#446622"))
      (let ((input (ebox-cascade-value-test--retained-input color t)))
        (ebox-commit (current-buffer) input)
        (should (equal (ebox-cascade-value-test--appearance (buffer-string))
                       (ebox-cascade-value-test--appearance (ebox-render input))))))))

(defun ebox-cascade-value-test--font-tree (&rest properties)
  "Build colored descendants which inherit parent font PROPERTIES."
  (ebox-build
   (append
    '(column :id "root")
    (unless (plist-member properties :color) '(:color "#223344"))
    properties
    '((text "Plain")
      (column :color "#446688"
              (text "Inherited")
              (text :color "#884466" "Colored")
              (text :font-size 14 "Fixed"))))))

(ert-deftest ebox-cascade-values-inherit-font-updates-through-explicit-colors ()
  "Retained colored children inherit font changes exactly like fresh rendering."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer)
                          (ebox-cascade-value-test--font-tree))
    (dolist (properties
             (list '(:font-size 20)
                   '(:font-size 16 :font-weight bold)
                   '(:font-size 24 :font-weight normal :font-style italic)
                   (list :font-size (ecss-wide-value 'initial)
                         :font-weight 'normal :font-style 'normal)))
      (apply #'ebox-region-update "root" properties)
      (should
       (equal
        (ebox-cascade-value-test--appearance (buffer-string))
        (ebox-cascade-value-test--appearance
         (ebox-render (apply #'ebox-cascade-value-test--font-tree properties))))))))

(ert-deftest ebox-cascade-values-font-inheritance-survives-publication-rejection ()
  "Rejecting a font publication preserves inherited styles for the next update."
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (before (ebox-cascade-value-test--font-tree :font-size 16))
           (next (ebox-cascade-value-test--font-tree :font-size 24)))
      (ebox-render-to-buffer buffer before)
      (let ((text (buffer-string))
            (revision (ebox-surface-buffer-revision buffer)))
        (should-error
         (ebox-framework-spi-update
          buffer next (lambda (_report) (user-error "Reject inherited font"))
          (lambda (_report) nil))
         :type 'user-error)
        (should (equal-including-properties text (buffer-string)))
        (should (= revision (ebox-surface-buffer-revision buffer)))
        (ebox-commit buffer next)
        (should
         (equal (ebox-cascade-value-test--appearance (buffer-string))
                (ebox-cascade-value-test--appearance (ebox-render next)))))
      (ebox-region-update "root" :font-size 20 :color "#667788")
      (should
       (equal
        (ebox-cascade-value-test--appearance (buffer-string))
        (ebox-cascade-value-test--appearance
         (ebox-render (ebox-cascade-value-test--font-tree
                       :font-size 20 :color "#667788"))))))))

(defun ebox-cascade-value-test--region-appearance ()
  "Return visible text and effective inline faces, preserving face precedence."
  (let ((appearance (ebox-cascade-value-test--appearance (buffer-string))))
    (cons (car appearance)
          (mapcar
           (lambda (entry)
             (let (attributes)
               (cl-labels
                   ((merge-face
                     (face)
                     (cond
                      ((null face) nil)
                      ((keywordp (car-safe face))
                       (cl-loop for (key value) on face by #'cddr
                                unless (assq key attributes)
                                do (push (cons key value) attributes)))
                      ((listp face) (mapc #'merge-face face))
                      (t (error "Unexpected non-inline fixture face: %S" face)))))
                 (merge-face (cadr entry)))
               (list (car entry)
                     (sort attributes (lambda (a b)
                                        (string< (symbol-name (car a))
                                                 (symbol-name (car b))))))))
           (cdr appearance)))))

(defun ebox-cascade-value-test--mounted-appearance (input)
  "Return INPUT's fresh mounted appearance in the current display context."
  (with-temp-buffer
    (ebox-render-to-buffer (current-buffer) input)
    (ebox-cascade-value-test--region-appearance)))

(ert-deftest ebox-cascade-values-region-text-style-matches-fresh-rendering ()
  "Text typography and decorations publish and reset like a fresh render."
  (dolist (batched '(nil t))
    (with-temp-buffer
      (let ((tree (lambda (props)
                    (ebox-build
                     `(column
                       (text :id "label" ,@props "Reading")
                       (text :color "#113355" "Unchanged"))))))
        (ebox-render-to-buffer (current-buffer) (funcall tree nil))
        (dolist (props '((:text-decoration-line underline
                          :text-decoration-color "#cc5533"
                          :text-decoration-style wavy)
                         (:text-decoration-line none
                          :text-decoration-color "#cc5533"
                          :text-decoration-style solid
                          :font-weight bold)
                         (:font-weight normal :font-style italic)
                         (:font-weight normal :font-style normal
                          :text-decoration-line underline
                          :text-decoration-color "#cc5533"
                          :text-decoration-style wavy)
                         (:font-weight normal :font-style normal
                          :text-decoration-line none
                          :text-decoration-color "#cc5533"
                          :text-decoration-style solid)))
          (if batched
              (ebox-call-with-update-batch
               (lambda () (apply #'ebox-region-update "label" props)))
            (apply #'ebox-region-update "label" props))
          (ert-info ((format "batch=%S props=%S faces=%S/%S"
                             batched props
                             (cadr (cadr (ebox-cascade-value-test--region-appearance)))
                             (cadr (cadr (ebox-cascade-value-test--mounted-appearance
                                         (funcall tree props))))))
            (should
             (equal (ebox-cascade-value-test--region-appearance)
                    (ebox-cascade-value-test--mounted-appearance
                     (funcall tree props))))))))))

(ert-deftest ebox-cascade-values-region-text-style-batch-rolls-back ()
  "A rejected text/style batch preserves paint and accepts a later update."
  (with-temp-buffer
    (ebox-render-to-buffer
     (current-buffer) (ebox-build '(column (text :id "label" "Before")
                                          (text :id "peer" "Peer"))))
    (let ((before (buffer-string))
          (revision (ebox-surface-buffer-revision (current-buffer))))
      (should-error
       (ebox-call-with-update-batch
        (lambda ()
          (ebox-region-update "label" :content "After" :font-weight 'bold
                              :text-decoration-line 'underline)
          (ebox-region-update "peer" :font-size 'invalid))))
      (should (= revision (ebox-surface-buffer-revision (current-buffer))))
      (should (equal-including-properties before (buffer-string))))
    (ebox-call-with-update-batch
     (lambda ()
       (ebox-region-update "label" :content "After" :font-weight 'bold
                           :text-decoration-line 'underline)))
    (should
     (equal (ebox-cascade-value-test--region-appearance)
            (ebox-cascade-value-test--mounted-appearance
             (ebox-build '(column (text :id "label" :font-weight bold
                                        :text-decoration-line underline "After")
                                  (text :id "peer" "Peer"))))))))

(provide 'ebox-cascade-values-tests)
;;; ebox-cascade-values-tests.el ends here
