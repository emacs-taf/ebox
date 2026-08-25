;;; ebox-viewport.el --- Coalesced Emacs viewport delivery -*- lexical-binding: t; -*-

;;; Commentary:
;; Emacs owns window events; Ebox owns the mounted viewport.  This module is
;; the single bridge between them.  Size hooks only sample the latest visible
;; dimensions.  One deferred callback per buffer publishes the newest sample,
;; so continuous frame dragging cannot enqueue synchronous layout transactions.

;;; Code:

(require 'cl-lib)
(require 'ebox-surface)

(declare-function ebox--buffer-render-state "ebox-incremental" (buffer))
(declare-function ebox-rerender-buffer-with-context
                  "ebox" (buffer viewport-width &optional viewport-height))

(defcustom ebox-viewport-resize-delay 0.05
  "Seconds after the latest size event before publishing its viewport.
Continuous size events replace one pending sample for each mounted buffer."
  :type 'number
  :group 'ebox)

(defvar ebox--viewport-resize-pending-table (make-hash-table :test #'eq)
  "Buffer-keyed latest viewport samples awaiting publication.")

(defvar ebox--viewport-resize-generation 0
  "Monotonic identity for pending viewport samples.")

(defun ebox-viewport-window-width (window)
  "Return Ebox's display-safe viewport width for live WINDOW."
  (and (window-live-p window)
       (ebox-surface--window-content-width window)))

(defun ebox--cancel-buffer-viewport-resize (buffer)
  "Cancel BUFFER's pending viewport publication."
  (when-let* ((pending (gethash buffer ebox--viewport-resize-pending-table)))
    (let ((timer (aref pending 4)))
      (when (timerp timer) (cancel-timer timer)))
    (remhash buffer ebox--viewport-resize-pending-table))
  nil)

(defun ebox--viewport-resize-apply (buffer generation)
  "Publish BUFFER's pending viewport identified by GENERATION."
  (when-let* ((pending (gethash buffer ebox--viewport-resize-pending-table)))
    (when (= generation (aref pending 0))
      (remhash buffer ebox--viewport-resize-pending-table)
      (let ((window (aref pending 1))
            (width (aref pending 2))
            (height (aref pending 3)))
        (when (and (buffer-live-p buffer)
                   (window-live-p window)
                   (eq (window-buffer window) buffer)
                   (ebox-surface-buffer-mounted-p buffer))
          (let ((state (ebox--buffer-render-state buffer)))
            (unless (and (= width (or (plist-get state :viewport-width) -1))
                         (= height (or (plist-get state :viewport-height) -1)))
              (ebox-rerender-buffer-with-context buffer width height))))))))

(defun ebox--schedule-buffer-viewport-resize
    (buffer window width height)
  "Replace BUFFER's pending viewport with WINDOW, WIDTH, and HEIGHT."
  (ebox--cancel-buffer-viewport-resize buffer)
  (let* ((generation (cl-incf ebox--viewport-resize-generation))
         (pending (vector generation window width height nil)))
    (puthash buffer pending ebox--viewport-resize-pending-table)
    (aset pending 4
          (run-at-time
           (max 0 ebox-viewport-resize-delay) nil
           #'ebox--viewport-resize-apply buffer generation)))
  buffer)

(defun ebox--window-size-change (frame)
  "Sample latest viewports for mounted Ebox buffers visible in FRAME."
  (when (and (frame-live-p frame) (not noninteractive))
    (let ((seen (make-hash-table :test #'eq)))
      (dolist (window (window-list frame 'no-minibuf))
        (when (window-live-p window)
          (let ((buffer (window-buffer window)))
            (unless (gethash buffer seen)
              (puthash buffer t seen)
              (when (and (buffer-live-p buffer)
                         (ebox-surface-buffer-mounted-p buffer))
                (let* ((state (ebox--buffer-render-state buffer))
                       (width (ebox-viewport-window-width window))
                       (height (window-body-height window)))
                  (when (and width
                             state
                             (not (and
                                   (= width
                                      (or (plist-get state :viewport-width) -1))
                                   (= height
                                      (or (plist-get state :viewport-height)
                                          -1)))))
                    (ebox--schedule-buffer-viewport-resize
                     buffer window width height)))))))))))

(when (boundp 'window-size-change-functions)
  (add-hook 'window-size-change-functions #'ebox--window-size-change))

(provide 'ebox-viewport)

;;; ebox-viewport.el ends here
