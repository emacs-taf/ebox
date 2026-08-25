;;; ebox-viewport.el --- Immediate Emacs viewport delivery -*- lexical-binding: t; -*-

;;; Commentary:
;; Emacs owns window events; Ebox owns the mounted viewport.  This module is
;; the single bridge between them.  Size hooks only sample the latest visible
;; dimensions and synchronously publish one exact incremental viewport update.
;; Emacs serializes the hook; Ebox's retained renderer bounds each transaction.

;;; Code:

(require 'ebox-surface)

(declare-function ebox--buffer-render-state "ebox-incremental" (buffer))
(declare-function ebox-rerender-buffer-with-context
                  "ebox" (buffer viewport-width &optional viewport-height))

(defvar ebox--window-size-change-in-progress nil
  "Non-nil while Ebox is synchronizing visible window viewports.
External GUI events cannot interleave in Emacs's single thread.  A nested call
can only originate from the current publication and therefore has no newer
window geometry to publish.")

(defun ebox-viewport-window-width (window)
  "Return Ebox's display-safe viewport width for live WINDOW."
  (and (window-live-p window)
       (ebox-surface--window-content-width window)))

(defun ebox--window-size-change (frame)
  "Synchronize mounted Ebox buffers visible in FRAME immediately."
  (when (and (frame-live-p frame)
             (not noninteractive)
             (not ebox--window-size-change-in-progress))
    (let ((ebox--window-size-change-in-progress t)
          (seen (make-hash-table :test #'eq)))
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
                         (height (window-body-height display-window)))
                    (when (and width
                               state
                               (not (and
                                     (= width
                                        (or (plist-get state :viewport-width)
                                            -1))
                                     (= height
                                        (or (plist-get state :viewport-height)
                                            -1)))))
                      (ebox-rerender-buffer-with-context
                       buffer width height))))))))))))

(when (boundp 'window-size-change-functions)
  (add-hook 'window-size-change-functions #'ebox--window-size-change))

(provide 'ebox-viewport)

;;; ebox-viewport.el ends here
