;;; benchmark-update-effects.el --- Public incremental effect matrix -*- lexical-binding: t; -*-

;;; Commentary:
;; Compare all combinations of content, paint, native interaction and geometry
;; through independent Ebox APIs.  This is a batch diagnostic, not GUI latency
;; certification.  Correctness is checked outside each timed candidate commit.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'ebox)

(defconst ebox-update-effects--evaluator-file
  (expand-file-name "benchmark-update-effects.el"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Source file identifying this evaluator.")

(defun ebox-update-effects--file-hash (file)
  "Return FILE's SHA256 digest."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun ebox-update-effects--native ()
  "Return the native backend's availability and loaded artifact identity."
  (let ((report (ebox-native-reflow-runtime-report)))
    (list :available (if (plist-get report :available-p) t :false)
          :layout_ready (if (plist-get report :layout-ready-p) t :false)
          :module_path (plist-get report :loaded-module-path)
          :module_sha256 (plist-get report :loaded-module-hash))))

(defun ebox-update-effects--integer (name default minimum maximum)
  "Read bounded integer environment NAME, falling back to DEFAULT."
  (let ((value (or (getenv name) (number-to-string default))))
    (unless (and (string-match-p "\\`[0-9]+\\'" value)
                 (<= minimum (string-to-number value) maximum))
      (error "%s must be an integer between %d and %d" name minimum maximum))
    (string-to-number value)))

(defun ebox-update-effects--effects (mask)
  "Return effects selected by four-bit MASK."
  (cl-loop for effect in '(content paint interaction geometry)
           for bit from 0 when (not (zerop (logand mask (ash 1 bit))))
           collect effect))

(defun ebox-update-effects--nodes (scoped effects active keymap)
  "Build changed node DSL forms for SCOPED EFFECTS, ACTIVE and KEYMAP."
  (let ((wide (and active (memq 'geometry effects)))
        (paint (and active (memq 'paint effects)))
        (enabled (and active (memq 'interaction effects))))
    (list
     `(box :id content :class ,(if wide '(value wide) '(value narrow))
           ,@(unless scoped (list :width (list 'ch (if wide 12 8))))
           ,(if (and active (memq 'content effects)) "After!" "Before"))
     `(box :id control :class ,(if paint '(control active) '(control inactive))
           :keymap ,keymap :disabled ,(not enabled)
           ,@(unless scoped (list :width '(ch 10) :color (if paint "#2255aa" "#777777")))
           "Control"))))

(defun ebox-update-effects--input (size scoped effects active keymap)
  "Build SIZE untouched siblings around SCOPED EFFECTS and ACTIVE controls."
  (ebox-build
   `(column :id root :width (ch 40)
            ,@(when scoped
                '(:ecss ((".value.narrow" :width (ch 8))
                         (".value.wide" :width (ch 12))
                         (".control" :width (ch 10))
                         (".control.inactive" :color "#777777")
                         (".control.active" :color "#2255aa"))))
            (row :width (ch 40)
                 ,@(ebox-update-effects--nodes scoped effects active keymap))
            ,@(cl-loop for index below size
                       collect `(box :width (ch 40) ,(format "Untouched %03d" index))))))

(defun ebox-update-effects--shape (text)
  "Return TEXT's visible characters and per-character display geometry."
  (list (substring-no-properties text)
        (vconcat (cl-loop for index below (length text)
                          collect (get-text-property index 'display text)))))

(defun ebox-update-effects--foreground (face)
  "Return the first explicit foreground in FACE."
  (cond ((and (consp face) (keywordp (car face))) (plist-get face :foreground))
        ((listp face) (cl-some #'ebox-update-effects--foreground face))
        ((and (symbolp face) (facep face))
         (let ((value (face-attribute face :foreground nil t)))
           (unless (memq value '(unspecified unspecified-fg)) value)))))

(defun ebox-update-effects--check-foreground (text effects active phase)
  "Validate TEXT's control color for EFFECTS and ACTIVE in PHASE."
  (let* ((position (string-match "Control" text))
         (foreground (and position
                          (ebox-update-effects--foreground
                           (get-text-property position 'face text))))
         (expected (if (and active (memq 'paint effects)) "#2255aa" "#777777")))
    (unless (equal foreground expected)
      (error "%s foreground: expected %s, got %S for %S"
             phase expected foreground effects))))

(defun ebox-update-effects--case (size scoped mask samples warmups)
  "Measure MASK at SIZE with SCOPED styles, SAMPLES and WARMUPS."
  (let* ((effects (ebox-update-effects--effects mask))
         (hits 0)
         (keymap (ebox-keymap-create :activate (lambda () (cl-incf hits))))
         (initial (ebox-update-effects--input size scoped effects nil keymap))
         (expected
          (vconcat
           (mapcar (lambda (state)
                     (let ((text (ebox-render
                                  (ebox-update-effects--input size scoped effects state keymap))))
                       (ebox-update-effects--check-foreground text effects state "Fresh render")
                       (ebox-update-effects--shape text)))
                   '(nil t))))
         (projection-counts (make-hash-table :test #'equal))
         active elapsed)
    (with-temp-buffer
      (ebox-render-to-buffer (current-buffer) initial)
      (ebox-update-effects--check-foreground (buffer-string) effects nil "Initial mount")
      (let ((ids (mapcar (lambda (selector)
                          (plist-get (car (ebox-selector-query-buffer (current-buffer) selector)) :node-id))
                        '("#content" "#control"))))
        (dotimes (index (+ samples warmups))
          (setq active (not active))
          (let ((start (float-time))
                (candidate (ebox-candidate-begin (current-buffer))))
            (cl-mapc (lambda (id node)
                       (ebox-candidate-replace candidate id (ebox-build node)))
                     ids (ebox-update-effects--nodes scoped effects active keymap))
            (ebox-commit (current-buffer) candidate)
            (when (>= index warmups)
              (push (* 1000.0 (- (float-time) start)) elapsed)))
          (unless (equal (aref expected (if active 1 0))
                         (ebox-update-effects--shape (buffer-string)))
            (error "Output differs from fresh rendering: %S active=%S" effects active))
          (let* ((position (1+ (string-match "Control" (buffer-string))))
                 (enabled (and active (memq 'interaction effects)))
                 (native-map (get-text-property position 'keymap))
                 (before hits))
            (ebox-update-effects--check-foreground (buffer-string) effects active "Incremental")
            (unless (if enabled
                        (and (keymapp native-map) (commandp (lookup-key native-map (kbd "RET"))))
                      (null native-map))
              (error "Incorrect native keymap: %S" effects))
            (if enabled
                (ebox-activate position)
              (condition-case nil
                  (progn (ebox-activate position)
                         (error "Disabled control accepted activation"))
                (user-error nil)))
            (unless (= hits (+ before (if enabled 1 0)))
              (error "Incorrect activation behavior: %S" effects)))
          (when (>= index warmups)
            (let ((kind (or (plist-get (ebox-buffer-update-report (current-buffer)) :projection-kind)
                            'ordinary)))
              (cl-incf (gethash (symbol-name kind) projection-counts 0)))))))
    (let ((ordered (sort (copy-sequence elapsed) #'<)))
      (list :untouched_nodes size :styles (if scoped "scoped" "inline")
            :effects (vconcat (mapcar #'symbol-name effects))
            :samples_ms (vconcat (nreverse elapsed))
            :p50_ms (nth (min (1- samples) (floor (* 0.5 samples))) ordered)
            :p95_ms (nth (min (1- samples) (floor (* 0.95 samples))) ordered)
            :max_ms (car (last ordered))
            :projection_counts projection-counts :correctness "passed"))))

(defun ebox-update-effects--source (feature)
  "Describe FEATURE's checked-out source revision and uncommitted changes."
  (let ((root (file-name-directory (locate-library (symbol-name feature)))))
    (cl-labels ((git (&rest args)
                  (with-temp-buffer
                    (if (zerop (apply #'process-file "git" nil t nil "-C" root args))
                        (buffer-string)
                      (error "Cannot identify source checkout: %s" feature)))))
      (list :package (symbol-name feature) :directory root
            :revision (string-trim (git "rev-parse" "HEAD"))
            :dirty (if (string-empty-p (git "status" "--porcelain")) :false t)
            :working_diff_sha256 (secure-hash 'sha256 (git "diff" "HEAD"))))))

(defun ebox-update-effects--write (output report)
  "Write complete REPORT atomically at OUTPUT."
  (let ((temporary (make-temp-file (expand-file-name ".update-effects-" (file-name-directory output)))))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (insert (json-serialize report :null-object nil :false-object :false) "\n"))
          (rename-file temporary output t)
          (setq temporary nil))
      (when temporary (delete-file temporary)))))

(defun ebox-update-effects-batch ()
  "Run the public update-effect matrix and write EBOX_UPDATE_EFFECTS_OUTPUT.
Sizes default to 20,100 untouched nodes, with 3 warmups and 10 samples per
case.  Fifteen effect combinations run with inline and scoped styles."
  (condition-case problem
      (let* ((sizes-text (or (getenv "EBOX_UPDATE_EFFECTS_SIZES") "20,100"))
             (samples (ebox-update-effects--integer "EBOX_UPDATE_EFFECTS_SAMPLES" 10 1 100))
             (warmups (ebox-update-effects--integer "EBOX_UPDATE_EFFECTS_WARMUPS" 3 0 100))
             (output (expand-file-name (or (getenv "EBOX_UPDATE_EFFECTS_OUTPUT")
                                          (make-temp-name (expand-file-name "ebox-update-effects-" temporary-file-directory)))))
             (lock (or (getenv "ETAF_PERF_LOCK_DIR")
                       (expand-file-name "etaf-performance-evaluator.lock" temporary-file-directory)))
             (report (list :schema 1 :workload "ebox-update-effects" :status "running"
                           :timing "batch-candidate-build-through-commit"
                           :emacs emacs-version :system system-configuration
                           :evaluator_sha256 (ebox-update-effects--file-hash
                                              ebox-update-effects--evaluator-file)
                           :samples samples :warmups warmups
                           :sources (vconcat (mapcar #'ebox-update-effects--source '(ebox ecss tp)))
                           :native (ebox-update-effects--native)
                           :cases [] :error nil))
             sizes cases acquired)
        (unless (string-match-p "\\`[0-9]+\\(?:,[0-9]+\\)*\\'" sizes-text)
          (error "EBOX_UPDATE_EFFECTS_SIZES must be comma-separated integers"))
        (setq sizes (mapcar #'string-to-number (split-string sizes-text ",")))
        (unless (and (<= (length sizes) 5) (cl-every (lambda (size) (<= 0 size 1000)) sizes))
          (error "Use at most five sizes between 0 and 1000"))
        (when (file-exists-p output) (error "Output already exists: %s" output))
        (unwind-protect
            (progn
              (condition-case nil (progn (make-directory lock) (setq acquired t))
                (file-already-exists (error "Performance host slot is occupied: %s" lock)))
              (with-temp-file (expand-file-name "pid" lock) (insert (number-to-string (emacs-pid))))
              (ebox-update-effects--write output report)
              (condition-case failure
                  (dolist (size sizes)
                    (dolist (scoped '(nil t))
                      (dotimes (index 15)
                        (let ((result
                               (condition-case case-error
                                   (ebox-update-effects--case size scoped (1+ index) samples warmups)
                                 (error
                                  (list :untouched_nodes size :styles (if scoped "scoped" "inline")
                                        :effects (vconcat (mapcar #'symbol-name
                                                                 (ebox-update-effects--effects (1+ index))))
                                        :correctness "failed" :error (error-message-string case-error))))))
                          (push result cases)
                          (princ (format "%4d %-6s %-35s %s\n"
                                         size (if scoped "scoped" "inline")
                                         (mapconcat #'identity (plist-get result :effects) "+")
                                         (if (plist-get result :error)
                                             (concat "FAILED " (plist-get result :error))
                                           (format "p95=%7.3f max=%7.3f ms"
                                                   (plist-get result :p95_ms) (plist-get result :max_ms)))))
                          (plist-put report :cases (vconcat (reverse cases)))
                          (plist-put report :native (ebox-update-effects--native))
                          (ebox-update-effects--write output report)))))
                (error (plist-put report :error (error-message-string failure))))
              (when (and (null (plist-get report :error))
                         (cl-some (lambda (result) (plist-get result :error)) cases))
                (plist-put report :error "One or more effect combinations failed correctness"))
              (plist-put report :status (if (plist-get report :error) "failed" "completed"))
              (ebox-update-effects--write output report)
              (princ (format "%s %s\n" (plist-get report :status) output))
              (when (plist-get report :error) (error "%s" (plist-get report :error))))
          (when acquired
            (delete-file (expand-file-name "pid" lock))
            (delete-directory lock))))
    (error (princ (format "ERROR %s\n" (error-message-string problem))) (kill-emacs 1))))

(provide 'benchmark-update-effects)
;;; benchmark-update-effects.el ends here
