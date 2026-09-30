;;; benchmark-retained-region.el --- Retained region scaling -*- lexical-binding: t; -*-

;;; Commentary:
;; Public region updates beside an unchanged list, flex meter and clock.
;; `ebox-retained-region-benchmark' measures update-through-publication only;
;; fresh-render and report checks run outside each sample.  The optional ratio
;; limit pins size independence independently of the absolute latency budget.

;;; Code:
(require 'cl-lib)
(require 'ebox)

(defun ebox-retained-region--input (rows clock width)
  "Build ROWS list entries followed by a meter at WIDTH and CLOCK text."
  (ebox-build
   `(flex :flex-direction column :width (vw 100) :height (vh 100)
          :color "#E9ECF1" :bgcolor "#0E1013"
          ,@(cl-loop for i from 1 to rows
                     collect `(flex :width stretch :height (lh 1)
                                    (text ,(format " %2d  一首名字相当长的歌曲标题 xx   某位歌手   某个专辑   VIP   4:0%d"
                                                   i (mod i 9)))))
          (flex :width stretch :height (lh 1) :align-items center
                (box :height (% 35) :width (% ,width) :flex-shrink 0
                     :min-width (px 1) :id meter :bgcolor "#EC4141")
                (box :height (% 35) :flex-grow 1 :flex-basis (px 0)
                     :min-width (px 0) :bgcolor "#232832"))
          (box :height (lh 1) :id clock (text ,clock)))))

(defun ebox-retained-region--pixels (text)
  "Return TEXT's visible characters, geometry and public paint properties."
  (list (substring-no-properties text)
        (vconcat
         (cl-loop for i below (length text)
                  collect (mapcar (lambda (property)
                                    (get-text-property i property text))
                                  '(display face font-lock-face keymap help-echo
                                    mouse-face pointer))))))

(defun ebox-retained-region-fixture (rows effect _mode)
  "Mount ROWS unchanged entries and return a public EFFECT workload."
  (let ((buffer (generate-new-buffer " *Ebox retained region*"))
        (ebox-viewport-width 1422)
        (ebox-viewport-height (+ rows 3))
        expected active handle report)
    (condition-case problem
        (progn
          (setq expected
                (vconcat
                 (mapcar
                  (lambda (value)
                    (ebox-retained-region--pixels
                     (ebox-render
                      (ebox-retained-region--input
                       rows (if (and value (eq effect 'content)) "9:59" "0:00")
                       (if (and value (eq effect 'geometry)) 31 30)))))
                  '(nil t))))
          (ebox-render-to-buffer buffer (ebox-retained-region--input rows "0:00" 30))
          (setq handle (ebox-region-resolve buffer (if (eq effect 'content) 'clock 'meter))))
      (error (kill-buffer buffer) (signal (car problem) (cdr problem))))
    (list
     :buffer buffer
     :invoke (lambda (_sample)
               (setq active (not active)
                     report
                     (if (eq effect 'content)
                         (ebox-region-update handle :content (if active "9:59" "0:00"))
                       (ebox-region-update-geometry handle :width (list '% (if active 31 30))))))
     :verify (lambda ()
               (cond
                ((not (equal (aref expected (if active 1 0))
                             (ebox-retained-region--pixels
                              (with-current-buffer buffer (buffer-string)))))
                 "Retained output differs from fresh rendering")
                ((not (and (= (plist-get report :dirty-count) 1)
                           (= (plist-get report :patch-count) 1)))
                 "One region update must report one dirty entry and one patch")
                (t t)))
     :report (lambda ()
               (cl-loop for key in '(:strategy :projection-kind :dirty-count :patch-count)
                        append (list key (plist-get report key))))
     :observe (lambda (sink)
                (ebox-buffer-set-observer buffer sink)
                (lambda () (ebox-buffer-set-observer buffer nil)))
     :cleanup (lambda ()
                (when (buffer-live-p buffer)
                  (when (ebox-surface-buffer-mounted-p buffer)
                    (ebox-unmount-buffer buffer))
                  (kill-buffer buffer))))))

(defun ebox-retained-region-benchmark (&optional samples ratio-limit)
  "Measure SAMPLES updates at 8/30/60 rows and check optional RATIO-LIMIT.
The median at 60 rows divided by the median at 8 rows must not exceed the
limit.  Three warmups precede each case; every update verifies fresh output."
  (let ((samples (or samples 20)) results)
    (dolist (effect '(content geometry))
      (let (medians)
        (dolist (rows '(8 30 60))
          (let ((fixture (ebox-retained-region-fixture rows effect 'batch)) elapsed)
            (unwind-protect
                (progn
                  (dotimes (i (+ samples 3))
                    (let ((start (float-time)))
                      (funcall (plist-get fixture :invoke) i)
                      (when (>= i 3) (push (* 1000 (- (float-time) start)) elapsed)))
                    (let ((verified (funcall (plist-get fixture :verify))))
                      (unless (eq verified t) (error "%s" verified))))
                  (let* ((ordered (sort (copy-sequence elapsed) #'<))
                         (median (nth (/ samples 2) ordered))
                         (result (list :effect effect :rows rows
                                       :mean-ms (/ (apply #'+ elapsed) samples)
                                       :p50-ms median
                                       :p95-ms (nth (min (1- samples) (floor (* samples 0.95))) ordered)
                                       :samples-ms (vconcat (nreverse elapsed))
                                       :report (funcall (plist-get fixture :report)))))
                    (push median medians)
                    (push result results)
                    (prin1 result) (terpri)))
              (funcall (plist-get fixture :cleanup)))))
        (let ((ratio (/ (car medians) (car (last medians)))))
          (princ (format "%s 60/8 median ratio: %.3f\n" effect ratio))
          (when (and ratio-limit (> ratio ratio-limit))
            (error "%s scaling ratio %.3f exceeds %.3f" effect ratio ratio-limit)))))
    (nreverse results)))

(provide 'benchmark-retained-region)
;;; benchmark-retained-region.el ends here
