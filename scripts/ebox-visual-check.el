;;; ebox-visual-check.el --- Visual verification helper for ebox -*- lexical-binding: t; -*-

;; Usage:
;;   Batch/property report:
;;     emacs -Q -L . -l scripts/ebox-visual-check.el -f ebox-visual-check-batch
;;
;;   GUI inspection:
;;     emacs -Q -L . -l scripts/ebox-visual-check.el \
;;       --eval '(ebox-visual-check-run t)'

(require 'cl-lib)

(let ((root (file-name-directory
             (directory-file-name
              (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path root))

(require 'ebox)

(defconst ebox-visual-check-buffer "*ebox-visual-check*"
  "Buffer used for visual inspection.")

(defcustom ebox-visual-check-output-dir
  (expand-file-name "ebox-visual-check" temporary-file-directory)
  "Directory used for optional screenshots and reports."
  :type 'directory
  :group 'ebox)

(defun ebox-visual-check-layout ()
  "Return the fixed layout used by visual verification."
  (let* ((title (ebox-test-box
                 :content "Ebox Visual Check"
                 :box-sizing 'border-box
                 :width 74
                 :padding '(0 1)
                 :border t
                 :border-color "#4A90D9"
                 :color "#EAF6FF"
                 :bgcolor "#203040"))
         (hidden (ebox-test-box
                  :content "Hidden: visible line\nHIDDEN-CLIPPED-LINE"
                  :box-sizing 'border-box
                  :width 24
                  :height 3
                  :padding '(1 1)
                  :border t
                  :border-color "#27AE60"
                  :color "#F0FFF4"
                  :bgcolor "#17351F"
                  :overflow 'hidden))
         (scroll (ebox-test-box
                  :content "Scroll: first\nSCROLL-SECOND\nSCROLL-THIRD"
                  :box-sizing 'border-box
                  :width 24
                  :height 3
                  :padding '(1 1)
                  :border t
                  :border-color "#E67E22"
                  :color "#FFF4E6"
                  :bgcolor "#3A2410"
                  :overflow 'scroll))
         (sized (ebox-test-box
                 :content "border-box max-height\nline 2\nSIZED-CLIPPED"
                 :box-sizing 'border-box
                 :width 26
                 :max-height 3
                 :padding '(1 1)
                 :border t
                 :border-color "#9B59B6"
                 :color "#F8EEFF"
                 :bgcolor "#2F1B3A"
                 :overflow 'hidden))
         (footer (ebox-test-box
                  :content "Checks: text properties + display specs + GUI screenshot"
                  :box-sizing 'border-box
                  :width 74
                  :padding '(0 1)
                  :border t
                  :border-color "#7F8C8D"
                  :color "#F8F9F9"
                  :bgcolor "#2C3E50")))
    (ebox-test-column title (ebox-test-row hidden scroll sized) footer)))

(defun ebox-visual-check--max-line-pixel-width (string)
  "Return maximum pixel width among STRING lines."
  (apply #'max (mapcar #'string-pixel-width (ebox-string-lines string))))

(defun ebox-visual-check--some-property-p (string property)
  "Return non-nil when STRING has PROPERTY anywhere."
  (let ((pos 0)
        (len (length string))
        found)
    (while (and (< pos len) (not found))
      (when (get-text-property pos property string)
        (setq found t))
      (setq pos (or (next-single-property-change pos property string)
                    (1+ pos))))
    found))

(defun ebox-visual-check--face-has-key-p (face key)
  "Return non-nil when FACE contains plist KEY."
  (cond
   ((null face) nil)
   ((and (listp face) (keywordp (car face)))
    (plist-member face key))
   ((listp face)
    (cl-some (lambda (item)
               (ebox-visual-check--face-has-key-p item key))
             face))
   (t nil)))

(defun ebox-visual-check--some-face-key-p (string key)
  "Return non-nil when any face property in STRING contains KEY."
  (let ((pos 0)
        (len (length string))
        found)
    (while (and (< pos len) (not found))
      (when (ebox-visual-check--face-has-key-p
             (get-text-property pos 'face string)
             key)
        (setq found t))
      (setq pos (or (next-single-property-change pos 'face string)
                    (1+ pos))))
    found))

(defun ebox-visual-check--check (name ok detail)
  "Return a check plist with NAME, OK, and DETAIL."
  (list :name name :ok (and ok t) :detail detail))

(defun ebox-visual-check-report ()
  "Return visual verification report based on rendered text properties."
  (let* ((layout (ebox-visual-check-layout))
         (ids-before (ebox-region-ids layout))
         (rendered (ebox-render layout))
         (plain (substring-no-properties rendered))
         (ids-after (ebox-region-ids rendered))
         (metrics (list :height (ebox-string-height rendered)
                        :pixel-width
                        (ebox-visual-check--max-line-pixel-width rendered)
                        :region-count (length ids-before))))
    (list
     (list
      :name "dashboard-contract"
      :metrics metrics
      :checks
      (list
       (ebox-visual-check--check
        "region ids are stable"
        (equal ids-before ids-after)
        (format "before=%S after=%S" ids-before ids-after))
       (ebox-visual-check--check
        "all expected boxes rendered"
        (= (length ids-before) 5)
        (format "region-count=%d" (length ids-before)))
       (ebox-visual-check--check
        "display specs exist"
        (ebox-visual-check--some-property-p rendered 'display)
        "pixel spaces are represented with display properties")
       (ebox-visual-check--check
        "foreground faces exist"
        (ebox-visual-check--some-face-key-p rendered :foreground)
        "checks :color render path")
       (ebox-visual-check--check
        "background faces exist"
        (ebox-visual-check--some-face-key-p rendered :background)
        "checks :bgcolor render path")
       (ebox-visual-check--check
        "hidden overflow is clipped"
        (not (string-match-p "HIDDEN-CLIPPED-LINE" plain))
        "hidden box should not expose clipped line")
       (ebox-visual-check--check
        "scroll overflow keeps initial window"
        (and (string-match-p "Scroll: first" plain)
             (not (string-match-p "SCROLL-SECOND" plain)))
        "scroll box should show first window only")
       (ebox-visual-check--check
        "border-box max-height clips outer box"
        (not (string-match-p "SIZED-CLIPPED" plain))
        "max-height includes vertical padding"))))))

(defun ebox-visual-check--format-report (report)
  "Format REPORT as human-readable text."
  (mapconcat
   (lambda (scenario)
     (let ((name (plist-get scenario :name))
           (metrics (plist-get scenario :metrics))
           (checks (plist-get scenario :checks)))
       (concat
        (format "Scenario: %s\nMetrics: %S\n" name metrics)
        (mapconcat
         (lambda (check)
           (format "%s %s -- %s"
                   (if (plist-get check :ok) "PASS" "FAIL")
                   (plist-get check :name)
                   (plist-get check :detail)))
         checks
         "\n"))))
   report
   "\n\n"))

(defun ebox-visual-check-all-passed-p (report)
  "Return non-nil when every check in REPORT passed."
  (cl-every
   (lambda (scenario)
     (cl-every (lambda (check) (plist-get check :ok))
               (plist-get scenario :checks)))
   report))

(defun ebox-visual-check-render-buffer ()
  "Render the visual check layout into `ebox-visual-check-buffer'."
  (ebox-render-to-buffer ebox-visual-check-buffer
    (ebox-visual-check-layout)))

(defun ebox-visual-check-capture-screenshot ()
  "Capture a macOS screenshot for the current GUI Emacs frame.
Return the screenshot path, or nil when screenshot capture is unavailable."
  (when (and (display-graphic-p)
             (executable-find "screencapture"))
    (make-directory ebox-visual-check-output-dir t)
    (raise-frame)
    (select-frame-set-input-focus (selected-frame))
    (when (and (eq system-type 'darwin)
               (executable-find "osascript"))
      (call-process "osascript" nil nil nil
                    "-e" "tell application id \"org.gnu.Emacs\" to activate"))
    (let ((file (expand-file-name
                 (format-time-string "ebox-visual-check-%Y%m%d-%H%M%S.png")
                 ebox-visual-check-output-dir)))
      (redisplay t)
      (sit-for 1)
      (when (zerop (call-process "screencapture" nil nil nil "-x" file))
        file))))

(defun ebox-visual-check--tokenize-ppm (file)
  "Return PPM FILE tokens, ignoring comments."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (tokens)
      (while (not (eobp))
        (cond
         ((looking-at "[ \t\r\n]+")
          (goto-char (match-end 0)))
         ((looking-at "#.*$")
          (forward-line 1))
         ((looking-at "[^ \t\r\n#]+")
          (push (match-string 0) tokens)
          (goto-char (match-end 0)))
         (t
          (forward-char 1))))
      (nreverse tokens))))

(defun ebox-visual-check--read-ppm (file)
  "Read an ASCII P3 PPM FILE into a plist."
  (let* ((tokens (ebox-visual-check--tokenize-ppm file))
         (magic (pop tokens)))
    (unless (equal magic "P3")
      (error "Only ASCII P3 PPM files are supported directly: %s" file))
    (let* ((width (string-to-number (pop tokens)))
           (height (string-to-number (pop tokens)))
           (max-value (string-to-number (pop tokens)))
           pixels)
      (dotimes (_ (* width height))
        (let ((r (string-to-number (pop tokens)))
              (g (string-to-number (pop tokens)))
              (b (string-to-number (pop tokens))))
          (push (vector r g b) pixels)))
      (list :width width
            :height height
            :max-value max-value
            :pixels (vconcat (nreverse pixels))))))

(defun ebox-visual-check--maybe-convert-to-ppm (file)
  "Return FILE as a PPM path, converting image formats with sips when needed."
  (if (string-match-p "\\.ppm\\'" file)
      file
    (unless (executable-find "sips")
      (error "Cannot convert image without sips: %s" file))
    (let ((out (make-temp-file "ebox-visual-check-" nil ".ppm")))
      (unless (zerop (call-process "sips" nil nil nil
                                   "-s" "format" "ppm"
                                   file "--out" out))
        (error "Failed to convert image to PPM: %s" file))
      out)))

(defun ebox-visual-check--pixel-at (image x y)
  "Return IMAGE pixel at X,Y."
  (let ((width (plist-get image :width))
        (pixels (plist-get image :pixels)))
    (aref pixels (+ (* y width) x))))

(defun ebox-visual-check--pixel-delta (p1 p2)
  "Return the maximum RGB channel delta between P1 and P2."
  (max (abs (- (aref p1 0) (aref p2 0)))
       (abs (- (aref p1 1) (aref p2 1)))
       (abs (- (aref p1 2) (aref p2 2)))))

(defun ebox-visual-check-compare-region (expected actual region &optional tolerance)
  "Compare EXPECTED and ACTUAL images inside REGION.
REGION is a plist with :x, :y, :width, and :height.  TOLERANCE is the
allowed maximum per-channel RGB delta, defaulting to 0.

The direct parser supports ASCII P3 PPM.  Other image files are converted to
PPM with macOS `sips' when available."
  (let* ((tolerance (or tolerance 0))
         (expected-ppm (ebox-visual-check--maybe-convert-to-ppm expected))
         (actual-ppm (ebox-visual-check--maybe-convert-to-ppm actual))
         (expected-image (ebox-visual-check--read-ppm expected-ppm))
         (actual-image (ebox-visual-check--read-ppm actual-ppm))
         (x (plist-get region :x))
         (y (plist-get region :y))
         (width (plist-get region :width))
         (height (plist-get region :height))
         (samples 0)
         (mismatches 0)
         (max-delta 0))
    (unless (and (= (plist-get expected-image :width)
                    (plist-get actual-image :width))
                 (= (plist-get expected-image :height)
                    (plist-get actual-image :height)))
      (error "Image dimensions differ: %S vs %S"
             (list (plist-get expected-image :width)
                   (plist-get expected-image :height))
             (list (plist-get actual-image :width)
                   (plist-get actual-image :height))))
    (dotimes (dy height)
      (dotimes (dx width)
        (let* ((px (+ x dx))
               (py (+ y dy))
               (delta (ebox-visual-check--pixel-delta
                       (ebox-visual-check--pixel-at expected-image px py)
                       (ebox-visual-check--pixel-at actual-image px py))))
          (setq samples (1+ samples))
          (setq max-delta (max max-delta delta))
          (when (> delta tolerance)
            (setq mismatches (1+ mismatches))))))
    (list :ok (= mismatches 0)
          :samples samples
          :mismatches mismatches
          :max-delta max-delta
          :tolerance tolerance)))

(defun ebox-visual-check-run (&optional capture)
  "Render visual check buffer for GUI inspection.
With CAPTURE non-nil, also save a screenshot when possible."
  (interactive "P")
  (let* ((buffer (ebox-visual-check-render-buffer))
         (report (ebox-visual-check-report))
         (passed (ebox-visual-check-all-passed-p report))
         screenshot)
    (switch-to-buffer buffer)
    (delete-other-windows)
    (goto-char (point-min))
    (when capture
      (setq screenshot (ebox-visual-check-capture-screenshot)))
    (message "ebox visual check: %s%s"
             (if passed "PASS" "FAIL")
             (if screenshot
                 (format " screenshot=%s" screenshot)
               ""))
    (list :passed passed :screenshot screenshot :report report)))

(defun ebox-visual-check-batch ()
  "Run property-based visual checks and print a report."
  (interactive)
  (let* ((report (ebox-visual-check-report))
         (passed (ebox-visual-check-all-passed-p report)))
    (princ (ebox-visual-check--format-report report))
    (princ (format "\n\n%s\n" (if passed "ALL CHECKS PASSED"
                                "CHECKS FAILED")))
    (when noninteractive
      (kill-emacs (if passed 0 1)))))

(provide 'ebox-visual-check)

;;; ebox-visual-check.el ends here
