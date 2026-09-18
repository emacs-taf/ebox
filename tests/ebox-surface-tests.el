;;; ebox-surface-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defvar ebox-native-reflow-module-path)

(defmacro ebox-surface-test--with-elisp-backend (&rest body)
  "Run BODY with the explicit Elisp rendering backend."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'ebox-native-reflow-layout-ready-p)
              (lambda () nil)))
     ,@body))

(ert-deftest ebox-surface-snapshot-preserves-empty-and-keyed-ranges ()
  "Detached export keeps exact source handles and transparent Range shape."
  (ebox-surface-test--with-elisp-backend
    (with-temp-buffer
      (let* ((builder (ebox-source-builder-create))
             (handle (ebox-source-builder-bind builder :identity 'root))
             (children (mapcar
                        (lambda (key)
                          (ebox-text-create
                           :value (symbol-name key)
                           :source-handle (ebox-source-builder-bind
                                           builder :identity key :key key)
                           :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
                        '(one two)))
             (input (ebox-canonical-input-create
                     (list (ebox-box-create
                            :source-handle handle :source-builder builder
                            :owned-facts (ebox-canonical-facts-from-declarations 'box nil)
                            :layout (ebox-column-layout-create)
                            :children (list (ebox-child-range 'empty)
                                            (apply #'ebox-child-range 'items children))))
                     (ebox-source-builder-finish builder)))
             (root (car (ebox-canonical-input-roots input))))
        (ebox-render-to-buffer (current-buffer) input)
        (let* ((snapshot (ebox-surface-buffer-snapshot (current-buffer)))
               (export (plist-get snapshot :input))
               (copy (car (ebox-canonical-input-roots export))))
          (should (equal (ebox-box-node-range-anchors root)
                         (ebox-box-node-range-anchors copy)))
          (should (eq (ebox-node-source-handle root) (ebox-node-source-handle copy)))
          (cl-mapc (lambda (before after)
                     (should (eq (ebox-node-source-handle before)
                                 (ebox-node-source-handle after))))
                   (ebox-box-node-children root) (ebox-box-node-children copy))
          (should (string-match-p "one" (ebox-render export)))
          (should-not (plist-get copy :node-id))
          (should-not (plist-get copy :surface-object))
          (should-not (plist-get copy :render-cache)))))))

(ert-deftest ebox-region-content-update-ignores-caller-narrowing ()
  "The local owner proof uses mounted coordinates outside the editor view."
  (ebox-surface-test--with-elisp-backend
    (with-temp-buffer
      (ebox-render-to-buffer
       (current-buffer)
       (ebox-build '(box :id "target" :width (px 120) "Before")))
      (goto-char (1+ (point-min)))
      (narrow-to-region (point) (point-max))
      (ebox-region-update "target" :content "After!")
      (save-restriction
        (widen)
        (should (string-prefix-p "After!" (buffer-string)))))))

(ert-deftest ebox-publication-rejects-participant-text-corruption ()
  "A failed framework stage preserves text, revision and the live target."
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (old (ebox-build '(box :id target :width (ch 12) "Before")))
          (next (ebox-build '(box :id target :width (ch 12) "After")))
          restored)
      (ebox-render-to-buffer buffer old)
      (let ((before (buffer-string))
            (revision (ebox-surface-buffer-revision buffer))
            (handle (ebox-region-resolve buffer "target")))
        (should-error
         (ebox-framework-spi-update
          buffer next
          (lambda (_report)
            (with-current-buffer buffer
              (let ((inhibit-read-only t) (buffer-undo-list t))
                (put-text-property (point-min) (1+ (point-min))
                                   'display "Corrupted"))))
          (lambda (_report) (setq restored t))))
        (should restored)
        (should (equal-including-properties before (buffer-string)))
        (should (= revision (ebox-surface-buffer-revision buffer)))
        (ebox-region-update handle :content "Recovered")
        (should (string-match-p "Recovered" (buffer-string)))))))

(provide 'ebox-surface-tests)
;;; ebox-surface-tests.el ends here
