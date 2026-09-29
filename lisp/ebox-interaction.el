;;; ebox-interaction.el --- Fixed native node capabilities -*- lexical-binding: t; -*-

;;; Commentary:
;; Validates finite node interaction inputs, projects native text properties,
;; and owns mounted focus and navigation through publication and rollback.
;; Disabled and mounted focus feed the shared selector and cascade semantics.

;;; Code:

(require 'cl-lib)
(require 'ebox-text)
(require 'ebox-property)
(defvar ebox-selector-view--current)
(defvar ebox-selector-view--topology)
(defvar ebox-style--scopes)
(require 'ebox-publication)

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
(declare-function ebox-surface-buffer-observer "ebox-surface" (buffer))
(declare-function ebox-surface-call-with-observation "ebox-surface" (buffer stage function))
(declare-function ebox-surface--paint-node-chain "ebox-surface" (state role-ids))
(declare-function ebox--host-ref-node "ebox-runtime" (buffer host-ref))
(declare-function ebox-host-ref-bounds "ebox-runtime" (buffer-or-name host-ref))
(declare-function ebox--node-all-region-ids "ebox-runtime" (node))
(declare-function ebox-source--copy-data "ebox-source" (value))
(declare-function ebox-source--index-record "ebox-source" (index handle))
(declare-function ebox-source-record-key "ebox-source" (record))
(declare-function ebox-source-record-interactions "ebox-source" (record))
(declare-function ebox-source--handle-id-view "ebox-source" (handle))
(declare-function ebox-source-index-interactions "ebox-source" (index handle))
(declare-function ebox-tree-node-source-handle "ebox-tree" (node))
(declare-function ebox-tree-node-source-identity "ebox-tree" (node))
(declare-function ebox-tree-node-subject "ebox-tree" (source-index node))
(declare-function ebox-tree-node-source-declarations "ebox-tree" (source-index node))
(declare-function ebox-style-source-scopes "ebox-style" (source-index &optional root))
(declare-function ebox-tree-source-interaction-state "ebox-tree"
                  (index state target-handle old-handle))
(declare-function ebox-surface--stylesheet-signature "ebox-surface" ())
(declare-function ebox-surface--stylesheet-subject-local-p "ebox-surface"
                  (stylesheet-signature &optional fixed-scope-roots-p))
(declare-function ebox-surface--compute-node-style "ebox-surface"
                  (subject declarations parent-style))
(declare-function ebox--buffer-render-state "ebox-incremental" (buffer))
(declare-function ebox--buffer-runtime-node "ebox-incremental" (buffer node-id))
(declare-function ebox--buffer-host-ref-table "ebox-incremental" (buffer))
(declare-function ebox-selector--live-region-handle
                  "ebox-selector" (buffer object &optional logical-id))
(declare-function ebox-region-update "ebox" (handle &rest props))
(declare-function ebox-incremental-begin-batch "ebox" (buffer))
(declare-function ebox-incremental-flush "ebox" (buffer))
(declare-function ebox-incremental--ensure-buffer-selector-indexes "ebox-incremental" (buffer))
(declare-function ebox-incremental--static-style-bindings-p "ebox-incremental" (state))
(declare-function ebox--region-update-content-value "ebox-runtime" (box))
(declare-function ebox-geometry--interaction-capability "ebox-geometry" (buffer state))
(declare-function ebox-geometry--publish-interaction "ebox-geometry"
                  (buffer state operation stage rollback accept))
(declare-function ebox-source--interaction-slots-prepare "ebox-update-selector" (index handles))
(declare-function ebox-source--interaction-slots-index "ebox-update-selector" (slots))
(declare-function ebox-source--interaction-slots-current-p "ebox-update-selector" (slots index))
(declare-function ebox-source--interaction-slots-stage "ebox-update-selector"
                  (slots old-focus new-focus old-active new-active))
(declare-function ebox-source--interaction-slots-rollback "ebox-update-selector" (slots))
(defvar ebox-region-types)
(defvar ebox-buffer--decoration-style-map)

(defconst ebox-interaction-properties
  '(:help-echo :pointer :hover-style :hover-content :keymap :tab-index :disabled
    :drag-lock-modifier :hover-group)
  "Fixed node capabilities accepted outside the Ebox style schema.")

(defconst ebox-interaction--hover-properties
  '(:color :background-color :text-decoration-line
    :text-decoration-color :text-decoration-style)
  "Geometry-independent Ebox declarations accepted by `:hover-style'.")

(defvar ebox-interaction--dispatching-activation nil
  "Non-nil while invoking a target already selected by Ebox activation.")

(defvar-local ebox-interaction--hover-content-specs nil
  "Visible hover-content registrations for the current mounted buffer.")

(defvar-local ebox-interaction--hover-content-owner nil
  "Host reference whose hover content is currently active, or nil.")

(defvar-local ebox-interaction--hover-content-group nil
  "Active hover-content group key, or nil when no group is active.")

(defvar-local ebox-interaction--hover-content-bases nil
  "Alist of (HOST-REF . CONTENT) saved for the active hover-content group.")

(defvar-local ebox-interaction--hover-content-track-mouse nil
  "Saved local `track-mouse' binding while hover-content tracking is enabled.")

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
`:drag-lock-modifier' optionally names `shift', `control', `meta', `super' or
`hyper'.  Holding it for the initial primary-button press keeps the gesture
alive after the first release; motion continues to publish `move' until the
next primary-button press publishes `end'.  ESC cancels the locked gesture.
Each input round merges at most 64 pending same-window motions without waiting,
then publishes the latest position and redisplays.  Release, another press,
cancel, unrelated input and leaving the window are barriers.  A started gesture
has one end/cancel; consuming a locked release never delivers motion after end.
`:hover-group' groups sibling `:hover-content' nodes.  Entering one member
updates every member in one incremental batch; leaving the group restores all
members together.  Group keys are symbols, strings, numbers or nil.
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
             (unless (memq key '(:activate :bindings :drag :drag-lock-modifier))
               (error "Unknown Ebox keymap option: %S" key))
             (when (memq key seen)
               (error "Repeated Ebox keymap option: %S" key))
             (push key seen))
    (let ((activate (plist-get options :activate))
          (drag (plist-get options :drag))
          (drag-lock-modifier (plist-get options :drag-lock-modifier))
          (bindings (plist-get options :bindings)))
      (when (and drag-lock-modifier
                 (not (memq drag-lock-modifier
                            '(shift control meta super hyper))))
        (error "Ebox :drag-lock-modifier must be a supported modifier: %S"
               drag-lock-modifier))
      (when (and drag-lock-modifier (not drag))
        (error "Ebox :drag-lock-modifier requires :drag"))
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
        ;; Modifier-prefixed presses are claimed as well: otherwise a
        ;; lock-modifier drag (for example shift-click) leaves the press to a
        ;; global command such as shift-click region extension.
        (dolist (event (append
                        '(mouse-1 double-mouse-1 triple-mouse-1
                          down-mouse-1 double-down-mouse-1
                          triple-down-mouse-1 drag-mouse-1
                          double-drag-mouse-1 triple-drag-mouse-1)
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
                            (ebox-interaction--track-drag
                             press drag nil
                             (and drag-lock-modifier
                                  (memq drag-lock-modifier
                                        (event-modifiers press))))))
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
      xy)))

(defun ebox-interaction--track-drag
    (event callback &optional defer-active-p lock-p)
  "Track EVENT's committed owner and deliver gesture phases to CALLBACK.
When DEFER-ACTIVE-P is non-nil, defer transient active publication until
the first motion, so a click that releases immediately does not commit
pressed state. Drag callbacks keep immediate active feedback. When LOCK-P is
non-nil, the first release changes the gesture into a pointer lock; motion
continues until the next primary-button press, which publishes `end'. ESC
publishes `cancel'."
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
               started finished active-p locked finishing
               validated-state validated-revision validated-position)
          (cl-labels
              ((available ()
                 (and (window-live-p window) (buffer-live-p buffer)
                      (eq (window-buffer window) buffer)
                      (eq surface (ebox-surface--live-buffer-surface buffer))
                      (let ((current (ebox-surface--buffer-client-state buffer))
                            (revision (ebox--pub-surface-revision surface)))
                        (with-current-buffer buffer
                          (or (and (eq current validated-state)
                                   (eql revision validated-revision)
                                   validated-position
                                   (<= (point-min) validated-position)
                                   (< validated-position (point-max))
                                   (not (invisible-p validated-position))
                                   (not (equal (get-text-property validated-position 'display) "")))
                              (and (equal owner (ebox-interaction--resolve-focus-owner
                                                 current (plist-get current :source-index) identity owner key))
                                   (setq validated-position
                                         (or (ebox-interaction--native-position buffer current owner)
                                             (ebox-interaction--focus-position current owner)))
                                   (setq identity (ebox-interaction--focus-ref current owner)
                                         validated-state current
                                         validated-revision revision)))))))
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
                      (unless defer-active-p
                        (ebox-interaction--set-active identity buffer)
                        (setq active-p t))
                      (setq started t)
                      (emit 'start)
                      (track-mouse
                        (let ((track-mouse 'dragging) done)
                          (while (and (not done) (or finishing (available)))
                            ;; A timeout lets ordinary Emacs timers invalidate a
                            ;; removed owner or window even while the mouse rests.
                            (when-let* ((next (read-event nil nil 0.05)))
                              ;; `read-event' runs timers.  Do not deliver the
                              ;; event to an owner invalidated during that wait.
                              (unless (or finishing (available))
                                (push next unread-command-events)
                                (setq reason 'target-unavailable done t))
                              (when (and (not done) (not finishing)
                                         (mouse-movement-p next)
                                         (ebox-interaction--drag-position
                                          (event-start next) window))
                                ;; Only already pending motions are replaceable.
                                ;; Bound each drain so a busy input stream still
                                ;; publishes promptly.  The first semantic barrier
                                ;; returns unchanged to the native input queue.
                                (let ((count 1) (poll t))
                                  (while (and poll (< count 64) (available))
                                    (let ((candidate (read-event nil nil 0)))
                                      (cond
                                       ((null candidate) (setq poll nil))
                                       ((and (available)
                                             (mouse-movement-p candidate)
                                             (ebox-interaction--drag-position
                                              (event-start candidate) window))
                                        (setq next candidate count (1+ count)))
                                       (t (push candidate unread-command-events)
                                          (setq poll nil))))))
                                (unless (available)
                                  (setq reason 'target-unavailable done t)))
                              (setq last-event next)
                              (unless done
                                (let* ((modifiers (event-modifiers next))
                                       (primary-down
                                        (and (eq (event-basic-type next) button)
                                             (memq 'down modifiers)))
                                       (release (and (eq (event-basic-type next) button)
                                                     (not (memq 'down modifiers))))
                                       (motion (mouse-movement-p next)))
                                  (cond
                                   ((and locked
                                         (or (eq (event-basic-type next) 'escape)
                                             (equal next ?\e)))
                                    (setq reason 'quit done t))
                                   ((and finishing release)
                                    (setq done t))
                                   ((and finishing motion)
                                    ;; The second locked press already delivered
                                    ;; the terminal position.  Drain to its release
                                    ;; without publishing any later motion.
                                    nil)
                                   ((and locked primary-down)
                                    (if-let* ((xy (ebox-interaction--drag-position
                                                   (event-start next) window)))
                                        (progn
                                          (setq position xy finished t finishing t locked nil)
                                          (emit 'end)
                                          (redisplay t))
                                      (push next unread-command-events)
                                      (setq reason 'window-left done t)))
                                   ((or release motion)
                                    (when (and defer-active-p motion (not active-p))
                                      (ebox-interaction--set-active identity buffer)
                                      (setq active-p t))
                                    (let ((xy (and (available)
                                                   (ebox-interaction--drag-position
                                                    (if release (event-end next) (event-start next)) window))))
                                      (cond
                                       ((null xy) (setq reason 'window-left done t))
                                       (release
                                        (setq position xy)
                                        (if (and lock-p (not locked))
                                            (progn
                                              (setq locked t)
                                              (emit 'move))
                                          (setq finished t done t)
                                          (emit 'end)))
                                       ((not (equal xy position))
                                        (setq position xy)
                                        (emit 'move)))
                                      (redisplay t)))
                                   (t (push next unread-command-events)
                                      (setq reason 'input done t)))))))
                          (unless (available) (setq reason 'target-unavailable)))))
                  ((error quit)
                   (setq reason (if (eq (car problem) 'quit) 'quit 'error))
                   (signal (car problem) (cdr problem))))
              (unwind-protect
                  (when (and started (not finished)) (emit 'cancel))
                (when (and active-p (buffer-live-p buffer)
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
                 ;; A primary-button activation gives its target logical focus,
                 ;; just like RET. Resolve the accepted binding only after the
                 ;; release and focus publications have settled.
                 ;; Events dispatched for an unselected window must retain
                 ;; that window's point and selection; a click in the active
                 ;; window follows normal focus semantics.
                 (if (eq window (selected-window))
                     (ebox-interaction--release-active-and-focus reference buffer)
                   (ebox-interaction--set-active nil buffer))
                 ;; Resolve the accepted binding after release styles publish.
                 (let* ((current (ebox-surface--buffer-client-state buffer))
                        (owner (gethash reference (ebox--buffer-host-ref-table buffer)))
                        (map (and owner (ebox-interaction--owner-keymap current owner)))
                        (command (and map (lookup-key map release-key)))
                        (ebox-interaction--dispatching-activation t)
                        (last-input-event (plist-get gesture :event)))
                   (when (commandp command) (command-execute command)))))))))) t)

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
    (or (ebox-interaction--native-keymap-owner state map)
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
                              node-id))))))))))

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

(defun ebox-interaction--candidate-source (buffer old-state index source root &optional retained-topology-p)
  "Project BUFFER's requested or retained interactions into INDEX SOURCE.
RETAINED-TOPOLOGY-P certifies that ROOT and its source handles are unchanged."
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
        (setq source
              (if retained-topology-p
                  (ebox-tree-source-interaction-state
                   source "active" handle
                   (when-let* ((previous (ebox-interaction--focus-node
                                         old-state ebox-interaction--active-owner)))
                     (ebox-tree-node-source-handle previous)))
                (ebox-source--with-interaction-state source "active" handle)))))
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
	(let ((projected
               (if retained-topology-p
                   (ebox-tree-source-interaction-state
                    source "focus" handle
                    (when-let* ((previous (ebox-interaction--focus-node
                                          old-state ebox-interaction--focus-owner)))
                      (ebox-tree-node-source-handle previous)))
                 (ebox-source--with-interaction-state source "focus" handle))))
          (when handle
            (let* ((subjects (ebox-tree-style-source-index root projected))
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
        ebox-interaction--focus-order nil
        ebox-interaction--hover-content-owner nil
        ebox-interaction--hover-content-group nil
        ebox-interaction--hover-content-bases nil
        ebox-interaction--hover-content-specs nil)
  (when ebox-interaction--hover-content-track-mouse
    (let ((saved ebox-interaction--hover-content-track-mouse))
      (if (car saved)
          (setq-local track-mouse (cadr saved))
        (kill-local-variable 'track-mouse)))
    (setq ebox-interaction--hover-content-track-mouse nil)))

(defun ebox-interaction--commit-state (buffer state)
  "Publish an interaction request against BUFFER's accepted STATE.
The mounted root already owns a validated source generation. Transport that
generation directly instead of validating the whole author forest again."
  (unless (eq state (ebox-surface--buffer-client-state buffer))
    (error "Ebox interaction base is no longer current"))
  (ebox-commit buffer
               (ebox-canonical--make-input
                :nodes (list (plist-get state :root-node))
                :source-index (plist-get state :source-index))))

(defun ebox-interaction--set-active (host-ref buffer)
  "Publish HOST-REF as BUFFER's pressed owner, or clear it with nil."
  (with-current-buffer (ebox-interaction--focus-buffer buffer)
    (let* ((state (ebox-surface--buffer-client-state buffer))
           (owner (and host-ref (gethash host-ref (ebox--buffer-host-ref-table buffer)))))
      (when (and host-ref (not (and owner (or (ebox-interaction--native-position buffer state owner)
                                  (ebox-interaction--focus-position state owner)))))
        (user-error "No enabled visible Ebox pressed target"))
      (unless (equal owner ebox-interaction--active-owner)
        (unless (ebox-interaction--native-publish buffer state ebox-interaction--focus-owner owner nil)
          (let ((ebox-interaction--active-request (list buffer host-ref state)))
            (save-restriction
              (widen)
              (ebox-interaction--commit-state buffer state))))))))

(defun ebox-interaction--release-active-and-focus (host-ref buffer)
  "Clear the pressed state and focus HOST-REF in one publication.

Mouse activation used to publish the release and the resulting logical focus
as two independent Ebox commits.  Both requests are consumed by
`ebox-interaction--candidate-source' against the same base state, so keeping
them in one commit preserves selector ordering while avoiding a redundant
full owner walk.  Callers that do not own the selected window continue to
clear only the pressed state, matching native Emacs focus semantics."
  (with-current-buffer (ebox-interaction--focus-buffer buffer)
    (let* ((state (ebox-surface--buffer-client-state buffer))
           (owner (and host-ref
                       (gethash host-ref
                                (ebox--buffer-host-ref-table buffer))))
           (position (and owner (or (ebox-interaction--native-position buffer state owner)
                                  (ebox-interaction--focus-position state owner)))))
      (unless (and owner position)
        (user-error "No enabled visible Ebox focus target: %S" host-ref))
      (if (or (not (eq (selected-window) (get-buffer-window buffer t)))
              (equal owner ebox-interaction--focus-owner))
          (ebox-interaction--set-active nil buffer)
        (unless (ebox-interaction--native-publish buffer state owner nil t)
          (let ((ebox-interaction--active-request (list buffer nil state))
                (ebox-interaction--focus-request (list buffer host-ref state)))
            (save-restriction
              (widen)
              (ebox-interaction--commit-state buffer state))))))))

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
      (and (equal (point) (or (ebox-interaction--native-position
                              (current-buffer) state ebox-interaction--focus-owner)
                             (ebox-interaction--focus-position state ebox-interaction--focus-owner)))
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
  "Run native input READER for HOST-REF in BUFFER-OR-NAME.  READER is a
zero-argument function, for example a minibuffer read.  Return its result
only while the same mounted target remains enabled and visible; otherwise
signal `ebox-input-cancelled', a subtype of `quit'.  READER errors and user
quits propagate.  No result is applied to application state here.  Restore
logical focus to the retained target on return, error or quit when it is
still available.  Reorder and unrelated publication retain ownership;
replacement, unmount, deletion, hiding and disabling invalidate it.  This
function changes no window selection and owns no input buffer.  Native Emacs
readers own editing, input methods, selection and undo.  Call outside a Ebox
publication transaction; it must not write native text into an Ebox-owned
surface."
  (unless (functionp reader)
    (signal 'wrong-type-argument (list 'functionp reader)))
  (when (ebox-transaction-active-p)
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
  "Focus HOST-REF in BUFFER-OR-NAME, defaulting to the current buffer.  Return
the current opaque Host reference and move point to its first accessible
visible painted character, without selecting a window.  Any enabled visible
node may receive explicit focus, including a negative or absent
`:tab-index'.  Nil HOST-REF clears focus and preserves numeric point,
clamped after layout.  Focus changes publish the focus selector state and
its computed styles together.  Styles that make a newly requested target
inaccessible reject the operation.  Missing, disabled, hidden or
inaccessible targets signal `user-error' without changing focus or point.
Focus follows retained identity through publication.  Removal, hiding and
disabling clear it without choosing a replacement; navigation can then
restart.  Failed publication restores focus.  Unmount and buffer death
release it.  An active Ebox publication transaction is an error: call after
acceptance instead. Focus changes cannot join an outer transaction or expose
provisional targets."
  (when (ebox-transaction-active-p)
    (error "Ebox focus changes require an accepted transaction boundary"))
  (with-current-buffer (ebox-interaction--focus-buffer buffer-or-name)
    (let* ((state (ebox-surface--buffer-client-state (current-buffer)))
           (owner (and host-ref (gethash host-ref (ebox--buffer-host-ref-table (current-buffer)))))
           (position (and owner (or (ebox-interaction--native-position (current-buffer) state owner)
                                    (ebox-interaction--focus-position state owner)))))
      (when (and host-ref (not position))
        (user-error "No enabled visible Ebox focus target: %S" host-ref))
      (if (equal owner ebox-interaction--focus-owner)
          (when position (goto-char position))
        (unless (ebox-interaction--native-publish
                 (current-buffer) state owner ebox-interaction--active-owner t)
          (let ((ebox-interaction--focus-request (list (current-buffer) host-ref state)))
            (save-restriction
              (widen)
              (ebox-interaction--commit-state (current-buffer) state)))))
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
                     (min (point-max) (max (point-min) (nth 1 snapshot)))))))
    (ebox-interaction--hover-content-sync buffer)))

(defun ebox-interaction--focus-settle (buffer snapshot state)
  "Apply BUFFER's focus point after Ebox publication restores its native view
for STATE.

Hover-content bounds follow every committed publication: retained geometry
updates move hover targets without any focus change, and stale bounds would
stop `:hover-content' from ever activating.
"
  (when (and (buffer-live-p buffer)
             (eq state (ebox-surface--buffer-client-state buffer)))
    (when (or (car snapshot)
              (ebox-interaction--focus-request-for buffer (nth 5 snapshot)))
      (with-current-buffer buffer
        (let ((position (and (or (nth 2 snapshot)
                                 (ebox-interaction--focus-request-for buffer (nth 5 snapshot)))
                             (ebox-interaction--focus-position
                              state ebox-interaction--focus-owner))))
          (goto-char (or position
                         (min (point-max) (max (point-min) (nth 1 snapshot))))))))
    (with-current-buffer buffer
      (ebox-interaction--hover-content-sync buffer))))

(defun ebox-interaction--rollback (buffer snapshot)
  "Restore BUFFER's interaction owners after publication rejection."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ebox-interaction--focus-owner (car snapshot)
            ebox-interaction--active-owner (nth 6 snapshot)
            ebox-interaction--focus-order nil))))

(cl-defstruct (ebox-interaction--geometry-target
               (:constructor ebox-interaction--geometry-target-create))
  "Cold-owned lookup and bounds storage for one retained interaction target."
  owner ref primary-start primary-end primary-position
  fallback-start fallback-end fallback-position position
  hover-spec hover-cell hover-bounds old-hover-bounds old-start old-end
  native-p eligible old-position handle)

(cl-defstruct (ebox-interaction--geometry
               (:constructor ebox-interaction--geometry-create))
  "Prepared interaction dependencies and reusable publication rollback cells."
  buffer surface state targets bindings focus active focus-owner active-owner
  hover-specs tracking-backup
  mask next-focus next-active next-position follow point staged old-focus-position
  old-focus old-active old-order old-hover-specs
  old-track-local old-track-value old-tracking
  target-table state-slots native native-keymaps)

(cl-defstruct (ebox-interaction--native
               (:constructor ebox-interaction--native-create))
  "Cold native state publication storage for one shared prepared scene."
  capability unsafe-mask report
  next-focus next-active requested-focus next-position follow point staged
  old-focus old-active old-order old-cap-focus old-cap-active
  old-cap-focus-owner old-cap-active-owner old-revision old-report
  old-report-revision old-report-publication old-layer-revision)

(defun ebox-interaction--selector-native-state-mask (selector)
  "Return focus/active dependency bits in the public ECSS SELECTOR AST.
Unknown forms conservatively depend on both states.  This cold proof remains
valid when prepared class or declaration values change."
  (pcase (car-safe selector)
    ((or :universal :type :id :class :attr :anchor :scope-root) 0)
    (:state
     (let* ((value (cadr selector))
            (name (if (consp value) (car value) value)))
       (logior (cond ((equal name "focus") 1) ((equal name "active") 2) (t 0))
               (if (and (consp value) (nth 2 value))
                   (ebox-interaction--selector-native-state-mask (nth 2 value))
                 0))))
    ((or :and :list :is :where :not :has :descendant :child :adjacent :sibling)
     (let ((mask 0))
       (dolist (branch (cdr selector))
         (setq mask (logior mask (ebox-interaction--selector-native-state-mask branch))))
       mask))
    (_ 3)))

(defun ebox-interaction--native-state-style-mask (state source)
  "Return STATE's cold focus/active style dependency bits for SOURCE.
Every global and mounted-scope rule participates, including selector scopes.
Independent dynamic evaluators are unsupported.  No match or computed-style
equality is assumed for future class values."
  (catch 'unsupported
    (condition-case nil
        (let* ((ebox-style--scopes (ebox-style-source-scopes source (plist-get state :root-node)))
               (signature (ebox-surface--stylesheet-signature))
               (mask 0))
          (unless (and (equal signature (plist-get state :stylesheet-signature))
                       (ebox-incremental--static-style-bindings-p state))
            (throw 'unsupported 3))
          (dolist (handle (ebox-source-index-handles source))
            (let ((declarations (ebox-source-record-declarations (ebox-source--index-record source handle))))
              (while declarations
                (when (or (functionp (cadr declarations))
                          (ecss-declaration-value-tagged-p (cadr declarations)))
                  (throw 'unsupported 3))
                (setq declarations (cddr declarations)))))
          (cl-labels
              ((include (rule)
                 (setq mask
                       (logior mask
                               (ebox-interaction--selector-native-state-mask (ecss-rule-selector rule))
                               (if (ecss-rule-scope rule)
                                   (ebox-interaction--selector-native-state-mask (ecss-rule-scope rule))
                                 0)))))
            (mapc #'include (car signature))
            (dolist (scope ebox-style--scopes)
              (mapc #'include (ecss-stylesheet-rules (ecss-scope-stylesheet scope)))))
          mask)
      (error 3))))

(defun ebox-interaction--geometry-prepare (buffer state surface)
  "Prepare fixed interaction dependencies for BUFFER's STATE and SURFACE.
Private selector-state slots share the prepared source and declaration
context.  A cold selector dependency mask admits only state changes that
cannot affect styles, without excluding visible translations."
  (require 'ebox-update-selector)
  (with-current-buffer buffer
    (when (or (plist-get state :selector-index-stale-p)
              (ebox-source--index-derived-stale-p (plist-get state :source-index)))
      (plist-put state :selector-index-stale-p t)
      (setq state (ebox-incremental--ensure-buffer-selector-indexes buffer)))
    (let* ((source (plist-get state :source-index))
           (focus-owner ebox-interaction--focus-owner)
           (active-owner ebox-interaction--active-owner)
           (targets (make-hash-table :test #'eql))
           (bindings (make-hash-table :test #'eq))
           focus active hover-specs state-slots)
      (cl-labels
          ((target (owner &optional native)
             (let ((entry
                    (or (gethash owner targets)
                        (let* ((node (ebox-interaction--focus-node state owner))
                               (entry (ebox-interaction--geometry-target-create
                                       :owner owner :ref (ebox-interaction--focus-ref state owner)
                                       :handle (ebox-tree-node-source-handle node)
                                       :eligible (not (plist-get (ebox-interaction--focus-properties state owner)
                                                                 :disabled))
                                       :position (ebox-interaction--focus-position state owner))))
                          (dolist (region (ebox--node-all-region-ids node))
                            (when-let* ((object (gethash region
                                                         (plist-get state :region-surface-object-table))))
                              (puthash object (cons (cons entry region) (gethash object bindings)) bindings)))
                          (puthash owner entry targets)
                          entry))))
               (when native (setf (ebox-interaction--geometry-target-native-p entry) t))
               entry)))
        (when focus-owner (setq focus (target focus-owner t)))
        (when active-owner (setq active (target active-owner t)))
        ;; Preparation visits declared capabilities once, including currently
        ;; occluded hover targets which can be revealed by later translation.
        (maphash
         (lambda (ref owner)
           (let* ((node (ebox-interaction--focus-node state owner))
                  (facts (ebox-interaction--focus-properties state owner))
                  (content (plist-get facts :hover-content)))
             (when (or (plist-get facts :keymap) (integerp (plist-get facts :tab-index)))
               (target owner t))
             (when content
               (when-let* ((editable (ebox-interaction--hover-content-handle buffer node state)))
                 (let* ((entry (target owner))
                        (bounds (cons 0 0))
                        (spec (list :ref ref :node node :handle editable :content content
                                    :group (plist-get facts :hover-group) :bounds nil)))
                   (setf (ebox-interaction--geometry-target-hover-spec entry) spec
                         (ebox-interaction--geometry-target-hover-cell entry) (cdr (plist-member spec :bounds))
                         (ebox-interaction--geometry-target-hover-bounds entry) bounds)
                   (push spec hover-specs))))))
         (ebox--buffer-host-ref-table buffer)))
      (setq state-slots
            (ebox-source--interaction-slots-prepare
             source (vconcat (mapcar #'ebox-interaction--geometry-target-handle
                                     (hash-table-values targets)))))
      (when state-slots
        (setq source (ebox-source--interaction-slots-index state-slots))
        (plist-put state :source-index source)
        (plist-put state :selector-id-table (ebox-source--index-selector-table source 'id))
        (plist-put state :selector-class-table (ebox-source--index-selector-table source 'class))
        (plist-put state :selector-type-table (ebox-source--index-selector-table source 'type))
        (plist-put state :selector-index-stale-p nil))
      (unless (plist-member state :selector-index-stale-p)
        (plist-put state :selector-index-stale-p nil))
      (let ((capability
             (ebox-interaction--geometry-create
              :buffer buffer :surface surface :state state
              :targets (vconcat (hash-table-values targets)) :bindings bindings :target-table targets
              :focus focus :active active :focus-owner focus-owner :active-owner active-owner
              :state-slots state-slots
              :hover-specs hover-specs
              :tracking-backup (or ebox-interaction--hover-content-track-mouse
                                   (list (local-variable-p 'track-mouse) track-mouse)))))
        (setf (ebox-interaction--geometry-native-keymaps capability)
              (ebox-interaction--native-keymaps-prepare capability))
        (when state-slots
          (setf (ebox-interaction--geometry-native capability)
                (ebox-interaction--native-create
                 :capability capability :unsafe-mask (ebox-interaction--native-state-style-mask state source)
                 :report (list :strategy 'metadata-update :projection-kind 'prepared-interaction
                               :dirty-kinds '(selector) :prepared-interaction-p t
                               :revision 0 :publication nil))))
        capability))))

(defun ebox-interaction--geometry-owner-handle (capability owner)
  "Read OWNER's cold source handle in CAPABILITY, or nil for no owner."
  (when-let* ((target (and owner (gethash owner (ebox-interaction--geometry-target-table capability)))))
    (ebox-interaction--geometry-target-handle target)))

(defun ebox-interaction--native-keymaps-prepare (capability)
  "Index unambiguous native map owners in CAPABILITY's accepted text.
A shared map observed on different declaring targets retains the ordinary
ownership lookup.  This cold pass adds no alternative mouse dispatch."
  (let* ((surface (ebox-interaction--geometry-surface capability))
         (state (ebox-interaction--geometry-state capability))
         (targets (ebox-interaction--geometry-target-table capability))
         (maps (make-hash-table :test #'eq :size (max 1 (hash-table-count targets))))
         ;; A run's owner depends only on its map and region properties, so
         ;; repeated runs of one declaration resolve their ancestry once.
         (owners (make-hash-table :test #'eq))
         (position (max (point-min) (marker-position (ebox--pub--surface-start surface))))
         (limit (min (point-max) (marker-position (ebox--pub--surface-end surface)))))
    (while (< position limit)
      (let ((end (next-property-change position nil limit))
            (map (get-text-property position 'keymap))
            (probe position))
        (while (and (< probe end) (eq (char-after probe) ?\n))
          (setq probe (1+ probe)))
        (when (and (< probe end) (keymapp map)
                   (not (eq (gethash map maps) 'ebox/ambiguous)))
          (let* ((regions (cl-loop for (_role . property) in ebox-region-types
                                   collect (get-text-property probe property)))
                 (known (or (gethash map owners)
                            (puthash map (make-hash-table :test #'equal) owners)))
                 (owner (let ((cached (gethash regions known 'ebox/unknown)))
                          (if (eq cached 'ebox/unknown)
                              (puthash regions (ebox-interaction--navigation-owner probe state)
                                       known)
                            cached)))
                 (target (and owner (gethash owner targets)))
                 (previous (gethash map maps 'ebox/unknown)))
            (if (and target (ebox-interaction--geometry-target-native-p target))
                (cond ((eq previous 'ebox/unknown) (puthash map target maps))
                      ((not (eq previous target)) (puthash map 'ebox/ambiguous maps)))
              (puthash map 'ebox/ambiguous maps))))
        (setq position end)))
    maps))

(defun ebox-interaction--native-keymap-owner (state map)
  "Resolve an accepted MAP in STATE's cold native owner index, or decline."
  (when-let* ((capability (ebox-interaction--current-native-capability (current-buffer) state))
              (target (gethash map (ebox-interaction--geometry-native-keymaps capability)))
              ((ebox-interaction--geometry-target-p target)))
    (ebox-interaction--geometry-target-owner target)))

(defun ebox-interaction--current-native-capability (buffer state)
  "Return BUFFER's current compiled native state capability for STATE."
  (when (and (not (buffer-narrowed-p))
             (not (ebox-transaction-active-p)))
    (let ((capability (ebox-geometry--interaction-capability buffer state)))
      (and capability (ebox-interaction--geometry-native capability)
           (ebox-source--interaction-slots-current-p
            (ebox-interaction--geometry-state-slots capability) (plist-get state :source-index))
           capability))))

(defun ebox-interaction--native-target-position (capability owner)
  "Read OWNER's accepted visible native position from CAPABILITY's index."
  (when-let* ((target (and owner (gethash owner (ebox-interaction--geometry-target-table capability))))
              ((ebox-interaction--geometry-target-native-p target))
              ((ebox-interaction--geometry-target-eligible target))
              (position (ebox-interaction--geometry-target-position target)))
    (and (<= (point-min) position) (< position (point-max))
         (not (invisible-p position))
         (not (equal (get-text-property position 'display) ""))
         position)))

(defun ebox-interaction--native-position (buffer state owner)
  "Return OWNER's compiled position when BUFFER's prepared STATE is current."
  (when-let* ((capability (ebox-interaction--current-native-capability buffer state)))
    (ebox-interaction--native-target-position capability owner)))

(defun ebox-interaction--native-stage (operation publication-report)
  "Stage OPERATION's native source facts and logical owners atomically."
  (let* ((capability (ebox-interaction--native-capability operation))
         (state (ebox-interaction--geometry-state capability))
         (report (ebox-interaction--native-report operation)))
    (with-current-buffer (ebox-interaction--geometry-buffer capability)
      (setf (ebox-interaction--native-old-focus operation) ebox-interaction--focus-owner
            (ebox-interaction--native-old-active operation) ebox-interaction--active-owner
            (ebox-interaction--native-old-order operation) ebox-interaction--focus-order
            (ebox-interaction--native-old-cap-focus operation) (ebox-interaction--geometry-focus capability)
            (ebox-interaction--native-old-cap-active operation) (ebox-interaction--geometry-active capability)
            (ebox-interaction--native-old-cap-focus-owner operation) (ebox-interaction--geometry-focus-owner capability)
            (ebox-interaction--native-old-cap-active-owner operation) (ebox-interaction--geometry-active-owner capability)
            (ebox-interaction--native-old-revision operation) (plist-get state :runtime-revision)
            (ebox-interaction--native-old-layer-revision operation)
            (plist-get state :layer-composition-revision)
            (ebox-interaction--native-old-report operation) (plist-get state :last-update-report)
            (ebox-interaction--native-old-report-revision operation) (plist-get report :revision)
            (ebox-interaction--native-old-report-publication operation) (plist-get report :publication)
            (ebox-interaction--native-staged operation) t)
      (ebox-source--interaction-slots-stage
       (ebox-interaction--geometry-state-slots capability)
       (ebox-interaction--geometry-owner-handle capability ebox-interaction--focus-owner)
       (ebox-interaction--geometry-owner-handle capability (ebox-interaction--native-next-focus operation))
       (ebox-interaction--geometry-owner-handle capability ebox-interaction--active-owner)
       (ebox-interaction--geometry-owner-handle capability (ebox-interaction--native-next-active operation)))
      (setq ebox-interaction--focus-owner (ebox-interaction--native-next-focus operation)
            ebox-interaction--active-owner (ebox-interaction--native-next-active operation))
      (plist-put state :runtime-revision (1- (plist-get publication-report :new-revision)))
      ;; This route proved selector independence and retains the exact output
      ;; and mounts.  Advance only a previously current raster baseline.
      (when (eql (ebox-interaction--native-old-layer-revision operation)
                 (ebox-interaction--native-old-revision operation))
        (plist-put state :layer-composition-revision
                   (plist-get state :runtime-revision)))
      (plist-put report :revision (plist-get publication-report :new-revision))
      (plist-put report :publication publication-report)
      (plist-put state :last-update-report report)
      (when (and (ebox-interaction--native-requested-focus operation)
                 (ebox-interaction--native-next-position operation))
        (goto-char (ebox-interaction--native-next-position operation))))))

(defun ebox-interaction--native-accept (operation _report)
  "Settle OPERATION's logical focus after native view restoration."
  (let* ((capability (ebox-interaction--native-capability operation))
         (targets (ebox-interaction--geometry-target-table capability)))
    (with-current-buffer (ebox-interaction--geometry-buffer capability)
      (let ((position (ebox-interaction--native-next-position operation)))
        (when (or (ebox-interaction--native-requested-focus operation)
                  (ebox-interaction--native-old-focus operation))
          (goto-char
           (if (and position (or (ebox-interaction--native-requested-focus operation)
                                 (ebox-interaction--native-follow operation)))
               position
             (min (point-max) (max (point-min) (ebox-interaction--native-point operation)))))))
      (setf (ebox-interaction--geometry-focus capability) (gethash ebox-interaction--focus-owner targets)
            (ebox-interaction--geometry-active capability) (gethash ebox-interaction--active-owner targets)
            (ebox-interaction--geometry-focus-owner capability) ebox-interaction--focus-owner
            (ebox-interaction--geometry-active-owner capability) ebox-interaction--active-owner))))

(defun ebox-interaction--native-rollback (operation _report)
  "Restore OPERATION's source, owners, point and report after rejection."
  (when (ebox-interaction--native-staged operation)
    (let* ((capability (ebox-interaction--native-capability operation))
           (state (ebox-interaction--geometry-state capability))
           (report (ebox-interaction--native-report operation)))
      (ebox-source--interaction-slots-rollback (ebox-interaction--geometry-state-slots capability))
      (with-current-buffer (ebox-interaction--geometry-buffer capability)
        (setq ebox-interaction--focus-owner (ebox-interaction--native-old-focus operation)
              ebox-interaction--active-owner (ebox-interaction--native-old-active operation)
              ebox-interaction--focus-order (ebox-interaction--native-old-order operation))
        (goto-char (min (point-max) (max (point-min) (ebox-interaction--native-point operation)))))
      (setf (ebox-interaction--geometry-focus capability) (ebox-interaction--native-old-cap-focus operation)
            (ebox-interaction--geometry-active capability) (ebox-interaction--native-old-cap-active operation)
            (ebox-interaction--geometry-focus-owner capability) (ebox-interaction--native-old-cap-focus-owner operation)
            (ebox-interaction--geometry-active-owner capability) (ebox-interaction--native-old-cap-active-owner operation))
      (plist-put state :runtime-revision (ebox-interaction--native-old-revision operation))
      (plist-put state :layer-composition-revision
                 (ebox-interaction--native-old-layer-revision operation))
      (plist-put state :last-update-report (ebox-interaction--native-old-report operation))
      (plist-put report :revision (ebox-interaction--native-old-report-revision operation))
      (plist-put report :publication (ebox-interaction--native-old-report-publication operation)))
    (setf (ebox-interaction--native-staged operation) nil)))

(defun ebox-interaction--native-publish (buffer state focus active requested-focus)
  "Publish compiled native state with BUFFER's optional observation scope."
  (if (ebox-surface-buffer-observer buffer)
      (ebox-surface-call-with-observation
       buffer 'interaction
       (lambda () (ebox-interaction--native-publish-direct buffer state focus active requested-focus)))
    (ebox-interaction--native-publish-direct buffer state focus active requested-focus)))

(defun ebox-interaction--native-publish-direct (buffer state focus active requested-focus)
  "Publish no-style native FOCUS and ACTIVE changes in BUFFER's shared STATE.
REQUESTED-FOCUS preserves explicit focus and native release point semantics.
Unknown targets or selector dependencies decline before source mutation."
  (when-let* ((capability (ebox-interaction--current-native-capability buffer state)))
    (let* ((operation (ebox-interaction--geometry-native capability))
           (targets (ebox-interaction--geometry-target-table capability))
           (focus-position (and focus (ebox-interaction--native-target-position capability focus)))
           (active-position (and active (ebox-interaction--native-target-position capability active)))
           (changed (+ (if (equal focus ebox-interaction--focus-owner) 0 1)
                       (if (equal active ebox-interaction--active-owner) 0 2))))
      (when (and (= 0 (logand changed (ebox-interaction--native-unsafe-mask operation)))
                 (or (null focus) focus-position)
                 (or (null active) active-position)
                 (or (null ebox-interaction--focus-owner) (gethash ebox-interaction--focus-owner targets))
                 (or (null ebox-interaction--active-owner) (gethash ebox-interaction--active-owner targets)))
        (setf (ebox-interaction--native-next-focus operation) focus
              (ebox-interaction--native-next-active operation) active
              (ebox-interaction--native-requested-focus operation) requested-focus
              (ebox-interaction--native-next-position operation) focus-position
              (ebox-interaction--native-point operation) (point)
              (ebox-interaction--native-follow operation)
              (and ebox-interaction--focus-owner
                   (equal (point) (ebox-interaction--geometry-target-position
                                   (gethash ebox-interaction--focus-owner targets))))
              (ebox-interaction--native-staged operation) nil)
        (when (ebox-geometry--publish-interaction
               buffer state operation #'ebox-interaction--native-stage
               #'ebox-interaction--native-rollback #'ebox-interaction--native-accept)
          (setf (ebox-interaction--native-staged operation) nil)
          t)))))

(defun ebox-interaction--geometry-painted-position (rendered start end)
  "Return the first visible painted offset in RENDERED's START..END interval."
  (let ((position start) found)
    (while (and (< position end) (not found))
      (cond
       ((eq (aref rendered position) ?\n) (setq position (1+ position)))
       ((or (invisible-p (get-text-property position 'invisible rendered))
            (equal (get-text-property position 'display rendered) ""))
        (setq position (next-property-change position rendered end)))
       (t (setq found position))))
    found))

(defun ebox-interaction--geometry-ready-p (capability slots count rendered)
  "Resolve CAPABILITY against candidate SLOTS before publishing RENDERED.
Visit actual output mount metadata and cold target bindings, never the Box
tree.  Return nil before mutation if a required interaction style change
would need general rendering."
  (with-current-buffer (ebox-interaction--geometry-buffer capability)
    (when (and (not (buffer-narrowed-p))
               (or (null ebox-interaction--focus-owner)
                   (eql ebox-interaction--focus-owner
                        (ebox-interaction--geometry-focus-owner capability)))
               (or (null ebox-interaction--active-owner)
                   (eql ebox-interaction--active-owner
                        (ebox-interaction--geometry-active-owner capability))))
      (let ((targets (ebox-interaction--geometry-targets capability))
            (bindings (ebox-interaction--geometry-bindings capability))
            (base (marker-position (ebox--pub--surface-start
                                    (ebox-interaction--geometry-surface capability)))))
        (setf (ebox-interaction--geometry-point capability) (point)
              (ebox-interaction--geometry-old-focus-position capability)
              (and (ebox-interaction--geometry-focus capability)
                   (ebox-interaction--geometry-target-position
                    (ebox-interaction--geometry-focus capability)))
              (ebox-interaction--geometry-follow capability)
              (and ebox-interaction--focus-owner
                   (equal (point) (ebox-interaction--geometry-target-position
                                   (ebox-interaction--geometry-focus capability)))))
        (dotimes (index (length targets))
          (let ((entry (aref targets index)))
            (setf (ebox-interaction--geometry-target-old-position entry)
                  (ebox-interaction--geometry-target-position entry)
                  (ebox-interaction--geometry-target-primary-start entry) nil
                  (ebox-interaction--geometry-target-primary-end entry) nil
                  (ebox-interaction--geometry-target-primary-position entry) nil
                  (ebox-interaction--geometry-target-fallback-start entry) nil
                  (ebox-interaction--geometry-target-fallback-end entry) nil
                  (ebox-interaction--geometry-target-fallback-position entry) nil)))
        (dotimes (index (if (= (length targets) 0) 0 count))
          (let* ((offset (* index 4))
                 (mount (aref slots offset))
                 (start (aref slots (1+ offset)))
                 (end (aref slots (+ offset 2)))
                 (tags (aref slots (+ offset 3)))
                 (known (gethash (ebox--pub--surface-mount-object mount) bindings)))
            (when (< start end)
              (dolist (binding known)
                (let* ((entry (car binding))
                       (same (equal (cdr binding) (plist-get tags :ebox/region-id)))
                       (roles (and same (plist-get tags :ebox/roles)))
                       primary)
                  (while (and roles (not primary))
                    (setq primary (memq (car roles) ebox--horizontal-border-anchor-roles)
                          roles (cdr roles)))
                  (when (or same (plist-get tags :ebox/descendant-output))
                    (let ((position (ebox-interaction--geometry-painted-position rendered start end)))
                      (setf (ebox-interaction--geometry-target-fallback-start entry)
                            (min start (or (ebox-interaction--geometry-target-fallback-start entry) start))
                            (ebox-interaction--geometry-target-fallback-end entry)
                            (max end (or (ebox-interaction--geometry-target-fallback-end entry) end)))
                      (when position
                        (setf (ebox-interaction--geometry-target-fallback-position entry)
                              (min position (or (ebox-interaction--geometry-target-fallback-position entry) position))))))
                  (when primary
                    (let ((position (ebox-interaction--geometry-painted-position rendered start end)))
                      (setf (ebox-interaction--geometry-target-primary-start entry)
                            (min start (or (ebox-interaction--geometry-target-primary-start entry) start))
                            (ebox-interaction--geometry-target-primary-end entry)
                            (max end (or (ebox-interaction--geometry-target-primary-end entry) end)))
                      (when position
                        (setf (ebox-interaction--geometry-target-primary-position entry)
                              (min position (or (ebox-interaction--geometry-target-primary-position entry) position)))))))))))
        (let* ((focus (ebox-interaction--geometry-focus capability))
               (active (ebox-interaction--geometry-active capability))
               (focus-position
                (and focus ebox-interaction--focus-owner
                     (if (ebox-interaction--geometry-target-primary-start focus)
                         (ebox-interaction--geometry-target-primary-position focus)
                       (ebox-interaction--geometry-target-fallback-position focus))))
               (active-position
                (and active ebox-interaction--active-owner
                     (if (ebox-interaction--geometry-target-primary-start active)
                         (ebox-interaction--geometry-target-primary-position active)
                       (ebox-interaction--geometry-target-fallback-position active))))
               (mask (+ (if focus-position 1 0) (if active-position 2 0))))
          (setf (ebox-interaction--geometry-mask capability) mask
                (ebox-interaction--geometry-next-focus capability) (and focus-position ebox-interaction--focus-owner)
                (ebox-interaction--geometry-next-active capability) (and active-position ebox-interaction--active-owner)
                (ebox-interaction--geometry-next-position capability) (and focus-position (+ base focus-position)))
          (= 0 (logand (ebox-interaction--native-unsafe-mask
                        (ebox-interaction--geometry-native capability))
                       (+ (if (and ebox-interaction--focus-owner (null focus-position)) 1 0)
                          (if (and ebox-interaction--active-owner (null active-position)) 2 0)))))))))

(defun ebox-interaction--geometry-stage (capability)
  "Stage CAPABILITY's preflighted source facts and current native input bounds."
  (with-current-buffer (ebox-interaction--geometry-buffer capability)
    (setf (ebox-interaction--geometry-old-focus capability) ebox-interaction--focus-owner
          (ebox-interaction--geometry-old-active capability) ebox-interaction--active-owner
          (ebox-interaction--geometry-old-order capability) ebox-interaction--focus-order
          (ebox-interaction--geometry-old-hover-specs capability) ebox-interaction--hover-content-specs
          (ebox-interaction--geometry-old-track-local capability) (local-variable-p 'track-mouse)
          (ebox-interaction--geometry-old-track-value capability) track-mouse
          (ebox-interaction--geometry-old-tracking capability) ebox-interaction--hover-content-track-mouse
          (ebox-interaction--geometry-staged capability) t)
    (ebox-source--interaction-slots-stage
     (ebox-interaction--geometry-state-slots capability)
     (ebox-interaction--geometry-owner-handle capability ebox-interaction--focus-owner)
     (ebox-interaction--geometry-owner-handle capability (ebox-interaction--geometry-next-focus capability))
     (ebox-interaction--geometry-owner-handle capability ebox-interaction--active-owner)
     (ebox-interaction--geometry-owner-handle capability (ebox-interaction--geometry-next-active capability)))
    (setq ebox-interaction--focus-owner (ebox-interaction--geometry-next-focus capability)
          ebox-interaction--active-owner (ebox-interaction--geometry-next-active capability)
          ebox-interaction--focus-order nil
          ebox-interaction--hover-content-specs (ebox-interaction--geometry-hover-specs capability))
    (let ((targets (ebox-interaction--geometry-targets capability))
          (base (marker-position (ebox--pub--surface-start
                                  (ebox-interaction--geometry-surface capability))))
          visible)
      (dotimes (index (length targets))
        (let* ((entry (aref targets index))
               (cell (ebox-interaction--geometry-target-hover-cell entry))
               (bounds (ebox-interaction--geometry-target-hover-bounds entry)))
          (when cell
            (setf (ebox-interaction--geometry-target-old-hover-bounds entry) (car cell)
                  (ebox-interaction--geometry-target-old-start entry) (car bounds)
                  (ebox-interaction--geometry-target-old-end entry) (cdr bounds))
            (let* ((primary (ebox-interaction--geometry-target-primary-start entry))
                   (start (or primary (ebox-interaction--geometry-target-fallback-start entry)))
                   (end (if primary (ebox-interaction--geometry-target-primary-end entry)
                          (ebox-interaction--geometry-target-fallback-end entry))))
              (if (and start end (< start end))
                  (progn (setcar bounds (+ base start)) (setcdr bounds (+ base end))
                         (setcar cell bounds) (setq visible t))
                (setcar cell nil))))))
      (cond
       (visible
        (unless ebox-interaction--hover-content-track-mouse
          (setq ebox-interaction--hover-content-track-mouse
                (ebox-interaction--geometry-tracking-backup capability)))
        (setq-local track-mouse t))
       (ebox-interaction--hover-content-track-mouse
        (let ((saved ebox-interaction--hover-content-track-mouse))
          (if (car saved) (setq-local track-mouse (cadr saved))
            (kill-local-variable 'track-mouse)))
        (setq ebox-interaction--hover-content-track-mouse nil))))))

(defun ebox-interaction--geometry-sync-owners (capability)
  "Bind CAPABILITY's mutable-state focus targets to their accepted owners."
  (when (ebox-interaction--geometry-state-slots capability)
    (with-current-buffer (ebox-interaction--geometry-buffer capability)
      (let ((targets (ebox-interaction--geometry-target-table capability)))
        (setf (ebox-interaction--geometry-focus capability) (gethash ebox-interaction--focus-owner targets)
              (ebox-interaction--geometry-active capability) (gethash ebox-interaction--active-owner targets)
              (ebox-interaction--geometry-focus-owner capability) ebox-interaction--focus-owner
              (ebox-interaction--geometry-active-owner capability) ebox-interaction--active-owner)))))

(defun ebox-interaction--geometry-accept (capability)
  "Settle CAPABILITY's logical focus after the publisher restores native view."
  (with-current-buffer (ebox-interaction--geometry-buffer capability)
    (let ((position (ebox-interaction--geometry-next-position capability)))
      (when (ebox-interaction--geometry-old-focus capability)
        (goto-char (if (and position (ebox-interaction--geometry-follow capability)) position
                     (min (point-max) (max (point-min) (ebox-interaction--geometry-point capability)))))))
    (let ((targets (ebox-interaction--geometry-targets capability))
          (base (marker-position (ebox--pub--surface-start
                                  (ebox-interaction--geometry-surface capability)))))
      (dotimes (index (length targets))
        (let* ((entry (aref targets index))
               (position (if (ebox-interaction--geometry-target-primary-start entry)
                             (ebox-interaction--geometry-target-primary-position entry)
                           (ebox-interaction--geometry-target-fallback-position entry))))
          (setf (ebox-interaction--geometry-target-position entry)
                (and position (ebox-interaction--geometry-target-eligible entry) (+ base position)))))))
  (ebox-interaction--geometry-sync-owners capability))

(defun ebox-interaction--geometry-rollback (capability)
  "Restore CAPABILITY's saved source and interaction slots without reading mounts."
  ;; Teardown owns a dead buffer's interaction lifetime.  Do not enter it or
  ;; restore its owners: the outer transaction must still reach caller rollback.
  (when (and (ebox-interaction--geometry-staged capability)
             (buffer-live-p (ebox-interaction--geometry-buffer capability)))
    (with-current-buffer (ebox-interaction--geometry-buffer capability)
      (when (ebox-interaction--geometry-state-slots capability)
        (ebox-source--interaction-slots-rollback (ebox-interaction--geometry-state-slots capability)))
      (setq ebox-interaction--focus-owner (ebox-interaction--geometry-old-focus capability)
            ebox-interaction--active-owner (ebox-interaction--geometry-old-active capability)
            ebox-interaction--focus-order (ebox-interaction--geometry-old-order capability)
            ebox-interaction--hover-content-specs (ebox-interaction--geometry-old-hover-specs capability)
            ebox-interaction--hover-content-track-mouse (ebox-interaction--geometry-old-tracking capability))
      (if (ebox-interaction--geometry-old-track-local capability)
          (setq-local track-mouse (ebox-interaction--geometry-old-track-value capability))
        (kill-local-variable 'track-mouse))
      (let ((targets (ebox-interaction--geometry-targets capability)))
        (dotimes (index (length targets))
          (let ((entry (aref targets index)))
            (setf (ebox-interaction--geometry-target-position entry)
                  (ebox-interaction--geometry-target-old-position entry))
            (when-let* ((cell (ebox-interaction--geometry-target-hover-cell entry)))
              (setcar cell (ebox-interaction--geometry-target-old-hover-bounds entry))
              (setcar (ebox-interaction--geometry-target-hover-bounds entry)
                      (ebox-interaction--geometry-target-old-start entry))
              (setcdr (ebox-interaction--geometry-target-hover-bounds entry)
                      (ebox-interaction--geometry-target-old-end entry)))))))
    (ebox-interaction--geometry-sync-owners capability)
    (when-let* ((focus (ebox-interaction--geometry-focus capability)))
      (setf (ebox-interaction--geometry-target-position focus)
            (ebox-interaction--geometry-old-focus-position capability))))
  (setf (ebox-interaction--geometry-staged capability) nil))

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
Defaults are one stop and the current buffer.  Negative COUNT moves
backward; zero returns current focus.  CYCLE non-nil wraps at a boundary;
otherwise a missing stop signals `user-error' without changing focus or
point.  Only nodes declaring a nonnegative integer `:tab-index' are
navigation stops.  Order is ascending tab index, buffer start, then end;
exact ties use retained node identity.  Disabled, hidden and inaccessible
nodes are skipped.  Navigation starts at the first (or backward last) stop
when there is no eligible focus.  No window is selected and no key bindings
are installed. Nonzero moves reject active Ebox publication transactions;
zero remains a read-only query. See `ebox-focus'."
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
            (let ((copy (ebox-text-property-value-copy value)))
              (when (cddr copy)
                (setcar (cddr copy) (binding (nth 2 value))))
              copy))
           ((and (consp value) (stringp (car value)))
            (cons (ebox-text-property-value-copy (car value)) (binding (cdr value))))
           ((and (consp value) (keymapp (car value)))
            (cons (map-copy (car value)) (ebox-text-property-value-copy (cdr value))))
           (t (ebox-text-property-value-copy value))))
         (map-copy
          (source)
          (setq source (if (symbolp source) (indirect-function source) source))
          (or (gethash source copies)
              (let* ((parent (keymap-parent source))
                     (local (copy-sequence source))
                     (copy (ebox-text-property-value-copy source)))
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

(defvar ebox-interaction--published-keymaps (make-hash-table :test #'eq :weakness 'key)
  "Caller keymaps mapped to their structure log and frozen snapshot.")

(defun ebox-interaction--keymap-log (keymap)
  "Return KEYMAP's complete mutable structure as a vector, or nil.
The log records every cons cell with its car and cdr, resolved named maps
and string contents, so binding, parent, prompt and name changes remain
observable.  Character-table maps return nil and are always copied."
  (let ((log nil) (seen (make-hash-table :test #'eq)))
    (catch 'unsupported
      (cl-labels
          ((visit (value)
             (while value
               (cond
                ((and (symbolp value) (keymapp value))
                 (let ((definition (indirect-function value)))
                   (push value log) (push definition log)
                   (setq value (and (not (symbolp definition)) definition))))
                ((stringp value)
                 (push (copy-sequence value) log)
                 (setq value nil))
                ((or (char-table-p value) (bool-vector-p value))
                 (throw 'unsupported nil))
                ((and (vectorp value) (not (recordp value)))
                 (unless (gethash value seen)
                   (puthash value t seen)
                   (push value log)
                   (dotimes (index (length value))
                     (push (aref value index) log)
                     (visit (aref value index))))
                 (setq value nil))
                ((and (consp value) (not (functionp value)))
                 (if (gethash value seen)
                     (setq value nil)
                   (puthash value t seen)
                   (push value log) (push (car value) log) (push (cdr value) log)
                   (visit (car value))
                   (setq value (cdr value))))
                (t (setq value nil))))))
        (visit keymap)
        (vconcat (nreverse log))))))

(defun ebox-interaction--keymap-log-equal-p (old new)
  "Return non-nil when structure logs OLD and NEW record the same keymap."
  (and (= (length old) (length new))
       (let ((index 0) (same t))
         (while (and same (< index (length old)))
           (let ((left (aref old index)) (right (aref new index)))
             (unless (or (eq left right)
                         (and (stringp left) (stringp right)
                              (equal-including-properties left right)))
               (setq same nil)))
           (setq index (1+ index)))
         same)))

(defun ebox-interaction--published-keymap (keymap)
  "Return KEYMAP's owned snapshot, reusing it while KEYMAP is unchanged.
A reused snapshot keeps its identity, so unchanged interactive output keeps
render-cache and publication equality proofs."
  (if (gethash keymap ebox-text--frozen-values)
      keymap
    (let ((entry (gethash keymap ebox-interaction--published-keymaps))
          (log (ebox-interaction--keymap-log keymap)))
      (if (and entry log (ebox-interaction--keymap-log-equal-p (car entry) log))
          (cdr entry)
        (let ((snapshot (ebox-interaction--keymap-snapshot keymap)))
          (when log
            (ebox-text--freeze snapshot)
            (puthash keymap (cons log snapshot) ebox-interaction--published-keymaps))
          snapshot)))))

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
               (:drag-lock-modifier
                (unless (or (null value)
                            (memq value '(shift control meta super hyper)))
                  (error "Ebox :drag-lock-modifier has unsupported value: %S"
                         value)))
               (:hover-group
                (unless (or (null value) (symbolp value) (stringp value)
                            (numberp value))
                  (error "Ebox :hover-group requires nil or a scalar key: %S"
                         value)))
               (:hover-style (ebox-interaction--hover-face value))
               (:hover-content
                (unless (or (null value) (stringp value)
                            (and (functionp value)
                                 (or (autoloadp (indirect-function value))
                                     (zerop (car (func-arity value))))))
                  (error "Ebox :hover-content requires a string or zero-argument function")))
               (_ (error "Ebox has no interaction property %S" key)))))
  (let ((keymap (plist-get properties :keymap)))
    (ebox-text-property-value-copy
     (if keymap
         (plist-put (copy-sequence properties) :keymap
                    (ebox-interaction--published-keymap keymap))
       properties))))

(defun ebox-interaction--hover-content-value (value buffer)
  "Resolve hover CONTENT VALUE in BUFFER and validate its result.
VALUE is either a literal string or a zero-argument function.  Functions run
with BUFFER current, matching `ebox-help-create' context rules."
  (let ((result (if (functionp value)
                    (with-current-buffer buffer (funcall value))
                  value)))
    (unless (stringp result)
      (error "Ebox :hover-content function must return a string"))
    result))

(defun ebox-interaction--hover-content-handle (buffer node state)
  "Return an editable handle for NODE in BUFFER and STATE, or nil.
The handle is reconstructed from Ebox's retained publication object rather
than exposing a runtime region table to callers."
  (let* ((region-id (and node (ebox-get node :region-id)))
         (object (and region-id
                      (gethash region-id
                               (plist-get state :region-surface-object-table)))))
    (and object
         (ebox-selector--live-region-handle buffer object))))

(defun ebox-interaction--hover-content-specs (&optional buffer)
  "Return visible hover-content specs for BUFFER's committed surface."
  (setq buffer (or buffer (current-buffer)))
  (let* ((state (and (buffer-live-p buffer)
                     (ebox-surface--buffer-client-state buffer)))
         (source (and state (plist-get state :source-index)))
         specs)
    (when (and state source)
      (maphash
       (lambda (ref node-id)
         (when-let* ((node (ebox--buffer-runtime-node buffer node-id))
                     (handle (ebox-tree-node-source-handle node))
                     (interactions (ebox-source-index-interactions source handle))
                     (content (plist-get interactions :hover-content))
                     (editable (ebox-interaction--hover-content-handle
                                buffer node state))
                     (bounds (ebox-host-ref-bounds buffer ref)))
           (push (list :ref ref :node node :handle editable
                       :content content
                       :group (plist-get interactions :hover-group)
                       :bounds bounds)
                 specs)))
       (ebox--buffer-host-ref-table buffer)))
    specs))

(defun ebox-interaction--hover-content-sync (&optional buffer)
  "Refresh hover-content registrations and local motion tracking for BUFFER.
Tracking is enabled only for a mounted buffer that declares at least one
`:hover-content' capability.  Other Ebox buffers retain their normal input
path and never receive motion events."
  (setq buffer (or buffer (current-buffer)))
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ebox-interaction--hover-content-specs
            (ebox-interaction--hover-content-specs buffer))
      (if ebox-interaction--hover-content-specs
          (progn
            (unless ebox-interaction--hover-content-track-mouse
              (setq ebox-interaction--hover-content-track-mouse
                    (list (local-variable-p 'track-mouse) track-mouse))
              (setq-local track-mouse t)))
        (when ebox-interaction--hover-content-track-mouse
          (let ((saved ebox-interaction--hover-content-track-mouse))
            (if (car saved)
                (setq-local track-mouse (cadr saved))
              (kill-local-variable 'track-mouse)))
          (setq ebox-interaction--hover-content-track-mouse nil))))))

(defun ebox-interaction--hover-content-spec-at (position)
  "Return the innermost hover-content spec covering text POSITION."
  (let (result width)
    (dolist (spec ebox-interaction--hover-content-specs result)
      (let ((bounds (plist-get spec :bounds)))
        (when (and bounds (<= (car bounds) position) (< position (cdr bounds)))
          (let ((candidate (- (cdr bounds) (car bounds))))
            (when (or (null width) (< candidate width))
              (setq result spec width candidate))))))))

(defun ebox-interaction--hover-content-update (spec content)
  "Publish CONTENT for hover SPEC through Ebox's retained update boundary."
  (when (and spec (stringp content))
    (condition-case _error
        (ebox-region-update (plist-get spec :handle) :content content)
      (error nil))))

(defun ebox-interaction--hover-content-group-key (spec)
  "Return SPEC's explicit hover group, or its own reference when absent."
  (or (plist-get spec :group) (plist-get spec :ref)))

(defun ebox-interaction--hover-content-update-many (buffer updates)
  "Publish UPDATES for BUFFER in one retained incremental batch.
Each UPDATE is `(SPEC . CONTENT)'.  Invalid or stale members are ignored;
the remaining members still share one candidate publication."
  (when updates
    (with-current-buffer buffer
      (condition-case _error
          (progn
            (ebox-incremental-begin-batch buffer)
            (dolist (update updates)
              (ebox-region-update (plist-get (car update) :handle)
                                  :content (cdr update)))
            (ebox-incremental-flush buffer))
        (error
         (ignore-errors (ebox-incremental-flush buffer)))))))

(defun ebox-interaction--hover-content-spec-by-ref (ref specs)
  "Return the SPEC in SPECS whose reference equals REF."
  (cl-find-if (lambda (spec) (equal ref (plist-get spec :ref))) specs))

(defun ebox-interaction--hover-content-restore-group (buffer specs)
  "Restore the currently active hover group in BUFFER from saved bases."
  (let (updates)
    (dolist (entry ebox-interaction--hover-content-bases)
      (when-let* ((spec (ebox-interaction--hover-content-spec-by-ref
                         (car entry) specs)))
        (push (cons spec (cdr entry)) updates)))
    (ebox-interaction--hover-content-update-many buffer updates)
    (setq ebox-interaction--hover-content-group nil
          ebox-interaction--hover-content-bases nil
          ebox-interaction--hover-content-owner nil)))

(defun ebox-interaction--hover-content-activate-group (buffer specs group)
  "Activate GROUP in BUFFER and save every member's original content."
  (let (updates bases)
    (dolist (spec specs)
      (when (equal group (ebox-interaction--hover-content-group-key spec))
        (let* ((node (plist-get spec :node))
               (base (and node (ebox--region-update-content-value node)))
               (content (condition-case _error
                            (ebox-interaction--hover-content-value
                             (plist-get spec :content) buffer)
                          (error nil))))
          (when (and base content (plist-get spec :handle))
            (push (cons (plist-get spec :ref)
                        (ebox-text-property-value-copy base))
                  bases)
            (push (cons spec content) updates)))))
    (ebox-interaction--hover-content-update-many buffer updates)
    (setq ebox-interaction--hover-content-group group
          ebox-interaction--hover-content-bases bases)))

(defun ebox-interaction--hover-content-event (event)
  "Handle one native mouse-movement EVENT for a hover-content buffer.
Only transitions between groups publish content updates; motion within one
group is ignored so a drag or pointer sweep does not trigger a render for every
pixel.  Entering a group updates all of its members in one batch."
  (interactive "e")
  ;; A few global Emacs animation packages treat any mouse event in
  ;; `this-command-keys-vector' as a click.  Ebox's movement event is a
  ;; retained hover update, never activation; clear the command sequence before
  ;; post-command hooks can mistake it for a click ripple.
  (clear-this-command-keys)
  (let* ((position (event-end event))
         (window (and (consp position) (posn-window position)))
         (point (and (consp position) (posn-point position)))
         (buffer (and (window-live-p window) (window-buffer window))))
    (when (and buffer (null (posn-area position))
               (integer-or-marker-p point))
      (with-current-buffer buffer
        (let* ((spec (ebox-interaction--hover-content-spec-at point))
               (owner (and spec (plist-get spec :ref)))
               (group (and spec (ebox-interaction--hover-content-group-key spec)))
               (previous-group ebox-interaction--hover-content-group))
          (unless (equal group previous-group)
            (when previous-group
              (ebox-interaction--hover-content-restore-group
               buffer ebox-interaction--hover-content-specs))
            (when group
              (ebox-interaction--hover-content-activate-group
               buffer ebox-interaction--hover-content-specs group))
            (setq ebox-interaction--hover-content-owner owner))))))
    nil)

(defun ebox-interaction-surface-properties (properties)
  "Project normalized node PROPERTIES to native surface facts."
  (append
   (when (plist-get properties :disabled) '(keymap nil))
   (cl-loop for (key value) on properties by #'cddr
           unless (or (memq key '(:tab-index :disabled :hover-content :hover-group))
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
Literal callbacks retain identity; keymap snapshots use Ebox's native
property policy, which compares bindings while retaining command identity.
Paint and data values use native value equality, before surface publication
loads."
  (or (eq left right)
      (and (= (length left) (length right))
           (cl-loop for (property value) on left by #'cddr
                    for entry = (plist-member right property)
                    always (and entry
                                (cond
                                 ((or (keymapp value) (keymapp (cadr entry)))
                                  (funcall
                                   (ebox-property-policy-equality
                                    (ebox-register-text-property
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
