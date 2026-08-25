;;; ebox-buffer-backend.el --- Emacs buffer backend for Ebox -*- lexical-binding: t; -*-

;;; Commentary:
;; Builds propertized render strings and reshapes them for existing layout
;; slots.  Live buffer publication and retained markers belong to TP.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-measure)
(require 'tp-style)

(defvar ebox--propertize-private-content-line-p nil
  "Non-nil allows ownership to be added to fresh content lines in place.")
(declare-function ebox--maplines
                  "ebox" (function string))
(declare-function ebox--register-render-owned-text-value
                  "ebox-render-context" (property value))
(declare-function ebox--register-render-owned-face-values
                  "ebox-render-context" (source rendered))
(declare-function ebox--add-render-face!
                  "ebox-render-context" (string start end face &optional append))
(declare-function ebox--string-repeat-lines
                  "ebox" (string count))
(declare-function ebox-lines-join
                  "ebox" (lines))
(declare-function ebox-string-lines
                  "ebox" (string))
(defvar ebox-region-types)

(defvar ebox-render-gc-cons-threshold (* 128 1024 1024)
  "Temporary `gc-cons-threshold' used during Ebox render transactions.
Set this to nil to leave `gc-cons-threshold' unchanged.")

(defvar ebox-deferred-render-gc-cons-threshold 'auto
  "Temporary `gc-cons-threshold' used across interactive render bursts.
The default `auto' uses a bounded fraction of physical memory so visible frames
can favor throughput without assuming every machine has the same headroom.
Set this to a byte count for a fixed budget, or nil to leave the setting alone.")

(defvar ebox-deferred-render-gc-auto-min-threshold (* 128 1024 1024)
  "Minimum interactive render allocation budget selected by `auto'.")

(defvar ebox-deferred-render-gc-auto-max-threshold (* 512 1024 1024)
  "Maximum interactive render allocation budget selected by `auto'.")

(defvar ebox-deferred-render-gc-auto-memory-fraction (/ 1.0 32.0)
  "Fraction of physical memory available to an interactive render burst.")

(defvar ebox--physical-memory-bytes 'unknown
  "Cached physical memory size used by automatic render GC tuning.")

(defun ebox--darwin-physical-memory-bytes ()
  "Return macOS physical memory in bytes, or nil when unavailable."
  (when (eq system-type 'darwin)
    (when-let ((sysctl (executable-find "sysctl")))
      (with-temp-buffer
        (when (zerop (call-process sysctl nil t nil "-n" "hw.memsize"))
          (goto-char (point-min))
          (when (looking-at "[0-9]+")
            (string-to-number (match-string 0))))))))

(defun ebox--physical-memory-bytes ()
  "Return local physical memory in bytes, or nil when unavailable."
  (when (eq ebox--physical-memory-bytes 'unknown)
    (setq ebox--physical-memory-bytes
          (or (when-let ((info
                          (and (fboundp 'memory-info)
                               (let ((default-directory
                                      temporary-file-directory))
                                 (memory-info)))))
                (* 1024 (car info)))
              (ebox--darwin-physical-memory-bytes)
              'unavailable)))
  (unless (eq ebox--physical-memory-bytes 'unavailable)
    ebox--physical-memory-bytes))

(defun ebox--effective-deferred-render-gc-cons-threshold ()
  "Return the byte threshold for the current interactive render burst."
  (pcase ebox-deferred-render-gc-cons-threshold
    ('auto
     (let* ((minimum (max 1 ebox-deferred-render-gc-auto-min-threshold))
            (maximum
             (max minimum ebox-deferred-render-gc-auto-max-threshold))
            (physical-memory (ebox--physical-memory-bytes))
            (scaled
             (and physical-memory
                  (floor (* physical-memory
                            ebox-deferred-render-gc-auto-memory-fraction)))))
       (max minimum (min maximum (or scaled minimum)))))
    ((pred numberp) ebox-deferred-render-gc-cons-threshold)
    (_ nil)))

(defvar ebox-render-gc-cons-percentage 0.6
  "Temporary `gc-cons-percentage' used during Ebox render transactions.
Set this to nil to leave `gc-cons-percentage' unchanged.")

(defmacro ebox--with-render-gc (&rest body)
  "Evaluate BODY with GC tuned for one Ebox render transaction."
  (declare (indent 0) (debug t))
  `(let ((gc-cons-threshold
          (if (numberp ebox-render-gc-cons-threshold)
              (max gc-cons-threshold ebox-render-gc-cons-threshold)
            gc-cons-threshold))
         (gc-cons-percentage
          (if (numberp ebox-render-gc-cons-percentage)
              (max gc-cons-percentage ebox-render-gc-cons-percentage)
            gc-cons-percentage)))
     ,@body))

(defvar ebox--deferred-render-gc-state nil
  "Saved GC settings while an interactive render transaction is settling.")

(defvar ebox--deferred-render-gc-timer nil
  "Timer used to restore GC settings after interactive rendering settles.")

(defvar ebox--deferred-render-gc-depth 0
  "Number of overlapping interactive render bursts that still own GC defer.")

(defvar ebox--deferred-render-gc-generation 0
  "Generation used to reject callbacks from cancelled GC restore timers.")

(cl-defstruct (ebox--render-burst-record
               (:constructor ebox--make-render-burst-record))
  "Private saved state for one public framework render burst."
  mode
  saved-threshold
  saved-percentage)

(defvar ebox--render-burst-records (make-hash-table :test #'eq)
  "Private render-burst records keyed by opaque public tokens.")

(defvar ebox--render-burst-stack nil
  "Active public render-burst tokens, innermost first.")

(defun ebox--render-burst-create-record (mode threshold percentage)
  "Return private burst state for MODE, THRESHOLD, and PERCENTAGE."
  (ebox--make-render-burst-record
   :mode mode
   :saved-threshold threshold
   :saved-percentage percentage))

(defun ebox--make-deferred-render-gc-state (threshold percentage)
  "Return private deferred GC state for THRESHOLD and PERCENTAGE."
  (list :gc-cons-threshold threshold
        :gc-cons-percentage percentage))

(defun ebox--deferred-render-gc-restore ()
  "Restore GC settings saved by `ebox--with-deferred-render-gc'."
  (let ((state ebox--deferred-render-gc-state))
    (cl-incf ebox--deferred-render-gc-generation)
    (setq ebox--deferred-render-gc-state nil)
    (setq ebox--deferred-render-gc-timer nil)
    (setq ebox--deferred-render-gc-depth 0)
    (when state
      (setq gc-cons-threshold
            (plist-get state :gc-cons-threshold))
      (setq gc-cons-percentage
            (plist-get state :gc-cons-percentage))
      (garbage-collect))))

(defun ebox--deferred-render-gc-enter ()
  "Raise GC settings for an interactive render transaction."
  (let ((saved-threshold gc-cons-threshold)
        (saved-percentage gc-cons-percentage))
    ;; Cross a safe allocation boundary before automatic tuning or saved-state
    ;; construction can allocate.  The original scalar values above require no
    ;; heap record and remain authoritative for the eventual restore.
    (when (numberp ebox-render-gc-cons-threshold)
      (setq gc-cons-threshold
            (max gc-cons-threshold ebox-render-gc-cons-threshold)))
    (when (numberp ebox-render-gc-cons-percentage)
      (setq gc-cons-percentage
            (max gc-cons-percentage ebox-render-gc-cons-percentage)))
    (cl-incf ebox--deferred-render-gc-generation)
    (cl-incf ebox--deferred-render-gc-depth)
    (when-let ((threshold
                (ebox--effective-deferred-render-gc-cons-threshold)))
      (setq gc-cons-threshold threshold))
    (unless ebox--deferred-render-gc-state
      (setq ebox--deferred-render-gc-state
            (ebox--make-deferred-render-gc-state
             saved-threshold saved-percentage)))
    (when (timerp ebox--deferred-render-gc-timer)
      (cancel-timer ebox--deferred-render-gc-timer)
      (setq ebox--deferred-render-gc-timer nil))))

(defun ebox--deferred-render-gc-raise-threshold (threshold)
  "Raise an active interactive burst allocation budget to THRESHOLD."
  (when (and ebox--deferred-render-gc-state
             (numberp threshold))
    (setq gc-cons-threshold (max gc-cons-threshold threshold))))

(defun ebox--deferred-render-gc-set-threshold (threshold)
  "Set the active burst budget to THRESHOLD without lowering its saved value."
  (when (and ebox--deferred-render-gc-state
             (numberp threshold))
    (setq gc-cons-threshold
          (max (plist-get ebox--deferred-render-gc-state :gc-cons-threshold)
               threshold))))

(defun ebox--deferred-render-gc-schedule-restore ()
  "Restore deferred GC settings after a short settling delay."
  (when (> ebox--deferred-render-gc-depth 0)
    (cl-decf ebox--deferred-render-gc-depth))
  (when (and (zerop ebox--deferred-render-gc-depth)
             ebox--deferred-render-gc-state)
    (when (timerp ebox--deferred-render-gc-timer)
      (cancel-timer ebox--deferred-render-gc-timer))
    (let ((generation (cl-incf ebox--deferred-render-gc-generation)))
      (setq ebox--deferred-render-gc-timer
            (run-at-time
             0.2 nil #'ebox--deferred-render-gc-restore-if-current
             generation)))))

(defun ebox--deferred-render-gc-restore-if-current (generation)
  "Restore deferred GC state when GENERATION still owns the timer boundary."
  (when (and (= generation ebox--deferred-render-gc-generation)
             (zerop ebox--deferred-render-gc-depth)
             ebox--deferred-render-gc-state)
    (ebox--deferred-render-gc-restore)))

(defmacro ebox--with-deferred-render-gc (&rest body)
  "Evaluate BODY with render GC settings restored after idle redisplay.
This is for interactive UI commands where restoring the default GC threshold
immediately after BODY can trigger GC before the updated buffer is visible."
  (declare (indent 0) (debug t))
  `(progn
     (ebox--deferred-render-gc-enter)
     (unwind-protect
         (progn ,@body)
       (ebox--deferred-render-gc-schedule-restore))))

;;;###autoload
(defun ebox-render-burst-begin ()
  "Begin a framework render burst and return an opaque ownership token.

Frameworks may enter this boundary at the start of an input callback so
allocation performed before `ebox-commit' shares the same GC budget as Ebox
rendering and publication.  Interactive callers reuse Ebox's settling burst:
the outermost matching end restores settings after 0.2 seconds.  Batch callers
restore the exact settings captured by this call immediately, without running
GC at the boundary.

Pass the returned token to `ebox-render-burst-end'.  Bursts may be nested, but
must be ended in last-in, first-out order.  Prefer
`ebox-call-with-render-burst' when the complete operation is available as a
function, because it guarantees cleanup across errors and quits."
  (let ((saved-threshold gc-cons-threshold)
        (saved-percentage gc-cons-percentage)
        token
        completed)
    (if noninteractive
        ;; Do not allocate the opaque token, its private record, or a stack
        ;; cons until the old threshold can no longer collect at begin itself.
        (progn
          (when (numberp ebox-render-gc-cons-threshold)
            (setq gc-cons-threshold
                  (max gc-cons-threshold ebox-render-gc-cons-threshold)))
          (when (numberp ebox-render-gc-cons-percentage)
            (setq gc-cons-percentage
                  (max gc-cons-percentage ebox-render-gc-cons-percentage))))
      (ebox--deferred-render-gc-enter))
    (unwind-protect
        (progn
          (setq token (make-symbol "ebox-render-burst-token"))
          (puthash
           token
           (ebox--render-burst-create-record
            (if noninteractive 'batch 'interactive)
            (and noninteractive saved-threshold)
            (and noninteractive saved-percentage))
           ebox--render-burst-records)
          (push token ebox--render-burst-stack)
          (setq completed t)
          token)
      (unless completed
        (when token
          (remhash token ebox--render-burst-records))
        (if noninteractive
            (setq gc-cons-threshold saved-threshold
                  gc-cons-percentage saved-percentage)
          (ebox--deferred-render-gc-schedule-restore))))))

;;;###autoload
(defun ebox-render-burst-end (token)
  "End the render burst owned by opaque TOKEN.

TOKEN must be the most recently returned active token from
`ebox-render-burst-begin'.  Invalid, repeated, or out-of-order ends signal an
error without changing GC ownership.  Return nil after a successful end."
  (let ((record (gethash token ebox--render-burst-records)))
    (unless record
      (error "Invalid or inactive Ebox render-burst token"))
    (unless (eq token (car ebox--render-burst-stack))
      (error "Ebox render bursts must end in last-in, first-out order"))
    (pop ebox--render-burst-stack)
    (remhash token ebox--render-burst-records)
    (if (eq (ebox--render-burst-record-mode record) 'interactive)
        (ebox--deferred-render-gc-schedule-restore)
      (setq gc-cons-threshold
            (ebox--render-burst-record-saved-threshold record)
            gc-cons-percentage
            (ebox--render-burst-record-saved-percentage record))))
  nil)

;;;###autoload
(defun ebox-call-with-render-burst (function &rest arguments)
  "Call FUNCTION with ARGUMENTS inside one framework render burst.

The burst is always ended when FUNCTION returns, signals an error, or quits.
Return FUNCTION's value."
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (let ((token (ebox-render-burst-begin)))
    (unwind-protect
        (apply function arguments)
      (ebox-render-burst-end token))))

;;; Paint Mapping

(defun ebox-buffer--font-attributes (style)
  "Return anonymous face attributes for STYLE typography longhands."
  (let (face)
    (dolist (entry '((:font-family . :family)
                     (:font-height . :height)
                     (:font-weight . :weight)
                     (:font-slant . :slant)))
      (when-let ((value (plist-get style (car entry))))
        (setq face (plist-put face (cdr entry) value))))
    face))

(defun ebox-buffer--font-face (style)
  "Return STYLE's complete Emacs face value for typography."
  (let* ((base (plist-get style :font))
         (base (if (stringp base) (list :family base) base))
         (attributes (ebox-buffer--font-attributes style)))
    (cond
     ((and attributes base)
      (if (and (listp base) (not (keywordp (car-safe base))))
          (cons attributes base)
        (list attributes base)))
     (attributes attributes)
     (base base))))

(defun ebox-buffer--paint-color (style role)
  "Return the foreground paint color for STYLE and ROLE."
  (or (plist-get style :color)
      (and (memq role '(border border-top border-right border-bottom border-left))
           (or (plist-get style :border-color)
               (plist-get style :border-top-color)
               (plist-get style :border-right-color)
               (plist-get style :border-bottom-color)
               (plist-get style :border-left-color)))))

(defun ebox-buffer--paint-background-color (style role)
  "Return the background paint color for STYLE and ROLE."
  (unless (memq role '(border border-top border-right border-bottom border-left))
    (or (plist-get style :background-color)
        (plist-get style :bgcolor))))

(defun ebox-buffer--default-foreground-face ()
  "Return a face that resets only foreground to the resolved default.
Fall back to inheriting `default' when a headless frame has no concrete
foreground color."
  (let ((foreground (face-attribute 'default :foreground nil t)))
    (if (or (null foreground)
            (eq foreground 'unspecified)
            (and (stringp foreground)
                 (string-prefix-p "unspecified" foreground)))
        '(:inherit default)
      (list :foreground foreground))))

(defun ebox-buffer-paint-text-properties (style role)
  "Return Emacs text properties for computed STYLE in paint ROLE.
This backend mapper intentionally accepts computed style facts and emits only
buffer-facing paint properties.  Layout-only properties never pass through."
  (let ((face (ebox-buffer--font-face style)))
    (when-let ((foreground (ebox-buffer--paint-color style role)))
      (setq face
            (cond
             ((tp-paint-slot-p foreground)
              (let ((slot-face (tp-paint-slot-face foreground)))
                (if face (list slot-face face) slot-face)))
             ((eq foreground 'ebox/default-foreground)
              (append (ebox-buffer--default-foreground-face) face))
             (t (plist-put face :foreground foreground)))))
    (when-let ((background (ebox-buffer--paint-background-color style role)))
      (setq face
            (if (tp-paint-slot-p background)
                (let ((slot-face (tp-paint-slot-face background)))
                  (if face (list slot-face face) slot-face))
              (plist-put face :background background))))
    (when face
      (list 'face face))))

(defun ebox--propertize-typography (string style)
  "Apply STYLE's typography to one copy of STRING."
  (if-let ((face (ebox-buffer--font-face style)))
      (let ((copy (copy-sequence string)))
        (ebox--add-render-face! copy 0 (length copy) face t)
        (ebox--register-render-owned-face-values string copy))
    string))

;;; Text Property Helpers

(defun ebox-buffer-side-border-face (color)
  "Return the canonical Emacs face for a side border with COLOR."
  (cond
   ((tp-paint-slot-p color) (tp-paint-slot-face color))
   (color `(:background ,color))
   (t '(:inverse-video t))))

(defun ebox--pixel-border (pixel-width height &optional color)
  "Generate a border line of PIXEL-WIDTH and HEIGHT using optional COLOR."
  (when (and pixel-width height (> pixel-width 0) (> height 0))
    (let* ((face (ebox-buffer-side-border-face color))
           (display
            (ebox--register-render-owned-text-value
             'display `(space :width (,pixel-width))))
           (line (propertize " " 'display display)))
      (ebox--add-render-face! line 0 (length line) face)
      (ebox--register-render-owned-text-value 'face face)
      (ebox--string-repeat-lines line height))))

(defun ebox--propertize-bgcolor (string bgcolor)
  "Apply background color BGCOLOR to STRING."
  (let* ((source string)
         (string (copy-sequence source))
         (length (length string)))
    (ebox--add-render-face!
     string 0 length
     (if (tp-paint-slot-p bgcolor)
         (tp-paint-slot-face bgcolor)
       `(:background ,bgcolor))
     t)
    (ebox--register-render-owned-face-values source string)))

(defun ebox--propertize-color (string color)
  "Apply foreground COLOR to STRING."
  (let* ((source string)
         (string (copy-sequence source))
         (length (length string)))
    (ebox--add-render-face!
     string 0 length
     (cond
      ((tp-paint-slot-p color) (tp-paint-slot-face color))
      ((eq color 'ebox/default-foreground)
       (ebox-buffer--default-foreground-face))
      (t `(:foreground ,color)))
     t)
    (ebox--register-render-owned-face-values source string)))

(defun ebox--propertize-colors (string color bgcolor)
  "Apply foreground COLOR and background BGCOLOR to one copy of STRING."
  (let* ((source string)
         (string (copy-sequence source))
         (length (length string)))
    (when color
      (ebox--add-render-face!
       string 0 length
       (cond
        ((tp-paint-slot-p color) (tp-paint-slot-face color))
        ((eq color 'ebox/default-foreground)
         (ebox-buffer--default-foreground-face))
        (t `(:foreground ,color)))
       t))
    (when bgcolor
      (ebox--add-render-face!
       string 0 length
       (if (tp-paint-slot-p bgcolor)
           (tp-paint-slot-face bgcolor)
         `(:background ,bgcolor))
       t))
    (ebox--register-render-owned-face-values source string)))

(defun ebox--propertize-overline (string &optional color)
  "Apply overline to STRING with optional COLOR."
  (let* ((source string)
         (string (copy-sequence source)))
    (ebox--add-render-face!
     string 0 (length string)
     (if (tp-paint-slot-p color)
         (tp-paint-slot-face color)
       `(:overline ,(or color t)))
     t)
    (ebox--register-render-owned-face-values source string)))

(defun ebox--propertize-underline (string &optional color)
  "Apply underline to STRING with optional COLOR."
  (let* ((source string)
         (string (copy-sequence source)))
    (ebox--add-render-face!
     string 0 (length string)
     (if (tp-paint-slot-p color)
         (tp-paint-slot-face color)
       `(:underline (:position t ,@(when color `(:color ,color)))))
     t)
    (ebox--register-render-owned-face-values source string)))

(defun ebox--propertize-region (string property region-id)
  "Add PROPERTY with REGION-ID to each line of STRING."
  (when string
    (ebox--maplines
     (lambda (line) (propertize line property region-id))
     string)))

(defun ebox--content-owner-stack-at (string pos)
  "Return the existing owner stack in STRING at POS, inner to outer."
  (let ((owners (copy-sequence
                 (or (get-text-property pos 'ebox-content-owners string)
                     nil)))
        (owner (get-text-property pos 'ebox-content-owner string)))
    (if (and owner (not (member owner owners)))
        (append owners (list owner))
      owners)))

(defun ebox--next-content-owner-property-change
    (pos string limit &optional complete-stack-p)
  "Return next owner metadata change in STRING after POS before LIMIT.
When COMPLETE-STACK-P is non-nil, `ebox-content-owners' already contains the
current direct owner, so only a stack change can affect the next output run."
  (let ((next limit))
    (dolist (prop (if complete-stack-p
                      '(ebox-content-owners)
                    '(ebox-content-owner ebox-content-owners)))
      (let ((change (next-single-property-change pos prop string limit)))
        (when (and change (< change next))
          (setq next change))))
    next))

(defun ebox--add-content-owner! (string region-id)
  "Destructively append REGION-ID to STRING's content owner stack."
  (let ((length (length string)))
    (unless (= length 0)
      (let ((owner (get-text-property 0 'ebox-content-owner string))
            (owners-prop (get-text-property 0 'ebox-content-owners string)))
        (if (and (not (text-property-not-all
                       0 length 'ebox-content-owner owner string))
                 (not (text-property-not-all
                       0 length 'ebox-content-owners owners-prop string)))
            (let ((owners (copy-sequence (or owners-prop nil))))
              (when (and owner (not (member owner owners)))
                (setq owners (append owners (list owner))))
              (unless (member region-id owners)
                (setq owners (append owners (list region-id))))
              (ebox--register-render-owned-text-value
               'ebox-content-owner region-id)
              (ebox--register-render-owned-text-value
               'ebox-content-owners owners)
              (add-text-properties
               0 length
               (list 'ebox-content-owner region-id
                     'ebox-content-owners owners)
               string))
          (let ((pos 0)
                next owners original-owners)
            (while (< pos length)
              (let* ((owner (get-text-property
                             pos 'ebox-content-owner string))
                     (owners-prop (get-text-property
                                   pos 'ebox-content-owners string))
                     (complete-stack-p
                      (and owners-prop (member owner owners-prop))))
                (setq original-owners owners-prop)
                (setq next (ebox--next-content-owner-property-change
                             pos string length complete-stack-p))
                (setq owners
                      (if complete-stack-p
                          owners-prop
                        (ebox--content-owner-stack-at string pos))))
              (unless (member region-id owners)
                (setq owners (append owners (list region-id))))
              (ebox--register-render-owned-text-value
               'ebox-content-owner region-id)
              (unless (eq owners original-owners)
                (ebox--register-render-owned-text-value
                 'ebox-content-owners owners))
              (add-text-properties pos next
                                   (list 'ebox-content-owner region-id
                                         'ebox-content-owners owners)
                                   string)
              (setq pos next))))))
    string))

(defun ebox--add-content-owner (string region-id)
  "Return a copy of STRING with REGION-ID appended to its owner stack."
  (ebox--add-content-owner! (copy-sequence string) region-id))

(defun ebox--add-content-owners (string owners)
  "Return STRING with OWNERS appended to its content owner stack."
  (let ((result (copy-sequence string))
        (length (length string)))
    (when (and owners (> length 0))
      (let ((position 0)
            (final-owner (car (last owners))))
        (while (< position length)
          (let* ((owner (get-text-property
                         position 'ebox-content-owner result))
                 (stack (get-text-property
                         position 'ebox-content-owners result))
                 (original-stack stack)
                 (complete-stack-p (and stack (member owner stack)))
                 (next (ebox--next-content-owner-property-change
                        position result length complete-stack-p)))
            (unless complete-stack-p
              (setq stack
                    (ebox--content-owner-stack-at result position)))
            (dolist (new-owner owners)
              (unless (member new-owner stack)
                (setq stack (append stack (list new-owner)))))
            (ebox--register-render-owned-text-value
             'ebox-content-owner final-owner)
            (unless (eq stack original-stack)
              (ebox--register-render-owned-text-value
               'ebox-content-owners stack))
            (add-text-properties
             position next
             (list 'ebox-content-owner final-owner
                   'ebox-content-owners stack)
             result)
            (setq position next)))))
    result))

(defun ebox--propertize-content-line (line region-id idx fallback)
  "Return LINE with region ownership for REGION-ID at content index IDX.
Preserve child `ebox-content' properties and add wrapper ownership through
`ebox-content-owner'.  If LINE has no child content region, use REGION-ID as
the line's direct `ebox-content' owner.  Use FALLBACK when LINE is empty.  When
the current render context marks LINE as a fresh private allocation, ownership
may be added in place."
  (let* ((empty-line-p (string-empty-p line))
         (source (if empty-line-p fallback line))
         (mutate-p (and ebox--propertize-private-content-line-p
                        (not empty-line-p)))
         (line
          (if (and (not (text-property-not-all
                         0 (length source)
                         'ebox-content-owner nil source))
                   (not (text-property-not-all
                         0 (length source)
                         'ebox-content-owners nil source)))
              (let ((copy (if mutate-p source (copy-sequence source)))
                    (owners (list region-id)))
                (ebox--register-render-owned-text-value
                 'ebox-content-owner region-id)
                (ebox--register-render-owned-text-value
                 'ebox-content-owners owners)
                (add-text-properties
                 0 (length copy)
                 (list 'ebox-content-owner region-id
                       'ebox-content-owners owners)
                 copy)
                copy)
            (if mutate-p
                (ebox--add-content-owner! source region-id)
                (ebox--add-content-owner source region-id)))))
    (unless (text-property-not-all 0 (length line)
                                   'ebox-content nil line)
      (add-text-properties 0 (length line)
                           (list 'ebox-content region-id
                                 'ebox-content-idx idx)
                           line))
    line))

;;; Existing Slot Shaping

(defun ebox-buffer--rendered-owned-lines
    (rendered region-ids &optional expected-line-count)
  "Project RENDERED to its contiguous direct role-owned lines.

REGION-IDS is the same owner set used to derive retained TP spans.  Leading
and trailing lines without a direct target role are stable wrapper chrome and
are omitted.  When EXPECTED-LINE-COUNT is non-nil, any remaining excess may
be removed only from role-proven outer margin/border lines (`mt'/`bt' at the
start, `mb'/`bb' at the end).  Padding and content are never inferred from a
numeric box-model delta.  An unowned interior line or a foreign direct
`content' role fails closed.  Returned lines retain all text properties."
  (let ((region-set (make-hash-table :test 'equal))
        (lines (ebox-string-lines rendered))
        infos first last invalid)
    (dolist (region-id region-ids)
      (puthash region-id t region-set))
    (dolist (line lines)
      (let ((position 0)
            (limit (length line))
            owned foreign-content roles)
        (while (< position limit)
          (let ((next limit))
            (dolist (entry ebox-region-types)
              (let* ((property (cdr entry))
                     (region-id (get-text-property position property line))
                     (change (next-single-property-change
                              position property line limit)))
                (when (and region-id (gethash region-id region-set))
                  (setq owned t)
                  (cl-pushnew (car entry) roles))
                (when (and (eq (car entry) 'content) region-id
                           (not (gethash region-id region-set)))
                  (setq foreign-content t))
                (when (and change (< change next))
                  (setq next change))))
            (setq position (max next (1+ position)))))
        (push (list :line line :owned (and owned (not foreign-content))
                    :roles roles)
              infos)
        (when (and owned foreign-content)
          (setq invalid t))))
    (setq infos (nreverse infos))
    (cl-loop for info in infos
             for index from 0
             when (plist-get info :owned)
             do (unless first (setq first index))
             and do (setq last index))
    (when (and first (not invalid)
               (cl-every (lambda (info) (plist-get info :owned))
                         (cl-subseq infos first (1+ last))))
      (let ((owned (cl-subseq infos first (1+ last))))
        (when expected-line-count
          (while (> (length owned) expected-line-count)
            (let ((leading-roles (plist-get (car owned) :roles))
                  (trailing-roles (plist-get (car (last owned)) :roles)))
              (cond
               ((and (not (memq 'content leading-roles))
                     (not (memq 'content-owner leading-roles))
                     (cl-some (lambda (role) (memq role '(mt bt)))
                              leading-roles))
                (setq owned (cdr owned)))
               ((and (not (memq 'content trailing-roles))
                     (not (memq 'content-owner trailing-roles))
                     (cl-some (lambda (role) (memq role '(mb bb)))
                              trailing-roles))
                (setq owned (butlast owned)))
               (t
                (setq invalid t
                      owned nil))))))
        (when (and owned (not invalid)
                   (or (null expected-line-count)
                       (= (length owned) expected-line-count)))
          (ebox-lines-join
           (mapcar (lambda (info) (plist-get info :line)) owned)))))))

(defun ebox-buffer--span-slot-width (span)
  "Return SPAN's visual slot width in its current buffer line."
  (save-excursion
    (goto-char (car span))
    (let ((line-start (line-beginning-position)))
      (- (ebox--string-pixel-width
          (buffer-substring line-start (cdr span)))
         (ebox--string-pixel-width
         (buffer-substring line-start (car span)))))))

(defun ebox-buffer--partial-line-slots-p (spans)
  "Return non-nil when SPANS are parent-owned partial line slots."
  (cl-some (lambda (span)
             (save-excursion
               (goto-char (car span))
               (not (and (= (car span) (line-beginning-position))
                         (= (cdr span) (line-end-position))))))
           spans))

(defun ebox-buffer--pad-line-to-slot-width (line width)
  "Return LINE padded to visual slot WIDTH, or nil if LINE is wider."
  (let* ((line-width (ebox--string-pixel-width line))
         (extra (- width line-width)))
    (when (>= extra 0)
      (concat line (ebox-pixel-space extra)))))

(defun ebox-buffer--slots-require-wrapper-side-border-p (spans owner-set)
  "Return non-nil when SPANS contain side borders absent from OWNER-SET."
  (cl-some
   (lambda (span)
     (cl-some
      (lambda (property)
        (let ((position (car span))
              (limit (cdr span))
              owner)
          (while (and (< position limit)
                      (progn
                        (setq owner (get-text-property position property))
                        (or (not owner)
                            (and owner-set (gethash owner owner-set)))))
            (setq position
                  (or (next-single-property-change
                       position property nil limit)
                      limit)))
          (and owner (< position limit))))
      '(ebox-bl ebox-br)))
   spans))

(defun ebox-buffer--rendered-in-existing-slots
    (spans rendered &optional owner-set require-exact-width-p)
  "Return RENDERED padded to fit SPANS' safe old parent slots.
Return nil when RENDERED needs more lines or width than the old slots provide.
When REQUIRE-EXACT-WIDTH-P is non-nil, decline padding that would hide a
parent layout change."
  (let* ((lines (ebox-string-lines rendered))
         (slot-count (length spans))
         (slot-widths (mapcar #'ebox-buffer--span-slot-width spans))
         (line-widths (mapcar #'ebox--string-pixel-width lines)))
    (when (and (or (null owner-set)
                   (not
                    (ebox-buffer--slots-require-wrapper-side-border-p
                     spans owner-set)))
               (ebox-buffer--partial-line-slots-p spans)
               (<= (length lines) slot-count)
               (or (not require-exact-width-p)
                   (cl-loop for width in line-widths
                            for slot-width in slot-widths
                            always (= width slot-width))))
      (let (padded ok)
        (setq ok t)
        (cl-loop for width in slot-widths
                 for line = (or (pop lines) (ebox-pixel-space 0))
                 do (if-let ((padded-line
                              (ebox-buffer--pad-line-to-slot-width
                               line width)))
                        (push padded-line padded)
                      (setq ok nil)))
        (when ok
          (ebox-lines-join (nreverse padded)))))))

(provide 'ebox-buffer-backend)

;;; ebox-buffer-backend.el ends here
