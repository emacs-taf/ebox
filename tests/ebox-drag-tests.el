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
  "Press BUFFER's Drag text and supply native EVENTS to its generated command.
A function in EVENTS performs a read-time action and returns that read's event."
  (save-window-excursion
    (set-window-buffer (selected-window) buffer)
    (with-current-buffer buffer
      (goto-char (point-min))
      (search-forward "Drag")
      (let* ((position (match-beginning 0))
             (press (ebox-drag-test--event 'down-mouse-1 (selected-window) position '(1 . 1)))
             (command (key-binding (vector press) nil nil position)))
        (cl-letf (((symbol-function 'read-event)
                   (lambda (&optional _prompt _inherit seconds)
                     (cond
                      (unread-command-events (pop unread-command-events))
                      (events (let ((next (pop events)))
                                (if (functionp next) (funcall next) next)))
                      ((equal seconds 0) nil)
                      (t ?q)))))
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
                             (lambda (&optional _prompt _inherit seconds)
                               (cond (unread-command-events (pop unread-command-events))
                                     (events (pop events))
                                     ((equal seconds 0) nil)
                                     (t ?q)))))
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

(ert-deftest ebox-drag-coalesces-bounded-bursts-and-keeps-release-position ()
  "A burst publishes its latest positions in bounded groups and its exact release."
  (let ((buffer (generate-new-buffer " *ebox-drag-burst*"))
        (unread-command-events nil) positions)
    (unwind-protect
        (let* ((window (selected-window))
               (release (ebox-drag-test--event 'drag-mouse-1 window 1 '(1 . 1) '(7 . 4)))
               (map (ebox-keymap-create
                     :drag (lambda (gesture)
                             (push (list (plist-get gesture :phase)
                                         (plist-get gesture :position)) positions)
                             (when (memq (plist-get gesture :phase) '(move end))
                               (ebox-region-update
                                "status" :content
                                (number-to-string (car (plist-get gesture :delta)))))))))
          (ebox-render-to-buffer buffer (ebox-drag-test--input map))
          (setq unread-command-events
                (append
                 (cl-loop for index from 1 to 130
                          collect (ebox-drag-test--event
                                   'mouse-movement window 1
                                   (cons (+ 2 (mod index 50)) 2)))
                 (list release)))
          (ebox-drag-test--run buffer nil)
          (should (equal (reverse positions)
                         '((start (1 . 1)) (move (16 . 2)) (move (30 . 2))
                           (move (32 . 2)) (end (7 . 4)))))
          (should-not unread-command-events)
          (with-current-buffer buffer
            (should (string-match-p "\n6[ \t]*\\'" (buffer-string)))))
      (kill-buffer buffer))))

(ert-deftest ebox-drag-preserves-input-barriers-and-remaining-event-order ()
  "Keys and another press stop coalescing and retain the complete remaining queue."
  (dolist (barrier (list ?x 'escape
                        (ebox-drag-test--event 'down-mouse-1 (selected-window) 1 '(5 . 3))))
    (let ((buffer (generate-new-buffer " *ebox-drag-barrier*"))
          (unread-command-events nil) positions reason)
      (unwind-protect
          (let* ((window (selected-window))
                 (remaining (list barrier ?y
                                  (ebox-drag-test--event 'mouse-movement window 1 '(6 . 3))
                                  (ebox-drag-test--event 'mouse-1 window 1 '(7 . 3))))
                 (map (ebox-keymap-create
                       :drag (lambda (gesture)
                               (push (list (plist-get gesture :phase)
                                           (plist-get gesture :position)) positions)
                               (setq reason (plist-get gesture :reason))))))
            (ebox-render-to-buffer buffer (ebox-drag-test--input map))
            (setq unread-command-events
                  (append (list (ebox-drag-test--event 'mouse-movement window 1 '(3 . 2))
                                (ebox-drag-test--event 'mouse-movement window 1 '(4 . 2)))
                          remaining))
            (ebox-drag-test--run buffer nil)
            (should (equal (reverse positions)
                           '((start (1 . 1)) (move (4 . 2)) (cancel (4 . 2)))))
            (should (eq reason 'input))
            (should (equal unread-command-events remaining)))
        (kill-buffer buffer)))))

(ert-deftest ebox-drag-treats-another-window-as-a-motion-barrier ()
  "A burst cannot cross another window and resume at a later original-window position."
  (let ((buffer (generate-new-buffer " *ebox-drag-window-barrier*"))
        (unread-command-events nil) positions reason)
    (unwind-protect
        (save-window-excursion
          (let* ((window (selected-window))
                 (other (split-window-below))
                 (remaining (list (ebox-drag-test--event 'mouse-movement window 1 '(6 . 2))
                                  (ebox-drag-test--event 'mouse-1 window 1 '(7 . 2))))
                 (map (ebox-keymap-create
                       :drag (lambda (gesture)
                               (push (list (plist-get gesture :phase)
                                           (plist-get gesture :position)) positions)
                               (setq reason (plist-get gesture :reason))))))
            (ebox-render-to-buffer buffer (ebox-drag-test--input map))
            (setq unread-command-events
                  (append (list (ebox-drag-test--event 'mouse-movement window 1 '(3 . 2))
                                (ebox-drag-test--event 'mouse-movement other 1 '(4 . 2)))
                          remaining))
            (ebox-drag-test--run buffer nil)
            (should (equal (reverse positions)
                           '((start (1 . 1)) (move (3 . 2)) (cancel (3 . 2)))))
            (should (eq reason 'window-left))
            (should (equal unread-command-events remaining))))
      (kill-buffer buffer))))

(ert-deftest ebox-drag-rechecks-target-after-wait-and-motion-poll ()
  "A target invalidated while reading input gets cancellation without another move."
  (dolist (poll '(nil t))
    (dolist (change '(disable hide delete unmount window narrow))
      (let ((buffer (generate-new-buffer " *ebox-drag-read-lifetime*"))
            (unread-command-events nil) phases reason)
        (unwind-protect
            (let* ((window (selected-window))
                   (map (ebox-keymap-create
                         :drag (lambda (gesture)
                                 (push (plist-get gesture :phase) phases)
                                 (setq reason (plist-get gesture :reason))))))
              (ebox-render-to-buffer buffer (ebox-drag-test--input map))
              (ebox-drag-test--run
               buffer
               (append
                (when poll (list (ebox-drag-test--event 'mouse-movement window 1 '(3 . 2))))
                (list (lambda ()
                        (pcase change
                          ('disable (ebox-region-update "drag" :disabled t))
                          ('hide (ebox-region-update "drag" :visibility 'hidden))
                          ('delete (ebox-commit buffer (ebox-build '(text "Removed"))))
                          ('unmount (ebox-unmount-buffer buffer))
                          ('window (set-window-buffer window (get-buffer-create "*scratch*")))
                          ('narrow (goto-char (point-max))
                                   (forward-line 0)
                                   (narrow-to-region (point) (point-max))))
                        ?x))))
              (should (equal (reverse phases) '(start cancel)))
              (should (eq reason 'target-unavailable))
              (should (equal unread-command-events '(?x))))
          (kill-buffer buffer))))))

(ert-deftest ebox-drag-locked-end-rejects-finishing-motion-and-release-position ()
  "A locked second press ends once; later motion and release cannot change its endpoint."
  (let ((buffer (generate-new-buffer " *ebox-drag-locked-end*"))
        (unread-command-events nil) positions)
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (let* ((window (selected-window))
                 (map (ebox-keymap-create
                       :drag-lock-modifier 'shift
                       :drag (lambda (gesture)
                               (push (list (plist-get gesture :phase)
                                           (plist-get gesture :position)) positions))))
                 (press (ebox-drag-test--event 'S-down-mouse-1 window 1 '(1 . 1))))
            (ebox-render-to-buffer buffer (ebox-drag-test--input map))
            (setq unread-command-events
                  (list (ebox-drag-test--event 'mouse-1 window 1 '(2 . 2))
                        (ebox-drag-test--event 'mouse-movement window 1 '(3 . 2))
                        (ebox-drag-test--event 'down-mouse-1 window 1 '(4 . 2))
                        (ebox-drag-test--event 'mouse-movement window 1 '(5 . 3))
                        (ebox-drag-test--event 'drag-mouse-1 window 1 '(4 . 2) '(7 . 4))))
            (cl-letf (((symbol-function 'read-event)
                       (lambda (&rest _) (pop unread-command-events))))
              (funcall (lookup-key map [down-mouse-1]) press))
            (should (equal (reverse positions)
                           '((start (1 . 1)) (move (2 . 2)) (move (3 . 2)) (end (4 . 2)))))
            (should-not unread-command-events)
            (should-not (ebox-selector-query-buffer buffer ":active"))))
      (kill-buffer buffer))))

(ert-deftest ebox-drag-locked-escape-preserves-later-input ()
  "Escape terminates a locked burst before subsequent input is consumed."
  (let ((buffer (generate-new-buffer " *ebox-drag-locked-escape*"))
        (unread-command-events nil) phases reason)
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (let* ((window (selected-window))
                 (remaining (list (ebox-drag-test--event 'mouse-movement window 1 '(6 . 3)) ?x))
                 (map (ebox-keymap-create
                       :drag-lock-modifier 'shift
                       :drag (lambda (gesture)
                               (push (plist-get gesture :phase) phases)
                               (setq reason (plist-get gesture :reason)))))
                 (press (ebox-drag-test--event 'S-down-mouse-1 window 1 '(1 . 1))))
            (ebox-render-to-buffer buffer (ebox-drag-test--input map))
            (setq unread-command-events
                  (append (list (ebox-drag-test--event 'mouse-1 window 1 '(2 . 2))
                                (ebox-drag-test--event 'mouse-movement window 1 '(3 . 2))
                                ?\e)
                          remaining))
            (cl-letf (((symbol-function 'read-event)
                       (lambda (&rest _) (pop unread-command-events))))
              (funcall (lookup-key map [down-mouse-1]) press))
            (should (equal (reverse phases) '(start move move cancel)))
            (should (eq reason 'quit))
            (should (equal unread-command-events remaining))))
      (kill-buffer buffer))))

(ert-deftest ebox-drag-prepared-geometry-retains-and-releases-active-owner ()
  "Prepared row moves preserve a held owner until accepted occlusion cancels it."
  (let ((buffer (generate-new-buffer " *ebox-drag-prepared*"))
        (unread-command-events nil) operation phases ref reason (moves 0))
    (unwind-protect
        (let ((map
               (ebox-keymap-create
                :drag (lambda (gesture)
                        (push (plist-get gesture :phase) phases)
                        (setq ref (plist-get gesture :host-ref))
                        (pcase (plist-get gesture :phase)
                          ('start
                           (setq operation (ebox-geometry-prepare buffer ref [:left :top :z-index]))
                           (should operation))
                          ('move
                           (cl-incf moves)
                           (should (ebox-geometry-apply
                                    operation (if (= moves 1)
                                                  [(px 4) (lh 3) 2]
                                                [(px 2) (lh 1) 0])))
                           (if (= moves 1)
                               (progn
                                 (should (ebox-host-ref-bounds buffer ref))
                                 (should (= 1 (length (ebox-selector-query-buffer buffer "#drag:active")))))
                             (should-not (ebox-host-ref-bounds buffer ref))
                             (should-not (ebox-selector-query-buffer buffer ":active"))))
                          ('cancel (setq reason (plist-get gesture :reason))))))))
          (ebox-render-to-buffer
           buffer
           (ebox-build
            `(box :width (px 80) :height (lh 8)
                  (box :id "drag" :key drag :position absolute
                       :left (px 2) :top (lh 1) :width (px 20) :height (lh 2)
                       :z-index 2 :keymap ,map "Drag")
                  (box :id "peer" :position absolute
                       :left (px 2) :top (lh 1) :width (px 20) :height (lh 2)
                       :z-index 1 "Peer"))))
          (let ((window (selected-window)))
            (ebox-drag-test--run
             buffer (list (ebox-drag-test--event 'mouse-movement window 1 '(3 . 2))
                          nil
                          (ebox-drag-test--event 'mouse-movement window 1 '(5 . 3))
                          nil
                          (ebox-drag-test--event 'mouse-1 window 1 '(7 . 4)))))
          (should (equal (reverse phases) '(start move move cancel)))
          (should (eq reason 'target-unavailable))
          (should-not (ebox-selector-query-buffer buffer ":active")))
      (kill-buffer buffer))))

(provide 'ebox-drag-tests)
;;; ebox-drag-tests.el ends here
