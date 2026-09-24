;;; ebox-font.el --- Surface-resolved font facts -*- lexical-binding: t; -*-

;;; Commentary:
;; Resolves canonical font inputs against one Emacs display capability and
;; returns a shared immutable fact for measurement and final paint.  It does
;; not own author parsing, cascade, layout, Ebox publication priority, or buffer publication.

;;; Code:

(require 'cl-lib)

(cl-defstruct (ebox-font-fact
               (:constructor ebox-font--make-fact)
               (:conc-name ebox-font-fact--))
  "One surface-resolved font projection shared by all downstream consumers."
  (requested-decipoints nil :read-only t)
  (resolved-font-identity nil :read-only t)
  (measurement-metrics nil :read-only t)
  (capability-signature nil :read-only t))

(defun ebox-font-fact-requested-decipoints (fact)
  "Return FACT's requested decipoints scalar."
  (ebox-font-fact--requested-decipoints fact))

(defun ebox-font-fact-resolved-font-identity (fact)
  "Return a detached resolved identity from FACT."
  (copy-tree (ebox-font-fact--resolved-font-identity fact) t))

(defun ebox-font-fact-measurement-metrics (fact)
  "Return detached measurement metrics from FACT."
  (copy-tree (ebox-font-fact--measurement-metrics fact) t))

(defun ebox-font-fact-capability-signature (fact)
  "Return a detached display capability signature from FACT."
  (copy-tree (ebox-font-fact--capability-signature fact) t))

(defconst ebox-font--cache-max-entries 512
  "Maximum resolved font facts retained across display capabilities.")

(defvar ebox-font--cache (make-hash-table :test #'equal)
  "Cache keyed by canonical font inputs and complete capability signature.")

(defvar ebox-font--measurement-epoch 0
  "Invalidation epoch for cold font and glyph-allocation proofs.")

(defun ebox-font--requested-decipoints (font-size-px)
  "Convert positive FONT-SIZE-PX reference pixels to integer decipoints."
  (when font-size-px
    (unless (and (numberp font-size-px) (> font-size-px 0))
      (error "Ebox font size must be positive CSS reference pixels: %S"
             font-size-px))
    ;; CSS reference px is 1/96 inch.  Emacs integer face height is 1/10 point.
    ;; px * 72 / 96 * 10 = px * 7.5; positive values round half up.
    (floor (+ (* font-size-px 7.5) 0.5))))

(defun ebox-font--face
    (family decipoints weight style weight-active-p style-active-p)
  "Return Emacs face projection for canonical font inputs."
  (let (face)
    (when family
      (setq face
            (plist-put face :family
                       (if (symbolp family) (symbol-name family) family))))
    (when decipoints (setq face (plist-put face :height decipoints)))
    (when weight-active-p (setq face (plist-put face :weight weight)))
    (when style-active-p (setq face (plist-put face :slant style)))
    face))

(defun ebox-font--parent-css-weight (fact)
  "Return FACT's resolved CSS numeric weight, defaulting to normal."
  (or (and (ebox-font-fact-p fact)
           (plist-get (ebox-font-fact--resolved-font-identity fact)
                      :css-weight))
      400))

(defun ebox-font--absolute-css-weight (weight parent-fact)
  "Resolve CSS WEIGHT against PARENT-FACT to one absolute numeric weight."
  (pcase weight
    ((or 'nil 'normal) 400)
    ('bold 700)
    ('bolder
     (let ((parent (ebox-font--parent-css-weight parent-fact)))
       (cond ((<= parent 300) 400)
             ((<= parent 500) 700)
             (t 900))))
    ('lighter
     (let ((parent (ebox-font--parent-css-weight parent-fact)))
       (cond ((<= parent 500) 100)
             ((<= parent 700) 400)
             (t 700))))
    ((pred numberp) weight)
    (_ (error "Invalid canonical CSS font weight: %S" weight))))

(defun ebox-font--emacs-weight (css-weight)
  "Map absolute numeric CSS-WEIGHT to an Emacs face weight."
  (alist-get css-weight
             '((100 . ultra-light) (200 . extra-light) (300 . light)
               (400 . normal) (500 . normal) (600 . semi-bold)
               (700 . bold) (800 . extra-bold) (900 . ultra-bold))))

(defun ebox-font--default-resolver (face window)
  "Resolve FACE in WINDOW and return identity plus actual measurement metrics."
  (let* ((window (and (window-live-p window) window))
         (probe (propertize "M " 'face face))
         (font (ignore-errors (font-at 0 window probe)))
         (name
          (and font
               (or (ignore-errors (font-get font :name))
                   (and (fboundp 'font-xlfd-name)
                        (ignore-errors (font-xlfd-name font))))))
         (info
          (and name
               (ignore-errors
                 (font-info name (and window (window-frame window))))))
         (zero-width (string-pixel-width (propertize "0" 'face face))))
    (list
     :identity
     (if font
         (list :type (font-get font :type)
               :name name
               :family (font-get font :family)
               :weight (font-get font :weight)
               :slant (font-get font :slant)
               :width (font-get font :width)
               :size (font-get font :size)
               :file (and info (> (length info) 12) (aref info 12)))
       (list :unresolved-face (copy-tree face)))
     :metrics
     (if info
         (list :pixel-size (aref info 2)
               :zero-width zero-width
               :height (aref info 3)
               :baseline-offset (aref info 4)
               :max-width (aref info 7)
               :ascent (aref info 8)
               :descent (aref info 9)
               :space-width (aref info 10)
               :average-width (aref info 11))
       (list :probe-width (string-pixel-width probe)
             :zero-width zero-width
             :space-width
             (string-pixel-width (propertize " " 'face face)))))))

(defvar ebox-font--resolver #'ebox-font--default-resolver
  "Function resolving an Emacs face into identity and measurement metrics.")

(cl-defun ebox-font--project
    (&key family size weight style weight-active-p style-active-p
          capability-signature window parent-fact)
  "Return one cached font fact for canonical inputs and display capability."
  (let* ((css-weight (ebox-font--absolute-css-weight weight parent-fact))
         (emacs-weight (ebox-font--emacs-weight css-weight))
         (decipoints (ebox-font--requested-decipoints size))
         (face (ebox-font--face
                family decipoints emacs-weight style
                weight-active-p style-active-p))
         (key (list family size weight css-weight style
                    weight-active-p style-active-p capability-signature))
         (missing (make-symbol "ebox-font-fact-missing"))
         (cached (gethash key ebox-font--cache missing)))
    (if (not (eq cached missing))
        cached
      (let* ((resolved (funcall ebox-font--resolver face window))
             (fact
              (ebox-font--make-fact
               :requested-decipoints decipoints
               :resolved-font-identity
               (list :css-weight css-weight
                     :face (copy-tree face)
                     :resource (copy-tree (plist-get resolved :identity)))
               :measurement-metrics
               (copy-tree (plist-get resolved :metrics))
               :capability-signature (copy-tree capability-signature))))
        (when (>= (hash-table-count ebox-font--cache)
                  ebox-font--cache-max-entries)
          (clrhash ebox-font--cache))
        (puthash (copy-tree key) fact ebox-font--cache)
        fact))))

(defun ebox-font-project-values
    (values specified capability-signature &optional window parent-fact)
  "Project canonical font VALUES for one Emacs display capability.
SPECIFIED is the canonical property-id set with declaration winners."
  (let* ((values values)
         (family (plist-get values 'ebox/font-family))
         (size (plist-get values 'ebox/font-size))
         (weight (plist-get values 'ebox/font-weight))
         (font-style (plist-get values 'ebox/font-style))
         (weight-active-p
          (or (not (eq weight 'normal))
              (memq 'ebox/font-weight specified)))
         (style-active-p
          (or (not (eq font-style 'normal))
              (memq 'ebox/font-style specified))))
    (when (or family size weight-active-p style-active-p)
      (ebox-font--project
       :family family :size size :weight weight :style font-style
       :weight-active-p weight-active-p :style-active-p style-active-p
       :capability-signature capability-signature :window window
       :parent-fact parent-fact))))

(defun ebox-font-clear-cache ()
  "Clear all surface-resolved font facts."
  (clrhash ebox-font--cache)
  (cl-incf ebox-font--measurement-epoch))

(defun ebox-font-measurement-face (fact)
  "Return a detached measurement face from font FACT."
  (unless (ebox-font-fact-p fact)
    (signal 'wrong-type-argument (list 'ebox-font-fact-p fact)))
  (copy-tree
   (plist-get (ebox-font-fact--resolved-font-identity fact) :face)))

(defun ebox-font-paint-face (fact)
  "Return a detached final-paint face from the same font FACT."
  (unless (ebox-font-fact-p fact)
    (signal 'wrong-type-argument (list 'ebox-font-fact-p fact)))
  (copy-tree
   (plist-get (ebox-font-fact--resolved-font-identity fact) :face)))

(defun ebox-font--prepared-metrics (fact capability window)
  "Return complete actual metrics for FACT in CAPABILITY and WINDOW.
Neutral inherited font projections may be nil; resolve their actual default
font once on this cold path.  Missing native height or baseline evidence
does not establish that a prepared font transition keeps its allocation."
  (let* ((fact (or fact (ebox-font--project
                        :weight 'normal :style 'normal
                        :capability-signature capability :window window)))
         (metrics (ebox-font-fact--measurement-metrics fact)))
    (when (cl-every (lambda (property) (numberp (plist-get metrics property)))
                    '(:zero-width :space-width :height :baseline-offset :ascent :descent))
      metrics)))

(defun ebox-font--prepared-metrics-equal-p (left right capability window &optional terminal-cell)
  "Prove LEFT and RIGHT keep actual font-based geometry in CAPABILITY/WINDOW."
  (if terminal-cell
      ;; The terminal renderer has a fixed line cell, independent of font
      ;; weight.  Ebox itself falls back to that height for lh; retain its
      ;; actual measured zero/space advances for ch and horizontal fill.
      (let* ((neutral (ebox-font--project :weight 'normal :style 'normal
                                         :capability-signature capability :window window))
             (before (ebox-font-fact--measurement-metrics (or left neutral)))
             (after (ebox-font-fact--measurement-metrics (or right neutral))))
        (and (= (or (plist-get before :height) (aref terminal-cell 1))
                (or (plist-get after :height) (aref terminal-cell 1)))
             (cl-every (lambda (property)
                         (and (numberp (plist-get before property))
                              (numberp (plist-get after property))
                              (= (plist-get before property) (plist-get after property))))
                       '(:zero-width :space-width))))
    (let ((before (ebox-font--prepared-metrics left capability window))
          (after (ebox-font--prepared-metrics right capability window)))
      (and before after
           (cl-every (lambda (property) (= (plist-get before property) (plist-get after property)))
                     '(:zero-width :space-width :height :baseline-offset :ascent :descent))))))

(defun ebox-font--prepared-glyph-metrics (text position window)
  "Read the actual font metrics for TEXT's glyph at POSITION in WINDOW.
This cold proof includes caller faces and fontset fallback selection, which
the FontFact's Latin default probe alone cannot establish."
  (let* ((font (ignore-errors (font-at position window text)))
         (name (and font
                    (or (ignore-errors (font-get font :name))
                        (and (fboundp 'font-xlfd-name)
                             (ignore-errors (font-xlfd-name font))))))
         (info (and name (ignore-errors
                          (font-info name (and (window-live-p window) (window-frame window)))))))
    (when (and (vectorp info) (> (length info) 9)
               (cl-every (lambda (index) (numberp (aref info index))) '(3 4 8 9)))
      (vector (aref info 3) (aref info 4) (aref info 8) (aref info 9)))))

(defun ebox-font-fact-neutral-p (fact)
  "Return non-nil when FACT adds no non-default font capability."
  (and (ebox-font-fact-p fact)
       (null (ebox-font-fact--requested-decipoints fact))
       (null (plist-get
              (ebox-font-fact--resolved-font-identity fact) :face))))

(provide 'ebox-font)
;;; ebox-font.el ends here
