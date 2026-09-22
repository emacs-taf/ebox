;;; ebox-drag-tests.el --- Public native drag behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Drive generated native keymaps with Emacs events and observe published output.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'ebox)

(defun ebox-drag-test--input (map &optional reversed)
  "Build a keyed draggable node with MAP, optionally REVERSED with its peer."
  (let ((nodes `((box :key drag :id "drag" :keymap ,map "Drag")
                 (text :key peer "Peer"))))
    (ebox-build `(column :key root :width (px 80)
                         ,@(if reversed (reverse nodes) nodes)
                         (text :key status :id "status" "0")))))

(defun ebox-drag-test--event (kind window point xy &optional endpoint)
  "Return KIND at WINDOW/POINT and XY, optionally ending at ENDPOINT."
  (append (list kind (list window point xy 0))
          (when endpoint (list (list window point endpoint 1)))))

(defun ebox-drag-test--run (buffer events)
  "Press BUFFER's Drag text and supply native EVENTS to its generated command."
  (save-window-excursion
    (set-window-buffer (selected-window) buffer)
    (with-current-buffer buffer
      (goto-char (point-min))
      (search-forward "Drag")
      (let* ((position (match-beginning 0))
             (press (ebox-drag-test--event 'down-mouse-1 (selected-window) position '(1 . 1)))
             (command (key-binding (vector press) nil nil position)))
        (cl-letf (((symbol-function 'read-event)
                   (lambda (&rest _) (if events (pop events) ?q))))
          (funcall command press))))))

(ert-deftest ebox-drag-follows-keyed-owner-and-publishes-release ()
  "Movement and release keep the same owner while its published position changes."
  (let ((buffer (generate-new-buffer " *ebox-drag*")) phases targets map)
    (unwind-protect
        (progn
          (setq map
                (ebox-keymap-create
                 :drag
                 (lambda (gesture)
                   (push (plist-get gesture :phase) phases)
                   (when (memq (plist-get gesture :phase) '(start move))
                     (should (= 1 (length (ebox-selector-query-buffer buffer "#drag:active")))))
                   (let ((bounds (ebox-host-ref-bounds buffer (plist-get gesture :host-ref))))
                     (push (buffer-substring-no-properties (car bounds) (cdr bounds)) targets))
                   (when (eq (plist-get gesture :phase) 'move)
                     (ebox-commit buffer (ebox-drag-test--input map t)))
                   (when (memq (plist-get gesture :phase) '(move end))
                     (ebox-region-update "status" :content
                                         (number-to-string (car (plist-get gesture :delta))))))))
          (ebox-render-to-buffer buffer (ebox-drag-test--input map))
          (let ((window (selected-window)))
            (ebox-drag-test--run
             buffer (list (ebox-drag-test--event 'mouse-movement window 1 '(4 . 3))
                          (ebox-drag-test--event 'drag-mouse-1 window 1 '(1 . 1) '(7 . 4)))))
          (should (equal (reverse phases) '(start move end)))
          (should-not (ebox-selector-query-buffer buffer ":active"))
          (should (cl-every (lambda (text) (string-match-p "Drag" text)) targets))
          (with-current-buffer buffer
            (should (string-match-p "Peer.*\nDrag.*\n6" (buffer-string)))))
      (kill-buffer buffer))))

(ert-deftest ebox-drag-cancels-disabled-target-and-preserves-unrelated-input ()
  "Disabled owners end tracking; unrelated keys return to the native command loop."
  (dolist (disable '(nil t))
    (let ((buffer (generate-new-buffer " *ebox-drag-cancel*"))
          (unread-command-events nil) phases reason)
      (unwind-protect
          (let ((map (ebox-keymap-create
                      :drag (lambda (gesture)
                              (push (plist-get gesture :phase) phases)
                              (when (and disable (eq (plist-get gesture :phase) 'move))
                                (ebox-region-update "drag" :disabled t))
                              (when (eq (plist-get gesture :phase) 'cancel)
                                (setq reason (plist-get gesture :reason)))))))
            (ebox-render-to-buffer buffer (ebox-drag-test--input map))
            (ebox-drag-test--run
             buffer (list (ebox-drag-test--event 'mouse-movement (selected-window) 1 '(3 . 2)) ?x))
            (should (equal (reverse phases) '(start move cancel)))
            (should (eq reason (if disable 'target-unavailable 'input)))
            (unless disable (should (equal unread-command-events '(?x)))))
        (kill-buffer buffer)))))

(ert-deftest ebox-drag-lock-modifier-keeps-gesture-after-release ()
  "Shift-down starts a locked drag whose next click publishes the end phase."
  (let ((buffer (generate-new-buffer " *ebox-drag-lock*")) phases)
    (unwind-protect
        (progn
          (let ((map (ebox-keymap-create
                      :drag-lock-modifier 'shift
                      :drag (lambda (gesture)
                              (push (plist-get gesture :phase) phases)))))
            (ebox-render-to-buffer buffer (ebox-drag-test--input map))
            (save-window-excursion
              (set-window-buffer (selected-window) buffer)
              (with-current-buffer buffer
                (goto-char (point-min))
                (search-forward "Drag")
                (let* ((position (match-beginning 0))
                       (window (selected-window))
                       (data (list window position '(1 . 1) 0))
                       (press (list 'S-down-mouse-1 data))
                       (command (lookup-key map [down-mouse-1]))
                       (events (list
                                (ebox-drag-test--event 'mouse-movement window
                                                       position '(4 . 3))
                                (ebox-drag-test--event 'drag-mouse-1 window
                                                       position '(4 . 3) '(7 . 4))
                                (list 'S-down-mouse-1 data)
                                (list 'mouse-1 data))))
                  (cl-letf (((symbol-function 'read-event)
                             (lambda (&rest _) (or (pop events) ?q))))
                    (funcall command press)))))
            (should (equal (reverse phases) '(start move move end)))
            (should-not (ebox-selector-query-buffer buffer ":active")))
      (kill-buffer buffer)))))

(ert-deftest ebox-drag-cancels-when-leaving-the-original-window ()
  "A pointer outside the original text area cancels without moving the target."
  (let ((buffer (generate-new-buffer " *ebox-drag-outside*")) phases reason)
    (unwind-protect
        (let ((map (ebox-keymap-create
                    :drag (lambda (gesture)
                            (push (plist-get gesture :phase) phases)
                            (setq reason (plist-get gesture :reason))))))
          (ebox-render-to-buffer buffer (ebox-drag-test--input map))
          (ebox-drag-test--run
           buffer (list (ebox-drag-test--event 'mouse-movement (selected-window) 1 '(100000 . 1))))
          (should (equal (reverse phases) '(start cancel)))
          (should (eq reason 'window-left)))
      (kill-buffer buffer))))

(ert-deftest ebox-drag-releases-removed-owners-and-lost-windows ()
  "Deletion, unmount and a switched window end a resting gesture promptly."
  (dolist (change '(delete unmount window))
    (let ((buffer (generate-new-buffer " *ebox-drag-lifetime*")) phases reason)
      (unwind-protect
          (let ((map
                 (ebox-keymap-create
                  :drag (lambda (gesture)
                          (push (plist-get gesture :phase) phases)
                          (pcase (plist-get gesture :phase)
                            ('start
                             (pcase change
                               ('delete (ebox-commit buffer (ebox-build '(text "Removed"))))
                               ('unmount (ebox-unmount-buffer buffer))
                               ('window (set-window-buffer (plist-get gesture :window)
                                                           (get-buffer-create "*scratch*")))))
                            ('cancel (setq reason (plist-get gesture :reason))))))))
            (ebox-render-to-buffer buffer (ebox-drag-test--input map))
            (ebox-drag-test--run buffer nil)
            (should (equal (reverse phases) '(start cancel)))
            (should (eq reason 'target-unavailable)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'ebox-drag-tests)
;;; ebox-drag-tests.el ends here
