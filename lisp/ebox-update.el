;;; ebox-update.el --- Prepared mixed primitive publication -*- lexical-binding: t; -*-

;;; Commentary:
;; Bind a stable cohort of mounted source cells to the retained scene.
;; Applying a change recomputes only the changed nodes' cascade, re-renders
;; their nearest composition boundary with the ordinary renderer, and replaces
;; that boundary's retained primitives.  Sparse accepted changes share one
;; existing surface publication and rollback.

;;; Code:
(require 'cl-lib)
(require 'ebox-geometry)
(require 'ebox-update-selector)

(cl-defstruct (ebox-update--member (:constructor ebox-update--make-member))
  group properties offsets variants)

(cl-defstruct (ebox-update--group (:constructor ebox-update--make-group))
  "One Host's prebound members.  DIRTY marks any changed member; REPAINT
marks a changed raster value, the only change that re-renders BOUNDARY."
  node properties variants first-member slots values geometry-program x-factor
  boundary style-p restyle resized repaint crop class-slot hover-cell hover-old hover-owners dirty staged dx dy z)

(cl-defstruct (ebox-update--boundary (:constructor ebox-update--make-boundary))
  "Nearest retained composition primitive owning a group's pixels.
NODE is rendered in HOST's content context with the ordinary renderer.  Its
pieces replace NODE's primitive records in ROUTE's program.  A flow child
must keep exactly the same source rows and pixel intervals; an absolute
panel does not participate in flow, so its complete footprint may change."
  node host route dirty)

(cl-defstruct (ebox-update--cohort (:constructor ebox-update--make-cohort))
  buffer state scene members groups boundaries marks epoch snapshots
  signatures viewport-nodes viewport-subtrees css-viewport-subtrees viewport-heights stage rollback after-commit report old-report old-revision old-stale
  old-report-revision old-report-publication old-report-kinds staged paint-changed)

(defun ebox-update--node (buffer reference)
  "Resolve mounted BUFFER REFERENCE at the cold preparation boundary."
  (or (ebox--host-ref-node buffer reference)
      (and (ebox-source-semantic-id-p reference)
           (with-current-buffer buffer
             (ignore-errors
               (let* ((handle (ebox-region-resolve buffer reference))
                      (target (ebox-selector--region-target handle)))
                 (ebox--root-region-box (ebox--buffer-root-node buffer) (cdr target))))))))

(defun ebox-update--current-value (node property &optional source)
  "Read NODE's already computed primitive PROPERTY."
  (pcase property
    (:content (plist-get node :ebox-text-value))
    (:hover-content (and source (plist-get (ebox-source-record-interactions
                                            (ebox-source--index-record source (plist-get node :ebox-source-handle)))
                                           :hover-content)))
    (:class (and source (ebox-source-record-classes
                         (ebox-source--index-record source (plist-get node :ebox-source-handle)))))
    (:border (and source (ebox-source--update-slots-border-value source node)))
    (:font-weight (and source (plist-get (ebox-source-record-declarations
                                          (ebox-source--index-record source (plist-get node :ebox-source-handle)))
                                         (ebox-style-schema-id :font-weight))))
    (:background-color (ebox-get node :bgcolor))
    (_ (ebox-get node property))))

(defun ebox-update--group-current-value (group index)
  "Read GROUP's prebound primitive value at INDEX."
  (let ((property (aref (ebox-update--group-properties group) index)))
    (if (memq property '(:hover-content :class :border :font-weight))
        (ebox-source--update-slots-value (ebox-update--group-slots group) index)
      (ebox-update--current-value (ebox-update--group-node group) property))))

(defun ebox-update--scene (buffer state nodes &optional resize-node)
  "Return BUFFER's shared scene admitting NODES, preferring RESIZE-NODE.
A requested fixed-content size binding prepares the crop primitive before
input; ordinary layout keeps its existing publication route."
  (or (with-current-buffer buffer
        (and (ebox-geometry--session-valid-p ebox-geometry--session)
             ebox-geometry--session))
      (let ((parents (plist-get state :parent-table))
            (table (plist-get state :node-table)) anchor reference)
        (catch 'found
          (dolist (node (if resize-node (cons resize-node nodes) nodes))
            (while node
              (when (eq (plist-get node :position) 'absolute)
                (setq anchor node)
                (throw 'found t))
              (setq node (ebox-runtime-index-get
                          (ebox-runtime-index-get (plist-get node :node-id) parents) table))))
          (ebox-runtime-index-map
           (lambda (_id node)
             (when (eq (plist-get node :position) 'absolute)
               (setq anchor node)
               (throw 'found t))) table))
        (when anchor
          (maphash (lambda (ref id)
                     (when (equal id (plist-get anchor :node-id)) (setq reference ref)))
                   (ebox--buffer-host-ref-table buffer))
          (setq reference (or reference (plist-get anchor :id)))
          (when reference
            (when-let* ((operation (ebox-geometry-prepare
                                   buffer reference
                                   (if resize-node [:left :top :width :height]
                                     [:left :top :z-index]))))
              (ebox-geometry--operation-session operation)))))))

(defun ebox-update--geometry-binding (group routes)
  "Bind GROUP's geometry to a fixed primitive target in ROUTES."
  (let ((node (ebox-update--group-node group)) target program wrapper)
    (dotimes (index (length routes))
      (let* ((route (aref routes index))
             (candidate (ebox-geometry--route-program route)))
        (when (and (null target)
                   (gethash (plist-get node :node-id) (ebox-layer--program-targets candidate)))
          (setq target (gethash (plist-get node :node-id) (ebox-layer--program-targets candidate))
                program candidate wrapper (ebox-geometry--route-wrapper route)))))
    (when (and target (eq (plist-get node :position) 'absolute))
      (setf (ebox-update--group-geometry-program group) program
            (ebox-update--group-x-factor group) (ebox--size-pixels '(ch 1) wrapper 'width))
      t)))

;; Retained primitives record their row and pixel interval in the containing
;; plane.  An ordinary render of the boundary node proves that a change keeps
;; this footprint, so only record text changes and composition stays fixed.
(defun ebox-update--bind-boundary (state routes node table)
  "Return NODE's nearest boundary owning primitive records in ROUTES.
TABLE shares one boundary among all groups rendered by the same node."
  (let ((parents (plist-get state :parent-table))
        (nodes (plist-get state :node-table))
        found)
    (while (and node (not found))
      (let ((id (plist-get node :node-id)) (index 0))
        (while (and (not found) (< index (length routes)))
          (let* ((route (aref routes index))
                 (program (ebox-geometry--route-program route))
                 (target (gethash id (ebox-layer--program-targets program))))
            (when (and target (> (length target) 0))
              (setq found
                    (or (gethash node table)
                        (puthash node
                                 (ebox-update--make-boundary
                                  :node node :route index
                                  :host (ebox-runtime-index-get
                                         (plist-get (ebox-geometry--route-wrapper route) :node-id)
                                         nodes))
                                 table)))))
          (setq index (1+ index)))
        (unless found
          (setq node (ebox-runtime-index-get (ebox-runtime-index-get id parents) nodes)))))
    (and found (ebox-update--boundary-host found) found)))

(cl-defstruct (ebox-update--binding (:constructor ebox-update--make-binding))
  "Opaque cold capability for mounted state and its measurement environment."
  public-token buffer state stylesheet stylesheet-epoch font-epoch environment window width height)

(defvar-local ebox-update--binding-token nil
  "Current immutable prepared-binding capability for this mounted buffer.")

(defvar-local ebox-update--prepare-report nil
  "Latest cold prepared-update admission report; queried only on request.")

(defvar ebox-update--preparing-buffer nil)
(defvar ebox-update--preparing-member nil)
(defvar ebox-update--preparing-property nil)

(defun ebox-update--binding-current-p (token buffer state)
  "Check TOKEN against BUFFER and STATE without building a measurement signature."
  (and (ebox-update--binding-p token)
       (eq buffer (ebox-update--binding-buffer token))
       (eq state (ebox-update--binding-state token))
       (eq ebox-style-stylesheet (ebox-update--binding-stylesheet token))
       (= ebox-style--stylesheet-epoch (ebox-update--binding-stylesheet-epoch token))
       (= ebox-font--measurement-epoch (ebox-update--binding-font-epoch token))
       (ebox-geometry--display-current-p (ebox-update--binding-environment token))
       (let ((window (ebox-update--binding-window token)))
         (or (null window)
             (and (window-live-p window) (eq buffer (window-buffer window))
                  (= (window-pixel-width window) (ebox-update--binding-width token))
                  (= (window-pixel-height window) (ebox-update--binding-height token)))))))

;;;###autoload
(defun ebox-update-binding-token (buffer-or-name)
  "Return BUFFER-OR-NAME's opaque prepared-binding capability, or nil.
Compare tokens with `eq'; never inspect their representation.  The token is
stable across prepared source/pixel publications on the same runtime state.
Ordinary publication, stylesheet changes and a changed measurement environment
produce a new token at the next control-plane query.  The unchanged hot query
only compares captured fields and returns the existing object."
  (let* ((buffer (ebox--host-ref-buffer buffer-or-name))
         (state (and buffer (ebox--buffer-render-state buffer))))
    (when state
      (with-current-buffer buffer
        (unless (ebox-update--binding-current-p ebox-update--binding-token buffer state)
          (let* ((window (get-buffer-window buffer t))
                 (frame (if window (window-frame window) (selected-frame)))
                 (environment
                  (ebox-geometry--make-operation
                   :buffer buffer :frame-font-frame frame
                   :display-snapshot (vconcat (ebox--display-signature-for-frame frame)))))
            (setq ebox-update--binding-token
                  (ebox-update--make-binding
                   :public-token (make-symbol "ebox-update-binding")
                   :buffer buffer :state state :stylesheet ebox-style-stylesheet
                   :stylesheet-epoch ebox-style--stylesheet-epoch :font-epoch ebox-font--measurement-epoch
                   :environment environment
                   :window window :width (and window (window-pixel-width window))
                   :height (and window (window-pixel-height window))))))
        (ebox-update--binding-public-token ebox-update--binding-token)))))

;;;###autoload
(defun ebox-update-prepare-report (buffer-or-name)
  "Return BUFFER-OR-NAME's latest cold prepared-update admission report.
The defensive plist contains :status (ready, unsupported or stale), :reason,
:binding-token and, when a particular member was rejected, :member and
:property.  Unsupported members may be excluded until the binding token or
their declared variant configuration changes.  A stale report requests a
control-plane refresh; it never authorizes use of the previous operation."
  (let ((buffer (ebox--host-ref-buffer buffer-or-name)))
    (when buffer
      (with-current-buffer buffer (copy-tree ebox-update--prepare-report)))))

(defun ebox-update--locate-member (members group &optional property raster-p)
  "Bind cold diagnostics to GROUP's exact member and optional PROPERTY."
  (let ((index 0) found)
    (while (and (< index (length members)) (not found))
      (let* ((member (aref members index))
             (keys (ebox-update--member-properties member)))
        (when (and (eq group (ebox-update--member-group member))
                   (cond (property (cl-position property keys))
                         (raster-p (cl-some (lambda (key) (not (memq key ebox--region-geometry-properties)))
                                            (append keys nil)))
                         (t t)))
          (setq found t ebox-update--preparing-member index
                ebox-update--preparing-property property)))
      (setq index (1+ index)))
    (unless found
      (setq ebox-update--preparing-member (ebox-update--group-first-member group)
            ebox-update--preparing-property property))))

(defun ebox-update--decline (reason &optional stale)
  "Reject the active cold preparation with REASON and optional STALE status."
  (when (buffer-live-p ebox-update--preparing-buffer)
    (with-current-buffer ebox-update--preparing-buffer
      (setq ebox-update--prepare-report
            (list :status (if stale 'stale 'unsupported) :reason reason
                  :binding-token (and ebox-update--binding-token
                                      (ebox-update--binding-public-token ebox-update--binding-token))
                  :member ebox-update--preparing-member :property ebox-update--preparing-property))))
  (throw 'unsupported nil))

;;;###autoload
(defun ebox-update-prepare (buffer-or-name specifications &optional stage rollback after-commit)
  "Compile BUFFER-OR-NAME's fixed SPECIFICATIONS into one primitive cohort.
A member is [HOST-REF PROPERTY-VECTOR] or [HOST-REF PROPERTY-VECTOR VARIANTS].
VARIANTS, when present, aligns with the properties; a class slot contains a
nonempty vector of finite canonical class token/list values.  Other slots use
nil.  Duplicate Hosts may declare disjoint properties.  STAGE and ROLLBACK
are paired zero-argument callbacks.  AFTER-COMMIT runs once after acceptance.
Return an opaque operation or nil.  `ebox-update-prepare-report' describes
cold admission."
  (let* ((buffer (ebox--host-ref-buffer buffer-or-name))
         (ebox-update--preparing-buffer buffer)
         (ebox-update--preparing-member nil)
         (ebox-update--preparing-property nil)
         (token (and buffer (ebox-update-binding-token buffer)))
         result)
    (when buffer
      (with-current-buffer buffer
        (setq ebox-update--prepare-report
              (list :status 'unsupported :reason 'unavailable :binding-token token))))
    (let (completed)
      (unwind-protect
          (setq result (if buffer
                           (with-current-buffer buffer
                             (ebox-update--prepare buffer-or-name specifications stage rollback after-commit))
                         (ebox-update--prepare buffer-or-name specifications stage rollback after-commit))
                completed t)
        ;; A quit or `while-no-input' may leave the shared canvas half
        ;; refreshed; accepted output is untouched, so the next pass is cold.
        (unless (or completed (not (buffer-live-p buffer)))
          (with-current-buffer buffer
            (setq ebox-geometry--session nil
                  ebox-update--prepare-report
                  (list :status 'unsupported :reason 'interrupted :binding-token token))))))
    (when result
      (with-current-buffer buffer
        (setq ebox-update--prepare-report
              (list :status 'ready :reason nil :binding-token token))))
    result))

(defun ebox-update--prepare (buffer-or-name specifications &optional stage rollback after-commit)
  "Compile BUFFER-OR-NAME's fixed SPECIFICATIONS into one primitive cohort.
SPECIFICATIONS is a vector of [HOST-REF PROPERTY-VECTOR] members.  Duplicate
Hosts may declare disjoint properties.  STAGE and ROLLBACK are paired zero
argument callbacks; AFTER-COMMIT runs once after acceptance.  Return an opaque
operation, or nil if a member cannot use the fixed retained canvas."
  (unless (and (vectorp specifications) (> (length specifications) 0)
               (or (null stage) (functionp stage))
               (or (null rollback) (functionp rollback))
               (eq (null stage) (null rollback))
               (or (null after-commit) (functionp after-commit)))
    (user-error "Invalid Ebox prepared update specification"))
  (when (ebox-transaction-active-p)
    (user-error "Ebox update preparation requires a settled publication"))
  (catch 'unsupported
    (let* ((buffer (ebox--host-ref-buffer buffer-or-name))
           (state (and buffer (ebox--buffer-render-state buffer)))
           (groups-table (make-hash-table :test #'eq))
           (members (make-vector (length specifications) nil)) groups nodes scene)
      (unless state (ebox-update--decline 'unmounted t))
      (unless (equal (plist-get state :display-signature)
                     (append (ebox-geometry--operation-display-snapshot
                              (ebox-update--binding-environment ebox-update--binding-token)) nil))
        (ebox-update--decline 'display-context t))
      (dotimes (index (length specifications))
        (setq ebox-update--preparing-member index ebox-update--preparing-property nil)
        (let* ((spec (aref specifications index))
               (node (and (vectorp spec) (memq (length spec) '(2 3))
                          (ebox-update--node buffer (aref spec 0))))
               (keys (and (vectorp spec) (memq (length spec) '(2 3)) (aref spec 1)))
               (variants (and (vectorp spec) (= (length spec) 3) (aref spec 2))))
          (unless (and (vectorp keys) (> (length keys) 0))
            (user-error "Prepared Ebox members require a Host and property vector"))
          (unless (or (null variants) (and (vectorp variants) (= (length variants) (length keys))))
            (user-error "Prepared member variants must align with its property vector"))
          (unless node (ebox-update--decline 'missing-host t))
          (setq keys (vconcat (mapcar (lambda (key) (if (eq key :bgcolor) :background-color key)) (append keys nil))))
          (let ((group (or (gethash node groups-table)
                           (let ((entry (ebox-update--make-group :node node :first-member index)))
                             (puthash node entry groups-table)
                             (push entry groups) (push node nodes) entry))))
            (dotimes (key-index (length keys))
              (let ((property (aref keys key-index)))
                (setq ebox-update--preparing-property property)
                (unless (or (memq property ebox--region-geometry-properties)
                            (memq property '(:content :color :background-color :bgcolor :hover-content :class :border :font-weight :visibility)))
                  (ebox-update--decline 'unsupported-property))
                (when (memq property (ebox-update--group-properties group))
                  (user-error "Prepared Ebox cohort properties overlap for one Host"))
                (setf (ebox-update--group-properties group)
                      (append (ebox-update--group-properties group) (list property))
                      (ebox-update--group-variants group)
                      (append (ebox-update--group-variants group) (list (and variants (aref variants key-index)))))))
            (aset members index (ebox-update--make-member :group group :properties (copy-sequence keys) :variants (and variants (copy-tree variants t)))))))
      (setq ebox-update--preparing-member nil ebox-update--preparing-property nil)
      (setq groups (vconcat (nreverse groups))
            scene (ebox-update--scene
                   buffer state nodes
                   (cl-loop for group across groups
                            when (and (cl-intersection (ebox-update--group-properties group)
                                                       '(:width :height))
                                      (ebox-geometry--crop-candidate-p (ebox-update--group-node group)))
                            return (ebox-update--group-node group))))
      (unless scene (ebox-update--decline 'fixed-canvas))
      (let ((routes (ebox-geometry--operation-routes scene))
            (boundaries (make-hash-table :test #'eq)))
        (dotimes (index (length groups))
          (let* ((group (aref groups index))
                 (node (ebox-update--group-node group))
                 (keys (vconcat (ebox-update--group-properties group)))
                 (variants (vconcat (ebox-update--group-variants group)))
                 (values (make-vector (length keys) nil))
                 (crop (ebox-geometry--operation-crop scene)) geometry raster)
            (when (and crop (eq node (aref crop 0)))
              (setf (ebox-update--group-crop group) crop))
            (setq ebox-update--preparing-member (ebox-update--group-first-member group)
                  ebox-update--preparing-property nil)
            (dotimes (key-index (length keys))
              (let ((property (aref keys key-index)))
                ;; A proved fixed-text crop resizes through the retained
                ;; geometry program; every other size change re-renders the
                ;; Host's composition boundary.
                (when (or (memq property '(:left :top :z-index))
                          (and (ebox-update--group-crop group) (memq property '(:width :height))))
                  (setq geometry t))
                (when (memq property '(:color :background-color :bgcolor :border :font-weight :visibility))
                  (setf (ebox-update--group-style-p group) t))
                (when (or (memq property '(:content :color :background-color :bgcolor :hover-content :border
                                              :font-weight :visibility))
                          (and (memq property '(:width :height)) (not (ebox-update--group-crop group))))
                  (setq raster t))
                (aset values key-index (copy-tree (ebox-update--current-value node property (plist-get state :source-index))))))
            (setf (ebox-update--group-properties group) keys
                  (ebox-update--group-variants group) variants
                  (ebox-update--group-values group) values)
            ;; Translation writes placement directly, so only a proved inline
            ;; winner may own it.  Paint recomputes the complete cascade.
            (when geometry
              (unless (ebox-geometry--inline-slots-p state node keys) (ebox-update--decline 'inline-winner))
              (unless (ebox-update--geometry-binding group routes)
                (ebox-update--decline 'geometry-target)))
            (when-let* ((class-index (cl-position :class keys)))
              (ebox-update--locate-member members group :class)
              (let ((palette (aref variants class-index)))
                (unless (and (vectorp palette) (> (length palette) 0))
                  (ebox-update--decline 'class-variants))
                (let ((proof (ebox-update-selector-prepare state node palette)))
                  (unless proof (ebox-update--decline 'selector-dependency))
                  (setf (ebox-update--group-class-slot group) proof))))
            (when raster
              (ebox-update--locate-member members group nil t)
              (let ((boundary (ebox-update--bind-boundary state routes node boundaries)))
                (unless boundary (ebox-update--decline 'raster-boundary))
                (setf (ebox-update--group-boundary group) boundary)))))
        ;; All output proofs precede the equivalent private source rebinding.
        (dotimes (index (length groups))
          (let* ((group (aref groups index))
                 (node (ebox-update--group-node group))
                 (_diagnostic (ebox-update--locate-member members group))
                 (slots (ebox-source--update-slots-prepare
                         (plist-get state :source-index) node (ebox-update--group-properties group))))
            (unless slots (ebox-update--decline 'source-binding))
            (setf (ebox-update--group-slots group) slots)
            (plist-put node :ebox-source-handle (ebox-source--update-slots-handle slots))
            (plist-put state :source-index (ebox-source--update-slots-index slots))))
        (dotimes (index (length groups))
          (let ((group (aref groups index)))
            (when (ebox-update--group-class-slot group)
              (ebox-update--locate-member members group :class)
              (unless (ebox-update-selector-bind
                       state (ebox-update--group-slots group)
                       (cl-position :class (ebox-update--group-properties group))
                       (ebox-update--group-class-slot group))
                (ebox-update--decline 'selector-binding)))))
        (dotimes (index (length members))
          (let* ((member (aref members index))
                 (keys (ebox-update--member-properties member))
                 (all (ebox-update--group-properties (ebox-update--member-group member)))
                 (offsets (make-vector (length keys) 0)))
            (dotimes (key-index (length keys))
              (aset offsets key-index (cl-position (aref keys key-index) all)))
            (setf (ebox-update--member-offsets member) offsets)))
        (setf (ebox-geometry--operation-interaction scene)
              (ebox-interaction--geometry-prepare buffer state (ebox-geometry--operation-surface scene)))
        (let ((targets (ebox-interaction--geometry-targets (ebox-geometry--operation-interaction scene))))
          (dotimes (index (length groups))
            (let ((group (aref groups index)))
              (when (cl-position :hover-content (ebox-update--group-properties group))
                (dotimes (target (length targets))
                  (when-let* ((spec (ebox-interaction--geometry-target-hover-spec (aref targets target))))
                    (when (eq (plist-get spec :node) (ebox-update--group-node group))
                      (setf (ebox-update--group-hover-cell group) (cdr (plist-member spec :content)))))))
              (let ((owner (plist-get (ebox-update--group-node group) :node-id)) refs)
                (while owner
                  (dotimes (target (length targets))
                    (when-let* ((spec (ebox-interaction--geometry-target-hover-spec (aref targets target))))
                      (when (equal owner (plist-get (plist-get spec :node) :node-id))
                        (push (plist-get spec :ref) refs))))
                  (setq owner (ebox-runtime-index-get owner (plist-get state :parent-table))))
                (setf (ebox-update--group-hover-owners group) refs)))))
        (unless (plist-member state :computed-styles-stale-p)
          (plist-put state :computed-styles-stale-p nil))
        (let ((operation
               (ebox-update--make-cohort
                :buffer buffer :state state :scene scene :members members :groups groups
                :boundaries (let (all)
                              (maphash (lambda (_node boundary) (push boundary all)) boundaries)
                              (vconcat all))
                :marks (make-vector (length members) 0) :epoch 0
                :signatures (make-hash-table :test #'eq)
                :viewport-nodes (make-hash-table :test #'eq)
                :viewport-subtrees (make-hash-table :test #'eq)
                :css-viewport-subtrees (make-hash-table :test #'eq)
                :viewport-heights (make-hash-table :test #'eq)
                :stage stage :rollback rollback :after-commit after-commit
                :report (list :strategy 'owner-rerender :projection-kind 'prepared-update
                              :dirty-kinds '(geometry paint span) :prepared-update-p t
                              :revision 0 :publication nil))))
          operation)))))

;;;###autoload
(defun ebox-update-valid-p (operation)
  "Return whether OPERATION still binds the accepted mounted generation."
  (and (ebox-update--cohort-p operation)
       (ebox-geometry--session-valid-p (ebox-update--cohort-scene operation))
       (let ((groups (ebox-update--cohort-groups operation))
             (index (plist-get (ebox-update--cohort-state operation) :source-index))
             (valid t))
         (dotimes (position (length groups))
           (let ((group (aref groups position)))
             (unless (ebox-source--update-slots-current-p (ebox-update--group-slots group) index)
               (setq valid nil)))) valid)))

(defun ebox-update--capture-value (group index value)
  "Validate VALUE for GROUP's INDEX and retain owned primitive storage."
  (let* ((property (aref (ebox-update--group-properties group) index))
         (old (ebox-update--group-current-value group index))
         (values (ebox-update--group-values group)))
    (cond
     ((memq property '(:left :top))
      (unless (and (consp value) (consp (cdr value)) (null (cddr value))
                   (eq (car value) (car-safe old))
                   (memq (car value) (if (eq property :left) '(px ch) '(lh)))
                   (ebox-size--finite-number-p (cadr value)))
        (throw 'unsupported nil))
      (setcar (cdr (aref values index)) (cadr value))
      (if (eq property :left)
          (setf (ebox-update--group-dx group)
                (* (- (cadr value) (cadr old))
                   (if (eq (car value) 'ch) (ebox-update--group-x-factor group) 1)))
        (setf (ebox-update--group-dy group) (- (floor (cadr value)) (floor (cadr old))))))
     ((and (ebox-update--group-crop group) (memq property '(:width :height)))
      (unless (and (consp value) (consp (cdr value)) (null (cddr value))
                   (eq (car value) (if (eq property :width) 'px 'lh))
                   (integerp (cadr value)) (> (cadr value) 0)
                   (<= (cadr value) (aref (ebox-update--group-crop group)
                                          (if (eq property :width) 1 2))))
        (throw 'unsupported nil))
      (setcar (cdr (aref values index)) (cadr value)))
     ((memq property '(:width :height))
      (unless (and (consp value) (consp (cdr value)) (null (cddr value))
                   (eq (car value) (car-safe old))
                   (eq (aref (ebox-source--update-slots-kinds (ebox-update--group-slots group)) index) 'unit)
                   (ebox-size--finite-number-p (cadr value)))
        (throw 'unsupported nil))
      (unless (= (cadr value) (cadr old)) (setf (ebox-update--group-resized group) t))
      (setcar (cdr (aref values index)) (cadr value)))
     ((eq property :z-index)
      (unless (integerp value) (throw 'unsupported nil))
      (aset values index value) (setf (ebox-update--group-z group) value))
     ((eq property :class)
      (unless (ebox-update-selector-value-p (ebox-update--group-class-slot group) value)
        (throw 'unsupported nil))
      (aset values index (ebox-update-selector-value (ebox-update--group-class-slot group) value)))
     ((eq property :font-weight)
      (unless (memq value '(normal bold)) (throw 'unsupported nil))
      (aset values index value))
     ((eq property :border)
      (unless (ebox-source--update-slots-border-valid-p (ebox-update--group-slots group) index value)
        (throw 'unsupported nil))
      (setcar (cddr (aref values index)) (if (stringp (nth 2 value)) (copy-sequence (nth 2 value)) (nth 2 value))))
     ((eq property :content)
      (unless (stringp value) (throw 'unsupported nil))
      (aset values index (copy-sequence value)))
     ((eq property :hover-content)
      (unless (or (stringp value) (functionp value)) (throw 'unsupported nil))
      (aset values index (if (stringp value) (copy-sequence value) value)))
     ((memq property '(:color :background-color :bgcolor))
      (unless (or (null value) (stringp value) (ebox-paint-slot-p value)) (throw 'unsupported nil))
      (aset values index (if (stringp value) (copy-sequence value) value)))
     ((eq property :visibility)
      (unless (memq value '(visible hidden)) (throw 'unsupported nil))
      (aset values index value))
     ((not (equal-including-properties value old)) (throw 'unsupported nil)))))

;; Restyling rewrites plist values in place, may append keys and may delete
;; and re-add keys, which changes key positions.  A snapshot keeps the
;; original key/value sequence, so rollback restores NODE's exact plist
;; while keeping the head cells that retained owners refer to.
(defun ebox-update--snapshot-node (operation node)
  "Record NODE's plist keys and values once for OPERATION's rollback."
  (unless (assq node (ebox-update--cohort-snapshots operation))
    (push (cons node (copy-sequence node))
          (ebox-update--cohort-snapshots operation))))

(defun ebox-update--restore-node (node snapshot)
  "Restore NODE's plist keys and values from SNAPSHOT in place."
  (let ((tail node) (source snapshot))
    (while source
      (setcar tail (car source))
      (setcar (cdr tail) (cadr source))
      (setq source (cddr source))
      (if source
          (progn
            (unless (cddr tail) (setcdr (cdr tail) (list nil nil)))
            (setq tail (cddr tail)))
        (setcdr (cdr tail) nil)))))

(defun ebox-update--restyle (operation node)
  "Recompute NODE's cascade and its descendants' inherited consequences.
Descendants recompute only while an inherited value or the projected font
of their ancestor changed: a paint change confined to the changed Host, such
as its background or visibility, leaves every descendant cascade intact."
  (let* ((state (ebox-update--cohort-state operation))
         (source (plist-get state :source-index))
         (parents (plist-get state :parent-table))
         (nodes (plist-get state :node-table))
         (parent (ebox-runtime-index-get
                  (ebox-runtime-index-get (plist-get node :node-id) parents) nodes))
         (scopes (ebox-style-source-scopes source))
         (ebox-selector-view--current (ebox-source--index-selector-view source))
         (ebox-selector-view--topology (ebox-source--index-selector-topology source)))
    (cl-labels
        ((visit (node parent-style parent-font)
           (when (and (listp node) (not (stringp node)))
             (unless (and (plist-get node :ebox-source-handle)
                          (ebox-source--index-node-subject source node))
               (throw 'unsupported nil))
             (ebox-update--snapshot-node operation node)
             (let* ((old-style (plist-get node :ebox-computed-style))
                    (old-font (plist-get node :ebox-font-fact))
                    (style (ebox-surface--compute-node-style
                            (ebox-tree-node-subject source node)
                            (ebox-tree-node-source-declarations source node)
                            parent-style scopes ebox-selector-view--current))
                    (snapshot (ebox-style--computed-snapshot style t)))
               (ebox-surface--project-font node style parent-font snapshot)
               (ebox-style-apply-computed node style snapshot)
               (let ((font (plist-get node :ebox-font-fact)))
                 (unless (and old-style
                              (equal old-font font)
                              (equal (ebox-style--inherited-style-signature old-style)
                                     (ebox-style--inherited-style-signature style)))
                   (ebox-tree-for-each-direct-child
                    node (lambda (child) (visit child style font)))))))))
      (visit node (plist-get parent :ebox-computed-style) (plist-get parent :ebox-font-fact)))))

;; Render signatures are recursive and memoized by node identity.  A change
;; can alter only its own and its ancestors' memoized entries.
(defun ebox-update--forget-signatures (operation)
  "Drop OPERATION's memoized render facts along changed nodes' ancestor paths."
  (let* ((state (ebox-update--cohort-state operation))
         (parents (plist-get state :parent-table))
         (nodes (plist-get state :node-table))
         (tables (list (ebox-update--cohort-signatures operation)
                       (ebox-update--cohort-viewport-nodes operation)
                       (ebox-update--cohort-viewport-subtrees operation)
                       (ebox-update--cohort-css-viewport-subtrees operation)
                       (ebox-update--cohort-viewport-heights operation)))
         (groups (ebox-update--cohort-groups operation))
         (changed (mapcar #'car (ebox-update--cohort-snapshots operation))))
    (dotimes (index (length groups))
      (when (ebox-update--group-dirty (aref groups index))
        (push (ebox-update--group-node (aref groups index)) changed)))
    (dolist (node changed)
      (while node
        (dolist (table tables) (remhash node table))
        (setq node (ebox-runtime-index-get
                    (ebox-runtime-index-get (plist-get node :node-id) parents) nodes))))))

(defun ebox-update--render-boundary (operation boundary)
  "Render BOUNDARY's node in its host context from OPERATION's current nodes."
  (let* ((state (ebox-update--cohort-state operation))
         (scene (ebox-update--cohort-scene operation))
         (ebox-viewport-width (plist-get state :viewport-width))
         (ebox-viewport-height (plist-get state :viewport-height))
         (ebox--render-display-signature (plist-get state :display-signature))
         (ebox--render-source-index (plist-get state :source-index))
         (ebox--region-box-table (ebox-geometry--operation-region-table scene))
         (ebox--scroll-global-state (ebox-geometry--operation-scroll-table scene))
         (ebox--render-runtime-revision (plist-get state :runtime-revision))
         (ebox--render-cache-table (plist-get state :render-cache))
         (ebox--render-cache-allow-viewport-dependent t)
         (ebox--render-cache-signature-cache (ebox-update--cohort-signatures operation))
         (ebox--layout-fragments-table nil)
         (ebox--layout-fragments-reuse-p nil)
         (ebox-layer--previous-composition-cache nil)
         (ebox-layer--composition-cache nil)
         (ebox-layer--composition-context nil)
         (ebox-layer--active-p 'unknown)
         (ebox-incremental--render-portals-p nil)
         (ebox--viewport-dependent-node-ids-cache (ebox-update--cohort-viewport-nodes operation))
         (ebox--viewport-dependent-subtree-cache (ebox-update--cohort-viewport-subtrees operation))
         (ebox--css-viewport-dependent-subtree-cache (ebox-update--cohort-css-viewport-subtrees operation))
         (ebox--viewport-height-dependent-subtree-cache (ebox-update--cohort-viewport-heights operation))
         (ebox--flex-content-min-width-table (plist-get state :flex-content-min-widths))
         (ebox--paint-origin-capture-p t)
         (ebox--render-owned-text-values (make-hash-table :test #'eq))
         (ebox--surface-materialization-active t)
         (node (ebox-update--boundary-node boundary)))
    (unless (eq (plist-get node :visibility) 'hidden)
      (cl-letf (((symbol-function 'ebox--scroll-schedule-idle-prefetch) #'ignore))
        (ebox--call-with-box-content-context
         (ebox-update--boundary-host boundary)
         (lambda () (ebox--render-with-cache node)))))))

(defun ebox-update--replace-boundary (operation boundary)
  "Replace BOUNDARY's retained primitives with its ordinary render.
Rows whose pixels are unchanged keep their primitives and damage.  Throw
`unsupported' when a flow child's footprint changes or new pixels contain
roles the mounted projection cannot represent."
  (let* ((scene (ebox-update--cohort-scene operation))
         (route (aref (ebox-geometry--operation-routes scene) (ebox-update--boundary-route boundary)))
         (program (ebox-geometry--route-program route))
         (records (ebox-layer--program-records program))
         (projection (ebox-geometry--operation-projection scene))
         (node (ebox-update--boundary-node boundary))
         (host (ebox-update--boundary-host boundary))
         (target (gethash (plist-get node :node-id) (ebox-layer--program-targets program)))
         (text (ebox-update--render-boundary operation boundary))
         (pieces (and (stringp text) (ebox-layer--pieces (ebox-string-lines text) node)))
         (keys (make-hash-table :test #'equal))
         (annotated (make-hash-table :test #'eq))
         (first-row nil) (offset nil) (same (> (length pieces) 0)))
    (unless target (throw 'unsupported nil))
    (dotimes (position (length target))
      (let* ((record (aref records (aref target position)))
             (row (plist-get record :source-row)))
        (when (>= (plist-get record :y) 0)
          (setq first-row (if first-row (min first-row row) row))
          (puthash (cons row (plist-get record :source-start)) (aref target position) keys))))
    (setq offset (and first-row pieces (- first-row (plist-get (car pieces) :y)))
          same (and same offset (= (length pieces) (hash-table-count keys))))
    (dolist (piece pieces)
      (let ((index (and same (gethash (cons (+ offset (plist-get piece :y)) (plist-get piece :start)) keys))))
        (unless (and index (= (plist-get piece :end) (plist-get (aref records index) :source-end)))
          (setq same nil))))
    (cl-flet ((annotate (line)
                (unless (gethash line annotated)
                  (unless (ebox-surface--geometry-mount-refresh-raster projection line t)
                    (throw 'unsupported nil))
                  (puthash line t annotated))))
      (if same
          (dolist (piece pieces)
            (let* ((index (gethash (cons (+ offset (plist-get piece :y)) (plist-get piece :start)) keys))
                   (line (plist-get piece :line)))
              (unless (equal-including-properties line (plist-get (aref records index) :text))
                (annotate line)
                (ebox-layer--program-replace-text program index line))))
        (unless (eq (plist-get node :position) 'absolute) (throw 'unsupported nil))
        (dolist (piece pieces) (annotate (plist-get piece :line)))
        (let ((width (ebox-layer--program-width program))
              (height (ebox-layer--program-height program)))
          (ebox-layer--program-replace-target
           program (plist-get node :node-id) pieces
           (ebox-layer--offset node :left host width)
           (ebox-layer--offset node :top host height)))))))

(defun ebox-update--dirty-kinds (operation)
  "Return the kinds of work OPERATION's current application performed.
`geometry' translates or crops retained primitives, `selector' publishes a
proved class change, `paint' recomputes a cascade and `span' re-renders a
composition boundary."
  (let ((groups (ebox-update--cohort-groups operation))
        (boundaries (ebox-update--cohort-boundaries operation))
        kinds)
    (dotimes (index (length groups))
      (let ((group (aref groups index)))
        (when (ebox-update--group-dirty group)
          (when (ebox-update--group-geometry-program group) (cl-pushnew 'geometry kinds))
          (when (ebox-update--group-class-slot group) (cl-pushnew 'selector kinds))
          (when (ebox-update--group-restyle group) (cl-pushnew 'paint kinds)))))
    (dotimes (index (length boundaries))
      (when (ebox-update--boundary-dirty (aref boundaries index)) (cl-pushnew 'span kinds)))
    (nreverse kinds)))

(defun ebox-update--stage (scene publication-report)
  "Stage SCENE's active cohort and its paired caller state."
  (let* ((operation (ebox-geometry--operation-active-operation scene))
         (state (ebox-update--cohort-state operation))
         (report (ebox-update--cohort-report operation)))
    (when ebox-surface--observation-context
      (setf (ebox-surface--observation-correlation-id ebox-surface--observation-context)
            (plist-get publication-report :transaction-id)))
    (setf (ebox-update--cohort-old-revision operation) (plist-get state :runtime-revision)
          (ebox-update--cohort-old-report operation) (plist-get state :last-update-report)
          (ebox-update--cohort-old-stale operation) (plist-get state :computed-styles-stale-p)
          (ebox-update--cohort-old-report-revision operation) (plist-get report :revision)
          (ebox-update--cohort-old-report-publication operation) (plist-get report :publication)
          (ebox-update--cohort-old-report-kinds operation) (plist-get report :dirty-kinds)
          (ebox-update--cohort-staged operation) t)
    (ebox-interaction--geometry-stage (ebox-geometry--operation-interaction scene))
    (plist-put state :runtime-revision (1- (plist-get publication-report :new-revision)))
    (plist-put report :revision (plist-get publication-report :new-revision))
    (plist-put report :publication publication-report)
    (plist-put report :dirty-kinds (ebox-update--dirty-kinds operation))
    (plist-put state :last-update-report report)
    (when (ebox-update--cohort-stage operation) (funcall (ebox-update--cohort-stage operation)))))

(defun ebox-update--restore-source (operation)
  "Restore OPERATION's restyled nodes, staged source and native hover cells."
  (let ((groups (ebox-update--cohort-groups operation)))
    ;; Snapshots follow staging, so restore derived styles before source slots.
    (ebox-update--forget-signatures operation)
    (dolist (entry (ebox-update--cohort-snapshots operation))
      (ebox-update--restore-node (car entry) (cdr entry)))
    (setf (ebox-update--cohort-snapshots operation) nil)
    (dotimes (index (length groups))
      (let ((group (aref groups index)))
        (when (ebox-update--group-staged group)
          (ebox-source--update-slots-rollback (ebox-update--group-slots group))
          (when (ebox-update--group-hover-cell group)
            (setcar (ebox-update--group-hover-cell group) (ebox-update--group-hover-old group)))
          (setf (ebox-update--group-staged group) nil))))))

(defun ebox-update--rollback (scene _report)
  "Restore SCENE's source, runtime, interaction and paired caller authority."
  (let* ((operation (ebox-geometry--operation-active-operation scene))
         (state (ebox-update--cohort-state operation)))
    (ebox-update--restore-source operation)
    (when (ebox-update--cohort-staged operation)
      (ebox-interaction--geometry-rollback (ebox-geometry--operation-interaction scene))
      (plist-put state :runtime-revision (ebox-update--cohort-old-revision operation))
      (plist-put state :last-update-report (ebox-update--cohort-old-report operation))
      (plist-put state :computed-styles-stale-p (ebox-update--cohort-old-stale operation))
      (plist-put (ebox-update--cohort-report operation) :revision (ebox-update--cohort-old-report-revision operation))
      (plist-put (ebox-update--cohort-report operation) :publication (ebox-update--cohort-old-report-publication operation))
      (plist-put (ebox-update--cohort-report operation) :dirty-kinds (ebox-update--cohort-old-report-kinds operation))
      (when (ebox-update--cohort-rollback operation) (funcall (ebox-update--cohort-rollback operation)))
      (setf (ebox-update--cohort-staged operation) nil))))

(defun ebox-update--accept (scene _report)
  "Accept SCENE's active cohort and retire general derived proofs."
  (let* ((operation (ebox-geometry--operation-active-operation scene))
         (state (ebox-update--cohort-state operation)))
    (ebox-interaction--geometry-accept (ebox-geometry--operation-interaction scene))
    (dolist (key '(:layout-snapshots :layout-fragments :render-signature-cache))
      (when (hash-table-p (plist-get state key)) (clrhash (plist-get state key))))
    (dolist (key '(:surface-owned-ranges :surface-fragments
                                         :native-render-fragment-template :native-committed-fragment-template
                                         :native-committed-owned-ranges :layout-snapshots-complete-p :layer-composition-cache))
      (when (plist-member state key) (plist-put state key nil)))))

;;;###autoload
(defun ebox-update-apply (operation values changed-indices &optional count)
  "Apply OPERATION's sparse CHANGED-INDICES from reusable VALUES atomically.
VALUES is a vector of member value vectors in preparation order.  COUNT is
the active prefix of CHANGED-INDICES, defaulting to its length.  Return t on
acceptance, nil before publication for stale or unsupported changes.  Errors
restore both provider and paired caller state; after-commit errors propagate
after acceptance."
  (unless (ebox-update--cohort-p operation)
    (signal 'wrong-type-argument (list 'ebox-update--cohort-p operation)))
  (if (ebox-surface-buffer-observer (ebox-update--cohort-buffer operation))
      (ebox-surface-call-with-observation
       (ebox-update--cohort-buffer operation) 'prepared-update
       (lambda () (ebox-update--apply operation values changed-indices count)))
    (ebox-update--apply operation values changed-indices count)))

(defun ebox-update--apply (operation values changed-indices count)
  "Execute OPERATION's prebound mixed primitive cohort."
  (let* ((members (ebox-update--cohort-members operation))
         (groups (ebox-update--cohort-groups operation))
         (scene (ebox-update--cohort-scene operation))
         (routes (ebox-geometry--operation-routes scene))
         (count (or count (and (vectorp changed-indices) (length changed-indices))))
         (epoch (1+ (ebox-update--cohort-epoch operation))) result)
    (unless (and (vectorp values) (= (length values) (length members))
                 (vectorp changed-indices) (integerp count) (<= 0 count (length changed-indices)))
      (user-error "Invalid Ebox prepared update values or member indices"))
    (when (ebox-update-valid-p operation)
      (setf (ebox-update--cohort-epoch operation) epoch
            (ebox-update--cohort-snapshots operation) nil
            (ebox-update--cohort-paint-changed operation) nil
            (ebox-update--cohort-staged operation) nil)
      (dotimes (index (length groups))
        (let* ((group (aref groups index)) (node (ebox-update--group-node group))
               (keys (ebox-update--group-properties group)) (owned (ebox-update--group-values group)))
          (setf (ebox-update--group-dirty group) nil (ebox-update--group-staged group) nil
                (ebox-update--group-resized group) nil (ebox-update--group-restyle group) nil
                (ebox-update--group-repaint group) nil
                (ebox-update--group-dx group) 0 (ebox-update--group-dy group) 0
                (ebox-update--group-z group) (or (ebox-get node :z-index) 0))
          (dotimes (key-index (length keys))
            (let ((current (ebox-update--group-current-value group key-index)))
              (cond
               ((eq (aref keys key-index) :border)
                (setcar (cddr (aref owned key-index)) (nth 2 current)))
               ((and (consp current) (consp (aref owned key-index))
                     (memq (aref keys key-index) '(:left :top :width :height)))
                (setcar (cdr (aref owned key-index)) (cadr current)))
               (t (aset owned key-index current)))))))
      (unwind-protect
          (catch 'unsupported
            (dotimes (position count)
              (let ((index (aref changed-indices position)))
                (unless (and (integerp index) (<= 0 index) (< index (length members))
                             (/= (aref (ebox-update--cohort-marks operation) index) epoch))
                  (user-error "Invalid or repeated Ebox prepared member index"))
                (aset (ebox-update--cohort-marks operation) index epoch)
                (let* ((member (aref members index)) (group (ebox-update--member-group member))
                       (incoming (aref values index)) (keys (ebox-update--member-properties member))
                       (offsets (ebox-update--member-offsets member)))
                  (unless (and (vectorp incoming) (= (length incoming) (length keys)))
                    (user-error "Prepared member values do not match their properties"))
                  (setf (ebox-update--group-dirty group) t)
                  ;; Only a raster value that differs from the displayed one
                  ;; re-renders the boundary; translation, crop and selector
                  ;; changes keep their retained primitives.
                  (dotimes (key-index (length keys))
                    (let* ((property (aref keys key-index))
                           (value (aref incoming key-index))
                           (offset (aref offsets key-index)))
                      (when (and (memq property '(:content :hover-content :color :background-color :bgcolor
                                                  :border :font-weight :visibility))
                                 (not (equal-including-properties
                                       value (ebox-update--group-current-value group offset))))
                        (setf (ebox-update--group-repaint group) t)
                        (unless (memq property '(:content :hover-content))
                          (setf (ebox-update--cohort-paint-changed operation) t
                                (ebox-update--group-restyle group) t)))
                      (ebox-update--capture-value group offset value)))
                  (when (ebox-update--group-resized group)
                    (setf (ebox-update--group-repaint group) t)))))
            (with-current-buffer (ebox-update--cohort-buffer operation)
              (when ebox-interaction--hover-content-owner
                (dotimes (index (length groups))
                  (let ((group (aref groups index)))
                    (when (and (ebox-update--group-dirty group)
                               (member ebox-interaction--hover-content-owner (ebox-update--group-hover-owners group)))
                      (throw 'unsupported nil))))))
            (dotimes (index (length routes))
              (ebox-layer--program-batch-begin (ebox-geometry--route-program (aref routes index))))
            (dotimes (index (length groups))
              (let ((group (aref groups index)))
                (when (ebox-update--group-dirty group)
                  (when (ebox-update--group-hover-cell group)
                    (setf (ebox-update--group-hover-old group) (car (ebox-update--group-hover-cell group))))
                  (setf (ebox-update--group-staged group) t)
                  (ebox-source--update-slots-stage (ebox-update--group-slots group) (ebox-update--group-values group))
                  (when (ebox-update--group-hover-cell group)
                    (setcar (ebox-update--group-hover-cell group)
                            (ebox-source--update-slots-value
                             (ebox-update--group-slots group)
                             (cl-position :hover-content (ebox-update--group-properties group)))))
                  (when (ebox-update--group-geometry-program group)
                    (let* ((program (ebox-update--group-geometry-program group))
                           (node (ebox-update--group-node group))
                           (target (gethash (plist-get node :node-id)
                                            (ebox-layer--program-targets program))))
                      (ebox-layer--program-translate
                       program target
                       (ebox-update--group-dx group) (ebox-update--group-dy group)
                       (ebox-update--group-z group))
                      (when (and (ebox-update--group-crop group)
                                 (not (ebox-geometry--resize-program
                                       program target (ebox-update--group-crop group)
                                       (cadr (ebox-get node :width)) (cadr (ebox-get node :height)))))
                        (throw 'unsupported nil)))))))
            ;; Source writes precede every derived computation, so several
            ;; changed members of one cascade observe the complete new input.
            ;; Geometry-only changes of a member that also owns paint keep the
            ;; cascade, so only changed paint recomputes it.
            (dotimes (index (length groups))
              (let ((group (aref groups index)))
                (when (and (ebox-update--group-dirty group) (ebox-update--group-style-p group)
                           (ebox-update--group-restyle group))
                  (ebox-update--restyle operation (ebox-update--group-node group)))))
            (let ((boundaries (ebox-update--cohort-boundaries operation)))
              (dotimes (index (length boundaries))
                (setf (ebox-update--boundary-dirty (aref boundaries index)) nil))
              (dotimes (index (length groups))
                (let ((group (aref groups index)))
                  (when (and (ebox-update--group-dirty group) (ebox-update--group-repaint group)
                             (ebox-update--group-boundary group))
                    (setf (ebox-update--boundary-dirty (ebox-update--group-boundary group)) t))))
              (ebox-update--forget-signatures operation)
              (ebox-incremental--with-phase 'layout
                (dotimes (index (length boundaries))
                  (when (ebox-update--boundary-dirty (aref boundaries index))
                    (ebox-update--replace-boundary operation (aref boundaries index))))))
            (dotimes (index (length routes))
              (ebox-layer--program-batch-end (ebox-geometry--route-program (aref routes index))))
            (setf (ebox-geometry--operation-active-operation scene) operation
                  (ebox-geometry--operation-frame-stage scene) #'ebox-update--stage
                  (ebox-geometry--operation-frame-rollback scene) #'ebox-update--rollback
                  (ebox-geometry--operation-frame-accept scene) #'ebox-update--accept)
            (let* ((rendered (ebox-incremental--with-phase 'layout
                                                           (ebox-geometry--render scene)))
                   (root-route (aref routes (1- (length routes))))
                   (mount-count
                    (and rendered (ebox-incremental--with-phase 'projection
                                                                (ebox-geometry--fill
                                                                 scene rendered
                                                                 (ebox-geometry--route-lines root-route) (ebox-geometry--route-dirty root-route))))))
              (when (and mount-count
                         (ebox-interaction--geometry-ready-p
                          (ebox-geometry--operation-interaction scene)
                          (ebox-surface--geometry-mount-slots (ebox-geometry--operation-projection scene))
                          mount-count rendered))
                (setq result
                      (ebox-incremental--with-phase 'transaction
                                                    (ebox--pub-frame-publish
                                                     (ebox-geometry--operation-frame scene) rendered (ebox-update--cohort-state operation) mount-count
                                                     (ebox-geometry--route-damage root-route) (ebox-geometry--route-damage-count root-route)))))))
        (unless result (ebox-update--restore-source operation))
        (dotimes (index (length routes))
          (let ((route (aref routes index)))
            (ebox-layer--program-settle (ebox-geometry--route-program route) (and result t))
            (ebox-geometry--settle-wrapper route (and result t)))))
      (when result
        (setf (ebox-update--cohort-staged operation) nil)
        (setf (ebox-update--cohort-snapshots operation) nil)
        (dotimes (index (length groups))
          (setf (ebox-update--group-staged (aref groups index)) nil))
        (when (ebox-update--cohort-after-commit operation) (funcall (ebox-update--cohort-after-commit operation)))
        t))))

(provide 'ebox-update)
;;; ebox-update.el ends here
