;;; ebox-spi-tests.el --- M2a framework provider SPI gates -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'benchmark)
(require 'ebox)
(require 'ebox-spi)
(require 'ebox-fixtures)

(defconst ebox-spi-test--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by provider SPI tests.")

(defun ebox-spi-test--source (file)
  "Return repository FILE as text."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file ebox-spi-test--root))
    (buffer-string)))

(defun ebox-spi-test--reset-runtime-state ()
  "Reset identities and compatibility mirrors used by SPI tests."
  (setq ebox--region-id-counter 0
        ebox--runtime-node-id-counter 0)
  (dolist (table (list ebox--region-box-table
                       ebox--buffer-render-state-table
                       ebox--scroll-global-state))
    (when (hash-table-p table) (clrhash table))))

(ert-deftest ebox-spi-provider-schema-is-complete-and-defensive ()
  "The additive v2 provider exposes one complete immutable snapshot."
  (let* ((first (ebox-framework-spi-capabilities))
         (second (ebox-framework-spi-capabilities))
         (initial (ebox-framework-spi-provider-initial-operation first))
         (update (ebox-framework-spi-provider-update-operation first)))
    (should (featurep 'ebox-framework-spi-v2))
    (should (ebox-framework-spi-validate-provider first))
    (should-not (eq first second))
    (should (= (ebox-framework-spi-provider-spi-version first) 2))
    (should (eq (ebox-framework-spi-provider-schema-version first)
                'ebox-framework-spi-schema/v2))
    (should (eq (ebox-framework-spi-provider-tp-protocol first)
                'tp-transaction-protocol-v1+v2))
    (should
     (equal (ebox-framework-spi-provider-capabilities first)
            '(initial-paired-stage-rollback
              update-paired-stage-rollback
              combined-participant-ordering
              same-object-legacy-report)))
    (should
     (equal (ebox-framework-spi-provider-stage-order first)
            '(ebox-mirror/native framework-stage)))
    (should
     (equal (ebox-framework-spi-provider-rollback-order first)
            '(framework-rollback ebox-mirror/native tp)))
    (should (eq (ebox-framework-spi-provider-report-semantics first)
                'same-object-legacy-report))
    (should (eq (ebox-framework-spi-operation-kind initial) 'initial))
    (should (eq (ebox-framework-spi-operation-function initial)
                'ebox-framework-spi-initial))
    (should
     (equal (ebox-framework-spi-operation-argument-schema initial)
            '(buffer canonical-input framework-stage framework-rollback)))
    (should (eq (ebox-framework-spi-operation-result-schema initial)
                'ebox-legacy-report/same-object))
    (should (eq (ebox-framework-spi-operation-paired-stage-rollback-p initial)
                t))
    (should (eq (ebox-framework-spi-operation-kind update) 'update))
    (should (eq (ebox-framework-spi-operation-function update)
                'ebox-framework-spi-update))
    (should
     (equal (ebox-framework-spi-operation-argument-schema update)
            '(buffer canonical-input-or-candidate
              framework-stage framework-rollback)))
    (should (eq (ebox-framework-spi-operation-result-schema update)
                'ebox-legacy-report/same-object))
    (should (eq (ebox-framework-spi-operation-paired-stage-rollback-p update)
                t))
    (should-error
     (eval
      `(setf (ebox-framework-spi-provider-spi-version ',first) 3)))
    (should-error
     (eval
      `(setf (ebox-framework-spi-operation-kind ',initial) 'broken)))
    (let ((capabilities (ebox-framework-spi-provider-capabilities first))
          (stage-order (ebox-framework-spi-provider-stage-order first))
          (rollback-order (ebox-framework-spi-provider-rollback-order first))
          (arguments (ebox-framework-spi-operation-argument-schema initial)))
      (setcar capabilities 'mutated)
      (setcar stage-order 'mutated)
      (setcar rollback-order 'mutated)
      (setcar arguments 'mutated))
    (should (ebox-framework-spi-validate-provider first))
    (should (eq (car (ebox-framework-spi-provider-capabilities first))
                'initial-paired-stage-rollback))
    (should (eq (car (ebox-framework-spi-provider-stage-order first))
                'ebox-mirror/native))
    (should (eq (car (ebox-framework-spi-provider-rollback-order first))
                'framework-rollback))
    (should (eq (car (ebox-framework-spi-operation-argument-schema initial))
                'buffer))
    (let ((fresh (ebox-framework-spi-capabilities)))
      (should (eq (car (ebox-framework-spi-provider-capabilities fresh))
                  'initial-paired-stage-rollback))
      (should (eq (car (ebox-framework-spi-operation-argument-schema
                        (ebox-framework-spi-provider-initial-operation fresh)))
                  'buffer)))))

(ert-deftest ebox-spi-provider-is-additive-and-does-not-bootstrap-consumers ()
  "E5 publishes no selected port, consumer probe, or v1 removal."
  (let ((source (ebox-spi-test--source "ebox-spi.el"))
        (facade (ebox-spi-test--source "ebox.el")))
    (dolist (pattern '("featurep" "fboundp" "selected-port"
                       "etaf-renderer-port" "etaf-spi-bootstrap"))
      (should-not (string-match-p (regexp-quote pattern) source)))
    (should (string-match-p "(tp \"1.0.0\")" facade))
    (should (functionp #'ebox-render-to-buffer))
    (should (functionp #'ebox-commit))
    (should (functionp #'ebox-framework-spi-capabilities))))

(ert-deftest ebox-spi-initial-and-update-share-their-legacy-report ()
  "Both operation descriptors preserve paired callbacks and report identity."
  (ebox-spi-test--reset-runtime-state)
  (let* ((provider (ebox-framework-spi-capabilities))
         (initial-function
          (ebox-framework-spi-operation-function
           (ebox-framework-spi-provider-initial-operation provider)))
         (update-function
          (ebox-framework-spi-operation-function
           (ebox-framework-spi-provider-update-operation provider)))
         (buffer (generate-new-buffer " *ebox-m2a-e5-success*"))
         initial-seen update-seen trace)
    (unwind-protect
        (let ((initial-report
               (funcall
                initial-function buffer
                (ebox-test-box :key 'root (ebox-test-text "initial")
                               :width '(96))
                (lambda (report)
                  (setq initial-seen report)
                  (push 'initial-stage trace)
                  (should (eq (plist-get report :framework-participant-state)
                              'published))
                  (let ((surface (ebox-surface--live-buffer-surface buffer)))
                    (should surface)
                    (should
                     (eq (gethash buffer ebox--buffer-render-state-table)
                         (tp-surface-client-state surface))))
                  (plist-put report :framework-token 'initial-token))
                (lambda (_report) (push 'initial-rollback trace)))))
          (should (eq initial-report initial-seen))
          (should (eq (plist-get initial-report :framework-participant-state)
                      'completed))
          (should (eq (plist-get initial-report :framework-token)
                      'initial-token))
          (should (eq (plist-get initial-report :strategy) 'initial-mount))
          (should (equal trace '(initial-stage)))
          (setq trace nil)
          (let ((update-report
                 (funcall
                  update-function buffer
                  (ebox-test-box :key 'root (ebox-test-text "updated")
                                 :width '(96))
                  (lambda (report)
                    (setq update-seen report)
                    (push 'update-stage trace)
                    (plist-put report :framework-token 'update-token))
                  (lambda (_report) (push 'update-rollback trace)))))
            (should (eq update-report update-seen))
            (should (eq (plist-get update-report
                                   :framework-participant-state)
                        'completed))
            (should (eq (plist-get update-report :framework-token)
                        'update-token))
            (should (equal trace '(update-stage)))
            (should (string-match-p
                     "updated"
                     (with-current-buffer buffer
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-spi-initial-rolls-the-same-report-back ()
  "A later TP failure rolls initial framework and Ebox state back in order."
  (ebox-spi-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-m2a-e5-initial-fault*"))
        (original
         (symbol-function 'tp--run-transaction-precommit-functions))
        stage-report rollback-report trace failure)
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "sentinel"))
          (cl-letf
              (((symbol-function 'tp--run-transaction-precommit-functions)
                (lambda ()
                  (funcall original)
                  (error "E5 initial later failure"))))
            (setq failure
                  (condition-case condition
                      (ebox-framework-spi-initial
                       buffer
                       (ebox-test-box
                        :key 'root :width '(96) :height 1 :overflow 'scroll
                        (ebox-test-text "zero\none\ntwo\nthree"))
                       (lambda (report)
                         (setq stage-report report)
                         (push 'stage trace)
                         (should (> (hash-table-count
                                     ebox--scroll-global-state)
                                    0)))
                       (lambda (report)
                         (setq rollback-report report)
                         (push 'rollback trace)))
                    (error condition))))
          (should (equal (cadr failure) "E5 initial later failure"))
          (should (equal trace '(rollback stage)))
          (should (eq stage-report rollback-report))
          (should (eq (plist-get stage-report :framework-participant-state)
                      'rolled-back))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (should-not (gethash buffer ebox--buffer-render-state-table))
          (should (= (hash-table-count ebox--scroll-global-state) 0))
          (should
           (equal (with-current-buffer buffer (buffer-string)) "sentinel")))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-spi-initial-stage-failure-runs-its-pair ()
  "An initial framework-stage error rolls back the same report and mount."
  (ebox-spi-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-m2a-e5-stage-fault*"))
        stage-report rollback-report trace)
    (unwind-protect
        (progn
          (should-error
           (ebox-framework-spi-initial
            buffer
            (ebox-test-box :key 'root (ebox-test-text "rejected"))
            (lambda (report)
              (setq stage-report report)
              (push 'stage trace)
              (error "E5 stage callback failure"))
            (lambda (report)
              (setq rollback-report report)
              (push 'rollback trace))))
          (should (equal trace '(rollback stage)))
          (should (eq stage-report rollback-report))
          (should (eq (plist-get stage-report :framework-participant-state)
                      'rolled-back))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (should-not (gethash buffer ebox--buffer-render-state-table))
          (should (equal (with-current-buffer buffer (buffer-string)) "")))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-spi-update-rolls-the-same-report-back ()
  "A later TP failure restores update state through the v2 operation."
  (ebox-spi-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-m2a-e5-update-fault*"))
        (original
         (symbol-function 'tp--run-transaction-precommit-functions))
        stage-report rollback-report trace)
    (unwind-protect
        (progn
          (ebox-render-to-buffer
           buffer (ebox-test-box :key 'root (ebox-test-text "old")))
          (let* ((surface (ebox-surface--live-buffer-surface buffer))
                 (state (tp-surface-client-state surface))
                 (revision (tp-surface-revision surface))
                 (contents
                  (with-current-buffer buffer
                    (buffer-substring (point-min) (point-max)))))
            (cl-letf
                (((symbol-function 'tp--run-transaction-precommit-functions)
                  (lambda ()
                    (funcall original)
                    (error "E5 update later failure"))))
              (should-error
               (ebox-framework-spi-update
                buffer
                (ebox-test-box :key 'root (ebox-test-text "rejected"))
                (lambda (report)
                  (setq stage-report report)
                  (push 'stage trace))
                (lambda (report)
                  (setq rollback-report report)
                  (push 'rollback trace)))))
            (should (equal trace '(rollback stage)))
            (should (eq stage-report rollback-report))
            (should (eq (plist-get stage-report
                                   :framework-participant-state)
                        'rolled-back))
            (should (eq (tp-surface-client-state surface) state))
            (should (= (tp-surface-revision surface) revision))
            (should
             (equal-including-properties
              (with-current-buffer buffer
                (buffer-substring (point-min) (point-max)))
              contents))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-spi-rejects-malformed-pairs-and-provider-records ()
  "Provider-side schemas reject malformed callbacks and capability records."
  (let ((buffer (generate-new-buffer " *ebox-m2a-e5-invalid*"))
        (input (ebox-test-box :key 'root (ebox-test-text "invalid")))
        (valid (ebox-framework-spi-capabilities)))
    (unwind-protect
        (progn
          (should-error
           (ebox-framework-spi-initial buffer input nil #'ignore)
           :type 'wrong-type-argument)
          (should-error
           (ebox-framework-spi-initial buffer input #'ignore nil)
           :type 'wrong-type-argument)
          (should-error
           (ebox-framework-spi-update buffer input 7 #'ignore)
           :type 'wrong-type-argument)
          (should-error
           (ebox-framework-spi-validate-provider
            (ebox-framework-spi--make-provider
             :spi-version 99
             :schema-version 'broken
             :capabilities nil
             :tp-protocol 'broken))
           :type 'ebox-framework-spi-provider-error)
          (should-error
           (ebox-framework-spi-validate-provider
            (ebox-framework-spi--make-provider
             :spi-version 2
             :schema-version 'ebox-framework-spi-schema/v2
             :capabilities
             '(initial-paired-stage-rollback
               update-paired-stage-rollback
               combined-participant-ordering
               same-object-legacy-report)
             :tp-protocol 'tp-transaction-protocol-v1+v2
             :stage-order '(ebox-mirror/native framework-stage)
             :rollback-order '(framework-rollback ebox-mirror/native tp)
             :report-semantics 'same-object-legacy-report
             :initial-operation
             (ebox-framework-spi--make-operation
              :kind 'initial
              :function 'ebox-framework-spi-initial
              :argument-schema
              '(buffer canonical-input framework-stage framework-rollback)
              :result-schema 'broken
              :paired-stage-rollback-p nil)
             :update-operation
             (ebox-framework-spi-provider-update-operation valid)))
           :type 'ebox-framework-spi-provider-error))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-spi-performance-builds-bounded-provider-snapshots ()
  "Capability access constructs one provider and two operations per call."
  (let ((provider-count 0)
        (operation-count 0)
        (provider-constructor
         (symbol-function 'ebox-framework-spi--make-provider))
        (operation-factory
         (symbol-function 'ebox-framework-spi--operation))
        benchmark last)
    (cl-letf (((symbol-function 'ebox-framework-spi--make-provider)
               (lambda (&rest arguments)
                 (cl-incf provider-count)
                 (apply provider-constructor arguments)))
              ((symbol-function 'ebox-framework-spi--operation)
               (lambda (&rest arguments)
                 (cl-incf operation-count)
                 (apply operation-factory arguments))))
      (setq benchmark
            (benchmark-run
              1
              (dotimes (_iteration 1000)
                (setq last (ebox-framework-spi-capabilities))))))
    (should (ebox-framework-spi-provider-p last))
    (should (= provider-count 1000))
    (should (= operation-count 2000))
    (should (< (car benchmark) 2.0))))

(provide 'ebox-spi-tests)

;;; ebox-spi-tests.el ends here
