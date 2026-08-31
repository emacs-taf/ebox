;;; ebox-performance-evaluator.el --- Stage performance evaluator -*- lexical-binding: t; -*-

;;; Commentary:
;; Batch entry point for the repository-local performance contract.
;;
;;   emacs -Q -L . -L ../new-architecture/ecss -L ../tp \
;;     -l scripts/ebox-performance-evaluator.el \
;;     -f ebox-performance-evaluator-batch

;;; Code:

(require 'cl-lib)
(require 'ert)

(defconst ebox-performance-evaluator--root
  (expand-file-name ".."
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Repository root used by the performance evaluator.")

(add-to-list 'load-path ebox-performance-evaluator--root)

(require 'ebox)
(require 'ebox-selector)
(require 'tp-surface)

(defconst ebox-performance-evaluator--stage-specs
  '((candidate-preparation
     ebox-tree-copy-node-structure
     ebox-tree-validate-declarative-root
     ebox-surface--clear-runtime-attachments
     ebox-surface--candidate-root
     ebox-surface--reconcile-candidate
     ebox-incremental--prepare-declarative-root
     ebox-incremental--prepare-logical-candidate
     ebox-incremental--prepare-declarative-runtime
     ebox-incremental--prepare-viewport-commit
     ebox-tree-reconcile-runtime)
    (style-cascade
     ebox-tree-subject-index
     ebox-style-compute-subject
     ecss-compute-style
     ebox-style-apply-computed)
    (node-projection
     ebox-surface--projection-start
     ebox-surface--ensure-node-tree
     ebox--runtime-index)
    (layout-fragment-ownership
     ebox--render-layout
     ebox-surface--render-candidate
     ebox-surface--owned-ranges
     ebox-surface--surface-plan
     ebox-incremental--layout-owner-plan)
    (tp-object-preparation
     tp-object-ensure
     tp-object-retain
     tp-bind)
    (publication
     tp-surface-materialize-string
     tp-surface-mount
     tp-surface-update
     tp-surface-update-scoped
     ebox-surface--publish-runtime-state))
  "Functions grouped by computation or publication stage.")

(defvar ebox-performance-evaluator--active nil
  "Non-nil while a measured evaluator action is running.")

(defvar ebox-performance-evaluator--stack nil
  "Advice frames used to subtract nested stage timings.")

(defvar ebox-performance-evaluator--metrics nil
  "Hash table containing per-function inclusive and exclusive timings.")

(defun ebox-performance-evaluator--hash-table-p (symbol)
  "Return non-nil when SYMBOL is bound to a hash table."
  (and (boundp symbol) (hash-table-p (symbol-value symbol))))

(defun ebox-performance-evaluator--cancel-timers (symbol)
  "Cancel and clear timers stored in hash table SYMBOL."
  (when (ebox-performance-evaluator--hash-table-p symbol)
    (maphash (lambda (_key timer)
               (when (timerp timer)
                 (cancel-timer timer)))
             (symbol-value symbol))
    (clrhash (symbol-value symbol))))

(defun ebox-performance-evaluator--reset-runtime-state ()
  "Reset global Ebox runtime tables used by one evaluator scenario."
  (setq ebox--region-id-counter 0
        ebox--runtime-node-id-counter 0
        ebox--render-region-id nil
        ebox--deferred-render-gc-state nil)
  (when (timerp ebox--deferred-render-gc-timer)
    (cancel-timer ebox--deferred-render-gc-timer))
  (setq ebox--deferred-render-gc-timer nil)
  (dolist (symbol '(ebox--region-box-table
                    ebox--buffer-render-state-table
                    ebox--scroll-global-state
                    ebox--smooth-scroll-state-table
                    ebox--render-root-cache-table-table
                    ebox--render-cache-entry-side-effects-table
                    ebox--rendered-uniform-width-table
                    ebox--flex-sized-render-observation-table
                    ebox--runtime-prewarm-jobs
                    ebox--flex-content-min-width-table))
    (when (ebox-performance-evaluator--hash-table-p symbol)
      (clrhash (symbol-value symbol))))
  (dolist (symbol '(ebox--scroll-idle-prefetch-timers
                    ebox--runtime-prewarm-timers
                    ebox--reflow-cache-prewarm-timers))
    (ebox-performance-evaluator--cancel-timers symbol))
  (when (fboundp 'ebox-cache-reset-default-registry)
    (ebox-cache-reset-default-registry)))

(defun ebox-performance-evaluator--reset-counters ()
  "Reset ephemeral counters without changing the stylesheet."
  (setq ebox--region-id-counter 0
        ebox--runtime-node-id-counter 0
        ebox--render-region-id nil))

(defun ebox-performance-evaluator--metric (key)
  "Return or create the timing vector for KEY."
  (or (gethash key ebox-performance-evaluator--metrics)
      (let ((value (vector 0 0.0 0.0)))
        (puthash key value ebox-performance-evaluator--metrics)
        value)))

(defun ebox-performance-evaluator--record (category function elapsed exclusive)
  "Record CATEGORY FUNCTION timing values ELAPSED and EXCLUSIVE."
  (let ((value (ebox-performance-evaluator--metric
                (list category function))))
    (aset value 0 (1+ (aref value 0)))
    (aset value 1 (+ (aref value 1) elapsed))
    (aset value 2 (+ (aref value 2) (max 0.0 exclusive)))))

(defun ebox-performance-evaluator--around
    (category function original &rest arguments)
  "Measure ORIGINAL under CATEGORY and FUNCTION while preserving its result."
  (if (not ebox-performance-evaluator--active)
      (apply original arguments)
    (let ((frame (list category function (float-time) 0.0)))
      (push frame ebox-performance-evaluator--stack)
      (unwind-protect
          (apply original arguments)
        (let* ((elapsed (- (float-time) (nth 2 frame)))
               (exclusive (- elapsed (nth 3 frame))))
          (setq ebox-performance-evaluator--stack
                (cdr ebox-performance-evaluator--stack))
          (when ebox-performance-evaluator--stack
            (setf (nth 3 (car ebox-performance-evaluator--stack))
                  (+ (nth 3 (car ebox-performance-evaluator--stack))
                     elapsed)))
          (ebox-performance-evaluator--record
           category function elapsed exclusive))))))

(defun ebox-performance-evaluator--install-advice ()
  "Install timing advice and return the installed advice descriptors."
  (let (installed)
    (dolist (spec ebox-performance-evaluator--stage-specs)
      (let ((category (car spec)))
        (dolist (function (cdr spec))
          (when (fboundp function)
            (let ((advice
                   (lambda (original &rest arguments)
                     (apply #'ebox-performance-evaluator--around
                            category function original arguments))))
              (advice-add function :around advice)
              (push (list function advice) installed))))))
    installed))

(defun ebox-performance-evaluator--remove-advice (installed)
  "Remove timing advice descriptors in INSTALLED."
  (dolist (entry installed)
    (advice-remove (nth 0 entry) (nth 1 entry))))

(defun ebox-performance-evaluator--category-report (metrics)
  "Return category and function timing reports from METRICS."
  (let ((categories (make-hash-table :test #'eq)) functions)
    (maphash
     (lambda (key value)
       (let* ((category (car key))
              (function (cadr key))
              (category-value
               (or (gethash category categories)
                   (let ((new (vector 0 0.0 0.0)))
                     (puthash category new categories)
                     new))))
         (dotimes (index 3)
           (aset category-value index
                 (+ (aref category-value index) (aref value index))))
         (push (list :category category :function function
                     :count (aref value 0)
                     :inclusive (aref value 1)
                     :exclusive (aref value 2))
               functions)))
     metrics)
    (list
     :categories
     (sort
      (let (result)
        (maphash
         (lambda (category value)
           (push (list :category category :count (aref value 0)
                       :inclusive (aref value 1)
                       :exclusive (aref value 2))
                 result))
         categories)
        result)
      (lambda (left right)
        (string< (symbol-name (plist-get left :category))
                 (symbol-name (plist-get right :category)))))
     :functions
     (sort functions
           (lambda (left right)
             (if (eq (plist-get left :category)
                     (plist-get right :category))
                 (> (plist-get left :exclusive)
                    (plist-get right :exclusive))
               (string< (symbol-name (plist-get left :category))
                        (symbol-name (plist-get right :category)))))))))

(defun ebox-performance-evaluator--measure (thunk)
  "Run THUNK with stage advice and return its value and timing report."
  (let ((installed (ebox-performance-evaluator--install-advice)))
    (unwind-protect
        (let ((ebox-performance-evaluator--active t)
              (ebox-performance-evaluator--stack nil)
              (ebox-performance-evaluator--metrics
               (make-hash-table :test #'equal))
              (start (float-time)))
          (let ((value (funcall thunk)))
            (list :value value
                  :elapsed (- (float-time) start)
                  :timings
                  (ebox-performance-evaluator--category-report
                   ebox-performance-evaluator--metrics))))
      (ebox-performance-evaluator--remove-advice installed))))

(defun ebox-performance-evaluator--assert (condition format-string &rest args)
  "Signal an evaluator failure unless CONDITION is non-nil."
  (unless condition
    (error "Ebox performance evaluator: %s"
           (apply #'format format-string args))))

(defun ebox-performance-evaluator--check (name condition detail)
  "Return a named check with NAME, CONDITION, and DETAIL."
  (list :name name :ok (and condition t) :detail detail))

(defun ebox-performance-evaluator--assert-timings (measurement)
  "Return a non-overlap check for MEASUREMENT's inclusive/exclusive timings."
  (let* ((timings (plist-get measurement :timings))
         (categories (plist-get timings :categories))
         (exclusive-total
          (apply #'+ (mapcar (lambda (entry) (plist-get entry :exclusive))
                             categories)))
         (elapsed (plist-get measurement :elapsed)))
    (ebox-performance-evaluator--check
     "stage timings are non-overlapping"
         (and (cl-every
           (lambda (entry)
             (>= (+ (plist-get entry :inclusive) 0.000001)
                 (plist-get entry :exclusive)))
           categories)
          (<= exclusive-total (+ elapsed 0.01)))
     (format "elapsed=%.6fs exclusive-total=%.6fs"
             elapsed exclusive-total))))

(defun ebox-performance-evaluator--buffer-string (buffer)
  "Return BUFFER's complete propertized contents."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (buffer-substring (point-min) (point-max)))))

(defun ebox-performance-evaluator--runtime-output (buffer)
  "Return a fresh propertized render of BUFFER's current runtime root."
  (let* ((state (ebox--buffer-render-state buffer))
         (ebox--scroll-global-state (make-hash-table :test #'equal))
         (ebox--region-box-table (make-hash-table :test #'equal)))
    (ebox--with-buffer-render-context buffer
      (ebox--render-node
       (ebox--buffer-root-node buffer) (plist-get state :source-index)))))

(defun ebox-performance-evaluator--surface-producer (input)
  "Return a one-shot TP producer for canonical INPUT."
  (ebox-surface-producer
   (ebox-canonical-input--single-root input "Ebox performance evaluator")
   nil t
   (list :source-base-index (ebox-canonical-input--source-index input))))

(defun ebox-performance-evaluator--static-fixture
    (&optional styled target-content)
  "Return a deterministic fixture, optionally STYLED and with TARGET-CONTENT."
  (let (rows)
    (dotimes (row 5)
      (let (cells)
        (dotimes (column 4)
          (push
           (append
            (list 'box
                  :key (format "cell-%d-%d" row column)
                  :width '(52)
                  :padding '(0 1)
                  :color "#0F172A"
                  :bgcolor "#F8FAFC")
            (when (and (= row 2) (= column 1)) '(:id target))
            (when styled '(:class card))
            (list (if (and target-content (= row 2) (= column 1))
                      target-content
                    (format "row-%d cell-%d\ndetail-%d-%d"
                            row column row column))))
           cells))
        (push (cons 'row (nreverse cells)) rows)))
    (ebox-build (cons 'column (nreverse rows)))))

(defun ebox-performance-evaluator--resize-fixture ()
  "Return a viewport-dependent wrapped flex fixture."
  (let (items)
    (dotimes (index 12)
      (push
       (list 'box
             :key (format "resize-item-%d" index)
             :width '(70)
             :padding '(0 1)
             :color "#172554"
             :bgcolor "#DBEAFE"
             (format "resize-%02d" index))
       items))
    (ebox-build
     (append (list 'flex
                   :key 'resize-root
                   :width '(viewport)
                   :flex-wrap 'wrap
                   :column-gap '(6)
                   :row-gap 1)
             (nreverse items)))))

(defun ebox-performance-evaluator--pure-static ()
  "Measure isolated static materialization against a TP-backed reference."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create))
        (ebox-viewport-width 240)
        (ebox-viewport-height 12))
    (ebox-performance-evaluator--reset-runtime-state)
    (let ((expected
           (tp-surface-materialize-string
            (ebox-performance-evaluator--surface-producer
             (ebox-performance-evaluator--static-fixture)))))
      (ebox-performance-evaluator--reset-runtime-state)
      (let* ((measurement
              (ebox-performance-evaluator--measure
               (lambda ()
                 (ebox-render
                  (ebox-performance-evaluator--static-fixture)))))
             (actual (plist-get measurement :value))
             (checks
              (list
               (ebox-performance-evaluator--check
                "isolated output matches TP-backed reference"
                (equal-including-properties actual expected)
                (format "characters=%d" (length actual)))
               (ebox-performance-evaluator--assert-timings measurement))))
        (ebox-performance-evaluator--assert
         (cl-every (lambda (check) (plist-get check :ok)) checks)
         "pure static scenario failed: %S" checks)
        (list :name 'pure-static :measurement measurement
              :checks checks :tp-report nil)))))

(defun ebox-performance-evaluator--stylesheet-pure ()
  "Measure pure projection with an active ECSS stylesheet."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create))
        (ebox-viewport-width 240)
        (ebox-viewport-height 12))
    (ebox-style-add-rule
     ".card" '(:color "#F8FAFC" :bgcolor "#1E293B") :layer 'components)
    (ebox-performance-evaluator--reset-runtime-state)
    (let ((ebox-performance-evaluator--active nil)
          (expected
           (tp-surface-materialize-string
            (ebox-performance-evaluator--surface-producer
             (ebox-performance-evaluator--static-fixture t)))))
      (ebox-performance-evaluator--reset-runtime-state)
      (let* ((measurement
              (ebox-performance-evaluator--measure
               (lambda ()
                 (ebox-render
                  (ebox-performance-evaluator--static-fixture t)))))
             (actual (plist-get measurement :value))
             (style-count
              (cl-loop for entry in (plist-get (plist-get measurement :timings)
                                               :functions)
                       when (and (eq (plist-get entry :category)
                                     'style-cascade)
                                 (eq (plist-get entry :function)
                                     'ecss-compute-style))
                       sum (plist-get entry :count)))
             (checks
              (list
               (ebox-performance-evaluator--check
                "stylesheet output matches a second TP materialization"
                (equal-including-properties actual expected)
                (format "characters=%d" (length actual)))
               (ebox-performance-evaluator--check
                "stylesheet cascade was exercised"
                (> style-count 0)
                (format "ecss-compute-style calls=%d" style-count))
               (ebox-performance-evaluator--assert-timings measurement))))
        (ebox-performance-evaluator--assert
         (cl-every (lambda (check) (plist-get check :ok)) checks)
         "stylesheet pure scenario failed: %S" checks)
        (list :name 'stylesheet-pure :measurement measurement
              :checks checks :tp-report nil)))))

(defun ebox-performance-evaluator--mounted-update ()
  "Measure one scoped mounted content commit and validate its output."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create))
        (ebox-viewport-width 240)
        (ebox-viewport-height 12)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil)
        (buffer (generate-new-buffer " *ebox-performance-update*")))
    (unwind-protect
        (progn
          (ebox-performance-evaluator--reset-runtime-state)
          (ebox-render-to-buffer
           buffer (ebox-performance-evaluator--static-fixture))
          (let* ((handle (ebox-region-resolve buffer "target"))
                 (before-object
                  (ebox-selector--region-handle-object handle))
                 (measurement
                  (ebox-performance-evaluator--measure
                   (lambda ()
                     (ebox-commit
                      buffer
                      (ebox-performance-evaluator--static-fixture
                       nil "UPDATED\ndetail")))))
                 (report (ebox-buffer-update-report buffer))
                 (surface (plist-get (ebox--buffer-render-state buffer)
                                     :surface))
                 (after-handle (ebox-region-resolve buffer "target"))
                 (after-object
                  (ebox-selector--region-handle-object after-handle))
                 (expected (ebox-performance-evaluator--runtime-output buffer))
                 (actual (ebox-performance-evaluator--buffer-string buffer))
                 (tp-report (tp-surface-report surface))
                 (checks
                  (list
                   (ebox-performance-evaluator--check
                    "mounted output matches runtime render"
                    (equal-including-properties actual expected)
                    (format "characters=%d" (length actual)))
                   (ebox-performance-evaluator--check
                    "target mounted identity is retained"
                    (eq before-object after-object)
                    (format "same-object=%S" (eq before-object after-object)))
                   (ebox-performance-evaluator--check
                    "publication is scoped"
                    (and (not (plist-get tp-report :full-root))
                         (> (or (plist-get tp-report :scope-count) 0) 0))
                    (format "full-root=%S scope-count=%S"
                            (plist-get tp-report :full-root)
                            (plist-get tp-report :scope-count)))
                   (ebox-performance-evaluator--check
                    "update report confirms runtime publication"
                    (plist-get report :runtime-published)
                    (format "strategy=%S" (plist-get report :strategy)))
                   (ebox-performance-evaluator--assert-timings measurement))))
            (ebox-performance-evaluator--assert
             (cl-every (lambda (check) (plist-get check :ok)) checks)
             "mounted update scenario failed: %S" checks)
            (list :name 'mounted-content-update :measurement measurement
                  :checks checks :tp-report tp-report)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ebox-performance-evaluator--viewport-resize ()
  "Measure one viewport resize and validate its runtime output."
  (let ((ebox-style-stylesheet (ecss-stylesheet-create))
        (ebox-viewport-width 180)
        (ebox-viewport-height 6)
        (ebox-runtime-idle-prewarm nil)
        (ebox-runtime-idle-reflow-cache-prewarm nil)
        (buffer (generate-new-buffer " *ebox-performance-resize*")))
    (unwind-protect
        (progn
          (ebox-performance-evaluator--reset-runtime-state)
          (ebox-render-to-buffer
           buffer (ebox-performance-evaluator--resize-fixture))
          (let* ((old-state (ebox--buffer-render-state buffer))
                 (old-root-object
                  (plist-get (plist-get old-state :root-node) :surface-object))
                 (measurement
                  (ebox-performance-evaluator--measure
                   (lambda ()
                     (ebox-rerender-buffer-with-context buffer 320 6))))
                 (report (ebox-buffer-update-report buffer))
                 (surface (plist-get (ebox--buffer-render-state buffer)
                                     :surface))
                 (expected (ebox-performance-evaluator--runtime-output buffer))
                 (actual (ebox-performance-evaluator--buffer-string buffer))
                 (tp-report (tp-surface-report surface))
                 (new-root-object
                  (plist-get (plist-get (ebox--buffer-render-state buffer)
                                        :root-node)
                             :surface-object))
                 (checks
                  (list
                   (ebox-performance-evaluator--check
                    "resized output matches runtime render"
                    (equal-including-properties actual expected)
                    (format "characters=%d" (length actual)))
                   (ebox-performance-evaluator--check
                    "root mounted identity is retained"
                    (eq old-root-object new-root-object)
                    (format "same-root-object=%S"
                            (eq old-root-object new-root-object)))
                   (ebox-performance-evaluator--check
                    "viewport update publishes through TP"
                    (and (plist-get report :runtime-published)
                         (tp-surface-live-p surface))
                    (format "strategy=%S" (plist-get report :strategy)))
                   (ebox-performance-evaluator--assert-timings measurement))))
            (ebox-performance-evaluator--assert
             (cl-every (lambda (check) (plist-get check :ok)) checks)
             "viewport resize scenario failed: %S" checks)
            (list :name 'viewport-resize :measurement measurement
                  :checks checks :tp-report tp-report)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ebox-performance-evaluator--print-report (report)
  "Print REPORT in a stable human-readable form."
  (let* ((measurement (plist-get report :measurement))
         (timings (plist-get measurement :timings)))
    (princ (format "SCENARIO %s elapsed=%.6fs\n"
                   (plist-get report :name)
                   (plist-get measurement :elapsed)))
    (dolist (category (plist-get timings :categories))
      (princ
       (format "STAGE %s count=%d inclusive=%.6fs exclusive=%.6fs\n"
               (plist-get category :category)
               (plist-get category :count)
               (plist-get category :inclusive)
               (plist-get category :exclusive))))
    (dolist (function (plist-get timings :functions))
      (when (memq (plist-get function :category)
                  '(candidate-preparation node-projection))
        (princ
         (format "DETAIL %s/%s count=%d inclusive=%.6fs exclusive=%.6fs\n"
                 (plist-get function :category)
                 (plist-get function :function)
                 (plist-get function :count)
                 (plist-get function :inclusive)
                 (plist-get function :exclusive)))))
    (dolist (check (plist-get report :checks))
      (princ (format "%s %s -- %s\n"
                     (if (plist-get check :ok) "PASS" "FAIL")
                     (plist-get check :name)
                     (plist-get check :detail))))
    (when-let* ((tp-report (plist-get report :tp-report)))
      (princ (format "TP-REPORT %S\n" tp-report)))
    (princ "\n")))

(defun ebox-performance-evaluator--all-passed-p (reports)
  "Return non-nil when every check in REPORTS passed."
  (cl-every
   (lambda (report)
     (cl-every (lambda (check) (plist-get check :ok))
               (plist-get report :checks)))
   reports))

;;;###autoload
(defun ebox-performance-evaluator-layout-boundary-report ()
  "Run the pure layout/materialization scenarios used by the M2a E2 gate."
  (let ((reports (list (ebox-performance-evaluator--pure-static)
                       (ebox-performance-evaluator--stylesheet-pure))))
    (dolist (report reports)
      (ebox-performance-evaluator--print-report report))
    (ebox-performance-evaluator--assert
     (ebox-performance-evaluator--all-passed-p reports)
     "layout boundary scenarios failed")
    (princ "LAYOUT-BOUNDARY-PERFORMANCE PASS\n")
    reports))

;;;###autoload
(defun ebox-performance-evaluator-layout-boundary-batch ()
  "Run the M2a E2 performance gate as a batch command."
  (condition-case error-data
      (progn
        (ebox-performance-evaluator-layout-boundary-report)
        (kill-emacs 0))
    (error
     (princ (format "LAYOUT-BOUNDARY-PERFORMANCE FAIL: %S\n" error-data))
     (kill-emacs 1))))

;;;###autoload
(defun ebox-performance-evaluator-report ()
  "Run all declared Ebox performance scenarios and print their reports."
  (let ((reports (list (ebox-performance-evaluator--pure-static)
                       (ebox-performance-evaluator--stylesheet-pure)
                       (ebox-performance-evaluator--mounted-update)
                       (ebox-performance-evaluator--viewport-resize))))
    (dolist (report reports)
      (ebox-performance-evaluator--print-report report))
    (ebox-performance-evaluator--assert
     (ebox-performance-evaluator--all-passed-p reports)
     "one or more scenarios failed")
    (princ "PERFORMANCE-EVALUATOR PASS\n")
    reports))

;;;###autoload
(defun ebox-performance-evaluator-batch ()
  "Run the performance evaluator as a batch command with an exit status."
  (condition-case error-data
      (progn
        (ebox-performance-evaluator-report)
        (kill-emacs 0))
    (error
     (princ (format "PERFORMANCE-EVALUATOR FAIL: %S\n" error-data))
     (kill-emacs 1))))

(provide 'ebox-performance-evaluator)

;;; ebox-performance-evaluator.el ends here
