;;; native-parity.el --- Compare native and Elisp Ebox renderings -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The native layout must publish the same text and the same visible and
;; interactive text properties as the Elisp renderer for every document it
;; accepts.  This development tool renders one `ebox-build' form through both
;; paths and reports the first textual difference with its context plus every
;; property difference, so a native compiler change can be diagnosed without a
;; GUI session.
;;
;;   python3 scripts/elisp.py run -p ebox -l scripts/native-parity.el -e \
;;     '(ebox-native-parity-report
;;       (list (quote box) :width (list (quote px) 40) :wrap-mode (quote word)
;;             "中文与 words 内容更多一些的第二段文本，换行位置应当一致"))'
;;
;; A report's `:native-kind' names the projection the native attempt selected;
;; when the module is unavailable or declined, `:native-available' is nil and
;; the comparison only proves the Elisp renderer against itself.
;;
;; Batch entry: point EB_NATIVE_PARITY_FORM at a file holding one form and run
;; `make native-parity FORM=<file>'; the command prints the report and exits
;; non-zero when the two renderings differ.  It is a diagnostic smoke tool, not
;; a correctness gate: maintained scenarios live in the package test suite.

;;; Code:

(require 'cl-lib)
(require 'ebox)
(require 'ebox-native-reflow)

(defconst ebox-native-parity--properties
  '(face display mouse-face help-echo keymap)
  "Text properties that must survive the native layout unchanged.
Region and ownership metadata (`ebox-content', region roles) identify nodes
in one build and legitimately differ between the two builds compared here.
Keymaps compare by presence; their bindings are opaque callback state.")

(defconst ebox-native-parity--difference-limit 8
  "Maximum property differences a report keeps.")

(defun ebox-native-parity--summarize (value &optional depth)
  "Return VALUE with images, keymaps and long strings reduced for printing.
DEPTH bounds recursive walks so cyclic property values stay printable."
  (let ((depth (or depth 4)))
    (cond
     ((zerop depth) '...)
     ((imagep value)
      (list 'image (image-type value) (ignore-errors (image-size value t))))
     ((and (keymapp value) t) 'keymap)
     ((and (functionp value) value) 'function)
     ((consp value)
      (cons (ebox-native-parity--summarize (car value) (1- depth))
            (ebox-native-parity--summarize (cdr value) (1- depth))))
     ((and (stringp value) (> (length value) 64))
      (concat (substring value 0 61) "..."))
     (t value))))

(defun ebox-native-parity--properties-at (string position)
  "Return STRING's parity-relevant properties at POSITION as an alist."
  (let ((properties (text-properties-at position string)) entries)
    (dolist (property ebox-native-parity--properties (nreverse entries))
      (when (plist-member properties property)
        (push (cons property
                    (ebox-native-parity--summarize
                     (plist-get properties property)))
              entries)))))

(defun ebox-native-parity--render (input native-p width height)
  "Render INPUT and return (KIND . STRING).
When NATIVE-P is non-nil the native frame is attempted; otherwise the module
is forced off so the ordinary Elisp renderer publishes the reference."
  (with-temp-buffer
    (let* ((ebox-viewport-width width)
           (ebox-viewport-height height)
           (kind nil)
           (options (list :observer
                          (lambda (_buffer report)
                            (when (eq (plist-get report :provider) 'ebox)
                              (setq kind (plist-get report :projection-kind)))))))
      (if native-p
          (ebox-render-to-buffer (current-buffer) input options)
        (let ((ebox-native-reflow--load-attempted-p t)
              (ebox-native-reflow--available-p nil))
          (ebox-render-to-buffer (current-buffer) input options)))
      (cons kind (buffer-string)))))

(defun ebox-native-parity--text-difference (native elisp)
  "Return the first textual difference between NATIVE and ELISP, or nil."
  (let* ((plain-native (substring-no-properties native))
         (plain-elisp (substring-no-properties elisp))
         (limit (min (length plain-native) (length plain-elisp)))
         (position 0))
    (while (and (< position limit)
                (eq (aref plain-native position)
                    (aref plain-elisp position)))
      (setq position (1+ position)))
    (unless (and (= position limit)
                 (= (length plain-native) (length plain-elisp)))
      (list :position position
            :native-context
            (substring plain-native (max 0 (- position 30))
                       (min (length plain-native) (+ position 60)))
            :elisp-context
            (substring plain-elisp (max 0 (- position 30))
                       (min (length plain-elisp) (+ position 60)))))))

(defun ebox-native-parity--property-differences (native elisp)
  "Return bounded property differences between NATIVE and ELISP."
  (let ((limit (min (length native) (length elisp)))
        (position 0)
        differences)
    (while (and (< position limit)
                (< (length differences) ebox-native-parity--difference-limit))
      (let ((native-properties (ebox-native-parity--properties-at native position))
            (elisp-properties (ebox-native-parity--properties-at elisp position)))
        (unless (equal native-properties elisp-properties)
          (push (list :position position
                      :native native-properties
                      :elisp elisp-properties)
                differences))
        (setq position
              (max (1+ position)
                   (min (or (next-property-change position native limit) limit)
                        (or (next-property-change position elisp limit) limit))))))
    (nreverse differences)))

(defun ebox-native-parity-report (form &optional width height)
  "Render FORM natively and through Elisp and report every difference.
FORM is an `ebox-build' form.  WIDTH and HEIGHT default to 900 pixels and
50 lines.  Return a plist describing the native attempt and the comparison:

  :native-available  module present before the render
  :native-kind       projection the native render selected
  :viewport          (WIDTH HEIGHT) used for both renders
  :equal             text and parity properties agree
  :lengths           (NATIVE-LENGTH ELISP-LENGTH)
  :text              first textual difference, when different
  :properties        bounded list of differing property runs

Build the form twice: rendering canonicalizes its input."
  (let* ((native-available (ebox-native-reflow-layout-ready-p))
         (width (or width 900))
         (height (or height 50))
         (native (ebox-native-parity--render (ebox-build form) t width height))
         (elisp (ebox-native-parity--render (ebox-build form) nil width height))
         (native-string (cdr native))
         (elisp-string (cdr elisp))
         (text-difference
          (ebox-native-parity--text-difference native-string elisp-string))
         (property-differences
          (ebox-native-parity--property-differences native-string elisp-string)))
    (list :native-available native-available
          :native-kind (car native)
          :viewport (list width height)
          :equal (and (null text-difference) (null property-differences))
          :lengths (list (length native-string) (length elisp-string))
          :text text-difference
          :properties property-differences)))

(defun ebox-native-parity-report-file (file)
  "Read FILE's single `ebox-build' form and return its parity report."
  (let* ((parsed (with-temp-buffer
                   (insert-file-contents file)
                   (goto-char (point-min))
                   (read (current-buffer)))))
    (ebox-native-parity-report parsed)))

(defun ebox-native-parity-batch ()
  "Check one form from EB_NATIVE_PARITY_FORM and exit non-zero on a difference.
Print the usage line when the variable is unset."
  (let ((file (getenv "EB_NATIVE_PARITY_FORM")))
    (unless (and file (file-readable-p file))
      (princ "usage: EB_NATIVE_PARITY_FORM=<lisp-form-file> make native-parity\n")
      (kill-emacs 2))
    (let* ((report (ebox-native-parity-report-file file))
           (native (getenv "EB_NATIVE_PARITY_FORM")))
      (princ (format "form=%s native-available=%S kind=%S equal=%S lengths=%S\n"
                     native
                     (plist-get report :native-available)
                     (plist-get report :native-kind)
                     (plist-get report :equal)
                     (plist-get report :lengths)))
      (when-let* ((difference (plist-get report :text)))
        (princ (format "text-difference position=%S\n  native=%S\n  elisp =%S\n"
                       (plist-get difference :position)
                       (plist-get difference :native-context)
                       (plist-get difference :elisp-context))))
      (dolist (difference (plist-get report :properties))
        (princ (format "property-difference position=%S\n  native=%S\n  elisp =%S\n"
                       (plist-get difference :position)
                       (plist-get difference :native)
                       (plist-get difference :elisp))))
      (kill-emacs (if (plist-get report :equal) 0 1)))))

(provide 'native-parity)
;;; native-parity.el ends here
