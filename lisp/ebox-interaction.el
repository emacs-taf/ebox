;;; ebox-interaction.el --- Keymaps, focus, pointer input and scrolling -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Interaction capabilities live on retained nodes.  Composition copies the
;; lines of an interactive node and fills unset `ebox-node', `keymap',
;; `help-echo', `pointer' and `mouse-face' properties, so the innermost node
;; wins and an ancestor's keymap reaches descendants without their own.
;; Focus and the held pointer target are mount state; they surface as the
;; derived selector states focus and active, and :disabled t derives disabled.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox-node)
(require 'ebox-layout)
(require 'ebox-buffer)

(define-error 'ebox-input-cancelled "Ebox input target is no longer available" 'quit)

;;;; Derived states

(defun ebox--interaction-states (node)
  "Return NODE's interaction-derived selector states."
  (let ((mount ebox--current-mount) states)
    (when (plist-get (ebox-node-inter node) :disabled) (push "disabled" states))
    (when mount
      (when (eq node (ebox-mount-active mount)) (push "active" states))
      (when (eq node (ebox-mount-focus mount)) (push "focus" states)))
    states))

(setq ebox--derived-states-function #'ebox--interaction-states)

;;;; Text properties of interactive nodes

(defconst ebox--hover-properties
  '(:color :background-color :font-weight :font-style :text-decoration-line
    :text-decoration-style :text-decoration-color)
  "Paint properties accepted by :hover-style.")

(defun ebox--hover-face (value)
  "Return the native mouse face for :hover-style VALUE."
  (unless (and (proper-list-p value) (zerop (% (length value) 2)))
    (signal 'ebox-error (list "Ebox :hover-style must be an even plist" value)))
  (let (face)
    (cl-loop for (key val) on value by #'cddr do
             (unless (memq key ebox--hover-properties)
               (signal 'ebox-error (list "Ebox :hover-style does not support" key)))
             (pcase key
               (:color (setq face (plist-put face :foreground val)))
               (:background-color (setq face (plist-put face :background val)))
               (:font-weight (setq face (plist-put face :weight (ebox--emacs-weight
                                                                 (ebox--css-weight val 400)))))
               (:font-style (setq face (plist-put face :slant val)))
               (:text-decoration-line
                (pcase val
                  ('underline (setq face (plist-put face :underline t)))
                  ('line-through (setq face (plist-put face :strike-through t)))
                  ('overline (setq face (plist-put face :overline t)))
                  ('none (setq face (append face '(:underline nil :overline nil
                                                   :strike-through nil))))))
               (:text-decoration-color
                (when (eq (plist-get face :underline) t)
                  (setq face (plist-put face :underline
                                        (list :color (if (eq val 'currentColor)
                                                         'foreground-color val))))))))
    face))

(defvar ebox--empty-keymap (make-sparse-keymap)
  "Keymap that blocks an ancestor's keymap on explicit nil.")

(defvar ebox--inter-cache (make-hash-table :test 'eq :weakness 'key)
  "Node to (INTER . TEXT-PROPERTIES) of its interaction capabilities.")

(defun ebox--inter-text-properties (node)
  "Return text properties painting NODE's interaction capabilities."
  (let* ((inter (ebox-node-inter node))
         (cached (gethash node ebox--inter-cache)))
    (if (and cached (eq (car cached) inter)) (cdr cached)
      (let ((props (list 'ebox-node node)))
        (when (plist-member inter :keymap)
          (setq props (append props
                              (list 'keymap
                                    (if (plist-get inter :disabled) ebox--empty-keymap
                                      (or (plist-get inter :keymap) ebox--empty-keymap))))))
        (when (and (plist-get inter :disabled) (not (plist-member inter :keymap)))
          (setq props (append props (list 'keymap ebox--empty-keymap))))
        (when (plist-get inter :help-echo)
          (setq props (append props (list 'help-echo (plist-get inter :help-echo)))))
        (when (plist-get inter :pointer)
          (setq props (append props (list 'pointer (plist-get inter :pointer)))))
        (when (plist-get inter :hover-style)
          (setq props (append props (list 'mouse-face
                                          (ebox--hover-face (plist-get inter :hover-style))))))
        (puthash node (cons inter props) ebox--inter-cache)
        props))))

(defun ebox--fill-property (string property value)
  "Put PROPERTY VALUE on the parts of STRING where it is unset."
  (let ((pos 0) (len (length string)))
    (while (< pos len)
      (let ((next (next-single-property-change pos property string len)))
        (unless (get-text-property pos property string)
          (put-text-property pos next property value string))
        (setq pos next)))))

(defun ebox--decorate-interactive (node line)
  "Return a copy of LINE carrying NODE's interaction properties."
  (let ((props (ebox--inter-text-properties node))
        (copy (copy-sequence line)))
    (when (and ebox--current-mount (plist-get (ebox-node-inter node) :hover-content))
      (setf (ebox-mount-hover-p ebox--current-mount) t))
    (while props
      (ebox--fill-property copy (car props) (cadr props))
      (setq props (cddr props)))
    copy))

(setq ebox--decorate-function #'ebox--decorate-interactive)

;;;; Liveness

(defun ebox--node-live-p (node mount)
  "Return non-nil when NODE is laid out under MOUNT's root.
A text node has no box of its own; it is live when its parent is."
  (and node mount
       (ebox-node-layout (if (ebox-node-text-p node)
                             (ebox-node-parent node)
                           node))
       (eq (ebox-node-root node) (ebox-mount-root mount))
       (buffer-live-p (ebox-mount-buffer mount))))

(defun ebox--node-visible-p (node)
  "Return non-nil when NODE and its ancestors paint."
  (let ((ok t))
    (while (and ok node)
      (when (or (null (ebox-node-cs node)) (ebox--hidden-p node)) (setq ok nil))
      (setq node (ebox-node-parent node)))
    ok))

(defun ebox--node-enabled-p (node)
  "Return non-nil unless NODE or an ancestor is disabled."
  (let ((ok t))
    (while (and ok node)
      (when (plist-get (ebox-node-inter node) :disabled) (setq ok nil))
      (setq node (ebox-node-parent node)))
    ok))

(defun ebox--mount-for (buffer-or-name)
  "Return the mount of BUFFER-OR-NAME or signal `user-error'."
  (or (ebox-buffer-mount buffer-or-name)
      (user-error "No mounted Ebox tree in %s"
                  (if buffer-or-name buffer-or-name (buffer-name)))))

(defun ebox--set-mount-state (mount slot node)
  "Set MOUNT's interaction SLOT (focus or active) to NODE and restyle."
  (let ((old (if (eq slot 'focus) (ebox-mount-focus mount) (ebox-mount-active mount))))
    (unless (eq old node)
      (if (eq slot 'focus)
          (setf (ebox-mount-focus mount) node)
        (setf (ebox-mount-active mount) node))
      (ebox-with-batch
        (when (ebox--node-live-p old mount) (ebox-node-restyle old))
        (when node (ebox-node-restyle node))))))

;;;; Keymaps

(defvar ebox--dispatching-activation nil
  "Non-nil while invoking a target already selected by Ebox activation.")

(defun ebox--declared-keymap (node)
  "Return the keymap NODE uses, inherited from its nearest declaring ancestor."
  (let (found done)
    (while (and node (not done))
      (let ((inter (ebox-node-inter node)))
        (cond
         ((plist-get inter :disabled) (setq done t))
         ((plist-member inter :keymap)
          (setq found (plist-get inter :keymap) done t))))
      (setq node (ebox-node-parent node)))
    found))

(defun ebox--keymap-owner (node)
  "Return NODE's nearest ancestor-or-self declaring a non-nil keymap."
  (let (found done)
    (while (and node (not done))
      (let ((inter (ebox-node-inter node)))
        (when (plist-member inter :keymap)
          (setq done t)
          (when (and (plist-get inter :keymap) (not (plist-get inter :disabled)))
            (setq found node))))
      (setq node (ebox-node-parent node)))
    found))

(defun ebox--focused-at-point ()
  "Return the focused node when point is at its first painted character."
  (let* ((mount ebox--buffer-mount)
         (focus (and mount (ebox-mount-focus mount))))
    (when (and (ebox--node-live-p focus mount)
               (eql (point) (ebox-node-position focus)))
      focus)))

(defun ebox--command (callback &optional activation-p)
  "Wrap CALLBACK as a command; ACTIVATION-P uses logical focus."
  (lambda (&optional event)
    (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
    (if (null event)
        (if (and activation-p (not ebox--dispatching-activation)
                 (ebox--focused-at-point))
            (ebox-activate)
          (funcall callback))
      (let* ((position (event-start event))
             (window (posn-window position)))
        (unless (and (window-live-p window) (null (posn-area position)))
          (user-error "Ebox activation requires a live text window"))
        (with-current-buffer (window-buffer window)
          (funcall callback))))))

(defun ebox-keymap-create (&rest options)
  "Create a native keymap from OPTIONS.
:activate is a zero-argument callback for RET, return, SPC and the primary
mouse button; :bindings is an alist of key descriptions or vectors paired with
zero-argument callbacks; :drag is a one-argument gesture callback and
:drag-lock-modifier names a modifier that keeps the gesture alive after
release.  See the Ebox Commentary for the gesture protocol."
  (unless (and (proper-list-p options) (zerop (% (length options) 2)))
    (error "Ebox keymap options must be an even plist"))
  (let ((map (make-sparse-keymap)) seen keys)
    (cl-loop for (key _value) on options by #'cddr do
             (unless (memq key '(:activate :bindings :drag :drag-lock-modifier))
               (error "Unknown Ebox keymap option: %S" key))
             (when (memq key seen)
               (error "Repeated Ebox keymap option: %S" key))
             (push key seen))
    (let ((activate (plist-get options :activate))
          (drag (plist-get options :drag))
          (lock (plist-get options :drag-lock-modifier))
          (bindings (plist-get options :bindings)))
      (when (and lock (not (memq lock '(shift control meta super hyper))))
        (error "Ebox :drag-lock-modifier must be a supported modifier: %S" lock))
      (when (and lock (not drag))
        (error "Ebox :drag-lock-modifier requires :drag"))
      (when (and drag (not (functionp drag)))
        (error "Ebox :drag callback must accept one gesture argument"))
      (unless (proper-list-p bindings)
        (error "Ebox keymap :bindings must be an alist"))
      (when activate
        (setq bindings (append (mapcar (lambda (key) (cons key activate))
                                       (if drag '("RET" [return] "SPC")
                                         '("RET" [return] "SPC" [mouse-1])))
                               bindings)))
      (dolist (entry bindings)
        (unless (and (consp entry) (functionp (cdr entry)))
          (error "Ebox keymap bindings require a key and a callback"))
        (let ((key (car entry)) (callback (cdr entry)))
          (unless (or (stringp key) (vectorp key))
            (error "Ebox keymap keys must be strings or vectors"))
          (unless (or (autoloadp (indirect-function callback))
                      (zerop (car (func-arity callback))))
            (error "Ebox keymap callbacks must accept zero arguments"))
          (setq key (vconcat (kbd (if (stringp key) key (key-description key)))))
          (when (zerop (length key))
            (error "Ebox keymap keys must not be empty"))
          (when (cl-some (lambda (other)
                           (let ((n (min (length key) (length other))))
                             (equal (cl-subseq key 0 n) (cl-subseq other 0 n))))
                         keys)
            (error "Ebox keymap binding overlaps an existing key: %s"
                   (key-description key)))
          (define-key map key
                      (ebox--command callback
                                     (and activate
                                          (member key '([13] [return] [32] [mouse-1])))))
          (push key keys)))
      (when (or activate drag)
        ;; Claim the whole primary-button sequence so presses do not start
        ;; region selection and modifier presses do not reach global commands.
        (dolist (event (append
                        '(mouse-1 double-mouse-1 triple-mouse-1
                          down-mouse-1 double-down-mouse-1 triple-down-mouse-1
                          drag-mouse-1 double-drag-mouse-1 triple-drag-mouse-1)
                        (cl-loop for modifier in '(shift control meta super hyper)
                                 append (mapcar
                                         (lambda (base)
                                           (event-convert-list (list modifier base)))
                                         '(down-mouse-1 mouse-1 drag-mouse-1)))))
          (unless (lookup-key map (vector event))
            (define-key map (vector event)
                        (cond
                         ((and drag (memq 'down (event-modifiers event)))
                          (lambda (press)
                            (interactive (list last-input-event))
                            (ebox--track-drag
                             press drag nil
                             (and lock (memq lock (event-modifiers press))))))
                         ((and activate (not drag)
                               (memq event '(double-mouse-1 triple-mouse-1)))
                          (lookup-key map [mouse-1]))
                         ((and activate (memq 'down (event-modifiers event)))
                          (lambda (press)
                            (interactive (list last-input-event))
                            (ebox--track-press press)))
                         (t #'ignore)))))))
    map))

(defun ebox-help-create (function)
  "Adapt zero-argument FUNCTION to a native `help-echo' callback.
The help object's buffer becomes current while FUNCTION runs; it must return
a string or nil."
  (unless (and (functionp function)
               (or (autoloadp (indirect-function function))
                   (zerop (car (func-arity function)))))
    (error "Ebox help requires a zero-argument function"))
  (lambda (window object _position)
    (let ((buffer (cond ((bufferp object) object)
                        ((overlayp object) (overlay-buffer object))
                        ((and (stringp object) (window-live-p window))
                         (window-buffer window)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((value (funcall function)))
            (unless (or (null value) (stringp value))
              (error "Ebox help function must return a string or nil"))
            value))))))

;;;; Activation

(defun ebox-activate (&optional position noerror)
  "Invoke the RET binding of the node at POSITION, defaulting to point.
With nil POSITION, the focused node wins while point is at its first painted
character.  Signal `user-error' when there is no command, or return nil when
NOERROR is non-nil."
  (interactive)
  (let* ((focused (and (null position) (ebox--focused-at-point)))
         (position (or position (point)))
         (map (cond
               (focused (ebox--declared-keymap focused))
               ((and (integer-or-marker-p position)
                     (<= (point-min) position) (< position (point-max))
                     (not (eq (char-after position) ?\n)))
                (get-text-property position 'keymap))))
         (command (and (keymapp map) (lookup-key map (kbd "RET")))))
    (if (commandp command)
        (let ((last-input-event ?\r)
              (ebox--dispatching-activation t))
          (command-execute command))
      (unless noerror (user-error "No Ebox RET command at position")))))

;;;; Pointer gestures

(defvar ebox--drag-active nil
  "Non-nil inside the primary-button tracking loop.")

(defun ebox--drag-position (position window)
  "Return POSITION's text-area pixels inside WINDOW, or nil."
  (let ((xy (posn-x-y position)) (edges (window-inside-pixel-edges window)))
    (when (and (eq (posn-window position) window) (null (posn-area position))
               (consp xy) (numberp (car xy)) (numberp (cdr xy))
               (<= 0 (car xy)) (< (car xy) (- (nth 2 edges) (nth 0 edges)))
               (<= 0 (cdr xy)) (< (cdr xy) (- (nth 3 edges) (nth 1 edges))))
      xy)))

(defun ebox--event-owner (position)
  "Return the keymap owner node painted at buffer POSITION."
  (when (and (integer-or-marker-p position)
             (<= (point-min) position) (< position (point-max)))
    (let ((node (get-text-property position 'ebox-node)))
      (and node (ebox--keymap-owner node)))))

(defun ebox--track-drag (event callback &optional defer-active lock)
  "Track primary-button EVENT on its owner, calling CALLBACK per phase.
DEFER-ACTIVE delays the active state until the first motion.  LOCK keeps the
gesture alive after the first release until the next press."
  (when ebox--drag-active
    (user-error "An Ebox drag is already active"))
  (let* ((press (event-start event)) (window (posn-window press)))
    (unless (and (window-live-p window) (null (posn-area press)))
      (user-error "Ebox drag requires a live text window"))
    (let* ((buffer (window-buffer window))
           (mount (ebox-buffer-mount buffer))
           (start (ebox--drag-position press window))
           (owner (and mount start
                       (with-current-buffer buffer
                         (ebox--event-owner (posn-point press)))))
           (button (event-basic-type event))
           (position start) (last-event event) (reason 'input)
           (ebox--drag-active t)
           (mouse-fine-grained-tracking t)
           started finished active locked finishing)
      (cl-labels
          ((available ()
             (and (window-live-p window) (eq (window-buffer window) buffer)
                  (eq (ebox-buffer-mount buffer) mount)
                  (ebox--node-live-p owner mount)
                  (ebox--node-visible-p owner)
                  (ebox--node-enabled-p owner)))
           (emit (phase)
             (with-current-buffer (if (buffer-live-p buffer) buffer (current-buffer))
               (funcall callback
                        (list :phase phase :event last-event :node owner
                              :window window :buffer buffer
                              :start (cons (car start) (cdr start))
                              :position (cons (car position) (cdr position))
                              :delta (cons (- (car position) (car start))
                                           (- (cdr position) (cdr start)))
                              :reason (and (eq phase 'cancel) reason))))))
        (when (and owner (available))
          (unwind-protect
              (condition-case problem
                  (progn
                    (unless defer-active
                      (ebox--set-mount-state mount 'active owner)
                      (setq active t))
                    (setq started t)
                    (emit 'start)
                    (track-mouse
                      (let ((track-mouse 'dragging) done)
                        (while (and (not done) (or finishing (available)))
                          (when-let* ((next (read-event nil nil 0.05)))
                            (unless (or finishing (available))
                              (push next unread-command-events)
                              (setq reason 'target-unavailable done t))
                            (when (and (not done) (not finishing)
                                       (mouse-movement-p next)
                                       (ebox--drag-position (event-start next) window))
                              ;; Merge already pending motions, bounded per round.
                              (let ((count 1) (poll t))
                                (while (and poll (< count 64))
                                  (let ((candidate (read-event nil nil 0)))
                                    (cond
                                     ((null candidate) (setq poll nil))
                                     ((and (mouse-movement-p candidate)
                                           (ebox--drag-position (event-start candidate) window))
                                      (setq next candidate count (1+ count)))
                                     (t (push candidate unread-command-events)
                                        (setq poll nil)))))))
                            (setq last-event next)
                            (unless done
                              (let* ((modifiers (event-modifiers next))
                                     (primary-down (and (eq (event-basic-type next) button)
                                                        (memq 'down modifiers)))
                                     (release (and (eq (event-basic-type next) button)
                                                   (not (memq 'down modifiers))))
                                     (motion (mouse-movement-p next)))
                                (cond
                                 ((and locked (or (eq (event-basic-type next) 'escape)
                                                  (equal next ?\e)))
                                  (setq reason 'quit done t))
                                 ((and finishing release) (setq done t))
                                 ((and finishing motion) nil)
                                 ((and locked primary-down)
                                  (if-let* ((xy (ebox--drag-position (event-start next) window)))
                                      (progn
                                        (setq position xy finished t finishing t locked nil)
                                        (emit 'end)
                                        (redisplay t))
                                    (push next unread-command-events)
                                    (setq reason 'window-left done t)))
                                 ((or release motion)
                                  (when (and defer-active motion (not active))
                                    (ebox--set-mount-state mount 'active owner)
                                    (setq active t))
                                  (let ((xy (ebox--drag-position
                                             (if release (event-end next) (event-start next))
                                             window)))
                                    (cond
                                     ((null xy) (setq reason 'window-left done t))
                                     (release
                                      (setq position xy)
                                      (if (and lock (not locked))
                                          (progn (setq locked t) (emit 'move))
                                        (setq finished t done t)
                                        (emit 'end)))
                                     ((not (equal xy position))
                                      (setq position xy)
                                      (emit 'move)))
                                    (redisplay t)))
                                 (t (push next unread-command-events)
                                    (setq reason 'input done t)))))))
                        (unless (or finished (available))
                          (setq reason 'target-unavailable)))))
                ((error quit)
                 (setq reason (if (eq (car problem) 'quit) 'quit 'error))
                 (signal (car problem) (cdr problem))))
            (unwind-protect
                (when (and started (not finished)) (emit 'cancel))
              (when (and active (eq (ebox-buffer-mount buffer) mount))
                (ebox--set-mount-state mount 'active nil)))))))))

(defun ebox--track-press (event)
  "Track primary-button EVENT until release; activate its owner when still hit."
  (let* ((window (posn-window (event-start event)))
         (buffer (and (window-live-p window) (window-buffer window)))
         (release-key (cond ((memq 'triple (event-modifiers event)) [triple-mouse-1])
                            ((memq 'double (event-modifiers event)) [double-mouse-1])
                            (t [mouse-1]))))
    (when (and buffer (ebox-buffer-mount buffer))
      (ebox--track-drag
       event
       (lambda (gesture)
         (when (eq (plist-get gesture :phase) 'end)
           (let* ((owner (plist-get gesture :node))
                  (mount (ebox-buffer-mount buffer))
                  (position (posn-point (event-end (plist-get gesture :event))))
                  (hit (with-current-buffer buffer (ebox--event-owner position))))
             (when (eq owner hit)
               (ebox--set-mount-state mount 'active nil)
               (when (eq window (selected-window))
                 (ignore-errors (ebox-focus owner buffer)))
               (let* ((map (ebox--declared-keymap owner))
                      (command (and (keymapp map) (lookup-key map release-key)))
                      (ebox--dispatching-activation t)
                      (last-input-event (plist-get gesture :event)))
                 (when (commandp command)
                   (with-current-buffer buffer (command-execute command))))))))
       t))))

;;;; Focus

(defun ebox--focusable-p (node mount)
  "Return non-nil when NODE can receive focus in MOUNT."
  (and (ebox--node-live-p node mount)
       (ebox--node-visible-p node)
       (ebox--node-enabled-p node)
       (> (or (plist-get (ebox-node-geometry node) :height) 0) 0)))

(defun ebox-focus (node &optional buffer-or-name)
  "Focus NODE in BUFFER-OR-NAME and move point to its first character.
Nil NODE clears focus.  Signal `user-error' when NODE cannot be focused."
  (let ((mount (ebox--mount-for buffer-or-name)))
    (when (and node (not (ebox--focusable-p node mount)))
      (user-error "Ebox node cannot receive focus"))
    (ebox--set-mount-state mount 'focus node)
    (when node
      (let ((position (ebox-node-position node)))
        (when position
          (with-current-buffer (ebox-mount-buffer mount)
            (goto-char position)
            (dolist (window (get-buffer-window-list (current-buffer) nil t))
              (set-window-point window position))))))
    node))

(defun ebox-focused-node (&optional buffer-or-name)
  "Return the focused node of BUFFER-OR-NAME, or nil."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (when mount
      (let ((focus (ebox-mount-focus mount)))
        (if (and focus (not (ebox--focusable-p focus mount)))
            (progn (setf (ebox-mount-focus mount) nil) nil)
          focus)))))

(defun ebox--tab-stops (mount &optional within)
  "Return MOUNT's focus stops in tab order, optionally only WITHIN a node."
  (let (stops)
    (ebox-node-walk (or within (ebox-mount-root mount))
                    (lambda (node)
                      (let ((index (plist-get (ebox-node-inter node) :tab-index)))
                        (when (and (integerp index) (>= index 0)
                                   (ebox--focusable-p node mount))
                          (let ((g (ebox-node-geometry node)))
                            (push (list node index (plist-get g :y) (plist-get g :x))
                                  stops))))))
    (mapcar #'car
            (sort (nreverse stops)
                  (lambda (a b)
                    (cond ((/= (nth 1 a) (nth 1 b)) (< (nth 1 a) (nth 1 b)))
                          ((/= (nth 2 a) (nth 2 b)) (< (nth 2 a) (nth 2 b)))
                          (t (< (nth 3 a) (nth 3 b)))))))))

(defun ebox--focus-move (count cycle buffer-or-name &optional within restart)
  "Move focus COUNT stops; CYCLE wraps.  WITHIN limits the stops to a subtree.
RESTART ignores the current focus."
  (let* ((mount (ebox--mount-for buffer-or-name))
         (stops (ebox--tab-stops mount within))
         (current (and (not restart) (ebox-focused-node buffer-or-name)))
         (index (and current (cl-position current stops))))
    (unless stops (user-error "No Ebox focus stop"))
    (if (and (eql count 0) (not restart))
        current
    (let* ((n (length stops))
           (target
            (cond
             ((null index) (if (< count 0) (+ n count) (max 0 (1- count))))
             (t (+ index count)))))
      (if cycle (setq target (mod target n))
        (unless (and (>= target 0) (< target n))
          (user-error "No %s Ebox focus stop" (if (< count 0) "previous" "next"))))
      (ebox-focus (nth target stops) buffer-or-name)))))

(defun ebox-focus-next (&optional count cycle buffer-or-name)
  "Move focus COUNT (default 1) tab stops forward; CYCLE wraps at the end."
  (interactive (list 1 t nil))
  (ebox--focus-move (or count 1) cycle buffer-or-name))

(defun ebox-focus-previous (&optional count cycle buffer-or-name)
  "Move focus COUNT (default 1) tab stops backward; CYCLE wraps at the start."
  (interactive (list 1 t nil))
  (ebox--focus-move (- (or count 1)) cycle buffer-or-name))

(defun ebox-focus-first (&optional buffer-or-name)
  "Focus the first tab stop of BUFFER-OR-NAME."
  (interactive)
  (ebox--focus-move 1 nil buffer-or-name nil t))

(defun ebox-focus-within (node &optional count cycle buffer-or-name)
  "Move focus among the tab stops inside NODE.
Nil COUNT focuses the first stop; integer COUNT moves relative to the current
focus when it lies inside NODE."
  (let* ((mount (ebox--mount-for buffer-or-name))
         (current (ebox-focused-node buffer-or-name))
         (inside (and current (ebox-node-ancestor-p node current))))
    (unless (ebox--node-live-p node mount)
      (user-error "Ebox focus root is not mounted"))
    (if (or (null count) (not inside))
        (ebox--focus-move (if (and count (< count 0)) -1 1) cycle buffer-or-name node t)
      (ebox--focus-move count cycle buffer-or-name node))))

;;;; Native input

(defun ebox-call-with-input (node reader &optional buffer-or-name)
  "Call zero-argument READER for visible, enabled NODE in BUFFER-OR-NAME.
Return its result when NODE is still available afterwards; otherwise signal
`ebox-input-cancelled'.  Logical focus is restored afterwards."
  (let* ((mount (ebox--mount-for buffer-or-name))
         (focus (ebox-mount-focus mount)))
    (unless (ebox--focusable-p node mount)
      (user-error "Ebox input target is not available"))
    (let (result)
      (unwind-protect
          (setq result (funcall reader))
        (when (and (eq (ebox-buffer-mount (ebox-mount-buffer mount)) mount)
                   (ebox--focusable-p focus mount))
          (ebox--set-mount-state mount 'focus focus)))
      (unless (and (eq (ebox-buffer-mount (ebox-mount-buffer mount)) mount)
                   (ebox--focusable-p node mount))
        (signal 'ebox-input-cancelled (list node)))
      result)))

;;;; Input sessions

(define-error 'ebox-input-error "Invalid Ebox input session" 'ebox-error)

(cl-defstruct (ebox--input-session (:constructor ebox--input-session-make)
                                   (:copier nil))
  "Native editing of one node's painted text."
  mount node start end original read-only)

(defun ebox-input-active-p (&optional buffer-or-name)
  "Return the active input session of BUFFER-OR-NAME, or nil."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (and mount (ebox-mount-session mount))))

(defun ebox-input-begin (buffer-or-name node)
  "Begin native editing of NODE's painted text in BUFFER-OR-NAME.
Return a session for `ebox-input-text' and `ebox-input-end'.  Pending
changes are written first.  While the session is active the buffer is
writable, the user edits the node's span directly, and flushes of this
mount are deferred, so typed text, point, selection and undo stay intact.
Tree mutations meanwhile are kept and written when the session ends.  An
unmounted buffer, a node without painted text and a second session are
`ebox-input-error's."
  (let ((mount (ebox-buffer-mount buffer-or-name)))
    (unless mount (signal 'ebox-input-error (list "Expected a mounted Ebox buffer")))
    (when (ebox-mount-session mount)
      (signal 'ebox-input-error (list "Buffer already has an input session")))
    (ebox-flush)
    (let ((bounds (and (ebox--node-live-p node mount) (ebox-node-bounds node))))
      (unless bounds
        (signal 'ebox-input-error (list "Node has no painted text to edit" node)))
      (with-current-buffer (ebox-mount-buffer mount)
        (let ((session (ebox--input-session-make
                        :mount mount :node node
                        :start (copy-marker (car bounds))
                        :end (copy-marker (cdr bounds) t)
                        :original (buffer-substring (car bounds) (cdr bounds))
                        :read-only buffer-read-only)))
          (setq buffer-read-only nil)
          (setf (ebox-mount-session mount) session)
          session)))))

(defun ebox--input-check (session)
  "Signal unless SESSION is an input session."
  (unless (ebox--input-session-p session)
    (signal 'ebox-input-error (list "Expected an input session" session))))

(defun ebox-input-text (session)
  "Return SESSION's current property-free text, or nil once released."
  (ebox--input-check session)
  (let ((start (marker-position (ebox--input-session-start session))))
    (when start
      (with-current-buffer (marker-buffer (ebox--input-session-start session))
        (buffer-substring-no-properties
         start (ebox--input-session-end session))))))

(defun ebox-input-session-node (session)
  "Return the node SESSION edits."
  (ebox--input-check session)
  (ebox--input-session-node session))

(defun ebox--input-release (session)
  "Detach SESSION from its mount and markers without touching text."
  (let ((mount (ebox--input-session-mount session)))
    (when (eq (ebox-mount-session mount) session)
      (setf (ebox-mount-session mount) nil))
    (set-marker (ebox--input-session-start session) nil)
    (set-marker (ebox--input-session-end session) nil)))

(defun ebox-input-end (session)
  "End SESSION, restore its painted text and return the user's text.
Deferred changes are then written.  Ending a released session, for example
after its buffer was unmounted, only returns nil."
  (ebox--input-check session)
  (let* ((mount (ebox--input-session-mount session))
         (buffer (ebox-mount-buffer mount))
         (live (and (eq (ebox-mount-session mount) session)
                    (buffer-live-p buffer)
                    (marker-position (ebox--input-session-start session))))
         text)
    (unwind-protect
        (when live
          (with-current-buffer buffer
            (let ((start (marker-position (ebox--input-session-start session)))
                  (finish (marker-position (ebox--input-session-end session))))
              (setq text (buffer-substring-no-properties start finish))
              (let ((inhibit-read-only t)
                    (inhibit-modification-hooks t))
                (save-excursion
                  (delete-region start finish)
                  (goto-char start)
                  (insert (ebox--input-session-original session))))
              (setq buffer-read-only (ebox--input-session-read-only session))
              ;; Line anchors inside the edited span collapsed with it.
              (ebox--rebuild-anchors mount))))
      (ebox--input-release session)
      (when (and live (ebox-mount-queued mount)
                 (eq (ebox-buffer-mount buffer) mount))
        (unless (memq mount ebox--queue) (push mount ebox--queue))
        (ebox--settle)))
    text))

;;;; Interaction navigation

(defun ebox--interaction-move (count)
  "Move point COUNT keymap owners forward (negative: backward)."
  (unless (ebox-buffer-mount) (user-error "Current buffer has no Ebox tree"))
  (if (zerop count) (point)
    (let* ((origin (point))
           (current (and (< origin (point-max)) (ebox--event-owner origin)))
           (seen (make-hash-table :test 'eq))
           (position (point-min)) stops)
      (while (< position (point-max))
        (let* ((end (next-single-property-change position 'ebox-node nil (point-max)))
               (owner (ebox--event-owner position)))
          (while (and (< position end) (eq (char-after position) ?\n))
            (setq position (1+ position)))
          (when (and owner (< position end) (not (gethash owner seen)))
            (puthash owner t seen)
            (push (cons position owner) stops))
          (setq position end)))
      (when (> count 0) (setq stops (nreverse stops)))
      (let* ((eligible (cl-remove-if-not
                        (lambda (stop)
                          (and (not (eq (cdr stop) current))
                               (if (> count 0) (> (car stop) origin) (< (car stop) origin))))
                        stops))
             (target (nth (1- (abs count)) eligible)))
        (unless target
          (user-error "No %s Ebox interaction" (if (> count 0) "next" "previous")))
        (goto-char (car target))))))

(defun ebox-next-interaction (&optional count)
  "Move point to the next keymap owner COUNT times; return the position."
  (interactive "p")
  (ebox--interaction-move (or count 1)))

(defun ebox-previous-interaction (&optional count)
  "Move point to the previous keymap owner COUNT times; return the position."
  (interactive "p")
  (ebox--interaction-move (- (or count 1))))

;;;; Hover content

(defun ebox--hover-target (node)
  "Return the text node whose content NODE's :hover-content replaces."
  (if (eq (ebox-node-tag node) 'text) node
    (let (found)
      (ebox--do-kids (child node)
        (when (and (not found) (eq (ebox-node-tag child) 'text))
          (setq found child)))
      found)))

(defun ebox--hover-group (node)
  "Return NODE's hover group key, or NODE itself."
  (or (plist-get (ebox-node-inter node) :hover-group) node))

(defun ebox--hover-owner (position)
  "Return the innermost node with :hover-content painted at POSITION."
  (let ((node (and (< position (point-max)) (get-text-property position 'ebox-node))))
    (while (and node (not (plist-get (ebox-node-inter node) :hover-content)))
      (setq node (ebox-node-parent node)))
    node))

(defun ebox--hover-members (mount group)
  "Return MOUNT's hover-content nodes in GROUP."
  (if (ebox-node-p group) (list group)
    (let (members)
      (ebox-node-walk (ebox-mount-root mount)
                      (lambda (node)
                        (let ((inter (ebox-node-inter node)))
                          (when (and (plist-get inter :hover-content)
                                     (equal (plist-get inter :hover-group) group))
                            (push node members)))))
      members)))

(defun ebox--hover-restore (mount)
  "Restore the text replaced by MOUNT's active hover group."
  (ebox-with-batch
    (dolist (entry (ebox-mount-hover-saved mount))
      (when (ebox-node-parent (car entry))
        (ebox-node-set-text (car entry) (cdr entry)))))
  (setf (ebox-mount-hover mount) nil
        (ebox-mount-hover-saved mount) nil))

(defun ebox--hover-activate (mount group)
  "Show the :hover-content of every member of GROUP in MOUNT."
  (let (saved)
    (ebox-with-batch
      (dolist (node (ebox--hover-members mount group))
        (let* ((target (ebox--hover-target node))
               (value (plist-get (ebox-node-inter node) :hover-content))
               (content (if (functionp value)
                            (with-current-buffer (ebox-mount-buffer mount) (funcall value))
                          value)))
          (when (and target (stringp content))
            (push (cons target (ebox-node-text target)) saved)
            (ebox-node-set-text target content)))))
    (setf (ebox-mount-hover mount) group
          (ebox-mount-hover-saved mount) saved)))

(defun ebox--hover-event (event)
  "Update hover content for mouse-movement EVENT."
  (interactive "e")
  (clear-this-command-keys)
  (let* ((position (event-end event))
         (window (and (consp position) (posn-window position)))
         (point (and (consp position) (posn-point position)))
         (buffer (and (window-live-p window) (window-buffer window)))
         (mount (and buffer (ebox-buffer-mount buffer))))
    (when (and mount (null (posn-area position)))
      (with-current-buffer buffer
        (let* ((owner (and (integer-or-marker-p point) (ebox--hover-owner point)))
               (group (and owner (ebox--hover-group owner))))
          (unless (equal group (ebox-mount-hover mount))
            (when (ebox-mount-hover mount) (ebox--hover-restore mount))
            (when group (ebox--hover-activate mount group))))))
    nil))

(defun ebox--hover-sync (buffer)
  "Enable local mouse tracking in BUFFER once it paints hover content."
  (with-current-buffer buffer
    (let ((mount ebox--buffer-mount))
      (when (and mount (ebox-mount-hover-p mount) (not (local-variable-p 'track-mouse)))
        (setq-local track-mouse t)))))

;;;; Scrolling

(defvar ebox-scroll-step 3
  "Lines scrolled by one wheel step or `ebox-scroll-down'.")

(defun ebox--scrollable-p (node)
  "Return non-nil when NODE clips scrollable content."
  (let ((geo (ebox-node-layout node)))
    (and geo (memq (ebox-cs-overflow (ebox-node-cs node)) '(scroll auto))
         (> (ebox-geo-ch geo) (ebox-geo-vh geo)))))

(defun ebox--scroll-chain (position)
  "Return scrollable nodes containing buffer POSITION, innermost first."
  (let ((node (and (integer-or-marker-p position) (ebox-node-at position)))
        chain)
    (while node
      (when (ebox--scrollable-p node) (push node chain))
      (setq node (if (and (ebox-node-cs node) (ebox--abs-p node))
                     (ebox-node-host node)
                   (ebox-node-parent node))))
    (nreverse chain)))

(defun ebox-node-scroll-offset (node)
  "Return NODE's scroll offset in lines."
  (ebox-node-scroll node))

(defun ebox-node-set-scroll (node offset)
  "Scroll NODE's content to OFFSET lines, clamped; return the applied offset."
  (let* ((geo (ebox-node-layout node))
         (limit (if geo (max 0 (- (ebox-geo-ch geo) (ebox-geo-vh geo))) 0))
         (offset (max 0 (min offset limit))))
    (unless (= offset (ebox-node-scroll node))
      (setf (ebox-node-scroll node) offset)
      (let ((mount (ebox--mount-of node)))
        (if (and geo mount (zerop (logand (ebox-node-dirty node) 15)))
            ;; Scrolling changes which content lines show, not the layout.
            (progn
              (setf (ebox-geo-scroll geo) offset)
              (push (list node 0 (ebox-node-h node) (ebox-node-h node))
                    (ebox-mount-report mount))
              (ebox--enqueue node))
          (ebox--mark node ebox--d-layout))
        (ebox--settle)))
    offset))

(defun ebox--scroll-by (delta position fallback)
  "Scroll the node chain at POSITION by DELTA lines; FALLBACK gets the rest."
  (let ((rest delta))
    (dolist (node (ebox--scroll-chain position))
      (unless (zerop rest)
        (let* ((old (ebox-node-scroll node))
               (new (ebox-node-set-scroll node (+ old rest))))
          (setq rest (- rest (- new old))))))
    (unless (zerop rest)
      (condition-case nil
          (funcall fallback rest)
        ((beginning-of-buffer end-of-buffer) nil)))))

(defun ebox-scroll-down (&optional n)
  "Scroll the content at point down by N lines (default `ebox-scroll-step')."
  (interactive "p")
  (ebox--scroll-by (or n ebox-scroll-step) (point)
                   (lambda (rest) (if (> rest 0) (scroll-up rest) (scroll-down (- rest))))))

(defun ebox-scroll-up (&optional n)
  "Scroll the content at point up by N lines (default `ebox-scroll-step')."
  (interactive "p")
  (ebox-scroll-down (- (or n ebox-scroll-step))))

(defun ebox--page-lines (arg)
  "Return the page size in lines for prefix ARG."
  (if arg (prefix-numeric-value arg)
    (max 1 (- (window-body-height) next-screen-context-lines))))

(defun ebox-scroll-page-down (&optional arg)
  "Scroll the content at point down by a page, or ARG lines."
  (interactive "P")
  (ebox-scroll-down (ebox--page-lines arg)))

(defun ebox-scroll-page-up (&optional arg)
  "Scroll the content at point up by a page, or ARG lines."
  (interactive "P")
  (ebox-scroll-up (ebox--page-lines arg)))

(defun ebox--wheel (event delta)
  "Scroll the content under wheel EVENT by DELTA lines."
  (let* ((start (event-start event))
         (window (posn-window start)))
    (if (and (window-live-p window) (null (posn-area start))
             (ebox-buffer-mount (window-buffer window)))
        (with-selected-window window
          (ebox--scroll-by delta (posn-point start)
                           (lambda (rest)
                             (if (> rest 0) (scroll-up rest) (scroll-down (- rest))))))
      (mwheel-scroll event))))

(defun ebox-wheel-scroll-down (event)
  "Scroll the content under wheel EVENT down."
  (interactive "e")
  (ebox--wheel event ebox-scroll-step))

(defun ebox-wheel-scroll-up (event)
  "Scroll the content under wheel EVENT up."
  (interactive "e")
  (ebox--wheel event (- ebox-scroll-step)))

;;;; Buffer mode

(defvar ebox-buffer-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (area '(nil right-fringe left-fringe right-margin left-margin))
      (let ((prefix (if area (vector area) [])))
        (dolist (event '(wheel-down double-wheel-down triple-wheel-down mouse-5))
          (define-key map (vconcat prefix (vector event)) #'ebox-wheel-scroll-down))
        (dolist (event '(wheel-up double-wheel-up triple-wheel-up mouse-4))
          (define-key map (vconcat prefix (vector event)) #'ebox-wheel-scroll-up))))
    (define-key map [remap scroll-up-command] #'ebox-scroll-page-down)
    (define-key map [remap scroll-down-command] #'ebox-scroll-page-up)
    (define-key map (kbd "n") #'ebox-scroll-down)
    (define-key map (kbd "p") #'ebox-scroll-up)
    (dolist (key '("C-v" "<next>" "<kp-next>" "SPC"))
      (define-key map (kbd key) #'ebox-scroll-page-down))
    (dolist (key '("M-v" "<prior>" "<kp-prior>" "S-SPC" "<backspace>"))
      (define-key map (kbd key) #'ebox-scroll-page-up))
    (define-key map (kbd "q") #'quit-window)
    (dolist (key '("TAB" "<tab>"))
      (define-key map (kbd key) (lambda () (interactive) (ebox-focus-next 1 t))))
    (dolist (key '("S-TAB" "<backtab>"))
      (define-key map (kbd key) (lambda () (interactive) (ebox-focus-previous 1 t))))
    (dolist (key '("RET" "<return>"))
      (define-key map (kbd key) #'ebox-activate))
    (define-key map [mouse-movement] #'ebox--hover-event)
    map)
  "Keymap of mounted Ebox buffers: scrolling, focus navigation and activation.")

(defconst ebox--scroll-overridden-modes '(pixel-scroll-precision-mode pixel-scroll-mode)
  "Minor modes whose wheel bindings Ebox buffers override locally.")

(defvar-local ebox--saved-overline-margin nil
  "Original local flag and value of `overline-margin' while the mode is on.")

(define-minor-mode ebox-buffer-mode
  "Minor mode for mounted Ebox buffers."
  :lighter " Ebox"
  :keymap ebox-buffer-mode-map
  (if ebox-buffer-mode
      (progn
        (unless ebox--saved-overline-margin
          (setq ebox--saved-overline-margin
                (cons (local-variable-p 'overline-margin) overline-margin)))
        ;; Overlines otherwise add ascent to rows with a top border.
        (setq-local overline-margin 0)
        (setq-local minor-mode-overriding-map-alist
                    (append (mapcar (lambda (mode) (cons mode ebox-buffer-mode-map))
                                    ebox--scroll-overridden-modes)
                            (cl-remove-if (lambda (entry)
                                            (memq (car entry) ebox--scroll-overridden-modes))
                                          minor-mode-overriding-map-alist)))
        (ebox--hover-sync (current-buffer)))
    (setq-local minor-mode-overriding-map-alist
                (cl-remove-if (lambda (entry)
                                (memq (car entry) ebox--scroll-overridden-modes))
                              minor-mode-overriding-map-alist))
    (when ebox--saved-overline-margin
      (if (car ebox--saved-overline-margin)
          (setq-local overline-margin (cdr ebox--saved-overline-margin))
        (kill-local-variable 'overline-margin))
      (setq ebox--saved-overline-margin nil))
    (kill-local-variable 'track-mouse)))

(defun ebox--after-flush-hover (buffer)
  "Enable BUFFER's mouse tracking once it paints hover content."
  (when (and (buffer-local-value 'ebox-buffer-mode buffer)
             (not (local-variable-p 'track-mouse buffer)))
    (ebox--hover-sync buffer)))

(add-hook 'ebox-after-flush-functions #'ebox--after-flush-hover)

;;;; Selector queries

(defun ebox-selector-query (root selector)
  "Return ROOT's descendants-or-self matching SELECTOR in document order."
  (let ((selector (if (stringp selector) (ecss-selector-parse selector) selector))
        (ebox--current-mount (ebox-node-mount (ebox-node-root root)))
        matches)
    (unless (ebox-mount-p ebox--current-mount) (setq ebox--current-mount nil))
    (ebox-node-walk root (lambda (node)
                           (when (ecss-selector-match-p selector node ebox--ecss-adapter)
                             (push node matches))))
    (nreverse matches)))

(defun ebox-selector-query-buffer (buffer-or-name selector)
  "Return nodes mounted in BUFFER-OR-NAME matching SELECTOR."
  (let ((root (ebox-buffer-root buffer-or-name)))
    (and root (ebox-selector-query root selector))))

(provide 'ebox-interaction)

;;; ebox-interaction.el ends here
