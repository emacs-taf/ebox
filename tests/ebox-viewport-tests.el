;;; ebox-viewport-tests.el --- Event-loop viewport delivery acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Verify the window-event bridge: transient UI that borrows displayed space
;; must not rerender a mounted viewport, and releasing that space settles the
;; canvas back onto the window geometry.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'ebox)

(defconst ebox-viewport-tests--scene
  '(box :width (px 60) :height (vh 100) :overflow hidden
        "a\nb\nc\nd\ne\nf\ng\nh")
  "Scene whose rendered text follows the canvas height.")

(defun ebox-viewport-tests--fresh-text (width height)
  "Return the scene's rendered text at viewport WIDTH and HEIGHT."
  (with-temp-buffer
    (let ((ebox-viewport-width width) (ebox-viewport-height height))
      (ebox-render-to-buffer (current-buffer)
                             (ebox-build ebox-viewport-tests--scene)))
    (substring-no-properties (buffer-string))))

(defun ebox-viewport-tests--text (buffer)
  "Return BUFFER's rendered text without properties."
  (with-current-buffer buffer
    (substring-no-properties (buffer-string))))

(defun ebox-viewport-tests--settle (frame)
  "Notify FRAME's size bridge and wait for its settle task.
Batch Emacs has no window manager or echo area; notify the framework the way
an interactive resize would."
  (let ((noninteractive nil))
    (run-hook-with-args 'window-size-change-functions frame))
  (sleep-for 0.4))

(defun ebox-viewport-tests--install (buffer)
  "Display BUFFER on the selected window and sync the scene into it."
  (set-frame-size (selected-frame) 80 25)
  (delete-other-windows)
  (set-window-buffer (selected-window) buffer)
  (let ((ebox-viewport-width 400) (ebox-viewport-height 20))
    (ebox-render-to-buffer buffer (ebox-build ebox-viewport-tests--scene)))
  (ebox-viewport-tests--settle (selected-frame)))

(ert-deftest ebox-viewport-keeps-its-height-while-transient-ui-borrows-space ()
  "Borrowed echo-area space is not a viewport resize."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *ebox-transient-viewport*"))
          (popup-buffer (generate-new-buffer " *ebox-transient-popup*")))
      (unwind-protect
          (progn
            (ebox-viewport-tests--install buffer)
            (let* ((window (get-buffer-window buffer t))
                   (width (ebox-viewport-window-width window))
                   (height (window-body-height window))
                   (popup (split-window window -1 'below)))
              (should (equal (ebox-viewport-tests--text buffer)
                             (ebox-viewport-tests--fresh-text width height)))
              (set-window-buffer popup popup-buffer)
              ;; The echo area borrows the bottom line while the minibuffer is
              ;; active, and the frame also loses one line.  Present the state
              ;; the hook sees during completion, then notify it the way a
              ;; resize would.
              (cl-letf (((symbol-function 'active-minibuffer-window)
                         (lambda () (minibuffer-window (selected-frame)))))
                (set-frame-size (selected-frame) 80 23)
                (ebox-viewport-tests--settle (selected-frame))
                ;; Borrowed space must not rerender the canvas.
                (should (equal (ebox-viewport-tests--text buffer)
                               (ebox-viewport-tests--fresh-text width height))))
              (when (window-live-p popup) (delete-window popup))
              ;; Releasing the space settles onto the restored window height.
              (ebox-viewport-tests--settle (selected-frame))
              (should (equal (ebox-viewport-tests--text buffer)
                             (ebox-viewport-tests--fresh-text
                              width (window-body-height window))))
              (should-not (equal (ebox-viewport-tests--text buffer)
                                 (ebox-viewport-tests--fresh-text width height)))))
        (when (buffer-live-p buffer) (ebox-unmount-buffer buffer))
        (when (buffer-live-p popup-buffer) (kill-buffer popup-buffer))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (set-frame-size (selected-frame) 80 25)))))

(provide 'ebox-viewport-tests)
;;; ebox-viewport-tests.el ends here
