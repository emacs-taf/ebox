;;; ebox-spi.el --- Versioned Ebox framework provider -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provider-side Ebox framework SPI v3.  This module publishes an
;; immutable capability snapshot and delegates initial/update execution to the
;; existing combined Ebox participant.  It does not select a consumer port,
;; or probe a framework package.

;;; Code:

(require 'cl-lib)
(require 'ebox-canonical)
(require 'ebox-surface)
(require 'ebox-publication)

(defconst ebox-framework-spi-supported-publication-protocols
  '(ebox-publication/v1)
  "Publication contract implemented by Ebox.")

(declare-function ebox--render-to-buffer-internal
                  "ebox" (buffer-or-name input options &optional participant))
(declare-function ebox-commit
                  "ebox"
                  (buffer-or-name next-root &optional framework-stage
                                  framework-rollback))
(declare-function ebox-transaction-active-p "ebox-reactive" ())

(define-error 'ebox-framework-spi-provider-error
  "Invalid Ebox framework SPI provider")

(defconst ebox-framework-spi-version 3
  "Version of the additive Ebox framework provider SPI.")

(defconst ebox-framework-spi-schema-version 'ebox-framework-spi-schema/v3
  "Schema identity for Ebox framework provider records.")

(defconst ebox-framework-spi--required-capabilities
  '(initial-paired-stage-rollback
    update-paired-stage-rollback
    combined-participant-ordering
    same-object-legacy-report
    initial-observation-replay)
  "Capabilities guaranteed by every Ebox framework SPI v3 provider record.")

(defconst ebox-framework-spi--stage-order
  '(ebox-mirror/native framework-stage)
  "Owner order inside the combined Ebox participant stage.")

(defconst ebox-framework-spi--rollback-order
  '(framework-rollback ebox-mirror/native publication)
  "Rollback order exposed by the combined Ebox participant contract.")

(cl-defstruct
    (ebox-framework-spi-operation
     (:constructor ebox-framework-spi--make-operation)
     (:conc-name ebox-framework-spi--operation-))
  "One immutable operation descriptor in the framework SPI."
  (kind nil :read-only t)
  (function nil :read-only t)
  (argument-schema nil :read-only t)
  (result-schema nil :read-only t)
  (paired-stage-rollback-p nil :read-only t))

(cl-defstruct
    (ebox-framework-spi-provider
     (:constructor ebox-framework-spi--make-provider)
     (:conc-name ebox-framework-spi--provider-))
  "One immutable Ebox framework SPI capability record."
  (spi-version nil :read-only t)
  (schema-version nil :read-only t)
  (capabilities nil :read-only t)
  (publication-protocol nil :read-only t)
  (stage-order nil :read-only t)
  (rollback-order nil :read-only t)
  (report-semantics nil :read-only t)
  (initial-operation nil :read-only t)
  (update-operation nil :read-only t))

(defun ebox-framework-spi-operation-kind (operation)
  "Return OPERATION's immutable kind."
  (ebox-framework-spi--operation-kind operation))

(defun ebox-framework-spi-operation-function (operation)
  "Return OPERATION's immutable function symbol."
  (ebox-framework-spi--operation-function operation))

(defun ebox-framework-spi-operation-argument-schema (operation)
  "Return a defensive copy of OPERATION's argument schema."
  (copy-sequence (ebox-framework-spi--operation-argument-schema operation)))

(defun ebox-framework-spi-operation-result-schema (operation)
  "Return OPERATION's immutable result schema."
  (ebox-framework-spi--operation-result-schema operation))

(defun ebox-framework-spi-operation-paired-stage-rollback-p (operation)
  "Return non-nil when OPERATION requires paired stage and rollback."
  (ebox-framework-spi--operation-paired-stage-rollback-p operation))

(defun ebox-framework-spi-provider-spi-version (provider)
  "Return PROVIDER's immutable SPI version."
  (ebox-framework-spi--provider-spi-version provider))

(defun ebox-framework-spi-provider-schema-version (provider)
  "Return PROVIDER's immutable schema version."
  (ebox-framework-spi--provider-schema-version provider))

(defun ebox-framework-spi-provider-capabilities (provider)
  "Return a defensive copy of PROVIDER's capabilities."
  (copy-sequence (ebox-framework-spi--provider-capabilities provider)))

(defun ebox-framework-spi-provider-publication-protocol (provider)
  "Return PROVIDER's immutable Ebox publication protocol."
  (ebox-framework-spi--provider-publication-protocol provider))

(defun ebox-framework-spi-provider-stage-order (provider)
  "Return a defensive copy of PROVIDER's participant stage order."
  (copy-sequence (ebox-framework-spi--provider-stage-order provider)))

(defun ebox-framework-spi-provider-rollback-order (provider)
  "Return a defensive copy of PROVIDER's participant rollback order."
  (copy-sequence (ebox-framework-spi--provider-rollback-order provider)))

(defun ebox-framework-spi-provider-report-semantics (provider)
  "Return PROVIDER's immutable report semantics."
  (ebox-framework-spi--provider-report-semantics provider))

(defun ebox-framework-spi-provider-initial-operation (provider)
  "Return PROVIDER's immutable initial operation descriptor."
  (ebox-framework-spi--provider-initial-operation provider))

(defun ebox-framework-spi-provider-update-operation (provider)
  "Return PROVIDER's immutable update operation descriptor."
  (ebox-framework-spi--provider-update-operation provider))

(defun ebox-framework-spi--validate-callback-pair
    (framework-stage framework-rollback)
  "Validate FRAMEWORK-STAGE and FRAMEWORK-ROLLBACK as a required pair."
  (unless (functionp framework-stage)
    (signal 'wrong-type-argument (list 'functionp framework-stage)))
  (unless (functionp framework-rollback)
    (signal 'wrong-type-argument (list 'functionp framework-rollback)))
  t)

(defun ebox-framework-spi--buffer-overlays (buffer)
  "Return every overlay currently attached to BUFFER."
  (with-current-buffer buffer
    (let ((lists (overlay-lists)))
      (delete-dups (append (car lists) (cdr lists))))))

(defun ebox-framework-spi--snapshot-editor-custody (buffer)
  "Capture BUFFER state that an unsuccessful initial mount must preserve."
  (with-current-buffer buffer
    (let ((restriction-start (point-min))
          (restriction-end (point-max)))
      (save-restriction
        (widen)
        (list
         :point (point)
         :mark-marker (mark-marker)
         :mark-position (mark t)
         :mark-insertion-type (marker-insertion-type (mark-marker))
         :mark-active mark-active
         :restriction-start restriction-start
         :restriction-end restriction-end
         :overlays
         (mapcar (lambda (overlay)
                   (list overlay (overlay-start overlay) (overlay-end overlay)))
                 (ebox-framework-spi--buffer-overlays buffer))
         :undo-list (copy-tree buffer-undo-list)
         :modified-p (buffer-modified-p))))))

(defun ebox-framework-spi--restore-editor-custody (buffer snapshot)
  "Restore BUFFER editor state from SNAPSHOT after mount rollback."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (widen)
      (let* ((overlay-snapshots (plist-get snapshot :overlays))
             (original-overlays (mapcar #'car overlay-snapshots)))
        (dolist (overlay (ebox-framework-spi--buffer-overlays buffer))
          (unless (memq overlay original-overlays)
            (delete-overlay overlay)))
        (dolist (entry overlay-snapshots)
          (when (overlayp (car entry))
            (move-overlay (car entry) (nth 1 entry) (nth 2 entry) buffer))))
      (let ((mark-marker (plist-get snapshot :mark-marker)))
        (set-marker mark-marker (plist-get snapshot :mark-position) buffer)
        (set-marker-insertion-type
         mark-marker (plist-get snapshot :mark-insertion-type)))
      (goto-char (plist-get snapshot :point))
      (setq mark-active (plist-get snapshot :mark-active)
            buffer-undo-list (copy-tree (plist-get snapshot :undo-list)))
      (narrow-to-region (plist-get snapshot :restriction-start)
                        (plist-get snapshot :restriction-end))
      (set-buffer-modified-p (plist-get snapshot :modified-p)))))

(defun ebox-framework-spi-initial
    (buffer-or-name input framework-stage framework-rollback)
  "Initially mount INPUT and run the paired framework callbacks.

FRAMEWORK-STAGE runs after provisional Ebox publication state and Ebox
mirrors/native state agree.  FRAMEWORK-ROLLBACK receives the same legacy
report on any later transaction failure.  Return that same report object
after completion."
  (ebox-framework-spi--validate-callback-pair
   framework-stage framework-rollback)
  (unless (ebox-canonical-input-p input)
    (signal 'wrong-type-argument (list 'ebox-canonical-input-p input)))
  (when (ebox-transaction-active-p)
    (error "Ebox SPI initial operation cannot join an outer Ebox publication transaction"))
  (let ((buffer (get-buffer-create buffer-or-name)))
    (when (ebox-surface-buffer-mounted-p buffer)
      (error "Ebox SPI initial operation requires an unmounted buffer"))
    (let* ((custody (ebox-framework-spi--snapshot-editor-custody buffer))
           (change-group (with-current-buffer buffer (prepare-change-group)))
           (existing-bridge
            (with-current-buffer buffer ebox-surface--publication-observer))
           (started (float-time))
           (participant
            (ebox-surface--make-framework-participant
             :publish
             (lambda (report)
               (plist-put report :framework-initial-observation-started
                          started)
               (funcall framework-stage report))
             :rollback
             (lambda (report)
               (cl-remf report :framework-initial-observation-started)
               (funcall framework-rollback report))
             :state 'unpublished
             :diagnostics nil))
           activated success)
      (unwind-protect
          (progn
            (unless existing-bridge
              (ebox-surface--ensure-publication-observer buffer))
            (with-current-buffer buffer (activate-change-group change-group))
            (setq activated t)
            (prog1 (with-current-buffer buffer
                     (save-restriction
                       (widen)
                       (ebox--render-to-buffer-internal
                        buffer input nil participant)))
              (with-current-buffer buffer (accept-change-group change-group))
              (setq success t)))
        (unwind-protect
            (unless success
              (when (and activated (buffer-live-p buffer))
                (with-current-buffer buffer
                  (cancel-change-group change-group))
                (ebox-framework-spi--restore-editor-custody buffer custody)))
          (unless existing-bridge
            (ebox-surface-cleanup-buffer-observer buffer)))))))

(defun ebox-framework-spi-update
    (buffer-or-name input framework-stage framework-rollback)
  "Update BUFFER-OR-NAME from INPUT through paired framework callbacks.
Return the same completed legacy report object observed by FRAMEWORK-STAGE."
  (ebox-framework-spi--validate-callback-pair
   framework-stage framework-rollback)
  (ebox-commit buffer-or-name input framework-stage framework-rollback))

(defun ebox-framework-spi-initial-observation-reports (report)
  "Return publication/render snapshots captured by completed initial REPORT.
The reports are defensive observational snapshots; they expose no publication
or promotion capability."
  (unless (and (proper-list-p report)
               (eq (plist-get report :framework-participant-state) 'completed)
               (integerp (plist-get report :publication-transaction-id)))
    (signal 'ebox-framework-spi-provider-error
            (list :invalid-initial-report report)))
  (let ((reports
         (plist-get report :framework-initial-observation-reports)))
    (cond
     ((and (proper-list-p reports)
           (= (length reports) 2)
           (equal (mapcar (lambda (item)
                            (plist-get item :provider))
                          reports)
                  '(ebox-publication ebox))
           (cl-every
            (lambda (item)
              (and (numberp (plist-get item :duration-ms))
                   (>= (plist-get item :duration-ms) 0.0)))
            reports))
      (copy-tree reports))
     ((cl-find 'framework-report-finalization
               (plist-get report :framework-participant-diagnostics)
               :key (lambda (entry) (plist-get entry :phase)))
      ;; The accepted publication remains authoritative.  Its completed
      ;; report carries the failure; observer replay is skipped, never
      ;; reclassified as a rollback-capable provider error.
      nil)
     (t
      (signal 'ebox-framework-spi-provider-error
              (list :missing-initial-observation-reports report))))))

(defun ebox-framework-spi--operation
    (kind function argument-schema)
  "Return a fresh KIND operation descriptor for FUNCTION and ARGUMENT-SCHEMA."
  (ebox-framework-spi--make-operation
   :kind kind
   :function function
   :argument-schema (copy-sequence argument-schema)
   :result-schema 'ebox-legacy-report/same-object
   :paired-stage-rollback-p t))

(defun ebox-framework-spi--validate-operation
    (operation kind function argument-schema)
  "Validate OPERATION against KIND, FUNCTION, and ARGUMENT-SCHEMA."
  (unless (and (ebox-framework-spi-operation-p operation)
               (eq (ebox-framework-spi--operation-kind operation) kind)
               (eq (ebox-framework-spi--operation-function operation) function)
               (equal (ebox-framework-spi--operation-argument-schema operation)
                      argument-schema)
               (eq (ebox-framework-spi--operation-result-schema operation)
                   'ebox-legacy-report/same-object)
               (eq (ebox-framework-spi--operation-paired-stage-rollback-p
                    operation)
                   t))
    (signal 'ebox-framework-spi-provider-error
            (list :malformed-operation kind operation)))
  t)

(defun ebox-framework-spi-validate-provider (provider)
  "Validate PROVIDER as one complete Ebox framework SPI v3 record."
  (unless (ebox-framework-spi-provider-p provider)
    (signal 'ebox-framework-spi-provider-error
            (list :malformed-provider provider)))
  (unless (and (eql (ebox-framework-spi--provider-spi-version provider)
                    ebox-framework-spi-version)
               (eq (ebox-framework-spi--provider-schema-version provider)
                   ebox-framework-spi-schema-version)
               (equal (ebox-framework-spi--provider-capabilities provider)
                      ebox-framework-spi--required-capabilities)
               (memq (ebox-framework-spi--provider-publication-protocol provider)
                     ebox-framework-spi-supported-publication-protocols)
               (equal (ebox-framework-spi--provider-stage-order provider)
                      ebox-framework-spi--stage-order)
               (equal (ebox-framework-spi--provider-rollback-order provider)
                      ebox-framework-spi--rollback-order)
               (eq (ebox-framework-spi--provider-report-semantics provider)
                   'same-object-legacy-report))
    (signal 'ebox-framework-spi-provider-error
            (list :malformed-provider-schema provider)))
  (ebox-framework-spi--validate-operation
   (ebox-framework-spi--provider-initial-operation provider)
   'initial 'ebox-framework-spi-initial
   '(buffer canonical-input framework-stage framework-rollback))
  (ebox-framework-spi--validate-operation
   (ebox-framework-spi--provider-update-operation provider)
   'update 'ebox-framework-spi-update
   '(buffer canonical-input-or-candidate framework-stage framework-rollback))
  t)

(defun ebox-framework-spi-capabilities ()
  "Return a fresh immutable Ebox framework SPI v3 provider record."
  (let ((provider
         (ebox-framework-spi--make-provider
          :spi-version ebox-framework-spi-version
          :schema-version ebox-framework-spi-schema-version
          :capabilities
          (copy-sequence ebox-framework-spi--required-capabilities)
          :publication-protocol 'ebox-publication/v1
          :stage-order (copy-sequence ebox-framework-spi--stage-order)
          :rollback-order (copy-sequence ebox-framework-spi--rollback-order)
          :report-semantics 'same-object-legacy-report
          :initial-operation
          (ebox-framework-spi--operation
           'initial 'ebox-framework-spi-initial
           '(buffer canonical-input framework-stage framework-rollback))
          :update-operation
          (ebox-framework-spi--operation
           'update 'ebox-framework-spi-update
           '(buffer canonical-input-or-candidate
             framework-stage framework-rollback)))))
    (ebox-framework-spi-validate-provider provider)
    provider))

(provide 'ebox-framework-spi-v3)
(provide 'ebox-spi)

;;; ebox-spi.el ends here
