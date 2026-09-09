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
    (should (equal ebox-framework-spi-required-tp-version "2.0.0"))
    (should (equal ebox-framework-spi-supported-tp-protocols
                   '(tp-transaction-protocol-v1+v2
                     tp-transaction-protocol-v2)))
    (should (eq (ebox-framework-spi-provider-schema-version first)
                'ebox-framework-spi-schema/v2))
    (should (eq (ebox-framework-spi-provider-tp-protocol first)
                tp-transaction-protocol))
    (should
     (equal (ebox-framework-spi-provider-capabilities first)
            '(initial-paired-stage-rollback
              update-paired-stage-rollback
              combined-participant-ordering
              same-object-legacy-report
              initial-observation-replay)))
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

(ert-deftest ebox-spi-provider-does-not-bootstrap-consumers ()
  "The provider publishes no selected port or consumer probe."
  (let ((source (ebox-spi-test--source "ebox-spi.el"))
        (facade (ebox-spi-test--source "ebox.el")))
    (dolist (pattern '("featurep" "fboundp" "selected-port"
                       "etaf-renderer-port" "etaf-spi-bootstrap"))
      (should-not (string-match-p (regexp-quote pattern) source)))
    (should (string-match-p "Version: 3.0.0" facade))
    (should (string-match-p "(tp \"2.0.0\")" facade))
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

(ert-deftest ebox-spi-initial-replays-observational-provider-reports ()
  "Completed initial reports replay TP then Ebox without mutable authority."
  (ebox-spi-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-m2a-e5-observation*")))
    (unwind-protect
        (let* ((report
                (ebox-framework-spi-initial
                 buffer
                 (ebox-test-box :key 'root (ebox-test-text "observed"))
                 #'ignore #'ignore))
               (reports
                (ebox-framework-spi-initial-observation-reports report)))
          (should (equal (mapcar (lambda (item) (plist-get item :provider))
                                 reports)
                         '(tp ebox)))
          (should (equal (mapcar (lambda (item) (plist-get item :stage))
                                 reports)
                         '(publication mount)))
          (should
           (apply #'=
                  (mapcar (lambda (item)
                            (plist-get item :correlation-id))
                          reports)))
          (dolist (item reports)
            (should (numberp (plist-get item :duration-ms)))
            (should (> (plist-get item :duration-ms) 0.0)))
          (should
           (equal reports
                  (plist-get report
                             :framework-initial-observation-reports)))
          (plist-put (car reports) :provider 'mutated)
          (should-not (plist-member report :provider)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-spi-native-retirement-failure-is-postaccept-diagnostic ()
  "A contained native retirement failure cannot escape after final accept."
  (ebox-spi-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-m2a-e5-native-retirement*"))
        (diagnostic
         '(:phase native-session-retirement :session-id 7
           :condition (error "release failed"))))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-surface--settle-native-session)
                   (lambda (&rest _arguments) (list diagnostic))))
          (let ((report
                 (ebox-framework-spi-initial
                  buffer
                  (ebox-test-box :key 'root (ebox-test-text "committed"))
                  #'ignore #'ignore)))
            (should (eq (plist-get report :framework-participant-state)
                        'completed))
            (should
             (equal (plist-get report :framework-participant-diagnostics)
                    (list diagnostic)))
            (should (ebox-surface-buffer-mounted-p buffer))
            (should (equal "committed"
                           (with-current-buffer buffer
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))
            (let ((update-report
                   (ebox-framework-spi-update
                    buffer
                    (ebox-test-box :key 'root (ebox-test-text "updated"))
                    #'ignore #'ignore)))
              (should (eq (plist-get update-report
                                     :framework-participant-state)
                          'completed))
              (should
               (equal
                (plist-get update-report :framework-participant-diagnostics)
                (list diagnostic)))
              (should (equal "updated"
                             (with-current-buffer buffer
                               (buffer-substring-no-properties
                                (point-min) (point-max))))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-spi-postaccept-report-failure-never-enters-rollback ()
  "Initial, scoped, and full report-finalization faults stay postaccept."
  (ebox-spi-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-m2a-e5-report-finalization*"))
        (rollback-count 0))
    (unwind-protect
        (cl-letf (((symbol-function 'ebox-surface--participant-complete)
                   (lambda (&rest _arguments)
                     (error "injected report finalization failure"))))
          (cl-labels
              ((assert-completed
                (report)
                (should (eq (plist-get report :framework-participant-state)
                            'completed))
                (should
                 (eq (plist-get
                      (car (plist-get report
                                     :framework-participant-diagnostics))
                      :phase)
                     'framework-report-finalization))))
            (let ((initial-report
                   (ebox-framework-spi-initial
                    buffer
                    (ebox-test-box :key 'root (ebox-test-text "initial"))
                    #'ignore (lambda (_report) (cl-incf rollback-count)))))
              (assert-completed initial-report)
              (should-not
               (ebox-framework-spi-initial-observation-reports
                initial-report)))
            (assert-completed
             (ebox-framework-spi-update
              buffer (ebox-test-box :key 'root (ebox-test-text "scoped"))
              #'ignore (lambda (_report) (cl-incf rollback-count))))
            (let ((candidate (ebox-candidate-begin buffer)))
              (ebox-candidate-replace-root
               candidate
               (ebox-test-box :key 'root (ebox-test-text "full")))
              (assert-completed
               (ebox-framework-spi-update
                buffer candidate #'ignore
                (lambda (_report) (cl-incf rollback-count)))))
            (should (zerop rollback-count))
            (should (string-match-p
                     "full"
                     (with-current-buffer buffer
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-spi-public-unmount-allows-a-fresh-initial-generation ()
  "Public Ebox teardown removes retained authority before a later initial."
  (ebox-spi-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-m2a-e5-remount*")))
    (unwind-protect
        (progn
          (ebox-framework-spi-initial
           buffer (ebox-test-box :key 'root (ebox-test-text "first"))
           #'ignore #'ignore)
          (should (ebox-surface-buffer-mounted-p buffer))
          (should (eq (ebox-unmount-buffer buffer) buffer))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (ebox-framework-spi-initial
           buffer (ebox-test-box :key 'root (ebox-test-text "second"))
           #'ignore #'ignore)
          (should (ebox-surface-buffer-mounted-p buffer))
          (should (string-match-p
                   "second"
                   (with-current-buffer buffer
                     (buffer-substring-no-properties
                      (point-min) (point-max))))))
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

(ert-deftest ebox-spi-initial-activation-failure-cleans-only-owned-observer ()
  "Activation errors and throws preserve text and pre-existing observers."
  (dolist (failure '(error throw))
    (dolist (existing '(nil t))
      (ert-info ((format "failure=%s existing-observer=%s" failure existing))
        (let ((buffer (generate-new-buffer " *ebox-spi-activation-fault*"))
              (input (ebox-test-box :key 'root (ebox-test-text "new")))
              prior-observer cancelled result)
          (unwind-protect
              (progn
                (with-current-buffer buffer
                  (insert (propertize "sentinel" 'face 'bold)))
                (when existing
                  (setq prior-observer
                        (ebox-surface--ensure-tp-observer buffer)))
                (cl-letf (((symbol-function 'activate-change-group)
                           (lambda (_group)
                             (if (eq failure 'throw)
                                 (throw 'ebox-spi-activation 'activation-throw)
                               (error "activation-error"))))
                          ((symbol-function 'cancel-change-group)
                           (lambda (_group) (setq cancelled t))))
                  (setq result
                        (catch 'ebox-spi-activation
                          (condition-case condition
                              (ebox-framework-spi-initial
                               buffer input #'ignore #'ignore)
                            (error condition)))))
                (should (equal result
                               (if (eq failure 'throw) 'activation-throw
                                 '(error "activation-error"))))
                (should-not cancelled)
                (should-not (ebox-surface-buffer-mounted-p buffer))
                (should-not (gethash buffer ebox--buffer-render-state-table))
                (with-current-buffer buffer
                  (should (eq ebox-surface--tp-observer prior-observer))
                  (should (equal-including-properties
                           (buffer-string)
                           (propertize "sentinel" 'face 'bold)))))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest ebox-spi-initial-failure-restores-exact-editor-custody ()
  "A failed initial mount preserves editor identities, bounds, and history."
  (ebox-spi-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-spi-editor-custody*"))
        (input (ebox-test-box :key 'root (ebox-test-text "committed")))
        overlay left-marker right-marker snapshot captured)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (buffer-enable-undo)
            (insert (propertize "sentinel" 'face 'bold))
            (undo-boundary)
            (goto-char 4)
            (set-mark 2)
            (setq mark-active t
                  overlay (make-overlay 2 6 buffer t t)
                  left-marker (copy-marker 3 nil)
                  right-marker (copy-marker 5 t))
            (overlay-put overlay 'ebox-test-property '(owned value))
            (narrow-to-region 2 7)
            (set-buffer-modified-p nil)
            (setq snapshot
                  (list
                   :contents
                   (save-restriction
                     (widen)
                     (buffer-substring (point-min) (point-max)))
                   :point (point)
                   :mark-marker (mark-marker)
                   :mark-position (mark t)
                   :mark-insertion-type
                   (marker-insertion-type (mark-marker))
                   :mark-active mark-active
                   :narrow-start (point-min)
                   :narrow-end (point-max)
                   :overlay-start (overlay-start overlay)
                   :overlay-end (overlay-end overlay)
                   :overlay-properties (overlay-properties overlay)
                   :left-position (marker-position left-marker)
                   :left-insertion-type (marker-insertion-type left-marker)
                   :right-position (marker-position right-marker)
                   :right-insertion-type (marker-insertion-type right-marker)
                   :undo-list (copy-tree buffer-undo-list)
                   :modified-p (buffer-modified-p))))
          (condition-case condition
              (ebox-framework-spi-initial
               buffer input
               (lambda (_report) (error "editor custody primary"))
               #'ignore)
            (error (setq captured condition)))
          (should (equal captured '(error "editor custody primary")))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (should-not (ebox-surface-buffer-observer buffer))
          (with-current-buffer buffer
            (should
             (equal (save-restriction
                      (widen)
                      (buffer-substring (point-min) (point-max)))
                    (plist-get snapshot :contents)))
            (should (= (point) (plist-get snapshot :point)))
            (should (eq (mark-marker) (plist-get snapshot :mark-marker)))
            (should (= (mark t) (plist-get snapshot :mark-position)))
            (should (eq (marker-insertion-type (mark-marker))
                        (plist-get snapshot :mark-insertion-type)))
            (should (eq mark-active (plist-get snapshot :mark-active)))
            (should (= (point-min) (plist-get snapshot :narrow-start)))
            (should (= (point-max) (plist-get snapshot :narrow-end)))
            (should (eq (overlay-buffer overlay) buffer))
            (should (= (overlay-start overlay)
                       (plist-get snapshot :overlay-start)))
            (should (= (overlay-end overlay)
                       (plist-get snapshot :overlay-end)))
            (should (equal (overlay-properties overlay)
                           (plist-get snapshot :overlay-properties)))
            (should (= (marker-position left-marker)
                       (plist-get snapshot :left-position)))
            (should (eq (marker-insertion-type left-marker)
                        (plist-get snapshot :left-insertion-type)))
            (should (= (marker-position right-marker)
                       (plist-get snapshot :right-position)))
            (should (eq (marker-insertion-type right-marker)
                        (plist-get snapshot :right-insertion-type)))
            (should (equal buffer-undo-list (plist-get snapshot :undo-list)))
            (should (eq (buffer-modified-p)
                        (plist-get snapshot :modified-p)))))
      (when (overlayp overlay) (delete-overlay overlay))
      (when (markerp left-marker) (set-marker left-marker nil))
      (when (markerp right-marker) (set-marker right-marker nil))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest ebox-spi-rollback-throw-cannot-stop-initial-cleanup ()
  "A framework rollback throw escapes only after editor cleanup completes."
  (ebox-spi-test--reset-runtime-state)
  (let ((buffer (generate-new-buffer " *ebox-spi-rollback-throw*"))
        (input (ebox-test-box :key 'root (ebox-test-text "committed"))))
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "before"))
          (should
           (eq
            (catch 'ebox-spi-rollback-escape
              (ebox-framework-spi-initial
               buffer input
               (lambda (_report) (error "primary before rollback throw"))
               (lambda (_report)
                 (throw 'ebox-spi-rollback-escape 'rollback-escaped)))
              'not-escaped)
            'rollback-escaped))
          (should-not (ebox-surface-buffer-mounted-p buffer))
          (should-not (ebox-surface-buffer-observer buffer))
          (should (equal "before"
                         (with-current-buffer buffer (buffer-string)))))
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
