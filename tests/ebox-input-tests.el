;;; ebox-input-tests.el --- Native input session acceptance -*- lexical-binding: t; -*-

(require 'ert)
(require 'ebox)

(defun ebox-input-test--input (field-text)
  "Build a canonical input whose FIELD-TEXT Host is named `field'."
  (let* ((builder (ebox-source-builder-create))
         (root (ebox-source-builder-bind builder :identity 'root :key 'root
                                         :id "form"))
         (children
          (mapcar
           (lambda (entry)
             (let* ((ref (car entry)) (text (cdr entry))
                    (handle (ebox-source-builder-bind
                             builder :identity ref :key ref :id (symbol-name ref))))
               (ebox-text-create
                :value text :source-handle handle
                :owned-facts (ebox-canonical-facts-from-declarations 'text nil nil))))
           (list (cons 'before "before") (cons 'field field-text) (cons 'after "after")))))
    (ebox-canonical-input-create
     (list (ebox-box-create
            :source-handle root :layout (ebox-column-layout-create)
            :children children
            :owned-facts (ebox-canonical-facts-from-declarations 'column nil nil)))
     (ebox-source-builder-finish builder))))

(defun ebox-input-test--mount (field-text)
  "Mount the test form with FIELD-TEXT and return its buffer."
  (let ((buffer (generate-new-buffer " *ebox input test*")))
    (ebox-render-to-buffer buffer (ebox-input-test--input field-text))
    buffer))

(ert-deftest ebox-input-session-accepts-edits-and-restores-on-end ()
  "Native edits inside the span survive; ending restores published text."
  (let ((buffer (ebox-input-test--mount "value"))
        session)
    (unwind-protect
        (progn
          (setq session (ebox-input-begin buffer 'field))
          (should (ebox-input-active-p buffer))
          (should (equal (ebox-input-text session) "value"))
          (with-current-buffer buffer
            (goto-char (car (ebox-host-ref-bounds buffer 'field)))
            (insert "X")
            (should-error (ebox-commit buffer (ebox-input-test--input "value"))
                          :type 'ebox-input-session-active))
          (should (equal (ebox-input-text session) "Xvalue"))
          (should (equal (ebox-input-end session) "Xvalue"))
          (should-not (ebox-input-active-p buffer))
          (with-current-buffer buffer
            (should (equal (buffer-substring-no-properties
                            (car (ebox-host-ref-bounds buffer 'field))
                            (cdr (ebox-host-ref-bounds buffer 'field)))
                           "value")))
          (ebox-commit buffer (ebox-input-test--input "Xvalue"))
          (with-current-buffer buffer
            (should (equal (buffer-substring-no-properties
                            (car (ebox-host-ref-bounds buffer 'field))
                            (cdr (ebox-host-ref-bounds buffer 'field)))
                           "Xvalue"))))
      (when (and session (ebox-input-active-p buffer)) (ebox-input-end session))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-input-session-validates-lifecycle ()
  "One session per buffer; invalid Hosts and handles are rejected."
  (let ((buffer (ebox-input-test--mount "value"))
        session)
    (unwind-protect
        (progn
          (should-error (ebox-input-begin buffer 'missing) :type 'ebox-input-error)
          (setq session (ebox-input-begin buffer 'field))
          (should-error (ebox-input-begin buffer 'before) :type 'ebox-input-session-active)
          (should-error (ebox-input-text 'not-a-session) :type 'ebox-input-error)
          (should-error (ebox-input-end 'not-a-session) :type 'ebox-input-error)
          (should (equal (ebox-input-end session) "value"))
          (should-not (ebox-input-end session))
          (should-not (ebox-input-active-p buffer))
          (should-error (ebox-input-begin (generate-new-buffer " *dead*") 'field)
                        :type 'ebox-input-error))
      (when (and session (ebox-input-active-p buffer)) (ebox-input-end session))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-input-session-end-recovers-from-a-lost-span ()
  "A session whose span was erased or whose buffer died still ends cleanly."
  (let ((buffer (ebox-input-test--mount "value")) session)
    (setq session (ebox-input-begin buffer 'field))
    ;; Another code path erased the buffer while the session owned the text;
    ;; ending must clear the refusal instead of signaling.
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer)))
    (should (equal (ebox-input-end session) ""))
    (should-not (ebox-input-active-p buffer))
    (with-current-buffer buffer
      (should (string-match-p "value" (buffer-string))))
    (kill-buffer buffer))
  (let ((buffer (ebox-input-test--mount "value")) session)
    (setq session (ebox-input-begin buffer 'field))
    (kill-buffer buffer)
    (should-not (ebox-input-end session))
    (should-not (ebox-input-end session))))

(provide 'ebox-input-tests)
;;; ebox-input-tests.el ends here
