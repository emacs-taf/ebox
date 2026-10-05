;;; ebox-viewport-tests.el --- Event-loop viewport delivery acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Verify the window-event bridge: transient UI that borrows displayed space
;; must not rerender a mounted viewport, while a frame resize still settles the
;; canvas onto the new window geometry.

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

(ert-deftest ebox-viewport-width-fills-the-window-content-box ()
  "The mounted canvas width is the window's content width.
A hidden reserve used to shrink every canvas by two character columns, which
read as a right-edge gap in every application; the published viewport must
equal the pixel body width whenever Emacs reports one."
  (let* ((window (selected-window))
         (body (window-body-width window t)))
    (when (and body (> body 0))
      (should (= (ebox-viewport-window-width window) body)))))

(ert-deftest ebox-viewport-keeps-its-height-while-transient-ui-borrows-space ()
  "Borrowed echo-area space is not a resize, while a frame resize still fits."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *ebox-transient-viewport*"))
          (popup-buffer (generate-new-buffer " *ebox-transient-popup*")))
      (unwind-protect
          (progn
            (set-frame-size (selected-frame) 80 25)
            (delete-other-windows)
            (set-window-buffer (selected-window) buffer)
            ;; Let a fresh split normalize the frame before the canvas exists,
            ;; so the borrowed height below changes only the window layout.
            (let ((popup (split-window (selected-window) -1 'below)))
              (set-window-buffer popup popup-buffer)
              (sleep-for 0.4)
              (let ((ebox-viewport-width 400) (ebox-viewport-height 20))
                (ebox-render-to-buffer buffer
                                       (ebox-build ebox-viewport-tests--scene)))
              ;; First delivery syncs the mounted canvas onto the window.
              (ebox-viewport-tests--settle (selected-frame))
              (unwind-protect
                  (let* ((window (get-buffer-window buffer t))
                         (width (ebox-viewport-window-width window))
                         (height (window-body-height window)))
                    (should (equal (ebox-viewport-tests--text buffer)
                                   (ebox-viewport-tests--fresh-text
                                    width height)))
                    ;; A completion popup borrows lines while the minibuffer is
                    ;; active.  Present the state the hook sees during
                    ;; completion, then notify it the way a resize would.
                    (window-resize popup 2)
                    ;; The borrowed window also reports a different content
                    ;; width; that must not defeat the borrowed-height guard.
                    (set-window-margins window 3 3)
                    (should-not (equal (ebox-viewport-window-width window)
                                       width))
                    (cl-letf (((symbol-function 'active-minibuffer-window)
                               (lambda () (minibuffer-window (selected-frame)))))
                      (ebox-viewport-tests--settle (selected-frame))
                      ;; Borrowed space must not rerender the canvas.
                      (should (equal (ebox-viewport-tests--text buffer)
                                     (ebox-viewport-tests--fresh-text
                                      width height)))
                      ;; A frame resize is user geometry even while that UI is
                      ;; present, so the canvas follows the new window.
                      (set-window-margins window 0 0)
                      (set-frame-size (selected-frame) 80 21)
                      (ebox-viewport-tests--settle (selected-frame))
                      (should (equal (ebox-viewport-tests--text buffer)
                                     (ebox-viewport-tests--fresh-text
                                      width (window-body-height window))))
                      (should-not (equal (ebox-viewport-tests--text buffer)
                                         (ebox-viewport-tests--fresh-text
                                          width height))))
                    ;; Releasing the space settles onto the restored height.
                    (delete-window popup)
                    (ebox-viewport-tests--settle (selected-frame))
                    (should (equal (ebox-viewport-tests--text buffer)
                                   (ebox-viewport-tests--fresh-text
                                    width (window-body-height window))))
                    (should-not (equal (ebox-viewport-tests--text buffer)
                                       (ebox-viewport-tests--fresh-text
                                        width height))))
                (when (window-live-p popup) (delete-window popup)))))
        (when (buffer-live-p buffer) (ebox-unmount-buffer buffer))
        (when (buffer-live-p popup-buffer) (kill-buffer popup-buffer))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (set-frame-size (selected-frame) 80 25)))))

(provide 'ebox-viewport-tests)
;;; ebox-viewport-tests.el ends here
