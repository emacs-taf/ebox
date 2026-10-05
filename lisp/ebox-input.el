;;; ebox-input.el --- Native editing sessions over retained Hosts -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A session lets the user edit one retained Host's published text directly in
;; the Ebox buffer.  While it is active, Ebox accepts edits inside that span
;; and refuses to publish the buffer, so the user's text, point, selection and
;; undo survive untouched.  Ending the session restores the previously
;; published text and returns the user's text, so the application can publish
;; the new value through its ordinary update path.  The session owns no
;; application state: callers keep values, drafts and submission policy.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'ebox-publication)
(require 'ebox-runtime)

(declare-function ebox-surface-buffer-mounted-p "ebox-surface" (buffer-or-name))
(declare-function ebox--window-size-change "ebox-viewport" (frame))

(defun ebox-input-active-p (buffer-or-name)
  "Return BUFFER-OR-NAME's active input session, or nil."
  (let ((buffer (get-buffer buffer-or-name)))
    (and (buffer-live-p buffer)
         (buffer-local-value 'ebox--input-session buffer))))

;;;###autoload
(defun ebox-input-begin (buffer-or-name host-ref)
  "Begin native editing of HOST-REF's published text in BUFFER-OR-NAME.
Return a session for `ebox-input-text' and `ebox-input-end'.  The session
makes the normally read-only surface buffer writable and restores that state
on end.  While it is active, edits inside the Host's published span are
accepted and publication of that buffer is refused, so the user's text, point,
selection and undo are not disturbed.  The caller keeps the application value
and normally mirrors edits into it through its own change callback.

Host references resolve through the committed publication, so an unmounted
surface, a hidden or missing Host, a dead buffer and an existing session are
errors.  One buffer holds at most one session."
  (let* ((buffer (get-buffer buffer-or-name))
         (existing (ebox-input-active-p buffer)))
    (when existing
      (signal 'ebox-input-session-active (list buffer)))
    (unless (buffer-live-p buffer)
      (signal 'ebox-input-error (list "Expected a live Ebox buffer")))
    (unless (ebox-surface-buffer-mounted-p buffer)
      (signal 'ebox-input-error (list "Expected a mounted Ebox surface")))
    (let ((bounds (ebox-host-ref-bounds buffer host-ref)))
      (unless bounds
        (signal 'ebox-input-error
                (list "Host has no published span to edit" host-ref)))
      (with-current-buffer buffer
        (let ((session (ebox--input-session-create
                        :buffer buffer :host-ref host-ref
                        :start (copy-marker (car bounds))
                        :end (copy-marker (cdr bounds) t)
                        :original (buffer-substring (car bounds) (cdr bounds))
                        :read-only buffer-read-only)))
          (setq buffer-read-only nil)
          (setq ebox--input-session session)
          session)))))

;;;###autoload
(defun ebox-input-text (session)
  "Return SESSION's current property-free user text."
  (unless (ebox--input-session-p session)
    (signal 'ebox-input-error (list "Expected an input session")))
  (with-current-buffer (ebox--input-session-buffer session)
    (buffer-substring-no-properties (ebox--input-session-start session)
                                    (ebox--input-session-end session))))

;;;###autoload
(defun ebox-input-session-host-ref (session)
  "Return SESSION's edited Host reference."
  (unless (ebox--input-session-p session)
    (signal 'ebox-input-error (list "Expected an input session")))
  (ebox--input-session-host-ref session))

;;;###autoload
(defun ebox-input-end (session)
  "End SESSION, restore its published text, and return the user's text.
Restoration runs without host modification hooks, so it is a sanctioned write
that does not invalidate the surface.  Publish the new value afterwards
through the ordinary update path.  An ended or foreign session is an error.
Ending is idempotent and tolerant: a session whose buffer died, or which
another code path already removed from its buffer, only releases its markers
and returns nil, so a failure after the user's edit cannot leave the buffer
refusing every publication."  
  (unless (ebox--input-session-p session)
    (signal 'ebox-input-error (list "Expected an input session")))
  (let ((buffer (ebox--input-session-buffer session))
        (text nil))
    (unwind-protect
        (when (eq (and (buffer-live-p buffer)
                       (buffer-local-value 'ebox--input-session buffer))
                  session)
          (with-current-buffer buffer
            (let ((start (marker-position (ebox--input-session-start session)))
                  (finish (marker-position (ebox--input-session-end session))))
              (when (and start finish)
                (setq text (buffer-substring-no-properties start finish))
                (let ((inhibit-modification-hooks t)
                      (inhibit-read-only t))
                  (delete-region start finish)
                  (goto-char start)
                  (insert (ebox--input-session-original session))))
              (setq buffer-read-only (ebox--input-session-read-only session))
              (setq ebox--input-session nil))))
      (set-marker (ebox--input-session-start session) nil)
      (set-marker (ebox--input-session-end session) nil)
      ;; A viewport that changed while the session owned the text was never
      ;; published; ask the viewport bridge to re-check this buffer's window
      ;; once the session releases the text.
      (when (and (buffer-live-p buffer)
                 (fboundp 'ebox--window-size-change))
        (let ((window (get-buffer-window buffer t)))
          (when (window-live-p window)
            (ebox--window-size-change (window-frame window))))))
    text))

(defun ebox--input-session-covers-p (beg end)
  "Return non-nil when the active session's span contains BEG through END.
BEG and END delimit a host modification; an insertion has equal bounds.
The span is taken from the before-change capture when present, because a
deletion that removes the whole span collapses its end marker."
  (let ((session ebox--input-session))
    (when session
      (let* ((captured ebox--input-session-before)
             (start (if captured
                        (car captured)
                      (marker-position (ebox--input-session-start session))))
             (finish (if captured
                         (cdr captured)
                       (marker-position (ebox--input-session-end session)))))
        (and (numberp start) (numberp finish)
             (<= start beg)
             (<= end finish))))))

(provide 'ebox-input)
;;; ebox-input.el ends here
