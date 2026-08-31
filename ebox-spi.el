;;; ebox-spi.el --- Versioned Ebox framework provider -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Additive provider-side Ebox framework SPI v2.  This module publishes an
;; immutable capability snapshot and delegates initial/update execution to the
;; existing combined Ebox participant.  It does not select a consumer port,
;; probe a framework package, or remove the v1 callback surface.

;;; Code:

(require 'cl-lib)
(require 'ebox-canonical)
(require 'ebox-surface)
(require 'tp-transaction)

(declare-function ebox--render-to-buffer-internal
                  "ebox" (buffer-or-name input options &optional participant))
(declare-function ebox-commit
                  "ebox"
                  (buffer-or-name next-root &optional framework-stage
                                  framework-rollback))
(declare-function tp-transaction-active-p "tp-reactive" ())

(define-error 'ebox-framework-spi-provider-error
  "Invalid Ebox framework SPI provider")

(defconst ebox-framework-spi-version 2
  "Version of the additive Ebox framework provider SPI.")

(defconst ebox-framework-spi-schema-version 'ebox-framework-spi-schema/v2
  "Schema identity for Ebox framework provider records.")

(defconst ebox-framework-spi--required-capabilities
  '(initial-paired-stage-rollback
    update-paired-stage-rollback
    combined-participant-ordering
    same-object-legacy-report)
  "Capabilities guaranteed by every Ebox framework SPI v2 provider record.")

(defconst ebox-framework-spi--stage-order
  '(ebox-mirror/native framework-stage)
  "Owner order inside the combined Ebox participant stage.")

(defconst ebox-framework-spi--rollback-order
  '(framework-rollback ebox-mirror/native tp)
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
  (tp-protocol nil :read-only t)
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

(defun ebox-framework-spi-provider-tp-protocol (provider)
  "Return PROVIDER's immutable TP protocol."
  (ebox-framework-spi--provider-tp-protocol provider))

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

(defun ebox-framework-spi-initial
    (buffer-or-name input framework-stage framework-rollback)
  "Initially mount INPUT and run the paired framework callbacks.

FRAMEWORK-STAGE runs after provisional TP state and Ebox mirrors/native state
agree.  FRAMEWORK-ROLLBACK receives the same legacy report on any later
transaction failure.  Return that same report object after completion."
  (ebox-framework-spi--validate-callback-pair
   framework-stage framework-rollback)
  (unless (ebox-canonical-input-p input)
    (signal 'wrong-type-argument (list 'ebox-canonical-input-p input)))
  (when (tp-transaction-active-p)
    (error "Ebox SPI initial operation cannot join an outer TP transaction"))
  (let ((buffer (get-buffer-create buffer-or-name)))
    (when (ebox-surface-buffer-mounted-p buffer)
      (error "Ebox SPI initial operation requires an unmounted buffer"))
    (let ((participant
           (ebox-surface--make-framework-participant
            :publish framework-stage
            :rollback framework-rollback
            :state 'unpublished
            :diagnostics nil)))
      (ebox--render-to-buffer-internal buffer input nil participant))))

(defun ebox-framework-spi-update
    (buffer-or-name input framework-stage framework-rollback)
  "Update BUFFER-OR-NAME from INPUT through paired framework callbacks.
Return the same completed legacy report object observed by FRAMEWORK-STAGE."
  (ebox-framework-spi--validate-callback-pair
   framework-stage framework-rollback)
  (ebox-commit buffer-or-name input framework-stage framework-rollback))

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
  "Validate PROVIDER as one complete Ebox framework SPI v2 record."
  (unless (ebox-framework-spi-provider-p provider)
    (signal 'ebox-framework-spi-provider-error
            (list :malformed-provider provider)))
  (unless (and (eql (ebox-framework-spi--provider-spi-version provider)
                    ebox-framework-spi-version)
               (eq (ebox-framework-spi--provider-schema-version provider)
                   ebox-framework-spi-schema-version)
               (equal (ebox-framework-spi--provider-capabilities provider)
                      ebox-framework-spi--required-capabilities)
               (eq (ebox-framework-spi--provider-tp-protocol provider)
                   tp-transaction-protocol)
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
  "Return a fresh immutable Ebox framework SPI v2 provider record."
  (let ((provider
         (ebox-framework-spi--make-provider
          :spi-version ebox-framework-spi-version
          :schema-version ebox-framework-spi-schema-version
          :capabilities
          (copy-sequence ebox-framework-spi--required-capabilities)
          :tp-protocol tp-transaction-protocol
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

(provide 'ebox-framework-spi-v2)
(provide 'ebox-spi)

;;; ebox-spi.el ends here
