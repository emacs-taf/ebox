;;; benchmark-image.el --- Image preparation and retained commit costs -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with make's normal batch load paths and -f ebox-image-benchmark-batch.
;; Real optional converters are measured; unavailable ones select placeholder.
;; Batch graphics uses simulated frame metrics and decoding, explicitly labeled
;; in the report.  Run preparation in a graphics frame for real decoding costs.

;;; Code:
(require 'cl-lib)
(require 'ebox)

(defconst ebox-image-benchmark--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun ebox-image-benchmark--source (file red)
  "Write a small deterministic PPM to FILE with RED as its red channel."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert "P6\n24 24\n255\n")
    (dotimes (y 24)
      (dotimes (x 24) (insert (unibyte-string red (* x 10) (* y 10)))))
    (let ((coding-system-for-write 'binary))
      (write-region (point-min) (point-max) file nil 'silent))))

(defun ebox-image-benchmark--median (function count)
  "Return median milliseconds for FUNCTION across COUNT calls."
  (garbage-collect)
  (let (samples)
    (dotimes (_ count)
      (let ((start (current-time)))
        (funcall function)
        (push (* 1000.0 (float-time (time-subtract (current-time) start))) samples)))
    (nth (/ count 2) (sort samples #'<))))

(defun ebox-image-benchmark--prepare (source adapter)
  "Prepare SOURCE with ADAPTER, simulating graphics only in batch mode."
  (if (and (eq adapter 'auto) (not (display-graphic-p)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _frame) t))
                ((symbol-function 'frame-char-width) (lambda (&optional _frame) 1))
                ((symbol-function 'frame-char-height) (lambda (&optional _frame) 1))
                ((symbol-function 'font-info)
                 (lambda (&rest _args) [nil nil 1 1 0 nil nil 1 1 0]))
                ((symbol-function 'image-type-available-p) (lambda (_type) t))
                ((symbol-function 'image-size)
                 (lambda (image &rest _args)
                   (cons (plist-get (cdr image) :width) (plist-get (cdr image) :height)))))
        (ebox-image-prepare source 24 12))
    (ebox-image-prepare source 24 12 :adapter adapter)))

(defun ebox-image-benchmark--input (prepared)
  "Create PREPARED above one unchanged lyric through the public content API."
  (let* ((builder (ebox-source-builder-create))
         (cover (ebox-image-create prepared builder :identity 'cover :id "cover"))
         (lyric (ebox-text-create
                 :value "The lyric stays here"
                 :source-handle (ebox-source-builder-bind builder :identity 'lyric)
                 :owned-facts (ebox-canonical-facts-from-declarations 'text nil)))
         (root (ebox-box-create
                :layout (ebox-column-layout-create)
                :source-handle (ebox-source-builder-bind builder :identity 'player)
                :owned-facts (ebox-canonical-facts-from-declarations 'column nil)
                :source-builder builder :children (list cover lyric))))
    (ebox-canonical-input-create (list root) (ebox-source-builder-finish builder))))

(defun ebox-image-benchmark-run (&optional count)
  "Return prepare/cache/content-copy/commit timings for 24 by 12 images.
Use COUNT samples per measurement (default 9).  Batch graphics measures the
Elisp descriptor/slice and publication costs, not native decoding or redisplay.
Placeholder source changes are visually identical and therefore commit no-ops."
  (let* ((count (or count 9))
         (directory (make-temp-file (expand-file-name "image-bench-"
                                                      ebox-image-benchmark--directory) t))
         (a (expand-file-name "a.ppm" directory))
         (b (expand-file-name "b.ppm" directory))
         (ebox-native-reflow-module-path nil)
         results)
    (unwind-protect
        (progn
          (ebox-image-benchmark--source a 240)
          (ebox-image-benchmark--source b 40)
          (dolist (adapter '(auto text placeholder))
            (let* ((prepare-ms
                    (ebox-image-benchmark--median
                     (lambda ()
                       (ebox-image-cache-clear)
                       (ebox-image-benchmark--prepare a adapter)) count))
                   (first (ebox-image-benchmark--prepare a adapter))
                   (second (ebox-image-benchmark--prepare b adapter))
                   (cache-ms (ebox-image-benchmark--median
                              (lambda () (ebox-image-benchmark--prepare a adapter)) count))
                   (copy-ms (ebox-image-benchmark--median
                             (lambda () (ebox-image-content first)) count))
                   (next second) commit-ms report)
              (with-temp-buffer
                (unwind-protect
                    (progn
                      (ebox-render-to-buffer (current-buffer) (ebox-image-benchmark--input first))
                      (setq commit-ms
                            (ebox-image-benchmark--median
                             (lambda ()
                               (ebox-region-update "cover" :content (ebox-image-content next))
                               (setq next (if (eq next first) second first))) count)
                            report (ebox-buffer-update-report (current-buffer))))
                  (when (ebox-surface-buffer-mounted-p (current-buffer))
                    (ebox-unmount-buffer (current-buffer)))))
              (push (append
                     (ebox-image-info first)
                     (list :graphics-simulated (and (eq adapter 'auto) (not (display-graphic-p)))
                           :prepare-ms prepare-ms :cache-ms cache-ms :content-copy-ms copy-ms
                           :commit-ms commit-ms :report
                           (cl-loop for key in '(:strategy :projection-kind :dirty-count
                                                 :patch-count :publication-scope-count
                                                 :publication-full-root :publication-text-operations
                                                 :publication-property-operations)
                                    append (list key (plist-get report key))))) results)))
          (nreverse results))
      (ebox-image-cache-clear)
      (delete-directory directory t))))

(defun ebox-image-benchmark-batch ()
  "Print reproducible 24 by 12 costs, with graphics simulation labeled."
  (dolist (result (ebox-image-benchmark-run)) (prin1 result) (terpri)))

(provide 'benchmark-image)
;;; benchmark-image.el ends here
