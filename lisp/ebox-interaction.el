;;; ebox-interaction.el --- Fixed native node capabilities -*- lexical-binding: t; -*-

;;; Commentary:
;; Validates Ebox's finite interaction inputs and projects them to native text
;; properties.  These node facts do not participate in CSS cascade or geometry.

;;; Code:

(require 'cl-lib)
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
(declare-function ebox-surface--paint-node-chain "ebox-surface" (state role-ids))
(defvar ebox-region-types)
(defvar ebox-buffer--decoration-style-map)

(defconst ebox-interaction-properties
  '(:help-echo :pointer :hover-style :keymap)
  "Fixed node capabilities accepted outside the Ebox style schema.")

(defconst ebox-interaction--hover-properties
  '(:color :background-color :text-decoration-line
    :text-decoration-color :text-decoration-style)
  "Geometry-independent Ebox declarations accepted by `:hover-style'.")

(defun ebox-interaction--command (callback)
  "Wrap zero-argument CALLBACK as a keyboard or mouse command."
  (lambda (&optional event)
    (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
    (if (null event)
        (funcall callback)
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
the primary mouse button.  Repeated clicks each activate once; primary-button
press and drag events do nothing, so they do not start native text selection.
Nil omits these activation bindings.  `:bindings' is an alist of string key
descriptions or key vectors paired with zero-argument callbacks.  Explicit
bindings override the repeated-click, press and drag defaults.
Callbacks are not invoked until a generated command runs.  Keyboard commands
use the current buffer; mouse commands use the event window's buffer without
selecting a window or moving point.  Duplicate or overlapping keys are errors.
This function does not supply focus navigation, state or event propagation."
  (unless (and (proper-list-p options) (zerop (% (length options) 2)))
    (error "Ebox keymap options must be an even plist"))
  (let ((map (make-sparse-keymap)) seen keys)
    (cl-loop for (key _value) on options by #'cddr do
             (unless (memq key '(:activate :bindings))
               (error "Unknown Ebox keymap option: %S" key))
             (when (memq key seen)
               (error "Repeated Ebox keymap option: %S" key))
             (push key seen))
    (let ((activate (plist-get options :activate))
          (bindings (plist-get options :bindings)))
      (unless (proper-list-p bindings)
        (error "Ebox keymap :bindings must be an alist"))
      (when activate
        (setq bindings (append (mapcar (lambda (key) (cons key activate))
                                      '("RET" [return] "SPC" [mouse-1]))
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
          (define-key map key (ebox-interaction--command callback))
          (push key keys)))
      (when activate
        ;; A release-only map lets the preceding press enter mouse-drag-region;
        ;; double/triple clicks can then select words or whole lines.  Claim
        ;; the primary-button sequence locally, preserving explicit handlers.
        (dolist (event '(double-mouse-1 triple-mouse-1
                                      down-mouse-1 double-down-mouse-1
                                      triple-down-mouse-1 drag-mouse-1
                                      double-drag-mouse-1 triple-drag-mouse-1))
          (unless (lookup-key map (vector event))
            (define-key map (vector event)
                        (if (memq event '(double-mouse-1 triple-mouse-1))
                            (lookup-key map [mouse-1])
                          #'ignore))))))
    map))

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
Absent keys inherit enclosing surface values; explicit nil blocks them.
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
  (cl-loop for (key value) on properties by #'cddr
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
                            (:keymap 'keymap)) value))))

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
  "Compare native surface plists LEFT and RIGHT without collapsing commands.
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
                                    (tp-register-text-property property))
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
