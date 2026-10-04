;;; ebox-viewport.el --- Event-loop viewport delivery -*- lexical-binding: t; -*-

;;; Commentary:
;; Emacs owns window events; Ebox owns the mounted viewport.  This module is
;; the single bridge between them.  Size hooks record frame intents; one task
;; samples current visible dimensions and publishes after the redisplay hook.

;;; Code:

(require 'cl-lib)
(require 'ebox-surface)

(declare-function ebox--buffer-render-state "ebox-incremental" (buffer))
(declare-function ebox-rerender-buffer-with-context
                  "ebox" (buffer viewport-width &optional viewport-height))

(defvar ebox--window-size-change-in-progress nil
  "Non-nil while Ebox is draining one batch of viewport notifications.")

(defvar ebox--window-size-change-pending-frames nil
  "Frames awaiting viewport synchronization, deduplicated by EQ.
The queue holds no buffers, runtime roots or sampled dimensions.")

(defvar ebox--viewport-frame-sizes (make-hash-table :test #'eq)
  "Last frame size seen by the viewport bridge, keyed by frame.
A frame resize stays a user resize even while transient UI borrows window
space; only a window-configuration change inside an unchanged frame is
borrowed.")

(defun ebox--viewport-frame-size (frame)
  "Return FRAME's size in character rows and columns, or nil."
  (when (frame-live-p frame)
    (cons (frame-width frame) (frame-height frame))))

(defun ebox--viewport-record-frame-size (frame)
  "Record FRAME's current character size for the viewport bridge guard."
  (when-let* ((size (ebox--viewport-frame-size frame)))
    (puthash frame size ebox--viewport-frame-sizes)))

(defvar ebox--window-size-change-timer nil
  "The single owned task scheduled to drain viewport notifications.")

(defvar ebox-viewport-settle-delay 0.12
  "Seconds of quiet after the last size change before Ebox reflows.
Dragging a frame edge fires size events faster than one reflow completes, so
rendering every event queues reflow after reflow and freezes the session.
Reschedule this trailing delay on each event; the drag then reflows once it
settles instead of once per intermediate size.")

(defun ebox-viewport-window-width (window)
  "Return Ebox's display-safe viewport width for live WINDOW."
  (and (window-live-p window)
       (ebox-surface--window-content-width window)))

(defun ebox--window-size-change-sync-frame (frame)
  "Synchronize current mounted Ebox viewports whose canonical window is in FRAME."
  (when (frame-live-p frame)
    (let ((seen (make-hash-table :test #'eq))
          (frame-size (ebox--viewport-frame-size frame))
          (frame-changed
           (not (equal (ebox--viewport-frame-size frame)
                       (gethash frame ebox--viewport-frame-sizes)))))
      (dolist (window (window-list frame 'no-minibuf))
        (when (window-live-p window)
          (let ((buffer (window-buffer window)))
            (unless (gethash buffer seen)
              (puthash buffer t seen)
              (let ((display-window
                     (and (buffer-live-p buffer)
                          (ebox-surface--buffer-display-window buffer))))
                (when (and (window-live-p display-window)
                           (eq (window-frame display-window) frame)
                           (ebox-surface-buffer-mounted-p buffer))
                  (let* ((state (ebox--buffer-render-state buffer))
                         (width (ebox-viewport-window-width display-window))
                         (height (window-body-height display-window))
                         (recorded-width (plist-get state :viewport-width))
                         (recorded-height (plist-get state :viewport-height)))
                    (when (and width
                               state
                               (not (and
                                     (= width
                                        (or recorded-width -1))
                                     (= height
                                        (or recorded-height -1))))
                               ;; Borrowed space is not a resize.  A height
                               ;; decrease while the minibuffer, a completion
                               ;; popup or the echo area is showing keeps the
                               ;; committed canvas even when the borrowed window
                               ;; also reports a different content width; only
                               ;; a frame change or height growth stays real
                               ;; geometry.
                               (not (and (not frame-changed)
                                         (ebox--viewport-transient-space-borrow-p
                                          frame)
                                         (< height (or recorded-height -1)))))
                      (ebox-rerender-buffer-with-context
                       buffer width height)))))))))
      (when frame-size
        (puthash frame frame-size ebox--viewport-frame-sizes)))))

(defun ebox--viewport-transient-space-borrow-p (frame)
  "Whether FRAME's transient UI currently borrows its displayed space.
An active minibuffer or completion popup, and a message in the echo area,
take lines from displayed windows without the user resizing the frame.  A
mounted viewport keeps its committed size until that UI releases them."
  (or (let ((minibuffer (active-minibuffer-window)))
        (and minibuffer
             (eq (window-frame minibuffer) frame)))
      (and (current-message) t)))

(defun ebox--window-size-change-schedule ()
  "Schedule one task for live pending frames outside the current batch."
  (setq ebox--window-size-change-pending-frames
        (cl-delete-if-not #'frame-live-p
                          ebox--window-size-change-pending-frames))
  (when (and ebox--window-size-change-pending-frames
             (not ebox--window-size-change-in-progress))
    (when ebox--window-size-change-timer
      (cancel-timer ebox--window-size-change-timer))
    (setq ebox--window-size-change-timer
          (run-at-time ebox-viewport-settle-delay nil
                       #'ebox--window-size-change-drain))))

(defun ebox--window-size-change-drain ()
  "Consume one frame batch, leaving nested notifications for a later task."
  (unless ebox--window-size-change-in-progress
    (let ((ebox--window-size-change-in-progress t)
          (frames (nreverse ebox--window-size-change-pending-frames))
          first-error)
      (unwind-protect
          (progn
            (setq ebox--window-size-change-pending-frames nil
                  ebox--window-size-change-timer nil)
            ;; Timer dispatch inhibits quit by default.  Enable C-g only after
            ;; cleanup is installed; Ebox publication retains its own final-accept protection.
            (let ((inhibit-quit nil))
              (while frames
                (let ((frame (pop frames)))
                  (condition-case failure
                      (ebox--window-size-change-sync-frame frame)
                    (error (unless first-error (setq first-error failure))))))))
        ;; A quit may leave unstarted frames.  Keep those intents, but do not
        ;; retry the frame whose publication already started and failed.
        (dolist (frame frames)
          (unless (memq frame ebox--window-size-change-pending-frames)
            (push frame ebox--window-size-change-pending-frames)))
        (let ((ebox--window-size-change-in-progress nil))
          (ebox--window-size-change-schedule)))
      (when first-error (signal (car first-error) (cdr first-error))))))

(defun ebox--window-size-change (frame)
  "Record FRAME's latest viewport intent without rendering inside the hook."
  (when (and (frame-live-p frame) (not noninteractive))
    (unless (memq frame ebox--window-size-change-pending-frames)
      (push frame ebox--window-size-change-pending-frames))
    (ebox--window-size-change-schedule)))

(defun ebox--window-size-change-minibuffer-exit ()
  "Recheck viewports once the minibuffer releases borrowed space.
A completion popup may close inside `minibuffer-exit-hook' while the exit is
still in progress, so the following settle re-reads the stable geometry."
  (dolist (frame (frame-list))
    (when (frame-live-p frame)
      (ebox--window-size-change frame))))

(when (boundp 'window-size-change-functions)
  (add-hook 'window-size-change-functions #'ebox--window-size-change))

(when (boundp 'minibuffer-exit-hook)
  (add-hook 'minibuffer-exit-hook #'ebox--window-size-change-minibuffer-exit))

(provide 'ebox-viewport)

;;; ebox-viewport.el ends here
