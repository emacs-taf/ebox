;;; performance-scenarios.el --- Independent Ebox interaction workloads -*- lexical-binding: t; -*-

;;; Commentary:
;; Register standalone provider workloads with the shared performance driver.
;; Every operation and verification uses the Ebox public API.

;;; Code:
(require 'cl-lib)
(require 'ebox)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun ebox-benchmark--environment ()
  "Report the active public renderer capability and configured GC policy."
  (let ((native (ebox-native-reflow-runtime-report)))
    (list :native_available (if (plist-get native :available-p) t :false)
          :native_layout (if (plist-get native :layout-ready-p) t :false)
          :native_hash (plist-get native :loaded-module-hash)
          :native_path (plist-get native :loaded-module-path)
          :render_gc_threshold ebox-render-gc-cons-threshold
          :render_gc_percentage ebox-render-gc-cons-percentage)))

(defun ebox-benchmark--focus-fixture (size paint _mode)
  "Create SIZE unchanged siblings around two controls with optional PAINT."
  (let ((buffer (generate-new-buffer " *TAF Ebox states*")) targets expected)
    (with-current-buffer buffer
      (ebox-render-to-buffer
       buffer
       (ebox-build
        `(column :width (ch 50) :color "#334155"
                 :ecss (("#a:focus" :color ,(if paint "#cc3344" "#334155"))
                        ("#b:focus" :color ,(if paint "#cc3344" "#334155")))
          (box :id a :key a :tab-index 0 "Alpha")
          (box :id b :key b :tab-index 1 "Bravo")
          ,@(cl-loop for index below size collect `(text ,(format "Unchanged row %04d" index))))))
      ;; This is an explicitly steady-state workload. Target discovery is setup.
      (setq targets (list (ebox-focus-first) (ebox-focus-next))))
    (list
     :buffer buffer :environment #'ebox-benchmark--environment
     :invoke (lambda (sample)
               (setq expected (nth (% sample 2) targets))
               (ebox-focus expected buffer))
     :verify
     (lambda ()
       (with-current-buffer buffer
         (cond
          ((not (equal expected (ebox-focused-host-ref buffer))) "Published focus differs from the requested target")
          ((/= 1 (length (ebox-selector-query-buffer buffer ":focus"))) "Selector view must contain exactly one focused target")
          ((not (and (string-match-p "Alpha" (buffer-string)) (string-match-p "Bravo" (buffer-string))))
           "An unchanged control label disappeared")
          (t
           (let* ((word (if (equal expected (car targets)) "Alpha" "Bravo"))
                  (position (+ (point-min) (string-match word (buffer-string))))
                  (color (plist-get (get-text-property position 'face) :foreground))
                  (wanted (if paint "#cc3344" "#334155")))
             (if (equal color wanted) t
               (format "Focused foreground is %s; expected %s" color wanted)))))))
     :observe (lambda (sink)
                (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup (lambda ()
                (when (buffer-live-p buffer)
                  (when (ebox-surface-buffer-mounted-p buffer) (ebox-unmount-buffer buffer))
                  (kill-buffer buffer))))))

(defun ebox-benchmark--located-update-input (size value)
  "Build SIZE fixed-width selector targets containing VALUE."
  (ebox-build
   `(column :width (ch 48)
            ,@(cl-loop for index below size
                       collect `(box :key ,index :class located
                                     :width (ch 48) ,value))
            (box :width (ch 48) "Untouched"))))

(defun ebox-benchmark--located-update-fixture (size _mode)
  "Prepare a selector-driven SIZE-member update workload."
  (let* ((buffer (generate-new-buffer " *TAF Ebox locate*"))
         (inputs (list (ebox-benchmark--located-update-input size "Before")
                       (ebox-benchmark--located-update-input size "After!")))
         (expected (mapcar (lambda (input)
                             (substring-no-properties (ebox-render input)))
                           inputs))
         current)
    (with-current-buffer buffer
      (let ((ebox-viewport-width 60) (ebox-viewport-height 12))
        (ebox-render-to-buffer buffer (car inputs))))
    (list
     :buffer buffer :environment #'ebox-benchmark--environment
     :invoke (lambda (sample)
               (setq current (if (= (% sample 2) 0) 1 0))
               (let ((summary
                      (ebox-selector-update-buffer
                       buffer ".located" :content
                       (if (= current 1) "After!" "Before"))))
                 (unless (= size (plist-get summary :updated))
                   (error "Selector updated %S of %d targets"
                          (plist-get summary :updated) size))))
     :verify (lambda ()
               (with-current-buffer buffer
                 (let ((report (ebox-buffer-update-report buffer)))
                   (cond
                    ((not (equal (nth current expected)
                                 (buffer-substring-no-properties
                                  (point-min) (point-max))))
                     "Located updates differ from a fresh render")
                    ((/= size (plist-get report :dirty-count))
                     "The accepted report omitted located dirty owners")
                    ((not (memq (plist-get report :projection-kind)
                                '(span-patch owner-scoped)))
                     "The update did not retain a scoped projection")
                    (t t)))))
     :observe (lambda (sink)
                (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup (lambda ()
                (when (buffer-live-p buffer)
                  (when (ebox-surface-buffer-mounted-p buffer)
                    (ebox-unmount-buffer buffer))
                  (kill-buffer buffer))))))

(dolist (size '(16 64))
  (let ((count size))
    (taf-benchmark-register
     (format "ebox.selector.locate-content.%s" count)
     :version 1 :modes '(batch) :isolation 'series :required-providers '(ebox)
     :impact 'local :budget-ms (if (<= count 16) 50 150)
     :description (format "Update %d selector-located Boxes in one scoped publication" count)
     :setup (lambda (mode) (ebox-benchmark--located-update-fixture count mode)))))

(dolist (size '(32 128 512))
  (dolist (paint '(nil t))
    (let ((count size) (paint-p paint))
      (taf-benchmark-register
       (format "ebox.focus.%s.%s" (if paint "paint" "metadata") size)
       :version 1 :modes '(batch gui) :isolation 'series
       :required-providers '(ebox)
       :impact (if paint 'local 'metadata) :budget-ms (if paint 50 10)
       :description (format "Steady focus with %d unchanged siblings; %s" size
                            (if paint "focus changes foreground" "computed paint stays equal"))
       :setup (lambda (mode) (ebox-benchmark--focus-fixture count paint-p mode))))))

;;; performance-scenarios.el ends here
