;;; ebox-interaction.el --- Fixed native node capabilities -*- lexical-binding: t; -*-

;;; Commentary:
;; Validates finite node interaction inputs, projects native text properties,
;; and owns mounted focus and navigation through publication and rollback.
;; Disabled and mounted focus feed the shared selector and cascade semantics.

;;; Code:

(require 'cl-lib)
(defvar ebox-selector-view--current)
(require 'tp)
(require 'tp)

(declare-function ebox-style-compile-form "ebox-style" (tag plist))
(declare-function ebox-style-declaration-properties "ebox-style"
                  (declarations predicate))
(declare-function ebox-buffer--text-decoration-face "ebox-buffer-backend" (style))
(declare-function ebox-buffer-paint-text-properties "ebox-buffer-backend"
                  (style role))
(declare-function ebox-get "ebox" (box property))
(declare-function ebox--ensure-region-id "ebox" (box))
(declare-function ebox-runtime-index-get "ebox-runtime-index" (key index &optional default))
(declare-function ebox-fragment-style-source-node "ebox-fragment" (node))
(declare-function ebox-surface-buffer-mounted-p "ebox-surface" (buffer))
(declare-function ebox-surface--buffer-client-state "ebox-surface" (buffer))
(declare-function ebox-surface--live-buffer-surface "ebox-surface" (buffer))
(declare-function ebox-surface--paint-node-chain "ebox-surface" (state role-ids))
(declare-function ebox--buffer-host-ref-table "ebox-incremental" (buffer))
(declare-function ebox--host-ref-node "ebox-runtime" (buffer host-ref))
(declare-function ebox-host-ref-bounds "ebox-runtime" (buffer-or-name host-ref))
(declare-function ebox-source--copy-data "ebox-source" (value))
(declare-function ebox-source--index-record "ebox-source" (index handle))
(declare-function ebox-source-record-key "ebox-source" (record))
(declare-function ebox-source-record-interactions "ebox-source" (record))
(declare-function ebox-source--handle-id-view "ebox-source" (handle))
(defvar ebox-region-types)
(defvar ebox-buffer--decoration-style-map)

(defconst ebox-interaction-properties
  '(:help-echo :pointer :hover-style :keymap :tab-index :disabled)
  "Fixed node capabilities accepted outside the Ebox style schema.")

(defconst ebox-interaction--hover-properties
  '(:color :background-color :text-decoration-line
    :text-decoration-color :text-decoration-style)
  "Geometry-independent Ebox declarations accepted by `:hover-style'.")

(defvar ebox-interaction--dispatching-activation nil
  "Non-nil while invoking a target already selected by Ebox activation.")

(defun ebox-interaction--command (callback &optional activation-p)
  "Wrap CALLBACK as a command; ACTIVATION-P uses shared keyboard focus."
  (lambda (&optional event)
    (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
    (if (null event)
        (if (and activation-p (not ebox-interaction--dispatching-activation)
                 (ebox-interaction--focused-owner-at-point))
            (ebox-activate)
          (funcall callback))
      (unless (and (consp event) (mouse-event-p event))
        (user-error "Ebox activation requires a mouse text event"))
      (let* ((position (event-start event))
             (window (posn-window position))
             (point (posn-point position)))
        (unless (and (window-live-p window) (null (posn-area position))
                     (integer-or-marker-p point))
          (user-error "Ebox activation requires a live text window"))
        (with-current-buffer (window-buffer window)
          (unless (and (or (integerp point)
                           (eq (marker-buffer point) (current-buffer)))
                       (<= (point-min) point (point-max)))
            (user-error "Ebox activation position is outside its text buffer"))
          (funcall callback))))))

;;;###autoload
(defun ebox-keymap-create (&rest options)
  "Create an ordinary native keymap from OPTIONS.
`:activate' is an optional zero-argument callback for RET, return, SPC and
the primary mouse button.  Mounted presses consume motion and release, publish
:active while held, and clear it before activating once on release over the same
owner.  Releasing elsewhere cancels activation.  Point and selection
are preserved.
Pure rendered text keeps release activation without mounted state.
Nil omits these activation bindings.  `:drag' accepts a one-argument callback
for start/move/end/cancel gesture plists.  It owns primary-button tracking;
when both options are supplied, activation remains keyboard-only.
`:bindings' is an alist of string key
descriptions or key vectors paired with zero-argument callbacks.  Explicit
bindings override the repeated-click, press and drag defaults.
Callbacks are not invoked until a generated command runs.  Keyboard commands
use the current buffer; mouse commands use the event window's buffer without
selecting a window or moving point.  Duplicate or overlapping keys are errors.
Generated activation keys use Ebox's logical focus when point still addresses
it, including a focused parent overlapping a child.  Mouse events always use
the clicked binding.  Explicit custom bindings keep their own native behavior.
This function does not install navigation bindings or event propagation."
  (unless (and (proper-list-p options) (zerop (% (length options) 2)))
    (error "Ebox keymap options must be an even plist"))
  (let ((map (make-sparse-keymap)) seen keys)
    (cl-loop for (key _value) on options by #'cddr do
             (unless (memq key '(:activate :bindings :drag))
               (error "Unknown Ebox keymap option: %S" key))
             (when (memq key seen)
               (error "Repeated Ebox keymap option: %S" key))
             (push key seen))
    (let ((activate (plist-get options :activate))
          (drag (plist-get options :drag))
          (bindings (plist-get options :bindings)))
      (when drag
        (unless (and (functionp drag)
                     (or (autoloadp (indirect-function drag))
                         (let ((arity (func-arity drag)))
                           (and (<= (car arity) 1)
                                (or (eq (cdr arity) 'many) (>= (cdr arity) 1))))))
          (error "Ebox :drag callback must accept one gesture argument")))
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
                           (let ((length (min (length key) (length other))))
                             (equal (cl-subseq key 0 length)
                                    (cl-subseq other 0 length))))
                         keys)
            (error "Ebox keymap binding overlaps an existing key: %s"
                   (key-description key)))
          (define-key map key
                      (ebox-interaction--command
                       callback (and activate (member key '([13] [return] [32] [mouse-1])))))
          (push key keys)))
      (when (or activate drag)
        ;; A release-only map lets the preceding press enter mouse-drag-region;
        ;; double/triple clicks can then select words or whole lines.  Claim
        ;; the primary-button sequence locally, preserving explicit handlers.
        (dolist (event '(mouse-1 double-mouse-1 triple-mouse-1
                                      down-mouse-1 double-down-mouse-1
                                      triple-down-mouse-1 drag-mouse-1
                                      double-drag-mouse-1 triple-drag-mouse-1))
          (unless (lookup-key map (vector event))
            (define-key map (vector event)
                        (cond
                         ((and drag (memq 'down (event-modifiers event)))
                          (lambda (press)
                            (interactive (list last-input-event))
                            (ebox-interaction--track-drag press drag)))
                         ((and activate (not drag)
                               (memq event '(double-mouse-1 triple-mouse-1)))
                          (lookup-key map [mouse-1]))
                         ((and activate (memq 'down (event-modifiers event)))
                          (lambda (press)
                            (interactive (list last-input-event))
                            (ebox-interaction--track-press press)))
                         (t #'ignore)))))))
    map))

(defvar ebox-interaction--drag-active nil
  "Non-nil inside the native primary-button tracking boundary.")

(defun ebox-interaction--drag-position (position window)
  "Return POSITION's text-area pixels inside WINDOW, or nil."
  (let ((xy (posn-x-y position)) (edges (window-inside-pixel-edges window)))
    (when (and (eq (posn-window position) window) (null (posn-area position))
               (consp xy) (numberp (car xy)) (numberp (cdr xy))
               (<= 0 (car xy)) (< (car xy) (- (nth 2 edges) (nth 0 edges)))
               (<= 0 (cdr xy)) (< (cdr xy) (- (nth 3 edges) (nth 1 edges))))
      (cons (car xy) (cdr xy)))))

(defun ebox-interaction--track-drag (event callback)
  "Track EVENT's committed owner and deliver gesture phases to CALLBACK."
  (when ebox-interaction--drag-active
    (user-error "An Ebox drag is already active"))
  (unless (and (mouse-event-p event) (eq (event-basic-type event) 'mouse-1)
               (memq 'down (event-modifiers event)))
    (user-error "Ebox drag requires a primary-button press"))
  (let* ((press (event-start event)) (window (posn-window press)))
    (unless (and (window-live-p window) (null (posn-area press)))
      (user-error "Ebox drag requires a live text window"))
    (let* ((buffer (window-buffer window))
           (start (ebox-interaction--drag-position press window))
           (point (posn-point press)))
      (unless (and start (integer-or-marker-p point))
        (user-error "Ebox drag requires a text position"))
      (with-current-buffer (ebox-interaction--focus-buffer buffer)
        (let* ((state (ebox-surface--buffer-client-state buffer))
               (surface (ebox-surface--live-buffer-surface buffer))
               (owner (ebox-interaction--navigation-owner point state))
               (identity (ebox-interaction--focus-ref state owner))
               (key (ebox-interaction--focus-key state owner))
               (button (event-basic-type event))
               (position start) (last-event event) (reason 'input)
               (ebox-interaction--drag-active t)
               (mouse-fine-grained-tracking t)
               started finished)
          (cl-labels
              ((available ()
                 (and (window-live-p window) (buffer-live-p buffer)
                      (eq (window-buffer window) buffer)
                      (eq surface (ebox-surface--live-buffer-surface buffer))
                      (let ((current (ebox-surface--buffer-client-state buffer)))
                        (and (equal owner (ebox-interaction--resolve-focus-owner
                                           current (plist-get current :source-index) identity owner key))
                             (with-current-buffer buffer
                               (when (ebox-interaction--focus-position current owner)
                                 (setq identity (ebox-interaction--focus-ref current owner))))))))
               (emit (phase)
                 (with-current-buffer (if (buffer-live-p buffer) buffer (current-buffer))
                   (funcall callback
                          (list :phase phase :event last-event
                                :host-ref (ebox-source--copy-data identity)
                                :window window :buffer buffer
                                :start (cons (car start) (cdr start))
                                :position (cons (car position) (cdr position))
                                :delta (cons (- (car position) (car start))
                                             (- (cdr position) (cdr start)))
                                :reason (and (eq phase 'cancel) reason))))))
            (unless (and owner identity (available))
              (user-error "No enabled Ebox drag target at the press position"))
            (unwind-protect
                (condition-case problem
                    (progn
                      (ebox-interaction--set-active identity buffer)
                      (setq started t)
                      (emit 'start)
                      (redisplay t)
                      (track-mouse
                        (let ((track-mouse 'dragging) done)
                          (while (and (not done) (available))
                            ;; A timeout lets ordinary Emacs timers invalidate a
                            ;; removed owner or window even while the mouse rests.
                            (when-let* ((next (read-event nil nil 0.05)))
                              (setq last-event next)
                              (let* ((release (and (eq (event-basic-type next) button)
                                                   (not (memq 'down (event-modifiers next)))))
                                     (motion (mouse-movement-p next)))
                                (cond
                                 ((or release motion)
                                  (let ((xy (and (available)
                                                 (ebox-interaction--drag-position
                                                  (if release (event-end next) (event-start next)) window))))
                                    (cond
                                     ((null xy) (setq reason 'window-left done t))
                                     (release
                                      (setq position xy finished t done t)
                                      (emit 'end))
                                     ((not (equal xy position))
                                      (setq position xy)
                                      (emit 'move)))
                                    (redisplay t)))
                                 (t (push next unread-command-events)
                                    (setq reason 'input done t))))))
                          (unless (available) (setq reason 'target-unavailable)))))
                  ((error quit)
                   (setq reason (if (eq (car problem) 'quit) 'quit 'error))
                   (signal (car problem) (cdr problem))))
              (unwind-protect
                  (when (and started (not finished)) (emit 'cancel))
                (when (and (buffer-live-p buffer)
                           (eq surface (ebox-surface--live-buffer-surface buffer)))
                  (ebox-interaction--set-active nil buffer))))))))))

(defun ebox-interaction--track-press (event)
  "Track EVENT until release and activate its retained owner when still hit."
  ;; Pure rendered text also carries these ordinary maps.  Without a mounted
  ;; owner leave its release to Emacs; there is no retained state to publish.
  (let* ((window (posn-window (event-start event)))
         (buffer (and (window-live-p window) (window-buffer window)))
         (release-key (cond ((memq 'triple (event-modifiers event)) [triple-mouse-1])
                            ((memq 'double (event-modifiers event)) [double-mouse-1])
                            (t [mouse-1]))))
    (when (and buffer (ebox-surface--buffer-client-state buffer))
      (ebox-interaction--track-drag
         event
         (lambda (gesture)
           (when (eq (plist-get gesture :phase) 'end)
             (let* ((buffer (plist-get gesture :buffer))
                    (state (ebox-surface--buffer-client-state buffer))
                    (reference (plist-get gesture :host-ref))
                    (owner (gethash reference (ebox--buffer-host-ref-table buffer)))
                    (position (posn-point (event-end (plist-get gesture :event))))
                    (hit (and (integer-or-marker-p position)
                              (<= (point-min) position) (< position (point-max))
                              (ebox-interaction--navigation-owner position state))))
               (when (and owner (equal owner hit))
                 (ebox-interaction--set-active nil buffer)
                 ;; Resolve the accepted binding after release styles publish.
                 (let* ((current (ebox-surface--buffer-client-state buffer))
                        (owner (gethash reference (ebox--buffer-host-ref-table buffer)))
                        (map (and owner (ebox-interaction--owner-keymap current owner)))
                        (command (and map (lookup-key map release-key)))
                        (ebox-interaction--dispatching-activation t)
                        (last-input-event (plist-get gesture :event)))
                   (when (commandp command) (command-execute command)))))))))))

(defun ebox-interaction--navigable-keymap-p (map)
  "Return non-nil when MAP contains a command, including inherited bindings.
Inspect prefix and menu maps without invoking menu filters or enable forms."
  (when (keymapp map)
    (let ((copy (ebox-interaction--keymap-snapshot map))
          (seen (make-hash-table :test #'eq)) commands)
      (cl-labels
          ((binding
            (value)
            (cond
             ((keymapp value) (visit value) value)
             ((eq (car-safe value) 'menu-item) (binding (nth 2 value)))
             ((and (consp value) (stringp (car value))) (binding (cdr value)))
             (t (when (and (not (eq value 'undefined)) (commandp value))
                  (cl-pushnew value commands :test #'eq))
                value)))
           (visit
            (value)
            (unless (gethash value seen)
              (puthash value t seen)
              (let ((parent (keymap-parent value))
                    (local (copy-sequence value)))
                (set-keymap-parent local nil)
                (map-keymap (lambda (event definition)
                              (define-key value (vector event) (binding definition)))
                            local)
                (when parent (visit parent))))))
        ;; Native lookup composes inherited prefix maps instead of treating
        ;; a local prefix as shadowing its parent's entire prefix.  Remove
        ;; menu wrappers only in this detached copy before using that lookup.
        (visit copy)
        (cl-some (lambda (command)
                   (where-is-internal command (list copy) 'non-ascii nil t))
                 commands)))))

(defun ebox-interaction--navigation-owner (position state)
  "Resolve POSITION's live native keymap to its declaring node in STATE.
Rendered region ownership and the retained parent index identify inheritance;
an explicit nil on a descendant blocks an ancestor's declaration."
  (when-let* ((map (get-text-property position 'keymap))
              ((keymapp map)))
    (let ((chain (ebox-surface--paint-node-chain
                  state (cl-loop for (role . property) in ebox-region-types
                                 for region = (get-text-property position property)
                                 when region collect (cons role region)))))
      (catch 'owner
        (dolist (node-id chain)
          (let* ((node (ebox-runtime-index-get node-id (plist-get state :node-table)))
                 (source (ebox-fragment-style-source-node node))
                 (entry (plist-member (ebox-get source :surface-properties) 'keymap)))
            (when entry
              (throw 'owner
                     (and (cadr entry)
                          (ebox-interaction-surface-equal-p
                           (list 'keymap map) (list 'keymap (cadr entry)))
                          node-id)))))))))

;;;###autoload
(defun ebox-activate (&optional position noerror)
  "Invoke the live Ebox RET binding at POSITION, defaulting to point.
With nil POSITION, prefer logical focus if point is still at that target's
first visible character.  Focus resolves its own or inherited map, ignoring
an overlapping child's map.  Explicit POSITION always selects by that position.
Only visible, accessible text belonging to a committed node keymap is eligible.
Inherited maps use their declaring owner; an explicit nil keymap blocks it.
Buffer and overlay maps do not supply activation targets.  This function does
not move point or select a window.  The command runs in the current buffer
with RET as `last-input-event'; its result or error is returned unchanged.
An absent target or RET command signals `user-error', or returns nil when
NOERROR is non-nil.  NOERROR does not suppress command errors."
  (interactive)
  (let* ((focused-owner (and (null position) (ebox-interaction--focused-owner-at-point)))
         (position (or position (point)))
         (eligible
          (and (ebox-surface-buffer-mounted-p (current-buffer))
               (integer-or-marker-p position)
               (or (integerp position) (eq (marker-buffer position) (current-buffer)))
               (<= (point-min) position) (< position (point-max))
               (not (eq (char-after position) ?\n))
               (not (invisible-p position))
               (not (equal (get-text-property position 'display) ""))))
         (state (and eligible (ebox-surface--buffer-client-state (current-buffer))))
         (owner (and state (or focused-owner
                               (ebox-interaction--navigation-owner position state))))
         (map (and owner (if focused-owner
                             (ebox-interaction--owner-keymap state owner)
                           (get-text-property position 'keymap))))
         (command (and map (lookup-key map (kbd "RET")))))
    (if (commandp command)
        (let ((last-input-event ?\r)
              (ebox-interaction--dispatching-activation t))
          (command-execute command))
      (unless noerror (user-error "No live Ebox RET command at position")))))

(defvar ebox-interaction--focus-request nil
  "Dynamic (BUFFER HOST-REF BASE-STATE) for one focus publication.")

(defun ebox-interaction--focus-request-for (buffer state)
  "Return the focus request belonging to BUFFER and committed base STATE."
  (and (eq buffer (car ebox-interaction--focus-request))
       (eq state (nth 2 ebox-interaction--focus-request))
       ebox-interaction--focus-request))

(defun ebox-interaction--resolve-focus-owner (state source ref owner key)
  "Resolve REF in STATE SOURCE, then retain OWNER only through matching KEY."
  (or (and ref (gethash ref (ebox-source--index-host-ref-table source)))
      (and key (equal key (ebox-interaction--focus-key state owner)) owner)))

(defun ebox-interaction--candidate-source (buffer old-state index source root)
  "Project BUFFER's requested or retained interactions into INDEX SOURCE."
  (with-current-buffer buffer
    (let* ((request (ebox-interaction--active-request-for buffer old-state))
           (reference (if request (cadr request)
                        (ebox-interaction--focus-ref old-state ebox-interaction--active-owner)))
           (owner (ebox-interaction--resolve-focus-owner
                   index source reference ebox-interaction--active-owner
                   (unless request (ebox-interaction--focus-key old-state ebox-interaction--active-owner))))
           (node (and owner (ebox-interaction--focus-node index owner)))
           (handle (and node (ebox-tree-node-source-handle node))))
      (when (or (and handle (plist-get (ebox-source-index-interactions source handle) :disabled))
                (and owner (not (ebox-interaction--focus-visible-p index owner))))
        (setq handle nil))
      (when (or request ebox-interaction--active-owner)
        (setq source (ebox-source--with-interaction-state source "active" handle))))
    (if (and (null ebox-interaction--focus-owner)
             (not (ebox-interaction--focus-request-for buffer old-state)))
        source
      (let* ((request (ebox-interaction--focus-request-for buffer old-state))
             (ref (if request (cadr request)
                    (ebox-interaction--focus-ref old-state ebox-interaction--focus-owner)))
             (owner (ebox-interaction--resolve-focus-owner
                     index source ref ebox-interaction--focus-owner
                     (unless request
                       (ebox-interaction--focus-key old-state ebox-interaction--focus-owner))))
             (node (and owner (ebox-interaction--focus-node index owner)))
             (handle (and node (ebox-tree-node-source-handle node))))
	(when (or (and handle (plist-get (ebox-source-index-interactions source handle) :disabled))
                  (and owner (not (ebox-interaction--focus-visible-p index owner)))
                  (and (not request) ebox-interaction--focus-owner
                       (not (ebox-interaction--focus-position old-state ebox-interaction--focus-owner))))
          (setq handle nil))
	(let ((projected (ebox-source--with-interaction-state source "focus" handle)))
          (when handle
            (let* ((subjects (ebox-tree-source-index root t nil projected))
                   (ebox-selector-view--current (ebox-source--index-selector-view subjects))
                   (ebox-style--scopes (ebox-style-source-scopes subjects))
                   (current owner) chain parent-style hidden)
              (while current
		(push (ebox-interaction--focus-node index current) chain)
		(setq current (ebox-runtime-index-get current (plist-get index :parent-table))))
              (dolist (ancestor chain)
		(setq parent-style
                      (ebox-style-compute-subject
                       (ebox-tree-node-subject subjects ancestor)
                       (ebox-style-node-declarations subjects ancestor) parent-style))
		(when (eq (ebox-style-computed-value parent-style :visibility) 'hidden)
                  (setq hidden t)))
              (when hidden
		(if (and request (cadr request))
                    (user-error "Focus styles removed the enabled visible target: %S" (cadr request))
                  (setq projected (ebox-source--with-interaction-state projected "focus" nil))))))
          projected)))))

(defvar-local ebox-interaction--focus-owner nil
  "Runtime node identity owning this buffer's logical focus.")

(defvar-local ebox-interaction--focus-order nil
  "Derived navigation index for the current published state.")

(defvar-local ebox-interaction--active-owner nil
  "Committed owner of the current primary-button gesture.")

(defvar ebox-interaction--active-request nil
  "Dynamic (BUFFER HOST-REF BASE-STATE) for one pressed-state publication.")

(defun ebox-interaction--active-request-for (buffer state)
  "Return the pressed-state request belonging to BUFFER and base STATE."
  (and (eq buffer (car ebox-interaction--active-request))
       (eq state (nth 2 ebox-interaction--active-request))
       ebox-interaction--active-request))

(defun ebox-interaction--reset ()
  "Release this buffer's interaction owners and derived navigation index."
  (setq ebox-interaction--focus-owner nil
        ebox-interaction--active-owner nil
        ebox-interaction--focus-order nil))

(defun ebox-interaction--set-active (host-ref buffer)
  "Publish HOST-REF as BUFFER's pressed owner, or clear it with nil."
  (with-current-buffer (ebox-interaction--focus-buffer buffer)
    (let* ((state (ebox-surface--buffer-client-state buffer))
           (owner (and host-ref (gethash host-ref (ebox--buffer-host-ref-table buffer)))))
      (when (and host-ref (not (and owner (ebox-interaction--focus-position state owner))))
        (user-error "No enabled visible Ebox pressed target"))
      (unless (equal owner ebox-interaction--active-owner)
        (let ((ebox-interaction--active-request (list buffer host-ref state)))
          (save-restriction
            (widen)
            (ebox-commit buffer
                         (ebox-canonical-input-create (list (plist-get state :root-node))
                                                      (plist-get state :source-index)))))))))

(defun ebox-interaction--focus-node (state owner)
  "Return OWNER's runtime node in STATE."
  (and owner (ebox-runtime-index-get owner (plist-get state :node-table))))

(defun ebox-interaction--focus-ref (state owner)
  "Return OWNER's current source identity in STATE."
  (when-let* ((node (ebox-interaction--focus-node state owner))
              (handle (plist-get node :ebox-source-handle)))
    (ebox-source--handle-id-view handle)))

(defun ebox-interaction--focus-key (state owner)
  "Return OWNER's sibling key in STATE, or nil."
  (when-let* ((node (ebox-interaction--focus-node state owner))
              (record (ebox-source--index-record
                       (plist-get state :source-index)
                       (plist-get node :ebox-source-handle))))
    (ebox-source-record-key record)))

(defun ebox-interaction--focus-properties (state owner)
  "Return OWNER's committed interaction facts in STATE."
  (when-let* ((node (ebox-interaction--focus-node state owner))
              (record (ebox-source--index-record
                       (plist-get state :source-index)
                       (plist-get node :ebox-source-handle))))
    (ebox-source-record-interactions record)))

(defun ebox-interaction--focus-visible-p (state owner)
  "Return non-nil when OWNER is outside every hidden visibility boundary."
  (let ((current owner) (visible t))
    (while (and current visible)
      (when (eq (ebox-get (ebox-interaction--focus-node state current) :visibility) 'hidden)
        (setq visible nil))
      (setq current (ebox-runtime-index-get current (plist-get state :parent-table))))
    visible))

(defun ebox-interaction--focus-position (state owner)
  "Return OWNER's first accessible visible painted position in STATE."
  (when (and (not (plist-get (ebox-interaction--focus-properties state owner) :disabled))
             (ebox-interaction--focus-visible-p state owner))
    (when-let* ((ref (ebox-interaction--focus-ref state owner))
                (bounds (ebox-host-ref-bounds (current-buffer) ref)))
      (let ((position (max (point-min) (car bounds)))
            (limit (min (point-max) (cdr bounds))))
        (catch 'position
          (while (< position limit)
            (let ((end (next-char-property-change position limit)))
              (while (and (< position end) (eq (char-after position) ?\n))
                (setq position (1+ position)))
              (when (and (< position end) (not (invisible-p position))
                         (not (equal (get-text-property position 'display) ""))
                         (member owner
                                 (ebox-surface--paint-node-chain
                                  state
                                  (cl-loop for (role . property) in ebox-region-types
                                           for region = (get-text-property position property)
                                           when region collect (cons role region)))))
                (throw 'position position))
              (setq position end))))))))

(defun ebox-interaction--focused-owner-at-point ()
  "Return the current mounted focus owner when point still addresses it."
  (when (and ebox-interaction--focus-owner
             (ebox-surface-buffer-mounted-p (current-buffer)))
    (let ((state (ebox-surface--buffer-client-state (current-buffer))))
      (and (equal (point) (ebox-interaction--focus-position state ebox-interaction--focus-owner))
           ebox-interaction--focus-owner))))

(defun ebox-interaction--owner-keymap (state owner)
  "Return OWNER's effective committed keymap in STATE, respecting nil barriers."
  (catch 'keymap
    (while owner
      (let* ((node (ebox-interaction--focus-node state owner))
             (source (ebox-fragment-style-source-node node))
             (entry (plist-member (ebox-get source :surface-properties) 'keymap)))
        (when entry (throw 'keymap (cadr entry))))
      (setq owner (ebox-runtime-index-get owner (plist-get state :parent-table))))))

(defun ebox-interaction--focus-buffer (buffer-or-name)
  "Resolve BUFFER-OR-NAME to a mounted buffer, defaulting to current buffer."
  (let ((buffer (if buffer-or-name (get-buffer buffer-or-name) (current-buffer))))
    (unless (and (buffer-live-p buffer) (ebox-surface-buffer-mounted-p buffer))
      (user-error "Buffer has no live Ebox surface"))
    buffer))

(define-error 'ebox-input-cancelled "Ebox input target is no longer available" 'quit)

;;;###autoload
(defun ebox-call-with-input (host-ref reader &optional buffer-or-name)
  "Run native input READER for HOST-REF in BUFFER-OR-NAME.
READER is a zero-argument function, for example a minibuffer read.  Return
its result only while the same mounted target remains enabled and visible;
otherwise signal `ebox-input-cancelled', a subtype of `quit'.  READER errors
and user quits propagate.  No result is applied to application state here.
Restore logical focus to the retained target on return, error or quit when
it is still available.  Reorder and unrelated publication retain ownership;
replacement, unmount, deletion, hiding and disabling invalidate it.
This function changes no window selection and owns no input buffer.  Native
Emacs readers own editing, input methods, selection and undo.  Call outside
a TP transaction; it must not write native text into an Ebox-owned surface."
  (unless (functionp reader)
    (signal 'wrong-type-argument (list 'functionp reader)))
  (when (tp-transaction-active-p)
    (error "Ebox input requires an accepted transaction boundary"))
  (let* ((buffer (ebox-interaction--focus-buffer buffer-or-name))
         (surface (ebox-surface--live-buffer-surface buffer))
         (owner (gethash host-ref (ebox--buffer-host-ref-table buffer)))
         (state (ebox-surface--buffer-client-state buffer))
         (key (and owner (ebox-interaction--focus-key state owner)))
         result completed valid)
    (cl-labels
        ((available ()
           (and (buffer-live-p buffer)
                (eq surface (ebox-surface--live-buffer-surface buffer))
                (equal owner (gethash host-ref (ebox--buffer-host-ref-table buffer)))
                (let ((current (ebox-surface--buffer-client-state buffer)))
                  (and (equal key (ebox-interaction--focus-key current owner))
                       (with-current-buffer buffer
                         (ebox-interaction--focus-position current owner)))))))
      (unless (and owner (available))
        (signal 'ebox-input-cancelled (list host-ref)))
      (unwind-protect
          (with-current-buffer buffer
            (setq result (funcall reader) completed t))
        (setq valid (available))
        (when valid
          (condition-case problem
              (ebox-focus host-ref buffer)
            ((error quit)
             (setq valid nil)
             (when completed (signal (car problem) (cdr problem)))))))
      (unless valid (signal 'ebox-input-cancelled (list host-ref)))
      result)))

;;;###autoload
(defun ebox-focus (host-ref &optional buffer-or-name)
  "Focus HOST-REF in BUFFER-OR-NAME, defaulting to the current buffer.
Return the current opaque Host reference and move point to its first accessible
visible painted character, without selecting a window.  Any enabled visible
node may receive explicit focus, including a negative or absent `:tab-index'.
Nil HOST-REF clears focus and preserves numeric point, clamped after layout.
Focus changes publish the focus selector state and its computed styles together.
Styles that make a newly requested target inaccessible reject the operation.
Missing, disabled, hidden or
inaccessible targets signal `user-error' without changing focus or point.
Focus follows retained identity through publication.  Removal, hiding and
disabling clear it without choosing a replacement; navigation can then restart.
Failed publication restores focus.  Unmount and buffer death release it.
An active TP transaction is an error: call after acceptance instead. Focus
changes cannot join an outer transaction or expose provisional targets."
  (when (tp-transaction-active-p)
    (error "Ebox focus changes require an accepted transaction boundary"))
  (with-current-buffer (ebox-interaction--focus-buffer buffer-or-name)
    (let* ((state (ebox-surface--buffer-client-state (current-buffer)))
           (owner (and host-ref (gethash host-ref (ebox--buffer-host-ref-table (current-buffer)))))
           (position (and owner (ebox-interaction--focus-position state owner))))
      (when (and host-ref (not position))
        (user-error "No enabled visible Ebox focus target: %S" host-ref))
      (if (equal owner ebox-interaction--focus-owner)
          (when position (goto-char position))
        (let ((ebox-interaction--focus-request (list (current-buffer) host-ref state)))
          (save-restriction
            (widen)
            (ebox-commit
             (current-buffer)
             (ebox-canonical-input-create (list (plist-get state :root-node))
                                          (plist-get state :source-index))))))
      (ebox-focused-host-ref))))

;;;###autoload
(defun ebox-focused-host-ref (&optional buffer-or-name)
  "Return the logical focus Host reference in BUFFER-OR-NAME, or nil.
Default to the current buffer.  Dead or unmounted buffers return nil.
Manual point movement does not clear logical focus; it stops publication from
following the target until point is moved back to that target's first character."
  (let ((buffer (if buffer-or-name (get-buffer buffer-or-name) (current-buffer))))
    (when (and (buffer-live-p buffer) (ebox-surface-buffer-mounted-p buffer))
      (with-current-buffer buffer
        (ebox-source--copy-data
         (ebox-interaction--focus-ref
          (ebox-surface--buffer-client-state buffer) ebox-interaction--focus-owner))))))

(defun ebox-interaction--capture (buffer)
  "Capture BUFFER's interaction owners and point before publication."
  (with-current-buffer buffer
    (let ((state (ebox-surface--buffer-client-state buffer)))
      (list ebox-interaction--focus-owner (point)
            (and state ebox-interaction--focus-owner
                 (equal (point) (ebox-interaction--focus-position
                                 state ebox-interaction--focus-owner)))
            (and state (ebox-interaction--focus-ref
                        state ebox-interaction--focus-owner))
            (and state (ebox-interaction--focus-key
                        state ebox-interaction--focus-owner))
            state
            ebox-interaction--active-owner
            (and state (ebox-interaction--focus-ref state ebox-interaction--active-owner))
            (and state (ebox-interaction--focus-key state ebox-interaction--active-owner))))))

(defun ebox-interaction--publish (buffer snapshot)
  "Reconcile BUFFER's interaction owners against the published candidate."
  (with-current-buffer buffer
    (setq ebox-interaction--focus-order nil)
    (let* ((state (ebox-surface--buffer-client-state buffer))
           (request (ebox-interaction--active-request-for buffer (nth 5 snapshot)))
           (owner (ebox-interaction--resolve-focus-owner
                   state (plist-get state :source-index)
                   (if request (cadr request) (nth 7 snapshot))
                   (nth 6 snapshot) (unless request (nth 8 snapshot))))
           (record (and owner
                        (ebox-source--index-record
                         (plist-get state :source-index)
                         (ebox-tree-node-source-handle (ebox-interaction--focus-node state owner)))))
           (position (and record (member "active" (ebox-source-record-interaction-states record))
                          (ebox-interaction--focus-position state owner))))
      (when (and request (cadr request) (not position))
        (user-error "Pressed styles removed the enabled visible target"))
      (setq ebox-interaction--active-owner (and position owner)))
    (let* ((state (ebox-surface--buffer-client-state buffer))
           (request (ebox-interaction--focus-request-for buffer (nth 5 snapshot)))
           (owner (ebox-interaction--resolve-focus-owner
                   state (plist-get state :source-index)
                   (if request (cadr request) (nth 3 snapshot))
                   (car snapshot) (unless request (nth 4 snapshot))))
           (owner (and owner
                       (when-let* ((node (ebox-interaction--focus-node state owner))
                                   (record (ebox-source--index-record
                                            (plist-get state :source-index)
                                            (ebox-tree-node-source-handle node))))
                         (and (member "focus" (ebox-source-record-interaction-states record)) owner))))
           (position (and owner (ebox-interaction--focus-position state owner))))
      (when (and request (cadr request) (not position))
        (user-error "Focus styles removed the enabled visible target: %S" (cadr request)))
      (setq ebox-interaction--focus-owner (and position owner))
      (when (or request (car snapshot))
        (goto-char (if (and position (or request (nth 2 snapshot))) position
                     (min (point-max) (max (point-min) (nth 1 snapshot)))))))))

(defun ebox-interaction--focus-settle (buffer snapshot state)
  "Apply BUFFER's focus point after TP restores its native view for STATE."
  (when (and (or (car snapshot)
                 (ebox-interaction--focus-request-for buffer (nth 5 snapshot)))
             (buffer-live-p buffer)
             (eq state (ebox-surface--buffer-client-state buffer)))
    (with-current-buffer buffer
      (let ((position (and (or (nth 2 snapshot)
                               (ebox-interaction--focus-request-for buffer (nth 5 snapshot)))
                           (ebox-interaction--focus-position
                            state ebox-interaction--focus-owner))))
        (goto-char (or position
                       (min (point-max) (max (point-min) (nth 1 snapshot)))))))))

(defun ebox-interaction--rollback (buffer snapshot)
  "Restore BUFFER's interaction owners after publication rejection."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ebox-interaction--focus-owner (car snapshot)
            ebox-interaction--active-owner (nth 6 snapshot)
            ebox-interaction--focus-order nil))))

(defun ebox-interaction--focus-index (state)
  "Return a cached navigation vector and owner ranks for published STATE."
  (unless (eq state (car ebox-interaction--focus-order))
    (let (entries)
      (maphash
       (lambda (ref owner)
         (let ((index (plist-get (ebox-interaction--focus-properties state owner) :tab-index)))
           (when (and (integerp index) (>= index 0))
             (let ((bounds (ebox-host-ref-bounds (current-buffer) ref)))
               (push (list index (or (car bounds) most-positive-fixnum)
                           (or (cdr bounds) most-positive-fixnum) owner) entries)))))
       (ebox--buffer-host-ref-table (current-buffer)))
      (setq entries
            (sort entries
                  (lambda (left right)
                    (or (< (nth 0 left) (nth 0 right))
                        (and (= (nth 0 left) (nth 0 right))
                             (or (< (nth 1 left) (nth 1 right))
                                 (and (= (nth 1 left) (nth 1 right))
                                      (or (< (nth 2 left) (nth 2 right))
                                          (and (= (nth 2 left) (nth 2 right))
                                               (string< (prin1-to-string (nth 3 left))
                                                        (prin1-to-string (nth 3 right))))))))))))
      (let ((owners (vconcat (mapcar (lambda (entry) (nth 3 entry)) entries)))
            (ranks (make-hash-table :test #'equal)))
        (dotimes (rank (length owners)) (puthash (aref owners rank) rank ranks))
        (setq ebox-interaction--focus-order (list state owners ranks)))))
  (cdr ebox-interaction--focus-order))

;;;###autoload
(defun ebox-focus-next (&optional count cycle buffer-or-name)
  "Move logical focus COUNT stops forward in BUFFER-OR-NAME and return its ref.
Defaults are one stop and the current buffer.  Negative COUNT moves backward;
zero returns current focus.  CYCLE non-nil wraps at a boundary; otherwise a
missing stop signals `user-error' without changing focus or point.
Only nodes declaring a nonnegative integer `:tab-index' are navigation stops.
Order is ascending tab index, buffer start, then end; exact ties use retained
node identity.  Disabled, hidden and inaccessible nodes are skipped.  Navigation
starts at the first (or backward last) stop when there is no eligible focus.
No window is selected and no key bindings are installed. Nonzero moves reject
active TP transactions; zero remains a read-only query. See `ebox-focus'."
  (interactive "p")
  (ebox-interaction--focus-move (or count 1) cycle buffer-or-name nil))

(defun ebox-interaction--focus-within-p (state owner root)
  "Return non-nil when OWNER is inside ROOT in committed STATE.
Nil ROOT leaves navigation unrestricted."
  (or (null root)
      (let ((cursor owner))
        (while (and cursor (not (equal cursor root)))
          (setq cursor (ebox-runtime-index-get cursor (plist-get state :parent-table))))
        cursor)))

(defun ebox-interaction--focus-move (count cycle buffer-or-name restart &optional root)
  "Move COUNT stops in BUFFER-OR-NAME within optional ROOT.
CYCLE wraps and RESTART ignores focus."
  (setq count (or count 1))
  (unless (integerp count) (signal 'wrong-type-argument (list 'integerp count)))
  (with-current-buffer (ebox-interaction--focus-buffer buffer-or-name)
    (if (zerop count) (ebox-focused-host-ref)
      (let* ((state (ebox-surface--buffer-client-state (current-buffer)))
             (index (ebox-interaction--focus-index state))
             (owners (car index))
             (size (length owners))
             (step (if (> count 0) 1 -1))
             (rank (and (not restart)
                        (ebox-interaction--focus-within-p state ebox-interaction--focus-owner root)
                        (ebox-interaction--focus-position state ebox-interaction--focus-owner)
                        (gethash ebox-interaction--focus-owner (cadr index))))
             (rank (or rank (if (> step 0) -1 size)))
             owner)
        (dotimes (_ (abs count))
          (setq owner nil)
          (let ((visited 0))
            (while (and (not owner) (< visited size))
              (setq rank (+ rank step) visited (1+ visited))
              (when cycle (setq rank (mod rank size)))
              (if (not (< -1 rank size))
                  (setq visited size)
                (when (and (ebox-interaction--focus-within-p state (aref owners rank) root)
                           (ebox-interaction--focus-position state (aref owners rank)))
                  (setq owner (aref owners rank)))))
            (unless owner (user-error "No eligible Ebox focus stop"))))
        (ebox-focus (ebox-interaction--focus-ref state owner))))))

;;;###autoload
(defun ebox-focus-within (host-ref &optional count cycle buffer-or-name)
  "Navigate within HOST-REF's committed subtree in BUFFER-OR-NAME.
Nil COUNT chooses the first eligible stop.  An integer moves that many stops;
negative moves backward and CYCLE wraps within the subtree.  Zero returns the
current focus only when it belongs to this subtree.  Invalid or inaccessible
roots and missing stops signal `user-error' without changing focus or point.
Use the same ordering, visibility and publication rules as `ebox-focus-next'.
This installs no input bindings and does not restrict other focus operations."
  (with-current-buffer (ebox-interaction--focus-buffer buffer-or-name)
    (let* ((state (ebox-surface--buffer-client-state (current-buffer)))
           (root (gethash host-ref (ebox--buffer-host-ref-table (current-buffer)))))
      (unless (and root (ebox-interaction--focus-position state root))
        (user-error "No enabled visible Ebox navigation root: %S" host-ref))
      (if (and (integerp count) (zerop count))
          (when (ebox-interaction--focus-within-p state ebox-interaction--focus-owner root)
            (ebox-focused-host-ref))
        (ebox-interaction--focus-move count cycle (current-buffer) (null count) root)))))

;;;###autoload
(defun ebox-focus-first (&optional buffer-or-name)
  "Focus the first eligible navigation stop in BUFFER-OR-NAME and return its ref.
Default to the current buffer.  Use the same tab order and visibility rules as
`ebox-focus-next', independently of current focus.  If no stop exists, signal
`user-error' without changing focus or point.  Never select a window."
  (interactive)
  (ebox-interaction--focus-move 1 nil buffer-or-name t))

;;;###autoload
(defun ebox-focus-previous (&optional count cycle buffer-or-name)
  "Move logical focus COUNT stops backward in BUFFER-OR-NAME.
COUNT defaults to one; negative COUNT moves forward.  See `ebox-focus-next'
for navigation order, CYCLE, visibility and failure semantics."
  (interactive "p")
  (ebox-focus-next (- (or count 1)) cycle buffer-or-name))

(defun ebox-interaction--move (count)
  "Move by COUNT interaction stops in the accessible live Ebox surface.
Resolve every stop from current rendered properties; keep no navigation state."
  (unless (integerp count)
    (signal 'wrong-type-argument (list 'integerp count)))
  (unless (ebox-surface-buffer-mounted-p (current-buffer))
    (user-error "Current buffer has no live Ebox surface"))
  (if (zerop count)
      (point)
    (let* ((state (ebox-surface--buffer-client-state (current-buffer)))
           (origin (point))
           (current-owner (and (< origin (point-max))
                               (ebox-interaction--navigation-owner origin state)))
           (seen (make-hash-table :test #'equal))
           (maps (make-hash-table :test #'eq))
           (position (point-min)) stops)
      (while (< position (point-max))
        (let* ((end (next-char-property-change position (point-max)))
               (map (get-text-property position 'keymap))
               (owner (and map (ebox-interaction--navigation-owner position state))))
          ;; Structural line breaks carry no activation target.  A property
          ;; run can begin at one after narrowing or native publication.
          (while (and (< position end) (eq (char-after position) ?\n))
            (setq position (1+ position)))
          (when (and owner (< position end) (not (invisible-p position))
                     (not (equal (get-text-property position 'display) ""))
                     (not (gethash owner seen)))
            (let ((navigable (gethash map maps 'unknown)))
              (when (eq navigable 'unknown)
                (setq navigable (ebox-interaction--navigable-keymap-p map))
                (puthash map navigable maps))
              (when navigable
                (puthash owner t seen)
                (push (cons position owner) stops))))
          (setq position end)))
      (when (> count 0) (setq stops (nreverse stops)))
      (let* ((eligible
              (cl-remove-if-not
               (lambda (stop)
                 (and (not (equal (cdr stop) current-owner))
                      (if (> count 0) (> (car stop) origin)
                        (< (car stop) origin))))
               stops))
             (target (nth (1- (abs count)) eligible)))
        (unless target
          (user-error "No %s Ebox interaction" (if (> count 0) "next" "previous")))
        (goto-char (car target))))))

;;;###autoload
(defun ebox-next-interaction (&optional count)
  "Move point to the next rendered Ebox keymap owner; return its position.
With COUNT, move that many stops; a negative count moves backward, zero stays.
Each declaring node is one stop, at its first accessible rendered character,
even across multiple lines or inherited child content.  Explicit child maps
are separate stops; nil and maps without commands are skipped.  From within
an owner, skip that owner and seek the next stop after point.
Respect narrowing and invisible text.  Use the current committed surface, so
updates, removal and scrolling need no navigation refresh.  At a boundary,
signal `user-error' without moving; do not wrap or bind keys automatically.
Ordinary buffer, overlay and global keymaps do not create stops.  Menu enable
forms and filters are not evaluated; a declared command remains a stop even
when an application dynamically disables its menu item."
  (interactive "p")
  (ebox-interaction--move (or count 1)))

;;;###autoload
(defun ebox-previous-interaction (&optional count)
  "Move point to the previous rendered Ebox keymap owner; return its position.
COUNT defaults to one.  Negative COUNT moves forward.  See
`ebox-next-interaction' for ownership, narrowing and boundary behavior."
  (interactive "p")
  (ebox-interaction--move (- (or count 1))))

;;;###autoload
(defun ebox-help-create (function)
  "Adapt zero-argument FUNCTION to a native `help-echo' callback.
The help object's buffer, or the live window buffer for a displayed string,
becomes current while FUNCTION runs.  Neither point nor window selection is
changed.  FUNCTION runs only when Emacs requests help and must return a string
or nil.  Existing native three-argument callbacks need no adapter."
  (unless (and (functionp function)
               (or (autoloadp (indirect-function function))
                   (zerop (car (func-arity function)))))
    (error "Ebox help requires a zero-argument function"))
  (lambda (window object _position)
    (let ((buffer (cond ((bufferp object) object)
                        ((overlayp object) (overlay-buffer object))
                        ((and (stringp object) (window-live-p window))
                         (window-buffer window)))))
      (unless (buffer-live-p buffer)
        (user-error "Ebox help requires a live text buffer"))
      (with-current-buffer buffer
        (let ((value (funcall function)))
          (unless (or (null value) (stringp value))
            (error "Ebox help function must return a string or nil"))
          value)))))

(defun ebox-interaction--keymap-snapshot (keymap)
  "Copy native KEYMAP, resolving named root, prefix and parent maps.
Only native map positions are resolved; ordinary command symbols and literal
callback environments retain their identities.  Sharing and cycles survive."
  (let ((copies (make-hash-table :test #'eq)))
    (cl-labels
        ((binding
          (value)
          (cond
           ((keymapp value) (map-copy value))
           ((functionp value) value)
           ((and (consp value) (eq (car value) 'menu-item))
            (let ((copy (tp-property-value-copy value)))
              (when (cddr copy)
                (setcar (cddr copy) (binding (nth 2 value))))
              copy))
           ((and (consp value) (stringp (car value)))
            (cons (tp-property-value-copy (car value)) (binding (cdr value))))
           ((and (consp value) (keymapp (car value)))
            (cons (map-copy (car value)) (tp-property-value-copy (cdr value))))
           (t (tp-property-value-copy value))))
         (map-copy
          (source)
          (setq source (if (symbolp source) (indirect-function source) source))
          (or (gethash source copies)
              (let* ((parent (keymap-parent source))
                     (local (copy-sequence source))
                     (copy (tp-property-value-copy source)))
                (puthash source copy copies)
                ;; Only the copied spine is edited, leaving source bindings
                ;; and character tables untouched while enumerating locals.
                ;; Replacing existing entries also preserves native menu order.
                (set-keymap-parent local nil)
                (map-keymap
                 (lambda (event definition)
                   (define-key copy (vector event) (binding definition)))
                 local)
                (when parent (set-keymap-parent copy (map-copy parent)))
                copy))))
      (map-copy keymap))))

(defun ebox-interaction--hover-face (value)
  "Validate hover declarations VALUE and return a native mouse face."
  (unless (and (proper-list-p value) (zerop (% (length value) 2)))
    (error "Ebox :hover-style must be an even declaration plist"))
  (cl-loop for (key val) on value by #'cddr
           unless (memq key ebox-interaction--hover-properties)
           do (error "Ebox :hover-style does not support %S" key)
           when (memq key '(:color :background-color :text-decoration-color))
           unless (or (stringp val)
                      (and (eq key :text-decoration-color)
                           (eq val 'currentColor)))
           do (error "Ebox :hover-style %S requires a color string" key))
  (when value
    (require 'ebox-style)
    (require 'ebox-buffer-backend)
    (let* ((style (ebox-style-declaration-properties
                   (ebox-style-compile-form 'text value) (lambda (_property) t)))
           (face (ebox-buffer--text-decoration-face style)))
      ;; A solid underline is represented by t in a face, not an empty plist.
      (when (and (plist-member face :underline)
                 (null (plist-get face :underline)))
        (setq face (plist-put face :underline t)))
      (when (plist-member style :color)
        (setq face (plist-put face :foreground (plist-get style :color))))
      (when (plist-member style :background-color)
        (setq face (plist-put face :background
                              (plist-get style :background-color))))
      (when (eq (plist-get style :text-decoration-line) 'none)
        (setq face (append face '(:underline nil :overline nil
                                 :strike-through nil))))
      face)))

(defun ebox-interaction-normalize (properties)
  "Return an owned, validated copy of node interaction PROPERTIES.
Absent surface capabilities inherit enclosing values; explicit nil blocks them.
Tab index and disabled status are node-local and do not inherit.
Callback values remain literal functions.  Mutable keymaps are snapshotted;
replace the property to publish subsequent binding changes."
  (unless (and (proper-list-p properties)
               (zerop (% (length properties) 2)))
    (error "Ebox interaction properties must be an even plist"))
  (let (seen)
    (cl-loop for (key value) on properties by #'cddr do
             (when (memq key seen)
               (error "Ebox interaction property repeated: %S" key))
             (push key seen)
             (pcase key
               (:help-echo
                (unless (or (null value) (stringp value) (functionp value))
                  (error "Ebox :help-echo requires nil, a string or a function")))
               (:pointer
                (unless (memq value '(nil text arrow vdrag modeline hand
                                         hdrag nhdrag hourglass))
                  (error "Ebox :pointer has unsupported shape: %S" value)))
               (:keymap
                (unless (or (null value) (keymapp value))
                  (error "Ebox :keymap requires nil or a native keymap")))
               (:tab-index
                (unless (or (null value) (integerp value))
                  (error "Ebox :tab-index requires nil or an integer")))
               (:disabled
                (unless (memq value '(nil t))
                  (error "Ebox :disabled requires nil or t")))
               (:hover-style (ebox-interaction--hover-face value))
               (_ (error "Ebox has no interaction property %S" key)))))
  (let ((owned (tp-property-value-copy properties)))
    (when (plist-get properties :keymap)
      (setq owned (plist-put owned :keymap
                             (ebox-interaction--keymap-snapshot
                              (plist-get properties :keymap)))))
    owned))

(defun ebox-interaction-surface-properties (properties)
  "Project normalized node PROPERTIES to native surface facts."
  (append
   (when (plist-get properties :disabled) '(keymap nil))
   (cl-loop for (key value) on properties by #'cddr
           unless (or (memq key '(:tab-index :disabled))
                      (and (eq key :keymap) (plist-get properties :disabled)))
           append (if (eq key :hover-style)
                      (let* ((face (ebox-interaction--hover-face value))
                             (decoration
                              (cl-loop for (property entry) on value by #'cddr
                                       when (memq property
                                                  '(:text-decoration-line
                                                    :text-decoration-color
                                                    :text-decoration-style))
                                       append (list property entry)))
                             (paint
                              (cl-loop for (property entry) on face by #'cddr
                                       unless (memq property
                                                    '(:underline :overline
                                                      :strike-through))
                                       append (list property entry))))
                        (list 'ebox--hover-style
                              (when value (list :face paint :decoration decoration))
                              'mouse-face face))
                    (list (pcase key
                            (:help-echo 'help-echo) (:pointer 'pointer)
                            (:keymap 'keymap)) value)))))

(defun ebox-interaction--face-attribute (face attribute)
  "Return FACE's explicit ATTRIBUTE entry, following native face precedence."
  (cond
   ((null face) nil)
   ((and (consp face) (keywordp (car face)))
    (if-let* ((entry (plist-member face attribute)))
        (unless (eq (cadr entry) 'unspecified) (list attribute (cadr entry)))
      (ebox-interaction--face-attribute (plist-get face :inherit) attribute)))
   ((listp face)
    (cl-some (lambda (entry) (ebox-interaction--face-attribute entry attribute))
             face))
   ((facep face)
    (let ((value (face-attribute face attribute nil t)))
      (unless (eq value 'unspecified) (list attribute value))))))

(defun ebox-interaction--hover-decoration-face (declarations base)
  "Apply partial decoration DECLARATIONS to the effective BASE face."
  (when declarations
    (let* ((line-entry (plist-member declarations :text-decoration-line))
           (line (cadr line-entry))
           (lines (if (listp line) line (list line)))
           (color-entry (plist-member declarations :text-decoration-color))
           (color (cadr color-entry))
           (style-entry (plist-member declarations :text-decoration-style))
           (style (alist-get (cadr style-entry) ebox-buffer--decoration-style-map))
           face)
      (dolist (entry '((underline . :underline) (overline . :overline)
                       (line-through . :strike-through)))
        (let* ((property (cdr entry))
               (old (cadr (ebox-interaction--face-attribute base property)))
               (active (if line-entry (memq (car entry) lines) old)))
          (when (or line-entry active)
            (setq face
                  (plist-put
                   face property
                   (when active
                     (if (eq property :underline)
                         (let ((value (cond ((stringp old) (list :color old))
                                            ((consp old) (copy-sequence old)))))
                           (when color-entry
                             (if (eq color 'currentColor)
                                 (cl-remf value :color)
                               (setq value (plist-put value :color color))))
                           (when style-entry
                             (if (eq style 'line)
                                 (cl-remf value :style)
                               (setq value (plist-put value :style style))))
                           (or value t))
                       (if color-entry
                           (if (eq color 'currentColor) t color)
                         (or old t)))))))))
      face)))

(defvar ebox-interaction--hover-face-cache
  (make-hash-table :test #'equal :weakness 'value)
  "Weak cache preserving one native face identity per hover owner and paint.")

(defun ebox-interaction--node-surface-properties (node)
  "Return NODE's native surface facts with its computed hover base.
Native mouse highlighting paints one face across a contiguous region.  Its
unspecified attributes therefore use the hover owner's style, even when its
children have different ordinary text colors.  Explicit child hover remains
an independent region.  Physical border paint is handled during projection."
  (let* ((properties (ebox-get node :surface-properties))
         (declaration (plist-get properties 'ebox--hover-style)))
    (if (null declaration)
        properties
      (plist-put
       (copy-sequence properties) 'ebox--hover-style
       (append declaration
               (list :owner (ebox--ensure-region-id node)
                     :base (plist-get
                            (ebox-buffer-paint-text-properties node 'content)
                            'face)))))))

(defun ebox-interaction--hover-owner-base (declaration state)
  "Return DECLARATION's current owner face, resolving it in STATE when supplied."
  (let* ((owner (plist-get declaration :owner))
         (node-id (and state owner
                       (ebox-runtime-index-get
                        owner (plist-get state :region-node-table))))
         (node (and node-id
                    (ebox-runtime-index-get node-id (plist-get state :node-table))))
         (box (and node (ebox-fragment-style-source-node node))))
    (if box
        (plist-get (ebox-buffer-paint-text-properties box 'content) 'face)
      (plist-get declaration :base))))

(defun ebox-interaction--refresh-hover! (string start end &optional face state)
  "Project owned hover paint in STRING between START and END.
FACE supplies a fallback for legacy declarations without an owner.  STATE
resolves current owner paint during retained updates.  All interior runs with
the same owner and paint share the exact same native mouse face, including
padding.  Border glyphs are excluded; horizontal strokes keep their own paint."
  (let ((position start))
    (while (< position end)
      (setq position (or (text-property-not-all
                         position end 'ebox--hover-style nil string) end))
      (when (< position end)
        (let* ((next (next-property-change position string end))
               (declaration (get-text-property position 'ebox--hover-style string))
               (normal (or face (get-text-property position 'face string)))
               (base (if (plist-member declaration :owner)
                         (ebox-interaction--hover-owner-base declaration state)
                       normal))
               (hover (append
                       (ebox-interaction--hover-decoration-face
                        (plist-get declaration :decoration) base)
                       (plist-get declaration :face)))
               (faces (cond ((null base) nil)
                            ((and (consp base) (keywordp (car base))) (list base))
                            ((listp base) base)
                            (t (list base))))
               (side (or (get-text-property position 'ebox-bl string)
                         (get-text-property position 'ebox-br string)))
               (strokes
                (append
                 (when (get-text-property position 'ebox-bt string)
                   (ebox-interaction--face-attribute normal :overline))
                 (when (get-text-property position 'ebox-bb string)
                   (ebox-interaction--face-attribute normal :underline))))
               (combined (append (when strokes (list strokes))
                                 (when hover (list hover)) faces))
               (value (if (cdr combined) combined (car combined)))
               (key (list (plist-get declaration :owner) value))
               (shared (or (gethash key ebox-interaction--hover-face-cache)
                           (when value
                             (puthash key value ebox-interaction--hover-face-cache)))))
          (when (and state (plist-member declaration :owner)
                     (not (equal base (plist-get declaration :base))))
            (put-text-property
             position next 'ebox--hover-style
             (plist-put (copy-sequence declaration) :base base) string))
          (put-text-property position next 'mouse-face
                             (unless side shared) string)
          (setq position next)))))
  string)

(defun ebox-interaction-surface-equal-p (left right)
  "Compare native surface or interaction plists LEFT and RIGHT literally.
Literal callbacks retain identity; keymap snapshots use TP's native property
policy, which compares bindings while retaining command identity.  Paint and
data values use native value equality, before surface publication loads."
  (or (eq left right)
      (and (= (length left) (length right))
           (cl-loop for (property value) on left by #'cddr
                    for entry = (plist-member right property)
                    always (and entry
                                (cond
                                 ((or (keymapp value) (keymapp (cadr entry)))
                                  (funcall
                                   (tp-property-policy-equality
                                    (tp-register-text-property
                                     (if (eq property :keymap) 'keymap property)))
                                   value (cadr entry)))
                                 ((or (functionp value) (functionp (cadr entry)))
                                  (eq value (cadr entry)))
                                 (t (equal-including-properties
                                     value (cadr entry)))))))))

(defun ebox-interaction--fill-property (string start end property value)
  "Fill surface PROPERTY with VALUE in STRING between START and END.
Newlines are structural.  An inner explicit nil blocks enclosing values of
the four supported native properties, just as an inner non-nil value does."
  (let ((position start)
        (presence-p (memq property '(help-echo pointer mouse-face keymap
                                    ebox--hover-style))))
    (when (or value presence-p)
      (while (< position end)
        (let ((next (min (or (next-property-change position string end) end)
                         (or (string-match "\n" string position) end))))
          (if (= position next)
              (setq position (1+ position))
            (unless (if presence-p
                        (let ((props (text-properties-at position string)))
                          (or (plist-member props property)
                              (and (eq property 'ebox--hover-style)
                                   (plist-member props 'mouse-face))))
                      (get-text-property position property string))
              (add-text-properties position next (list property value) string))
            (when (eq property 'keymap)
                ;; Key lookup otherwise consults the preceding character at
                ;; the start of a non-front-sticky text-property interval.
                (dolist (sticky '(front-sticky rear-nonsticky))
                  (let ((existing (get-text-property position sticky string)))
                    (unless (eq existing t)
                      (put-text-property
                       position next sticky
                       (cons 'keymap (remq 'keymap (copy-sequence existing)))
                       string)))))
            (setq position next)))))))

(provide 'ebox-interaction)

;;; ebox-interaction.el ends here
