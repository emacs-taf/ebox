;;; ebox-prepared-children-tests.el --- Prepared structural member behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; A prepared `:children' member compiles one Host subtree replacement into
;; the cohort's candidate state, re-renders that owner's composition boundary,
;; and publishes only its retained primitives.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defmacro ebox-prepared-children-test--with-buffer (&rest body)
  "Run BODY in a fresh mounted-buffer context with the Elisp backend."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
              (lambda () nil)))
     (let ((ebox-viewport-width 48) (ebox-viewport-height 12))
       (with-temp-buffer ,@body))))

(defun ebox-prepared-children-test--text (builder identity value)
  "Return a TEXT node for BUILDER with IDENTITY and VALUE."
  (let ((handle (ebox-source-builder-bind
                 builder :identity identity :key identity)))
    (ebox-text-create
     :value value :source-handle handle
     :owned-facts (ebox-canonical-facts-from-declarations 'text nil))))

(defun ebox-prepared-children-test--box (builder identity style children)
  "Return a BOX node for BUILDER with IDENTITY, STYLE and CHILDREN."
  (let* ((declarations (ebox-style-compile-form 'box style))
         (handle (ebox-source-builder-bind
                  builder :identity identity :key identity :id identity
                  :declarations declarations)))
    (apply #'ebox-box-create
           (append
            (ebox-canonical-box-configuration 'box declarations)
            (list :source-handle handle :source-builder builder
                  :owned-facts (ebox-canonical-facts-from-declarations
                                'box declarations nil)
                  :children children)))))

(defun ebox-prepared-children-test--replacement-input (&optional fresh-p)
  "Return the canonical replacement for the `list' Host.
FRESH-P gives the replacement new identities, which changes node and region
identities and therefore cannot reuse the retained mount context."
  (let ((builder (ebox-source-builder-create)))
    (ebox-canonical-input-create
     (list (ebox-prepared-children-test--box
            builder 'list nil
            (list (ebox-prepared-children-test--text
                   builder (if fresh-p 'new-a 'old-a) "NEW-A")
                  (ebox-prepared-children-test--text
                   builder (if fresh-p 'new-b 'old-b) "NEW-B"))))
     (ebox-source-builder-finish builder))))

(defun ebox-prepared-children-test--fresh-input ()
  "Return a replacement whose new identities require ordinary publication."
  (ebox-prepared-children-test--replacement-input t))

(defun ebox-prepared-children-test--input ()
  "Return a mounted input whose `list' panel is one prepared structural owner."
  (let ((builder (ebox-source-builder-create)))
    (progn
      (let* ((rows (list (ebox-prepared-children-test--text builder 'old-a "OLD-A")
                         (ebox-prepared-children-test--text builder 'old-b "OLD-B")))
             (list-box (ebox-prepared-children-test--box builder 'list nil rows))
             (panel (ebox-prepared-children-test--box
                     builder 'panel
                     '(:position absolute :left (ch 0) :top (lh 0)
                       :width (ch 16) :height (lh 4) :z-index 1)
                     (list list-box)))
             (other (ebox-prepared-children-test--box
                     builder 'other
                     '(:position absolute :left (ch 18) :top (lh 0)
                       :width (ch 12) :height (lh 2) :z-index 2)
                     (list (ebox-prepared-children-test--text builder 'keep "KEEP"))))
             (root (ebox-prepared-children-test--box
                    builder 'surface
                    '(:width (ch 32) :height (lh 6))
                    (list panel other))))
        (ebox-canonical-input-create
         (list root) (ebox-source-builder-finish builder))))))

(ert-deftest ebox-prepared-children-replaces-one-owner-subtree ()
  "A `:children' member publishes the new subtree and keeps sibling pixels."
  (ebox-prepared-children-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-children-test--input))
    (should (string-match-p "OLD-A" (buffer-string)))
    (let ((operation (ebox-update-prepare
                      (current-buffer)
                      (vector (vector 'list :children
                                      (ebox-prepared-children-test--replacement-input))))))
      (should operation)
      (should (eq 'ready (plist-get (ebox-update-prepare-report (current-buffer))
                                    :status)))
      (should (ebox-update-apply operation (vector (vector nil)) [0]))
      (should (string-match-p "NEW-A" (buffer-string)))
      (should (string-match-p "NEW-B" (buffer-string)))
      (should (string-match-p "KEEP" (buffer-string)))
      (should-not (string-match-p "OLD-A" (buffer-string)))
      (let ((report (ebox-buffer-update-report (current-buffer))))
        (should (eq t (plist-get report :prepared-update-p)))
        (should (memq 'span (plist-get report :dirty-kinds)))))))

(ert-deftest ebox-prepared-children-rollback-restores-source-tables ()
  "A rejected application restores the swapped candidate tables and pixels."
  (ebox-prepared-children-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-children-test--input))
    (let* ((before (buffer-string))
           (operation (ebox-update-prepare
                       (current-buffer)
                       (vector (vector 'list :children
                                       (ebox-prepared-children-test--replacement-input)))
                       (lambda () (error "Reject structural publication"))
                       (lambda () nil))))
      (should operation)
      (should-error (ebox-update-apply operation (vector (vector nil)) [0]))
      (should (equal-including-properties before (buffer-string)))
      (should (string-match-p "OLD-A" (buffer-string)))
      (should-not (string-match-p "NEW-A" (buffer-string))))))

(ert-deftest ebox-prepared-children-declines-new-identities ()
  "A replacement that introduces new node or region identities is declined."
  (ebox-prepared-children-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-children-test--input))
    (let ((before (buffer-string)))
      (should-not (ebox-update-prepare
                   (current-buffer)
                   (vector (vector 'list :children
                                   (ebox-prepared-children-test--fresh-input)))))
      (should (eq 'unsupported (plist-get (ebox-update-prepare-report (current-buffer))
                                          :status)))
      (should (eq 'structural-topology (plist-get (ebox-update-prepare-report (current-buffer))
                                                  :reason)))
      (should (equal-including-properties before (buffer-string))))))

(ert-deftest ebox-prepared-children-requires-canonical-input ()
  "A malformed structural member is rejected before any state changes."
  (ebox-prepared-children-test--with-buffer
    (ebox-render-to-buffer (current-buffer) (ebox-prepared-children-test--input))
    (let ((before (buffer-string)))
      (should-error (ebox-update-prepare
                     (current-buffer) (vector (vector 'list :children 'not-an-input))))
      (should (equal-including-properties before (buffer-string))))))

(provide 'ebox-prepared-children-tests)
;;; ebox-prepared-children-tests.el ends here
